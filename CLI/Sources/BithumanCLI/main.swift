import AppKit
import AVFoundation
import bitHumanKit
import BithumanRealtimeOpenAI
import Foundation
import Speech

setbuf(stdout, nil)
setbuf(stderr, nil)

// MARK: - Modes

enum Mode: String {
    case text
    case voice
    /// `avatar` — talk with a lip-syncing animated face. Renamed
    /// from `video` in v0.10.0; the old name is still accepted by
    /// the parser as a hidden alias so existing scripts / shell
    /// history don't break. Internal code still calls it `.avatar`.
    case avatar
    case cleanup
    case doctor
}

struct CLIArgs {
    var mode: Mode = .voice              // bare `bithuman-cli` defaults to voice
    var localeIdentifier: String = "en-US"
    var voiceArg: String? = nil          // preset name OR file path
    var promptArg: String? = nil         // inline string OR @path
    var imageArg: String? = nil          // video mode: portrait path or preset
    /// Unified `--identity` flag. Dispatches by file extension —
    /// `.imx` → treated as `--model` (Essence model bundle); any
    /// image extension (jpg/jpeg/png/heic) → treated as `--image`
    /// (portrait for Expression). Bundle preset names also accepted
    /// as `--image` aliases (Alice, Marco, …). The CLI sets either
    /// `imageArg` or `modelArg` from this so downstream flow doesn't
    /// have to know about the unified shape.
    var identityArg: String? = nil
    /// Path to an `.imx` avatar model. `nil` (the unmodified default)
    /// means video mode auto-resolves the bundled Expression weights
    /// via ``ExpressionWeights/ensureAvailable()`` — same behaviour the
    /// CLI has always had. When set, the file is opened and dispatched
    /// on `manifest.model_type`: Expression `.imx` files use the
    /// existing `Bithuman` actor + circular `AvatarWindow`; Essence
    /// `.imx` files use the new `EssenceRuntime` + rectangular full-
    /// frame `AvatarWindow`.
    var modelArg: String? = nil          // video mode: path to .imx (Expression OR Essence)

    /// Voice mode only. Three states the user can express:
    ///
    ///   - `openAI = true`  →  user passed `--openai`. Force the
    ///     OpenAI Realtime backend; error if no API key.
    ///   - `local = true`   →  user passed `--local`. Force the
    ///     on-device LLM/ASR/TTS pipeline; downloads ~5 GB on
    ///     first run.
    ///   - both false       →  no flag. Auto-pick: OpenAI when
    ///     `OPENAI_API_KEY` is set (no downloads, snappier), else
    ///     fall back to local. The auto-pick is announced in
    ///     stdout so the user knows which path they're on.
    ///
    /// Both flags simultaneously is rejected at parse time.
    var openAI: Bool = false
    var local: Bool = false
    var openAIModel: String = "gpt-realtime-mini"
}

// MARK: - Help

let helpText = """
\u{1B}[1mbithuman-cli\u{1B}[0m — voice, text, and avatar chat
  by \u{1B}[1mbitHuman Inc.\u{1B}[0m  ·  https://www.bithuman.ai
  Apple Silicon, macOS 26+

\u{1B}[1mFAST PATHS\u{1B}[0m
  \u{1B}[2m# easiest — OpenAI cloud (instant; no downloads)\u{1B}[0m
  export OPENAI_API_KEY=sk-...
  bithuman-cli                    \u{1B}[2m# voice chat (auto-picks cloud)\u{1B}[0m
  bithuman-cli text               \u{1B}[2m# text chat (auto-picks cloud)\u{1B}[0m
  bithuman-cli avatar             \u{1B}[2m# avatar chat (lipsync local + cloud voice)\u{1B}[0m

  \u{1B}[2m# fully on-device — no cloud, no key needed\u{1B}[0m
  bithuman-cli voice --local      \u{1B}[2m# ~5 GB first-run download\u{1B}[0m
  bithuman-cli text --local       \u{1B}[2m# ~2 GB first-run download\u{1B}[0m
  bithuman-cli avatar --local     \u{1B}[2m# everything on-device (~7 GB)\u{1B}[0m

\u{1B}[1mUSAGE\u{1B}[0m
  bithuman-cli [<mode>] [options]

\u{1B}[1mMODES\u{1B}[0m
  voice  (default)        Speak to chat. Auto-picks the OpenAI Realtime
                          API when `OPENAI_API_KEY` is set, otherwise
                          uses the on-device pipeline. With no key in
                          an interactive terminal, prompts you to paste
                          one or pick local. Force a backend with
                          `--openai` / `--local`.

  text                    Type to chat. Same auto-pick rule as voice:
                          OpenAI Chat Completions when a key is
                          available, on-device Gemma otherwise.
                          Pipe-friendly: `echo "hi" | bithuman-cli text`.

  avatar                  Voice chat + a small floating animated face
                          that lip-syncs to the bot's voice. Same
                          auto-pick as voice mode: OpenAI Realtime
                          when a key is set (avatar renders locally
                          via lipsync tap on the WebRTC bot audio
                          track), fully on-device otherwise (~7 GB).
                          With no `--identity`, the bundled Diego
                          Expression agent's weights are auto-fetched
                          on first run. Pass `.imx` for an Essence
                          bundle or an image for a custom Expression
                          portrait. Right-click the avatar to pick
                          from 8 bundled agents, drag-drop a photo to
                          swap the face, audition voices, or edit the
                          prompt.

                          (Old name `video` is still accepted as a
                          hidden alias for backward compatibility.)

  doctor                  Read-only host check: CPU architecture, RAM,
                          free disk, OpenAI key availability. Run this
                          before a long cold-boot to catch issues
                          (low disk, x86_64 under Rosetta, etc.) up
                          front. Takes ~1 s.

  cleanup                 Wipe model caches (`~/.cache/huggingface` and
                          `~/.cache/bithuman`). Asks for confirmation,
                          shows total size first. Useful for testing
                          the cold-start flow or freeing disk.

\u{1B}[1mMORE EXAMPLES\u{1B}[0m
  bithuman-cli voice --voice ballad             \u{1B}[2m# cloud voice — dramatic style\u{1B}[0m
  bithuman-cli voice --prompt "Be a pirate."    \u{1B}[2m# custom personality\u{1B}[0m
  bithuman-cli voice --local --voice Aiden      \u{1B}[2m# on-device — Qwen3 preset\u{1B}[0m
  bithuman-cli voice --local --voice me.wav     \u{1B}[2m# on-device — clone your voice\u{1B}[0m
  bithuman-cli voice --local --locale ja-JP     \u{1B}[2m# on-device Japanese\u{1B}[0m
  bithuman-cli text  --prompt @persona.txt      \u{1B}[2m# load prompt from file\u{1B}[0m
  bithuman-cli avatar --identity ~/me.jpg       \u{1B}[2m# Expression w/ your portrait\u{1B}[0m
  bithuman-cli avatar --identity agent.imx      \u{1B}[2m# Essence bundle (face baked in)\u{1B}[0m
  bithuman-cli doctor                           \u{1B}[2m# check disk / RAM / arch / key\u{1B}[0m
  bithuman-cli cleanup                          \u{1B}[2m# wipe model caches (after confirm)\u{1B}[0m

\u{1B}[1mOPTIONS\u{1B}[0m
  --locale <bcp47>       (voice --local + avatar) Spoken-language code.
                         Default: en-US. Examples: en-US, ja-JP, zh-CN,
                         es-ES, fr-FR. Ignored under `--openai` —
                         the realtime model auto-detects the input
                         language, no locale hint needed.

  --voice <name|path>    Pick the bot's voice. Accepted values depend on
                         which backend is running — see the per-backend
                         lists below.

                         voice --openai → OpenAI Realtime voices:
                          • alloy (default), ash, ballad, coral, echo,
                            sage, shimmer, verse
                          • newer 2025 additions: marin, cedar
                          • path arguments are silently ignored (OpenAI
                            voices aren't cloneable)
                          • full canonical list:
                            https://platform.openai.com/docs/guides/realtime

                         voice --local → Qwen3-TTS, supports cloning:
                          • preset (case-insensitive):
                              English: Ryan, Aiden
                              Chinese: Vivian, Serena, Uncle_Fu, Dylan, Eric
                          • path to a 10–20 s mono audio file
                            (WAV/AIFF/M4A) → voice is cloned

                         avatar (default Expression) → Kokoro, preset only
                         (avatar engine needs the GPU, so video uses a
                         lightweight TTS that doesn't clone):
                          • preset (case-insensitive):
                              af_heart, af_alloy, af_aoede, af_kore,
                              am_adam, am_michael, am_echo,
                              bf_emma, bm_george
                          • paths not accepted — run
                            `bithuman-cli voice --local --voice <path>`
                            for cloning instead

                         avatar --model essence.imx → Qwen3-TTS (same
                         surface as `voice --local`): preset names +
                         audio paths for cloning, all accepted.

                         If omitted, each mode falls back to its default
                         voice — Expression to the bundled agent's
                         Kokoro preset, Essence to Qwen3-TTS's default,
                         OpenAI Realtime to alloy.

  --model <path>         (avatar only) Path to a packed avatar `.imx`.
                         Accepts BOTH Expression and Essence bundles —
                         the CLI peeks the manifest's `model_type` and
                         picks the right runtime + window shape:
                          • Expression .imx → circular floating window,
                            Kokoro voice + portrait identity (the
                            existing video-mode look).
                          • Essence    .imx → rectangular full-frame
                            window at the file's baked output
                            resolution; voice + identity are baked in
                            so `--voice` / `--image` become no-ops with
                            a friendly note.
                         If omitted, avatar mode downloads / uses the
                         bundled Expression weights — identical to
                         every previous release.

  --image <preset|path>  (avatar only) Pick the avatar's face. Accepts:
                          • a bundled preset name:
                              Alice, Marco, Captain, Nia, Riley
                          • a path to a portrait image (JPG / PNG / HEIC).
                            Face is cropped automatically; any size works.
                         If omitted, the default agent's face is used.

  --prompt <text|@path>  Override the bot's personality / system prompt.
                         Inline text OR @/path/to/file.txt. Works for
                         text, voice (local + --openai), and avatar modes.

  --openai               (text + voice + video) Force the cloud backend —
                         OpenAI Realtime for voice/video audio, Chat
                         Completions for text. Avatar lipsync still
                         renders locally. Requires OPENAI_API_KEY.
                         Auto-picked when the key is set even without
                         this flag.

  --local                (text + voice + video) Force the fully
                         on-device pipeline. Voice: ~5 GB first-run
                         download (LLM + TTS + speech). Text: ~2 GB
                         (Gemma only). Video: ~7 GB (avatar + LLM + TTS
                         + speech). Auto-picked when no OPENAI_API_KEY
                         is set. Mutually exclusive with --openai.

  --identity <path>      (avatar only) Unified avatar identity. Resolves
                         by file extension:
                          • `.imx`  → packed avatar bundle (Expression
                            or Essence; same as `--model`).
                          • image → portrait JPG/PNG/HEIC (same as
                            `--image`).
                         Pass either `--identity`, `--image`, or
                         `--model` — not multiple.

  --openai-model <id>    Cloud model id. Defaults differ by mode:
                         voice → `gpt-realtime-mini`
                         text  → `gpt-4o-mini`
                         Pass any compatible model name to override.

  -h, --help             Show this help and exit.

\u{1B}[1mCONTROLS\u{1B}[0m (voice / video)
  Talk:        just speak after you see "🎙️  Listening".
  Type:        type a message and hit Enter — same as speaking.
  Cut in:      start talking while the bot is replying — it stops within ~50 ms.
  Right-click: (video) open the persona menu — agents, image, voice, prompt.
  Drag-drop:   (video) drop a portrait onto the avatar to swap the face.
  Quit:        ⌘Q (video), or Ctrl-C from the terminal.

\u{1B}[1mENV\u{1B}[0m
  BITHUMAN_VERBOSE=1    Show model-loading internals (silent by default).
  OPENAI_API_KEY        Required when running with `--openai`. If unset,
                        the CLI falls back to a 0600 file at
                        `~/Library/Application Support/com.bithuman.cli/openai-api-key`,
                        populated automatically the first time you accept
                        the auto-pick prompt. Remove with:
                          rm ~/Library/Application\\ Support/com.bithuman.cli/openai-api-key
  VOICECHAT_VERBOSE=1   When `--openai` is on, dump every realtime API
                        event for debugging.

\u{1B}[1mDOCS\u{1B}[0m
  https://github.com/bithuman-product/homebrew-bithuman
  https://www.bithuman.ai
"""

