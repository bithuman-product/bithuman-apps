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
│   └── example/                  Reference app — build for any platform
├── CLI/                          Swift CLI (interactive macOS chat)
├── demos/                        Showcase apps (kiosk, tutor, NPC, …)
└── archive/                      Native Swift Mac/iPad/iPhone apps (parked)
```

## Quickstart — Flutter reference app

The example app under `flutter/bithuman_avatar/example/` is the canonical
demo. One Dart codebase covers **macOS + iOS + Android**, with the audio
transport selected at runtime per platform:

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

## Archive

Native Swift Mac / iPad / iPhone apps that previously lived at the repo root
are parked in [`archive/`](archive/) while the Flutter codebase becomes the
single source of truth for cross-platform demos. They still build against
`bithuman-sdk-public` (legacy bitHumanKit SwiftPM) and ship features the
Flutter port doesn't yet match (on-device LLM via MLX, Sparkle auto-updater,
drag-drop face swap). The plan is to fold the most-loved features into
`flutter/bithuman_avatar/` so all three platforms ship from one Dart
codebase. See [`archive/README.md`](archive/README.md).

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
