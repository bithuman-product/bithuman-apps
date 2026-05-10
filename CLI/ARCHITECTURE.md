# bithuman-cli — architecture

Internal design notes for the `bithuman-cli` executable target.
Read this before touching the parser, mode dispatch, or session
runners. User-facing usage docs live in [`README.md`](README.md);
this document is for people maintaining the code.

## High-level shape

`bithuman-cli` is a thin, *stateless* wrapper around two libraries:

```
┌──────────────────────┐
│  bithuman-cli (this) │
│  argv → dispatch     │
└──────────┬───────────┘
           │
   ┌───────┴───────┐
   ▼               ▼
bitHumanKit   BithumanRealtimeOpenAI
(local stack)   (cloud transport)
```

Both come from the [`bithuman-sdk`](https://github.com/bithuman-product/bithuman-sdk)
monorepo via a SwiftPM `path:` dep against a sibling clone — so the
CLI iterates in lockstep with engine changes during development.

The CLI itself owns:

1. **Argument parsing** — `argv` → `CLIArgs`
2. **Mode dispatch** — `CLIArgs.mode` → bootstrap function for that mode
3. **Resolvers** — `--voice`/`--image`/`--prompt` arg → SDK input objects
4. **Session runners** — bind the SDK pieces together for each mode
5. **Terminal UX** — `--help`, error hints, status pills, meter bars,
   the spend tracker, the interactive backend picker
6. **Credential handling** — env var > saved file > Keychain > prompt
7. **Maintenance** — `cleanup` and `doctor` modes

Everything else (audio I/O, ML inference, WebRTC, lip-sync) lives
in the SDK.

## File map

```
CLI/Sources/BithumanCLI/
├── main.swift              entry point — sets stdio buffering,
│                           calls parseArgs(), dispatches by mode
├── CLIArgs.swift           Mode enum + CLIArgs struct (parsed argv)
├── ArgParser.swift         parseArgs() + per-flag hints (FlagHint)
│                           + Levenshtein-based closestMatch typo
│                           suggester + knownFlags + interactive
│                           voice-backend picker (promptForVoiceBackend)
├── HelpText.swift          the --help string literal (~200 lines)
├── Resolvers.swift         resolveVoice (preset+path), resolveTranscript
│                           (Apple Speech), readInlineOrFile (--prompt
│                           inline-or-@path), makeConfig (the shared
│                           VoiceChatConfig builder), resolvePortrait
│                           (--image preset+path)
├── Auth.swift              fatalUsage / fatalKey / fatalBitHuman*
│                           / makeBithumanHeartbeat (the billing probe)
│                           / cliWarn (renamed from `warn` because it
│                           collided with POSIX warn(3) cross-file)
├── Modes/
│   ├── TextMode.swift      bootstrapText (local Gemma) +
│   │                       bootstrapTextOpenAI (OpenAI Chat Completions)
│   ├── VoiceMode.swift     bootstrapVoice (local Apple Speech +
│   │                       Gemma + Qwen3-TTS) + bootstrapVoiceOpenAI
│   │                       (OpenAI Realtime over WebRTC)
│   ├── AvatarMode.swift    bootstrapVideo (the only never-returning
│   │                       entry — calls NSApplication.run()) plus
│   │                       runExpression* / runEssence* runners
│   │                       (local + cloud variants of each), plus
│   │                       windowing helpers (centeredOrigin,
│   │                       videoHardwareHint)
│   └── Maintenance.swift   runCleanup + runDoctor + the host-info
│                           helpers (currentArch, appleSiliconBrand,
│                           appleSiliconGeneration, directorySize,
│                           formatBytes, freeDiskSpace)
├── BithumanKey.swift       Developer-key resolution: env >
│                           ~/Library/Application Support/.../bithuman-api-key
├── EmbeddedKey.swift       Compiled-in fallback (unused at runtime
│                           today; kept for the historical
│                           bundled-key path)
├── Keychain.swift          OpenAI key storage — file-backed (0600)
│                           rather than the system Keychain to keep
│                           the dependency footprint minimal
└── SpendTracker.swift      Per-session billing meter (60 s tick:
                            credits/min × elapsed; rate-card constants
                            pinned)

CLI/Tests/BithumanCLITests/
├── ArgParserTests.swift    Levenshtein, closestMatch, FlagHint,
│                           knownFlags
├── ResolversTests.swift    readInlineOrFile, Mode rawValue, defaults
├── SpendTrackerTests.swift rate-card constants, runtime mapping,
│                           BithumanKey env-var precedence
└── BinarySmokeTests.swift  spawn the built binary, assert
                            stderr/stdout/exit-code shape for every
                            parseArgs branch
```

## Lifecycle

```
$ bithuman-cli avatar --identity ~/agent.imx --prompt "be Einstein"
                          ▼
                   main.swift
                          ▼
              parseArgs() → CLIArgs   ← may exit(2) via fatalUsage
                          ▼
            switch cliArgs.mode { … }
                          ▼
                  bootstrapVideo(args)
                          ▼
        runVideoSession(args)         ← peek manifest.model_type
                          ▼
        ┌─────────────────┴──────────────────┐
        ▼                                    ▼
 runExpression*                        runEssence*
 (DiT pipeline,                        (lighter rect-frame
 circular window)                      runtime)
        │                                    │
        └──────────────┬─────────────────────┘
                       ▼
       NSApplication.run()  ← never returns; user quits with ⌘Q
```

For `text` and `voice`, the dispatch hands off to a `Task @MainActor`
which awaits the bootstrap, exits with `0` on success, `1` on
thrown error. `dispatchMain()` then services the run loop.

For `cleanup` and `doctor`, the run is synchronous — print, prompt,
exit cleanly.

## Argument parsing model

`parseArgs()` runs in three passes:

1. **Mode subcommand** (the leading non-flag token, optional).
   Recognises `text`, `voice`, `avatar`, `cleanup`, `doctor`,
   plus the legacy `video` alias for `avatar`. Anything else is a
   fatal usage error with the valid-mode list.

2. **Flag loop** — switch over every flag in `argv`. Value-bearing
   flags use the `nextValue(_:_:hint:)` helper, which on missing
   value emits the per-flag `FlagHint` string before exiting. The
   `default:` branch catches unknown flags, runs them through
   `closestMatch` against `knownFlags`, and emits a "did you mean?"
   suggestion when the Levenshtein distance is within tolerance.

3. **Mode-specific validation** — once `args.mode` is known, run
   the cross-flag checks: `--image` only applies to avatar mode,
   `--openai` and `--local` are mutually exclusive, etc. Some are
   `fatalUsage` (real conflicts), some are `cliWarn` (flag is
   ignored but the rest of the run is fine).

### Adding a new flag

1. Add a stored property on `CLIArgs` (`CLIArgs.swift`).
2. Add a `case` in `parseArgs`'s switch (`ArgParser.swift`).
3. Add a hint string in `FlagHint` (or pass `hint:` inline) and
   wire it through `nextValue(_:_:hint:)`.
4. Add the flag spelling to `knownFlags` so the typo suggester can
   recommend it.
5. Update the OPTIONS section of `helpText` (`HelpText.swift`).
6. If the flag has mode-specific semantics, add validation in the
   mode-specific block of `parseArgs`.
7. Add a `BinarySmokeTests` case asserting the missing-value error
   shape.

### Adding a new mode

1. Add the case to `Mode` (`CLIArgs.swift`).
2. Add a file under `Modes/` with the bootstrap function.
3. Wire the case into `main.swift`'s dispatch switch.
4. Add the case to the parser's mode-specific validation block in
   `parseArgs`.
5. Update the FAST PATHS section of `helpText`.

## Error UX conventions

The cardinal rule: **every parse failure must show what to type
instead.** The user shouldn't have to re-run with `--help` to
recover from a typo or a missing value.

| Helper | When | Format |
|---|---|---|
| `fatalUsage(msg)` | malformed argv | `error: <msg>\nRun \`bithuman-cli --help\` for usage.` (exit 2) |
| `fatalKey()` | `--openai` set but no key | the missingKeyMessage with three fix paths (exit 2) |
| `fatalBitHumanKeyMissing()` | avatar mode without bitHuman key | signup URL + env-var + key-file instructions (exit 2) |
| `fatalBitHumanAuthFailed(err)` | billing service rejected the key | the underlying reason (insufficient balance, suspended, …) (exit 3) |
| `cliWarn(msg)` | recoverable warning (flag ignored, etc.) | `warning: <msg>` to stderr, run continues |

Hints in `FlagHint` should pull live preset lists from the SDK
(`VoiceSelection.presetNames`, `VoiceChat.availableAvatarVoices`)
when applicable, so the hint can never drift from what the SDK
accepts.

## Testing

The `BithumanCLITests` target exercises everything that doesn't
need hardware. Run with `swift test`.

What's covered:

- **Pure logic** — Levenshtein, `closestMatch`, `FlagHint` string
  assembly, `readInlineOrFile`, `Mode(rawValue:)`, `CLIArgs`
  defaults, `SpendTracker` rate constants, `BithumanKey` env-var
  precedence
- **End-to-end parser behaviour** — `BinarySmokeTests` spawns the
  built binary with crafted argv and asserts stderr / stdout /
  exit code. Covers every `parseArgs` branch (--help, missing
  values, "got flag instead of value", typo suggester, unknown
  subcommand, conflicts, legacy `video` alias)

What's deliberately not covered:

- **Audio I/O** — needs a real microphone
- **MLX inference** — needs Apple Silicon + multi-GB weights cached
- **WebRTC + OpenAI Realtime** — needs network + API key
- **Avatar windowing / lip-sync** — needs a TTY + display
- **First-launch HuggingFace downloads** — not hermetic
- **macOS Keychain** — talks to the system store; can't be
  isolated per-test
- **Time-driven loops** (the `SpendTracker` 60 s tick, the
  `IdleVideoCache` palindrome timer) — the load-bearing constants
  are pinned; the timing isn't

These are validated manually (run `bithuman-cli doctor` to see
the readiness matrix; run each mode end-to-end before cutting a
release).

### Adding a test

- Pure logic → unit test in the matching `*Tests.swift` file.
- New parser branch → smoke test in `BinarySmokeTests.swift`.
- Hardware-dependent → don't add a flaky test; document the
  manual-QA step in the PR.

## Coverage targets

We don't chase 100 %. The honest target is **high coverage of the
testable surface** — pure logic + parser branches. The current
in-process line coverage of ~36 % understates this because the
denominator includes audio / MLX / WebRTC / fatal-exit code that
can't be tested in process. Of code that *can* be tested, we sit
in the 80–90 % range, plus the subprocess smoke layer on top.

When adding new code: write tests for the pure parts; document
the manual-QA path for the rest.

## Build & release

| Command | What it does |
|---|---|
| `swift build` | Debug binary in `.build/debug/bithuman-cli` |
| `swift build -c release --product bithuman-cli` | Release binary (~6–7 min cold, ~10 s warm) |
| `swift test` | Run the test target |
| `./build.sh` | Release build + Developer-ID signing |
| `./release.sh X.Y.Z` | build → notarize → staple → zip → upload to homebrew-bithuman releases (full pipeline) |

After `release.sh`, bump the formula's `version` and `sha256` in
[`homebrew-bithuman/Formula/bithuman-cli.rb`](https://github.com/bithuman-product/homebrew-bithuman/blob/main/Formula/bithuman-cli.rb)
and push the tap.

## Out of scope for this repo

- **SDK internals** (Wav2Vec2, DiT, VAE, ANE shaders, MLX
  kernels) — those live in
  [`bithuman-sdk`](https://github.com/bithuman-product/bithuman-sdk).
- **Halo, the desktop companion app** — that was archived; the
  Mac reference app at `bithuman-apps/Mac/` is its spiritual
  successor.
- **Per-language SDK distribution** — Swift xcframework releases
  are cut from `bithuman-sdk-public`; PyPI wheels from
  `bithuman-sdk/python/`.
- **Auto-update / Sparkle** — the brew tap *is* the update
  channel for `bithuman-cli`. The Mac reference app uses Sparkle
  separately.

## Related repos

- [`bithuman-sdk`](https://github.com/bithuman-product/bithuman-sdk) — Swift + Python SDK source
- [`bithuman-sdk-public`](https://github.com/bithuman-product/bithuman-sdk-public) — public binary distribution + docs source
- [`homebrew-bithuman`](https://github.com/bithuman-product/homebrew-bithuman) — brew tap + release zips
- [`bithuman-livekit-swift`](https://github.com/bithuman-product/bithuman-livekit-swift) — LiveKit Swift fork (used by avatar cloud paths)