// MARK: - Argv parsing

private func nextValue(_ flag: String, _ it: inout IndexingIterator<[String]>) -> String {
    guard let v = it.next() else { fatalUsage("\(flag) needs a value") }
    if v.hasPrefix("-") {
        fatalUsage("\(flag) needs a value but got the flag '\(v)'. Did you forget the argument?")
    }
    return v
}

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
            args.localeIdentifier = nextValue("--locale", &it)
        case "--voice":
            args.voiceArg = nextValue("--voice", &it)
        case "--image":
            args.imageArg = nextValue("--image", &it)
        case "--model":
            args.modelArg = nextValue("--model", &it)
        case "--identity":
            args.identityArg = nextValue("--identity", &it)
        case "--prompt":
            guard let v = it.next() else { fatalUsage("--prompt needs a string or @path") }
            args.promptArg = v
        case "--openai":
            args.openAI = true
        case "--local":
            args.local = true
        case "--openai-model":
            args.openAIModel = nextValue("--openai-model", &it)
        case "-h", "--help":
            print(helpText)
            exit(0)
        default:
            fatalUsage("unknown argument '\(arg)'")
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
            warn("--locale is ignored in text mode (no ASR/TTS).")
        }
        if args.voiceArg != nil {
            warn("--voice is ignored in text mode (no TTS).")
        }
        if args.imageArg != nil {
            warn("--image is ignored in text mode.")
        }
        if args.modelArg != nil {
            warn("--model is ignored in text mode (no avatar engine).")
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
            warn("--locale is ignored under --openai (the realtime model auto-detects the input language).")
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
            warn("flags ignored — `\(args.mode.rawValue)` mode takes no options.")
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

@MainActor
private func resolveVoice(_ args: CLIArgs) async -> VoiceSelection {
    guard let raw = args.voiceArg else { return .default }
    if let canonical = VoiceSelection.canonicalPreset(matching: raw) {
        return .preset(canonical)
    }
    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            fatalUsage("--voice file not readable: \(url.path)")
        }
        let transcript = await resolveTranscript(
            audioURL: url,
            locale: Locale(identifier: args.localeIdentifier)
        )
        return .clone(referenceAudio: url, transcript: transcript)
    }
    fatalUsage("""
        --voice '\(raw)' isn't a recognised preset and no file exists at that path.
          Valid presets: \(VoiceSelection.presetNames.joined(separator: ", "))
          Or supply a path to a 10–20 s mono audio file (WAV / AIFF / M4A).
        """)
}

@MainActor
private func resolveTranscript(audioURL: URL, locale: Locale) async -> String {
    let sibling = audioURL.deletingPathExtension().appendingPathExtension("txt")
    if let cached = (try? String(contentsOf: sibling, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
        return cached
    }
    print("🎧 transcribing reference audio with Apple Speech…")
    do {
        let transcript = try await transcribeAudioFile(at: audioURL, locale: locale)
        try? transcript.write(to: sibling, atomically: true, encoding: .utf8)
        print("🎧 cached transcript → \(sibling.lastPathComponent)")
        return transcript
    } catch {
        fatalUsage("Couldn't auto-transcribe \(audioURL.lastPathComponent): \(error)")
    }
}

private func readInlineOrFile(_ arg: String) -> String? {
    guard arg.hasPrefix("@") else {
        let s = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    let path = (String(arg.dropFirst()) as NSString).expandingTildeInPath
    guard let contents = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        return nil
    }
    let s = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// Actionable error string for the "user passed `--openai` but no
/// key is reachable" case. Replaces the bare "set OPENAI_API_KEY"
/// hint with a copy-paste-able set of fixes covering the three
/// places we look for the key (env var, saved file, paste in).
/// Construct a `BithumanHeartbeat` if a developer key is reachable
/// (env or saved file). Returns nil with a one-time hint when
/// neither is set so the user knows where to get one. Shared
/// between Expression and Essence cloud runners — only the
/// `billingType` and `tags` differ between the two.
private func makeBithumanHeartbeat(
    billingType: String,
    tags: String
) -> BithumanHeartbeat? {
    guard let key = BithumanKey.load(), !key.isEmpty else {
        FileHandle.standardError.write(Data("""
            ℹ️  No BITHUMAN_API_KEY set — running unmetered.
               Get a key at \(BithumanKey.signupURL) and either:
                 export BITHUMAN_API_KEY=...
               or save it once:
                 mkdir -p ~/Library/Application\\ Support/com.bithuman.cli
                 printf %s 'sk-...' > ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key
                 chmod 600     ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key

            """.utf8))
        return nil
    }
    return BithumanHeartbeat(config: BithumanAuthConfig(
        apiSecret: key,
        billingType: billingType,
        tags: tags
    ))
}

private func missingKeyMessage() -> String {
    let cyan = "\u{1B}[36m"
    let bold = "\u{1B}[1m"
    let dim = "\u{1B}[2m"
    let reset = "\u{1B}[0m"
    return """
        --openai needs an OpenAI API key, and none was found.

        \(bold)Pick the option that fits:\(reset)

          \(bold)1.\(reset) \(dim)Easiest — paste a key now (we'll save it for next time):\(reset)
                \(cyan)bithuman-cli avatar\(reset)
              When prompted, paste your key and answer "y" to "Save it locally?"

          \(bold)2.\(reset) \(dim)Export in your shell so every tool sees it:\(reset)
                \(cyan)echo 'export OPENAI_API_KEY=sk-...' >> ~/.zshrc\(reset)
                \(cyan)source ~/.zshrc\(reset)

          \(bold)3.\(reset) \(dim)Write the saved-key file directly:\(reset)
                \(cyan)mkdir -p ~/Library/Application\\ Support/com.bithuman.cli\(reset)
                \(cyan)printf %s 'sk-...' > ~/Library/Application\\ Support/com.bithuman.cli/openai-api-key\(reset)
                \(cyan)chmod 600     ~/Library/Application\\ Support/com.bithuman.cli/openai-api-key\(reset)

        \(dim)Get a key at https://platform.openai.com/api-keys\(reset)
        """
}

/// Like `fatalUsage` but skips the full help-text dump — the
/// message itself is already self-contained instructions, and
/// stacking the entire `--help` block beneath it just buries the
/// thing the user actually needs to read.
private func fatalKey() -> Never {
    FileHandle.standardError.write(Data("error: \(missingKeyMessage())\n\n".utf8))
    exit(2)
}

private func fatalUsage(_ message: String) -> Never {
    // Tight error first, then a one-liner pointer to --help. Dumping
    // the full help text on every malformed flag was producing an
    // overwhelming wall of output that buried the actual cause.
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    FileHandle.standardError.write(Data("Run `bithuman-cli --help` for usage.\n".utf8))
    exit(2)
}

private func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

@MainActor
private func makeConfig(_ args: CLIArgs) -> VoiceChatConfig {
    var config = VoiceChatConfig()
    config.localeIdentifier = args.localeIdentifier
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        config.systemPrompt = resolved
    }
    // Resolve the avatar API key in priority order:
    //   1. BITHUMAN_API_KEY env (developer override)
    //   2. The key compiled into this binary at release time
    //      (only present in distributed CLI builds — see
    //      `BithumanEmbeddedKey.value`).
    // Audio-only and text modes don't need this; only video mode
    // hits VoiceChat.start()'s API-key check. Setting it here for
    // all configs keeps the CLI consistent.
    if let envKey = ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"],
       !envKey.isEmpty {
        config.apiKey = envKey
    } else if let bundled = BithumanEmbeddedKey.value {
        config.apiKey = bundled
    }
    return config
}

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

@MainActor
private func resolvePortrait(_ raw: String?) -> URL? {
    guard let raw else { return nil }
    // Bundled gallery first — preset names take precedence over a
    // (probably accidental) file at the same path.
    if let preset = PortraitGallery.presetURL(matching: raw) {
        return preset
    }
    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            fatalUsage("--image: file at '\(url.path)' isn't readable.")
        }
        return url
    }
    fatalUsage("""
        --image '\(raw)' is neither a bundled preset nor a path on disk.
          Bundled presets: \(PortraitGallery.presetNames.joined(separator: ", "))
          Or pass a path to a portrait image (JPG / PNG / HEIC).
        """)
}

