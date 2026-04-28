# BithumanMac — reference macOS app

A SwiftUI App-lifecycle binary that demonstrates how to host
`bitHumanKit`'s avatar pipeline as a desktop product. The shell is
intentionally tiny — windowing + menu + Sparkle + entitlements — so
it doubles as a copy-paste starting point for your own app.

## Run in 30 seconds

```sh
cd Mac
swift run -c release BithumanMac
```

First launch downloads the model weights (~1.5 GB) into the Hugging
Face cache (`~/.cache/huggingface/hub/`). Subsequent launches are
fast.

## File walkthrough

```
Mac/
├── Package.swift
├── README.md                     this file
├── Sources/
│   └── BithumanMacApp.swift      @main App struct
├── Resources/
│   ├── Info.plist                bundle id, mic perms, Sparkle keys
│   └── BithumanMac.entitlements  hardened runtime + JIT + mic
├── Scripts/
│   └── build-mac-app.sh          .app + signed + notarised + DMG
└── docs/
    └── sparkle-setup.md          EdDSA keys + appcast feed
```

### `Sources/BithumanMacApp.swift`

The entire app. Roughly 110 LOC. Imports `bitHumanKit`, instantiates
`AvatarCoordinator`, hosts an `AvatarWindow` (NSWindow subclass that
wraps `AvatarRootView`), installs the main menu, wires Sparkle.

**Pattern that matters**: the app does NOT consult
`CommandLine.arguments`. It's launched from Finder/Dock, so any
optional behaviour should hang off SwiftUI `@AppStorage` instead.

**Where to extend**: replace the default agent / voice / face by
calling `coordinator.swap…` in `applicationDidFinishLaunching`.

### `Resources/Info.plist`

Bundle ID, microphone usage description, Sparkle's
`SUFeedURL` + `SUPublicEDKey`. The microphone string is what shows on
the very first permission prompt — ship copy that explains the
on-device guarantee.

### `Resources/BithumanMac.entitlements`

Hardened runtime + microphone + Apple Events + JIT (MLX needs
JIT-compiled Metal shaders). DO NOT enable App Sandbox without
testing — the avatar engine writes a Hugging Face cache outside any
sandbox container by default.

### `Scripts/build-mac-app.sh`

Production pipeline: `xcodebuild` → codesign with Developer ID →
`xcrun notarytool` → `stapler staple` → DMG. See `docs/sparkle-setup.md`
for the EdDSA key generation that has to happen before the FIRST
signed release.

## Where to extend

- **Custom agents**: `AgentCatalog.shared.register(...)` from your app
  delegate.
- **Different LLM / TTS**: see `bitHumanKit`'s `VoiceChatConfig`.
- **Custom voice**: drop a 5–15 s reference WAV + transcript into your
  bundle and pass it to `VoiceChatConfig.refAudio` / `refText`.
- **Custom avatar portrait**: any RGB JPEG/PNG 512×512+ via
  `coordinator.swapPortrait(url:)`.
