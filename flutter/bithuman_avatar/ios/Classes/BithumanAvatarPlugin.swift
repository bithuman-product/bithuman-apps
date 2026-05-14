// bithuman_avatar — iOS native plugin (v0.4).
//
// Mirrors the macOS plugin (macos/Classes/BithumanAvatarPlugin.swift) with
// the Flutter framework + UIKit types + the iOS slice of libessence
// vendored at ios/Vendor/build-ios{,-sim}/. The libessence + FFmpeg/HDF5/
// libwebp/libjpeg-turbo static libs are linked at podspec time; ORT comes
// in as an xcframework symlinked under ios/Frameworks/.
//
// Apache-2.0; (c) bitHuman.

import Flutter
import UIKit
import Accelerate
import CoreVideo
import CLibessence

public class BithumanAvatarPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  private var textures: [Int64: AvatarTexture] = [:]
  // One audio engine per texture (= per session). Holds the VP-IO graph
  // that owns mic + speaker for that conversation.
  private var audioIOs: [Int64: RealtimeAudioIO] = [:]
  // FlutterEventChannel MUST be retained for the lifetime of the
  // stream. Without this, the channel is deallocated when the
  // audioStart method handler returns and the mic stream never
  // delivers chunks to Dart even though the native VP-IO tap is firing.
  private var micChannels: [Int64: FlutterEventChannel] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    setenv("BITHUMAN_UNMETERED", "1", 1)

    let channel = FlutterMethodChannel(
      name: "ai.bithuman.avatar",
      binaryMessenger: registrar.messenger())
    let instance = BithumanAvatarPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "load":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "load requires path", details: nil))
        return
      }
      guard let textureRegistry = registrar?.textures() else {
        result(FlutterError(code: "NO_REGISTRY",
                            message: "no FlutterTextureRegistry available",
                            details: nil))
        return
      }
      let texture = AvatarTexture(imxPath: path)
      let textureId = textureRegistry.register(texture)
      texture.textureId = textureId
      texture.registry = textureRegistry
      textures[textureId] = texture
      texture.startRendering()
      NSLog("[BithumanAvatar] load id=%lld path=%@", textureId, path)
      result(textureId)

    case "pushAudio":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let pcm = args["pcm"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "pushAudio requires textureId + pcm",
                            details: nil))
        return
      }
      textures[textureId]?.enqueuePCM(pcm.data)
      result(nil)

    case "dispose":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "dispose requires textureId",
                            details: nil))
        return
      }
      if let tex = textures.removeValue(forKey: textureId) {
        tex.shutdown()
        registrar?.textures().unregisterTexture(textureId)
      }
      audioIOs[textureId]?.stop()
      audioIOs.removeValue(forKey: textureId)
      micChannels.removeValue(forKey: textureId)
      result(nil)

    case "engineVersion":
      let ver = String(cString: be_library_version())
      let abi = be_abi_version()
      result("\(ver) (ABI \(abi))")

    case "audioStart":
      // Stand up the VP-IO audio engine for this texture's session.
      // Also installs a Flutter EventChannel at
      // ai.bithuman.avatar.mic/<textureId> for 24 kHz PCM16 mic chunks.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let texture = textures[textureId] else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "audioStart requires textureId",
                            details: nil))
        return
      }
      if audioIOs[textureId] == nil {
        let io = RealtimeAudioIO()
        io.avatarTextureForLipsync = texture
        audioIOs[textureId] = io
        if let messenger = registrar?.messenger() {
          let micChan = FlutterEventChannel(
            name: "ai.bithuman.avatar.mic/\(textureId)",
            binaryMessenger: messenger)
          micChan.setStreamHandler(io)
          // RETAIN the channel — without this, ARC frees it when this
          // method returns and the mic stream silently never delivers
          // chunks to Dart even though the native tap is firing.
          micChannels[textureId] = micChan
          NSLog("[BithumanAvatar] mic EventChannel registered: %@", micChan)
        }
      }
      do {
        try audioIOs[textureId]?.start()
        result(nil)
      } catch {
        result(FlutterError(code: "AUDIO_START_FAILED",
                            message: error.localizedDescription,
                            details: nil))
      }

    case "audioStop":
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "audioStop requires textureId",
                            details: nil))
        return
      }
      audioIOs[textureId]?.stop()
      audioIOs.removeValue(forKey: textureId)
      micChannels.removeValue(forKey: textureId)
      result(nil)

    case "interrupt":
      // Barge-in: kill the agent's in-flight playback + lipsync.
      // Called from Dart the moment input_audio_buffer.speech_started
      // arrives from OpenAI (well before silence_duration_ms detects
      // end-of-user-turn).
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64 else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "interrupt requires textureId",
                            details: nil))
        return
      }
      audioIOs[textureId]?.barge()
      result(nil)

    case "playSpeakerPCM":
      // Take a chunk of 24 kHz PCM16 bot audio from OpenAI Realtime,
      // schedule it for playback, AND push the same chunk (resampled
      // to 16 kHz) into the avatar's lipsync queue. Both happen
      // synchronously here so A/V stays paired chunk-by-chunk.
      guard let args = call.arguments as? [String: Any],
            let textureId = args["textureId"] as? Int64,
            let pcm = args["pcm"] as? FlutterStandardTypedData,
            let io = audioIOs[textureId] else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "playSpeakerPCM requires audioStart + textureId + pcm",
                            details: nil))
        return
      }
      io.playSpeakerPCM24k(pcm.data)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