/// All async setup for `bithuman-cli video`. Called from the AppDelegate's
/// `applicationDidFinishLaunching` so it runs *after* NSApp.run() has
/// taken over the main thread — that's the only way the main-actor
/// dispatches inside `FramePump`'s render loop actually reach the
/// runloop. (Doing this from a top-level `try await` chain leaves the
/// main dispatch queue starved; every render hangs forever.)
///
/// **Dispatch.** When `--model <path>` is supplied we peek the file's
/// manifest via ``Bithuman/createRuntime(modelPath:)`` and route to
/// ``runEssenceVideoSession(args:modelPath:)`` for Essence `.imx`
/// files; Expression files (and the no-`--model` default, which uses
/// the bundled weights) fall through to the original code path
/// unchanged. Doing the peek-and-dispatch up here keeps the
/// Expression body byte-for-byte identical to commit 12 — important
/// for the "no regression" contract on this commit.
@MainActor
func runVideoSession(args: CLIArgs) async throws {
    if let hint = videoHardwareHint(args: args) {
        FileHandle.standardError.write(Data("\n\(hint)\n\n".utf8))
    }
    if let modelArg = args.modelArg {
        let url = URL(fileURLWithPath: (modelArg as NSString).expandingTildeInPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            fatalUsage("--model: file not found at '\(url.path)'.")
        }
        // Peek the manifest's model_type before paying for any
        // engine warm-up. `peekModelType` only reads the IMX header
        // + manifest.json (~few ms of disk I/O) so misuse surfaces
        // immediately — not five seconds into a wasted DiT load.
        let modelType: String?
        do {
            modelType = try Bithuman.peekModelType(modelPath: url)
        } catch let err as BithumanCreateError {
            switch err {
            case .invalidModelFile(let msg):
                fatalUsage("--model: '\(url.lastPathComponent)' isn't a valid .imx (\(msg)).")
            default:
                fatalUsage("--model: \(err)")
            }
        } catch {
            fatalUsage("--model: \(error)")
        }
        switch modelType {
        case "expression":
            if args.openAI {
                try await runExpressionVideoSessionOpenAIWebRTC(args: args, modelPath: url)
            } else {
                try await runExpressionVideoSession(args: args, modelPath: url)
            }
            return
        case "essence":
            if args.openAI {
                try await runEssenceVideoSessionOpenAIWebRTC(args: args, modelPath: url)
            } else {
                try await runEssenceVideoSession(args: args, modelPath: url)
            }
            return
        case let other:
            let label = other ?? "<missing model_type>"
            fatalUsage("""
                --model: '\(url.lastPathComponent)' has model_type=\(label).
                  bithuman-cli accepts model_type=\"expression\" or \"essence\".
                """)
        }
    }
    // No `--model` / `--identity` was supplied — default to the
    // Expression engine with the bundled Diego portrait. Auto-pick
    // cloud (WebRTC) when an OpenAI key is set, otherwise local.
    if args.openAI {
        try await runExpressionVideoSessionOpenAIWebRTC(args: args, modelPath: nil)
    } else {
        try await runExpressionVideoSession(args: args, modelPath: nil)
    }
}

/// Essence-mode video session. Boots a `VoiceChat` WITHOUT
/// `config.avatar` (so it skips the Expression engine + heartbeat
/// branch entirely), then layers an Essence-shaped audio + frame
/// fan-out on top:
///
///   1. ``EssenceRuntime/create`` — opens the .imx, validates
///      `model_type`, builds the per-frame generator. Throws on
///      unsupported hardware / malformed file with the same typed
///      error surface the Expression path uses.
///   2. ``AvatarWindow`` with `clipMode=.fill` at the manifest's
///      `output_resolution` — borderless rectangular floating window.
///   3. PCM observer on the TTS player (Qwen3-TTS in voice mode by
///      default; the only TTS active here since `config.avatar` is
///      nil): each chunk is resampled to 16 kHz Int16 and pushed
///      into ``EssenceRuntime/pushAudio(_:)``.
///   4. Consumer task drains ``EssenceRuntime/frames()`` and
///      forwards each `CGImage` to the window's renderer.
///
/// `--voice` and `--image` are no-ops on this path — Essence's
/// voice and identity are baked into the .imx at pack time. We print
/// a friendly note rather than silently ignoring the flag so the
/// user knows their argument didn't take.
/// Replace the running CLI process with a fresh `bithuman-cli video
/// --model <newPath>` invocation. Used by the Essence right-click
/// menu's "Choose model…" action — hot-swapping the .imx in place
/// would mean tearing down `EssenceRuntime`, the frame consumer, the
/// PCM bridge, and possibly resizing the window if the new
/// manifest's `output_resolution` differs. Process replacement is a
/// 5-line equivalent that's trivially correct; hot-swap is queued
/// for v2.
///
/// `execv` semantics: the current process image is replaced by the
/// new one (same PID, same parent). If the user launched from a
/// terminal, the terminal session continues uninterrupted; if from
/// `open`, the avatar window blanks for a beat then reappears with
/// the new model. Splash + boot progress run as usual.
@MainActor
private func relaunchEssenceProcess(modelPath: URL) {
    let exec = CommandLine.arguments.first ?? "/usr/bin/env"
    let argv = [
        exec,
        "video",
        "--model", modelPath.path
    ]
    // execv requires C strings + a NULL terminator. `withCString`
    // gives us valid pointers for the duration of the call; execv
    // never returns on success.
    let cstrings = argv.map { strdup($0) }
    defer { cstrings.forEach { free($0) } }
    var argvPtr: [UnsafeMutablePointer<CChar>?] = cstrings.map { $0 }
    argvPtr.append(nil)
    print("🔁 swapping to \(modelPath.lastPathComponent)…")
    fflush(stdout)
    _ = argvPtr.withUnsafeMutableBufferPointer { buf in
        execv(exec, buf.baseAddress!)
    }
    // execv only returns if it failed — print and exit so we don't
    // continue with a torn-down session.
    let err = String(cString: strerror(errno))
    FileHandle.standardError.write(Data(
        "error: failed to relaunch (\(err)). Quit and rerun manually with --model.\n".utf8
    ))
    exit(1)
}

