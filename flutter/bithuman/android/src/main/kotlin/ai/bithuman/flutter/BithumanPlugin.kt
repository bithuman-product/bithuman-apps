// bithuman Android plugin — v0.3.
//
// Drives ai.bithuman:sdk:1.13.0 (Maven Central) via Fixture + Runtime
// directly. Renders at 25 fps via ScheduledExecutorService + Bitmap+Canvas
// path. Auth bypass: BITHUMAN_UNMETERED=1 (set via setenv at attach time)
// keeps the heartbeat off for the public-catalog .imx models.
//
// Apache-2.0; (c) bitHuman.

package ai.bithuman.flutter

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
// Per render tick, do at most this many tickCompose calls. Each
// compose ≈ 8 ms; 5 * 8 + bgr→argb + draw stays inside the 40 ms
// render budget. Used to cap catch-up bursts from WebRTC audio
// arriving faster than 1× real-time.
private const val MAX_COMPOSES_PER_TICK = 5
// 40 ms @ 24 kHz int16 mono = 960 samples × 2 bytes = 1920 bytes.
// One compose tick emits exactly this much audio to the speaker at
// the same wall-clock instant the matching frame is rendered, so A/V
// can never drift no matter how bursty the upstream chunk arrival is.
private const val SPEAKER_BYTES_PER_TICK_24K = 1920

class BithumanPlugin : FlutterPlugin, MethodCallHandler {

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
            "load"                     -> handleLoad(call, result)
            "pushAudio"                -> handlePushAudio(call, result)
            "dispose"                  -> handleDispose(call, result)
            "engineVersion"            -> handleEngineVersion(result)
            "audioStart"               -> handleAudioStart(call, result)
            "audioStop"                -> handleAudioStop(call, result)
            "interrupt"                -> handleInterrupt(call, result)
            "playSpeakerPCM"           -> handlePlaySpeakerPCM(call, result)
            "attachWebrtcRemoteAudio"  -> handleAttachWebrtcRemoteAudio(call, result)
            "detachWebrtcRemoteAudio"  -> handleDetachWebrtcRemoteAudio(call, result)
            else                       -> result.notImplemented()
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
                val fi = fixture.info
                val libVer = try { Fixture.libraryVersion() } catch (_: Throwable) { "unknown" }
                val abi = try { Fixture.abiVersion() } catch (_: Throwable) { -1 }
                Log.i(TAG, "fixture.info: sampleRate=${fi.audioSampleRate} " +
                    "samplesPerTick=${fi.audioSamplesPerTick} " +
                    "melBins=${fi.melBins} melFramesPerChunk=${fi.melFramesPerChunk} " +
                    "clusters=${fi.clusterCount} frames=${fi.sourceFrameCount} " +
                    "frame=${fi.frameWidth}x${fi.frameHeight} " +
                    "libVer=$libVer abi=$abi")

