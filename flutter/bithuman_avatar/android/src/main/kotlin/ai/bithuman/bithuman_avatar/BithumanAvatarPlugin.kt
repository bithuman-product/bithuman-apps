// bithuman_avatar Android plugin — v0.3.
//
// Drives ai.bithuman:sdk:1.13.0 (Maven Central) via Fixture + Runtime
// directly. Renders at 25 fps via ScheduledExecutorService + Bitmap+Canvas
// path. Auth bypass: BITHUMAN_UNMETERED=1 (set via setenv at attach time)
// keeps the heartbeat off for the public-catalog .imx models.
//
// Apache-2.0; (c) bitHuman.

package ai.bithuman.bithuman_avatar

import ai.bithuman.sdk.ExecutionProvider
import ai.bithuman.sdk.Fixture
import ai.bithuman.sdk.Runtime
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

private const val TAG = "BithumanAvatar"
private const val FRAME_INTERVAL_MS = 40L           // 25 fps
private const val SAMPLES_PER_TICK = 640            // 40 ms @ 16 kHz
private const val MAX_FRAME_W = 1920
private const val MAX_FRAME_H = 1080
private const val MAX_QUEUE_CHUNKS = 200             // ~5 s of audio at 16 kHz

class BithumanAvatarPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private val executor: ScheduledExecutorService = Executors.newScheduledThreadPool(8)
    private val avatars = HashMap<Long, AvatarEntry>()
    private val avatarsLock = Any()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Public-catalog .imx files don't need metering, but the engine's
        // auth gate fires without this. Bypass at process scope.
        // android.system.Os.setenv is the only way to set a real POSIX env
        // var on Android — System.setProperty / ProcessBuilder.environment
        // only affect the JVM, not the C library's getenv().
        try {
            android.system.Os.setenv("BITHUMAN_UNMETERED", "1", true)
        } catch (e: Throwable) {
            Log.w(TAG, "Os.setenv BITHUMAN_UNMETERED failed: ${e.message}")
        }

        channel = MethodChannel(binding.binaryMessenger, "ai.bithuman.avatar")
        textureRegistry = binding.textureRegistry
        channel.setMethodCallHandler(this)
        Log.i(TAG, "onAttachedToEngine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val all: List<AvatarEntry>
        synchronized(avatarsLock) {
            all = avatars.values.toList()
            avatars.clear()
        }
        all.forEach { it.dispose() }
        Log.i(TAG, "onDetachedFromEngine — disposed ${all.size} avatar(s)")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "load"          -> handleLoad(call, result)
            "pushAudio"     -> handlePushAudio(call, result)
            "dispose"       -> handleDispose(call, result)
            "engineVersion" -> handleEngineVersion(result)
            else            -> result.notImplemented()
        }
    }

    private fun handleLoad(call: MethodCall, result: Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("BAD_ARGS", "load requires path", null)
            return
        }
        // textureRegistry.createSurfaceTexture() instantiates a Handler
        // and MUST run on the main looper. Allocate the entry here
        // (already on main thread because MethodCallHandler is invoked
        // there), then off-load the slow Fixture/Runtime construction.
        val entry = textureRegistry.createSurfaceTexture()
        val surface = Surface(entry.surfaceTexture())
        executor.submit {
            try {
                Log.i(TAG, "load start: $path")
                val fixture = Fixture(path, ExecutionProvider.CPU, intraOpThreads = 1)
                val runtime = Runtime(fixture)

                val bgrBuf = ByteArray(MAX_FRAME_W * MAX_FRAME_H * 3)
                val audioQueue = ConcurrentLinkedDeque<FloatArray>()
                val stopped = AtomicBoolean(false)
                // libessence runtime expects the FULL accumulated audio
                // buffer on every tickCompose — its internal cursor advances
                // one tick per call. Preallocate 60 s @ 16 kHz; grow valid
                // region as ticks fire / pushAudio appends.
                val audioBufTotal = 16_000 * 60
                val audioBuf = FloatArray(audioBufTotal)
                var audioValidCount = 0
                var audioWriteIdx = 0

                // bitmap + argb scratch are sized after first tickCompose.
                var bitmap: Bitmap? = null
                var argbInts: IntArray? = null
                var frameW = 0
                var frameH = 0

                val loopFuture: ScheduledFuture<*> = executor.scheduleAtFixedRate(
                    {
                        if (stopped.get()) return@scheduleAtFixedRate
                        try {
                            // Drain pushAudio queue into the rolling buffer.
                            while (true) {
                                val chunk = audioQueue.pollFirst() ?: break
                                for (s in chunk) {
                                    audioBuf[audioWriteIdx] = s
                                    audioWriteIdx = (audioWriteIdx + 1) % audioBufTotal
                                }
                            }
                            // Pass the ENTIRE pre-allocated buffer every tick.
                            // The engine's compose_cursor advances one tick per
                            // call; passing a partial range makes trailing-tick
                            // mel features use zero-pad lookhead, picking a wrong
                            // cluster_idx (visible as a misaligned lip patch).
                            runtime.tickCompose(audioBuf, /* frameIdxHint */ -1, /* frameOut */ bgrBuf)

                            if (frameW == 0) {
                                val info = fixture.info
                                frameW = info.frameWidth.takeIf { it > 0 } ?: MAX_FRAME_W
                                frameH = info.frameHeight.takeIf { it > 0 } ?: MAX_FRAME_H
                                Log.i(TAG, "first tick: frame=${frameW}x${frameH}")
                                entry.surfaceTexture().setDefaultBufferSize(frameW, frameH)
                            }
                            if (bitmap == null ||
                                bitmap!!.width != frameW || bitmap!!.height != frameH) {
                                bitmap?.recycle()
                                bitmap = Bitmap.createBitmap(frameW, frameH, Bitmap.Config.ARGB_8888)
                                argbInts = IntArray(frameW * frameH)
                            }
                            bgrToArgb(bgrBuf, frameW, frameH, argbInts!!, bitmap!!)

                            val canvas: Canvas
                            try {
                                canvas = surface.lockCanvas(null)
                            } catch (e: Exception) {
                                if (!stopped.get()) Log.w(TAG, "lockCanvas: ${e.message}")
                                return@scheduleAtFixedRate
                            }
                            try {
                                canvas.drawBitmap(bitmap!!, 0f, 0f, null)
                            } finally {
                                surface.unlockCanvasAndPost(canvas)
                            }
                        } catch (e: ai.bithuman.sdk.BithumanException) {
                            // Audio cursor exhaustion is normal — silence loops wrap.
                            Log.v(TAG, "tickCompose: ${e.message}")
                        } catch (e: Throwable) {
                            if (!stopped.get()) Log.e(TAG, "render loop error", e)
                        }
                    },
                    0L, FRAME_INTERVAL_MS, TimeUnit.MILLISECONDS
                )

                val avatarEntry = AvatarEntry(
                    fixture = fixture,
                    runtime = runtime,
                    surfaceEntry = entry,
                    surface = surface,
                    audioQueue = audioQueue,
                    stopped = stopped,
                    loopFuture = loopFuture,
                )
                synchronized(avatarsLock) {
                    avatars[entry.id()] = avatarEntry
                }
                Log.i(TAG, "load OK textureId=${entry.id()}")
                result.success(entry.id())
            } catch (e: Throwable) {
                Log.e(TAG, "load failed", e)
                result.error("LOAD_FAILED", e.message ?: "unknown error", null)
            }
        }
    }

    private fun handlePushAudio(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        val pcmBytes = call.argument<ByteArray>("pcm")
        if (textureId == null || pcmBytes == null) {
            result.error("BAD_ARGS", "pushAudio requires textureId and pcm", null)
            return
        }
        val entry = synchronized(avatarsLock) { avatars[textureId] }
        if (entry == null) {
            result.error("NOT_FOUND", "no avatar for textureId=$textureId", null)
            return
        }
        val bb = ByteBuffer.wrap(pcmBytes).order(ByteOrder.LITTLE_ENDIAN)
        val sb = bb.asShortBuffer()
        val nSamples = sb.remaining()
        val floats = FloatArray(nSamples)
        for (i in 0 until nSamples) {
            floats[i] = sb.get().toFloat() / 32768f
        }
        var off = 0
        while (off + SAMPLES_PER_TICK <= floats.size &&
               entry.audioQueue.size < MAX_QUEUE_CHUNKS) {
            entry.audioQueue.addLast(floats.copyOfRange(off, off + SAMPLES_PER_TICK))
            off += SAMPLES_PER_TICK
        }
        result.success(null)
    }

    private fun handleDispose(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        if (textureId == null) {
            result.error("BAD_ARGS", "dispose requires textureId", null)
            return
        }
        val entry = synchronized(avatarsLock) { avatars.remove(textureId) }
        entry?.dispose()
        Log.i(TAG, "dispose textureId=$textureId ${if (entry != null) "OK" else "not found"}")
        result.success(null)
    }

    private fun handleEngineVersion(result: Result) {
        try {
            val ver = "${Fixture.libraryVersion()} (ABI ${Fixture.abiVersion()})"
            result.success(ver)
        } catch (e: Throwable) {
            result.success("unknown (${e.message})")
        }
    }

    private companion object {
        fun bgrToArgb(bgr: ByteArray, w: Int, h: Int, argb: IntArray, bmp: Bitmap) {
            val px = w * h
            var s = 0
            for (i in 0 until px) {
                val b = bgr[s].toInt() and 0xFF
                val g = bgr[s + 1].toInt() and 0xFF
                val r = bgr[s + 2].toInt() and 0xFF
                argb[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                s += 3
            }
            bmp.setPixels(argb, 0, w, 0, 0, w, h)
        }
    }
}

private class AvatarEntry(
    val fixture: Fixture,
    val runtime: Runtime,
    val surfaceEntry: TextureRegistry.SurfaceTextureEntry,
    val surface: Surface,
    val audioQueue: ConcurrentLinkedDeque<FloatArray>,
    val stopped: AtomicBoolean,
    val loopFuture: ScheduledFuture<*>,
) {
    fun dispose() {
        stopped.set(true)
        loopFuture.cancel(false)
        runCatching { surface.release() }
        runCatching { runtime.close() }
        runCatching { fixture.close() }
        runCatching { surfaceEntry.release() }
    }
}
