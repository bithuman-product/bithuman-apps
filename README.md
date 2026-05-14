# bithuman-apps

Reference apps showing how to embed the [bithuman](https://www.bithuman.ai)
on-device avatar runtime in your own app. The canonical reference is now a
**Flutter codebase that ships from one Dart project to macOS, iOS, and
Android** via the [`bithuman_avatar`](flutter/bithuman_avatar/) plugin.
A terminal CLI ships separately for headless / scripting use.

```
bithuman-apps/
├── flutter/bithuman_avatar/      Flutter plugin (macOS · iOS · Android)
│   ├── lib/                      Dart API
│   ├── macos/ ios/ android/      Native plugin code per platform
│   └── example/                  Essence + cloud reference — build for any platform
├── expression/                   Native Expression demos (on-device LLM/TTS)
│   └── mac/                      macOS .app — Sparkle DMG, drag-drop face swap
├── CLI/                          Swift CLI (interactive macOS chat — both runtimes)
├── demos/                        Showcase apps (kiosk, tutor, NPC, …)
└── archive/                      Parked apps awaiting revival or fold-in
```

## Three reference flavors

| Demo | Platforms | Runtime | LLM / TTS | Distribution |
|---|---|---|---|---|
| [`flutter/bithuman_avatar/example/`](flutter/bithuman_avatar/example/) | macOS · iOS · Android | Essence | Cloud (OpenAI Realtime) | `flutter run` |
| [`expression/mac/`](expression/mac/) | macOS only | Expression | On-device (MLX) or Cloud | Sparkle DMG / `swift run` |
| [`bithuman-cli avatar`](CLI/) | macOS terminal | both Expression + Essence | both On-device + Cloud | `brew install bithuman-cli` |

These have intentionally non-overlapping scopes — the Flutter app is the
"easy cross-platform" path, `expression/` is the "full on-device" path,
and the CLI is the "scriptable / terminal-launched" path. Pick by use
case, not by preference.

## Quickstart — Flutter reference app

The example app under `flutter/bithuman_avatar/example/` is the canonical
cross-platform demo. One Dart codebase covers **macOS + iOS + Android**,
with the audio transport selected at runtime per platform:

| Platform | Transport for OpenAI Realtime | Why |
|---|---|---|
| macOS, iOS | WebSocket through plugin's VP-IO `RealtimeAudioIO` | Apple VP-IO is the cleanest hardware AEC; flutter_webrtc on macOS uses libwebrtc software AEC3 which self-interrupts in voice chat |
| Android | `flutter_webrtc` (libwebrtc native pipeline) | Validated path; sidesteps Android AAudio routing + Java audio sink limitations |

Drop your credentials + an `.imx` avatar in via `--dart-define`:

```sh
cd flutter/bithuman_avatar/example

# macOS
flutter run -d macos \
  --dart-define=OPENAI_API_KEY=sk-... \
  --dart-define=BITHUMAN_API_SECRET=bh-... \
  --dart-define=IMX_PATH=/abs/path/to/avatar.imx

# Android (Z Fold 5 etc.)
flutter run -d <android-device-id> \
  --dart-define=OPENAI_API_KEY=sk-... \
  --dart-define=BITHUMAN_API_SECRET=bh-...

# iOS device (release build required for sideload)
flutter build ios --release
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
```

If you skip `IMX_PATH`, the app falls back to `<application-support>/avatar.imx`
and prints the platform-specific path on first run so you can drop the file
there. See [`flutter/bithuman_avatar/example/lib/dev_config.dart`](flutter/bithuman_avatar/example/lib/dev_config.dart)
for all tunables (voice / system prompt / VAD threshold / model id /
`config.json` persistence).

## CLI

```sh
brew install bithuman-product/bithuman/bithuman    # Rust unified CLI (canonical)
brew install bithuman-product/bithuman/bithuman-cli # Swift interactive CLI (this repo)
```

The Swift `bithuman-cli` in [`CLI/`](CLI/) is a macOS-only interactive
voice/text/avatar terminal. It consumes the SDK source via SwiftPM `path:`
dep against a sibling clone of [`bithuman-sdk`](https://github.com/bithuman-product/bithuman-sdk)
— see [`CLI/README.md`](CLI/README.md#workspace-layout-for-development) for
the workspace convention.

The Rust `bithuman` (Homebrew tap formula `bithuman`) lives in
[`bithuman-sdk/cpp/bindings/rust`](https://github.com/bithuman-product/bithuman-sdk/tree/main/cpp/bindings/rust)
and ships with `voice` / `text` / `avatar` / `generate` / `stream` /
`pack` / `convert` subcommands across macOS + Linux. The Swift
`bithuman-cli` is being folded into the Rust CLI as a follow-up.

## Expression demos (on-device LLM/TTS)

The native Expression apps live under [`expression/`](expression/). The
macOS variant is live ([`expression/mac/`](expression/mac/)) — full
SwiftUI .app with Sparkle auto-update, drag-drop face swap, and the
on-device LLM/TTS stack via MLX (Gemma 3 + Qwen3-TTS / Kokoro). iPad +
iPhone Expression variants are parked in [`archive/`](archive/) pending
revisit; revive with `git mv archive/iPad expression/ipad` etc. See
[`expression/README.md`](expression/README.md) for the runtime
comparison matrix.

## Archive

Apps awaiting revival or fold-in live in [`archive/`](archive/). Right
now: the iPadOS + iOS Expression variants (parked while the Mac version
becomes the canonical Expression demo and Flutter handles cross-platform
Essence). See [`archive/README.md`](archive/README.md).

## Architecture

Every app in this repo consumes the bithuman runtime as an **external,
pre-built dependency**:

```
┌──────────────────────────┐  flutter pub /  ┌────────────────────────────┐
│  Flutter app (example)   │  SwiftPM / brew │  bithuman_avatar plugin    │
│  Dart UI + transport     │  ──────────────►│  + libessence native lib   │
│  selection               │                 │  (cpp/ from bithuman-sdk)  │
└──────────────────────────┘                 └────────────────────────────┘
```

Engine source-of-truth: [`bithuman-product/bithuman-sdk`](https://github.com/bithuman-product/bithuman-sdk)
— one C++ engine (libessence, ABI v6) powering all bindings. See its
[README](https://github.com/bithuman-product/bithuman-sdk#readme) for the
3-layer hierarchy (Engine → Bindings → End-user surfaces).

## Adding new apps or demos

- **Cross-platform demo**: build it on top of `flutter/bithuman_avatar/`.
  Same Dart code targets macOS + iOS + Android.
- **Use-case showcase**: add a subdirectory under `demos/`.
- **Native-only deep dive**: revive an entry from `archive/`, or add a
  new top-level directory and document the deviation (only when the
  Flutter path can't model the use case).

## Hardware requirements

The plugin gates eligibility at runtime. Under-spec devices see a polite
refusal.

| Platform | Minimum |
|---|---|
| macOS | M3+ Apple Silicon, macOS 13+ |
| iOS | iPhone 14 Pro / iPad Pro M2+ |
| Android | Snapdragon 8 Gen 2 / equivalent flagship, Android 14+ |

## Documentation

- **Plugin overview & quickstart** → [docs.bithuman.ai/swift-sdk](https://docs.bithuman.ai/swift-sdk/overview) and [docs.bithuman.ai/kotlin-sdk](https://docs.bithuman.ai/kotlin-sdk/overview)
- **Streaming API (ABI v6)** → [docs.bithuman.ai/swift-sdk/streaming](https://docs.bithuman.ai/swift-sdk/streaming) · [docs.bithuman.ai/kotlin-sdk/streaming](https://docs.bithuman.ai/kotlin-sdk/streaming)
- **Authentication** → [docs.bithuman.ai/getting-started/authentication](https://docs.bithuman.ai/getting-started/authentication)
- **Pricing & credits** → [docs.bithuman.ai/getting-started/pricing](https://docs.bithuman.ai/getting-started/pricing)

## License

See [LICENSE](LICENSE).
