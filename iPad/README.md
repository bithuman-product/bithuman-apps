# BithumanPad — reference iPadOS app

Reference iPadOS app demonstrating how to host `bitHumanKit` on iPad.
Includes Stage Manager floating-widget sizing, a draggable
Picture-in-Picture float, and PhotosPicker face swap. The Xcode
project under `App/` is the actual shipping target — `Sources/` is
referenced in place via xcodegen.

## Run in 30 seconds

```sh
cd iPad/App
xcodegen generate
open BithumanPad.xcodeproj    # then Cmd-R on a real M-series iPad
```

Prerequisites: Xcode 16+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), a free / paid Apple Developer account, and
an M-series iPad with 16 GB RAM (iPad Pro M4/M5 or iPad Air M2+).

## File walkthrough

```
iPad/
├── README.md
├── App/
│   ├── project.yml                 xcodegen spec — declares the SPM
│   │                               dep on github.com/bithuman-product/bithuman-sdk-public
│   ├── Assets.xcassets/            app icon + accent colour
│   ├── BithumanPad.entitlements    increased-memory + extended-vaddr
│   └── ExportOptions.plist         App Store distribution config
├── Sources/
│   ├── BithumanPadApp.swift        @main App + scene delegate
│   ├── iPadAvatarRoot.swift        iPad-shaped UI recomposition
│   ├── iPadAvatarRendererRepresentable.swift   UIKit bridge
│   └── MacOSStub.swift             stub @main for macOS swift build
├── Resources/
│   ├── Info.plist                  permission strings + scene manifest
│   └── BithumanPad.entitlements    duplicate of App/'s for SPM smoke
├── Scripts/
│   └── build-ipad-app.sh           archive + IPA + TestFlight upload
└── docs/
    └── uikit-conditionals.md       canImport(UIKit) patterns reference
```

### `App/project.yml`

xcodegen spec. **Key edit vs the dev repo**: `packages.bithuman-kit`
points at the public GitHub URL, not a local path. External devs get
a clean SPM resolve out of the box — no checkout of the SDK source
required.

### `Sources/BithumanPadApp.swift`

`@main` App struct + `UIApplicationDelegateAdaptor` + scene delegate.
Stage Manager widget sizing happens here:
`UISceneSizeRestrictions(min == max == 320×320)` clamps the floating
window. The avatar circle is centred inside via `iPadAvatarRoot`.

**Pattern that matters**: scene delegate is assigned via the
`UIApplicationSceneManifest` in Info.plist (defined in `project.yml`),
not via `@SceneStorage`. Multi-window iPad apps need the manifest
form to opt into multi-scene + widget-window classification.

### `Sources/iPadAvatarRoot.swift`

The big one — iPad-shaped recomposition of the avatar UI. Hosts:
- The 250 pt avatar circle (1.30× upscale of the engine's native
  384 px) for pixel-clean output at 2× retina.
- The `LoadingParticleField` warm-up splash with the asymptotic
  progress curve (`1 - exp(-elapsed / 25 s)`).
- The PhotosPicker face-swap entry, with EXIF-orientation
  normalisation before `coordinator.swapPortrait(url:)`.
- The PiP "Float" menu item that hands off to `AvatarPiPController`.

### `Sources/iPadAvatarRendererRepresentable.swift`

Thin `UIViewRepresentable` over `bitHumanKit`'s public
`AvatarRendererView`. Exists because SwiftUI on iPad needs a UIKit
host for the Metal layer the engine draws into.

### `Sources/MacOSStub.swift`

Placeholder `@main` for the SPM macOS smoke build (`swift build` on a
Mac sees this target as a macOS executable when there's no
per-target platform filter). When `canImport(UIKit)` is false this
stub takes over and prints a one-liner.

### `App/BithumanPad.entitlements`

The two memory entitlements:
- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`

Both are special-permission. See the dev-repo's README for the
entitlement-approval-request workflow with Apple.

## Where to extend

- **Different agents**: `AgentCatalog.shared.register(...)` in
  `BithumanPadApp.init`.
- **Different layout**: edit `iPadAvatarRoot`'s SwiftUI tree —
  everything else is engine-side.
- **Memory budget tuning**: see the SDK's `VoiceChatConfig` — turn
  off Kokoro if you only need voice mode (saves ~250 MB).
