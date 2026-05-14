# archive/

Native Swift reference apps that we're parking here while the consolidated
Flutter codebase becomes the single source of truth for cross-platform
demos. Nothing here is dead code — these apps still build against
`bithuman-sdk-public` (legacy bitHumanKit SwiftPM package) and ship
features the Flutter `bithuman_demo` doesn't yet match (on-device LLM
via MLX, ASR via SpeechAnalyzer, drag-drop face swap, Sparkle
auto-updater, etc.).

The plan is to fold the most-loved features into `flutter/bithuman_avatar`
+ `flutter/bithuman_demo` so all three platforms (macOS / iOS / Android)
ship from one Dart codebase. Until that migration lands, treat this
folder as an archive — useful as a reference for the native SwiftUI
patterns + as a fallback build path while the Flutter port catches up.

## What's here

- `Mac/` — full-featured macOS .app (Sparkle auto-updater, DMG release
  pipeline, Stage-Manager-friendly window).
- `iPad/` — Stage-Manager widget + PiP demo.
- `iPhone/` — portrait-orientation, smaller LLM (Gemma 3 1B QAT 4-bit).

Each subdirectory still has its own README.

## How to revive one

`git mv archive/<App>/ <App>/` and the build path is unchanged.
`bithuman-sdk-public`'s SwiftPM coords haven't moved, so a clean
`xcodebuild` (or `swift build` for the Mac one) picks up where it left
off — provided the `from: 0.8.x` SDK pin in `Package.swift` /
`project.yml` is still resolvable.
