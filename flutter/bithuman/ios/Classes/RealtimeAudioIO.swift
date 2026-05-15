// RealtimeAudioIO — single AVAudioEngine with VP-IO that owns both mic
// capture and TTS playback. iOS port of the macOS implementation under
// macos/Classes/RealtimeAudioIO.swift.
//
// iOS adds an AVAudioSession configuration step (.playAndRecord +
// .voiceChat mode) and a handler for AVAudioSession.interruptionNotification
// so phone calls / Siri / route changes don't permanently freeze the
// engine.
//
// Apache-2.0; (c) bitHuman.

import Foundation
import AVFoundation
import Flutter

/// Verbose-audio logging gate. Honors the `BITHUMAN_DEBUG_AUDIO` env
/// var: set to "1" / "true" to surface per-chunk RMS, per-channel peak
/// diagnostics, mic event-channel traces, etc.
private let kVerboseAudioLog: Bool = {
  let v = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_AUDIO"] ?? ""
  return v == "1" || v.lowercased() == "true"
}()

@inline(__always)
private func vlog(_ msg: @autoclosure () -> String) {
  if kVerboseAudioLog { NSLog("%@", msg()) }
}

final class RealtimeAudioIO: NSObject, FlutterStreamHandler {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  // Mixer node between player and output. The player is connected at
  // the OpenAI native 24 kHz Float32 format; the mixer takes that input
  // and outputs at the VP-IO output's real bus format (44.1/48 kHz
  // Float32). The mixer's internal resampler maintains continuous state
  // across scheduled buffers, eliminating chunk-boundary clicks that a
  // per-chunk AVAudioConverter would introduce.
  private let mixer = AVAudioMixerNode()
  private var playerFormat: AVAudioFormat?

