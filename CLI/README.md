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
├── Sources/
│   └── BithumanCLI/        Executable: arg parsing, mode dispatch, runners,
│                           terminal rendering, key storage, billing display
├── Package.swift           SPM manifest — depends on bithuman-sdk via path:
├── build.sh                Release build + Developer-ID signing
└── release.sh              build → notarize → staple → zip → upload artifact
```

The CLI is a thin wrapper over the [`bitHumanKit`](https://github.com/bithuman-product/bithuman-sdk) SDK + the optional `BithumanRealtimeOpenAI` cloud transport. Both come from `bithuman-product/bithuman-sdk` (the canonical engine source-of-truth, alongside the Python SDK), consumed via SwiftPM `path:` dep.

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