                // SELF-TEST: feed a synthetic vowel through a fresh
                // runtime and check cluster output. The signal is a
                // classic vowel signature (three formant tones at
                // 500/1500/2500 Hz modulated by an amplitude envelope
                // — close to /a/ as in "father"). If the engine
                // matches any cluster != 0 on this, it works; if it
                // stays 0, the engine itself can't classify here.
                runCatching {
                    val testRt = Runtime(fixture)
                    val testBuf = FloatArray(16000 * 8)  // 8 s of audio (enough buffer past 100 ticks * 640 = 64000 samples)
                    for (i in testBuf.indices) {
                        val t = i.toDouble() / 16000.0
                        val env = 0.5 + 0.5 * kotlin.math.sin(2 * Math.PI * 4 * t)
                        val f1 = kotlin.math.sin(2 * Math.PI * 500.0 * t)
                        val f2 = kotlin.math.sin(2 * Math.PI * 1500.0 * t) * 0.5
                        val f3 = kotlin.math.sin(2 * Math.PI * 2500.0 * t) * 0.3
                        testBuf[i] = (env * (f1 + f2 + f3) * 0.25).toFloat()
                    }
                    val testFrameBuf = ByteArray(fi.frameWidth.coerceAtLeast(MAX_FRAME_W) *
                        fi.frameHeight.coerceAtLeast(MAX_FRAME_H) * 3)
                    val seenClusters = IntArray(100)
                    var minCluster = Int.MAX_VALUE
                    var maxCluster = Int.MIN_VALUE
                    for (i in 0 until 100) {
                        val r = testRt.tickCompose(testBuf, -1, testFrameBuf)
                        if (i < seenClusters.size) seenClusters[i] = r.clusterIdx
                        if (r.clusterIdx < minCluster) minCluster = r.clusterIdx
                        if (r.clusterIdx > maxCluster) maxCluster = r.clusterIdx
                    }
                    testRt.close()
                    val histogram = seenClusters.toList().groupingBy { it }.eachCount()
                    Log.i(TAG, "ENGINE SELF-TEST: 100 ticks of synthetic vowel → " +
                        "cluster range=[$minCluster..$maxCluster] " +
                        "histogram=$histogram")
                    if (maxCluster == 0) {
                        Log.w(TAG, "ENGINE SELF-TEST FAILED: engine returned " +
                            "cluster=0 for ALL ticks of synthetic speech-like " +
                            "audio. The engine itself isn't classifying.")
                    } else {
                        Log.i(TAG, "ENGINE SELF-TEST PASSED: engine matched " +
                            "non-zero clusters on synthetic speech audio. " +
                            "The bug is in our audio sink path.")
                    }
                }.onFailure { e ->
                    Log.e(TAG, "ENGINE SELF-TEST threw: $e", e)
                }
                // EXPERIMENT: call runtime.tick() directly with a
                // chunk of the latest audio — this is the simpler
                // SDK API that just classifies and returns cluster.
                // Lets us test if the engine matches speech AT ALL,
                // independent of the tickCompose cursor logic.

                val bgrBuf = ByteArray(MAX_FRAME_W * MAX_FRAME_H * 3)
                val audioQueue = ConcurrentLinkedDeque<FloatArray>()
                val stopped = AtomicBoolean(false)

                // Streaming compose loop (ABI 6 / libessence v1.16):
                //   - Each render tick (40 ms) we push the freshly-drained
                //     audio chunks into the runtime's internal stream buffer
                //     (O(n_new); no recomputing mel over accumulated history).
                //   - When the stream goes idle, we push exactly one tick of
                //     silence so the engine keeps emitting idle-motion frames
                //     (blink/breathe/head-sway via cluster_idx==0).
                //   - resetStream() drops the accumulated mel + cursor on
                //     bridge-mode flips and utterance-gap detection without
                //     unloading the model.
                val state = ComposeState()
                val idleResetGapMs = 1000L  // matches macOS idleResetSecs
                val silenceTick = FloatArray(SAMPLES_PER_TICK)

                // bitmap + argb scratch are sized after first pullFrame.
                var bitmap: Bitmap? = null
                var argbInts: IntArray? = null
                var frameW = 0
                var frameH = 0

