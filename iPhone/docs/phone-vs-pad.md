# BithumanPhone vs BithumanPad — UX divergences

The iPhone and iPad targets share `bitHumanKit` and the same engine,
but their layouts differ deliberately. This doc records the three
hard-line divergences so future contributors don't accidentally
unify them.

Reference: the iPad scaffold subagent owns
`Apps/BithumanPad/docs/uikit-conditionals.md`, which lists every
macOS-only type in `bitHumanKit/UI` that needs a UIKit equivalent.
Both apps consume those equivalents.

## 1. Layout — single-pane vs split-view

| Aspect | iPhone (`BithumanPhone`) | iPad (`BithumanPad`) |
|---|---|---|
| Container | Single `WindowGroup`, no navigation chrome | `NavigationSplitView` |
| Avatar zone | Fills the entire screen (edge-to-edge) | Detail column |
| Customization surfaces | Sheets (modal) | Sidebar list (always visible) |
| Status bar | Hidden (`statusBarHidden(true)`) | Default (visible) |

**Why:** iPhone screen real estate (~6.3" diagonal on 16 Pro) can't
accommodate a sidebar without shrinking the avatar below the size
where lip-sync reads as natural. iPad's 11"+ canvas has room for
both the avatar and a persistent customization rail.

The phone uses a tap-to-collapse PiP behaviour to free screen space
when the user wants to look at something else (see §3 below).

## 2. Customization presentation — sheets with tab bar vs sidebar list

| Aspect | iPhone | iPad |
|---|---|---|
| Trigger | Top-right `ellipsis.circle.fill` menu | Tap row in sidebar |
| Container | `.sheet(isPresented:)` with `presentationDetents([.large])` | Inline detail / sidebar push |
| Switching surfaces | `TabView` inside the sheet (Agents / Voice / Prompt) | Independent sidebar rows |
| Dismissal | Drag-down or "Done" button | Tap another row |

**Why:** sheets are the canonical iOS pattern for "modal task that
the user finishes and dismisses". Stacking three sheets (one per
customization surface) produces friction on the phone — you'd have
to dismiss the agent picker, tap the menu again, pick voice, etc.
Wrapping all three in a single sheet with a compact tab bar lets the
user move between surfaces without leaving the modal. iPad's
sidebar pattern doesn't have this problem because the surfaces are
all visible simultaneously.

The TabView lives inside the sheet, NOT at the App level, because
the app's primary navigation is "talk to the avatar", not "pick a
tab". Putting the customization tabs at the root would imply
they're peer surfaces to the conversation, which they aren't.

## 3. Orientation — portrait-locked vs all-orientations

| Aspect | iPhone | iPad |
|---|---|---|
| Supported orientations | Portrait only | All four orientations |
| Where pinned | `Info.plist` (`UISupportedInterfaceOrientations`) + runtime `UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)` | Info.plist allows all four |
| PiP collapse | Tap avatar → 120 pt circle, bottom-right | Not applicable (avatar lives in the detail pane regardless) |

**Why:** the avatar engine's frame pump is sized for a single fixed
orientation at startup; rotating mid-session would force a renderer
rebuild and drop the conversation context. iPhone has the screen
size to make portrait the only sensible orientation anyway (a
full-screen avatar in landscape on a phone leaves ~70% black bars).
iPad is large enough that landscape is genuinely useful — the split
view fits naturally — and `NavigationSplitView` already handles the
column reflow, so we let the user rotate.

The PiP-collapse interaction is also phone-specific. On iPad the
avatar is always in its own column, so there's no "free up the
screen" use case.

## What's the same

- The library `bitHumanKit` and its public API surface.
- The renderer view (post-port, `AvatarUIKitRendererView`).
- The customization SwiftUI views (`AgentPickerView`,
  `VoicePickerView`, `PromptEditorView`) — both apps reuse them
  verbatim, just embed them in different containers.
- The lifecycle bootstrap path: `VoiceChat` → `AvatarCoordinator`
  → orchestrator binding.
- The increased-memory-limit + extended-virtual-addressing
  entitlements (both apps need them; see memory note
  `project_ipad_ml_support.md`).

## What the iPad subagent owns that we depend on

- `Apps/BithumanPad/docs/uikit-conditionals.md` — the canonical list
  of macOS-only types in `bitHumanKit/UI` and the UIKit equivalents
  needed. We reference this in our README.
- The `AvatarUIKitRendererView` UIView subclass spec (the phone uses
  the same type; we don't redefine it).
