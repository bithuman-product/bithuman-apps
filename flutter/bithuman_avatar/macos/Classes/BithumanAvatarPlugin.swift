// bithuman_avatar macOS plugin — same logic as iOS plugin, just the
// FlutterMacOS framework name differs. v0 is a scaffolding stub; see
// the iOS plugin (ios/Classes/BithumanAvatarPlugin.swift) for the
// shared TODO list.
//
// Apache-2.0; (c) bitHuman.

import Cocoa
import FlutterMacOS

public class BithumanAvatarPlugin: NSObject, FlutterPlugin {
  private weak var registrar: FlutterPluginRegistrar?
  private var textures: [Int64: AvatarTexture] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "ai.bithuman.avatar", binaryMessenger: registrar.messenger)
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
      let texture = AvatarTexture(imxPath: path)
      let textureId = registrar?.textures.register(texture) ?? -1
      texture.textureId = textureId
      texture.registry = registrar?.textures
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
        registrar?.textures.unregisterTexture(textureId)
        tex.shutdown()
      }
      result(nil)

    case "engineVersion":
      result("v0-stub")

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

  func enqueuePCM(_ data: Data) {
    _ = data
  }

  func shutdown() {}

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    return nil
  }
}
