// bithuman_avatar Android plugin.
//
// v0 STATUS: scaffolding only. load/pushAudio/dispose are routed via
// MethodChannel and a SurfaceTextureEntry is allocated, but the
// ai.bithuman:sdk:1.13.0 AAR binding + per-tick compose drive is TODO.
// See ARCHITECTURE.md → "v0.3".
//
// Apache-2.0; (c) bitHuman.

package ai.bithuman.bithuman_avatar

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

class BithumanAvatarPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var textures: TextureRegistry
    private val entries = mutableMapOf<Long, TextureRegistry.SurfaceTextureEntry>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "ai.bithuman.avatar")
        textures = binding.textureRegistry
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "load" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("BAD_ARGS", "load requires path", null)
                    return
                }
                val entry = textures.createSurfaceTexture()
                entries[entry.id()] = entry
                // TODO(v0.3): open the .imx via ai.bithuman.sdk.Fixture +
                // Runtime, start a 25fps compose loop that pushes BGR frames
                // into `entry.surfaceTexture()`.
                result.success(entry.id())
            }
            "pushAudio" -> {
                // TODO(v0.3): enqueue pcm into the audio queue feeding tick_compose.
                result.success(null)
            }
            "dispose" -> {
                val textureId = call.argument<Long>("textureId")
                if (textureId == null) {
                    result.error("BAD_ARGS", "dispose requires textureId", null)
                    return
                }
                entries.remove(textureId)?.release()
                result.success(null)
            }
            "engineVersion" -> result.success("v0-stub")
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        for ((_, e) in entries) e.release()
        entries.clear()
    }
}
