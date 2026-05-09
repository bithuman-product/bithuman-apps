# bithuman-apps

Reference apps showing how to embed [`bitHumanKit`](https://docs.bithuman.ai/swift-sdk/overview) — the on-device voice + lip-synced avatar SDK by [bitHuman](https://www.bithuman.ai) — on **macOS, iPadOS, and iOS**. Each app is a thin shell over the SDK: windowing + lifecycle + entitlements glue, no engine code. Clone, run one command, get a working avatar.

All three apps consume the SDK as a normal Swift Package Manager dependency from the public binary distribution:

```swift
.package(url: "https://github.com/bithuman-product/bithuman-sdk-public.git", from: "0.8.1")
```

Stack: ASR (SpeechAnalyzer) → LLM (Gemma 3 / 3n via MLX) → TTS (Qwen3-TTS / Kokoro) → bitHuman avatar engine (Wav2Vec2 → DiT → VAE → ANE). Full architecture, hardware floor, pricing, and integration docs live at **[docs.bithuman.ai/swift-sdk](https://docs.bithuman.ai/swift-sdk/overview)**.

## What's here

| Variant | Path     | Form factor                 | Walkthrough             |
| ------- | -------- | --------------------------- | ----------------------- |
| Mac     | [`Mac/`](Mac/)       | Sparkle-updateable .app + DMG | [Mac/README.md](Mac/README.md)       |
| iPad    | [`iPad/`](iPad/)     | Stage-Manager widget + PiP    | [iPad/README.md](iPad/README.md)     |
| iPhone  | [`iPhone/`](iPhone/) | Portrait, smaller LLM         | [iPhone/README.md](iPhone/README.md) |
| Demos   | [`demos/`](demos/)   | Showcase apps (kiosk, tutor, NPC, ...) | [demos/README.md](demos/README.md)   |

### Essence vs Expression — one factory, both runtimes

The SDK now ships two on-device avatar runtimes. **Expression** is the original audio→TTS→DiT actor with a circular floating window; **Essence** is a lighter-weight rectangular full-frame runtime whose lip-sync is pre-baked at `.imx` pack time and which surfaces frames as an `AsyncStream<CGImage?>`. Both Mac and iPad reference apps auto-detect which kind of `.imx` was loaded via the unified factory and dispatch internally — same UX regardless of which runtime drives the avatar:

```swift
let runtime: BithumanRuntime = try Bithuman.createRuntime(modelPath: weightsURL)
switch runtime {
case .expression(let bithuman):
    // existing wiring: VoiceChat → AvatarCoordinator → FramePump →
    // circular AvatarWindow / AvatarRendererView (clipMode = .circle)
case .essence(let essenceRuntime):
    // new wiring: rectangular AvatarWindow(targetSize:clipMode:.fill);
    // mic → essenceRuntime.pushAudio(_:) ; essenceRuntime.frames()
    // AsyncStream → renderer.show(_:)
}
```

The Essence branch is gated behind a `BITHUMAN_KIT_ESSENCE` Swift compile flag in each app's package — off by default until the next bithuman-sdk-public release ships the runtime. Existing Expression behaviour is unchanged when the flag is off.

iPhone is intentionally not in scope for the Essence demo this phase: the 8 GB iPhone 16 Pro memory budget is too tight to host Essence alongside the Expression-class assets safely. iPhone Essence is Phase 2 work.

---

## Mac

![](docs/img/hero.webp)

A SwiftUI App-lifecycle binary that wraps the SDK's `AvatarCoordinator` + `AvatarWindow` graph. Launches into video mode (no terminal), right-click the avatar to swap agent / voice / face / prompt. Ships as a Sparkle-updateable, hardened-runtime, notarised `.app`. Standalone SPM package — `swift run` and you're talking to an avatar in 30 seconds.

```sh
cd Mac
swift run -c release BithumanMac
```

Walkthrough: [Mac/README.md](Mac/README.md). For deployment-side topics (sandbox entitlements, distribution channels, Sparkle setup), see [docs.bithuman.ai/swift-sdk/macos](https://docs.bithuman.ai/swift-sdk/macos).

## iPad

![](docs/img/ipad-widget.webp)

iPadOS app with a 320 pt Stage Manager floating widget, a draggable Picture-in-Picture float, and PhotosPicker face swap. Wrapped by an Xcode project (xcodegen-driven) so it ships through TestFlight / App Store. Targets 16 GB M-series iPad Pro; uses `increased-memory-limit` + `extended-virtual-addressing` entitlements.

```sh
cd iPad/App
xcodegen generate
open BithumanPad.xcodeproj    # then Cmd-R on a real M-series iPad
```

Walkthrough: [iPad/README.md](iPad/README.md). For iOS-side topics (entitlements, hardware gating, TestFlight, PiP), see [docs.bithuman.ai/swift-sdk/ios](https://docs.bithuman.ai/swift-sdk/ios).

## iPhone

![](docs/img/portrait-picker.webp)

Phone-form-factor variant — portrait-locked, single-orientation frame pump, smaller LLM (Gemma 3 1B QAT 4-bit, ~800 MB) so it fits the iOS memory budget without paging. Same SDK, same avatar engine; the windowing + memory-budget tuning is what differs from iPad.

```sh
cd iPhone/App
xcodegen generate
open BithumanPhone.xcodeproj  # then Cmd-R on iPhone 16 Pro+
```

Walkthrough: [iPhone/README.md](iPhone/README.md).

---

## Architecture

Every app in this repo -- reference apps and demos alike -- consumes the bitHuman SDK as an **external, pre-built dependency** via the published binary package (SwiftPM for Apple platforms, pip for Python). No SDK source is vendored. This is intentional: it ensures the apps test the real developer experience, surface packaging or API gaps early, and stay decoupled from engine internals.

```
┌─────────────┐       SwiftPM / pip        ┌──────────────────────┐
│  App code   │  ──────────────────────►   │  bitHumanKit / bithuman  │
│  (this repo)│      published binary      │  (SDK, external)     │
└─────────────┘                            └──────────────────────┘
```

### Adding new apps or demos

- **Reference app** (new platform variant): add a top-level directory (e.g. `visionOS/`), wire the SwiftPM dependency, and add a row to the "What's here" table above.
- **Demo** (use-case showcase): add a subdirectory under `demos/`. See [demos/README.md](demos/README.md) for the checklist.

---

## Hardware requirements

The SDK gates this at runtime via `HardwareCheck.evaluate()`. Under-spec devices see a polite refusal screen.

| Platform | Minimum |
|---|---|
| macOS | M3+ Apple Silicon, macOS 26 (Tahoe) |
| iPad | iPad Pro M4+, 16 GB unified memory, iPadOS 26 |
| iPhone | iPhone 16 Pro+ (A18 Pro), iOS 26 |

## Documentation

- **SDK overview & quickstart** → [docs.bithuman.ai/swift-sdk](https://docs.bithuman.ai/swift-sdk/overview)
- **Authentication** → [docs.bithuman.ai/getting-started/authentication](https://docs.bithuman.ai/getting-started/authentication)
- **Pricing & credits** → [docs.bithuman.ai/getting-started/pricing](https://docs.bithuman.ai/getting-started/pricing)
- **Troubleshooting** → [docs.bithuman.ai/swift-sdk/troubleshooting](https://docs.bithuman.ai/swift-sdk/troubleshooting)

## License

See [LICENSE](LICENSE).
