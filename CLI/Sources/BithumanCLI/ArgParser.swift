// Argument parser + per-flag hint surface.
//
// `parseArgs()` is the single entry point the rest of the program
// uses to turn `argv` into a `CLIArgs`. Failure modes route through
// `fatalUsage` (in `Auth.swift`) so the user always sees an
// actionable hint rather than a Swift trap. The hint strings live
// in `FlagHint`, defined here so they stay in sync with the
// switch's value-flag list and with `knownFlags` (the typo
// suggester's vocabulary).
//
// `promptForVoiceBackend()` is colocated with the parser because
// it's invoked *during* argument resolution: the parser asks the
// user to choose between OpenAI and on-device when neither flag
// nor `OPENAI_API_KEY` resolves the ambiguity in interactive mode.

import Foundation
import bitHumanKit

// MARK: - Argv parsing

/// Per-flag hint strings for the "needs a value" error path. Each
/// hint is rendered as the second line of the error so the user
/// sees both *what* failed and *what to type instead* without
/// having to re-run with `--help`. Hints are produced lazily so
/// they can pull live preset lists from the SDK.
/// ANSI escape helpers used by hint typography. Wrapping them as
/// `let`s keeps the FlagHint string literals readable — `\u{1B}[1m`
/// inline at every emphasis would be visual noise. Non-TTY consumers
/// see the raw escape bytes; that's the same convention `helpText`
/// uses (we don't gate ANSI on isatty).
private let B = "\u{1B}[1m"   // bold on
private let D = "\u{1B}[2m"   // dim on
private let R = "\u{1B}[0m"   // reset

enum FlagHint {
    static let locale = """
        ASR + TTS language. Any BCP-47 code:

          \(B)en-US\(R) \(D)(default)\(R)  ·  ja-JP  ·  zh-CN  ·  es-ES  ·  fr-FR  ·  …
        """

    /// `--voice` accepts different value shapes per mode/backend.
    /// Card per backend so the user can scan the right row by mode
    /// without parsing a wall of comma-separated names. Preset lists
    /// pull live from the SDK so they can't drift.
    static var voice: String {
        let qwen3 = VoiceSelection.presetNames.joined(separator: ", ")
        // Long Kokoro list — wrap to a second line manually so it
        // doesn't blow past 80 cols on a normal terminal.
        let kokoro = VoiceChat.availableAvatarVoices
        let kokoroFirst = kokoro.prefix(4).joined(separator: ", ")
        let kokoroRest = kokoro.dropFirst(4).joined(separator: ", ")
        return """
        The TTS voice. Accepted values depend on the active backend:

          \(B)voice --local\(R)   \(D)Qwen3 · cloning supported\(R)
            presets · \(qwen3)
            clone   · path to a 10–20 s mono audio file (.wav, .aiff, .m4a)

          \(B)avatar\(R)          \(D)Kokoro · presets only\(R)
            presets · \(kokoroFirst),
                      \(kokoroRest)

          \(B)voice --openai\(R)  \(D)OpenAI Realtime API\(R)
            presets · alloy, ash, ballad, coral, echo, sage,
                      shimmer, verse, marin, cedar
        """
    }

    static let image = """
        The avatar's portrait. Bundled presets:

          \(B)Alice\(R)  ·  \(B)Marco\(R)  ·  \(B)Captain\(R)  ·  \(B)Nia\(R)  ·  \(B)Riley\(R)

          Or a path to a JPG / PNG / HEIC file on disk.
        """

    static let model = """
        Path to an .imx avatar bundle.

          Download one at \(B)https://www.bithuman.ai/#explore\(R)
          \(D)(click ⋯ on any agent → Download)\(R)
        """

    static let identity = """
        Unified --image / --model. Auto-dispatched by file shape:

          \(B).imx file\(R)    →  loaded as --model (Expression or Essence bundle)
          \(B)preset name\(R)  →  loaded as --image (Alice, Marco, Captain, Nia, Riley)
          \(B)image path\(R)   →  loaded as --image (.jpg / .png / .heic)
        """

    static let prompt = """
        System prompt for the LLM. Two forms:

          \(B)inline\(R)  ·  --prompt "You are a helpful assistant."
          \(B)file\(R)    ·  --prompt @/path/to/prompt.txt
        """

