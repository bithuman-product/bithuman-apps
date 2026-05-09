import Foundation
import Speech

/// Errors surfaced by `transcribeAudioFile`. All produce actionable
/// CLI messages; main.swift catches and routes through fatalUsage.
public enum AudioTranscribeError: Error, CustomStringConvertible, Sendable {
    case noRecognizer(String)
    case unavailable
    case recognitionFailed(String)
    case emptyResult

    public var description: String {
        switch self {
        case .noRecognizer(let id): return "no on-device speech recognizer for locale '\(id)'"
        case .unavailable:          return "speech recognizer is unavailable on this device"
        case .recognitionFailed(let detail): return "transcription failed: \(detail)"
        case .emptyResult:          return "transcription produced empty text"
        }
    }
}

/// Transcribe a local audio file with Apple's on-device speech
/// recognition. Used as the auto-fallback when --clone-voice is
/// supplied without an explicit --clone-text and no sibling .txt
/// exists. Result gets cached next to the audio file so subsequent
/// runs reuse it instead of re-transcribing.
///
/// Always runs locally (`requiresOnDeviceRecognition = true`); no
/// audio leaves the device. Caller must have already cleared the
/// `SFSpeechRecognizer.requestAuthorization` gate — typically through
/// `requestPermissions()` early in `bootstrap()`.
public func transcribeAudioFile(at url: URL, locale: Locale) async throws -> String {
    guard let recognizer = SFSpeechRecognizer(locale: locale) else {
        throw AudioTranscribeError.noRecognizer(locale.identifier)
    }
    guard recognizer.isAvailable else {
        throw AudioTranscribeError.unavailable
    }
    let request = SFSpeechURLRecognitionRequest(url: url)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false

    let text: String = try await withCheckedThrowingContinuation { cont in
        // SFSpeech's callback can fire multiple times; resumed flag
        // guards against trapping the continuation on the second hit.
        var resumed = false
        recognizer.recognitionTask(with: request) { result, error in
            guard !resumed else { return }
            if let error {
                resumed = true
                cont.resume(throwing: AudioTranscribeError.recognitionFailed(error.localizedDescription))
                return
            }
            guard let result, result.isFinal else { return }
            resumed = true
            cont.resume(returning: result.bestTranscription.formattedString)
        }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw AudioTranscribeError.emptyResult }
    return trimmed
}
