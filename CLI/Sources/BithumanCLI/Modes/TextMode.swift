// `bithuman-cli text` — typed REPL.
//
// Two backends: the on-device Gemma path (`bootstrapText`) and the
// OpenAI Realtime text-only path (`bootstrapTextOpenAI`). The
// parser resolves which one is active before either is called, so
// these functions trust their preconditions and just run.

import Foundation
import bitHumanKit
import BithumanRealtimeOpenAI

@MainActor
func bootstrapText(_ args: CLIArgs) async throws {
    if args.openAI {
        try await bootstrapTextOpenAI(args)
        return
    }
    var config = makeConfig(args)
    // Single-line progress for the LLM weights download/load. Only
    // attach when stderr is a TTY — piped use (`| grep …`) stays
    // clean and the legacy banner suffices.
    let interactiveStderr = isatty(fileno(stderr)) != 0
    var renderer: TerminalProgressRenderer? = nil
    let boot: BootProgress? = interactiveStderr ? BootProgress() : nil
    if let boot {
        let r = TerminalProgressRenderer(progress: boot)
        r.attach()
        renderer = r
        config.bootProgress = boot
    }
    let chat = TextChat(config: config)
    try await chat.start()
    boot?.update(.ready)
    renderer?.detach()
    // start() returns when stdin closes; nothing to park on.
}

@MainActor

func bootstrapTextOpenAI(_ args: CLIArgs) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        FileHandle.standardError.write(Data("error: OPENAI_API_KEY missing\n".utf8))
        exit(1)
    }
    // Reuse `--openai-model` so the model picker is symmetric with
    // voice. Map the realtime default to a reasonable chat default —
    // realtime models accept text-only requests but the dedicated
    // chat models (gpt-4o-mini, gpt-4.1-mini, etc.) are cheaper.
    let model: String
    if args.openAIModel == "gpt-realtime-mini" || args.openAIModel.hasPrefix("gpt-realtime") {
        // User didn't specify a chat model; pick the fast/cheap default.
        model = "gpt-4o-mini"
    } else {
        model = args.openAIModel
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"
    try await runOpenAIChat(
        apiKey: apiKey,
        model: model,
        instructions: instructions,
        verbose: verbose
    )
}

/// Center-of-screen origin for an avatar window of the given size.
/// Replaces the splash window's role as a position anchor.