    /// `--openai-model` is shared across modes but eligible names
    /// split by API — Realtime for voice/avatar (streaming audio
    /// in/out over WebRTC), Chat Completions for text.
    ///
    /// Realtime pricing nuance: **all four current Realtime models
    /// bill audio identically at $32 in / $64 out per 1M tokens.**
    /// The choice between them is capability + account-tier
    /// availability, not cost. Don't mistake the text-token pricing
    /// ($4 in / $24 out) for the audio-token pricing the CLI
    /// actually uses; the realtime backend uses audio tokens for
    /// every conversation turn.
    ///
    /// Text pricing varies by model — the table shows the per-1M
    /// rates so users can pick consciously. `★` marks the
    /// recommended default per mode.
    static var openAIModel: String {
        // Column widths picked so the helpful right-pipe lands at the
        // same column on every data row regardless of name/description
        // length. Built as an array of pre-padded lines and joined
        // with "\n", avoiding source-indent leak through string
        // literals.
        let modeWidth = 14   // visible width of mode column inside the box
        let nameWidth = 17   // visible width of model-name column
        let descWidth = 18   // visible width of description column
        // Total inside the models cell (between │ and │) = 1 lead + 1 icon
        // + 1 + nameWidth + 1 + descWidth + 1 trail = 40
        let modelsWidth = 1 + 1 + 1 + nameWidth + 1 + descWidth + 1   // = 40
        let modeDashes = String(repeating: "─", count: modeWidth + 2) // +2 for cell padding
        let modelDashes = String(repeating: "─", count: modelsWidth)

        func row(_ mode: String, _ icon: String, _ name: String, _ desc: String, dim: Bool = false) -> String {
            let modePad = mode.padding(toLength: modeWidth, withPad: " ", startingAt: 0)
            let namePad = name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let descPad = desc.padding(toLength: descWidth, withPad: " ", startingAt: 0)
            let descStyled = dim ? "\(D)\(descPad)\(R)" : descPad
            return "│ \(modePad) │ \(icon) \(namePad) \(descStyled) │"
        }

        let lines: [String] = [
            "The OpenAI model.  \(B)★\(R) = recommended default for the mode.",
            "",
            "  ┌\(modeDashes)┬\(modelDashes)┐",
            "  │ \("Mode".padding(toLength: modeWidth, withPad: " ", startingAt: 0)) │ \("Eligible models".padding(toLength: modelsWidth - 2, withPad: " ", startingAt: 0)) │",
            "  ├\(modeDashes)┼\(modelDashes)┤",
            "  " + row("voice / avatar", " ", "gpt-realtime-mini", "cost-efficient", dim: true),
            "  " + row("(Realtime API)", " ", "gpt-realtime",      "baseline",            dim: true),
            "  " + row("",               "\(B)★\(R)", "gpt-realtime-1.5",  "improved gen",        dim: true),
            "  " + row("",               " ", "gpt-realtime-2",    "newest, GPT-5",       dim: true),
            "  ├\(modeDashes)┼\(modelDashes)┤",
            "  " + row("text",           "\(B)★\(R)", "gpt-5.4-mini",  "$0.75 / $4.50"),
            "  " + row("(Chat API)",     " ", "gpt-5.4-nano",  "$0.20 / $1.25"),
            "  " + row("",               " ", "gpt-5.4",       "$2.50 / $15"),
            "  " + row("",               " ", "gpt-5.5",       "$5    / $30"),
            "  " + row("",               " ", "o3-mini",       "(reasoning)", dim: true),
            "  └\(modeDashes)┴\(modelDashes)┘",
            "",
            "  \(B)Realtime\(R): all four bill audio at $32 in / $64 out per 1M tok —",
            "  the choice is capability + tier availability, not cost.",
            "",
            "  \(B)Text\(R): prices shown are $in / $out per 1M text tokens.",
            "  \(B)★\(R) marks the value sweet spot — gpt-5.4-nano is cheaper",
            "  but limited to simple tasks.",
            "",
            "  \(D)Legacy chat (still in API; flagged legacy since OpenAI retired",
            "  them from ChatGPT 2026-02-13):",
            "    gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4.1-mini, o4-mini.\(R)",
            "",
            "  Full list · \(B)https://platform.openai.com/docs/models\(R)",
        ]
        return lines.joined(separator: "\n")
    }
}

