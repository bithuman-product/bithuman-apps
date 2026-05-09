import AVFoundation
import Foundation

/// Common surface for the two TTS backends bithuman-cli uses:
///
/// - **Qwen3-TTS** (voice mode) — high-quality, supports voice
///   cloning. ~600 M params; too heavy to coexist with the avatar
///   engine on the same Metal queue.
/// - **Kokoro** (video mode) — small (~80 M params), preset voices
///   only, sounds slightly more "TTS-y" but lets the avatar engine
///   process audio concurrently without choking Qwen3's per-token
///   cadence.
///
/// Orchestrator and VoiceChat speak only to this protocol; the
/// concrete backend is chosen by VoiceChat based on whether the
/// avatar pipeline is enabled.
protocol TTSPlayer: Actor {
    /// Load the model + run any per-voice warm-up.
    func prewarm() async

    /// Synthesise `text` and stream the audio into the player. Caller
    /// awaits return when the SYNTHESIS pass finishes — playback may
    /// still be draining. End-of-utterance drain goes through
    /// `awaitDrain()`.
    @discardableResult
    func speak(_ text: String) async -> Bool

    /// Wait until every queued buffer has finished playing. Used by
    /// the orchestrator at end-of-turn so the state machine flips
    /// back to listening only after the bot has actually fallen silent.
    func awaitDrain() async

    /// Cancel any in-flight synthesis + drop queued buffers. Used by
    /// barge-in.
    func cancelAll() async

    /// Avatar fan-out hook. Each scheduled PCM buffer is also handed
    /// to the observer, in addition to playing through the speaker.
    /// `nil` detaches.
    func setPCMObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?)

    /// Configure whether to suppress direct speaker playback when an
    /// observer is set.
    ///
    /// - `true` (Expression default): the player calls the observer
    ///   AND skips its own `graph.schedulePlayback`. The observer
    ///   (AvatarAudioBridge) buffers audio and the FramePump replays
    ///   it in lockstep with rendered frames — playing twice would
    ///   echo.
    /// - `false` (Essence default): the player calls the observer AND
    ///   plays through the speaker normally. The observer
    ///   (EssencePCMBridge) just taps the audio for the runtime's
    ///   lipsync; speaker output is still required for the user to
    ///   hear the bot.
    ///
    /// Default is `true` for backwards compatibility — pre-Essence
    /// callers all wanted the suppress-speaker behavior.
    func setSuppressDirectPlaybackWhenObserved(_ suppress: Bool)

    /// Wrapper called around each `speak()` to pause downstream MLX
    /// consumers (the avatar engine) while the TTS owns the GPU.
    /// Only meaningful when both run MLX-on-Metal concurrently — the
    /// Kokoro backend sets this to nil since contention is negligible
    /// at its model size.
    func setGenerationGate(_ gate: (@Sendable (Bool) async -> Void)?)

    /// +1 the drain counter when an avatar-rendered chunk's audio
    /// is scheduled on the player by `VoiceChat.playAvatarAudio`.
    /// Pairs 1:1 with `notifyAvatarPlayedBuffer`. The TTS player's
    /// own `scheduleChunk` skips drain accounting in avatar mode
    /// because TTS chunks (~240 ms each) and avatar chunks
    /// (~960 ms each) don't have a 1:1 ratio — only the avatar-side
    /// pair is reliable.
    func notifyAvatarScheduledBuffer()

    /// −1 the drain counter when a previously-scheduled avatar
    /// audio buffer has fully drained from the player.
    func notifyAvatarPlayedBuffer()
}