@MainActor
private func runEssenceVideoSession(args: CLIArgs, modelPath: URL) async throws {
    if args.imageArg != nil {
        print("note: --image is a no-op for Essence avatars — the .imx bakes its identity in at pack time. The flag has been dropped for this session.")
    }
    // --voice IS honoured for Essence: the avatar's identity is
    // baked into the .imx, but the voice driving the lip-sync comes
    // from the TTS player (Qwen3-TTS in voice mode). The right-click
    // menu lets the user hot-swap the voice at runtime; the flag
    // here is for parity with `bithuman-cli voice --voice …` so the
    // user can boot directly into a chosen voice.

    // Unified boot UI for the Essence path. Engine load + VoiceChat
    // pipeline (LLM, TTS, audio graph) all flow through the same
    // ``BootProgress`` so the user sees one self-overwriting
    // status line in their terminal AND a graphical splash window
    // covering the same stages — no blank-screen gap before the
    // avatar window opens.
    // Terminal-only progress: the build-log style block from
    // TerminalProgressRenderer is rich enough to keep the user
    // engaged without a graphical splash. Avatar window opens once
    // boot completes — see below.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    boot.update(.loadingExpressionEngine)
    // Push the synchronous engine load off the main actor — same
    // rationale as the Expression branch: avoids freezing any
    // SwiftUI redraws during the multi-second weight unpack.
    let runtime = try await Task.detached(priority: .userInitiated) {
        try EssenceRuntime.create(modelPath: modelPath)
    }.value
    let resolution = runtime.resolution
    let size = CGSize(width: resolution.width, height: resolution.height)

    // Audio-only VoiceChat — no AvatarConfig, no Expression engine,
    // no heartbeat. The Essence runtime is wired up below as a
    // PCM-observer side-channel rather than through the
    // Expression-shaped `AvatarConfig` plumbing in `VoiceChat.start()`.
    var config = makeConfig(args)
    // Honour --voice (preset name or path-to-audio for cloning) the
    // same way `bithuman-cli voice` does. Defaults to .default when
    // the flag isn't supplied.
    config.voice = await resolveVoice(args)
    config.bootProgress = boot
    let chat = VoiceChat(config: config)
    try await chat.start()
    boot.update(.ready)
    renderer.detach()

    let window = AvatarWindow(targetSize: size, clipMode: .fill)
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Right-click menu: Choose model… / Change voice ▶ / Change
    // prompt… / Quit. Hooks into the same coordinator the Expression
    // path uses so PromptEditorWindow can reuse `setSystemPrompt`,
    // and into VoiceChat for hot-swapping the Qwen3 reference voice.
    let coordinator = AvatarCoordinator(chat: chat)
    coordinator.bindToOrchestrator()
    coordinator.currentSystemPrompt = config.systemPrompt ?? ""
    let menuHandler = EssenceMenuHandler(
        chat: chat,
        coordinator: coordinator,
        currentModelPath: modelPath,
        relaunchWithModel: { newURL in
            relaunchEssenceProcess(modelPath: newURL)
        }
    )
    let essenceMenu = menuHandler.buildMenu()
    window.contentView?.menu = essenceMenu
    // Renderer subview also takes the menu so right-click on the
    // avatar pixels (not just the empty corners) surfaces it.
    for sub in window.contentView?.subviews ?? [] {
        sub.menu = essenceMenu
    }

    // EssenceVoiceChatSession (promoted from CLI-internal in v0.18 so
    // the apps can share it). Owns the frame consumer task and the
    // PCM bridge.
    let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
    session.startConsuming()

    // PCM bridge: each TTS chunk → 16 kHz Int16 → runtime.pushAudio.
    await chat.setPCMObserver { [bridge = session.pcmBridge] pcm in
        bridge.handle(pcm)
    }
    // Essence has no FramePump to replay TTS audio; we want the
    // speaker to keep playing the bot directly. (Expression's
    // default is to suppress, which is what `VoiceChat.start()`
    // installs for the avatar branch — but we never took that
    // branch since `config.avatar == nil`. The TTS player still
    // defaults to "suppress when observed" though, so we have to
    // explicitly opt out of that here.)
    await chat.setSuppressDirectPlaybackWhenObserved(false)

    // Park the chat + session on the AppDelegate so they outlive
    // this function — without explicit retains they'd be released
    // and the avatar would freeze. The delegate's existing
    // `retainSession` API takes a `FramePump`, which Essence
    // doesn't use, so we only stash the chat. The session itself
    // is captured by the strong reference in the chat's PCM
    // observer closure, keeping the runtime + window alive for
    // the lifetime of the chat.
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainEssenceSession(chat: chat, session: session)
        // Pin the menu handler too — NSMenu's target/action holds a
        // weak ref through the menu item, so without an external
        // strong ref the handler would deallocate at scope exit and
        // every selection would be a no-op.
        delegate.retainEssenceMenuHandler(menuHandler)
    }

    // Stdin reader — same shape as the Expression path's, lets the
    // user type messages through the same orchestrator turn flow.
    Task.detached(priority: .background) { [chat] in
        while !Task.isCancelled, let line = readLine() {
            await chat.inject(userText: line)
        }
    }

    print("🎥 essence avatar window ready. Talk or type any time. Ctrl-C or ⌘Q to quit.")
}

