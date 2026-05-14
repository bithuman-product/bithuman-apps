// iPadRuntimeDispatch.swift — auto-detect Expression vs Essence at the
// `.imx` boundary on iPadOS.
//
// Phase 1 of bitHuman's two-runtime story: the same factory call —
// `Bithuman.createRuntime(modelPath:)` — peeks the IMX manifest's
// `model_type` field and returns one of two cases:
//
//   * `.expression(let bithuman)` — the existing audio→TTS→DiT actor
//     the iPad demo has always used. Wired through `VoiceChat`.
//
//   * `.essence(let essenceRuntime)` — the new on-device runtime that
//     pre-bakes its lip-sync at .imx pack time and produces frames
//     via an `AsyncStream<CGImage?>`. Rectangular full-frame avatar.
//
// Mirrors `Mac/Sources/RuntimeDispatch.swift`. The iPad demo's Stage
// Manager floating widget already uses `AvatarRendererView` with a
// configurable `ClipMode` — for Essence we simply construct the
// renderer with `clipMode: .fill` (rectangular full-frame) instead of
// `.circle` (the legacy 250 pt avatar circle).
//
// **Compile gate.** `BITHUMAN_KIT_ESSENCE` is set in the iPad build's
// `OTHER_SWIFT_FLAGS` only when the SDK exposes `Bithuman.createRuntime`
// + `EssenceRuntime` (bithuman-kit ≥ the commit landing the Essence
// work — slated for the 0.10.0 bithuman-sdk-public release). Until that
// release ships, the gate is off and the demo falls through to the
// existing Expression-only path.

#if canImport(UIKit)
import Combine
import Foundation
import UIKit
import bitHumanKit

enum iPadRuntimeDispatch {
    /// The `.imx` is an Expression model — proceed with the existing
    /// `VoiceChat`-driven demo path.
    case expression
    /// The `.imx` is an Essence model — caller hands off to the
    /// Essence demo block (see `runEssenceDemo` below).
    case essence
}

/// Peek the `.imx` and return whether the iPad demo should take the
/// Expression or Essence branch. Same code path regardless of which
/// kind of file is loaded — the "one factory, both runtimes" SDK
/// story.
@MainActor
func iPadDetectRuntime(modelPath: URL, lifecycle: BithumanPadLifecycle) throws -> iPadRuntimeDispatch {
    #if BITHUMAN_KIT_ESSENCE
    let runtime: BithumanRuntime = try Bithuman.createRuntime(modelPath: modelPath)
    switch runtime {
    case .expression:
        // Discard the actor; VoiceChat will build its own internally
        // when the existing path proceeds. Same bytes, milliseconds
        // of duplicate work — dwarfed by the ~5–120 s weight load.
        return .expression
    case .essence(let essenceRuntime):
        Task { @MainActor in
            await runEssenceDemo(essenceRuntime: essenceRuntime, lifecycle: lifecycle)
        }
        return .essence
    }
    #else
    _ = modelPath
    _ = lifecycle
    NSLog("[BithumanPad] BITHUMAN_KIT_ESSENCE compile flag is off; assuming Expression `.imx`. Bump bithuman-kit to ≥ 0.10.0 + enable the flag to demo Essence.")
    return .expression
    #endif
}

#if BITHUMAN_KIT_ESSENCE
/// Drive the new Essence runtime to first pixels on iPad. Keeps the
/// floating Stage Manager widget shape the user already knows; the
/// only visible change is the renderer's `clipMode` flips from
/// `.circle` (legacy Expression circle) to `.fill` (Essence
/// rectangular full-frame at the manifest's native resolution).
///
///   1. Build an `AvatarRendererView` with `clipMode: .fill` sized to
///      the runtime's `resolution`.
///   2. Drain `essenceRuntime.frames()` into the renderer's `show(_:)`
///      sink on the main actor.
///   3. Audio capture (mic → 16 kHz int16 → `pushAudio(_:)`) is left
///      as a TODO for the same reasons as the Mac demo — Essence
///      pushAudio will be wired through the existing AVAudioSession
///      chain in a follow-up.
///
/// External developers who want to layer ASR / LLM / TTS on top of
/// Essence can swap step (3) for a TTS-driven push pipeline — same
/// 16 kHz int16 pushAudio contract.
@MainActor
private func runEssenceDemo(
    essenceRuntime: EssenceRuntime,
    lifecycle: BithumanPadLifecycle
) async {
    let res = essenceRuntime.resolution
    let pixelSize = CGSize(width: CGFloat(res.width), height: CGFloat(res.height))

    // Construct the renderer with the new rectangular full-frame
    // clipMode. The iPad app's `AvatarPanelView` already accepts an
    // injected `AvatarRendererView` — we just hand it one configured
    // for Essence. The window scene's 320×320 fixed size in
    // `BithumanPadSceneDelegate` will letterbox the rectangular
    // Essence frame inside the floating widget; product builds will
    // probably want to relax that constraint.
    let renderer = AvatarRendererView(
        frame: CGRect(origin: .zero, size: pixelSize),
        idleFrame: nil,
        clipMode: .fill
    )

    lifecycle.bindEssenceRenderer(renderer)

    // Frame consumer — drain the AsyncStream onto the renderer. Hop
    // back to the MainActor for the show call so UIKit isn't touched
    // off-thread.
    let frameTask = Task { [weak renderer] in
        for await maybeFrame in await essenceRuntime.frames() {
            guard let renderer else { return }
            if let frame = maybeFrame {
                await MainActor.run { renderer.show(frame) }
            }
            // `nil` is the idle marker (audio quiet for >100 ms).
            // Essence bakes its own internal idle motion; in this
            // first reference build we just skip rather than blank
            // the renderer. A real product would render a held
            // portrait here.
        }
    }

    NSLog("[BithumanPad] Essence demo started: \(res.width)×\(res.height), clipMode=.fill")

    // TODO: AVAudioEngine input → 16 kHz int16 resample →
    // `essenceRuntime.pushAudio(_:)`. Until that lands, the Essence
    // demo renders idle frames only — useful as a "the runtime is
    // alive, here is the resolution & clipMode" reference, not as a
    // talking-head demo. Tracked separately from this Phase 1 commit.

    // Park the task lifetime on the lifecycle so it isn't deallocated
    // when this function returns.
    lifecycle.bindEssenceFrameTask(frameTask)
}
#endif

#endif // canImport(UIKit)
