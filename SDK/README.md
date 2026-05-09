# bitHumanKit — Swift SDK

The on-device avatar SDK for Apple Silicon. Two SwiftPM library
products:

- **`bitHumanKit`** — avatar engines (Expression, Essence), LLM/TTS/ASR
  pipelines, asset management, cross-platform SwiftUI views. Used by
  every Swift consumer in this repo: Mac, iPad, iPhone, CLI.
- **`BithumanRealtimeOpenAI`** — optional libwebrtc-based transport for
  OpenAI Realtime cloud sessions. Kept as a separate library so the
  ~100 MB libwebrtc binary doesn't bloat consumers (iPad / iPhone) that
  don't need cloud realtime.

Internal targets (statically linked into `bitHumanKit`'s binary
distribution; not exposed as products):

- **`BitHumanInt8Conv`** — hand-NEON int8 GEMM kernel (C). Used by the
  Essence audio encoder.
- **`MLXAudio*`** (`Core` / `Codecs` / `G2P` / `TTS`) — vendored from
  [Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
  @ `020b7529`. Powers the Kokoro and Qwen3-TTS backends. Vendored to
  dodge SPM's stable-tag/transitive-revision conflict.

## Layout

```
SDK/
├── Package.swift
├── Sources/
│   ├── bitHumanKit/                  ← the SDK
│   │   ├── Audio*.swift, LLMClient.swift, TTS*.swift, …
│   │   ├── Common/                   IMX container, manifest, HDF5 reader
│   │   ├── Auth/                     billing heartbeat
│   │   ├── Expression/               DiT-based avatar runtime
│   │   ├── Essence/                  pre-baked avatar runtime
│   │   ├── UI/                       SwiftUI views + AppKit shells
│   │   └── Resources/                Agents, Brand, Portraits, ref voice
│   ├── BithumanRealtimeOpenAI/       libwebrtc transport
│   ├── BitHumanInt8Conv/             internal C kernel
│   └── MLXAudio{Core,Codecs,G2P,TTS}/  vendored
└── scripts/
    └── patch-webrtc-macos.sh         legacy stasel/WebRTC header repair;
                                      no-op against current LiveKitWebRTC
```

## Consumed by

| Consumer | Path |
|---|---|
| `bithuman-cli` | `bithuman-apps/CLI/Package.swift` (`path: "../SDK"`) |
| `BithumanMac` | `bithuman-apps/Mac/Package.swift` — currently consumes `bithuman-sdk-public` binary; will switch to local `path:` after the next public binary release is cut from this tree |
| `BithumanPad` / `BithumanPhone` | `bithuman-apps/iPad,iPhone/App/*.xcodeproj` — same; binary today, local `path:` after the next public release |
| `bithuman-product/bithuman-sdk-public` | publishes `bitHumanKit.xcframework.zip` built from this tree |

## Build

```bash
cd bithuman-apps/SDK
swift build
swift test     # (when SDK-level tests land)
```

## See also

- [bitHuman website](https://www.bithuman.ai)
- [Public binary distribution](https://github.com/bithuman-product/bithuman-sdk-public)
- [Homebrew tap](https://github.com/bithuman-product/homebrew-bithuman)
