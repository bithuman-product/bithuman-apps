// RealtimeAudioIO — single AVAudioEngine with VP-IO that owns both mic
// capture and TTS playback. Direct port of the canonical AudioGraph used
// by `bithuman-cli avatar --openai` (bithuman-sdk/swift/.../AudioGraph.swift).
//
// Why this exists: Flutter's `record` and `audioplayers` packages are
// independent CoreAudio clients. macOS doesn't share an APM between
// independent clients, so:
//   - Speaker output leaks back into the mic (self-talk loop)
//   - The avatar's lipsync queue and the speaker's playback queue have
//     no shared clock, so video drifts ahead/behind audio
//
// Putting both into a single AVAudioEngine with `setVoiceProcessingEnabled`
// on BOTH the input and output node gives us Apple's VP-IO aggregate:
//   - Acoustic echo cancellation (no self-talk)
//   - Noise suppression + AGC for free
//   - A common reference clock for mic ↔ player ↔ lipsync
//
// Apache-2.0; (c) bitHuman.

import Foundation
import AVFoundation
import FlutterMacOS

/// Verbose-audio logging gate. Honors the `BITHUMAN_DEBUG_AUDIO` env
/// var: set to "1" / "true" to surface per-chunk RMS, per-channel peak
/// diagnostics, mic event-channel traces, etc. Steady-state production
/// runs leave this off so logs only contain lifecycle + error lines —
/// mobile log pipes are slow + size-constrained.
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
  // the OpenAI native 24 kHz Int16 format; the mixer takes that input
  // and outputs at the VP-IO output's real bus format (48 kHz Float32).
  // The mixer's internal resampler maintains continuous state across
  // scheduled buffers, eliminating chunk-boundary clicks that a
  // per-chunk AVAudioConverter would introduce.
  private let mixer = AVAudioMixerNode()
  private var playerFormat: AVAudioFormat?

  // Resample target for the mic stream we hand back to Dart. OpenAI
  // Realtime wants 24 kHz mono PCM16; do the resample once in native
  // so Dart never sees 48 kHz Float32.
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
  // immediately convert to Float32 before scheduling — Int16 → Float32
  // is stateless and cheap, while AVAudioMixerNode reliably accepts
  // Float32 input. Routing Int16 through the mixer on macOS produces
  // a robotic "zzz" buzz because the mixer doesn't correctly type-pun
  // the channel data.
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
  // The texture owns the runtime + audio queue; we just push bytes.
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

  // Local voice-activity detection state. Mic chunks with PCM16 peak
  // above this threshold count as "user is talking". The first such
  // chunk after a quiet period triggers a local barge (player + lipsync
  // wiped) so the avatar stops animating before OpenAI's server-VAD
  // has a chance to fire (which would take ~300 ms via prefix_padding).
  // The "still talking" window stays open for voiceQuietTimeoutSecs
  // after the last loud chunk — while open, ALL bot audio is dropped
  // at playSpeakerPCM24k, so neither the speaker nor the lipsync runs
  // even if trailing `response.audio.delta` events keep arriving from
  // the cancelled response.
  private var lastVoiceActivityAt: Date?
  private let voicePeakThreshold: Int32 = 1500   // ~0.045 of full scale int16
  private let voiceQuietTimeoutSecs: TimeInterval = 0.5

  private var isUserVoiceActive: Bool {
    guard let t = lastVoiceActivityAt else { return false }
    return Date().timeIntervalSince(t) < voiceQuietTimeoutSecs
  }

  // MARK: - Lifecycle

  /// One-time graph setup. Attaching a node twice on the same engine
  /// raises an NSException that crashes the process, so the attach +
  /// connect dance MUST happen exactly once per RealtimeAudioIO. Call
  /// this from `start()` and gate it with `graphConfigured`.
  private var graphConfigured = false
  private func configureGraphIfNeeded() throws {
    if graphConfigured { return }
    let input = engine.inputNode
    let output = engine.outputNode

    // VP on BOTH ends before connecting. Single-sided VP makes the two
    // IO ends run at mismatched sample rates and engine.start() fails
    // with kAudioUnitErr_FailedInitialization (-10875) on outputNode.
    try input.setVoiceProcessingEnabled(true)
    try output.setVoiceProcessingEnabled(true)

    // Player → Mixer → Output. The mixer is the resampler: player
    // delivers 24 kHz Float32 chunks, mixer hands the VP-IO output node
    // 48 kHz Float32 with continuous polyphase-filter state across
    // chunks. Connecting the player DIRECTLY to the output at 24 kHz
    // fails -10875 because VP-IO requires its input bus to match its
    // own output rate. The mixer is the canonical AVFoundation pattern
    // for bridging sample rates between nodes.
    let outBusFormat = output.inputFormat(forBus: 0)
    engine.attach(player)
    engine.attach(mixer)
    engine.connect(player, to: mixer, format: serverTtsFormat)
    engine.connect(mixer, to: output, format: outBusFormat)
    graphConfigured = true
  }

  func start() throws {
    if started { return }
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
    NSLog("[RealtimeAudioIO] up: mic sr=%.0f Hz, player sr=%.0f Hz, vp=on",
          tapFormat.sampleRate, self.playerFormat?.sampleRate ?? 0)
  }

  func stop() {
    if !started { return }
    started = false
    player.stop()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    // Reset converter caches but KEEP the engine graph wired so a
    // subsequent start() doesn't try to re-attach nodes (which would
    // throw NSException and crash the process).
    micConverter = nil
    micConverterSrcFormat = nil
  }

  /// Cut the agent off mid-sentence. Fired the moment OpenAI detects
  /// the user has started talking (speech_started), well before the
  /// user finishes their sentence. Two things must happen in lockstep:
  ///   1. Stop the speaker so the agent's buffered audio doesn't keep
  ///      playing. `player.stop()` halts FUTURE scheduled buffers but
  ///      lets the CURRENT one finish (up to ~100 ms of tail); add
  ///      `player.reset()` to flush the in-flight render state too, so
  ///      the speaker goes silent within ~10 ms.
  ///   2. Tell the avatar to stop lipsyncing the cancelled audio.
  ///      Reset the runtime so the compose cursor goes back to 0 and
  ///      the looping-idle path kicks in until the next bot chunk.
  func barge() {
    NSLog("[RealtimeAudioIO] barge: cancelling agent playback + lipsync")
    if started {
      player.stop()
      player.reset()
      // Restart the player so the NEXT scheduleBuffer call (when the
      // agent resumes talking) actually plays. Without this, isPlaying
      // stays false and new buffers queue but never render.
      player.play()
    }
    // Drop any queued mic-pump bytes that the avatar texture hasn't
    // consumed yet — they were lipsync-bound for the cancelled
    // response and shouldn't drive the next utterance.
    avatarTextureForLipsync?.clearAudioQueue()
  }

  // MARK: - Mic tap → resample → event channel

  /// Architectural invariant: this method is the ONLY path mic audio
  /// takes through the plugin, and it forwards bytes to two
  /// destinations:
  ///   1. `micEventSink` (Flutter EventChannel) — Dart picks these up
  ///      and forwards to the OpenAI Realtime WebSocket as
  ///      `input_audio_buffer.append`.
  ///   2. The local VAD trigger that calls `barge()` on speech onset.
  ///
  /// Mic bytes MUST NEVER reach `avatarTextureForLipsync.enqueuePCM`.
  /// The bithuman runtime is fed ONLY by `playSpeakerPCM24k`, whose
  /// input is the bot's PCM from OpenAI's response.audio.delta. The
  /// avatar must lipsync the AGENT, never the USER.
  private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
    let src = buffer.format
    // Per-channel RMS for the first few diagnostic chunks — surfaces the
    // ch=9 multi-channel-input mystery (which channel actually has the
    // user's voice).
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
    // AVAudioConverter's automatic N→1 downmix produces silence when
    // the source has > 2 channels on macOS (observed: ch=9 from the
    // VP-IO input bus on M-series Macs even when the underlying
    // device is the built-in mic). Work around by manually extracting
    // channel 0 into a mono intermediate buffer FIRST, then converting
    // 1→1 (just sample-rate + Float32→Int16) which the converter
    // handles correctly.
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

    // Local voice-activity detection on the post-AEC mic signal. If
    // peak crosses the threshold we treat it as "user is talking" and:
    //   1. Refresh `lastVoiceActivityAt` so playSpeakerPCM24k keeps
    //      muting the agent until 0.5 s after the user falls silent.
    //   2. On the edge (was-quiet → now-loud) call `barge()` to clear
    //      already-buffered agent audio (speaker + lipsync) so we don't
    //      have to wait the ~300 ms for OpenAI's `speech_started` to
    //      arrive over the WebSocket.
    var maxAbs: Int32 = 0
    let frames = Int(out.frameLength)
    for i in stride(from: 0, to: frames, by: 8) {
      let a = int16Ptr[i] < 0 ? -Int32(int16Ptr[i]) : Int32(int16Ptr[i])
      if a > maxAbs { maxAbs = a }
    }
    if maxAbs > voicePeakThreshold {
      let wasQuiet = !isUserVoiceActive
      lastVoiceActivityAt = Date()
      if wasQuiet {
        let peakForLog = maxAbs
        NSLog("[RealtimeAudioIO] local VAD: speech onset (peak=%d) → barge",
              peakForLog)
        // CRITICAL: NEVER touch AVAudioEngine/PlayerNode state (stop/
        // reset/play/scheduleBuffer) from inside an installed tap
        // callback. The tap runs on the realtime audio thread, and
        // AVAudioPlayerNode.stop() internally does dispatch_sync on
        // that same queue, producing the "BUG IN CLIENT OF
        // LIBDISPATCH: dispatch_sync called on queue already owned by
        // current thread" SIGTRAP. Hop to the main queue.
        DispatchQueue.main.async { [weak self] in self?.barge() }
      }
    }

    let data = Data(bytes: int16Ptr, count: n)
    micChunkCount += 1
    let logThisChunk = micChunkCount == 1 || micChunkCount % 50 == 0
    if logThisChunk {
      // Quick RMS so we can tell silence from speech without leaving
      // the device. If this is always ~0 the mic isn't actually
      // capturing — either the OS is sending us silence, or VP-IO is
      // suppressing everything as "echo".
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
  /// speaker is rendering. Both calls happen synchronously here, so
  /// the avatar's compose queue and the player's render queue drain
  /// from the same source at the same instant.
  func playSpeakerPCM24k(_ pcm: Data) {
    spkChunkCount += 1
    if spkChunkCount == 1 || spkChunkCount % 50 == 0 {
      vlog("[RealtimeAudioIO] bot chunk #\(spkChunkCount) (\(pcm.count) bytes from OpenAI)")
    }
    // Hard gate: if the local VAD heard the user within the last
    // voiceQuietTimeoutSecs, drop this bot chunk entirely. The
    // speaker stays silent AND the avatar lipsync queue gets no
    // input — so the agent's already-buffered response can't keep
    // playing or animating while the user is talking, even before
    // OpenAI's server-VAD has notified us via speech_started.
    if isUserVoiceActive {
      return
    }
    let frameCount = AVAudioFrameCount(pcm.count / 2)
    guard frameCount > 0,
          let inBuf = AVAudioPCMBuffer(pcmFormat: serverTtsFormat, frameCapacity: frameCount)
    else { return }
    inBuf.frameLength = frameCount
    // Convert PCM16 → Float32 [-1, 1] inline. Stateless per-sample
    // scale (1/32768) — no risk of chunk-boundary artifacts. The
    // mixer downstream only needs to do the sample-rate change, which
    // it does correctly with continuous state.
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

    // 1. Speaker — schedule directly at the native 24 kHz Int16 format.
    // The engine's internal resampler bridges to the 48 kHz VP-IO output
    // with continuous state, so chunk boundaries are sample-clean.
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
