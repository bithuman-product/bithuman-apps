// `bithuman-cli voice` — voice REPL with two backends.
//
// `bootstrapVoice` is the on-device path: Apple SpeechAnalyzer →
// local LLM (Gemma) → Qwen3-TTS. `bootstrapVoiceOpenAI` is the
// cloud path: OpenAI Realtime over WebRTC.
//
// Backend selection (the auto-pick for `OPENAI_API_KEY` /
// interactive prompt fallback) happens in `parseArgs`; by the
// time we get here, exactly one of `args.openAI` / `args.local`
// is set and we just dispatch.

import Foundation
import bitHumanKit
import BithumanRealtimeOpenAI

@MainActor
func bootstrapVoice(_ args: CLIArgs) async throws {
    if args.openAI {
        // Route to the WebRTC + OpenAI Realtime backend. The local
        // LLM/ASR/TTS pipeline below is bypassed entirely; libwebrtc
        // owns audio I/O, OpenAI's server runs the conversation.
        try await bootstrapVoiceOpenAI(args)
        return
    }
    // We resolved the auto-pick during arg validation. If we got
    // here it means `--local` won (either explicitly or because
    // OPENAI_API_KEY wasn't set). The terminal progress UI takes
    // over from here.
    var config = makeConfig(args)
    config.voice = await resolveVoice(args)

    // Unified boot progress UI — one self-overwriting stderr line
    // covering speech-model fetch, LLM weights download/load, audio
    // graph init, and TTS load. Replaces the prior wall of separate
    // print() lines that gave the user no rate / ETA / fraction
    // information across long stages.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()
    config.bootProgress = boot

    let chat = VoiceChat(config: config)
    try await chat.start()
    boot.update(.ready)
    renderer.detach()

    // Same stdin reader as video mode — type a message in the
    // launching terminal and it's routed through the orchestrator's
    // turn flow exactly like a spoken utterance.
    Task.detached(priority: .background) { [chat] in
        while !Task.isCancelled, let line = readLine() {
            await chat.inject(userText: line)
        }
    }

    // Park forever; Ctrl-C tears the process down.
    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = chat
}

/// `bithuman-cli voice --openai` entry point. Reads the API key from
/// the env, picks the realtime model + voice, hands off to the
/// `BithumanRealtimeOpenAI` library which owns the WebRTC peer
/// connection + terminal UI. The local LLM/ASR/TTS pipeline is
/// completely bypassed in this mode — OpenAI runs the conversation
/// server-side, libwebrtc handles audio I/O + AEC.
@MainActor
func bootstrapVoiceOpenAI(_ args: CLIArgs) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        // Already validated at parse time; defensive.
        FileHandle.standardError.write(Data("error: OPENAI_API_KEY missing\n".utf8))
        exit(1)
    }
    // `--voice <name>` doubles for the OpenAI voice slot. The local
    // pipeline accepts preset names OR file paths (Qwen3 voice
    // cloning); OpenAI accepts only the named voices (`alloy`,
    // `echo`, `shimmer`, `sage`, …). If the user passes a path-shaped
    // arg with --openai we just default — silent lifecycle.
    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"
    // System prompt: same `--prompt` flag the local pipeline uses.
    // Inline text or `@path/to/file.txt`. nil → backend's default.
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }
    try await runOpenAIRealtime(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        verbose: verbose
    )
}
