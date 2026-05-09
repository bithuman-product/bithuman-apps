// SiriTTSPlayer — system AVSpeechSynthesizer-backed TTS for iOS.
//
// Why exists: on-device TTS without keeping a 600 M-param Qwen3-TTS or
// 80 M Kokoro model resident in our process. The system synthesizer
// runs in `com.apple.speech.speechsynthesisd` (or similar) — zero
// footprint in our app's address space. On iPhone where we're up
// against a ~6 GB per-app jetsam ceiling, that's ~700 MB of headroom
// we get for free.
//
// Compromises:
//   - Voice catalog is whatever the user has installed under
//     Settings → Accessibility → Spoken Content → Voices. The
//     "premium" Siri voices need to be downloaded (large, one-time).
//   - No voice cloning. Whatever the system has, that's what you get.
//   - First-token latency is slightly higher than Kokoro/Qwen3 (the
//     system service has its own warm-up). Acceptable for chat.
//
// Routing matches the existing TTSPlayer protocol: synthesised PCM
// goes to `AudioGraph.schedulePlayback` for speaker output (so AEC
// works through VP-IO), AND to the per-instance PCM observer for the
// Essence runtime's lipsync sampler.
//
// iOS-only — `AVSpeechSynthesizer.write(_:toBufferCallback:)` exists
// on macOS too but the existing Mac/iPad apps already have higher-
// quality MLX-driven TTS, so we keep this build-specific.

#if canImport(UIKit)
import AVFoundation
import Foundation

actor SiriTTSPlayer: TTSPlayer {

    // MARK: - Construction

    private let graph: AudioGraph
    private let voice: AVSpeechSynthesisVoice?
    private let synth = AVSpeechSynthesizer()

    /// PCM observer set by VoiceChat — fans out audio to the Essence
    /// runtime's lipsync sampler.
    private var pcmObserver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Whether to skip `graph.schedulePlayback` when an observer is set.
    /// Defaults to `true` for parity with the other backends. Essence
    /// flips it false so the user actually hears the bot.
    private var suppressDirectPlaybackWhenObserved: Bool = true

    /// Player drain counter — incremented when a buffer is scheduled,
    /// decremented when the player has played it. `awaitDrain()` waits
    /// for this to hit zero. Without it the orchestrator flips back to
    /// `.listening` while the system synth is still speaking.
    private var pendingPlaybackCount: Int = 0
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []

    /// Tracks whether the most-recent `speak` was cancelled. Per-call
    /// flag rather than a global cancel — a barge-in stops the current
    /// utterance, but the next `speak` after that should run normally.
    private var cancelled: Bool = false

    /// Pick a "pleasant" default if the caller doesn't specify one.
    /// `AVSpeechSynthesisVoice(language: "en-US")` returns the system
    /// default for that locale — Samantha or Aaron on most US devices.
    init(graph: AudioGraph, voiceIdentifier: String? = nil) {
        self.graph = graph
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            self.voice = v
        } else {
            self.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
    }

    // MARK: - TTSPlayer

    func prewarm() async {
        // System synthesizer is daemonised; nothing to load in-process.
    }

    @discardableResult
    func speak(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        cancelled = false
        await graph.enablePlayback()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Capture the values we'll need inside the (non-isolated)
        // write callback.
        let observerSnapshot = pcmObserver
        let suppressSnapshot = suppressDirectPlaybackWhenObserved
        let graphRef = graph
        let selfBox = SelfBox(player: self)

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let continuationBox = ContinuationBox<Bool>(cont)

            synth.write(utterance) { buffer in
                // The callback fires on a background thread. We hop to
                // the actor for any state mutation.
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    // Not PCM (shouldn't happen for AVSpeechUtterance,
                    // but be defensive). Treat as end-of-utterance.
                    continuationBox.resumeIfPending(true)
                    return
                }

                if pcm.frameLength == 0 {
                    // End-of-utterance signal from the system synth.
                    continuationBox.resumeIfPending(true)
                    return
                }

                // Fan out to the Essence PCM observer (lipsync sampler).
                observerSnapshot?(pcm)

                // Schedule for speaker playback unless suppressed (the
                // Expression-style avatar pipeline handles its own
                // chunked playback through FramePump).
                if !(observerSnapshot != nil && suppressSnapshot) {
                    Task { [graphRef, selfBox] in
                        await selfBox.player.incrementPending()
                        graphRef.schedulePlayback(pcm) {
                            Task { await selfBox.player.decrementPending() }
                        }
                    }
                }
            }
        }
    }

    func awaitDrain() async {
        // If everything we scheduled is gone, return immediately.
        if pendingPlaybackCount == 0 && !synth.isSpeaking { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainContinuations.append(cont)
        }
    }

    func cancelAll() async {
        cancelled = true
        synth.stopSpeaking(at: .immediate)
        // The graph-side drop is what actually silences output —
        // pendingPlaybackCount is decremented by the player's
        // callback. Force-resume any drainers waiting on us so the
        // orchestrator's barge-in path can flip to .listening.
        let waiters = drainContinuations
        drainContinuations.removeAll()
        for c in waiters { c.resume() }
        pendingPlaybackCount = 0
    }

    func setPCMObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.pcmObserver = observer
    }

    func setSuppressDirectPlaybackWhenObserved(_ suppress: Bool) {
        self.suppressDirectPlaybackWhenObserved = suppress
    }

    func setGenerationGate(_ gate: (@Sendable (Bool) async -> Void)?) {
        // System synth isn't on Metal — no MLX generation to gate.
    }

    func notifyAvatarScheduledBuffer() {
        pendingPlaybackCount += 1
    }

    func notifyAvatarPlayedBuffer() {
        pendingPlaybackCount = max(0, pendingPlaybackCount - 1)
        if pendingPlaybackCount == 0 && !synth.isSpeaking {
            let waiters = drainContinuations
            drainContinuations.removeAll()
            for c in waiters { c.resume() }
        }
    }

    // MARK: - Internal helpers

    fileprivate func incrementPending() {
        pendingPlaybackCount += 1
    }

    fileprivate func decrementPending() {
        pendingPlaybackCount = max(0, pendingPlaybackCount - 1)
        if pendingPlaybackCount == 0 && !synth.isSpeaking {
            let waiters = drainContinuations
            drainContinuations.removeAll()
            for c in waiters { c.resume() }
        }
    }
}

/// Sendable handle to the actor from the non-isolated synth callback.
private final class SelfBox: @unchecked Sendable {
    let player: SiriTTSPlayer
    init(player: SiriTTSPlayer) { self.player = player }
}

/// Resume-once wrapper for a `CheckedContinuation`. AVSpeechSynthesizer's
/// write callback fires multiple times per utterance; only the final
/// (zero-length) buffer should fulfill the speak() future.
private final class ContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ c: CheckedContinuation<T, Never>) { self.cont = c }
    func resumeIfPending(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

#endif // canImport(UIKit)
