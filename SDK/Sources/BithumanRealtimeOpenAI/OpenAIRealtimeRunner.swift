// Library entry point for the OpenAI realtime voice-chat client.
//
// Invoked from `bithuman-cli` when the user passes `--openai` (or
// when the API key is auto-detected). The CLI parses its own flags
// + env vars, then calls ``runOpenAIRealtime`` here. Keeping the
// entry as a function (rather than a `@main` struct) means the same
// CLI binary covers both local and OpenAI voice modes — only the
// flag dispatches.
//
// Up-front this function validates the API key and the voice name
// before painting the banner, so the user gets clear feedback on
// "what just happened" instead of finding out 30 seconds later when
// the WebRTC handshake fails. Validation results are surfaced in
// the banner with a checkmark or warning.

import Foundation

/// Voices the OpenAI Realtime API accepts as of mid-2025. Used for
/// pre-launch warnings only (we don't reject unknown voices since
/// OpenAI rotates this list periodically — better to forward the
/// name and let the server reject it if it's truly bad). Sourced
/// from https://platform.openai.com/docs/guides/realtime.
let knownOpenAIVoices: Set<String> = [
    "alloy", "ash", "ballad", "coral", "echo",
    "sage", "shimmer", "verse",
    "marin", "cedar",  // 2025 additions
]

/// Run the OpenAI realtime voice-chat loop until Ctrl-C. Throws on
/// fatal connection errors (bad API key, network down, OpenAI 4xx).
///
/// `instructions` is sent to the server as the session's system
/// prompt. When `nil`, the backend's built-in default applies — a
/// short "helpful, friendly voice assistant" prompt.
public func runOpenAIRealtime(
    apiKey: String,
    model: String,
    voice: String,
    instructions: String? = nil,
    verbose: Bool
) async throws {
    let ui = TerminalUI()
    await ui.start()

    // Pre-launch validation. Cheap (~150 ms total) and gives the
    // user actionable feedback before any audio plumbing kicks in.
    let keyOK = await validateOpenAIKey(apiKey)
    let voiceKnown = knownOpenAIVoices.contains(voice.lowercased())

    await ui.printOpeningBanner(
        model: model,
        voice: voice,
        verbose: verbose,
        keyValidated: keyOK,
        voiceKnown: voiceKnown
    )

    if !keyOK {
        throw NSError(
            domain: "BithumanRealtimeOpenAI",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey:
                "OPENAI_API_KEY is invalid or revoked. Generate a new key at " +
                "https://platform.openai.com/api-keys and re-export it."]
        )
    }

    let client = RealtimeWebRTCClient(
        apiKey: apiKey,
        model: model,
        voice: voice,
        instructions: instructions,
        ui: ui,
        verbose: verbose
    )
    try await client.connect()
    try await client.runReceiveLoop()
}

/// HEAD-style check against `/v1/models`. The realtime endpoint
/// itself is WebRTC and won't tell us "bad key" without a full
/// handshake; this gives an upfront 200/401 signal in <200 ms.
private func validateOpenAIKey(_ key: String) async -> Bool {
    var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
    req.httpMethod = "GET"
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.timeoutInterval = 5
    do {
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    } catch {
        // Network errors (no internet, DNS down, etc.) — fail open
        // so the user can see whatever the WebRTC handshake error
        // looks like instead of a misleading "bad key" message.
        return true
    }
}