/// Essence video session driven by OpenAI Realtime over WebRTC.
/// Same transport as `voice --openai`, plus an `RTCAudioRenderer`
/// hooked to the inbound bot audio track so we get every PCM buffer
/// libwebrtc plays — perfect for `EssenceRuntime.pushAudio` lipsync.
/// libwebrtc handles speaker output AND mic capture (with built-in
/// AEC + NS + AGC), so we don't need our own `AudioGraph` here at
/// all — the host system speaker plays the bot's voice and the
/// renderer just observes the same PCM stream on its way out.
@MainActor
private func runEssenceVideoSessionOpenAIWebRTC(args: CLIArgs, modelPath: URL) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        fatalKey()
    }

    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"

    // Boot block. No audio graph needed — libwebrtc owns mic +
    // speaker. The Essence runtime is the only heavy load step.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    boot.update(.loadingEssenceRuntime)
    let runtime = try await Task.detached(priority: .userInitiated) {
        try EssenceRuntime.create(modelPath: modelPath)
    }.value
    let resolution = runtime.resolution
    let size = CGSize(width: resolution.width, height: resolution.height)

    // bitHuman billing heartbeat — Essence runtime is metered at
    // 1 credit/min. Same fallback to unmetered when no key.
    let bithumanHeartbeat = makeBithumanHeartbeat(
        billingType: BithumanAuthConfig.selfHostedEssenceModel,
        tags: "bithuman-cli/avatar/essence"
    )
    if let hb = bithumanHeartbeat {
        do { try await hb.authenticate(); await hb.resume() }
        catch {
            FileHandle.standardError.write(Data(
                "‼ bitHuman billing heartbeat failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    boot.update(.connectingRealtime)

    // Open the avatar window before WebRTC connects so the user sees
    // something while the SDP exchange runs.
    let window = AvatarWindow(targetSize: size, clipMode: .fill)
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
    session.startConsuming()

    // Reuse the voice-mode UI for live mic + bot bars + transcripts.
    let ui = TerminalUI()
    await ui.start()
    // Per-minute spend reporter: prints elapsed time + accrued
    // bitHuman credits + estimated OpenAI $ to the scrolling area.
    let spendTracker = SpendTracker(
        runtime: .essence,
        ui: ui,
        openAIModel: args.openAIModel
    )
    await spendTracker.start()
    let voiceKnown = ["alloy", "ash", "ballad", "coral", "echo",
                      "sage", "shimmer", "verse", "marin", "cedar"]
        .contains(voice.lowercased())

    // Bot-PCM tap: every buffer libwebrtc would play through the
    // speaker is also delivered here. Convert from whatever format
    // libwebrtc is rendering at (typically 48 kHz Float32) to 16 kHz
    // Int16 mono and push into Essence for lipsync. Reset converter
    // when format changes (rare; libwebrtc renegotiates).
    let lipsyncFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    let converterBox = ConverterBox()
    let onBotPCM: @Sendable (AVAudioPCMBuffer) -> Void = { [ui, runtime] buffer in
        guard let conv = converterBox.converter(for: buffer.format, target: lipsyncFormat) else { return }
        let inFrames = Int(buffer.frameLength)
        let outCap = AVAudioFrameCount(Double(inFrames) * 16_000.0 / buffer.format.sampleRate + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: lipsyncFormat, frameCapacity: outCap) else { return }
        var delivered = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, statusOut in
            if delivered { statusOut.pointee = .noDataNow; return nil }
            delivered = true
            statusOut.pointee = .haveData
            return buffer
        }
        guard status != .error, let i16 = out.int16ChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let samples = Array(UnsafeBufferPointer(start: i16, count: n))

        // RMS for the UI bot bar — quick subsample.
        var sum: Double = 0
        var c = 0
        var i = 0
        while i < n { let s = Double(samples[i]) / 32768.0; sum += s * s; c += 1; i += 8 }
        let rms: Float = c > 0 ? Float((sum / Double(c)).squareRoot()) : 0

        Task {
            await runtime.pushAudio(samples)
            await ui.setBotLevel(rms)
        }
    }

    // Connect the WebRTC client with the lipsync tap installed.
    let client = RealtimeWebRTCClient(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        ui: ui,
        verbose: verbose,
        onBotPCM: onBotPCM
    )
    try await client.connect()

    boot.update(.ready)
    renderer.detach()
    await ui.printOpeningBanner(
        model: args.openAIModel,
        voice: voice,
        verbose: verbose,
        keyValidated: true,
        voiceKnown: voiceKnown
    )

    // The receive loop is the same one voice mode uses — it drives
    // every state transition in the UI from the data-channel events.
    Task { try? await client.runReceiveLoop() }

    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = (client, runtime, session, window, ui, converterBox, bithumanHeartbeat, spendTracker)
}

/// Box for an AVAudioConverter so a `@Sendable` closure can capture
/// it across calls without crossing actor boundaries. The closure
/// only ever runs on libwebrtc's audio render thread, so there's no
/// real concurrent use — the box just satisfies the type checker.
final class ConverterBox: @unchecked Sendable {
    private var conv: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    func converter(for src: AVAudioFormat, target: AVAudioFormat) -> AVAudioConverter? {
        if conv == nil || srcFormat?.sampleRate != src.sampleRate
            || srcFormat?.channelCount != src.channelCount {
            conv = AVAudioConverter(from: src, to: target)
            srcFormat = src
        }
        return conv
    }
}


/// Expression video session driven by OpenAI Realtime over WebRTC.
/// Mirrors `runEssenceVideoSessionOpenAIWebRTC` but for the
/// Expression engine — auto-downloads weights when no `.imx` is
/// supplied, resolves a portrait identity (custom image or the
/// bundled default agent), constructs `Bithuman` directly without
/// `VoiceChat` (no local LLM/TTS/ASR needed in cloud mode), and
/// drives lipsync from the inbound bot audio track via
/// `Bithuman.pushAudio(audio24k:audio16k:)`. libwebrtc owns the
/// speaker (with built-in AEC + NS + AGC), so the FramePump runs
/// in cloud mode where its speech-audio playback hook is `nil`.
@MainActor
private func runExpressionVideoSessionOpenAIWebRTC(
    args: CLIArgs,
    modelPath: URL?
) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        fatalKey()
    }

    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"

    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    // Auto-download Expression weights when no `.imx` was supplied.
    // Same `ExpressionWeights.ensureAvailable` flow the local Expression
    // runner uses, so cache hits are byte-identical and reusable across
    // local / cloud sessions.
    let weightsURL: URL
    if let modelPath {
        weightsURL = modelPath
    } else {
        weightsURL = try await ExpressionWeights.ensureAvailable(
            progress: { phase in
                switch phase {
                case .verifying:
                    boot.update(.verifyingEngine)
                case .downloading(_, let received, let total, let bps, let eta):
                    boot.update(.downloadingEngine(
                        received: received, total: total,
                        bytesPerSecond: bps, etaSeconds: eta
                    ))
                case .verifyingDownloaded:
                    boot.update(.verifyingEngine)
                case .ready:
                    break
                }
            },
            silenceStderr: true
        )
    }

    // Resolve the portrait identity. With `--identity <image>` /
    // `--image <path>` we use that face; otherwise the bundled default
    // agent (Diego) — same default as local Expression mode.
    let defaultAgent = AgentCatalog.defaultAgent
    if instructions == nil {
        instructions = defaultAgent.systemPrompt
    }
    let portraitURL = resolvePortrait(args.imageArg)
        ?? AgentCatalog.thumbnailURL(for: defaultAgent)
    let identity: Bithuman.Identity = portraitURL.map { .image($0) } ?? .default

    // Construct the engine. ~5–10 s on Apple Silicon for the ANE shader
    // compile + weight quantize on a warm cache (longer first run).
    boot.update(.loadingExpressionEngine)
    let createResult = try await Task.detached(priority: .userInitiated) {
        try Bithuman.create(modelPath: weightsURL, identity: identity)
    }.value
    let bithuman = createResult.bithuman

    // bitHuman billing heartbeat — tags this session against the
    // user's ImagineX account at 2 credits/min for Expression.
    // Without `BITHUMAN_API_KEY` we run unmetered (development);
    // print a one-time hint so the user knows about the dashboard.
    let bithumanHeartbeat = makeBithumanHeartbeat(
        billingType: BithumanAuthConfig.selfHostedExpressionModel,
        tags: "bithuman-cli/avatar/expression"
    )
    if let hb = bithumanHeartbeat {
        do { try await hb.authenticate(); await hb.resume() }
        catch {
            FileHandle.standardError.write(Data(
                "‼ bitHuman billing heartbeat failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }

    // Construct the FramePump + window NOW, but keep the window
    // hidden until idle-prewarm completes. In cloud mode, the WebRTC
    // bot-audio tap pushes a continuous stream of `pendingAudio` into
    // the engine, which keeps `bithuman.snapshot.pendingAudio16Count`
    // non-zero and starves the producer's idle-generation path.
    // Result: the visual splash sits stuck at whatever fill % the
    // cache had when the first audio chunk arrived (the user saw
    // "warming up — 13%" forever). The fix is to fill the cache
    // BEFORE WebRTC connects so no audio is competing for engine
    // dispatches.
    let coordinator = AvatarCoordinator()
    let window = AvatarWindow(idleFrame: createResult.staticIdleImage, coordinator: coordinator)

    // UI created up front so the speaker callback below can capture
    // it. Actual `await ui.start()` is deferred until after the
    // boot block clears (so the sticky-area renders don't fight the
    // multi-step progress block); calls before `start()` are
    // harmless no-ops since the render task hasn't been spun up.
    let ui = TerminalUI()

    // Apple-stack chunk-paired playback (the version that had A/V
    // sync). LiveKit's AudioEngine ADM creates an internal
    // AVAudioEngine; AudioEngineADMSpeaker hooks `didCreateEngine`
    // to attach an AVAudioPlayerNode + gainMixer to that engine,
    // enables Apple VP-IO on input/output for AEC, and rewires
    // the engine output so libwebrtc's auto-route is silenced
    // (outputVolume=0) while our player feeds the speaker. AEC
    // operates on the same engine our player drives — VP-IO
    // subtracts our chunk audio from the mic capture.
    let speaker = AudioEngineADMSpeaker(verbose: verbose, onPlay: { @Sendable [ui] rms in
        Task { await ui.setBotLevel(rms) }
    })
    let pump = FramePump(
        bithuman: bithuman,
        window: window,
        coordinator: coordinator,
        playSpeechAudio: { @Sendable [speaker] samples in
            speaker.play(samples24k: samples)
        }
    )
    coordinator.framePump = pump
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainSession(chat: bithuman, pump: pump)
    }

    // Try to load a previously-persisted idle palindrome from disk
    // before generating fresh frames. Same identity = same baseline
    // motion, so the cached frames are byte-for-byte equivalent to
    // what we'd regenerate. ~5–10 s saved on every cold start
    // after the first.
    let identityKey = IdleFrameDiskCache.identityKey(
        weightsURL: weightsURL,
        portraitURL: portraitURL
    )
    var seededFromDisk = false
    if let cached = IdleFrameDiskCache.load(identityKey: identityKey) {
        pump.seedIdleCache(frames: cached)
        seededFromDisk = true
        if verbose {
            FileHandle.standardError.write(Data(
                "↦ idle frames seeded from disk (\(cached.count) frames, key=\(identityKey))\n".utf8
            ))
        }
    }

    // Pre-warm the idle palindrome cache. With no audio flowing,
    // the producer hits the `generateIdleChunk` path on every loop
    // and the cache fills in ~5–10 s on M-series. Cap the wait at
    // 60 s so a misbehaving engine can't deadlock the boot.
    // Skips entirely when the disk cache hit above, since
    // `idlePrewarmReady` is already true.
    boot.update(.prewarmingIdle(progress: 0))
    let prewarmStart = Date()
    while !coordinator.idlePrewarmReady,
          Date().timeIntervalSince(prewarmStart) < 60 {
        boot.update(.prewarmingIdle(progress: coordinator.idlePrewarmProgress))
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    // Persist freshly-generated frames so subsequent launches with
    // this identity skip prewarm. Background-priority — don't block
    // the WebRTC connect on disk I/O.
    if !seededFromDisk, coordinator.idlePrewarmReady {
        let snapshot = pump.snapshotIdleCache()
        Task.detached(priority: .background) {
            IdleFrameDiskCache.save(snapshot, identityKey: identityKey)
        }
    }

    // Cache is full (or we hit the safety cap) — now show the window.
    // The renderer's CALayer is already up-to-date because the
    // FramePump's consumer timer has been ticking the latest idle
    // frame into it the whole time, so the user sees a fully
    // animated avatar the moment the window pops up.
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // `ui` was constructed earlier (so the speaker callback could
    // capture it); start the render task now that the boot block
    // has cleared.
    await ui.start()
    // Per-minute spend reporter — Expression is metered at 2
    // credits/min; the tracker's 60 s tick prints accrued cost
    // for both bitHuman and OpenAI to the scrolling area.
    let spendTracker = SpendTracker(
        runtime: .expression,
        ui: ui,
        openAIModel: args.openAIModel
    )
    await spendTracker.start()
    let voiceKnown = ["alloy", "ash", "ballad", "coral", "echo",
                      "sage", "shimmer", "verse", "marin", "cedar"]
        .contains(voice.lowercased())

    // Bot-PCM tap: every buffer libwebrtc plays through the speaker
    // is also delivered here. Resample 48 kHz Float → 24 kHz Float
    // and 16 kHz Float (Bithuman wants both for lipsync). Pushed
    // into the engine asynchronously; FramePump's producer dequeues
    // the resulting `TimedChunk`s and renders them.
    let conv24Box = ConverterBox()
    let conv16Box = ConverterBox()
    let fmt24 = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    let fmt16 = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    // Flag set true when the bot is actively responding (between
    // `response.created` and `response.done`/`cancelled`). When
    // false, `onBotPCM` skips the `bithuman.pushAudio` call —
    // OpenAI's WebRTC track sends silence padding during user
    // listening/hearing/thinking, and feeding that into the
    // engine causes it to dispatch DiT chunks for silence,
    // burning GPU on lipsync frames the user never sees.
    let botActiveBox = AtomicBool(initial: false)

    let pcmDiagBox = AtomicCounter()
    let onBotPCM: @Sendable (AVAudioPCMBuffer) -> Void = { [bithuman, ui, pcmDiagBox, verbose] buffer in
        let inFrames = Int(buffer.frameLength)
        guard inFrames > 0 else { return }
        pcmDiagBox.bump(inFrames)
        if verbose, pcmDiagBox.shouldReport() {
            FileHandle.standardError.write(Data(
                "→ onBotPCM fired \(pcmDiagBox.calls) times, \(pcmDiagBox.totalFrames) frames @ \(buffer.format.sampleRate)Hz · src=Bithuman feed\n".utf8
            ))
        }

        func resample(_ src: AVAudioPCMBuffer, to target: AVAudioFormat, conv: AVAudioConverter) -> [Float]? {
            let outCap = AVAudioFrameCount(Double(src.frameLength) * target.sampleRate / src.format.sampleRate + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return nil }
            var delivered = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, statusOut in
                if delivered { statusOut.pointee = .noDataNow; return nil }
                delivered = true
                statusOut.pointee = .haveData
                return src
            }
            guard status != .error, let p = out.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        }

        guard let conv24 = conv24Box.converter(for: buffer.format, target: fmt24),
              let conv16 = conv16Box.converter(for: buffer.format, target: fmt16),
              let s24 = resample(buffer, to: fmt24, conv: conv24),
              let s16 = resample(buffer, to: fmt16, conv: conv16)
        else { return }

        // Hz sanity check: expected ratios are exactly src→24k and
        // src→16k. If output is off by more than 1 sample per
        // chunk, the resampler is dropping/adding samples and
        // would cause cumulative A/V drift. Gated behind
        // `BITHUMAN_DEBUG_AUDIO=1` so default verbose runs stay
        // readable.
        let audioDebug = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_AUDIO"] == "1"
        if audioDebug, pcmDiagBox.shouldReport() {
            let srcRate = buffer.format.sampleRate
            let exp24 = Int(Double(inFrames) * 24_000.0 / srcRate)
            let exp16 = Int(Double(inFrames) * 16_000.0 / srcRate)
            FileHandle.standardError.write(Data(
                "→ resample: \(inFrames)@\(Int(srcRate)) → 24k: got \(s24.count) (exp \(exp24), Δ\(s24.count - exp24)) · 16k: got \(s16.count) (exp \(exp16), Δ\(s16.count - exp16))\n".utf8
            ))
        }

        // RMS for the bot meter. Now that libwebrtc plays the
        // bot's audio at realtime (its native auto-playback), the
        // arrival timing IS the playback timing — bar moves when
        // user hears audio.
        var sum: Double = 0
        var c = 0
        var i = 0
        while i < s16.count { let v = Double(s16[i]); sum += v * v; c += 1; i += 8 }
        let rms: Float = c > 0 ? Float((sum / Double(c)).squareRoot()) : 0
        Task {
            try? await bithuman.pushAudio(audio24k: s24, audio16k: s16)
            await ui.setBotLevel(rms)
        }
    }

    // Barge-in: when the user starts talking, immediately flush
    // every local pipeline so the bot's in-flight reply stops
    // dead instead of finishing over the user's voice.
    //
    //   1. Speaker queue — drop any scheduled audio buffers
    //      (`stopPlayback` then re-`play()` to re-arm).
    //   2. Frame buffer — drop queued speech frames so the avatar
    //      stops mouthing the cancelled reply within one display
    //      tick (~40 ms).
    //   3. Bithuman engine — `flush()` clears pendingAudio16/24
    //      and resets the streaming-pipeline counters so the next
    //      bot reply starts a fresh chunk window.
    let onUserSpeechStarted: @Sendable () async -> Void = { @Sendable [pump, bithuman, speaker] in
        // Barge-in: cut speaker, drop frames, snap to idle, flush
        // engine. Server cancel happens in the receive loop right
        // after this callback returns.
        speaker.stopPlayback()
        pump.buffer.flushSpeech()
        pump.snapToIdleNow()
        await bithuman.flush()
    }

    boot.update(.connectingRealtime)
    let client = RealtimeWebRTCClient(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        ui: ui,
        verbose: verbose,
        onBotPCM: onBotPCM,
        admSpeaker: speaker,
        onUserSpeechStarted: onUserSpeechStarted,
        onBotResponseActiveChange: { @Sendable [botActiveBox] active in
            botActiveBox.value = active
        }
    )
    try await client.connect()

    boot.update(.ready)
    renderer.detach()
    await ui.printOpeningBanner(
        model: args.openAIModel,
        voice: voice,
        verbose: verbose,
        keyValidated: true,
        voiceKnown: voiceKnown
    )

    Task { try? await client.runReceiveLoop() }

    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = (client, bithuman, pump, window, ui, speaker, bithumanHeartbeat, spendTracker)
}

/// Tiny atomic counter for reporting renderer / speaker activity
/// every ~1 s in verbose mode without spamming stderr per-buffer.
/// Tiny lock-protected boolean shared between the WebRTC receive
/// loop (writer, on the actor) and the renderer audio callback
/// (reader, on libwebrtc's audio render thread). Used to gate
/// `bithuman.pushAudio` on whether the bot is actively speaking,
/// so silence-padding RTP frames during user listening/hearing
/// don't burn GPU on DiT dispatches.
final class AtomicBool: @unchecked Sendable {
    private let q = DispatchQueue(label: "ai.bithuman.cli.atomicbool")
    private var _value: Bool
    init(initial: Bool) { self._value = initial }
    var value: Bool {
        get { q.sync { _value } }
        set { q.sync { _value = newValue } }
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let q = DispatchQueue(label: "ai.bithuman.cli.diag")
    private(set) var calls: Int = 0
    private(set) var totalFrames: Int = 0
    private var lastReport: Date = Date(timeIntervalSince1970: 0)
    func bump(_ frames: Int) {
        q.sync { calls += 1; totalFrames += frames }
    }
    func shouldReport() -> Bool {
        q.sync {
            let now = Date()
            if now.timeIntervalSince(lastReport) > 1.0 {
                lastReport = now
                return true
            }
            return false
        }
    }
}

/// Avatar (lipsync) stays local in `EssenceRuntime`; LLM/ASR/TTS
/// all happen server-side. Audio I/O is handled by `AudioGraph`
/// (Apple VP-IO for AEC) so laptop speakers + mic work without echo.
///
/// Pipeline:
///   mic → AudioGraph (VP-IO AEC) → 16/24 kHz PCM → WebSocket
///   ↑ server transcribes + responds
///   ↓ response.audio.delta (24 kHz PCM16)
///   → AudioGraph speaker (with VP-IO reference)
///   → resample to 16 kHz Int16 → EssenceRuntime.pushAudio
///   → EssenceRuntime emits frames → AvatarWindow
///
/// Skips the entire `VoiceChat` orchestrator since we don't need
/// local LLM/ASR/TTS; saves ~5 GB of model downloads on first run.
@MainActor
private func runEssenceVideoSessionOpenAI(args: CLIArgs, modelPath: URL) async throws {
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
          !apiKey.isEmpty
    else {
        fatalKey()
    }

    let voice: String
    if let raw = args.voiceArg, !raw.contains("/"), !raw.contains(".") {
        voice = raw
    } else {
        voice = "ash"
    }
    var instructions: String? = nil
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        instructions = resolved
    }

    // Reuse the same TerminalUI as `voice --openai` so users see a
    // live mic bar + bot bar + status pill + per-utterance histograms.
    // We still drive the multi-step boot block before the UI takes
    // over the sticky area, so the cold-start window stays informative.
    let verbose = ProcessInfo.processInfo.environment["VOICECHAT_VERBOSE"] == "1"
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    boot.update(.loadingEssenceRuntime)
    let runtime = try await Task.detached(priority: .userInitiated) {
        try EssenceRuntime.create(modelPath: modelPath)
    }.value
    let resolution = runtime.resolution
    let size = CGSize(width: resolution.width, height: resolution.height)

    boot.update(.openingAudioGraph)
    let graph = AudioGraph()
    try await graph.start()

    boot.update(.connectingRealtime)
    let client = RealtimeWebSocketClient(
        apiKey: apiKey,
        model: args.openAIModel,
        voice: voice,
        instructions: instructions,
        verbose: verbose
    )
    try await client.connect()

    boot.update(.ready)
    renderer.detach()

    // Hand the terminal off to the live UI.
    let ui = TerminalUI()
    await ui.start()
    let voiceKnown = ["alloy", "ash", "ballad", "coral", "echo",
                      "sage", "shimmer", "verse", "marin", "cedar"]
        .contains(voice.lowercased())
    await ui.printOpeningBanner(
        model: args.openAIModel,
        voice: voice,
        verbose: verbose,
        keyValidated: true,  // boot already exchanged session.update successfully
        voiceKnown: voiceKnown
    )
    await ui.setState(.listening)

    // Mic pump: tap the AudioGraph's micBuffers stream, downsample
    // each chunk to 24 kHz PCM16, and forward to the WS. AudioGraph's
    // tap is at the input node's hardware format (typically 48 kHz
    // mono Float32) with VP-IO already applied — clean signal for
    // the server's whisper.
    let realtimeFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    Task.detached(priority: .userInitiated) { [graph, client, realtimeFormat] in
        var converter: AVAudioConverter?
        var srcRate: Double = 0
        for await buffer in graph.micBuffers {
            if converter == nil || srcRate != buffer.format.sampleRate {
                converter = AVAudioConverter(from: buffer.format, to: realtimeFormat)
                srcRate = buffer.format.sampleRate
            }
            guard let conv = converter else { continue }
            let ratio = realtimeFormat.sampleRate / buffer.format.sampleRate
            let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: realtimeFormat, frameCapacity: outCap) else { continue }
            var delivered = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, statusOut in
                if delivered { statusOut.pointee = .noDataNow; return nil }
                delivered = true
                statusOut.pointee = .haveData
                return buffer
            }
            if status == .error || out.frameLength == 0 { continue }
            guard let int16Ptr = out.int16ChannelData?[0] else { continue }
            let data = Data(bytes: int16Ptr, count: Int(out.frameLength) * 2)
            await client.appendAudio(data)
        }
    }

    // Pump AudioGraph's mic-energy stream into the UI's mic level
    // bar AND drive a simple client-side VAD that triggers
    // `commit + response.create` when the user stops talking. We
    // don't trust server-side VAD here — empirically the WS
    // transport sees our PCM but never fires `speech_started`, so
    // the only way to get a reply is to commit manually.
    Task.detached(priority: .userInitiated) { [graph, ui, client] in
        let speakThreshold: Float = 0.025      // RMS above this counts as voice
        let silenceMs: Int = 600                // ms of quiet that ends a turn
        let minSpeechMs: Int = 200              // ignore very short blips
        var inSpeech = false
        var speechStart = Date()
        var lastVoice = Date()
        for await rms in graph.micEnergy {
            await ui.setMicLevel(rms)
            let now = Date()
            if rms > speakThreshold {
                if !inSpeech {
                    inSpeech = true
                    speechStart = now
                    await ui.setState(.hearing)
                    await ui.userSpeechStarted()
                }
                lastVoice = now
            } else if inSpeech {
                let quietFor = Int(now.timeIntervalSince(lastVoice) * 1000)
                let speechDur = Int(lastVoice.timeIntervalSince(speechStart) * 1000)
                if quietFor >= silenceMs, speechDur >= minSpeechMs {
                    inSpeech = false
                    await ui.setState(.thinking)
                    await client.commitAndRespond()
                } else if quietFor >= silenceMs {
                    inSpeech = false  // too short, abandon turn
                    await ui.setState(.listening)
                }
            }
        }
    }

    // Open avatar window centred on screen.
    let window = AvatarWindow(targetSize: size, clipMode: .fill)
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
    session.startConsuming()

    // Bot-event router: drives the live UI (mic / bot bars, status
    // pill, transcript timeline) AND fans bot audio out to the
    // speaker (AEC reference) + EssenceRuntime (lipsync).
    Task { [graph, runtime, ui] in
        let serverFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let lipsyncFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let lipsyncConverter = AVAudioConverter(from: serverFormat, to: lipsyncFormat)

        for await event in await client.events {
            switch event {
            case .sessionReady:
                await ui.setState(.listening)
            case .userSpeechStarted:
                await ui.setState(.hearing)
                await ui.userSpeechStarted()
            case .userSpeechStopped:
                await ui.setState(.thinking)
            case .userTranscript(let text):
                await ui.commitUserTranscript(text)
            case .botResponseStarted:
                await ui.setState(.responding)
                await ui.botResponseStarted()
            case .botTranscriptDelta(let delta):
                await ui.appendBotChunk(delta)
            case .botResponseEnded:
                await ui.endBotResponse()
                await ui.setState(.listening)
            case .botResponseCancelled:
                await ui.cancelledBotResponse()
                await ui.setState(.listening)
            case .error(let msg):
                await ui.errorLine("error: \(msg)")
            case .botAudio(let bytes):
                let frameCount = AVAudioFrameCount(bytes.count / 2)
                guard frameCount > 0,
                      let inBuf = AVAudioPCMBuffer(pcmFormat: serverFormat, frameCapacity: frameCount)
                else { continue }
                inBuf.frameLength = frameCount
                var rms: Float = 0
                if let dst = inBuf.int16ChannelData?[0] {
                    bytes.withUnsafeBytes { src in
                        guard let base = src.baseAddress else { return }
                        dst.update(from: base.assumingMemoryBound(to: Int16.self), count: Int(frameCount))
                    }
                    // Cheap RMS for the bot bar — sample every 8th
                    // value so a 1 s 24 kHz chunk costs ~3000 muls.
                    let n = Int(frameCount)
                    var sumSq: Double = 0
                    var count = 0
                    var i = 0
                    while i < n {
                        let s = Double(dst[i]) / 32768.0
                        sumSq += s * s
                        count += 1
                        i += 8
                    }
                    rms = count > 0 ? Float((sumSq / Double(count)).squareRoot()) : 0
                }
                await ui.setBotLevel(rms)

                // 1. Speaker — VP-IO sees this as the reference signal.
                await graph.schedulePlayback(inBuf)

                // 2. Lipsync — push 16 kHz Int16 into Essence.
                if let conv = lipsyncConverter {
                    let outCap = AVAudioFrameCount(Double(frameCount) * 16_000.0 / 24_000.0 + 16)
                    if let outBuf = AVAudioPCMBuffer(pcmFormat: lipsyncFormat, frameCapacity: outCap) {
                        var delivered = false
                        var err: NSError?
                        let status = conv.convert(to: outBuf, error: &err) { _, statusOut in
                            if delivered { statusOut.pointee = .noDataNow; return nil }
                            delivered = true
                            statusOut.pointee = .haveData
                            return inBuf
                        }
                        if (status == .haveData || status == .endOfStream),
                           let i16Ptr = outBuf.int16ChannelData?[0] {
                            let n = Int(outBuf.frameLength)
                            let samples = Array(UnsafeBufferPointer(start: i16Ptr, count: n))
                            await runtime.pushAudio(samples)
                        }
                    }
                }
            }
        }
    }

    // Park forever — Ctrl-C or ⌘Q tears the process down.
    let forever = AsyncStream<Void> { _ in }
    for await _ in forever { break }
    _ = (graph, client, runtime, session, window)
}

/// Original Expression-only video code path, preserved verbatim from
/// commit 12 except for the `modelPath` parameter (nil = use bundled
/// weights, non-nil = use the user-supplied `.imx`). Behaviour for
/// `bithuman-cli video` with no `--model` flag is byte-for-byte
/// identical to the previous release.
@MainActor
private func runExpressionVideoSession(args: CLIArgs, modelPath: URL? = nil) async throws {
    // Unified boot UI: a graphical splash window so the user sees a
    // progress bar from the very first second, plus a terminal
    // renderer so anyone who launched from a shell still gets the
    // status in their console. Both subscribe to the same
    // ``BootProgress`` instance.
    let boot = BootProgress()
    let renderer = TerminalProgressRenderer(progress: boot)
    renderer.attach()

    // Terminal-only progress for the Expression video path too — the
    // graphical splash has been retired in favour of the multi-line
    // TerminalProgressRenderer block. Avatar window appears at the
    // end (see below) without a teleport since we centre it.

    let weightsURL: URL
    if let modelPath {
        weightsURL = modelPath
    } else {
        // Forward DownloadPhase events into BootProgress so the same
        // renderer used by voice mode shows engine bytes / rate / ETA.
        // `silenceStderr: true` suppresses the legacy `📥 N%` lines
        // since the renderer already paints its own bar.
        weightsURL = try await ExpressionWeights.ensureAvailable(
            progress: { phase in
                switch phase {
                case .verifying:
                    boot.update(.verifyingEngine)
                case .downloading(_, let received, let total, let bps, let eta):
                    boot.update(.downloadingEngine(
                        received: received, total: total,
                        bytesPerSecond: bps, etaSeconds: eta
                    ))
                case .verifyingDownloaded:
                    boot.update(.verifyingEngine)
                case .ready:
                    break  // next phase is set by VoiceChat.start()
                }
            },
            silenceStderr: true
        )
    }
    // Fresh-user default: Diego (face + voice + prompt) unless the
    // CLI flags override pieces individually. Bake the portrait into
    // the avatar engine at boot so we don't pay a runtime VAE encode
    // for the default — instant Diego on first frame.
    let defaultAgent = AgentCatalog.defaultAgent
    let portraitURL = resolvePortrait(args.imageArg)
        ?? AgentCatalog.thumbnailURL(for: defaultAgent)
    let initialPrompt = args.promptArg ?? defaultAgent.systemPrompt

    // Resolve the Kokoro preset for video mode. parseArgs has already
    // validated args.voiceArg against the Kokoro list (rejecting paths
    // and Qwen3 names); here we just canonicalise case and fall back
    // to the default agent's preset if --voice wasn't supplied. We
    // intentionally do NOT call resolveVoice() — that's Qwen3-shaped
    // and config.voice is ignored when avatar is configured.
    let voicePreset: String = args.voiceArg
        .flatMap { raw in
            VoiceChat.availableAvatarVoices.first { $0.lowercased() == raw.lowercased() }
        }
        ?? defaultAgent.voicePreset

    var config = makeConfig(args)
    config.avatar = AvatarConfig(modelPath: weightsURL, portraitPath: portraitURL)
    config.systemPrompt = initialPrompt
    config.bootProgress = boot

    let chat = VoiceChat(config: config)
    try await chat.start()
    boot.update(.ready)
    renderer.detach()

    guard let bh = chat.bithuman else {
        fatalUsage("avatar engine failed to initialise — see preceding errors.")
    }
    _ = bh.frameSize  // unused for now; window size is fixed

    // Pin the Kokoro voice (the player boots with `af_heart`; the
    // chosen preset is either --voice or the default agent's voice).
    await chat.setVoicePreset(voicePreset)

    let coordinator = AvatarCoordinator(chat: chat)
    coordinator.bindToOrchestrator()
    coordinator.currentSystemPrompt = initialPrompt
    coordinator.currentVoicePreset = voicePreset
    // Highlight the default agent's card on first open of the picker.
    // If the user supplied any per-flag override, they've drifted off
    // the template, so we leave the highlight clear.
    if args.imageArg == nil && args.promptArg == nil && args.voiceArg == nil {
        coordinator.currentAgentCode = defaultAgent.code
    }
    coordinator.prewarmPortraitURL = portraitURL
    let window = AvatarWindow(idleFrame: chat.initialIdleFrame, coordinator: coordinator)
    // Open centred on the active screen — the splash window used to
    // pre-anchor the position; with no splash we just compute it.
    window.setFrameOrigin(centeredOrigin(forSize: window.frame.size))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let pump = FramePump(bithuman: bh, chat: chat, window: window, coordinator: coordinator)
    coordinator.framePump = pump
    // Flush the FramePump's frame buffer on barge-in so the avatar
    // doesn't keep mouthing the cancelled reply for a few seconds.
    chat.onBargeIn = { [weak pump] in
        pump?.buffer.flushSpeech()
    }
    // Expose buffer state to VoiceChat's drain poller — the
    // pipeline isn't quiet until our consumer-side speech queue is
    // empty too.
    chat.onCheckSpeechBuffer = { [weak pump] in
        pump?.buffer.hasSpeech == false
    }

    // Park the chat + pump on the AppDelegate so they outlive this
    // function — without an explicit retain they'd be released and
    // the avatar would freeze.
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainSession(chat: chat, pump: pump)
    }

    // Background stdin reader — lets the user TYPE a message in
    // the launching terminal in addition to (or instead of) speaking.
    // Each non-empty line is fed into the orchestrator's same turn
    // flow as an ASR final, so the bot replies the same way it
    // would for a spoken utterance.
    Task.detached(priority: .background) { [chat] in
        while !Task.isCancelled, let line = readLine() {
            await chat.inject(userText: line)
        }
    }

    print("🎥 floating avatar window ready. Talk or type any time. Ctrl-C or ⌘Q to quit.")
}

