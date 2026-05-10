# bithuman-cli

On-device voice + video chat CLI for macOS, by bitHuman. Source for
the binary that `brew install bithuman-cli` ships from
[homebrew-bithuman](https://github.com/bithuman-product/homebrew-bithuman).

```text
bithuman-cli text       # Chat by typing
bithuman-cli voice      # Chat by talking
bithuman-cli avatar     # Chat with a lip-syncing animated face
```

Auto-picks the OpenAI Realtime cloud backend when `OPENAI_API_KEY` is
set; falls back to the fully on-device Apple-Silicon stack otherwise
(MLX-based LLM + TTS + ASR + the bitHuman avatar engine).

## Layout

```
CLI/
├── Sources/BithumanCLI/        Executable target — see ARCHITECTURE.md for the file-by-file map
│   ├── main.swift              Entry point + dispatch
│   ├── CLIArgs.swift           Mode + CLIArgs struct
│   ├── ArgParser.swift         parseArgs + per-flag hints + typo suggester
│   ├── HelpText.swift          --help string
│   ├── Resolvers.swift         voice / portrait / config builders
│   ├── Auth.swift              fatalUsage + key-failure helpers
│   ├── Modes/                  TextMode, VoiceMode, AvatarMode, Maintenance
│   ├── BithumanKey.swift       developer-key resolution
│   ├── Keychain.swift          OpenAI key storage
│   └── SpendTracker.swift      session billing meter
├── Tests/BithumanCLITests/     Pure-logic unit tests + binary smoke tests (57 tests)
├── Package.swift               SPM manifest — depends on bithuman-sdk via path:
├── build.sh                    Release build + Developer-ID signing
├── release.sh                  build → notarize → staple → zip → upload artifact
├── README.md                   This file (user-facing)
└── ARCHITECTURE.md             Internal design — read before touching the parser or modes
```

The CLI is a thin wrapper over the [`bitHumanKit`](https://github.com/bithuman-product/bithuman-sdk) SDK + the optional `BithumanRealtimeOpenAI` cloud transport. Both come from `bithuman-product/bithuman-sdk` (the canonical engine source-of-truth, alongside the Python SDK), consumed via SwiftPM `path:` dep.

## Tests

```bash
swift test                          # 57 tests, ~2 s
swift test --enable-code-coverage   # adds llvm-cov data
```

See [ARCHITECTURE.md § Testing](ARCHITECTURE.md#testing) for what's covered and the deliberate gaps (audio I/O, MLX inference, WebRTC — all hardware-dependent, validated manually).

## Workspace layout (for development)

The `path:` dep in `Package.swift` expects sibling clones:

```
~/your-workspace/
├── bithuman-sdk/      ← cloned from bithuman-product/bithuman-sdk
└── bithuman-apps/     ← cloned from bithuman-product/bithuman-apps
```

`swift build` from this directory then resolves `../../bithuman-sdk/swift` and pulls `bitHumanKit` + `BithumanRealtimeOpenAI`.

## Build

```bash
swift build --product bithuman-cli -c release
.build/release/bithuman-cli --help
```

Signed + notarized for the Homebrew release:

```bash
./release.sh 0.13.0
```

Outputs `dist/bithuman-cli-0.13.0.zip`. Upload to a tagged release on
[homebrew-bithuman](https://github.com/bithuman-product/homebrew-bithuman/releases),
then bump the formula's `version` + `sha256` in
`homebrew-bithuman/Formula/bithuman-cli.rb` and push.
