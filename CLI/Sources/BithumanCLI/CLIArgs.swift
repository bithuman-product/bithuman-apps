// Mode + CLIArgs — the parsed shape of `argv`.
//
// `Mode` is the leading positional subcommand; `CLIArgs` is the
// fully-resolved struct downstream code reads. Both intentionally
// carry zero behaviour — they're typed bags. All parsing lives in
// `ArgParser.swift`; all dispatch lives in `main.swift` and
// `Modes/`.

import Foundation

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

    /// Default OpenAI model for voice/avatar (Realtime API). The
    /// `mini` variant is the cheapest live Realtime model — verified
    /// 2026-05-14 via `/v1/models` that it ships alongside
    /// `gpt-realtime-mini-2025-10-06` and `gpt-realtime-mini-2025-12-15`.
    /// Override with `--openai-model gpt-realtime-1.5` or `-2` for the
    /// pricier higher-end tiers when needed. Text mode substitutes a
    /// Chat model — see Modes/TextMode.swift.
    var openAIModel: String = "gpt-realtime-mini"
}