  // Resample target for the mic stream we hand back to Dart. OpenAI
  // Realtime wants 24 kHz mono PCM16; do the resample once in native
  // so Dart never sees float / device-rate samples.
  private let micTarget = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: false)!

  // Resample target for the lipsync push. Engine wants 16 kHz int16.
  private let lipsyncTarget = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false)!

  // Inbound TTS chunks from OpenAI are 24 kHz mono PCM16, but we
  // immediately convert to Float32 before scheduling — the mixer
  // reliably accepts Float32 input.
  private let serverTtsFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 24_000,
    channels: 1,
    interleaved: false)!

  private var micConverter: AVAudioConverter?
  private var micConverterSrcFormat: AVAudioFormat?
  private let lipsyncConverter: AVAudioConverter
  private var started = false

  // Event channel sink — set when Dart subscribes.
  private var micEventSink: FlutterEventSink?

  // Forward each resampled chunk to the AvatarTexture so it lands in the
  // avatar's compose buffer at the same moment we hand it to the player.
  weak var avatarTextureForLipsync: AvatarTexture?

  override init() {
    self.lipsyncConverter = AVAudioConverter(from: serverTtsFormat, to: lipsyncTarget)!
    super.init()
  }

  // MARK: - FlutterStreamHandler (mic event channel)

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.micEventSink = events
    vlog("[RealtimeAudioIO] mic event channel: Dart subscribed")
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.micEventSink = nil
    vlog("[RealtimeAudioIO] mic event channel: Dart cancelled")
    return nil
  }

  private var micChunkCount = 0
  private var spkChunkCount = 0

  // Local voice-activity detection state (see macOS impl for the full
  // rationale). Mic chunks with PCM16 peak above this threshold count
  // as "user is talking" and trigger a local barge before OpenAI's
  // server-VAD fires.
  private var lastVoiceActivityAt: Date?
  private let voicePeakThreshold: Int32 = 2500
  private let voiceQuietTimeoutSecs: TimeInterval = 0.5
  // Duration gate: barge only after the mic has stayed above the peak
  // threshold continuously for this many seconds. Filters out throat
  // clears, lip smacks, and brief ambient spikes. The user said the
  // agent felt hair-trigger interruptable on iPhone — the loudness
  // threshold alone fires within a single 10 ms tap callback, while a
  // genuine word is consistently loud for 100+ ms. 0.4 s = a clear
  // syllable, comfortable for the user to commit to barging.
  private let voiceSustainSecs: TimeInterval = 0.4
  // Wall-clock timestamp of the FIRST sustained-loud tap chunk in the
  // current potential-speech run. Cleared when the mic falls below
  // threshold; barge fires when (now - firstLoudAt) >= voiceSustainSecs.
  private var firstLoudAt: Date?
  // True once we've fired a barge for the current loud run — prevents
  // refiring on every subsequent loud chunk. Reset when the mic falls
  // back below threshold.
  private var bargedForCurrentRun: Bool = false

  private var isUserVoiceActive: Bool {
    guard let t = lastVoiceActivityAt else { return false }
    return Date().timeIntervalSince(t) < voiceQuietTimeoutSecs
  }

  // MARK: - Lifecycle

  /// One-time graph setup. Attaching a node twice on the same engine
  /// raises an NSException, so the attach + connect dance MUST happen
  /// exactly once per RealtimeAudioIO. Gated by `graphConfigured`.
  private var graphConfigured = false
  private func configureGraphIfNeeded() throws {
    if graphConfigured { return }
    let input = engine.inputNode
    let output = engine.outputNode

    // VP on BOTH ends before connecting. Single-sided VP on iOS gives
    // the same -10875 (kAudioUnitErr_FailedInitialization) we see on
    // macOS — the two IO ends end up at mismatched sample rates.
    try input.setVoiceProcessingEnabled(true)
    try output.setVoiceProcessingEnabled(true)

    let outBusFormat = output.inputFormat(forBus: 0)
    engine.attach(player)
    engine.attach(mixer)
    engine.connect(player, to: mixer, format: serverTtsFormat)
    engine.connect(mixer, to: output, format: outBusFormat)
    graphConfigured = true
  }

  /// Configure the shared AVAudioSession for full-duplex voice chat. The
  /// .voiceChat mode opts the session into Apple's VP-IO unit (matches
  /// what `setVoiceProcessingEnabled(true)` would request on the route).
  /// .defaultToSpeaker routes the output to the loudspeaker instead of
  /// the earpiece on iPhones; .allowBluetooth lets users keep their
  /// AirPods/HFP routes.
  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
    if #available(iOS 14.5, *) {
      // .allowBluetoothA2DP would force output-only BT; we want full
      // duplex so the HFP profile (mono in/out) is required — already
      // covered by .allowBluetooth.
      _ = options
    }
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
    try session.setPreferredSampleRate(48_000)
    try session.setActive(true)
  }

  // Strong refs on the notification observers so we can remove them in stop().
  private var interruptionObserver: NSObjectProtocol?
  private var routeChangeObserver: NSObjectProtocol?

  private func registerInterruptionHandler() {
    let nc = NotificationCenter.default
    interruptionObserver = nc.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] note in
      guard let self = self,
            let info = note.userInfo,
            let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
      switch type {
      case .began:
        NSLog("[RealtimeAudioIO] AVAudioSession interruption BEGAN — pausing engine")
        if self.started, self.engine.isRunning {
          self.engine.pause()
          self.player.pause()
        }
      case .ended:
        let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
          AVAudioSession.InterruptionOptions(rawValue: $0)
        } ?? []
        if opts.contains(.shouldResume), self.started {
          do {
            try AVAudioSession.sharedInstance().setActive(true)
            try self.engine.start()
            self.player.play()
            NSLog("[RealtimeAudioIO] AVAudioSession interruption ENDED — resumed")
          } catch {
            NSLog("[RealtimeAudioIO] interruption resume failed: %@",
                  error.localizedDescription)
          }
        }
      @unknown default:
        break
      }
    }
  }

  private func unregisterInterruptionHandler() {
    if let obs = interruptionObserver {
      NotificationCenter.default.removeObserver(obs)
      interruptionObserver = nil
    }
    if let obs = routeChangeObserver {
      NotificationCenter.default.removeObserver(obs)
      routeChangeObserver = nil
    }
  }

  func start() throws {
    if started { return }
    try configureAudioSession()
    try configureGraphIfNeeded()

    let input = engine.inputNode
    let tapFormat = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buf, _ in
      self?.handleMicBuffer(buf)
    }

    engine.prepare()
    try engine.start()
    self.playerFormat = player.outputFormat(forBus: 0)
    player.play()
    started = true
    registerInterruptionHandler()
    NSLog("[RealtimeAudioIO] up: mic sr=%.0f Hz, player sr=%.0f Hz, vp=on",
          tapFormat.sampleRate, self.playerFormat?.sampleRate ?? 0)
  }

  func stop() {
    if !started { return }
    started = false
    unregisterInterruptionHandler()
    player.stop()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    // Reset converter caches but KEEP the engine graph wired so a
    // subsequent start() doesn't try to re-attach nodes (which would
    // throw NSException and crash the process).
    micConverter = nil
    micConverterSrcFormat = nil
    // Release the audio session so other apps can use the mic.
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: [.notifyOthersOnDeactivation])
    } catch {
      NSLog("[RealtimeAudioIO] session deactivate failed: %@",
            error.localizedDescription)
    }
  }

  /// Cut the agent off mid-sentence. See macOS impl for full rationale.
  func barge() {
    NSLog("[RealtimeAudioIO] barge: cancelling agent playback + lipsync")
    if started {
      player.stop()
      player.reset()
      player.play()
    }
    avatarTextureForLipsync?.clearAudioQueue()
  }

  // MARK: - Mic tap → resample → event channel

  /// Mic bytes go to:
  ///   1. `micEventSink` (Flutter EventChannel) — Dart forwards to OpenAI
  ///   2. Local VAD trigger that calls `barge()` on speech onset.
  /// Never to the avatar's lipsync queue.
  private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
    let src = buffer.format
    if micChunkCount % 50 == 0 || micChunkCount == 0 {
      let n = Int(buffer.frameLength)
      let nch = Int(src.channelCount)
      var peaks = [Float](repeating: 0, count: nch)
      if let fchPtr = buffer.floatChannelData {
        for c in 0..<nch {
          let ch = fchPtr[c]
          var maxAbs: Float = 0
          for i in stride(from: 0, to: n, by: 8) {
            let a = ch[i] < 0 ? -ch[i] : ch[i]
            if a > maxAbs { maxAbs = a }
          }
          peaks[c] = maxAbs
        }
      }
      let peakStr = peaks.map { String(format: "%.4f", $0) }.joined(separator: ",")
      vlog("[RealtimeAudioIO] tap RAW: ch=\(nch) sr=\(Int(src.sampleRate)) per-ch peak=[\(peakStr)]")
    }
    // Defensive ch=0 extraction. iOS mic taps are almost always mono
    // already, but the macOS port hit a 9-channel quirk on M-series
    // and the wrapper is a no-op when input is mono — keep it.
    let monoSrcFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: src.sampleRate,
      channels: 1,
      interleaved: false)!
    guard let monoBuf = AVAudioPCMBuffer(pcmFormat: monoSrcFormat,
                                         frameCapacity: buffer.frameLength) else { return }
    monoBuf.frameLength = buffer.frameLength
    if let srcCh0 = buffer.floatChannelData?[0],
       let dst = monoBuf.floatChannelData?[0] {
      dst.update(from: srcCh0, count: Int(buffer.frameLength))
    }

    if micConverter == nil || micConverterSrcFormat?.sampleRate != monoSrcFormat.sampleRate {
      micConverter = AVAudioConverter(from: monoSrcFormat, to: micTarget)
      micConverterSrcFormat = monoSrcFormat
    }
    guard let conv = micConverter else { return }
    let ratio = micTarget.sampleRate / monoSrcFormat.sampleRate
    let outCap = AVAudioFrameCount(Double(monoBuf.frameLength) * ratio + 16)
    guard let out = AVAudioPCMBuffer(pcmFormat: micTarget, frameCapacity: outCap) else { return }
    var delivered = false
    var err: NSError?
    let status = conv.convert(to: out, error: &err) { _, statusOut in
      if delivered { statusOut.pointee = .noDataNow; return nil }
      delivered = true
      statusOut.pointee = .haveData
      return monoBuf
    }
    if status == .error || out.frameLength == 0 { return }
    guard let int16Ptr = out.int16ChannelData?[0] else { return }
    let n = Int(out.frameLength) * 2

    // Local VAD → barge on speech onset.
    var maxAbs: Int32 = 0
    let frames = Int(out.frameLength)
    for i in stride(from: 0, to: frames, by: 8) {
      let a = int16Ptr[i] < 0 ? -Int32(int16Ptr[i]) : Int32(int16Ptr[i])
      if a > maxAbs { maxAbs = a }
    }
    if maxAbs > voicePeakThreshold {
      let now = Date()
      lastVoiceActivityAt = now
      if firstLoudAt == nil { firstLoudAt = now }
      let runMs = now.timeIntervalSince(firstLoudAt!)
      if runMs >= voiceSustainSecs && !bargedForCurrentRun {
        bargedForCurrentRun = true
        NSLog("[RealtimeAudioIO] local VAD: sustained speech %d ms (peak=%d) → barge",
              Int(runMs * 1000), maxAbs)
        // NEVER touch engine/player state from inside the tap callback —
        // tap runs on the realtime audio thread and player.stop() does
        // dispatch_sync, deadlocking. Hop to the main queue.
        DispatchQueue.main.async { [weak self] in self?.barge() }
      }
    } else {
      // Mic went quiet — reset the sustain timer + barge interlock so
      // a fresh loud run has to accumulate voiceSustainSecs again.
      firstLoudAt = nil
      bargedForCurrentRun = false
    }

    let data = Data(bytes: int16Ptr, count: n)
    micChunkCount += 1
    let logThisChunk = micChunkCount == 1 || micChunkCount % 50 == 0
    if logThisChunk {
      let frames = Int(out.frameLength)
      var sumSq: Double = 0
      var peak: Int16 = 0
      for i in stride(from: 0, to: frames, by: 8) {
        let s = int16Ptr[i]
        let absS = s < 0 ? -Int32(s) : Int32(s)
        if Int32(peak) < absS { peak = Int16(min(Int32(Int16.max), absS)) }
        let f = Double(s)
        sumSq += f * f
      }
      let rmsAvg = (sumSq / Double(max(1, frames/8))).squareRoot()
      vlog("[RealtimeAudioIO] mic chunk #\(micChunkCount) → Dart (\(n) bytes, peak=\(peak) rms=\(Int(rmsAvg)))")
    }
    if let sink = micEventSink {
      DispatchQueue.main.async { sink(FlutterStandardTypedData(bytes: data)) }
    } else if logThisChunk {
      NSLog("[RealtimeAudioIO] mic chunk #%d DROPPED: no Dart subscriber",
            micChunkCount)
    }
  }

  // MARK: - Speaker playback (24 kHz PCM16 → engine format) + lipsync push

  /// Schedule a chunk of OpenAI Realtime TTS audio for playback AND
  /// push the same chunk (resampled to 16 kHz) into the avatar's
  /// audio queue so the lipsync animates against the same bytes the
  /// speaker is rendering.
  func playSpeakerPCM24k(_ pcm: Data) {
    spkChunkCount += 1
    if spkChunkCount == 1 || spkChunkCount % 50 == 0 {
      vlog("[RealtimeAudioIO] bot chunk #\(spkChunkCount) (\(pcm.count) bytes from OpenAI)")
    }
    // Hard gate: drop bot chunks while the user is talking.
    if isUserVoiceActive {
      return
    }
    let frameCount = AVAudioFrameCount(pcm.count / 2)
    guard frameCount > 0,
          let inBuf = AVAudioPCMBuffer(pcmFormat: serverTtsFormat, frameCapacity: frameCount)
    else { return }
    inBuf.frameLength = frameCount
    if let dst = inBuf.floatChannelData?[0] {
      pcm.withUnsafeBytes { src in
        guard let base = src.baseAddress else { return }
        let i16 = base.assumingMemoryBound(to: Int16.self)
        let n = Int(frameCount)
        let scale: Float = 1.0 / 32768.0
        for i in 0..<n {
          dst[i] = Float(i16[i]) * scale
        }
      }
    }

    // 1. Speaker — scheduled into the player → mixer → output graph.
    player.scheduleBuffer(inBuf, completionHandler: nil)
    if !player.isPlaying { player.play() }

    // 2. Lipsync — resample 24 → 16 kHz and push to the avatar runtime.
    let outCap = AVAudioFrameCount(Double(frameCount) * 16_000.0 / 24_000.0 + 16)
    if let outBuf = AVAudioPCMBuffer(pcmFormat: lipsyncTarget, frameCapacity: outCap) {
      var delivered = false
      var err: NSError?
      let status = lipsyncConverter.convert(to: outBuf, error: &err) { _, statusOut in
        if delivered { statusOut.pointee = .noDataNow; return nil }
        delivered = true
        statusOut.pointee = .haveData
        return inBuf
      }
      if status != .error,
         let i16Ptr = outBuf.int16ChannelData?[0] {
        let bytes = Int(outBuf.frameLength) * 2
        let pushData = Data(bytes: i16Ptr, count: bytes)
        avatarTextureForLipsync?.enqueuePCM(pushData)
      }
    }
  }
}
