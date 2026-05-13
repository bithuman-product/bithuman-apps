// bithuman_avatar — iOS native plugin (v0.1).
//
// Drives the libessence v1 compose pipeline (be_fixture_load →
// be_runtime_create → be_runtime_tick_compose at 25 fps) and feeds
// each BGR frame into a CVPixelBuffer that Flutter renders via the
// Texture widget.
//
// Public-catalog .imx models from bithuman.ai/api/agents don't require
// per-call billing — setting BITHUMAN_UNMETERED=1 at runtime bypasses
// the credit-check heartbeat so the example app works without an API
// secret. Production builds doing metered usage need a separate
// auth path (v0.4 scope).
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

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Dev-mode auth bypass — public bithuman.ai catalog .imx files don't
    // need metering credits, but the engine's auth gate fires without
    // this. Override here so the sample app runs anonymously.
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
      guard let registry = registrar?.textures() else {
        result(FlutterError(code: "NO_REGISTRY",
                            message: "no FlutterTextureRegistry available",
                            details: nil))
        return
      }
      let texture = AvatarTexture(imxPath: path)
      let textureId = registry.register(texture)
      texture.textureId = textureId
      texture.registry = registry
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
      result(nil)

    case "engineVersion":
      let ver = String(cString: be_library_version())
      let abi = be_abi_version()
      result("\(ver) (ABI \(abi))")

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// One live avatar instance. Owns a libessence fixture + runtime + a
/// CVPixelBuffer pool, drives a 25 fps compose timer, and exposes the
/// latest composed frame to Flutter via the FlutterTexture protocol.
final class AvatarTexture: NSObject, FlutterTexture {

  let imxPath: String
  var textureId: Int64 = 0
  weak var registry: FlutterTextureRegistry?

  init(imxPath: String) {
    self.imxPath = imxPath
    super.init()
  }

  // ----- FlutterTexture --------------------------------------------------

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelBufferLock.lock()
    let buf = latestPixelBuffer
    pixelBufferLock.unlock()
    guard let pb = buf else { return nil }
    return Unmanaged.passRetained(pb)
  }

  // ----- audio + lifecycle ----------------------------------------------

  /// Enqueue int16 PCM @ 16 kHz mono. Caller resamples if their source
  /// is 24 kHz (OpenAI Realtime) — the Dart-side BithumanRealtimeSession
  /// handles that.
  func enqueuePCM(_ data: Data) {
    let n = data.count / MemoryLayout<Int16>.size
    var floats = [Float](repeating: 0, count: n)
    data.withUnsafeBytes { raw in
      let int16s = raw.bindMemory(to: Int16.self)
      for i in 0..<n {
        floats[i] = Float(int16s[i]) / 32768.0
      }
    }
    audioLock.lock()
    audioQueue.append(contentsOf: floats)
    audioLock.unlock()
  }

  func startRendering() {
    // be_fixture_load needs to run on the platform thread (background
    // DispatchQueue causes a hang on macOS — ORT EP setup has main-thread
    // affinity; iOS appears tolerant but we keep the path consistent).
    loadFixtureAndRuntime()
    if runtimeHandle != nil {
      renderQueue.async { [weak self] in self?.startTimer() }
    }
  }

  func shutdown() {
    NSLog("[BithumanAvatar] shutdown id=%lld", textureId)
    isShutdown = true
    timer?.cancel()
    timer = nil
    renderQueue.async { [weak self] in self?.releaseNativeResources() }
  }

  // ----- internals -------------------------------------------------------

  private let renderQueue = DispatchQueue(label: "ai.bithuman.avatar.render",
                                          qos: .userInteractive)
  private let audioLock = NSLock()
  private let pixelBufferLock = NSLock()

  // The libessence runtime expects the FULL accumulated audio buffer on
  // every tick — its internal compose_cursor advances by one tick per
  // call. Preallocate 60 s @ 16 kHz; grow valid-region as ticks fire.
  private static let audioBufferTotal = 16_000 * 60
  private var audioBuf = [Float](repeating: 0, count: audioBufferTotal)
  private var audioValidCount: Int = 0
  private var audioWriteIdx: Int = 0
  private var audioQueue: [Float] = []   // pending pushAudio samples
  private var latestPixelBuffer: CVPixelBuffer?
  private var timer: DispatchSourceTimer?
  private var isShutdown = false

  private var fixtureHandle: OpaquePointer? = nil
  private var runtimeHandle: OpaquePointer? = nil
  private var loggedTickError = false

  // Lazy v1 init: frame dims are 0 until the first compose. Pre-allocate
  // at 1920x1080x3 ceiling so the first call always has space.
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
  }

  private func composeTick() {
    guard !isShutdown, let runtime = runtimeHandle else { return }

    audioLock.lock()
    if !audioQueue.isEmpty {
      for s in audioQueue {
        audioBuf[audioWriteIdx] = s
        audioWriteIdx = (audioWriteIdx + 1) % Self.audioBufferTotal
      }
      audioQueue.removeAll(keepingCapacity: true)
    }
    audioLock.unlock()
    // Pass the ENTIRE pre-allocated buffer every tick (matches
    // test_v1_bench.cpp's tick_compose pattern). Internal compose_cursor
    // advances one tick per call. Partial buffer makes trailing-tick mel
    // features fall back to zero-pad lookhead, which picks a wrong
    // cluster_idx and composites a visibly misaligned lip patch.
    var cr = be_compose_result_t()
    let status: be_status = audioBuf.withUnsafeBufferPointer { pcm in
      bgrBuffer.withUnsafeMutableBufferPointer { out in
        be_runtime_tick_compose(runtime, pcm.baseAddress, Self.audioBufferTotal, -1,
                                out.baseAddress, out.count, &cr)
      }
    }
    guard status == BE_OK else {
      // Boundary at end-of-audio is normal once we hand the engine a
      // finite stream — silence pads keep us inside cached_n_ticks.
      // Log other errors only — and log only once per shutdown cycle
      // to avoid 25 lines/sec of noise.
      let code = status.rawValue
      if code != BE_ERR_AUDIO_FORMAT.rawValue {
        if !loggedTickError {
          loggedTickError = true
          let msg = String(cString: be_last_error_message())
          NSLog("[BithumanAvatar] tick status=%d msg=%@", code, msg)
        }
      }
      return
    }
    loggedTickError = false
    guard cr.bytes_written > 0 else { return }

    if frameW == 0, let fixture = fixtureHandle {
      var info = be_fixture_info_t()
      if be_fixture_get_info(fixture, &info) == BE_OK,
         info.frame_width > 0, info.frame_height > 0 {
        frameW = Int(info.frame_width)
        frameH = Int(info.frame_height)
        NSLog("[BithumanAvatar] frame=%dx%d", frameW, frameH)
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
        // The source is BGR. kCVPixelFormatType_32BGRA stores B,G,R,A
        // per pixel. vImageConvert_RGB888toRGBA8888 packs the 3 source
        // bytes verbatim + appends the alpha constant — exactly what
        // we want for BGR→BGRA without any channel swap.
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
      NSLog("[BithumanAvatar] pool created %dx%d", width, height)
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
