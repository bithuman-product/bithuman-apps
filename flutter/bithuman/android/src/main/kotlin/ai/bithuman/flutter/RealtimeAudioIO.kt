// RealtimeAudioIO — Android mic capture + speaker playback + AEC, parallel
// to macOS Classes/RealtimeAudioIO.swift. AudioRecord and AudioTrack are
// independent CoreAudio-equivalents on Android; the AEC + NS effects pull
// echo cancellation onto the AudioRecord session so the agent's voice is
// removed from the mic stream before it reaches Dart / the local VAD.
//
// Data flow mirrors the Swift implementation:
//   mic loop (24 kHz Int16 mono) → EventChannel sink (Dart -> OpenAI) +
//   local VAD (peak > 1500 → barge)
//   speaker call (24 kHz Int16 mono) → AudioTrack.write() + push the same
//   chunk resampled to 16 kHz to the AvatarEntry for lip-sync
//
// Apache-2.0; (c) bitHuman.

package ai.bithuman.flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

private const val TAG = "RealtimeAudioIO"

// 24 kHz mono int16 PCM is the OpenAI Realtime native format on both ends.
private const val MIC_SAMPLE_RATE = 24_000
private const val SPK_SAMPLE_RATE = 24_000
private const val LIPSYNC_SAMPLE_RATE = 16_000
// 40 ms @ 24 kHz = 960 samples = 1920 bytes per chunk we hand back to Dart.
private const val MIC_CHUNK_SAMPLES = 960

// VAD constants (mirror Swift): peak > 1500 (~0.045 fs int16) marks the
// user as talking; 0.5 s quiet timeout closes the "user voice active"
// window during which all bot audio is dropped.
private const val VOICE_PEAK_THRESHOLD = 1500
private const val VOICE_QUIET_TIMEOUT_MS = 500L

// Echo gate: Android's AcousticEchoCanceler is weaker than Apple VP-IO,
// so the agent's voice leaks back through the speaker into the mic. To
// stop that leak from looking like user speech (and barge-cancelling the
// agent every ~1 s), require the mic peak to exceed ECHO_GATE_RATIO ×
// the recent speaker peak before firing local barge. Server VAD still
// fires the canonical end-of-turn on the OpenAI side regardless.
private const val ECHO_GATE_RATIO = 3.0f
// We treat the agent as "still audible at the speaker" for this long
// after the last speaker write. Drives the half-duplex mic gate:
// while audible, the mic loop replaces forwarded chunks with silence
// so OpenAI's server VAD can't fire on AEC residual of the agent's
// own voice. A response.audio.delta from the model may pause for
// 1-2 seconds mid-utterance (token generation hiccup), so set the
// tail long enough to bridge those gaps and not lose the rest of
// the reply to a spurious server-VAD cancel.
private const val SPEAKER_ACTIVE_TAIL_MS = 3000L