/// Synchronous video-mode entry. Calls `NSApp.run()` directly from a
/// non-async stack frame — the only context where AppKit's runloop
/// will actually drive the main dispatch queue our render loop
/// depends on.
/// `bithuman-cli text --openai` entry point. Mirrors the voice
/// auto-pick: when `OPENAI_API_KEY` is available (env or key file)
/// and the user didn't pass `--local`, run text chat through
/// OpenAI's Chat Completions API instead of the on-device Gemma —
/// no model downloads, snappier first reply.
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
@MainActor
private func centeredOrigin(forSize size: CGSize) -> NSPoint {
    let screen = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    return NSPoint(
        x: screen.midX - size.width / 2,
        y: screen.midY - size.height / 2
    )
}

// MARK: - Utility modes (cleanup, doctor)

/// `bithuman-cli cleanup` — wipe model caches so the next run
/// exercises the cold-start path. Lists what's there + total size,
/// asks for confirmation, then deletes. Idempotent.
///
/// Caches we own:
///   - `~/.cache/huggingface/hub`   — every MLX/HF weight (LLM, TTS,
///                                    speech, Qwen3, Kokoro, etc.)
///   - `~/.cache/bithuman`          — Expression engine weights,
///                                    Apple SpeechAnalyzer model
///                                    cache, Essence working dirs.
///
/// Things we deliberately DON'T touch:
///   - `~/.bithuman/embedded-key`   — maintainer's bundled API key
///                                    (release pipeline uses this).
///   - The macOS Keychain entry     — removable separately with
///                                    `security delete-generic-password
///                                    -s ai.bithuman.cli`.
@MainActor
func runCleanup() {
    let home = NSString(string: "~").expandingTildeInPath
    let candidates = [
        "\(home)/.cache/huggingface",
        "\(home)/.cache/bithuman",
        // Stable per-`.imx` extracted weights (see ExpressionModel.makeWorkDirectory).
        // Surviving this cache is what keeps ANED's shader-compile
        // result reusable across launches; wiping it here is fine
        // because the user is asking for a cold-start anyway.
        "\(home)/Library/Caches/com.bithuman.expression-extracted",
        // Per-identity idle-frame palindrome cache (see
        // IdleFrameDiskCache). 12 MB per identity, regenerable
        // from the engine on next launch.
        "\(home)/Library/Application Support/com.bithuman.cli/idle-frames",
    ]

    print("\n  bithuman-cli cleanup\n")
    var present: [(path: String, size: Int64)] = []
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let size = directorySize(path)
        present.append((path, size))
        print("    \(path)  \(formatBytes(size))")
    }
    if present.isEmpty {
        print("    (no caches found — nothing to clean)\n")
        return
    }
    let total = present.reduce(Int64(0)) { $0 + $1.size }
    print("\n    total: \(formatBytes(total))\n")
    print("    Delete these directories? [y/N] ", terminator: "")
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    if answer != "y" && answer != "yes" {
        print("    aborted.\n")
        return
    }
    for (path, _) in present {
        do {
            try FileManager.default.removeItem(atPath: path)
            print("    ✓ removed \(path)")
        } catch {
            print("    ✗ couldn't remove \(path): \(error.localizedDescription)")
        }
    }
    print("\n    done. Next `bithuman-cli` invocation will rebuild caches from scratch.\n")
}

