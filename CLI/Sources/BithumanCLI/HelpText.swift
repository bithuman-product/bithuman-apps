// `bithuman-cli --help` text.
//
// Single multi-line string literal, kept in its own file so the
// 200-line block doesn't clutter the parser. ANSI escape codes
// (\u{1B}[1m / \u{1B}[2m / \u{1B}[0m) render bold + dim sections
// in any TTY that respects them; non-TTY output strips them.

import Foundation

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
                          track), fully on-device otherwise.
                          Requires a bitHuman API key (see ENV) and
                          an `.imx` avatar file. Pass `--identity
                          <agent.imx>` for any Essence or Expression
                          bundle, or `--image <portrait>` for a
                          custom-portrait Expression avatar
                          (~1.56 GB engine on first run). Right-
                          click the avatar to audition voices or
                          edit the prompt.

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

  --openai-model <id>    Cloud model id. Same flag for every mode;
                         eligible models differ because voice/avatar
                         use the Realtime API while text uses Chat
                         Completions. ★ marks the cost-optimised
                         default per mode (May 2026 OpenAI pricing).

                         voice / avatar (Realtime API):
                           ★ gpt-realtime-1.5   $4   in / $16   out  per 1M tok
                             gpt-realtime-2     $32  in / $64   out  (newest, GPT-5-class)

                         text (Chat Completions API):
                           ★ gpt-5.4-mini       $0.75 in / $4.50 out  (workhorse)
                             gpt-5.4-nano       $0.20 in / $1.25 out  (simple tasks)
                             gpt-5.4            $2.50 in / $15   out  (frontier)
                             gpt-5.5            $5    in / $30   out  (newest frontier)
                             o3-mini                                  (reasoning model)

                         Legacy (still in API; flagged legacy since
                         OpenAI retired them from ChatGPT 2026-02-13):
                           gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4.1-mini, o4-mini

                         Full list · https://platform.openai.com/docs/models

                         text-mode safety net: passing a Realtime id
                         (`gpt-realtime*`) to `text --openai`
                         substitutes the chat default. The reverse
                         (chat id in voice/avatar) hits the Realtime
                         API as-is — match the mode or OpenAI 4xxs.

  -h, --help             Show this help and exit.
  -v, --version          Print the bithuman-cli version and exit.

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
