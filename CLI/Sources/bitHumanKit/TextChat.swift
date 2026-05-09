import Foundation

/// Text-only chat. Read user lines from stdin, stream replies to
/// stdout. No audio engine, no ASR, no TTS, no avatar — just the LLM.
///
/// Used by `bithuman-cli text`. The killer use case is dev / scripting:
/// pipe a prompt in, capture the reply out:
///
///     echo "summarise this:" | bithuman-cli text --prompt @system.md
///
/// Or interactively:
///
///     bithuman-cli text
///     > what's a fun macOS shell trick?
///     🤖 Try `pbcopy` and `pbpaste`…
///
/// Honours `VoiceChatConfig.systemPrompt`. Other voice-only fields
/// (`localeIdentifier`, `voice`) are ignored — text mode has no use
/// for them.
@MainActor
public final class TextChat {
    private let config: VoiceChatConfig
    private let llm: LLMClient

    public init(config: VoiceChatConfig = VoiceChatConfig()) {
        self.config = config
        self.llm = LLMClient(
            instructions: composeLLMInstructions(config.systemPrompt ?? defaultSystemPrompt),
            bootProgress: config.bootProgress
        )
    }

    /// Boot the LLM and run the readline loop. Returns when stdin
    /// closes (EOF, Ctrl-D) or the process is interrupted.
    public func start() async throws {
        try Preflight.run(.text)

        // Status to stderr so `bithuman-cli text | grep ...` and
        // similar shell pipelines see a clean stdout stream. When a
        // ``BootProgress`` is wired we let its renderer (e.g.,
        // ``TerminalProgressRenderer``) own the loading line so the
        // user sees a unified progress UI instead of a static banner
        // followed by a separate `📥` bar.
        if config.bootProgress == nil {
            FileHandle.standardError.write(Data(
                "loading on-device LLM (Gemma 4 E2B 4-bit, ~2 GB first run)…\n".utf8
            ))
        }
        await llm.prewarm()

        // Detect TTY vs piped stdin. Interactive use gets the
        // bitHuman-branded banner + `[me]` / `[bitHuman]` labels —
        // matching the cloud text path so recordings are
        // interchangeable. Piped use stays clean for shell
        // composition (no banner, no prompt prefix, no colour).
        let interactive = isatty(fileno(stdin)) != 0
        let bold = "\u{1B}[1m"
        let dim = "\u{1B}[2m"
        let cyan = "\u{1B}[36m"
        let magenta = "\u{1B}[35m"
        let reset = "\u{1B}[0m"
        let mePrefix = "\(cyan)[me]\(reset)"
        let botPrefix = "\(magenta)[bitHuman]\(reset)"

        if interactive {
            let banner = """

            \(dim)\(String(repeating: "━", count: 60))\(reset)

              \(bold)bithuman-cli\(reset)  \(dim)·  text chat (on-device)\(reset)
              \(dim)by\(reset) \(bold)bitHuman Inc.\(reset)  \(dim)·  https://www.bithuman.ai\(reset)

              \(dim)backend:\(reset) \(cyan)Gemma 4 E2B 4-bit\(reset) \(dim)(local)\(reset)

              \(dim)type a message and press Enter · ctrl-d or `quit` to exit\(reset)

            \(dim)\(String(repeating: "━", count: 60))\(reset)


            """
            FileHandle.standardError.write(Data(banner.utf8))
        }

        while true {
            if interactive {
                print("\(mePrefix) ", terminator: "")
                fflush(stdout)
            }
            guard let line = readLine() else {
                if interactive { print("") }
                return
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if interactive, ["quit", "exit", ":q"].contains(trimmed.lowercased()) {
                print("")
                return
            }

            if interactive {
                print("")
                print("\(botPrefix) ", terminator: "")
                fflush(stdout)
            }
            do {
                let stream = await llm.deltas(for: trimmed)
                for try await delta in stream {
                    print(delta, terminator: "")
                    fflush(stdout)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "\n\(dim)error: \(error.localizedDescription)\(reset)\n".utf8
                ))
            }
            print("")
            if interactive { print("") }  // breathing room between turns
        }
    }
}