/// `bithuman-cli doctor` — sanity-check the host before a long
/// download/load run. Surfaces issues that would otherwise show up
/// 5 minutes into a boot cycle: low disk, low RAM, x86_64
/// (Rosetta), wrong macOS version. Read-only — never modifies
/// state.
@MainActor
func runDoctor() {
    print("\n  bithuman-cli doctor — host capability check\n")

    let arch = currentArch()
    let archOK = (arch == "arm64")
    print("    \(archOK ? "✓" : "✗") CPU architecture: \(arch)\(archOK ? "" : "  (Apple Silicon required)")")

    let osVer = ProcessInfo.processInfo.operatingSystemVersionString
    print("    ✓ macOS:           \(osVer)")

    let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    let ramOK = ramGB >= 16
    print("    \(ramOK ? "✓" : "!") RAM:             \(String(format: "%.1f GB", ramGB))\(ramOK ? "" : "  (16 GB recommended for video mode)")")

    let home = NSString(string: "~").expandingTildeInPath
    let freeBytes = freeDiskSpace(home)
    let freeGB = Double(freeBytes) / 1_073_741_824
    let diskOK = freeGB >= 10
    print("    \(diskOK ? "✓" : "!") Free disk:       \(String(format: "%.1f GB", freeGB))\(diskOK ? "" : "  (need ~10 GB for cold start)")")

    let hasKey = !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
        || (BithumanKeychain.loadOpenAIKey()?.isEmpty == false)
    print("    \(hasKey ? "✓" : "·") OpenAI API key:  \(hasKey ? "available (env or key file)" : "not set — voice mode will use --local")")

    print("")
    if archOK && ramOK && diskOK {
        print("    All checks passed. You're good to run `bithuman-cli voice` or `video`.\n")
    } else {
        print("    Some checks didn't pass — see notes above.\n")
    }
}

