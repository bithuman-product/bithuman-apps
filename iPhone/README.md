# BithumanPhone — reference iOS app

Reference iPhone app demonstrating how to host `bitHumanKit` on the
phone form factor. Portrait-locked, single-orientation frame pump,
and a smaller LLM (Gemma 3 1B QAT 4-bit, ~800 MB) so the active
turn fits inside the iPhone memory ceiling without paging.

## Run in 30 seconds

```sh
cd iPhone/App
xcodegen generate
open BithumanPhone.xcodeproj  # then Cmd-R on iPhone 15 Pro+
```

Prerequisites: Xcode 16+, [`xcodegen`](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), an Apple Developer account, and an iPhone
with at least 8 GB RAM (iPhone 15 Pro / Pro Max / 16 / Air).

## File walkthrough

```
iPhone/
├── README.md
├── App/
│   ├── project.yml                  xcodegen spec — SPM dep on
│   │                                github.com/bithuman-product/bithuman-kit
│   ├── Assets.xcassets/             app icon
│   ├── BithumanPhone.entitlements   increased-memory + extended-vaddr
│   └── ExportOptions.plist          App Store distribution config
├── Sources/
│   ├── BithumanPhoneApp.swift       @main App + orientation lock
│   ├── iPhoneAvatarRoot.swift       phone-shaped layout shell
│   └── MacOSStub.swift              stub @main for macOS swift build
├── Resources/
│   ├── Info.plist                   portrait-only orientation
│   └── BithumanPhone.entitlements   duplicate of App/'s for SPM smoke
├── Scripts/
│   └── build-iphone-app.sh          archive + IPA + TestFlight upload
└── docs/
    └── phone-vs-pad.md              what differs from the iPad app
```

### `Sources/BithumanPhoneApp.swift`

`@main` App + the `PhoneOrientationLock` UIKit shim that pins the
window to portrait. The avatar engine's frame pump is sized to a
single fixed orientation on phone — switching mid-flight would force
a reallocation of the DiT working set.

**Pattern that matters**: orientation lock at the OS level
(Info.plist `UISupportedInterfaceOrientations: portrait-only`) AND
at the SwiftUI level (`PhoneOrientationLock`). One without the other
leaves a brief landscape flicker at app launch.

### `Sources/iPhoneAvatarRoot.swift`

Phone-shaped layout shell. Differs from the iPad sibling in:
- Full-screen avatar by default; tap to collapse the chrome.
- No PiP support — phone form factor doesn't get the floating-window
  affordance.
- No PhotosPicker face swap by default (you can re-enable it; the iPad
  version has the EXIF-normalisation code you'd want).

See `docs/phone-vs-pad.md` for the full delta.

### `Sources/MacOSStub.swift`

Same role as the iPad's stub — placates `swift build` on macOS so the
package resolves cleanly when the target's platform filter is
inferred from `canImport(UIKit)`.

### `App/BithumanPhone.entitlements`

Same two memory entitlements as the iPad app:
- `com.apple.developer.kernel.increased-memory-limit`
- `com.apple.developer.kernel.extended-virtual-addressing`

The iPhone budget is tighter — the smaller LLM (Gemma 3 1B QAT 4-bit)
is what makes the active turn fit. The SDK auto-selects this LLM
when `#if os(iOS) && !os(macCatalyst)`; you can override via
`VoiceChatConfig.llm`.

## Where to extend

- **Bigger LLM**: if you only target iPhone 16 Pro+ (12 GB),
  override `VoiceChatConfig.llm` to Gemma 3n E2B 4-bit (~2 GB).
- **Different orientation**: edit `Info.plist` AND
  `PhoneOrientationLock` — both have to agree.
- **Custom voice / agents**: same as the Mac/iPad apps.
