@preconcurrency import AVFoundation

/// Unified audio graph for the whole pipeline.
///
/// One AVAudioEngine owns both the mic tap and the TTS player node,
/// with `setVoiceProcessingEnabled(true)` on the input. This is what
/// makes echo cancellation actually useful: the engine knows the
/// reference signal (what we're playing through the player node) and
/// removes it from the mic input. Keeping TTS on a separate
/// AVSpeechSynthesizer audio session would defeat that — the engine
/// couldn't see the reference signal, so AEC would have nothing to
/// subtract, and every TTS word would self-trigger barge-in.
public actor AudioGraph {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    /// Gate for schedulePlayback. Flipped false by cancelPlayback and
    /// true by enablePlayback. Without this, Tasks spawned from the
    /// synth's write() callback can land on the player node AFTER a
    /// barge-in has already faded+stopped it, and audio resumes — the
    /// bot appears to keep talking through an interrupt.
    private var playbackEnabled = true

    /// PCM buffers arriving from the mic with AEC/NS/AGC applied.
    public nonisolated let micBuffers: AsyncStream<AVAudioPCMBuffer>
    private nonisolated let micCont: AsyncStream<AVAudioPCMBuffer>.Continuation

    /// Per-tap RMS energy on the AEC'd mic channel (channel 0 of the
    /// VP-IO output). Because AEC subtracts the bot's own voice, any
    /// spike above ambient during TTS playback is the user talking —
    /// this is the fast barge-in signal that beats SpeechTranscriber's
    /// ~300 ms partial latency to audible cutoff.
    public nonisolated let micEnergy: AsyncStream<Float>
    private nonisolated let energyCont: AsyncStream<Float>.Continuation

    private var converter: AVAudioConverter?
    private var converterSrcFormat: AVAudioFormat?

    public init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.micBuffers = AsyncStream { cont = $0 }
        self.micCont = cont
        var econt: AsyncStream<Float>.Continuation!
        self.micEnergy = AsyncStream { econt = $0 }
        self.energyCont = econt
    }

    public func start() throws {
        let input = engine.inputNode
        let output = engine.outputNode

        // Enable VP on BOTH ends before any connections. Mic and speaker
        // are distinct devices on macOS (BuiltInMicrophone vs
        // BuiltInSpeaker); VP on both coalesces them into a single VP-IO
        // aggregate so AEC has the reference signal. If VP is enabled on
        // one side only, the two IO ends run at different sample rates
        // and engine.start() fails with kAudioUnitErr_FailedInitialization
        // (-10875) at outputNode.
        try input.setVoiceProcessingEnabled(true)
        try output.setVoiceProcessingEnabled(true)

        // Connect the player at the output's actual bus format.
        // `format: nil` would pull AVAudioPlayerNode's default (44.1 kHz),
        // which mismatches the VP-IO output (48 kHz) and also fails
        // kAUInitialize with -10875.
        let outBusFormat = output.inputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: output, format: outBusFormat)

        let tapFormat = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [micCont, energyCont] buf, _ in
            micCont.yield(buf)
            if let ptr = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n {
                    let s = ptr[i]
                    sum += s * s
                }
                let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
                energyCont.yield(rms)
            }
        }

        engine.prepare()
        try engine.start()
        self.playerFormat = player.outputFormat(forBus: 0)
        player.play()

        Log.audio.info("graph up: mic sr=\(tapFormat.sampleRate, privacy: .public) Hz ch=\(tapFormat.channelCount, privacy: .public), player sr=\(self.playerFormat?.sampleRate ?? 0, privacy: .public) Hz, vp=on")
    }

    /// Schedule a TTS PCM buffer for playback. Drops buffers while
    /// playback is disabled (between a cancelPlayback and the next
    /// enablePlayback) so a barge-in cannot be undone by a straggler
    /// buffer from a race-losing synth.write() callback. The optional
    /// onPlayed callback fires (off an audio thread) once the player
    /// has actually consumed the buffer — the caller is expected to
    /// hop back to its own actor. If the buffer is dropped (disabled
    /// or conversion fails), onPlayed fires synchronously so the
    /// caller's pending-count stays balanced.
    public func schedulePlayback(_ buffer: AVAudioPCMBuffer, onPlayed: (@Sendable () -> Void)? = nil) {
        guard playbackEnabled else { onPlayed?(); return }
        guard let converted = convertToPlayerFormat(buffer) else { onPlayed?(); return }
        if let onPlayed {
            player.scheduleBuffer(converted, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                onPlayed()
            }
        } else {
            player.scheduleBuffer(converted, completionHandler: nil)
        }
    }

    /// Re-arm the player for a new utterance. Called by TTSPlayer at
    /// the top of each speak() so the first sentence of a post-barge-in
    /// reply plays normally. The volume is restored from the
    /// `cancelPlayback` fade-out, optionally with a quick fade-in to
    /// soften the very first chunk after a barge-in.
    func enablePlayback(fadeInMillis: Int = 12) async {
        playbackEnabled = true
        if !player.isPlaying { player.play() }
        // Quick volume ramp from 0 → 1 to soften the resumed audio's
        // attack — barely perceptible, but kills any micro-click that
        // would otherwise mark the resume point. Skip if volume is
        // already at 1 (i.e. we never actually faded out).
        if player.volume < 0.99 {
            let steps = 6
            let target: Float = 1.0
            let start = player.volume
            let stepDelayNs = UInt64(max(fadeInMillis, 1) * 1_000_000 / steps)
            for i in 1...steps {
                player.volume = start + (target - start) * Float(i) / Float(steps)
                try? await Task.sleep(nanoseconds: stepDelayNs)
            }
            player.volume = target
        }
    }

    /// Stop playback with a short linear volume ramp to avoid the
    /// audible click of a hard `stop()`. 15 ms is short enough that
    /// barge-in still feels instant but long enough to smooth the
    /// waveform to zero. Leaves the player stopped and disabled —
    /// enablePlayback() restarts it for the next utterance.
    func cancelPlayback(fadeMillis: Int = 1) async {
        playbackEnabled = false
        let steps = 6
        let startVolume = player.volume
        let stepDelayNs = UInt64(max(fadeMillis, 1) * 1_000_000 / steps)
        for i in 1...steps {
            player.volume = startVolume * (1.0 - Float(i) / Float(steps))
            try? await Task.sleep(nanoseconds: stepDelayNs)
        }
        player.stop()
        // `stop()` halts FUTURE buffer rendering but lets the
        // current buffer finish — at 960 ms avatar chunks that
        // means up to ~1 s of audio tail after barge-in. `reset()`
        // discards in-flight render state so the speaker actually
        // goes silent within ~10 ms. Voice-mode 240 ms TTS chunks
        // didn't notice this, but video-mode chunks do.
        player.reset()
        player.volume = startVolume
    }

    public func stop() {
        micCont.finish()
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: format conversion

    private func convertToPlayerFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = playerFormat else { return nil }
        let src = buffer.format
        if src.sampleRate == target.sampleRate,
           src.channelCount == target.channelCount,
           src.commonFormat == target.commonFormat {
            return buffer
        }
        if converter == nil || converterSrcFormat != src {
            converter = AVAudioConverter(from: src, to: target)
            converterSrcFormat = src
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / src.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var err: NSError?
        var delivered = false
        let status = converter.convert(to: out, error: &err) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.audio.error("tts convert: \(err?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return out
    }
}
