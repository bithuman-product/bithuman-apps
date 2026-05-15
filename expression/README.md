# expression/

Native reference apps for the **Expression** avatar runtime — the
full-stack pipeline (ASR → on-device LLM → TTS → DiT lip-sync) with
custom-portrait support, Sparkle auto-update, drag-drop face swap, and
the circular floating-window UX.

These are *complementary to* the Flutter `bithuman_avatar` reference
app under [`../flutter/bithuman_avatar/example/`](../flutter/bithuman_avatar/example/),
not redundant with it. The two have intentionally non-overlapping
scopes:

|                       | `expression/` (this dir)               | `flutter/bithuman_avatar/example/`     |
|-----------------------|----------------------------------------|----------------------------------------|
| **Runtime**           | Expression (Wav2Vec2 → DiT → VAE → ANE) | Essence (libessence streaming pipeline) |
| **LLM / TTS**         | On-device via MLX (Gemma 3 + Qwen3-TTS / Kokoro) | Cloud (OpenAI Realtime) |
| **Custom portrait**   | yes — drag-drop a JPG to swap the face | no — `.imx` bakes identity at pack time |
| **Auto-update**       | Sparkle DMG (Mac)                      | flutter run / `flutter build`          |
| **Platforms**         | macOS, iPadOS (live); iOS (parked in [`../archive/iPhone/`](../archive/iPhone/) — compute budget) | macOS, iOS, Android (single Dart codebase) |
| **SDK consumed**      | `bithuman-sdk-public` (legacy bitHumanKit SwiftPM) | `bithuman-sdk` libessence (via plugin) |

## What's here

- [`mac/`](mac/) — full-featured macOS .app. Sparkle-updateable,
  notarised DMG, hardened runtime. SwiftUI App-lifecycle binary that
  wraps bitHumanKit's `AvatarCoordinator` + `AvatarWindow` graph.
- [`ipad/`](ipad/) — iPadOS variant. Stage-Manager floating widget,
  draggable Picture-in-Picture, PhotosPicker face swap. Targets M4+
  iPad Pro with `increased-memory-limit` entitlement.

The iOS Expression variant stays parked in [`../archive/iPhone/`](../archive/iPhone/)
for now — the iPhone 16 Pro 8 GB memory budget is too tight to host
Expression alongside a smaller LLM safely. Phase 2 work (a leaner
on-device LLM track for iPhone, or moving iPhone Expression to the
cloud LLM/TTS path) will revisit revival.

## When to pick Expression vs Essence

- **Expression** when you want full on-device autonomy (no cloud round
  trip, no API key required), custom portraits, the largest expression
  range. Costs: ~7 GB on-disk model fetch, MLX → Apple-Silicon-only,
  higher RAM ceiling.
- **Essence** when you want one codebase across macOS/iOS/Android, the
  smallest possible runtime footprint per session, or bring-your-own
  LLM/TTS via OpenAI (or any audio source). Costs: cloud dependency for
  voice (today), pre-baked lip-sync per `.imx` (no portrait swap).

## SDK version pin

All apps in `expression/` (and the parked variants in `archive/`)
depend on **bitHumanKit from `bithuman-sdk-public`**, version pinned in
[`../version.yml`](../version.yml). The CI workflow
`.github/workflows/sdk-version-consistency.yml` checks every consumer's
`Package.swift` / `project.yml` against that pin so accidental drift
doesn't leak to PR.