/// Pull the next positional value off the arg iterator for the
/// given flag. On a missing or flag-shaped value, call `fatalUsage`
/// with a per-flag hint so the user sees the valid value shapes
/// without having to consult `--help`.
private func nextValue(
    _ flag: String,
    _ it: inout IndexingIterator<[String]>,
    hint: String? = nil
) -> String {
    guard let v = it.next() else {
        if let hint = hint {
            fatalUsage("\(flag) needs a value.\n  \(hint)")
        }
        fatalUsage("\(flag) needs a value")
    }
    if v.hasPrefix("-") {
        // The user wrote `--flag --otherflag` — almost always an
        // accidentally dropped value. Show the hint so they can fill
        // it in instead of re-reading the help.
        if let hint = hint {
            fatalUsage("""
                \(flag) needs a value but got the flag '\(v)'. Did you forget the argument?
                  \(hint)
                """)
        }
        fatalUsage("\(flag) needs a value but got the flag '\(v)'. Did you forget the argument?")
    }
    return v
}

/// Cheap typo-suggester used by the unknown-argument error path. Returns
/// the closest match from `candidates` if its Levenshtein distance is
/// within `tolerance`, otherwise nil. Tolerance scales with input length
/// so short flags need an exact-or-one-char-off match while longer ones
/// allow a couple of edits.
internal func closestMatch(_ input: String, in candidates: [String]) -> String? {
    let lower = input.lowercased()
    let tolerance = max(2, lower.count / 4)
    var best: (String, Int)? = nil
    for candidate in candidates {
        let d = levenshtein(lower, candidate.lowercased())
        if d <= tolerance, best.map({ d < $0.1 }) ?? true {
            best = (candidate, d)
        }
    }
    return best?.0
}

/// Iterative DP Levenshtein. Plenty fast for argv-sized inputs; we
/// don't need the early-exit optimisation here.
func levenshtein(_ a: String, _ b: String) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    if aChars.isEmpty { return bChars.count }
    if bChars.isEmpty { return aChars.count }
    var prev = Array(0...bChars.count)
    var curr = Array(repeating: 0, count: bChars.count + 1)
    for i in 1...aChars.count {
        curr[0] = i
        for j in 1...bChars.count {
            let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &curr)
    }
    return prev[bChars.count]
}

/// All recognised flags. Single source of truth used by the parser
/// and the unknown-argument typo suggester. Keep in sync with the
/// switch in `parseArgs`.
let knownFlags: [String] = [
    "--locale", "--voice", "--image", "--model", "--identity",
    "--prompt", "--openai", "--local", "--openai-model",
    "-h", "--help", "-v", "--version",
]

/// User's choice when no `OPENAI_API_KEY` was found and they ran
/// `bithuman-cli voice` in an interactive terminal. The exit case
/// is the polite-cancel path (Ctrl-C, blank line, or "3").
enum VoiceBackendChoice {
    case openai(String)  // user pasted a key
    case local
    case exit
}

/// Interactive picker shown when no `OPENAI_API_KEY` is set and the
/// user didn't pass `--openai` / `--local` explicitly. Keeps the UX
/// honest: we don't silently choose the multi-GB on-device path,
/// and we don't make the user re-run with a different flag — we
/// ask, accept the key on the spot if they want OpenAI, and move on.
private func promptForVoiceBackend() -> VoiceBackendChoice {
    let bold = "\u{1B}[1m"
    let dim = "\u{1B}[2m"
    let cyan = "\u{1B}[36m"
    let reset = "\u{1B}[0m"
    print("""

      \(bold)👋 Welcome — let's get you set up.\(reset)

      You can run \(bold)bithuman-cli\(reset) two ways:

        \(bold)[1] OpenAI cloud\(reset)   \(dim)·  starts in seconds, ~$0.06/min, paste your key once\(reset)
        \(bold)[2] On-device\(reset)       \(dim)·  fully private, ~5 GB one-time download\(reset)
        \(bold)[3] Exit\(reset)

      \(dim)Get an OpenAI key at https://platform.openai.com/api-keys\(reset)

    """)
    print("    Choose 1, 2, or 3: ", terminator: "")

    guard let raw = readLine() else { return .exit }
    let line = raw.trimmingCharacters(in: .whitespaces)
    switch line {
    case "1":
        print("    Paste your OpenAI API key (starts with sk-): ", terminator: "")
        guard let keyRaw = readLine() else { return .exit }
        let key = keyRaw.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return .exit }
        if !key.hasPrefix("sk-") {
            FileHandle.standardError.write(Data(
                "    ⚠️  That doesn't look like an OpenAI API key (no `sk-` prefix). I'll try it anyway.\n".utf8
            ))
        }
        // Default Y — the next-launch UX is way better when we
        // remember the key, and the file is owner-only (0600).
        print("    Remember it for next time? [Y/n] ", terminator: "")
        let saveAnswer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if saveAnswer == "" || saveAnswer == "y" || saveAnswer == "yes" {
            if BithumanKeychain.saveOpenAIKey(key) {
                print("    ✓ saved to ~/Library/Application Support/com.bithuman.cli/openai-api-key (0600)")
            } else {
                FileHandle.standardError.write(Data(
                    "warn: couldn't write the key file. Continuing for this session only.\n".utf8
                ))
            }
        }
        return .openai(key)
    case "2":
        return .local
    case "", "3", "q", "quit", "exit":
        return .exit
    default:
        FileHandle.standardError.write(Data(
            "invalid selection: \(line) — expected 1, 2, or 3.\n".utf8
        ))
        return .exit
    }
}

