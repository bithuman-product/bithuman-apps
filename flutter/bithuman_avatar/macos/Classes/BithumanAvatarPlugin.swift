// bithuman_avatar — macOS native plugin (v0.4).
//
// Mirrors the iOS plugin (ios/Classes/BithumanAvatarPlugin.swift) with
// the FlutterMacOS framework + Cocoa types + the macOS slice of
// libessence. The Homebrew-installed onnxruntime/ffmpeg/hdf5/jpeg-turbo/
// webp dylibs provide the C++ deps at runtime (matching how the
// `brew install bithuman` CLI works).
//
// Apache-2.0; (c) bitHuman.

import Cocoa
import FlutterMacOS
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
      binaryMessenger: registrar.messenger)
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
      guard let textureRegistry = registrar?.textures else {
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
        registrar?.textures.unregisterTexture(textureId)
      }
      audioIOs[textureId]?.stop()
      audioIOs.removeValue(forKey: textureId)
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
        if let messenger = registrar?.messenger {
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

  /// Drop everything queued for lipsync and tell the compose loop to
  /// reset the runtime's stream on its next fire. Used by the barge-in
  /// path so the avatar stops animating the cancelled response.
  func clearAudioQueue() {
    audioLock.lock()
    audioQueue.removeAll(keepingCapacity: true)
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
    if lastAudioArrivalTime > 0,
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

  // Streaming compose model (ABI 6 / libessence v1.16). See iOS plugin
  // for the per-tick contract — this file is the structurally-identical
  // macOS counterpart.
  private static let samplesPerTick = 640
  private static let idleResetSecs: Double = 1.0
  private static let maxComposesPerTick: Int = 5
  private var audioQueue: [Float] = []
  private var lastAudioArrivalTime: CFTimeInterval = 0
  private var pendingUtteranceReset = false
  private var latestPixelBuffer: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  private var isShutdown = false

  private var fixtureHandle: OpaquePointer? = nil
  private var runtimeHandle: OpaquePointer? = nil
  private var ticksEmitted: Int = 0
  private var tickCount = 0
  private var loggedTickError = false
  private let silenceTick = [Float](repeating: 0, count: 640)

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

  /// Reset the runtime's streaming state (mel buffer + cursor + STFT
  /// overlap). Cheap (no model unload).
  private func resetStream() {
    guard let rt = runtimeHandle else { return }
    be_runtime_reset_stream(rt)
    ticksEmitted = 0
  }

  private func composeTick() {
    guard !isShutdown, let runtime = runtimeHandle else { return }
    tickCount += 1

    // Audio pacing: pop EXACTLY one tick worth of audio per render tick
    // (or zero-fill the gap with silence). The speaker drain rate is 1×
    // real-time and our render rate is 25 fps, so consuming 640 samples
    // per render keeps video frame production locked to audio playback —
    // independent of how bursty the upstream enqueuePCM() arrivals are.
    // Leftover audio stays in audioQueue for subsequent ticks.
    audioLock.lock()
    let needsReset = pendingUtteranceReset
    pendingUtteranceReset = false
    let n = Self.samplesPerTick
    let take = min(n, audioQueue.count)
    var pending = Array(audioQueue.prefix(take))
    if take > 0 { audioQueue.removeFirst(take) }
    audioLock.unlock()

    if needsReset { resetStream() }

    // Pad to exactly one tick with trailing zeros if upstream is short.
    if pending.count < n {
      pending.append(contentsOf: repeatElement(0, count: n - pending.count))
    }
    let status: be_status = pending.withUnsafeBufferPointer { buf in
      be_runtime_push_audio(runtime, buf.baseAddress, buf.count)
    }
    if status != BE_OK {
      let msg = String(cString: be_last_error_message())
      NSLog("[BithumanAvatar] push_audio status=%d msg=%@", status.rawValue, msg)
      resetStream()
      return
    }

    // Pull at most ONE frame per render tick — matches the audio drain
    // rate. ticksAvailable will sit near 1 in steady state; if upstream
    // buffers ahead, the surplus is absorbed by the runtime's mel buffer
    // (cheap) and consumed at 25 fps wall clock.
    let available = Int(be_runtime_ticks_available(runtime))
    let composeCount = min(available, 1)
    var lastResult = be_compose_result_t()
    for _ in 0..<composeCount {
      var cr = be_compose_result_t()
      let status: be_status = bgrBuffer.withUnsafeMutableBufferPointer { out in
        be_runtime_pull_frame(runtime, -1, out.baseAddress, out.count, &cr)
      }
      if status != BE_OK {
        if !loggedTickError {
          loggedTickError = true
          let msg = String(cString: be_last_error_message())
          NSLog("[BithumanAvatar] pull_frame status=%d msg=%@ available=%d",
                status.rawValue, msg, available)
        }
        resetStream()
        return
      }
      lastResult = cr
      ticksEmitted += 1
    }
    if composeCount == 0 { return }
    loggedTickError = false
    if ticksEmitted == 1 || ticksEmitted % 100 == 0 {
      NSLog("[BithumanAvatar] composed t=%d cluster=%d frame=%d composeCount=%d available=%d",
            ticksEmitted, lastResult.cluster_idx, lastResult.frame_idx_used,
            composeCount, available)
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