internal class RealtimeAudioIO(
    private val avatarEntry: AvatarEntry,
    private val appContext: Context,
) : EventChannel.StreamHandler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val audioManager: AudioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    // We flip the system audio mode to MODE_IN_COMMUNICATION during the
    // session so AEC + AGC + speakerphone routing all engage as a unit.
    // savedMode / savedSpeakerphone restore the prior state on stop().
    private var savedMode: Int = AudioManager.MODE_NORMAL
    private var savedSpeakerphone: Boolean = false
    private var audioModeOwned: Boolean = false

    private var micRecord: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var agc: AutomaticGainControl? = null

    private var speakerTrack: AudioTrack? = null

    @Volatile private var micThread: Thread? = null
    private val micStopFlag = AtomicBoolean(false)
    private val started = AtomicBoolean(false)

    // EventChannel sink. Dart's mic stream subscriber lives here.
    private val micSink = AtomicReference<EventChannel.EventSink?>(null)

    // Local VAD state. lastVoiceActivityAtMs == 0 means "no voice
    // detected yet"; updated each time a mic chunk exceeds the peak
    // threshold. The isUserVoiceActive predicate looks at the current
    // clock vs this timestamp.
    @Volatile private var lastVoiceActivityAtMs: Long = 0L

    // Recent speaker peak + last-write timestamp. Updated every time the
    // Realtime client schedules bot audio. Drives the echo gate — mic
    // peaks below ECHO_GATE_RATIO × recentSpeakerPeak are assumed to be
    // AEC-residual leak from the agent's own voice, not real user speech.
    @Volatile private var recentSpeakerPeak: Int = 0
    @Volatile private var lastSpeakerWriteAtMs: Long = 0L

    private val isUserVoiceActive: Boolean
        get() {
            val t = lastVoiceActivityAtMs
            if (t == 0L) return false
            return (System.currentTimeMillis() - t) < VOICE_QUIET_TIMEOUT_MS
        }

    private val isAgentAudible: Boolean
        get() {
            // Agent is audible if a chunk arrived recently enough
            // that the compose loop is still emitting it from the
            // AvatarEntry's paired-speaker queue, or the AudioTrack
            // tail is still draining. SPEAKER_ACTIVE_TAIL_MS bridges
            // intra-utterance pauses + the speaker buffer's drain
            // tail.
            val t = lastSpeakerWriteAtMs
            if (t == 0L) return false
            return (System.currentTimeMillis() - t) < SPEAKER_ACTIVE_TAIL_MS
        }

    // -------- Lifecycle --------

    fun start() {
        if (started.getAndSet(true)) return
        try {
            // CRITICAL: USAGE_VOICE_COMMUNICATION routes audio to the
            // EARPIECE by default on most Android phones (it's the
            // "call" output path). Force MODE_IN_COMMUNICATION +
            // speakerphone so playback comes out the LOUDSPEAKER —
            // without this the user holds the phone normally and
            // hears nothing because the audio is going to the
            // pressed-against-the-ear receiver instead of the
            // hands-free speaker. macOS has no earpiece so this
            // problem doesn't exist there.
            try {
                savedMode = audioManager.mode
                savedSpeakerphone = audioManager.isSpeakerphoneOn
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = true
                audioModeOwned = true
                Log.i(TAG, "audio routing: mode=IN_COMMUNICATION speakerphone=ON " +
                           "(was mode=$savedMode speakerphone=$savedSpeakerphone)")
            } catch (e: Throwable) {
                Log.w(TAG, "could not set speakerphone routing: ${e.message}")
            }
            startSpeaker()
            startMic()
            Log.i(TAG, "audio engine up (mic ${MIC_SAMPLE_RATE} Hz, spk ${SPK_SAMPLE_RATE} Hz, AEC=${aec != null})")
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            stop()
            throw e
        }
    }

    fun stop() {
        if (!started.getAndSet(false)) return
        micStopFlag.set(true)
        try { micThread?.join(500) } catch (_: Throwable) {}
        micThread = null

        // Detach the speaker track from AvatarEntry so the compose
        // loop stops trying to write to it before we release.
        avatarEntry.attachedSpeakerTrack = null

        try { aec?.release() } catch (_: Throwable) {}
        try { ns?.release() } catch (_: Throwable) {}
        try { agc?.release() } catch (_: Throwable) {}
        aec = null; ns = null; agc = null

        try {
            micRecord?.stop()
            micRecord?.release()
        } catch (_: Throwable) {}
        micRecord = null

        try {
            speakerTrack?.pause()
            speakerTrack?.flush()
            speakerTrack?.release()
        } catch (_: Throwable) {}
        speakerTrack = null

        // Restore the system audio mode + speakerphone state we owned.
        if (audioModeOwned) {
            try {
                audioManager.mode = savedMode
                @Suppress("DEPRECATION")
                audioManager.isSpeakerphoneOn = savedSpeakerphone
            } catch (_: Throwable) {}
            audioModeOwned = false
        }

        Log.i(TAG, "audio engine down")
    }

    /// Cut the agent off mid-sentence — drop pending paired audio in
    /// the AvatarEntry queue (both 24k speaker bytes + 16k lipsync
    /// samples) and flush the AudioTrack ring so the user hears the
    /// stop within one tick. Mirrors RealtimeAudioIO.swift's barge().
    fun barge() {
        Log.i(TAG, "barge: cancelling agent playback + lipsync")
        // clearAudioQueue drops both the lipsync and the 24k speaker
        // pending bytes; the next compose tick pops silence and
        // writes that to the AudioTrack instead of agent audio.
        avatarEntry.clearAudioQueue()
        try {
            speakerTrack?.let {
                it.pause()
                it.flush()
                it.play()
            }
        } catch (e: Throwable) {
            Log.w(TAG, "barge: speaker reset: ${e.message}")
        }
    }

    // -------- Mic --------

    private fun startMic() {
        // VOICE_COMMUNICATION source enables platform-supplied AEC on
        // many devices implicitly. We still attempt to attach the
        // AcousticEchoCanceler effect explicitly as belt-and-suspenders
        // — some OEM HALs only expose it through the effect framework.
        val bufBytes = AudioRecord.getMinBufferSize(
            MIC_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        ).coerceAtLeast(MIC_CHUNK_SAMPLES * 2 * 4)

        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            MIC_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufBytes,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord state=${rec.state}; check RECORD_AUDIO permission")
        }
        micRecord = rec

        val sessionId = rec.audioSessionId
        if (AcousticEchoCanceler.isAvailable()) {
            aec = AcousticEchoCanceler.create(sessionId)?.apply { enabled = true }
            Log.i(TAG, "AEC attached: enabled=${aec?.enabled}")
        } else {
            Log.w(TAG, "AcousticEchoCanceler not available on this device")
        }
        if (NoiseSuppressor.isAvailable()) {
            ns = NoiseSuppressor.create(sessionId)?.apply { enabled = true }
        }
        if (AutomaticGainControl.isAvailable()) {
            agc = AutomaticGainControl.create(sessionId)?.apply { enabled = true }
        }

        rec.startRecording()
        micStopFlag.set(false)
        val t = Thread({ micLoop(rec) }, "bithuman-mic")
        t.isDaemon = true
        t.start()
        micThread = t
    }

    private fun micLoop(rec: AudioRecord) {
        val buf = ShortArray(MIC_CHUNK_SAMPLES)
        val bytes = ByteArray(MIC_CHUNK_SAMPLES * 2)
        var micChunkCount = 0L
        while (!micStopFlag.get()) {
            var read = 0
            while (read < MIC_CHUNK_SAMPLES && !micStopFlag.get()) {
                val n = rec.read(buf, read, MIC_CHUNK_SAMPLES - read)
                if (n <= 0) {
                    if (n == AudioRecord.ERROR_INVALID_OPERATION ||
                        n == AudioRecord.ERROR_BAD_VALUE) {
                        Log.w(TAG, "AudioRecord.read err=$n")
                        return
                    }
                    // Brief sleep on transient zero read (e.g. ERROR_DEAD_OBJECT
                    // after audio focus loss). Bail out if persistent.
                    Thread.sleep(2)
                    continue
                }
                read += n
            }
            if (read < MIC_CHUNK_SAMPLES) continue
            micChunkCount++

            // Peak detection for local VAD.
            var peak = 0
            var i = 0
            while (i < MIC_CHUNK_SAMPLES) {
                val s = buf[i].toInt()
                val a = if (s < 0) -s else s
                if (a > peak) peak = a
                i += 8
            }
            // Local VAD-driven barge has been REMOVED on Android.
            // Z Fold 5 (and most Android devices) have an
            // AcousticEchoCanceler effect that is dramatically weaker
            // than Apple VP-IO; the agent's own voice consistently
            // bleeds back into the mic at peaks ~2000-5000 — well
            // above any sensible absolute floor. Every false-positive
            // here calls speakerQueue.clear() + AudioTrack.flush() +
            // avatarEntry.clearAudioQueue(), which truncates the
            // agent's reply mid-word and freezes the lipsync queue.
            // OpenAI's server-side VAD still receives the mic stream
            // we forward unchanged and fires response.cancel when the
            // user actually starts speaking — that is the canonical
            // end-of-turn signal anyway. The only thing we lose by
            // removing local VAD here is ~500 ms of barge latency,
            // which is a far better trade than constant false barges.

            // Forward the real mic chunk. With speakerphone routing
            // active (MODE_IN_COMMUNICATION + setSpeakerphoneOn) the
            // mic and loudspeaker are physically far apart and the
            // platform AcousticEchoCanceler can effectively remove
            // the agent's own voice from the mic feed before it
            // reaches OpenAI's server VAD, so we no longer need to
            // mute the mic during agent speech.
            var b = 0
            for (idx in 0 until MIC_CHUNK_SAMPLES) {
                val s = buf[idx].toInt()
                bytes[b++] = (s and 0xFF).toByte()
                bytes[b++] = ((s ushr 8) and 0xFF).toByte()
            }
            val chunk = bytes.copyOf()  // Detach from the reused scratch buffer.

            val sink = micSink.get()
            if (sink != null) {
                mainHandler.post {
                    try { sink.success(chunk) }
                    catch (e: Throwable) { Log.w(TAG, "micSink.success: ${e.message}") }
                }
            } else if (micChunkCount == 1L || micChunkCount % 50L == 0L) {
                Log.d(TAG, "mic chunk #$micChunkCount DROPPED: no Dart subscriber")
            }
        }
    }

    // -------- Speaker + lipsync push --------

    private fun startSpeaker() {
        val minBuf = AudioTrack.getMinBufferSize(
            SPK_SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        // Reserve ~5 s of audio. OpenAI Realtime generates audio at
        // ~1.3-1.5× real-time and ships chunks as fast as the model can
        // emit, so a 10 s reply can pile up ~3 s of headroom in the
        // ring buffer before the consumer drains it. A 1 s buffer
        // overflowed and dropped the tail (audio mumbled after 1 s).
        // 30 s exceeded an AudioFlinger limit on Z Fold 5 and silently
        // produced an inert track (no playback at all). 5 s sits in
        // the safe band on every Android device we have data for.
        val bufBytes = (minBuf.coerceAtLeast(SPK_SAMPLE_RATE * 2 * 5))
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val fmt = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SPK_SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .build()
        // Drop PERFORMANCE_MODE_LOW_LATENCY: the framework constrains
        // sample rates in that mode and may silently coerce 24 kHz to
        // the device-native rate (48 kHz on Z Fold 5), playing each
        // sample at 2× speed. Default mode keeps the sample-rate
        // converter in path so 24 kHz plays as 24 kHz.
        val tr = AudioTrack.Builder()
            .setAudioAttributes(attrs)
            .setAudioFormat(fmt)
            .setBufferSizeInBytes(bufBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        if (tr.state != AudioTrack.STATE_INITIALIZED) {
            tr.release()
            throw IllegalStateException("AudioTrack state=${tr.state}")
        }
        Log.i(TAG, "speaker init: requested=${bufBytes}B " +
                   "actualFrames=${tr.bufferSizeInFrames} " +
                   "rate=${tr.sampleRate} playbackRate=${tr.playbackRate} " +
                   "minBuf=${minBuf}B")
        tr.play()
        speakerTrack = tr
        // Pre-fill ~200 ms of silence so the AudioTrack consumer has
        // cushion against scheduleAtFixedRate jitter in the compose
        // loop. Without this cushion, any tick that runs late by even
        // 5 ms causes an audible click/gap. The cushion shifts audio
        // playback back by 200 ms, which we don't compensate in the
        // lipsync side — the result is lipsync leads audio by ~200 ms.
        // Trade A/V offset for clean audio; we'll address the offset
        // separately via a lipsync delay.
        val prefillMs = 200
        val prefillBytes = SPK_SAMPLE_RATE * 2 * prefillMs / 1000
        tr.write(ByteArray(prefillBytes), 0, prefillBytes, AudioTrack.WRITE_NON_BLOCKING)
        // Hand the AudioTrack to the avatar's compose loop so it can
        // emit 40 ms of audio per tick in lockstep with each frame.
        // No separate writer thread — pacing is the compose loop's
        // 25 fps cadence, which guarantees A/V cannot drift.
        avatarEntry.attachedSpeakerTrack = tr
    }

    /// Receive a chunk of 24 kHz Int16 LE PCM bot audio from OpenAI
    /// Realtime. Drops it entirely while the local VAD believes the
    /// user is talking (same gate as the macOS path). Otherwise:
    ///   1. Hands the raw 24 kHz bytes to the AvatarEntry's paired
    ///      speaker queue. The compose loop pops 40 ms slices from
    ///      this queue per tick and writes them to AudioTrack — A/V
    ///      pairing happens at the compose loop, not here.
    ///   2. Resamples the chunk to 16 kHz Int16 and pushes it into
    ///      the lipsync queue so libessence's mel frontend has
    ///      audio to drive cluster_idx with.
    @Volatile private var spkChunksWritten: Long = 0L

    fun playSpeakerPCM24k(pcm: ByteArray) {
        if (isUserVoiceActive) return
        // Track this chunk's peak so the mic loop can echo-gate. Cheap
        // strided scan: every 16th sample is fine for 40 ms / 100 ms
        // chunks, the peak structure changes much slower than that.
        var spkPeak = 0
        var i = 0
        while (i + 1 < pcm.size) {
            val s = ((pcm[i].toInt() and 0xFF) or (pcm[i + 1].toInt() shl 8)).toShort().toInt()
            val a = if (s < 0) -s else s
            if (a > spkPeak) spkPeak = a
            i += 32  // every 16th Int16 sample
        }
        recentSpeakerPeak = spkPeak
        lastSpeakerWriteAtMs = System.currentTimeMillis()
        // Hand the raw 24 kHz bytes to the avatar's paired-speaker
        // queue. We pass a defensive copy because the source ByteArray
        // came from Flutter's FlutterStandardTypedData and we
        // shouldn't outlive its lifetime.
        avatarEntry.enqueueSpeaker24k(pcm.copyOf())
        spkChunksWritten++
        if (spkChunksWritten == 1L || spkChunksWritten % 50L == 0L) {
            Log.i(TAG, "speaker enqueue #$spkChunksWritten size=${pcm.size}")
        }

        // Lip-sync push: resample 24 kHz → 16 kHz Int16 (decimate 3:2)
        // via a single-tap linear interpolator. The avatar's mel
        // frontend tolerates linear-interpolated audio (verified bit-
        // exact-enough on the Swift side; cluster_idx unchanged for the
        // OpenAI TTS distribution).
        val nIn = pcm.size / 2
        val nOut = (nIn.toLong() * LIPSYNC_SAMPLE_RATE / SPK_SAMPLE_RATE).toInt()
        if (nOut <= 0) return
        val outShorts = ShortArray(nOut)
        // Decode input bytes into a working short array.
        val inShorts = ShortArray(nIn)
        var j = 0
        var k = 0
        while (j + 1 < pcm.size) {
            inShorts[k++] = ((pcm[j].toInt() and 0xFF) or (pcm[j + 1].toInt() shl 8)).toShort()
            j += 2
        }
        for (idx2 in 0 until nOut) {
            val srcPos = idx2.toDouble() * SPK_SAMPLE_RATE / LIPSYNC_SAMPLE_RATE
            val idx = srcPos.toInt()
            val frac = srcPos - idx
            val s0 = inShorts.getOrNull(idx)?.toInt() ?: 0
            val s1 = inShorts.getOrNull(idx + 1)?.toInt() ?: s0
            val v = (s0 + (s1 - s0) * frac).toInt()
            outShorts[idx2] = v.coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        avatarEntry.enqueueLipsync16kInt16(outShorts)
    }

    // -------- EventChannel.StreamHandler --------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        micSink.set(events)
        Log.i(TAG, "mic EventChannel: Dart subscribed")
    }

    override fun onCancel(arguments: Any?) {
        micSink.set(null)
        Log.i(TAG, "mic EventChannel: Dart cancelled")
    }
}
