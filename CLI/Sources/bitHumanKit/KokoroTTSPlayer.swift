@preconcurrency import AVFoundation
import Foundation
@preconcurrency import MLX
@preconcurrency import MLXAudioCore
@preconcurrency import MLXAudioTTS
@preconcurrency import MLXLMCommon

/// Lean TTS for video mode — 80 M-param Kokoro coexists with the
/// avatar engine on Metal without throttling its per-token cadence.
/// No voice cloning (preset voices only) and no `refAudio` plumbing,
/// so it's roughly half the LOC of `Qwen3TTSPlayer`.
///
/// Default preset is `af_heart` (Kokoro's American-female reference
/// voice — neutral, natural). Override at construction.
actor KokoroTTSPlayer: TTSPlayer {
    /// Public preset list — exported so the CLI's right-click menu
    /// can populate a Voice picker from the one source of truth.
    /// Kokoro's full voice catalogue is much larger; this is a
    /// curated handful that sound natural for English chat.
    public static let voicePresets: [String] = [
        "af_heart", "af_alloy", "af_aoede", "af_kore",
        "am_adam", "am_michael", "am_echo",
        "bf_emma", "bm_george"
    ]

    private let graph: AudioGraph
    private let modelRepo: String
    private var voicePreset: String

    private var model: (any SpeechGenerationModel)?
    private var loadTask: Task<Void, Error>?
    private var srcFormat: AVAudioFormat?

    private var cancelled = false
    private var totalPendingBuffers = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentStreamTask: Task<Void, Never>?

    private var pcmObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// When the observer is set, do we ALSO play through the speaker?
    /// Mirrors `Qwen3TTSPlayer.suppressDirectPlaybackWhenObserved`.
    private var suppressDirectPlaybackWhenObserved: Bool = true
    /// Kokoro is small enough (~80 M params) that its Metal load
    /// doesn't meaningfully throttle the avatar engine, so the
    /// generation gate is a no-op by default. The protocol still
    /// requires a setter.
    private var generationGate: (@Sendable (Bool) async -> Void)?

    init(
        graph: AudioGraph,
        modelRepo: String = "mlx-community/Kokoro-82M-4bit",
        voicePreset: String = "af_heart"
    ) {
        self.graph = graph
        self.modelRepo = modelRepo
        self.voicePreset = voicePreset
    }

    /// Hot-swap the preset name. Effective on the next `speak()`.
    func setVoicePreset(_ preset: String) {
        self.voicePreset = preset
    }

    /// One-shot preview that speaks `text` in `preset` without
    /// touching the persistent `voicePreset` (so the user can audition
    /// voices without committing) and bypasses `pcmObserver` so video
    /// mode plays the preview through the speaker directly instead of
    /// hijacking the avatar's lipsync engine. Cancels any prior
    /// preview / utterance first so back-to-back clicks don't overlap.
    func preview(text: String, voice preset: String) async {
        await cancelAll()
        cancelled = false
        await prewarm()
        guard let model, let srcFormat else { return }
        await graph.enablePlayback()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in model.generateStream(
                    text: text,
                    voice: preset,
                    refAudio: nil,
                    refText: nil,
                    language: nil,
                    generationParameters: GenerateParameters(),
                    streamingInterval: 0.24
                ) {
                    try Task.checkCancellation()
                    if case .audio(let chunk) = event {
                        await self.schedulePreviewChunk(chunk, srcFormat: srcFormat)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                Log.tts.error("kokoro preview: \(error.localizedDescription, privacy: .public)")
            }
        }
        currentStreamTask = task
        _ = await task.value
    }

    private func schedulePreviewChunk(_ chunk: MLXArray, srcFormat: AVAudioFormat) async {
        if cancelled { return }
        guard let pcm = Self.makePCMBuffer(from: chunk, format: srcFormat) else { return }
        await graph.schedulePlayback(pcm) { }
    }

    func setPCMObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.pcmObserver = observer
    }

    func setSuppressDirectPlaybackWhenObserved(_ suppress: Bool) {
        self.suppressDirectPlaybackWhenObserved = suppress
    }

    func setGenerationGate(_ gate: (@Sendable (Bool) async -> Void)?) {
        self.generationGate = gate
    }

    func prewarm() async {
        if model != nil { return }
        if loadTask == nil {
            let repo = modelRepo
            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let m = try await TTS.loadModel(modelRepo: repo)
                await self?.install(model: m)
            }
        }
        _ = try? await loadTask?.value
    }

    private func install(model: any SpeechGenerationModel) {
        self.model = model
        let rate = Double(model.sampleRate)
        self.srcFormat = AVAudioFormat(
            standardFormatWithSampleRate: rate,
            channels: 1
        )
    }

    @discardableResult
    func speak(_ text: String) async -> Bool {
        await prewarm()
        guard let model, let srcFormat else {
            Log.tts.error("Kokoro TTS not ready")
            return false
        }
        cancelled = false
        await graph.enablePlayback()
        await generationGate?(true)
        let gate = generationGate
        // Snapshot the preset on the actor before crossing into the
        // detached Task — `voicePreset` is now `var` (mutable for
        // hot-swap) so reading it inside the Task would be a
        // cross-actor access.
        let preset = voicePreset

        let result = await withCheckedContinuation { cont in
            let box = ContinuationBox(cont: cont)
            currentStreamTask = Task { [weak self] in
                guard let self else { box.resolve(false); return }
                do {
                    for try await event in model.generateStream(
                        text: text,
                        voice: preset,
                        refAudio: nil,
                        refText: nil,
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
                    Log.tts.error("kokoro stream: \(error.localizedDescription, privacy: .public)")
                    box.resolve(false)
                }
            }
        }
        await gate?(false)
        return result
    }

    private final class ContinuationBox: @unchecked Sendable {
        private var cont: CheckedContinuation<Bool, Never>?
        private let lock = NSLock()
        init(cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
        func resolve(_ value: Bool) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    private func scheduleChunk(_ chunk: MLXArray, srcFormat: AVAudioFormat) async {
        if cancelled { return }
        guard let pcm = Self.makePCMBuffer(from: chunk, format: srcFormat) else { return }
        pcmObserver?(pcm)
        if pcmObserver != nil, suppressDirectPlaybackWhenObserved {
            // Expression avatar mode: drain accounting is owned by
            // the avatar path (see Qwen3TTSPlayer for the full
            // rationale). Incrementing per-TTS-chunk here would
            // over-count by ~4–5×; the counter would never drain.
            //
            // For Essence (`suppressDirectPlaybackWhenObserved` =
            // false) we keep the direct speaker route so the user
            // hears the bot — the observer only taps audio for
            // lipsync.
            return
        }
        totalPendingBuffers += 1
        await graph.schedulePlayback(pcm) { [weak self] in
            guard let self else { return }
            Task { await self.onBufferPlayed() }
        }
    }


    func notifyAvatarScheduledBuffer() {
        totalPendingBuffers += 1
    }

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
        let waiters = drainWaiters
        drainWaiters.removeAll()
        for c in waiters { c.resume() }
    }

    func cancelAll() async {
        cancelled = true
        currentStreamTask?.cancel()
        currentStreamTask = nil
        await graph.cancelPlayback(fadeMillis: 1)
        totalPendingBuffers = 0
        resolveDrainWaiters()
    }

    /// Wrap an MLXArray of Float samples as an AVAudioPCMBuffer at
    /// the model's native rate. Mirrors `Qwen3TTSPlayer.makePCMBuffer`.
    private static func makePCMBuffer(from chunk: MLXArray, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let samples = chunk.asArray(Float.self)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }
}
