@preconcurrency import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXLMCommon

/// Qwen3-TTS (0.6B, 4-bit) via mlx-audio-swift. The only TTS backend
/// in this app — chosen because it auto-downloads its weights and
/// supports voice cloning, neither of which AVSpeechSynthesizer
/// (system voice installs are user-mediated only) or Kokoro
/// (preset-list only, no cloning) can match.
///
/// Streams PCM chunks as MLXArrays through `generateStream`; each
/// chunk is wrapped as an `AVAudioPCMBuffer` at the model's native
/// sample rate (typically 12 kHz) and handed to the shared AudioGraph
/// player, whose format converter handles the upsample to the 48 kHz
/// VP-IO output.
actor Qwen3TTSPlayer: TTSPlayer {
    private let graph: AudioGraph
    private let modelRepo: String
    private let voice: VoiceSelection

    private var model: Qwen3TTSModel?
    private var loadTask: Task<Void, Error>?
    private var srcFormat: AVAudioFormat?
    /// Reference audio + transcript captured on prewarm. Every speak()
    /// passes this same MLXArray instance, which flips the model from
    /// VoiceDesign mode (fresh speaker sampled each call — voice drifts
    /// sentence by sentence) into in-context-learning mode (speaker
    /// embedding cached by ObjectIdentity, voice is stable).
    private var cachedRefAudio: MLXArray?
    private var cachedRefText: String?

    private var cancelled = false
    /// Sentence-level pipelining: `speak` returns as soon as SYNTHESIS
    /// finishes for its utterance, not when playback has drained. This
    /// lets the orchestrator queue sentence N+1's synthesis while N is
    /// still audible, eliminating the ~0.5–1 s inter-sentence gap that
    /// an autoregressive TTS running at ~1× real-time would otherwise
    /// stamp between sentences. The orchestrator calls `awaitDrain()`
    /// at end-of-turn so the state flip back to `.listening` still
    /// waits for the last tail of audio.
    ///
    /// `totalPendingBuffers` accumulates across speak() calls — it's
    /// only decremented by `onBufferPlayed` and reset by `cancelAll`
    /// (via the completion callbacks fired when the player stops).
    private var totalPendingBuffers = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentStreamTask: Task<Void, Never>?

    /// Optional fan-out for the avatar pipeline. When set, every
    /// scheduled PCM chunk is also handed to this observer (in
    /// addition to being routed to the speaker via `AudioGraph`).
    /// Installed by `VoiceChat.start()` only when an avatar is
    /// configured — keeps the audio-only code path zero-overhead.
    private var pcmObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// When the observer is set, do we ALSO play through the speaker?
    /// `true` (default) suppresses direct playback (Expression — the
    /// FramePump replays the audio). `false` keeps direct playback
    /// (Essence — there's no FramePump; the observer just taps the
    /// audio for lipsync).
    private var suppressDirectPlaybackWhenObserved: Bool = true

    /// Install (or replace) the avatar fan-out observer. Pass `nil`
    /// to detach. Synchronous from the caller's perspective once the
    /// actor hop completes.
    func setPCMObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.pcmObserver = observer
    }

    func setSuppressDirectPlaybackWhenObserved(_ suppress: Bool) {
        self.suppressDirectPlaybackWhenObserved = suppress
    }

    /// Optional gate fired around each `speak()` to pause downstream
    /// MLX consumers (the avatar engine) while Qwen3 owns the GPU.
    /// Without this, the avatar engine's wav2vec2 + DiT dispatches
    /// contend with Qwen3 on the same Metal command queue and
    /// Qwen3's per-token output spacing becomes irregular —
    /// audible as chopped speech.
    private var generationGate: (@Sendable (Bool) async -> Void)?

    func setGenerationGate(_ gate: (@Sendable (Bool) async -> Void)?) {
        self.generationGate = gate
    }

    init(
        graph: AudioGraph,
        // 4-bit variant — user preference. Smaller download (~1 GB vs
        // 1.3 GB for 8-bit) and lower resident memory. Note: a
        // community benchmark suggested dequant overhead on Metal may
        // make 4-bit slightly slower end-to-end at this scale, but in
        // practice the quality and memory trade-off matters more here.
        modelRepo: String = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit",
        voice: VoiceSelection = .default
    ) {
        self.graph = graph
        self.modelRepo = modelRepo
        self.voice = voice
    }

    func prewarm() async {
        if model != nil && cachedRefAudio != nil { return }
        if loadTask == nil {
            let repo = modelRepo
            let voice = self.voice
            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let m = try await Qwen3TTSModel.fromPretrained(repo)
                await self?.install(model: m)
                try await self?.warmUpVoice(model: m, voice: voice)
            }
        }
        _ = try? await loadTask?.value
    }

    /// Hot-swap the cached speaker reference. Effective on the next
    /// ``speak`` call — utterances already in flight finish on the old
    /// voice. The model itself stays loaded; only the speaker
    /// embedding cache is replaced. Use this for the Essence right-
    /// click "Change voice…" menu so the user can switch to a Qwen3
    /// preset (canned speaker pool) or clone from a fresh audio file
    /// at runtime without bouncing the chat.
    ///
    /// Throws on decode/generation failures during the swap; on
    /// failure the previous reference stays in place so the chat
    /// keeps working.
    func setVoiceSelection(_ newVoice: VoiceSelection) async throws {
        guard let model else {
            // Not warmed yet — install will pick up the new voice when
            // prewarm runs. (Shouldn't happen in practice; the menu is
            // hidden until the splash hands off to the avatar window.)
            return
        }
        try await warmUpVoice(model: model, voice: newVoice)
    }

    private func install(model: Qwen3TTSModel) {
        self.model = model
        // Qwen3-TTS reports its native rate — usually 12 kHz — via
        // `sampleRate`. We build an AVAudioFormat once and reuse it for
        // every chunk; the graph's format converter handles the 12 →
        // 48 kHz resample into the VP-IO output.
        let rate = Double(model.sampleRate)
        self.srcFormat = AVAudioFormat(
            standardFormatWithSampleRate: rate,
            channels: 1
        )
    }

    /// Cache an MLXArray of reference samples + matching transcript.
    /// Every later speak() passes this same MLXArray instance to
    /// `generateStream`, so the library's speaker-embedding cache
    /// (keyed on `ObjectIdentifier(refAudio)`) hits and the voice
    /// stays stable across utterances.
    ///
    /// Three sources, one per VoiceSelection case:
    ///   - .default → bundled `Resources/ref.wav` (zero-cost decode).
    ///   - .clone(url, txt) → user-supplied audio file at runtime.
    ///   - .preset(name) → run a one-shot generation with the preset
    ///     name as the `voice` instruct, capture its output as a
    ///     reference, then reuse it. This converts the otherwise-
    ///     drifty preset path into a stable cloned-voice path.
    private func warmUpVoice(model: Qwen3TTSModel, voice: VoiceSelection) async throws {
        switch voice {
        case .default:
            // Bundled audio is guaranteed to exist (resource processed
            // by SPM at build time); a decode failure here is a build
            // configuration bug, not a user error.
            guard let (audio, text) = Self.loadBundledReference(targetRate: model.sampleRate) else {
                Log.tts.error("qwen3 warm-up: bundled ref.wav unreadable; this is a build issue.")
                FileHandle.standardError.write(Data(
                    "error: bundled Resources/ref.wav couldn't be decoded. Rebuild may be corrupt.\n".utf8
                ))
                exit(2)
            }
            Log.tts.info("qwen3 warm-up: bundled ref.wav (\(text.prefix(60), privacy: .public))")
            self.cachedRefAudio = audio
            self.cachedRefText = text

        case .clone(let url, let transcript):
            // main.swift already validated the file exists; an actual
            // decode failure means it's not a readable audio format.
            guard let samples = Self.decodeMonoFloat(at: url, targetRate: Double(model.sampleRate)) else {
                FileHandle.standardError.write(Data(
                    "error: couldn't decode \(url.path) as audio. Use a WAV / AIFF / M4A file.\n".utf8
                ))
                exit(2)
            }
            Log.tts.info("qwen3 warm-up: --clone-voice \(url.lastPathComponent, privacy: .public)")
            print("🗣️  cloning voice from \(url.path)…")
            self.cachedRefAudio = MLXArray(samples)
            self.cachedRefText = transcript

        case .preset(let name):
            // Generate one short utterance with the preset name as the
            // voice param, then cache that audio as the reference for
            // every subsequent call. A fresh model.generate without a
            // refAudio samples randomly from the preset's distribution,
            // so we lock the timbre by reusing the first sample's
            // output instead of regenerating each turn.
            let refText = "Hello there. I'm ready to help you today."
            print("🗣️  warming up preset voice '\(name)' (~2 s)…")
            let start = Date()
            let refAudio = try await model.generate(
                text: refText,
                voice: name,
                refAudio: nil,
                refText: nil,
                language: nil,
                generationParameters: GenerateParameters()
            )
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            Log.tts.info("qwen3 warm-up: preset '\(name, privacy: .public)' in \(ms, privacy: .public)ms")
            self.cachedRefAudio = refAudio
            self.cachedRefText = refText
        }
    }

    /// Read ref.wav and ref.txt from the SPM resource bundle, resample
    /// the audio to the model's native sample rate (typically 12 kHz
    /// for Qwen3-TTS-12Hz), and return them as an MLXArray + transcript.
    /// Returns nil on any failure so the caller can fall back.
    private static func loadBundledReference(targetRate: Int) -> (audio: MLXArray, text: String)? {
        guard
            let wavURL = Bundle.module.url(forResource: "ref", withExtension: "wav"),
            let txtURL = Bundle.module.url(forResource: "ref", withExtension: "txt"),
            let transcript = try? String(contentsOf: txtURL, encoding: .utf8),
            let samples = decodeMonoFloat(at: wavURL, targetRate: Double(targetRate))
        else {
            return nil
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return (MLXArray(samples), trimmed)
    }

    /// Decode a WAV file into a mono Float32 sample array at the
    /// requested sample rate. Resamples with AVAudioConverter — the
    /// VP-IO graph's converter handles its own rate matching downstream,
    /// but the speaker encoder expects the reference at the model's
    /// native rate.
    private static func decodeMonoFloat(at url: URL, targetRate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        guard let target = AVAudioFormat(
            standardFormatWithSampleRate: targetRate,
            channels: 1
        ) else { return nil }

        guard let inBuf = AVAudioPCMBuffer(
            pcmFormat: inFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { return nil }
        do { try file.read(into: inBuf) } catch { return nil }

        // Same-format fast path
        if inFormat.sampleRate == targetRate, inFormat.channelCount == 1, let ptr = inBuf.floatChannelData?[0] {
            let n = Int(inBuf.frameLength)
            return Array(UnsafeBufferPointer(start: ptr, count: n))
        }

        guard let converter = AVAudioConverter(from: inFormat, to: target) else { return nil }
        let ratio = targetRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error { return nil }
        guard let ptr = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
    }


    @discardableResult
    func speak(_ text: String) async -> Bool {
        await prewarm()
        guard let model, let srcFormat, let refAudio = cachedRefAudio, let refText = cachedRefText else {
            Log.tts.error("Qwen3 TTS not ready")
            return false
        }

        // Reset `cancelled` so a fresh speak after a prior cancelAll is
        // allowed. The leftover-buffer accounting is safe: cancelAll
        // calls graph.cancelPlayback which fires the completion
        // callbacks for any queued buffers, draining
        // totalPendingBuffers back to zero through onBufferPlayed.
        cancelled = false
        await graph.enablePlayback()

        // Pause the avatar engine's DiT dispatches for the duration
        // of this synthesis. They share a Metal command queue with
        // Qwen3; without the gate, contention slows Qwen3 token
        // emission to an irregular ~50–800 ms cadence, which becomes
        // audible as chopped speech.
        await generationGate?(true)
        let gate = generationGate

        let result = await withCheckedContinuation { cont in
            // Capture the continuation in a single-shot box — this
            // speak()'s continuation resolves when ITS generateStream
            // loop ends (success or cancellation), NOT when playback
            // drains. That's the whole point of pipelining: sentence
            // N+1's synthesis starts while sentence N's audio is still
            // playing. End-of-turn drain is handled separately by
            // awaitDrain().
            let box = ContinuationBox(cont: cont)
            // Run generateStream in a Task so cancelAll can cancel it.
            // Pass the cached refAudio + refText every call — the
            // library's in-context-learning cache keys on MLXArray
            // object identity, so the same reference locks the
            // speaker embedding across utterances. `voice: nil` tells
            // the model to derive everything from the reference.
            currentStreamTask = Task { [weak self] in
                guard let self else { box.resolve(false); return }
                do {
                    // streamingInterval=0.24 s ≈ 3 tokens at 12.5 Hz.
                    // Conservative middle between the 0.32 s benchmark
                    // sweet spot and the 0.16 s value that produced
                    // chunk underruns ("zzz" buzz + dropped sentences).
                    // 50% larger than the broken value, 75% of the
                    // safe value — should cut ~80 ms off first-audio
                    // latency without re-tripping the underrun bug.
                    // Revert to 0.32 if buzzing reappears.
                    for try await event in model.generateStream(
                        text: text,
                        voice: nil,
                        refAudio: refAudio,
                        refText: refText,
                        language: nil,
                        generationParameters: GenerateParameters(),
                        streamingInterval: 0.24
                    ) {
                        try Task.checkCancellation()
                        if case .audio(let chunk) = event {
                            await self.scheduleChunk(chunk, srcFormat: srcFormat)
                        }
                    }
                    box.resolve(true)
                } catch is CancellationError {
                    box.resolve(false)
                } catch {
                    Log.tts.error("qwen3 stream: \(error.localizedDescription, privacy: .public)")
                    box.resolve(false)
                }
            }
        }

        // Release the avatar gate so it can drain its pending
        // audio queue (via DiT dispatches) now that the GPU is free.
        await gate?(false)
        return result
    }

    /// Single-shot wrapper so we can resume the continuation exactly
    /// once from either the stream-finished path or a catch.
    private final class ContinuationBox: @unchecked Sendable {
        private var cont: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()
        init(cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
        func resolve(_ value: Bool) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private func scheduleChunk(_ chunk: MLXArray, srcFormat: AVAudioFormat) async {
        if cancelled { return }
        guard let pcm = Self.makePCMBuffer(from: chunk, format: srcFormat) else { return }
        pcmObserver?(pcm)
        if pcmObserver != nil, suppressDirectPlaybackWhenObserved {
            // Expression avatar mode: the FramePump plays each
            // rendered chunk's paired audio in lockstep with the
            // frame display. Suppress the direct speaker route here
            // — playing twice would echo. Drain accounting is owned
            // by the avatar path (`VoiceChat.playAvatarAudio` →
            // `notifyAvatarScheduledBuffer`); incrementing here
            // would double-count (TTS produces ~5 chunks per avatar
            // chunk).
            //
            // For Essence avatar mode (`suppressDirectPlaybackWhenObserved`
            // = false) the observer just taps the audio for lipsync;
            // there's no FramePump, so we still play directly through
            // the speaker so the user hears the bot. Drain accounting
            // is the same as a no-avatar session in that case.
            return
        }
        totalPendingBuffers += 1
        await graph.schedulePlayback(pcm) { [weak self] in
            guard let self else { return }
            Task { await self.onBufferPlayed() }
        }
    }

    /// +1 the drain counter from the avatar-runloop side at the
    /// moment a chunk's audio is scheduled on the player.
    func notifyAvatarScheduledBuffer() {
        totalPendingBuffers += 1
    }

    /// −1 the drain counter when that scheduled buffer has fully
    /// drained from the player.
    func notifyAvatarPlayedBuffer() {
        onBufferPlayed()
    }

    private func onBufferPlayed() {
        totalPendingBuffers -= 1
        if totalPendingBuffers <= 0 {
            totalPendingBuffers = 0
            resolveDrainWaiters()
        }
    }

    func awaitDrain() async {
        if totalPendingBuffers <= 0 { return }
        await withCheckedContinuation { cont in
            drainWaiters.append(cont)
        }
    }

    private func resolveDrainWaiters() {
        let w = drainWaiters
        drainWaiters.removeAll()
        for cont in w { cont.resume() }
    }

    func cancelAll() async {
        cancelled = true
        currentStreamTask?.cancel()
        currentStreamTask = nil
        // cancelPlayback fires completion callbacks for queued buffers,
        // which decrement totalPendingBuffers via onBufferPlayed and
        // naturally resolve any drainWaiters. Explicitly resolve below
        // as a belt-and-braces in case there were no queued buffers at
        // cancel time (no callbacks → drainWaiters would sit forever).
        await graph.cancelPlayback(fadeMillis: 1)
        totalPendingBuffers = 0
        resolveDrainWaiters()
    }

    /// Convert a 1-D Float32 MLXArray of samples into an
    /// AVAudioPCMBuffer. The chunk shape from Qwen3-TTS is a flat
    /// sample vector at `model.sampleRate`; we copy it into a mono
    /// Float32 AVAudioPCMBuffer and let AudioGraph's converter handle
    /// the upsample to the VP-IO rate.
    private static func makePCMBuffer(from chunk: MLXArray, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = chunk.asArray(Float.self)
        guard !samples.isEmpty else { return nil }
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        if let ptr = buf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                ptr.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buf
    }
}