/// Recursive directory-size walk. Used by `runCleanup`.
private func directorySize(_ path: String) -> Int64 {
    var total: Int64 = 0
    let enumerator = FileManager.default.enumerator(atPath: path)
    while let entry = enumerator?.nextObject() as? String {
        let full = "\(path)/\(entry)"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
           let size = attrs[.size] as? NSNumber {
            total += size.int64Value
        }
    }
    return total
}

private func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
}

private func freeDiskSpace(_ path: String) -> Int64 {
    do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
        if let bytes = attrs[.systemFreeSize] as? NSNumber {
            return bytes.int64Value
        }
    } catch {}
    return 0
}

private func currentArch() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) {
            String(cString: $0)
        }
    }
    return machine
}

/// Read `machdep.cpu.brand_string` and try to extract the Apple
/// Silicon generation as an integer (M1 → 1, M3 Pro → 3, M5 Max
/// → 5). Returns nil on Intel / unknown chips. Used to recommend
/// Expression vs Essence: M4+ silicon handles the Expression DiT
/// pipeline at ~25 fps comfortably, M3 and earlier may be choppy
/// and benefit from the lighter Essence runtime.
private func appleSiliconGeneration() -> Int? {
    var size: size_t = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    let brand = String(cString: buf)
    // Patterns: "Apple M1", "Apple M2 Pro", "Apple M3 Max",
    // "Apple M4", "Apple M5 Pro", etc. Find the digit right after
    // " M" and return it as an Int.
    guard let mIdx = brand.range(of: " M")?.upperBound else { return nil }
    let tail = brand[mIdx...]
    let digits = tail.prefix(while: { $0.isNumber })
    return Int(digits)
}

/// One-line hint about whether the user's hardware is well-suited
/// to the default video pipeline. Printed at the top of video mode
/// boot when relevant. Returns nil if there's nothing useful to
/// say (M4+ on Expression is the happy path; no hint needed).
@MainActor
func videoHardwareHint(args: CLIArgs) -> String? {
    // Only hint when running the default Expression path. If the
    // user supplied their own --model, they've already chosen.
    guard args.modelArg == nil else { return nil }
    guard let gen = appleSiliconGeneration() else { return nil }
    if gen >= 4 { return nil }  // M4+ runs Expression smoothly
    return """
        💡 \u{1B}[2mhardware hint:\u{1B}[0m Apple M\(gen) detected. The default Expression
           avatar pipeline is best on M4+. For smoother playback on this
           hardware, point at an Essence .imx via `--model <path>` —
           Essence is lighter and runs comfortably back to M1.
        """
}

@MainActor
func bootstrapVideo(_ args: CLIArgs) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = BithumanAppDelegate(onLaunch: {
        try await runVideoSession(args: args)
    })
    app.delegate = delegate
    installMainMenu()

    // Bridge Ctrl-C in the terminal to a clean app terminate so the
    // audio engine + Bithuman shutdown actually run.
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { NSApp.terminate(nil) }
    signal(SIGINT, SIG_IGN)
    sigint.resume()

    app.run()  // never returns
    exit(0)
}

// MARK: - Entrypoint
//
// Sync top-level. Async work for text / voice runs inside a Task,
// with `dispatchMain()` parking the main thread so that Task can be
// scheduled on the main dispatch queue. Video bypasses this
// entirely — it calls `NSApp.run()` synchronously, which provides
// its own main-queue service.

let cliArgs = parseArgs()

// Top-level is non-async, so calling @MainActor functions requires
// asserting we're on the main thread (we are — this *is* main).
MainActor.assumeIsolated {
    switch cliArgs.mode {
    case .avatar:
        bootstrapVideo(cliArgs)  // never returns

    case .cleanup:
        runCleanup()  // synchronous, exits when done
        exit(0)

    case .doctor:
        runDoctor()
        exit(0)

    case .text, .voice:
        let args = cliArgs
        Task { @MainActor in
            do {
                switch args.mode {
                case .text:  try await bootstrapText(args)
                case .voice: try await bootstrapVoice(args)
                case .avatar, .cleanup, .doctor: break  // unreachable
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}
// dispatchMain services the Task above for text/voice modes; for
// video the bootstrapVideo call doesn't return so this is unreachable.
dispatchMain()
