# bithuman-apps

Reference apps showing how to embed bitHuman avatars in your own product. Build them, run them, copy what you need.

- **`flutter/bithuman/example/`** — cross-platform Flutter app (macOS, iOS, iPad, Android) with cloud LLM/TTS via OpenAI Realtime.
- **`expression/mac/`** — native macOS app with on-device LLM/TTS via MLX, drag-drop face swap, Sparkle auto-update.
- **`expression/ipad/`** — native iPadOS app with Stage Manager floating widget, Picture-in-Picture, PhotosPicker face swap.
- **`demos/`** — focused use-case showcases (kiosk, tutor, NPC, …).
- **`archive/`** — apps parked while we sort out a leaner runtime story for them.

These apps all consume the bitHuman SDK as a pre-built dependency — the same way an external developer would. Treat them as starting points: fork what you need, replace the agent / voice / portrait, ship.

> **A note about scope.** The Flutter app uses the **Essence** runtime (CPU, pre-built `.imx` avatars). The native Expression apps use the **Expression** runtime (Apple Silicon, AI-animated faces). Pick the runtime that fits your hardware and feature needs — comparison at [docs.bithuman.ai/getting-started/models](https://docs.bithuman.ai/getting-started/models).

---

## Getting your API keys

The apps in this repo talk to two cloud services. Both have free tiers and take a couple of minutes each to set up.

### bitHuman API secret

You need this to render avatars (the lip-sync engine validates each session against your account).

1. Go to **[www.bithuman.ai](https://www.bithuman.ai)** and sign up — free, no credit card.
2. Once you're signed in, click **Developer → API Keys** in the top nav.
3. Click **Create new key**, give it a name (e.g. *"local dev"*), copy the value.
4. Free tier includes **99 credits/month** — about 50 minutes of avatar render time. Plenty for development.

You'll use this as either `BITHUMAN_API_SECRET` (Python, CLI, Flutter) or `BITHUMAN_API_KEY` (native Swift). Same value — the name just differs by SDK.

### OpenAI API key

The Flutter example app uses OpenAI's [Realtime API](https://platform.openai.com/docs/guides/realtime) for the voice loop (speech-to-speech with sub-200 ms latency). The native Expression apps run their own on-device LLM/TTS so they don't need this key.

1. Go to **[platform.openai.com/api-keys](https://platform.openai.com/api-keys)** and sign in (create an account if you haven't).
2. Click **Create new secret key**, give it a name, copy the value.
3. New OpenAI accounts get **\$5 of free credit** for the first three months — enough to try the demo for an hour or two. After that, top up at [platform.openai.com/settings/organization/billing](https://platform.openai.com/settings/organization/billing).

> **Keep both keys safe.** Treat them like passwords — anyone with the key can spend your credits. The recommended pattern is a `~/.env` file (mode `chmod 600`) at the root of your home directory; the launcher script (`flutter/bithuman/scripts/run-all.sh`) reads from there automatically.

### Save them once

Most of the examples in this repo read keys from environment variables. The easiest way to make them available to every shell + every build:

```sh
# ~/.env  (chmod 600 ~/.env)
OPENAI_API_KEY=sk-proj-...
BITHUMAN_API_SECRET=...
```

Then add this to your shell profile (`~/.zshrc` or `~/.bashrc`) so they're set automatically:

```sh
[ -f "$HOME/.env" ] && set -a && . "$HOME/.env" && set +a
```

---

## First-time setup

### 1. Clone the repo

```sh
git clone https://github.com/bithuman-product/bithuman-apps.git
cd bithuman-apps
```

### 2. Install platform tools

| You're building for | Tools you need |
|---|---|
| Anything Flutter | [Flutter SDK 3.11+](https://docs.flutter.dev/get-started/install) |
| iOS / iPadOS / macOS native | Xcode 16+ (from the Mac App Store), [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Android | Android Studio (or just `flutter doctor` to validate the toolchain) |

### 3. Fetch native dependencies *(Flutter only)*

The Flutter plugin links against pre-built native libraries (`libessence`, `onnxruntime`, etc.). Run the bootstrap script once after cloning:

```sh
cd flutter/bithuman
./scripts/bootstrap.sh
```

This downloads the right binaries for your host platform from this repo's GitHub Releases and places them under `flutter/bithuman/ios/Vendor/` and `flutter/bithuman/macos/Vendor/`. It only needs to run once per clone (or after a major SDK bump).

The Android target pulls its native library from Maven Central automatically — no bootstrap step needed there.

### 4. Set your Apple signing team *(iOS / iPadOS / macOS only)*

The example apps don't ship with a developer team baked in — you set yours via an environment variable or directly in Xcode. Find your team ID at [developer.apple.com/account](https://developer.apple.com/account) (top-right under your name; ten characters, e.g. `ABCDE12345`).

```sh
export DEVELOPMENT_TEAM=ABCDE12345
```

Or open the project in Xcode and pick your team in **Signing & Capabilities**.

---

## Build a reference app

### Flutter example — fastest cross-platform path

Runs on macOS, iOS, iPad, and Android from one Dart codebase. Full-bleed avatar, OpenAI Realtime voice loop, echo-cancelled mic, real-time barge-in.

```sh
cd flutter/bithuman/example
flutter pub get

# Run on the default device
flutter run --dart-define=OPENAI_API_KEY=$OPENAI_API_KEY \
            --dart-define=BITHUMAN_API_SECRET=$BITHUMAN_API_SECRET
```

To deploy to all your connected devices at once (Mac + iPhone + iPad + Android in parallel), use the launcher:

```sh
./flutter/bithuman/scripts/run-all.sh
```

It auto-discovers connected devices, picks up keys from `~/.env`, builds three artefacts in parallel (macOS app / universal iOS app / Android APK), and installs + launches everywhere.

Full walk-through: [`flutter/bithuman/example/README.md`](flutter/bithuman/example/README.md).

### Native macOS app — on-device Expression

100% on-device — no cloud round-trip, no API keys needed for the voice loop. Drag-drop face swap, Sparkle auto-update, Apple Silicon M3+.

```sh
cd expression/mac
swift run -c release BithumanMac
```

First launch downloads ~1.5 GB of model weights into `~/.cache/huggingface/hub/`. Subsequent launches are offline.

Details: [`expression/mac/README.md`](expression/mac/README.md).

### Native iPadOS app — on-device Expression on iPad

Stage Manager floating widget, draggable Picture-in-Picture, PhotosPicker face swap. Targets iPad Pro M4+ (16 GB RAM).

```sh
cd expression/ipad/App
xcodegen generate
open BithumanPad.xcodeproj    # Cmd-R on a real M-series iPad
```

Details: [`expression/ipad/README.md`](expression/ipad/README.md).

---

## Hardware support

Each app declares its own hardware floor. Devices below it see a polite refusal at launch rather than a crash.

| Platform | Minimum |
|---|---|
| macOS | Apple Silicon M3+, macOS 13+ |
| iPad | iPad Pro M4+, 16 GB RAM |
| iPhone | iPhone 15 Pro / 16 Pro / Air (8 GB+) |
| Android | Snapdragon 8 Gen 2 / equivalent flagship, Android 14+ |

For the Flutter example, the cross-platform Essence runtime is more forgiving — it'll run on any Apple Silicon Mac and most modern Android phones (the 25 FPS render is the limiting factor, not memory).

---

## Repo layout

```
bithuman-apps/
├── flutter/bithuman/          Flutter plugin (macOS · iOS · Android)
│   ├── lib/                   Dart API
│   ├── ios/ macos/ android/   Native plugin code per platform
│   ├── scripts/               bootstrap.sh, run-all.sh, e2e-all.sh
│   └── example/               Reference app — build for any platform
├── expression/                Native Expression demos (on-device LLM/TTS)
│   ├── mac/                   macOS .app
│   └── ipad/                  iPadOS .app
├── demos/                     Focused use-case showcases
├── archive/                   Parked apps awaiting revival
└── version.yml                Pinned bitHuman SDK version
```

---

## Where to get help

- **Bugs in this repo's example apps** — file an issue at [bithuman-product/bithuman-apps/issues](https://github.com/bithuman-product/bithuman-apps/issues).
- **SDK runtime questions** (lip-sync drift, audio glitches, model loading) — email [support@bithuman.ai](mailto:support@bithuman.ai) or post in the [Discord](https://discord.gg/ES953n7bPA). The engineers who can fix runtime bugs watch those channels.
- **Security reports** — email [security@bithuman.ai](mailto:security@bithuman.ai).
- **Full product docs** — [docs.bithuman.ai](https://docs.bithuman.ai).

---

## License

See [LICENSE](LICENSE). Example code is Apache-2.0; the underlying SDK frameworks have their own terms documented at [bithuman.ai/terms](https://www.bithuman.ai/terms).
