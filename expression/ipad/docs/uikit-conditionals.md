# UIKit conditionals — bitHumanKit/UI

Catalogue of macOS-only types in `Sources/bitHumanKit/UI/` that the
iPad target can't link against. Each entry pairs the existing AppKit
type with the UIKit equivalent the foreground will write next.

The convention to land in a follow-up:

```swift
#if canImport(AppKit)
import AppKit
final class AvatarRendererView: NSView { … }
#elseif canImport(UIKit)
import UIKit
final class AvatarRendererView: UIView { … }
#endif
```

Both branches expose the **same API surface** so the cross-platform
`AvatarCoordinator` + `FramePump` + SwiftUI views compile against
either platform without further branching.

---

## 1. `AvatarRendererView` (NSView subclass)

**File**: `Sources/bitHumanKit/UI/AvatarRenderer.swift`

**Today**: AppKit `NSView` with one CALayer child; the FramePump's
consumer timer calls `show(_:)` to swap the layer's `contents` 25× / s.

**iPad spec**: identical CALayer approach with a `UIView` superclass.
A working implementation is already provided as
`PadAvatarRendererView` in
`Apps/BithumanPad/Sources/iPadAvatarRendererRepresentable.swift` —
when promoting into the library, copy that body and tweak the
`#elseif canImport(UIKit)` branch.

**API surface** (must match across both platforms):

```swift
init(frame: CGRect, idleFrame: CGImage?)
func show(_ frame: CGImage)
```

The `NSRect` ↔ `CGRect` typealias (and `NSColor` vs `UIColor`)
are the only material differences.

---

## 2. `AvatarWindow` (NSWindow subclass)

**File**: `Sources/bitHumanKit/UI/AvatarWindow.swift`

**Today**: borderless circular floating NSWindow that hosts the
renderer + SwiftUI overlay via `NSHostingView`.

**iPad spec**: NO direct equivalent. The iPad's window is the
SwiftUI `WindowGroup` (a UIWindowScene under the hood). The
FramePump's `window: AvatarWindow` parameter has to be replaced
with a protocol or a typealias:

```swift
#if canImport(AppKit)
public typealias AvatarHost = AvatarWindow
#elseif canImport(UIKit)
public protocol AvatarHost: AnyObject {
    @MainActor func render(_ frame: CGImage)
}
#endif
```

The `iPadAvatarRendererRepresentable` would then conform a thin
host wrapper to this protocol and pass it to the FramePump. All
existing `window.render(frame)` call sites stay unchanged.

**Public statics that must stay accessible cross-platform**:
`AvatarWindow.windowSide`, `.labelZone`, `.windowHeight`,
`.avatarSide`, `.ringSide` — these are SwiftUI layout constants
used by `AvatarRootView` etc. Lift into a free `enum AvatarLayout
{ static let avatarSide … }` that's not platform-gated, then have
the macOS NSWindow forward to those constants.

---

## 3. `BithumanAppDelegate` (NSApplicationDelegate)

**File**: `Sources/bitHumanKit/UI/AppDelegate.swift`

**Today**: bootstraps NSApp, hides Dock icon flicker, runs
`installMainMenu()`, owns the avatar window's strong ref.

**iPad spec**: superseded entirely by
`BithumanPadAppDelegate` in
`Apps/BithumanPad/Sources/BithumanPadApp.swift`. Wrap the entire
file with `#if canImport(AppKit)` — there's no UIKit equivalent
needed in the library, the iPad target supplies its own.

---

## 4. `installMainMenu()`

**File**: `Sources/bitHumanKit/UI/AvatarWindow.swift`

**Today**: free function that builds NSApp's menu bar with
Quit/Minimize/Close.

**iPad spec**: `UIMenuBuilder` API exists for hardware keyboard
shortcuts, but we don't need it in the scaffold. Wrap the existing
function with `#if canImport(AppKit)`. The iPad target's toolbar
menu in `iPadAvatarRoot.swift` covers the user-facing actions
(Change image / voice / prompt).

---

## 5. `VoicePickerWindow` (NSWindow subclass)

**File**: `Sources/bitHumanKit/UI/VoiceGallery.swift` (sits next to
`VoicePickerView`)

**Today**: floating NSWindow hosting `VoicePickerView` via
`NSHostingView`.

**iPad spec**: no UIKit window analog needed. The iPad presents
`VoicePickerView` directly as a sheet via SwiftUI's
`.sheet(item:content:)` modifier. Wrap the NSWindow class with
`#if canImport(AppKit)`. `VoicePickerView` itself stays
cross-platform — make it `public` so the iPad target can present it.

---

## 6. `PromptEditorWindow` (NSWindow subclass)

**File**: `Sources/bitHumanKit/UI/PromptTemplates.swift`

**Today / iPad spec**: same as `VoicePickerWindow` — wrap the
NSWindow with `#if canImport(AppKit)`, mark `PromptEditorView` as
`public`.

---

## 7. `AgentPickerWindow` (NSWindow subclass)

**File**: `Sources/bitHumanKit/UI/AgentPicker.swift`

**Today / iPad spec**: same as `VoicePickerWindow` — wrap the
NSWindow with `#if canImport(AppKit)`, mark `AgentPickerView` and
`AgentCard` as `public`.

---

## Coordinator method gating

`AvatarCoordinator` is mostly cross-platform but has four methods
that drive AppKit windows:

```swift
func showVoicePicker()      { … VoicePickerWindow(…) … }
func showPromptEditor()     { … PromptEditorWindow(…) … }
func showAgentPicker()      { … AgentPickerWindow(…) … }
func showPortraitPicker()   { … NSOpenPanel(…) … }
```

Wrap each with `#if canImport(AppKit)`. The iPad target reaches the
same functionality through `iPadAvatarRoot`'s `presentedSheet`
state machine — it never calls these `show*` methods.

The four NSWindow strong-ref properties on the coordinator
(`voicePickerWindow`, `promptEditorWindow`, `agentPickerWindow`)
also need `#if canImport(AppKit)` gating since their type is an
AppKit class.

---

## Cross-platform views that are already iPad-ready

These compile against UIKit unchanged — they only need a `public`
modifier added so the iPad target can reach them:

- `LoadingParticleField` (uses `TimelineView` + `Canvas`, both iOS-OK)
- `StateRing` (`Canvas`-based, no AppKit)
- `StateLabel` (plain SwiftUI)
- `VoicePickerView`, `VoiceCard`
- `PromptEditorView`
- `AgentPickerView`, `AgentCard`
- `BrandColors` (just `Color` constants)
- `IdleFrameCache` (CGImage + Atomic — no UI framework)
- `PromptTemplate`, `PromptTemplates` data structs

---

## Audio + drag-drop

- `AvatarRootView`'s drag-drop overlay (`DropHintOverlay`,
  `.onDrop(of: [.fileURL, .image], …)`) is AppKit-only because
  `URL`-providers come through `NSItemProvider` on Mac. iPad uses
  the system Photos picker (handled in `PortraitPickerSheet`). No
  cross-platform unification needed; gate `AvatarRootView` itself
  behind `#if canImport(AppKit)`.

- The voice-processing IO unit (AEC) is configured differently:
  on macOS the `AVAudioEngine` `setVoiceProcessingEnabled(true)`
  call is on the input + output nodes; on iOS the equivalent is
  the `AVAudioSession` mode `.voiceChat`, which the iPad's
  `BithumanPadAppDelegate.configureAudioSession` already sets up.
  No library-side change required — `AudioGraph.swift` already has
  the right `#if os(macOS)` gates.
