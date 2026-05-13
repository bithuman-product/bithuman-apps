// bithuman_avatar iOS plugin.
//
// v0 STATUS: scaffolding only — load/pushAudio/dispose are routed via
// MethodChannel and a FlutterTexture is allocated, but the real
// libessence.xcframework binding + per-tick compose timer is TODO.
// The example app can run end-to-end (catalog browser, tap-to-pick,
// download .imx) but the rendered Texture stays empty until the real
// binding lands. See ARCHITECTURE.md → "v0.1".
//
// Apache-2.0; (c) bitHuman.

import Flutter
import UIKit

public class BithumanAvatarPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  private var textures: [Int64: AvatarTexture] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ai.bithuman.avatar", binaryMessenger: registrar.messenger())
    let instance = BithumanAvatarPlugin()
    instance.registrar = registrar
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "load":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS",
                            message: "load requires path",
                            details: nil))
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
        registrar?.textures().unregisterTexture(textureId)
        tex.shutdown()
      }
      result(nil)

    case "engineVersion":
      // TODO: when the libessence binding lands, return
      //   "libessence \(BithumanEssence.version) (stub)" → "(real)".
      result("v0-stub")

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// One avatar's pixel buffer source. Conforms to FlutterTexture so the
/// Dart side can render with `Texture(textureId: ...)`.
///
/// v0: the BGR→BGRA + libessence binding is stubbed. The texture stays
/// a single placeholder pixel buffer until v0.1.
final class AvatarTexture: NSObject, FlutterTexture {
  let imxPath: String
  var textureId: Int64 = 0
  weak var registry: FlutterTextureRegistry?

  init(imxPath: String) {
    self.imxPath = imxPath
    super.init()
  }

  func enqueuePCM(_ data: Data) {
    // TODO(v0.1): push PCM through libessence at 25 fps and call
    // registry?.textureFrameAvailable(textureId) per produced frame.
    _ = data
  }

  func shutdown() {
    // TODO(v0.1): release the be_runtime + be_fixture.
  }

  // FlutterTexture protocol — return a CVPixelBuffer with the latest
  // composed frame. v0 returns nil → Flutter Texture stays empty.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    return nil
  }
}