func parseArgs() -> CLIArgs {
    var args = CLIArgs()
    var rawArgs = Array(CommandLine.arguments.dropFirst())

    // First positional (if any) may be a mode subcommand. Help flags
    // and option flags both start with `-`, so the leading non-flag
    // token is the mode candidate. Unknown subcommands fall through
    // to the unknown-argument error path.
    if let first = rawArgs.first, !first.hasPrefix("-") {
        let normalized = first.lowercased()
        // Hidden alias: `video` was the old name for `avatar` before
        // v0.10.0. Keep accepting it so existing scripts and muscle
        // memory don't break — not advertised in help.
        let modeRaw = (normalized == "video") ? "avatar" : normalized
        if let mode = Mode(rawValue: modeRaw) {
            args.mode = mode
            rawArgs.removeFirst()
        } else {
            fatalUsage("""
                unknown subcommand '\(first)'.
                  Valid modes: text, voice, avatar. Or omit for voice (the default).
                """)
        }
    }

    var it = rawArgs.makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--locale":
            args.localeIdentifier = nextValue("--locale", &it, hint: FlagHint.locale)
        case "--voice":
            args.voiceArg = nextValue("--voice", &it, hint: FlagHint.voice)
        case "--image":
            args.imageArg = nextValue("--image", &it, hint: FlagHint.image)
        case "--model":
            args.modelArg = nextValue("--model", &it, hint: FlagHint.model)
        case "--identity":
            args.identityArg = nextValue("--identity", &it, hint: FlagHint.identity)
        case "--prompt":
            // --prompt accepts inline strings starting with '-' (e.g. an
            // imperative sentence), so we can't gate on the prefix here.
            // The only failure mode is a truly missing value.
            guard let v = it.next() else {
                fatalUsage("--prompt needs a value.\n  \(FlagHint.prompt)")
            }
            args.promptArg = v
        case "--openai":
            args.openAI = true
        case "--local":
            args.local = true
        case "--openai-model":
            args.openAIModel = nextValue("--openai-model", &it, hint: FlagHint.openAIModel)
        case "-h", "--help":
            print(helpText)
            exit(0)
        case "-v", "--version":
            print("bithuman-cli \(cliVersion)")
            exit(0)
        default:
            // Typo-suggest off `knownFlags`. Unknown subcommands are
            // already caught earlier; only flag-shaped unknowns reach
            // here, so suggesting flags is the right default. The
            // categorised list (Value / Boolean / Info) makes the
            // valid-flag dump scannable rather than a wall of commas.
            let flagsBlock = """
                  \(B)Value flags:\(R)
                    --locale  --voice  --image  --model  --identity
                    --prompt  --openai-model
                  \(B)Boolean flags:\(R)
                    --openai  --local
                  \(B)Info flags:\(R)
                    -h --help  -v --version
                """
            if let suggestion = closestMatch(arg, in: knownFlags) {
                fatalUsage("""
                    unknown argument '\(arg)'.

                      Did you mean \(B)\(suggestion)\(R)?

                    \(flagsBlock)
                    """)
            }
            fatalUsage("""
                unknown argument '\(arg)'.

                \(flagsBlock)
                """)
        }
    }

    // Resolve `--identity` into the legacy `--image` / `--model`
    // slots based on file shape. Reject conflicts up front.
    if let raw = args.identityArg {
        if args.imageArg != nil {
            fatalUsage("--identity and --image both supplied; pass only one.")
        }
        if args.modelArg != nil {
            fatalUsage("--identity and --model both supplied; pass only one.")
        }
        let lower = raw.lowercased()
        if lower.hasSuffix(".imx") {
            args.modelArg = raw  // Essence/Expression model bundle
        } else {
            // Anything else — preset name or image path — flows to
            // the existing `--image` resolver, which already handles
            // both shapes (preset gallery + JPG/PNG/HEIC).
            args.imageArg = raw
        }
    }

    // Mode-specific argument validation.
    switch args.mode {
    case .text:
        if args.localeIdentifier != "en-US" {
            cliWarn("--locale is ignored in text mode (no ASR/TTS).")
        }
        if args.voiceArg != nil {
            cliWarn("--voice is ignored in text mode (no TTS).")
        }
        if args.imageArg != nil {
            cliWarn("--image is ignored in text mode.")
        }
        if args.modelArg != nil {
            cliWarn("--model is ignored in text mode (no avatar engine).")
        }
        if args.openAI && args.local {
            fatalUsage("--openai and --local are mutually exclusive; pass at most one.")
        }
        // Same auto-pick + saved-key fallback as voice mode: prefer
        // OpenAI when a key is available, fall back to local Gemma
        // otherwise. The local pipeline is heavy (~2 GB on disk);
        // text chats over the cloud API instead saves the download.
        if (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty,
           let saved = BithumanKeychain.loadOpenAIKey(), !saved.isEmpty {
            setenv("OPENAI_API_KEY", saved, 1)
        }
        if args.openAI && ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty != false {
            fatalKey()
        }
        if !args.openAI && !args.local {
            if !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty {
                args.openAI = true
            } else {
                args.local = true
            }
        }
    case .voice:
        if args.imageArg != nil {
            fatalUsage("--image only applies to avatar mode. Did you mean `bithuman-cli avatar --image ...`?")
        }
        if args.modelArg != nil {
            fatalUsage("--model only applies to avatar mode. Did you mean `bithuman-cli avatar --model ...`?")
        }
        if args.openAI && args.local {
            fatalUsage("--openai and --local are mutually exclusive; pass at most one.")
        }
        // Pull a saved key out of the macOS Keychain into the
        // process env if the env var isn't set. Same precedence the
        // OpenAI Python/Node SDKs use: env var wins; secondary
        // store fills in. Removable with
        // `security delete-generic-password -s ai.bithuman.cli`.
        if (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty,
           let saved = BithumanKeychain.loadOpenAIKey(), !saved.isEmpty {
            setenv("OPENAI_API_KEY", saved, 1)
        }
        if args.openAI && ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty != false {
            fatalKey()
        }
        // Backend selection. Three cases:
        //
        //   1. User passed --openai or --local — honour it.
        //   2. OPENAI_API_KEY is set — pick OpenAI (no downloads,
        //      lower memory).
        //   3. Neither flag, no key —
        //      a. Interactive terminal: ask the user whether to
        //         paste a key or fall back to on-device.
        //      b. Non-interactive (piped, scripted): fall back to
        //         on-device with a one-line notice on stderr so
        //         the runner sees what happened.
        //
        // Resolved here so `bootstrapVoice` always sees a clear
        // choice in `args.openAI` / `args.local`.
        if !args.openAI && !args.local {
            if !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty {
                args.openAI = true
            } else if isatty(fileno(stdin)) != 0 && isatty(fileno(stderr)) != 0 {
                switch promptForVoiceBackend() {
                case .openai(let key):
                    setenv("OPENAI_API_KEY", key, 1)
                    args.openAI = true
                case .local:
                    args.local = true
                case .exit:
                    exit(0)
                }
            } else {
                FileHandle.standardError.write(Data(
                    "ℹ️  No OPENAI_API_KEY set; using on-device mode (~5 GB first-run download). Pass --openai with a key for the cloud backend, or --local to silence this notice.\n".utf8
                ))
                args.local = true
            }
        }
        // Now that the backend is locked in, warn about flags that
        // don't apply to the resolved choice. (Done here, post-
        // auto-pick, so the warning fires whether the user passed
        // `--openai` or got it via the OPENAI_API_KEY auto-pick.)
        if args.openAI && args.localeIdentifier != "en-US" {
            cliWarn("--locale is ignored under --openai (the realtime model auto-detects the input language).")
        }
    case .avatar:
        // --image is optional; default portrait used if omitted.
        // --voice in default (Expression) avatar mode is a Kokoro
        // preset — not a Qwen3 preset and not a path. Kokoro
        // doesn't clone; reject path-shaped arguments with a
        // pointer to `bithuman-cli voice` so the user knows where
        // cloning lives. We detect "path-shape" structurally
        // (slashes, `~`, audio extension).
        //
        // Skipped when `--model <path>` is supplied: at parse time
        // we can't peek the .imx's `model_type` (sync context) so
        // we defer voice validation to the per-mode runtime.
        // Essence (`runEssenceVideoSession`) accepts the full Qwen3
        // surface — preset names AND audio paths for cloning —
        // because its TTS backend (Qwen3-TTS) supports both, unlike
        // Expression's Kokoro-only branch.
        if args.modelArg == nil, let raw = args.voiceArg {
            let lower = raw.lowercased()
            let looksLikePath =
                raw.contains("/") ||
                raw.hasPrefix("~") ||
                lower.hasSuffix(".wav") ||
                lower.hasSuffix(".aiff") ||
                lower.hasSuffix(".aif") ||
                lower.hasSuffix(".m4a") ||
                lower.hasSuffix(".mp3") ||
                lower.hasSuffix(".caf")
            if looksLikePath {
                fatalUsage("""
                    --voice <path> (voice cloning) isn't supported in avatar mode.
                      Video mode uses Kokoro TTS, which takes preset speakers only,
                      because the avatar engine needs the GPU. For cloning, run:
                          bithuman-cli voice --voice \(raw)
                      Or pick a Kokoro preset for video:
                          \(VoiceChat.availableAvatarVoices.joined(separator: ", "))
                    """)
            }
            let kokoroMatch = VoiceChat.availableAvatarVoices
                .first { $0.lowercased() == lower }
            if kokoroMatch == nil {
                // Helpful diagnosis: did the user pass a Qwen3 preset by accident?
                if VoiceSelection.canonicalPreset(matching: raw) != nil {
                    fatalUsage("""
                        --voice '\(raw)' is a voice-mode (Qwen3) preset; video mode uses Kokoro.
                          Kokoro presets: \(VoiceChat.availableAvatarVoices.joined(separator: ", "))
                          For voice mode (with cloning + Qwen3 voices):
                              bithuman-cli voice --voice \(raw)
                        """)
                }
                fatalUsage("""
                    --voice '\(raw)' isn't a recognised Kokoro preset.
                      Recognised: \(VoiceChat.availableAvatarVoices.joined(separator: ", "))
                    """)
            }
        }
    case .cleanup, .doctor:
        // Pure utility modes — flag args don't apply. Warn rather
        // than fatalUsage so a stray flag doesn't block a routine
        // cleanup/doctor run from a script.
        if args.localeIdentifier != "en-US" || args.voiceArg != nil
           || args.imageArg != nil || args.modelArg != nil
           || args.promptArg != nil || args.openAI || args.local
        {
            cliWarn("flags ignored — `\(args.mode.rawValue)` mode takes no options.")
        }
    }

    // Video mode also gets the cloud/local auto-pick for the voice
    // pipeline (LLM/TTS/ASR). Avatar engine stays local. Behaviour
    // mirrors voice + text:
    //   --openai / --local → honour
    //   key in env or key file → cloud
    //   no key → local
    if args.mode == .avatar {
        if args.openAI && args.local {
            fatalUsage("--openai and --local are mutually exclusive; pass at most one.")
        }
        if (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty,
           let saved = BithumanKeychain.loadOpenAIKey(), !saved.isEmpty {
            setenv("OPENAI_API_KEY", saved, 1)
        }
        if args.openAI && ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty != false {
            fatalKey()
        }
        if !args.openAI && !args.local {
            if !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty {
                args.openAI = true
            } else {
                args.local = true
            }
        }
    }

    return args
}

// MARK: - Mode dispatch