                fun resetRuntime() {
                    runtime.resetStream()
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
                            // Drain pending audio chunks. With streaming
                            // push_audio (O(n_new) per call), there is no
                            // need to cap drain — the per-chunk cost is
                            // ~0.2 ms for 640 samples. We still bound the
                            // pull (compose) side at MAX_COMPOSES_PER_TICK
                            // since each pullFrame does the heavy work
                            // (~8 ms: encode + KNN + decode + composite).
                            val pending = ArrayList<FloatArray>()
                            while (true) {
                                val c = audioQueue.pollFirst() ?: break
                                pending.add(c)
                            }
                            val nowMs = System.currentTimeMillis()
                            val idleGap = state.lastAudioArrivalMs > 0 &&
                                pending.isNotEmpty() &&
                                (nowMs - state.lastAudioArrivalMs) >= idleResetGapMs
                            if (pending.isNotEmpty()) {
                                state.lastAudioArrivalMs = nowMs
                            }
                            if (idleGap || state.pendingUtteranceReset) {
                                resetRuntime()
                            }

                            val tComposeStart = System.nanoTime()

                            // STREAMING COMPOSE LOOP (ABI 6):
                            //
                            //   pushAudio(real or silence) → ticksAvailable advances
                            //   pullFrame()                → consumes one tick
                            //
                            // The runtime's mel buffer extends by exactly the
                            // number of STFT frames produced by each push,
                            // so cursor advance == audio fill by construction.
                            // No chase-cursor math, no stale-pointer cache,
                            // no full-buffer recopy per tick.
                            val avatarEntryRef = avatarEntryHolder[0]
                            val inWebrtcBridgeMode =
                                avatarEntryRef?.webrtcPlaybackCallback != null ||
                                avatarEntryRef?.webrtcTrackSink != null

                            // Reset the stream on bridge-mode flips so stale
                            // audio from one mode doesn't drive the other.
                            if (inWebrtcBridgeMode != state.wasInBridgeMode) {
                                resetRuntime()
                                state.wasInBridgeMode = inWebrtcBridgeMode
                            }

                            // Feed the stream. When real chunks arrived this
                            // tick, push them all (O(n_new) per push). When
                            // nothing arrived, push one tick of silence so
                            // idle motion (blink/breathe/head-sway via
                            // cluster_idx 0 cycling bases[frame_idx]) keeps
                            // playing. In WebRTC bridge mode the sink fires
                            // ~100×/sec with always-present PCM so `pending`
                            // is essentially never empty — silence-push is
                            // the native (no WebRTC) idle path.
                            for (c in pending) {
                                try {
                                    runtime.pushAudio(c)
                                } catch (e: ai.bithuman.sdk.BithumanException) {
                                    Log.w(TAG, "pushAudio err — resetting: ${e.message}")
                                    resetRuntime()
                                    return@scheduleAtFixedRate
                                }
                            }
                            if (pending.isEmpty()) {
                                runtime.pushAudio(silenceTick)
                            }

                            // Drain available frames. Bounded so a momentary
                            // burst (e.g. WebRTC sink replay after a network
                            // hiccup) doesn't blow the 40 ms render budget.
                            val available = runtime.ticksAvailable.toInt()
                            val composeCount = minOf(available, MAX_COMPOSES_PER_TICK)
                            var composeErr = false
                            var lastClusterIdx = -1
                            var lastFrameIdx = -1
                            for (i in 0 until composeCount) {
                                try {
                                    val r = runtime.pullFrame(bgrBuf, -1)
                                    lastClusterIdx = r.clusterIdx
                                    lastFrameIdx = r.frameIdxUsed
                                    state.ticksEmitted++
                                } catch (e: ai.bithuman.sdk.BithumanException) {
                                    if (!state.loggedTickError) {
                                        state.loggedTickError = true
                                        Log.w(TAG, "pullFrame err — resetting: ${e.message}")
                                    }
                                    resetRuntime()
                                    composeErr = true
                                    break
                                }
                            }
                            if (composeErr) return@scheduleAtFixedRate
                            state.loggedTickError = false
                            val tComposeEnd = System.nanoTime()

                            if (composeCount == 0) {
                                if (state.ticksEmitted % 25 == 0) {
                                    Log.i(TAG, "perf skip (no audio) — idle redraw, " +
                                        "ticksAvailable=$available " +
                                        "queue=${avatarEntryRef?.audioQueue?.size ?: 0}")
                                }
                                return@scheduleAtFixedRate
                            }
                            if (state.ticksEmitted % 25 == 0) {
                                Log.i(TAG, "compose: cluster=$lastClusterIdx frame=$lastFrameIdx " +
                                    "composeCount=$composeCount available=$available")
                            }

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
                            // Native-mode post-utterance silence cleanup:
                            // after ~1 s of silence-only ticks (speaker
                            // queue drained empty), drop accumulated mel
                            // so the next utterance starts with a fresh
                            // stream. Skipped in WebRTC bridge mode (the
                            // sink owns the speaker queue, so realBytes
                            // is permanently 0 there — idleGap handling
                            // above is the bridge-mode analog).
                            if (!inWebrtcBridgeMode && realBytes == 0) {
                                state.idleSilentTicks++
                                if (state.idleSilentTicks > 25) {
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
                                val perComposeMs = if (composeCount > 0) composeMs / composeCount else 0.0
                                Log.i(TAG, "perf t=${state.ticksEmitted} " +
                                    "compose=${"%.1f".format(composeMs)}ms " +
                                    "perCompose=${"%.1f".format(perComposeMs)}ms " +
                                    "bgr→argb=${"%.1f".format(convMs)}ms " +
                                    "lockCanvas=${"%.1f".format(lockMs)}ms " +
                                    "draw+post=${"%.1f".format(drawMs)}ms " +
                                    "available=$available " +
                                    "queue=${avatarEntryRef?.audioQueue?.size ?: 0}")
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
        val (entry, io) = synchronized(avatarsLock) {
            avatars[textureId] to audioIOs[textureId]
        }
        // Always drop pending lipsync audio so the avatar's mouth stops
        // articulating the cancelled response and returns to idle.
        // This is what catches the WebRTC-bridge path — there's no
        // RealtimeAudioIO to call barge() on, but the lipsync queue
        // still has chunks the render loop is consuming.
        runCatching { entry?.clearAudioQueue() }
        runCatching { io?.barge() }
        result.success(null)
    }

    /// Attach taps to BOTH possible libwebrtc audio paths so we can
    /// drive the avatar's lipsync queue from whichever path actually
    /// carries OpenAI's bot output on this device. Empirically, on
    /// Z Fold 5 the JADM playback callback fires continuously but
    /// only with zeros — bot audio must be travelling via a
    /// different path. So we ALSO wire `org.webrtc.AudioTrack.addSink`
    /// on the remote track itself; for remote tracks that taps the
    /// RemoteAudioSource and should fire with decoded PCM regardless
    /// of how libwebrtc plumbs the device-side output.
    ///
    /// Both hooks are duplicate-safe: each one resamples + de-dups
    /// via the audioQueue cap. Whichever delivers real audio first
    /// drives lipsync; the other contributes only silence.
    private fun handleAttachWebrtcRemoteAudio(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        val trackId = call.argument<String>("trackId")
        if (textureId == null || trackId == null) {
            result.error("BAD_ARGS", "needs textureId and trackId", null)
            return
        }
        val entry = synchronized(avatarsLock) { avatars[textureId] }
        if (entry == null) {
            result.error("NOT_FOUND", "no avatar for textureId=$textureId", null)
            return
        }

        // Reach into FlutterWebRTCPlugin and pull its
        // PlaybackSamplesReadyCallbackAdapter. Both classes live in
        // com.cloudwebrtc.webrtc; the field is public on the
        // (singleton-held) MethodCallHandlerImpl. We use reflection
        // so the bithuman plugin doesn't link-depend on
        // flutter_webrtc — apps that ship it get the bridge, apps
        // that don't simply never call this method.
        val adapter: Any? = try {
            val pluginClass = Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin")
            val singleton = pluginClass.getField("sharedSingleton").get(null)
                ?: throw IllegalStateException(
                    "FlutterWebRTCPlugin.sharedSingleton is null — has WebRTC.initialize() run?")
            // methodCallHandler is private, but methodCallHandlerImpl
            // is the only field of that type on the plugin so we just
            // grab the first matching one.
            val handler = pluginClass.declaredFields
                .firstOrNull {
                    it.type.name.endsWith(".MethodCallHandlerImpl")
                }
                ?.apply { isAccessible = true }
                ?.get(singleton)
                ?: throw IllegalStateException(
                    "FlutterWebRTCPlugin.methodCallHandler not found via reflection")
            val adapterField = handler.javaClass.getField("playbackSamplesReadyCallbackAdapter")
            adapterField.get(handler)
                ?: throw IllegalStateException(
                    "playbackSamplesReadyCallbackAdapter is null")
        } catch (e: Throwable) {
            Log.e(TAG, "attachWebrtcRemoteAudio: $e")
            null
        }
        if (adapter == null) {
            result.error(
                "NO_WEBRTC_ADAPTER",
                "PlaybackSamplesReadyCallbackAdapter not reachable — make sure flutter_webrtc is loaded",
                null,
            )
            return
        }

        // If a previous callback was attached for this entry, detach
        // it first so we don't double-push on reconnect.
        val prev = entry.webrtcPlaybackCallback
        if (prev != null) {
            runCatching {
                adapter.javaClass
                    .getMethod(
                        "removeCallback",
                        Class.forName(
                            "org.webrtc.audio.JavaAudioDeviceModule\$PlaybackSamplesReadyCallback"
                        ),
                    )
                    .invoke(adapter, prev)
            }
            entry.webrtcPlaybackCallback = null
            entry.webrtcPlaybackAdapter = null
        }

        // We previously also wired a JADM PlaybackSamplesReadyCallback
        // here. It DID fire with real PCM (RMS up to 0.33 during bot
        // speech), but combining it with the AudioTrackSink doubled
        // the audio rate going into the lipsync queue — the runtime
        // ended up consuming an interleaved mix of the SAME audio
        // from two sources, which destroys the spectrogram and
        // forces the phoneme classifier into idle. Keep the
        // adapter handle for symmetric detach but never attach.
        entry.webrtcPlaybackAdapter = adapter

        // Attach the remote AudioTrack sink. For remote tracks this
        // hooks the RemoteAudioSource — decoded PCM appears here
        // before any device-side mixing, so we get clean OpenAI
        // output regardless of how libwebrtc routes playback.
        val track: org.webrtc.AudioTrack? = try {
            val pluginClass = Class.forName("com.cloudwebrtc.webrtc.FlutterWebRTCPlugin")
            val singleton = pluginClass.getField("sharedSingleton").get(null)
            val raw = pluginClass.getMethod("getRemoteTrack", String::class.java)
                .invoke(singleton, trackId)
            raw as? org.webrtc.AudioTrack
        } catch (e: Throwable) {
            Log.e(TAG, "remote AudioTrack lookup failed: $e")
            null
        }
        if (track == null) {
            result.error(
                "NO_REMOTE_TRACK",
                "audio track $trackId not found via FlutterWebRTCPlugin",
                null,
            )
            return
        }
        val sink = WebrtcLipsyncTrackSink(entry)
        try {
            track.addSink(sink)
        } catch (e: Throwable) {
            Log.e(TAG, "remote AudioTrack.addSink failed: $e")
            result.error("ADD_SINK_FAILED", e.message ?: "unknown", null)
            return
        }
        entry.webrtcTrackSink = sink
        entry.webrtcAttachedTrack = track
        Log.i(TAG, "WebRTC lipsync attached: textureId=$textureId trackId=$trackId")
        result.success(null)
    }

    private fun handleDetachWebrtcRemoteAudio(call: MethodCall, result: Result) {
        val textureId = call.argument<Number>("textureId")?.toLong()
        if (textureId == null) {
            result.error("BAD_ARGS", "detachWebrtcRemoteAudio requires textureId", null)
            return
        }
        val entry = synchronized(avatarsLock) { avatars[textureId] }
        if (entry == null) { result.success(null); return }
        val cb = entry.webrtcPlaybackCallback
        val adapter = entry.webrtcPlaybackAdapter
        if (cb != null && adapter != null) {
            runCatching {
                adapter.javaClass
                    .getMethod(
                        "removeCallback",
                        Class.forName(
                            "org.webrtc.audio.JavaAudioDeviceModule\$PlaybackSamplesReadyCallback"
                        ),
                    )
                    .invoke(adapter, cb)
            }
        }
        entry.webrtcPlaybackCallback = null
        entry.webrtcPlaybackAdapter = null
        val sink = entry.webrtcTrackSink
        val track = entry.webrtcAttachedTrack
        if (sink != null && track != null) {
            runCatching { track.removeSink(sink) }
        }
        entry.webrtcTrackSink = null
        entry.webrtcAttachedTrack = null
        // Also flush any in-flight lipsync chunks so the mouth stops
        // mid-utterance when the call ends.
        runCatching { entry.clearAudioQueue() }
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

    /// WebRTC-bridge handles. Both taps (JADM playback callback +
    /// remote AudioTrack sink) are attached at the same time so we
    /// catch the audio regardless of which path libwebrtc takes on
    /// this device.
    @Volatile var webrtcPlaybackCallback: Any? = null
    @Volatile var webrtcPlaybackAdapter: Any? = null
    @Volatile var webrtcTrackSink: WebrtcLipsyncTrackSink? = null
    @Volatile var webrtcAttachedTrack: org.webrtc.AudioTrack? = null

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
        val cb = webrtcPlaybackCallback
        val adapter = webrtcPlaybackAdapter
        if (cb != null && adapter != null) {
            runCatching {
                adapter.javaClass.getMethod(
                    "removeCallback",
                    Class.forName(
                        "org.webrtc.audio.JavaAudioDeviceModule\$PlaybackSamplesReadyCallback"
                    ),
                ).invoke(adapter, cb)
            }
        }
        webrtcPlaybackCallback = null
        webrtcPlaybackAdapter = null
        val sink = webrtcTrackSink
        val track = webrtcAttachedTrack
        if (sink != null && track != null) {
            runCatching { track.removeSink(sink) }
        }
        webrtcTrackSink = null
        webrtcAttachedTrack = null
        runCatching { surface.release() }
        runCatching { runtime.close() }
        runCatching { fixture.close() }
        runCatching { surfaceEntry.release() }
    }
}

/// AudioTrackSink on the remote audio track. For remote tracks this
/// hooks the RemoteAudioSource — fires when decoded PCM is available,
/// regardless of how libwebrtc routes playback to the device. Same
/// resample-and-enqueue logic as the JADM playback callback so the
/// downstream avatar code doesn't care which path delivered the data.
internal class WebrtcLipsyncTrackSink(
    private val entry: AvatarEntry,
) : org.webrtc.AudioTrackSink {
    private var carry: FloatArray = FloatArray(0)
    private var firedCount: Long = 0L
    private var lastRmsLog: Long = 0L
    private var maxRms: Float = 0f
    private var sawNonSilence = false

    override fun onData(
        audioData: java.nio.ByteBuffer,
        bitsPerSample: Int,
        sampleRate: Int,
        numberOfChannels: Int,
        numberOfFrames: Int,
        absoluteCaptureTimestampMs: Long,
    ) {
        firedCount++
        if (firedCount == 1L) {
            Log.i(
                TAG,
                "track sink firing: rate=$sampleRate ch=$numberOfChannels " +
                    "bps=$bitsPerSample frames=$numberOfFrames",
            )
        }
        if (bitsPerSample != 16 || numberOfFrames <= 0) return

        audioData.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        audioData.rewind()
        val sb = audioData.asShortBuffer()
        val mono = FloatArray(numberOfFrames)
        if (numberOfChannels == 1) {
            for (i in 0 until numberOfFrames) mono[i] = sb.get().toFloat() / 32768f
        } else {
            for (f in 0 until numberOfFrames) {
                var sum = 0f
                for (c in 0 until numberOfChannels) sum += sb.get().toFloat() / 32768f
                mono[f] = sum / numberOfChannels
            }
        }

        var sumSq = 0.0
        for (s in mono) sumSq += (s.toDouble() * s.toDouble())
        val rms = kotlin.math.sqrt(sumSq / numberOfFrames).toFloat()
        if (rms > maxRms) maxRms = rms
        if (rms > 0.005f) sawNonSilence = true
        val nowMs = System.currentTimeMillis()
        if (nowMs - lastRmsLog > 1000L) {
            Log.i(
                TAG,
                "track sink rms: max=${"%.4f".format(maxRms)} now=${"%.4f".format(rms)} " +
                    "sawNonSilence=$sawNonSilence calls=$firedCount",
            )
            lastRmsLog = nowMs
            maxRms = 0f
        }

        val resampled = resampleTo16k(mono, sampleRate)
        if (resampled.isEmpty()) return
        val combined = FloatArray(carry.size + resampled.size)
        System.arraycopy(carry, 0, combined, 0, carry.size)
        System.arraycopy(resampled, 0, combined, carry.size, resampled.size)
        var off = 0
        while (off + SAMPLES_PER_TICK <= combined.size &&
               entry.audioQueue.size < MAX_QUEUE_CHUNKS) {
            entry.audioQueue.addLast(
                combined.copyOfRange(off, off + SAMPLES_PER_TICK)
            )
            off += SAMPLES_PER_TICK
        }
        carry = if (off < combined.size) {
            combined.copyOfRange(off, combined.size)
        } else {
            EMPTY
        }
    }

    /// Resample to 16 kHz with anti-alias filtering.
    ///
    /// Naive decimation (every Nth sample) folds the spectrum above
    /// 8 kHz back into 4–8 kHz where speech formants live. libwebrtc
    /// upsamples OpenAI's 24 kHz feed to 48 kHz with content up to
    /// ~12 kHz, so plain decimation corrupts the 4–8 kHz formant
    /// region — the bithuman phoneme classifier then can't extract
    /// visemes and outputs cluster=0 (idle) forever, even though the
    /// audio has real RMS at the cursor. Box-filter averaging over
    /// the integer downsample ratio is crude but effective: it kills
    /// the alias band enough that the classifier sees clean formants
    /// (verified empirically — without this, real RMS ≈0.14 at cursor
    /// still produced cluster=0).
    private fun resampleTo16k(input: FloatArray, inRate: Int): FloatArray {
        if (inRate == 16000) return input
        if (input.isEmpty()) return input
        val integerRatio = inRate / 16000
        if (integerRatio >= 2 && inRate % 16000 == 0) {
            val outLen = input.size / integerRatio
            val output = FloatArray(outLen)
            for (i in 0 until outLen) {
                val idx = i * integerRatio
                var sum = 0f
                for (j in 0 until integerRatio) sum += input[idx + j]
                output[i] = sum / integerRatio
            }
            return output
        }
        val ratio = inRate.toDouble() / 16000.0
        val outLen = (input.size / ratio).toInt()
        if (outLen <= 0) return EMPTY
        val output = FloatArray(outLen)
        for (i in 0 until outLen) {
            val srcPos = i * ratio
            val idx = srcPos.toInt()
            val frac = (srcPos - idx).toFloat()
            output[i] = if (idx + 1 < input.size) {
                input[idx] * (1f - frac) + input[idx + 1] * frac
            } else {
                input[idx]
            }
        }
        return output
    }

    companion object {
        private val EMPTY = FloatArray(0)
    }
}

/// Receives OpenAI's bot-output PCM from flutter_webrtc's
/// JavaAudioDeviceModule playback callback, downmixes to mono if
/// needed, resamples to 16 kHz, and feeds the avatar's lipsync queue
/// at 40 ms per tick. Tap point is on the PLAYBACK path (samples
/// about to be written to AudioTrack) so it cannot pick up the mic —
/// the source is exclusively what the user is hearing.
internal class WebrtcLipsyncPlaybackCallback(
    private val entry: AvatarEntry,
) : org.webrtc.audio.JavaAudioDeviceModule.PlaybackSamplesReadyCallback {
    private var carry: FloatArray = FloatArray(0)
    private var firedCount: Long = 0L
    private var lastRmsLog: Long = 0L
    private var maxRms: Float = 0f
    // Track whether bot audio (non-silent samples) has ever flowed
    // through. If RMS never rises above the silence floor, the
    // playback callback isn't seeing the actual audio.
    private var sawNonSilence = false

    // Pre-fill chunks of silence into the queue on the first sink
    // firing. The runtime's tickCompose reads audio at and AHEAD of
    // the cursor (the existing buffer-wrap math pads by 3 ticks =
    // 120 ms, which is consistent with phoneme classification needing
    // forward context). Without this lead, the cursor would land on
    // unwritten audio every tick → idle motion forever even while
    // real PCM flows through. The macOS pushAudio path sidesteps
    // this because Dart already buffers ahead before pushing — the
    // bridge path delivers at exactly 1× real-time so we have to
    // manufacture the lead ourselves.
    private var seededSilence = false
    private val SEED_TICKS = 3

    override fun onWebRtcAudioTrackSamplesReady(
        samples: org.webrtc.audio.JavaAudioDeviceModule.AudioSamples,
    ) {
        firedCount++
        if (firedCount == 1L) {
            Log.i(
                TAG,
                "playback tap firing: rate=${samples.sampleRate} " +
                    "ch=${samples.channelCount} fmt=${samples.audioFormat} " +
                    "bytes=${samples.data.size}",
            )
        }
        if (!seededSilence) {
            seededSilence = true
            repeat(SEED_TICKS) {
                entry.audioQueue.addLast(FloatArray(SAMPLES_PER_TICK))
            }
            Log.i(TAG, "seeded $SEED_TICKS ticks of silence to give cursor a lead over fill")
        }

        // AudioSamples.data is PCM16 little-endian, channelCount
        // channels interleaved at sampleRate.
        val data = samples.data
        val sampleRate = samples.sampleRate
        val channels = samples.channelCount
        val numberOfFrames = data.size / 2 / channels
        if (numberOfFrames <= 0) return

        val bb = java.nio.ByteBuffer.wrap(data).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        val sb = bb.asShortBuffer()

        val mono = FloatArray(numberOfFrames)
        if (channels == 1) {
            for (i in 0 until numberOfFrames) {
                mono[i] = sb.get().toFloat() / 32768f
            }
        } else {
            for (f in 0 until numberOfFrames) {
                var sum = 0f
                for (c in 0 until channels) sum += sb.get().toFloat() / 32768f
                mono[f] = sum / channels
            }
        }

        // RMS probe — confirms the playback callback is seeing the
        // actual bot audio, not silence. Logs the rolling-max RMS
        // observed per second so we can tell whether the audio data
        // reaching this sink contains real speech (RMS rises above
        // ~0.01 during bot speech) or just zeros (RMS stays ~0).
        var sumSq = 0.0
        for (s in mono) sumSq += (s.toDouble() * s.toDouble())
        val rms = kotlin.math.sqrt(sumSq / numberOfFrames).toFloat()
        if (rms > maxRms) maxRms = rms
        if (rms > 0.005f) sawNonSilence = true
        val nowMs = System.currentTimeMillis()
        if (nowMs - lastRmsLog > 1000L) {
            Log.i(
                TAG,
                "playback rms: max=${"%.4f".format(maxRms)} now=${"%.4f".format(rms)} " +
                    "sawNonSilence=$sawNonSilence calls=$firedCount",
            )
            lastRmsLog = nowMs
            maxRms = 0f
        }

        val resampled = resampleTo16k(mono, sampleRate)
        if (resampled.isEmpty()) return

        val combined = FloatArray(carry.size + resampled.size)
        System.arraycopy(carry, 0, combined, 0, carry.size)
        System.arraycopy(resampled, 0, combined, carry.size, resampled.size)
        var off = 0
        while (off + SAMPLES_PER_TICK <= combined.size &&
               entry.audioQueue.size < MAX_QUEUE_CHUNKS) {
            entry.audioQueue.addLast(
                combined.copyOfRange(off, off + SAMPLES_PER_TICK)
            )
            off += SAMPLES_PER_TICK
        }
        carry = if (off < combined.size) {
            combined.copyOfRange(off, combined.size)
        } else {
            EMPTY
        }
    }

    /// Resample to 16 kHz with anti-alias filtering.
    ///
    /// Naive decimation (every Nth sample) folds the spectrum above
    /// 8 kHz back into 4–8 kHz where speech formants live. libwebrtc
    /// upsamples OpenAI's 24 kHz feed to 48 kHz with content up to
    /// ~12 kHz, so plain decimation corrupts the 4–8 kHz formant
    /// region — the bithuman phoneme classifier then can't extract
    /// visemes and outputs cluster=0 (idle) forever, even though the
    /// audio has real RMS at the cursor. Box-filter averaging over
    /// the integer downsample ratio is crude but effective: it kills
    /// the alias band enough that the classifier sees clean formants
    /// (verified empirically — without this, real RMS ≈0.14 at cursor
    /// still produced cluster=0).
    private fun resampleTo16k(input: FloatArray, inRate: Int): FloatArray {
        if (inRate == 16000) return input
        if (input.isEmpty()) return input
        val integerRatio = inRate / 16000
        if (integerRatio >= 2 && inRate % 16000 == 0) {
            val outLen = input.size / integerRatio
            val output = FloatArray(outLen)
            for (i in 0 until outLen) {
                val idx = i * integerRatio
                var sum = 0f
                for (j in 0 until integerRatio) sum += input[idx + j]
                output[i] = sum / integerRatio
            }
            return output
        }
        val ratio = inRate.toDouble() / 16000.0
        val outLen = (input.size / ratio).toInt()
        if (outLen <= 0) return EMPTY
        val output = FloatArray(outLen)
        for (i in 0 until outLen) {
            val srcPos = i * ratio
            val idx = srcPos.toInt()
            val frac = (srcPos - idx).toFloat()
            output[i] = if (idx + 1 < input.size) {
                input[idx] * (1f - frac) + input[idx + 1] * frac
            } else {
                input[idx]
            }
        }
        return output
    }

    companion object {
        private val EMPTY = FloatArray(0)
    }
}

/// State carried by the per-AvatarEntry compose loop. Held on a heap
/// object instead of as captured vars so we can mutate from a helper
/// function (`resetRuntime`) without dealing with Kotlin's
/// var-capture-in-closure semantics.
private class ComposeState {
    var ticksEmitted: Int = 0        // monotonic frame counter (diagnostics)
    /// Tracks whether the renderer was in WebRTC bridge mode last tick.
    /// Used to detect false↔true transitions and force a resetStream so
    /// stale audio from one mode doesn't drive the other.
    var wasInBridgeMode: Boolean = false
    /// Set when audio arrives after >= idleResetGapMs of silence so the
    /// next tick resets the stream before the new utterance lands.
    var pendingUtteranceReset: Boolean = false
    var lastAudioArrivalMs: Long = 0L
    /// Consecutive ticks of empty speaker queue. Trips a stream reset
    /// after ~1 s in native (non-WebRTC) mode.
    var idleSilentTicks: Int = 0
    var loggedTickError: Boolean = false
}
