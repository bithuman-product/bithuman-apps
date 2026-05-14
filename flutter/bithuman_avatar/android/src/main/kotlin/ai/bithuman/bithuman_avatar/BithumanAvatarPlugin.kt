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
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioTrack
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
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
// 40 ms @ 24 kHz int16 mono = 960 samples × 2 bytes = 1920 bytes.
// One compose tick emits exactly this much audio to the speaker at
// the same wall-clock instant the matching frame is rendered, so A/V
// can never drift no matter how bursty the upstream chunk arrival is.
private const val SPEAKER_BYTES_PER_TICK_24K = 1920

class BithumanAvatarPlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var binaryMessenger: BinaryMessenger
    private lateinit var appContext: Context
    private val executor: ScheduledExecutorService = Executors.newScheduledThreadPool(8)
    private val avatars = HashMap<Long, AvatarEntry>()
    private val audioIOs = HashMap<Long, RealtimeAudioIO>()
    // Hold a strong reference to the EventChannel for the lifetime of the
    // audio session. Without this, GC collects the channel and Dart's
    // mic stream silently stops delivering even though the native loop
    // is still firing — mirror of the same trap on the macOS side.
    private val micChannels = HashMap<Long, EventChannel>()
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

        binaryMessenger = binding.binaryMessenger
        channel = MethodChannel(binaryMessenger, "ai.bithuman.avatar")
        textureRegistry = binding.textureRegistry
        appContext = binding.applicationContext
        channel.setMethodCallHandler(this)
        Log.i(TAG, "onAttachedToEngine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val allAvatars: List<AvatarEntry>
        val allIOs: List<RealtimeAudioIO>
        synchronized(avatarsLock) {
            allAvatars = avatars.values.toList()
            allIOs = audioIOs.values.toList()
            avatars.clear()
            audioIOs.clear()
            micChannels.clear()
        }
        allIOs.forEach { runCatching { it.stop() } }
        allAvatars.forEach { it.dispose() }
        Log.i(TAG, "onDetachedFromEngine — disposed ${allAvatars.size} avatar(s) / ${allIOs.size} audio io(s)")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "load"           -> handleLoad(call, result)
            "pushAudio"      -> handlePushAudio(call, result)
            "dispose"        -> handleDispose(call, result)
            "engineVersion"  -> handleEngineVersion(result)
            "audioStart"     -> handleAudioStart(call, result)
            "audioStop"      -> handleAudioStop(call, result)
            "interrupt"      -> handleInterrupt(call, result)
            "playSpeakerPCM" -> handlePlaySpeakerPCM(call, result)
            else             -> result.notImplemented()
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

                // Mirror the macOS streaming compose model (see
                // macos/Classes/BithumanAvatarPlugin.swift composeTick):
                //   - Always tick_compose at 25 fps even during idle.
                //     The runtime sees the 60 s zero-padded buffer as
                //     silence → cluster_idx 0 → bases[frame_idx] cycles
                //     → user sees blink/breathe/head-sway loop.
                //   - When real audio arrives after an idle gap, reset
                //     the runtime so the internal compose_cursor goes
                //     back to 0 before the new utterance lands at idx 0.
                //   - When the cursor approaches end-of-buffer (~60 s of
                //     idle ticks), reset to keep cycling.
                // Pre-allocating audioBuf to the full 60 s means we can
                // pass `audioBuf` directly to tickCompose — the JNI
                // takes the FULL FloatArray length as the audio history
                // length, so a 60 s buffer of mostly zeros = 60 s of
                // silence to the runtime.
                val audioBufTotal = 16_000 * 60
                val audioBuf = FloatArray(audioBufTotal)
                val state = ComposeState()
                val idleResetGapMs = 1000L  // mirrors macOS idleResetSecs = 1.0
                // Wrap the SDK Runtime so we can swap it on reset
                // (Runtime() is immutable; close()+new is the only way
                // to rewind compose_cursor to 0).
                val rtHolder = RuntimeHolder(runtime)

                // bitmap + argb scratch are sized after first tickCompose.
                var bitmap: Bitmap? = null
                var argbInts: IntArray? = null
                var frameW = 0
                var frameH = 0

                fun resetRuntime() {
                    rtHolder.runtime.close()
                    rtHolder.runtime = Runtime(fixture)
                    state.audioValidCount = 0
                    state.ticksEmitted = 0
                    state.pendingUtteranceReset = false
                }

                // Per-tick scratch buffer for the 1920-byte 24 kHz
                // speaker slice popped from AvatarEntry. Reused across
                // ticks; the AudioTrack consumer copies its contents
                // synchronously inside the write call.
                val speakerTickBuf = ByteArray(SPEAKER_BYTES_PER_TICK_24K)

                // Forward reference so the render loop closure can
                // reach the AvatarEntry that's constructed AFTER the
                // ScheduledExecutorService schedules the first tick.
                // Set non-null right after the entry is built; until
                // then the loop's first iteration may see null and
                // skips that tick.
                val avatarEntryHolder = arrayOfNulls<AvatarEntry>(1)

                val loopFuture: ScheduledFuture<*> = executor.scheduleAtFixedRate(
                    {
                        if (stopped.get()) return@scheduleAtFixedRate
                        try {
                            // Drain pending push_audio chunks into the
                            // forward-growing accumulator. If audio arrives
                            // after an idle gap (>= 1 s of no incoming
                            // chunks), flag a runtime reset so the cursor
                            // realigns with audioBuf[0..valid] before the
                            // new utterance is composed.
                            val pending = ArrayList<FloatArray>()
                            while (true) {
                                val c = audioQueue.pollFirst() ?: break
                                pending.add(c)
                            }
                            val nowMs = System.currentTimeMillis()
                            if (pending.isNotEmpty() &&
                                state.audioValidCount > 0 &&
                                state.lastAudioArrivalMs > 0 &&
                                (nowMs - state.lastAudioArrivalMs) >= idleResetGapMs) {
                                state.pendingUtteranceReset = true
                            }
                            if (pending.isNotEmpty()) {
                                state.lastAudioArrivalMs = nowMs
                            }

                            // Reset if either flagged by an idle-gap
                            // detector OR real audio has arrived but the
                            // accumulator was just zeroed (initial paint
                            // wiped it). Mirrors macOS composeTick.
                            if (state.pendingUtteranceReset ||
                                (pending.isNotEmpty() && state.audioValidCount == 0)) {
                                resetRuntime()
                                // resetRuntime() zeros validCount + ticks
                                // + clears the flag.
                                state.pendingUtteranceReset = false
                            }

                            for (c in pending) {
                                for (s in c) {
                                    if (state.audioValidCount >= audioBufTotal) {
                                        // 60 s utterance — recycle. Wipe
                                        // the previous content so old
                                        // audio doesn't bleed into the
                                        // next compose.
                                        java.util.Arrays.fill(audioBuf, 0f)
                                        resetRuntime()
                                    }
                                    audioBuf[state.audioValidCount] = s
                                    state.audioValidCount++
                                }
                            }

                            // ALWAYS compose at 25 fps — silence input
                            // produces idle motion (blinks, breathing,
                            // head sway) because cluster_idx 0 cycles
                            // through bases[frame_idx]. Mirrors macOS.
                            //
                            // The runtime advances its internal compose
                            // cursor by SAMPLES_PER_TICK each call. After
                            // ~1500 ticks of pure idle, cursor approaches
                            // the 60 s buffer end → reset before the
                            // tick to avoid BE_ERR_AUDIO_FORMAT.
                            val cursorAfter = (state.ticksEmitted + 1) * SAMPLES_PER_TICK
                            val padded = cursorAfter + 3 * SAMPLES_PER_TICK
                            if (padded >= audioBufTotal) {
                                resetRuntime()
                            }
                            val tComposeStart = System.nanoTime()
                            try {
                                rtHolder.runtime.tickCompose(audioBuf, -1, bgrBuf)
                                state.ticksEmitted++
                            } catch (e: ai.bithuman.sdk.BithumanException) {
                                if (!state.loggedTickError) {
                                    state.loggedTickError = true
                                    Log.w(TAG, "tick err — resetting: ${e.message}")
                                }
                                resetRuntime()
                                return@scheduleAtFixedRate
                            }
                            state.loggedTickError = false
                            val tComposeEnd = System.nanoTime()

                            // Speaker emission, paired with this tick.
                            // Pop exactly 40 ms of 24 kHz audio from
                            // the AvatarEntry's speaker queue (silence
                            // when the queue is empty) and write to
                            // the attached AudioTrack. Because we run
                            // at exactly 25 fps wall-clock and emit
                            // 1920 bytes per tick, AudioTrack drains
                            // at exactly 1× real-time and never builds
                            // up backpressure — the lipsync frame
                            // rendered above and these bytes leave the
                            // speaker at the same moment, so A/V are
                            // bound chunk-by-chunk and cannot drift.
                            val avatarEntryRef = avatarEntryHolder[0]
                            val realBytes = avatarEntryRef?.popNextTickSpeaker24k(speakerTickBuf) ?: 0
                            avatarEntryRef?.attachedSpeakerTrack?.let { tr ->
                                try {
                                    // WRITE_NON_BLOCKING — the compose
                                    // loop's 40 ms scheduleAtFixedRate
                                    // is the pacing source. WRITE_BLOCKING
                                    // would stall the loop for an extra
                                    // ~40 ms per tick (buffer-drain wait),
                                    // halving effective fps and making
                                    // audio play at ~0.5× speed. The
                                    // AudioTrack ring is pre-filled at
                                    // startup with silence so the
                                    // consumer has cushion against the
                                    // compose loop's scheduling jitter.
                                    tr.write(speakerTickBuf, 0, speakerTickBuf.size,
                                             AudioTrack.WRITE_NON_BLOCKING)
                                } catch (e: Throwable) {
                                    if (state.ticksEmitted % 50 == 0) {
                                        Log.w(TAG, "speaker write: ${e.message}")
                                    }
                                }
                            }
                            // Reset cursor + audioBuf when the agent
                            // has been silent (no real bytes) for a
                            // while AND we previously emitted real
                            // audio. Keeps the runtime cursor from
                            // drifting too far past the audioBuf end
                            // during long idle stretches between
                            // utterances. (audioBuf is the lipsync
                            // history — distinct from the speaker
                            // 24k queue.)
                            if (realBytes == 0 && state.audioValidCount > 0) {
                                state.idleSilentTicks++
                                if (state.idleSilentTicks > 25) {
                                    // 1 s of silence post-utterance
                                    resetRuntime()
                                    state.idleSilentTicks = 0
                                }
                            } else if (realBytes > 0) {
                                state.idleSilentTicks = 0
                            }

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
                            val tConvStart = System.nanoTime()
                            bgrToArgb(bgrBuf, frameW, frameH, argbInts!!, bitmap!!)
                            val tConvEnd = System.nanoTime()

                            val canvas: Canvas
                            try {
                                canvas = surface.lockCanvas(null)
                            } catch (e: Exception) {
                                if (!stopped.get()) Log.w(TAG, "lockCanvas: ${e.message}")
                                return@scheduleAtFixedRate
                            }
                            val tLockEnd = System.nanoTime()
                            try {
                                canvas.drawBitmap(bitmap!!, 0f, 0f, null)
                            } finally {
                                surface.unlockCanvasAndPost(canvas)
                            }
                            val tDrawEnd = System.nanoTime()
                            // Log perf every ~1 s so we can see if any
                            // stage drifts past ~10 ms (which would
                            // squeeze the 40 ms tick budget).
                            if (state.ticksEmitted % 25 == 0) {
                                val composeMs = (tComposeEnd - tComposeStart) / 1_000_000.0
                                val convMs = (tConvEnd - tConvStart) / 1_000_000.0
                                val lockMs = (tLockEnd - tConvEnd) / 1_000_000.0
                                val drawMs = (tDrawEnd - tLockEnd) / 1_000_000.0
                                Log.i(TAG, "perf t=${state.ticksEmitted} " +
                                    "compose=${"%.1f".format(composeMs)}ms " +
                                    "bgr→argb=${"%.1f".format(convMs)}ms " +
                                    "lockCanvas=${"%.1f".format(lockMs)}ms " +
                                    "drawBitmap+post=${"%.1f".format(drawMs)}ms " +
                                    "audio=${state.audioValidCount}")
                            }
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
                avatarEntryHolder[0] = avatarEntry
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
        val (entry, io) = synchronized(avatarsLock) {
            val e = avatars.remove(textureId)
            val a = audioIOs.remove(textureId)
            micChannels.remove(textureId)
            e to a
        }
        runCatching { io?.stop() }
        entry?.dispose()
        Log.i(TAG, "dispose textureId=$textureId ${if (entry != null) "OK" else "not found"}")
        result.success(null)
    }

    private fun handleAudioStart(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        if (textureId == null) {
            result.error("BAD_ARGS", "audioStart requires textureId", null)
            return
        }
        val entry = synchronized(avatarsLock) { avatars[textureId] }
        if (entry == null) {
            result.error("NOT_FOUND", "no avatar for textureId=$textureId", null)
            return
        }
        try {
            val io = synchronized(avatarsLock) {
                audioIOs[textureId] ?: run {
                    val newIO = RealtimeAudioIO(entry, appContext)
                    audioIOs[textureId] = newIO
                    val ch = EventChannel(binaryMessenger, "ai.bithuman.avatar.mic/$textureId")
                    ch.setStreamHandler(newIO)
                    // RETAIN the channel — without this, GC frees it and the
                    // mic stream silently never delivers chunks to Dart
                    // even though the native loop is firing.
                    micChannels[textureId] = ch
                    newIO
                }
            }
            io.start()
            result.success(null)
        } catch (e: Throwable) {
            Log.e(TAG, "audioStart failed", e)
            result.error("AUDIO_START_FAILED", e.message ?: "unknown", null)
        }
    }

    private fun handleAudioStop(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        if (textureId == null) {
            result.error("BAD_ARGS", "audioStop requires textureId", null)
            return
        }
        val io = synchronized(avatarsLock) {
            val removed = audioIOs.remove(textureId)
            micChannels.remove(textureId)
            removed
        }
        runCatching { io?.stop() }
        result.success(null)
    }

    private fun handleInterrupt(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        if (textureId == null) {
            result.error("BAD_ARGS", "interrupt requires textureId", null)
            return
        }
        val io = synchronized(avatarsLock) { audioIOs[textureId] }
        runCatching { io?.barge() }
        result.success(null)
    }

    private fun handlePlaySpeakerPCM(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        val pcm = call.argument<ByteArray>("pcm")
        if (textureId == null || pcm == null) {
            result.error("BAD_ARGS", "playSpeakerPCM requires textureId + pcm", null)
            return
        }
        val io = synchronized(avatarsLock) { audioIOs[textureId] }
        if (io == null) {
            result.error("NOT_FOUND", "no audio io for textureId=$textureId (call audioStart first)", null)
            return
        }
        try {
            io.playSpeakerPCM24k(pcm)
            result.success(null)
        } catch (e: Throwable) {
            Log.w(TAG, "playSpeakerPCM: ${e.message}")
            result.error("SPEAKER_FAILED", e.message ?: "unknown", null)
        }
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

internal class AvatarEntry(
    val fixture: Fixture,
    val runtime: Runtime,
    val surfaceEntry: TextureRegistry.SurfaceTextureEntry,
    val surface: Surface,
    val audioQueue: ConcurrentLinkedDeque<FloatArray>,
    val stopped: AtomicBoolean,
    val loopFuture: ScheduledFuture<*>,
) {
    /// Speaker AudioTrack reference attached by RealtimeAudioIO at
    /// session start, cleared at stop. The compose loop writes 40 ms
    /// of 24 kHz audio per tick to this track in lockstep with the
    /// matching video frame — that pairing is what keeps A/V from
    /// drifting (the OpenAI Realtime model bursts audio at up to ~7×
    /// real-time, and a separate writer thread would let the lipsync
    /// render race ahead of the speaker output).
    @Volatile var attachedSpeakerTrack: AudioTrack? = null

    /// 24 kHz Int16 mono bot-audio bytes pending speaker emission.
    /// The compose loop drains exactly 1920 bytes (= 40 ms) per tick
    /// in lockstep with the lipsync queue, then writes them to
    /// attachedSpeakerTrack. Burst arrivals from OpenAI accumulate
    /// here without overflowing the AudioTrack ring buffer.
    private val pcm24kQueue = ConcurrentLinkedDeque<ByteArray>()
    private var pcm24kCarry: ByteArray? = null
    private var pcm24kCarryOffset: Int = 0
    private val pcm24kLock = Any()

    /// Push 16 kHz mono Int16 lipsync chunks from the speaker pipeline.
    /// Mirrors AvatarTexture.enqueuePCM on macOS — splits into per-tick
    /// 640-sample FloatArrays so the render loop's drain stays uniform.
    fun enqueueLipsync16kInt16(samples: ShortArray) {
        val perTick = 640
        var off = 0
        while (off < samples.size) {
            val take = minOf(perTick, samples.size - off)
            if (take < perTick) break
            val arr = FloatArray(perTick)
            for (i in 0 until perTick) {
                arr[i] = samples[off + i].toFloat() / 32768f
            }
            audioQueue.addLast(arr)
            off += perTick
            // Avoid unbounded growth if the render loop falls behind
            // (e.g. user shows mid-conversation menu).
            if (audioQueue.size > 200) audioQueue.pollFirst()
        }
    }

    /// Append a 24 kHz Int16 mono chunk to the pending speaker queue.
    /// The compose loop will pop 40-ms slices and write them to the
    /// AudioTrack in lockstep with the lipsync frames derived from
    /// the same chunk.
    fun enqueueSpeaker24k(pcm: ByteArray) {
        pcm24kQueue.addLast(pcm)
    }

    /// Fill [out] (must be 1920 bytes = 40 ms @ 24 kHz mono int16)
    /// with the next slice of pending speaker audio. If the queue is
    /// empty / partially exhausts, the remainder is zero-padded
    /// (silence). Returns the number of "real" audio bytes written
    /// (so the caller can tell whether the agent is mid-utterance).
    fun popNextTickSpeaker24k(out: ByteArray): Int {
        val target = out.size
        var written = 0
        synchronized(pcm24kLock) {
            while (written < target) {
                var src = pcm24kCarry
                var srcOff = pcm24kCarryOffset
                if (src == null) {
                    src = pcm24kQueue.pollFirst()
                    srcOff = 0
                    if (src == null) break  // queue empty
                }
                val available = src.size - srcOff
                val take = minOf(available, target - written)
                System.arraycopy(src, srcOff, out, written, take)
                written += take
                if (take == available) {
                    pcm24kCarry = null
                    pcm24kCarryOffset = 0
                } else {
                    pcm24kCarry = src
                    pcm24kCarryOffset = srcOff + take
                }
            }
        }
        // Zero-pad the tail so the AudioTrack consumer reads silence
        // for any portion of the tick we didn't have real audio for.
        if (written < target) {
            java.util.Arrays.fill(out, written, target, 0)
        }
        return written
    }

    /// Drop pending lipsync chunks + pending 24k speaker bytes. Used
    /// by the barge-in path so the avatar AND the speaker both stop
    /// playing the cancelled response. Parallels
    /// AvatarTexture.clearAudioQueue on macOS.
    fun clearAudioQueue() {
        audioQueue.clear()
        synchronized(pcm24kLock) {
            pcm24kQueue.clear()
            pcm24kCarry = null
            pcm24kCarryOffset = 0
        }
    }

    fun dispose() {
        stopped.set(true)
        loopFuture.cancel(false)
        attachedSpeakerTrack = null
        runCatching { surface.release() }
        runCatching { runtime.close() }
        runCatching { fixture.close() }
        runCatching { surfaceEntry.release() }
    }
}

/// State carried by the per-AvatarEntry compose loop. Held on a heap
/// object instead of as captured vars so we can mutate from a helper
/// function (`resetRuntime`) without dealing with Kotlin's
/// var-capture-in-closure semantics.
private class ComposeState {
    var audioValidCount: Int = 0     // forward-growing buffer fill
    var ticksEmitted: Int = 0        // tracks runtime's internal cursor
    /// Set to true when audio arrives after >= idleResetGapMs of no
    /// chunks. Tells the next tick to destroy + recreate the runtime so
    /// the cursor rewinds to 0 before the new utterance lands. Mirrors
    /// macOS pendingUtteranceReset.
    var pendingUtteranceReset: Boolean = false
    var lastAudioArrivalMs: Long = 0L
    /// Number of consecutive ticks since we last drained a real (non-
    /// silence) byte from the speaker queue. Used to reset the runtime
    /// after ~1 s of post-utterance silence, which keeps the runtime
    /// cursor from drifting too far past audioBuf during long pauses.
    var idleSilentTicks: Int = 0
    /// Throttle the once-per-tick error log so a steady-state failure
    /// doesn't flood logcat.
    var loggedTickError: Boolean = false
}

/// Holds a Runtime that can be swapped (close+new) when the cursor
/// would otherwise race past the audio buffer end.
private class RuntimeHolder(var runtime: ai.bithuman.sdk.Runtime)
