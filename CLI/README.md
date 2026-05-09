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
│   ├── BithumanCLI/           Executable entry point + subcommand dispatch
│   ├── BithumanRealtimeOpenAI/  WebRTC client for OpenAI Realtime API
│   ├── bitHumanKit/           Embedded SDK source (mirror of the slice published via bithuman-sdk-public)
│   ├── BitHumanInt8Conv/      Hand-NEON int8 GEMM kernel (C target)
│   └── MLXAudio*/             Vendored from Blaizzy/mlx-audio-swift
├── Package.swift              SPM manifest — produces `bithuman-cli` exec
├── build.sh                   Release build + Developer-ID signing
├── release.sh                 build → notarize → staple → zip → upload artifact
├── scripts/
│   └── patch-webrtc-macos.sh  Repairs LiveKitWebRTC's macOS slice headers
└── Package.resolved
```

## Build

Locally:

```bash
swift build --product bithuman-cli -c release
.build/release/bithuman-cli --help
```

Signed + notarized for the Homebrew release:

```bash
./release.sh 0.10.0
```

Outputs `dist/bithuman-cli-0.10.0.zip`. Upload to a tagged release on
[homebrew-bithuman](https://github.com/bithuman-product/homebrew-bithuman/releases),
then bump the formula's `version` + `sha256` in
`homebrew-bithuman/Formula/bithuman-cli.rb` and push.

## Why the embedded SDK source

The CLI directly imports the `bitHumanKit` Swift SDK; the in-tree
copy under `Sources/bitHumanKit/` is the working copy this CLI builds
against. The same source flows back to the SDK monorepo
(`bithuman-sdk`) and is republished as the public binary distribution
at `bithuman-product/bithuman-sdk-public`. When that distribution
catches up with this CLI's expectations, this manifest can switch to
consuming the binary `xcframework` instead — see the Mac/iPad/iPhone
sibling apps in this repo for that pattern.
