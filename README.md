# bithuman-apps

Reference apps showing how to embed [`bitHumanKit`](https://github.com/bithuman-product/bithuman-kit)
— the on-device voice + video chat SDK by [bitHuman](https://www.bithuman.ai)
— on **macOS, iPadOS, and iOS**. Each app is a thin shell over the SDK:
windowing + lifecycle + entitlements glue, no engine code. Clone, run
one command, get a working avatar.

All three apps consume the SDK as a normal Swift Package Manager
dependency:

```swift
.package(url: "https://github.com/bithuman-product/bithuman-kit.git", from: "0.7.1")
```

Stack: ASR (SpeechAnalyzer) -> LLM (Gemma 3 / 3n via MLX) -> TTS
(Qwen3-TTS / Kokoro) -> bitHuman avatar engine (Wav2Vec2 -> DiT -> VAE
-> ANE). Apple Silicon only (M-series Mac, M-series iPad, A17 Pro+
iPhone).

## What's here

| Variant | Path     | Form factor                 | Walkthrough             |
| ------- | -------- | --------------------------- | ----------------------- |
| Mac     | [`Mac/`](Mac/)       | Sparkle-updateable .app + DMG | [Mac/README.md](Mac/README.md)       |
| iPad    | [`iPad/`](iPad/)     | Stage-Manager widget + PiP    | [iPad/README.md](iPad/README.md)     |
| iPhone  | [`iPhone/`](iPhone/) | Portrait, smaller LLM         | [iPhone/README.md](iPhone/README.md) |

---

## Mac

![](docs/img/mac-hero.png)

A SwiftUI App-lifecycle binary that wraps the SDK's
`AvatarCoordinator` + `AvatarWindow` graph. Launches into video mode
(no terminal), right-click the avatar to swap agent / voice / face /
prompt. Ships as a Sparkle-updateable, hardened-runtime, notarised
.app. Standalone SPM package — `swift run` and you're talking to an
avatar in 30 seconds.

```sh
cd Mac
swift run -c release BithumanMac
```

Walkthrough: [Mac/README.md](Mac/README.md)

## iPad

![](docs/img/ipad-hero.png)

iPadOS app with a 320 pt Stage Manager floating widget, a draggable
Picture-in-Picture float, and PhotosPicker face swap. Wrapped by an
Xcode project (xcodegen-driven) so it ships through TestFlight / App
Store. Targets 16 GB M-series iPad Pro / Air; uses
`increased-memory-limit` + `extended-virtual-addressing` entitlements.

```sh
cd iPad/App
xcodegen generate
open BithumanPad.xcodeproj    # then Cmd-R on a real M-series iPad
```

Walkthrough: [iPad/README.md](iPad/README.md)

## iPhone

![](docs/img/iphone-hero.png)

Phone-form-factor variant — portrait-locked, single-orientation frame
pump, smaller LLM (Gemma 3 1B QAT 4-bit, ~800 MB) so it fits the iOS
memory budget without paging. Same SDK, same avatar engine; the
windowing + memory-budget tuning is what differs from iPad.

```sh
cd iPhone/App
xcodegen generate
open BithumanPhone.xcodeproj  # then Cmd-R on iPhone 15 Pro+
```

Walkthrough: [iPhone/README.md](iPhone/README.md)

---

## Hardware requirements

- **Mac**: Apple Silicon (M1+), macOS 26.0+, 16 GB RAM minimum.
- **iPad**: M-series iPad with 16 GB RAM (iPad Pro M4/M5, iPad Air M2+),
  iPadOS 26.0+. 8 GB SKUs jetsam during a turn.
- **iPhone**: A17 Pro / M-series iPhone with 8 GB RAM, iOS 26.0+.
  Smaller LLM keeps the active turn under the iPhone memory ceiling.

## License

See [LICENSE](LICENSE).