final class AvatarTexture: NSObject, FlutterTexture {
  let imxPath: String
  var textureId: Int64 = 0
  weak var registry: FlutterTextureRegistry?

  init(imxPath: String) {
    self.imxPath = imxPath
    super.init()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelBufferLock.lock()
    let buf = latestPixelBuffer
    pixelBufferLock.unlock()
    guard let pb = buf else { return nil }
    return Unmanaged.passRetained(pb)
  }

  /// Drop everything queued for lipsync AND wipe the live audio
  /// accumulator. Used by the barge-in path so the avatar stops
  /// animating the cancelled response and slides back to the
  /// looping-idle path until the next bot chunk lands.
  ///
  /// Note: we MUST zero `audioBuf` (not just reset audioValidCount).
  /// The looping-idle compose path passes `audioBuf[0..<padded]` to
  /// tick_compose every tick, with `padded = (ticksEmitted+5)·spt`.
  /// If those bytes still hold the previous agent's voice (which they
  /// do until something overwrites them), the mel frontend sees real
  /// audio and the cluster classifier returns a non-silence cluster
  /// → the avatar keeps lipsyncing the stale data. Zero the range we
  /// previously wrote so the runtime reads true silence.
  func clearAudioQueue() {
    audioLock.lock()
    audioQueue.removeAll(keepingCapacity: true)
    let wipeEnd = min(audioValidCount, Self.audioBufferTotal)
    if wipeEnd > 0 {
      audioBuf.withUnsafeMutableBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        memset(base, 0, wipeEnd * MemoryLayout<Float>.size)
      }
    }
    audioValidCount = 0
    ticksEmitted = 0
    pendingUtteranceReset = true
    audioLock.unlock()
  }

  func enqueuePCM(_ data: Data) {
    let n = data.count / MemoryLayout<Int16>.size
    var floats = [Float](repeating: 0, count: n)
    data.withUnsafeBytes { raw in
      let int16s = raw.bindMemory(to: Int16.self)
      for i in 0..<n { floats[i] = Float(int16s[i]) / 32768.0 }
    }
    let now = CACurrentMediaTime()
    audioLock.lock()
    // If we've been idle ≥ idleResetSecs, treat this chunk as the start
    // of a fresh utterance: ask the compose loop to reset the runtime
    // (resets the internal compose_cursor) before consuming this audio.
    if audioValidCount > 0,
       lastAudioArrivalTime > 0,
       (now - lastAudioArrivalTime) >= Self.idleResetSecs {
      pendingUtteranceReset = true
    }
    audioQueue.append(contentsOf: floats)
    lastAudioArrivalTime = now
    audioLock.unlock()
  }

  func startRendering() {
    // be_fixture_load on a background DispatchQueue can hang on macOS
    // (ORT's CoreML EP appears to have main-thread affinity for some
    // setup work). Call it synchronously here — we're already inside the
    // MethodChannel handler on the platform thread, so blocking briefly
    // is OK. After the runtime is ready, the 25-fps compose loop runs
    // on renderQueue as before.
    loadFixtureAndRuntime()
    if runtimeHandle != nil {
      renderQueue.async { [weak self] in self?.startTimer() }
    }
  }

  func shutdown() {
    isShutdown = true
    timer?.cancel()
    timer = nil
    renderQueue.async { [weak self] in self?.releaseNativeResources() }
  }

  private let renderQueue = DispatchQueue(label: "ai.bithuman.avatar.render",
                                          qos: .userInteractive)
  private let audioLock = NSLock()
  private let pixelBufferLock = NSLock()

  // Streaming compose model (mirrors AsyncAvatar._run_iter in Python):
  //   - `audioBuf` is a forward-growing accumulator. tick_compose is only
  //     called when at least one full tick + LOOKBACK_TICKS of audio is
  //     buffered AHEAD of the cursor. Otherwise we skip the timer fire
  //     (texture keeps its last frame, avatar appears idle).
  //   - The runtime's INTERNAL compose_cursor advances by `samplesPerTick`
  //     on every call. We track `ticksEmitted` to stay aligned with it.
  //   - On a "new utterance" (≥ 1.0 s of silence followed by fresh audio)
  //     we destroy + recreate the runtime so the cursor resets to 0.
  // 60 s @ 16 kHz = 3.84 MB. Once full we recycle from idx 0 (next
  // utterance reset will happen long before 60 s of continuous audio).
  private static let audioBufferTotal = 16_000 * 60
  private static let samplesPerTick = 640           // 25 fps @ 16 kHz
  private static let lookbackTicks = 3              // mel STFT lookahead
  private static let idleResetSecs: Double = 1.0    // gap → new utterance
  private var audioBuf = [Float](repeating: 0, count: audioBufferTotal)
  private var audioValidCount: Int = 0              // samples filled from idx 0
  private var ticksEmitted: Int = 0                 // matches runtime cursor / spt
  private var audioQueue: [Float] = []              // pending pushAudio samples
  private var lastAudioArrivalTime: CFTimeInterval = 0
  private var pendingUtteranceReset = false
  private var latestPixelBuffer: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  private var isShutdown = false

  private var fixtureHandle: OpaquePointer? = nil
  private var runtimeHandle: OpaquePointer? = nil
  private var tickCount = 0
  private var loggedTickError = false
  // Minimum PCM samples to keep `cached_n_ticks` >= ticksEmitted+1 in
  //
  // libessence's audio frontend. The mel STFT needs T >= 16 mel frames
  // for tick 0, plus ~3.2 mel frames per additional tick (mel_idx_mul).
  // Empirically (ticksEmitted+5)·640 gives a safe lookhead — works for
  // the initial tick (3200 samples) and grows from there.
  private static let minPcmHeadroomTicks = 5

  private var bgrBuffer = [UInt8](repeating: 0, count: 1920 * 1080 * 3)
  private var frameW: Int = 0
  private var frameH: Int = 0
  private var pixelBufferPool: CVPixelBufferPool? = nil

  private func loadFixtureAndRuntime() {
    NSLog("[BithumanAvatar] load begin path=%@", imxPath)
    var fopts = be_fixture_options_t()
    fopts.abi_version      = UInt32(BE_ABI_VERSION)
    fopts.preferred_ep     = BE_EP_CPU
    fopts.intra_op_threads = 4
    var fx: OpaquePointer? = nil
    let loadStatus: be_status = imxPath.withCString { cPath in
      withUnsafePointer(to: &fopts) { opts in
        be_fixture_load(cPath, opts, &fx)
      }
    }
    guard loadStatus == BE_OK, let fixture = fx else {
      let msg = String(cString: be_last_error_message())
      NSLog("[BithumanAvatar] FAIL be_fixture_load status=%d msg=%@",
            loadStatus.rawValue, msg)
      return
    }
    fixtureHandle = fixture

    var ropts = be_runtime_options_t()
    ropts.abi_version = UInt32(BE_ABI_VERSION)
    var rt: OpaquePointer? = nil
    let createStatus: be_status = withUnsafePointer(to: &ropts) { opts in
      be_runtime_create(fixture, opts, &rt)
    }
    guard createStatus == BE_OK, let runtime = rt else {
      let msg = String(cString: be_last_error_message())
      NSLog("[BithumanAvatar] FAIL be_runtime_create status=%d msg=%@",
            createStatus.rawValue, msg)
      be_fixture_release(fixture)
      fixtureHandle = nil
      return
    }
    runtimeHandle = runtime
    NSLog("[BithumanAvatar] runtime ready")
  }

  private func startTimer() {
    let t = DispatchSource.makeTimerSource(queue: renderQueue)
    t.schedule(deadline: .now() + 0.040, repeating: 0.040, leeway: .milliseconds(2))
    t.setEventHandler { [weak self] in self?.composeTick() }
    timer = t
    t.resume()
    NSLog("[BithumanAvatar] timer started")
  }

  /// Reset the libessence runtime (destroys + recreates against the
  /// same fixture). Use this between idle/active mode transitions OR
  /// when the PCM cursor approaches end-of-buffer during long idle
  /// stretches. Returns the new runtime handle, or nil on failure.
  @discardableResult
  private func resetRuntime() -> OpaquePointer? {
    guard let fx = fixtureHandle, let rt = runtimeHandle else { return nil }
    be_runtime_destroy(rt)
    runtimeHandle = nil
    var ropts = be_runtime_options_t()
    ropts.abi_version = UInt32(BE_ABI_VERSION)
    var newRt: OpaquePointer? = nil
    if withUnsafePointer(to: &ropts, { be_runtime_create(fx, $0, &newRt) }) == BE_OK,
       let r = newRt {
      runtimeHandle = r
      audioValidCount = 0
      ticksEmitted = 0
      return r
    } else {
      NSLog("[BithumanAvatar] runtime reset FAIL: %s", be_last_error_message())
      return nil
    }
  }

  private func composeTick() {
    guard !isShutdown, var runtime = runtimeHandle else { return }
    tickCount += 1
    // Drain pending push_audio bytes into the forward-growing accumulator.
    // If a new utterance was flagged, reset the runtime FIRST so the
    // internal compose_cursor starts back at 0 before this audio lands.
    audioLock.lock()
    let needsReset = pendingUtteranceReset
    pendingUtteranceReset = false
    let pending = audioQueue
    audioQueue.removeAll(keepingCapacity: true)
    audioLock.unlock()

    // Reset the runtime if EITHER:
    //   1. A new utterance was flagged after an idle gap (>= 1 s of
    //      no audio), OR
    //   2. Real audio arrived but we're starting fresh from idle (so
    //      the PCM cursor must align with audioBuf[0..audio_len])
    // The reset zeros audioValidCount + ticksEmitted, so the next
    // append lands at index 0 and the cursor reads it on tick 0.
    if needsReset || (!pending.isEmpty && audioValidCount == 0) {
      if let r = resetRuntime() { runtime = r }
    }

    if !pending.isEmpty {
      for s in pending {
        if audioValidCount >= Self.audioBufferTotal {
          // 60 s buffer full — recycle.
          if let r = resetRuntime() { runtime = r }
        }
        audioBuf[audioValidCount] = s
        audioValidCount += 1
      }
    }

    // Always compose at 25 FPS — even during idle. Matches the Python
    // SDK + Swift wrapper's "looping idle": cluster 0 (silence) picks
    // bases[frame_idx], frame_idx advances per tick, so the source
    // video plays through and the user sees blinks/breathing/head sway
    // continuously.
    //
    // Buffer strategy: pcmLen = max(audioValidCount, padded-for-cursor).
    // - audioValidCount: real audio actually pushed by playSpeakerPCM
    // - padded-for-cursor: silence padding so the mel frontend always
    //   has enough lookhead for the current tick. audioBuf is
    //   zero-initialised past audioValidCount, so the silence "comes
    //   for free" — we just tell tick_compose to read more bytes.
    //
    // When the padded length would exceed the 60 s buffer, reset the
    // runtime so the cursor goes back to 0 and we continue cycling.
    // (~60 s of idle motion, then a one-frame reset that may shift the
    // source-video cycle phase — barely perceptible.)
    let paddedLen = (ticksEmitted + Self.minPcmHeadroomTicks) * Self.samplesPerTick
    if paddedLen >= Self.audioBufferTotal {
      if let r = resetRuntime() { runtime = r }
    }
    let pcmLen = max(audioValidCount, (ticksEmitted + Self.minPcmHeadroomTicks) * Self.samplesPerTick)

    var cr = be_compose_result_t()
    let status: be_status = audioBuf.withUnsafeBufferPointer { pcm in
      bgrBuffer.withUnsafeMutableBufferPointer { out in
        be_runtime_tick_compose(runtime, pcm.baseAddress, pcmLen, -1,
                                out.baseAddress, out.count, &cr)
      }
    }
    if status != BE_OK {
      if !loggedTickError {
        loggedTickError = true
        let msg = String(cString: be_last_error_message())
        NSLog("[BithumanAvatar] tick status=%d msg=%@ pcm=%d ticksEmitted=%d",
              status.rawValue, msg, pcmLen, ticksEmitted)
      }
      // BE_ERR_AUDIO_FORMAT (status=6) means cursor went past the buffer
      // end despite our padding (shouldn't happen with the size check
      // above, but guard anyway). Reset and try again next tick.
      if status == be_status(rawValue: 6) {
        if let r = resetRuntime() { runtime = r }
      }
      return
    }
    loggedTickError = false
    guard cr.bytes_written > 0 else { return }
    ticksEmitted += 1
    if ticksEmitted == 1 || ticksEmitted == 25 || ticksEmitted == 100 {
      NSLog("[BithumanAvatar] composed tick=%d cluster=%d frame=%d pcm=%d",
            ticksEmitted, cr.cluster_idx, cr.frame_idx_used, pcmLen)
    }
    publishBGRToTexture()
  }

  /// Copy bgrBuffer into a CVPixelBuffer (BGRA on the Metal side) and
  /// publish it to the Flutter texture. Reused by both the active
  /// per-tick path and the one-shot static paint at startup.
  private func publishBGRToTexture() {
    if frameW == 0, let fixture = fixtureHandle {
      var info = be_fixture_info_t()
      if be_fixture_get_info(fixture, &info) == BE_OK,
         info.frame_width > 0, info.frame_height > 0 {
        frameW = Int(info.frame_width)
        frameH = Int(info.frame_height)
        createPixelBufferPool(width: frameW, height: frameH)
      }
    }
    let w = frameW, h = frameH
    guard w > 0, h > 0 else { return }
    if pixelBufferPool == nil { createPixelBufferPool(width: w, height: h) }
    guard let pool = pixelBufferPool else { return }
    var pb: CVPixelBuffer?
    let pbStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
    guard pbStatus == kCVReturnSuccess, let pixelBuffer = pb else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let dest = CVPixelBufferGetBaseAddress(pixelBuffer) {
      let destStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
      bgrBuffer.withUnsafeBytes { srcRaw in
        guard let src = srcRaw.baseAddress else { return }
        var srcBuf = vImage_Buffer(
          data: UnsafeMutableRawPointer(mutating: src),
          height: vImagePixelCount(h),
          width: vImagePixelCount(w),
          rowBytes: w * 3)
        var dstBuf = vImage_Buffer(
          data: dest,
          height: vImagePixelCount(h),
          width: vImagePixelCount(w),
          rowBytes: destStride)
        vImageConvert_RGB888toRGBA8888(&srcBuf, nil, 0xFF, &dstBuf, false,
                                       vImage_Flags(kvImageNoFlags))
      }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    pixelBufferLock.lock()
    latestPixelBuffer = pixelBuffer
    pixelBufferLock.unlock()
    registry?.textureFrameAvailable(textureId)
  }

  private func createPixelBufferPool(width: Int, height: Int) {
    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey  as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let poolAttrs: [String: Any] = [
      kCVPixelBufferPoolMinimumBufferCountKey as String: 3
    ]
    var pool: CVPixelBufferPool?
    if CVPixelBufferPoolCreate(kCFAllocatorDefault,
                               poolAttrs as CFDictionary,
                               attrs as CFDictionary,
                               &pool) == kCVReturnSuccess {
      pixelBufferPool = pool
    }
  }

  private func releaseNativeResources() {
    if let rt = runtimeHandle { be_runtime_destroy(rt); runtimeHandle = nil }
    if let fx = fixtureHandle { be_fixture_release(fx);  fixtureHandle = nil }
    pixelBufferLock.lock()
    latestPixelBuffer = nil
    pixelBufferLock.unlock()
    pixelBufferPool = nil
  }
}
