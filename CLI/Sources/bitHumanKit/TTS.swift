import Foundation

/// How the voice for the Qwen3-TTS backend was specified.
///
///  - `.default`: use the bundled `Sources/VoiceChat/Resources/ref.wav`
///    + `ref.txt` for in-context-learning voice cloning. This is the
///    no-flag default and the most stable option — the speaker
///    embedding is extracted from the same audio every boot.
///  - `.preset(String)`: one of the model's known speaker names. The
///    canonical name (matching the Qwen3-TTS Base checkpoint training
///    set) is stored as-is here. `main.swift` validates and
///    canonicalises against `presetNames` before constructing this.
///  - `.clone(URL, String)`: user-supplied reference audio file +
///    matching transcript, loaded at boot, resampled to the model's
///    native rate, cached as `refAudio` for every subsequent
///    `generateStream` call.
public enum VoiceSelection: Sendable {
    case `default`
    case preset(String)
    case clone(referenceAudio: URL, transcript: String)

    /// Speaker presets the Qwen3-TTS Base / CustomVoice checkpoints
    /// are trained on. Anything not in this list won't match
    /// `canonicalPreset` and should be supplied as a `.clone`.
    public static let presetNames: [String] = [
        // English
        "Ryan", "Aiden",
        // Chinese
        "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric",
    ]

    /// Case-insensitive match against the canonical preset list.
    /// Returns the canonical capitalisation expected by the model
    /// (e.g. `"ryan"` → `"Ryan"`), or nil for no match.
    public static func canonicalPreset(matching input: String) -> String? {
        let lower = input.lowercased()
        return presetNames.first { $0.lowercased() == lower }
    }
}
