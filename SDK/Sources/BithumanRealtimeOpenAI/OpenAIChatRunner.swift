// Text-mode entry point that drives the OpenAI Chat Completions
// API instead of the on-device LLM. Used by `bithuman-cli text`
// when an `OPENAI_API_KEY` is available (and `--local` wasn't
// passed). Stays in `BithumanRealtimeOpenAI` rather than the
// realtime client because the wire format is plain SSE — no
// WebRTC, no libwebrtc, no audio. Reusing the module just means
// callers can `import BithumanRealtimeOpenAI` once for both voice
// and text cloud paths.
//
// Wire format: POST `https://api.openai.com/v1/chat/completions`
// with `stream: true`. Server returns Server-Sent Events; each
// `data: {…}` line is a JSON chunk with a `choices[0].delta.content`
// string we accumulate into the bot's reply. Final event is
// `data: [DONE]`.

import Foundation

/// Run an interactive text chat loop until EOF on stdin.
///
/// `instructions` becomes the system prompt; `nil` falls back to a
/// short helpful-assistant prompt that matches what the local
/// pipeline does. `model` defaults to `gpt-4o-mini` — cheap, fast,
/// good enough for casual chat. Bigger models can be requested via
/// `--openai-model` (we forward it).
public func runOpenAIChat(
    apiKey: String,
    model: String,
    instructions: String? = nil,
    verbose: Bool = false
) async throws {
    let prompt = instructions
        ?? "You are a helpful, friendly assistant. Keep replies concise."

    // Conversation history kept as a `[message]` array so each turn
    // includes the prior context. Bounded only by the model's
    // context window (silently truncated on the server side); a
    // long-running session may eventually push out early turns.
    var messages: [[String: Any]] = [
        ["role": "system", "content": prompt],
    ]

    let bold = "\u{1B}[1m"
    let dim = "\u{1B}[2m"
    let cyan = "\u{1B}[36m"
    let magenta = "\u{1B}[35m"
    let reset = "\u{1B}[0m"
    let mePrefix = "\(cyan)[me]\(reset)"
    let botPrefix = "\(magenta)[bitHuman]\(reset)"

    print("\u{1B}[3J\u{1B}[2J\u{1B}[H", terminator: "")
    print("\(dim)\(String(repeating: "━", count: 60))\(reset)")
    print("")
    print("  \(bold)bithuman-cli\(reset)  \(dim)·  text chat over OpenAI\(reset)")
    print("  \(dim)by\(reset) \(bold)bitHuman Inc.\(reset)  \(dim)·  https://www.bithuman.ai\(reset)")
    print("")
    print("  \(dim)model:\(reset)  \(cyan)\(model)\(reset)")
    if instructions != nil {
        print("  \(dim)prompt:\(reset) \(dim)custom (via --prompt)\(reset)")
    }
    print("")
    print("  \(dim)type a message and press Enter · ctrl-d or `quit` to exit\(reset)")
    print("")
    print("\(dim)\(String(repeating: "━", count: 60))\(reset)")
    print("")

    while true {
        print("\(mePrefix) ", terminator: "")
        guard let line = readLine() else {
            // EOF / Ctrl-D — newline keeps the shell prompt clean.
            print("")
            return
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if trimmed == "quit" || trimmed == "exit" || trimmed == ":q" {
            print("")
            return
        }

        messages.append(["role": "user", "content": trimmed])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            print("\(dim)error: couldn't encode request\(reset)\n")
            continue
        }

        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        // Blank line + bot prefix on its own visual block — gives
        // each turn breathing room so a long reply doesn't run flush
        // against the user's prompt.
        print("")
        print("\(botPrefix) ", terminator: "")
        fflush(stdout)

        var assembled = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                print("\n\(dim)error: HTTP \(http.statusCode)\(reset)\n")
                continue
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                if payload.isEmpty { continue }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let token = delta["content"] as? String
                else {
                    if verbose, !payload.isEmpty {
                        FileHandle.standardError.write(Data("(unparsed: \(payload))\n".utf8))
                    }
                    continue
                }
                print(token, terminator: "")
                fflush(stdout)
                assembled += token
            }
        } catch {
            print("\n\(dim)error: \(error.localizedDescription)\(reset)\n")
            continue
        }
        // Trailing blank line so the next `[me]` prompt has a visual
        // separator from the just-finished reply.
        print("")
        print("")
        if !assembled.isEmpty {
            messages.append(["role": "assistant", "content": assembled])
        }
    }
}
