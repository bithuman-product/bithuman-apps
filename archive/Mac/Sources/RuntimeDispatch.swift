// RuntimeDispatch.swift — auto-detect Expression vs Essence at the
// `.imx` boundary.
//
// Phase 1 of bitHuman's two-runtime story: the same factory call —
// `Bithuman.createRuntime(modelPath:)` — peeks the IMX manifest's
// `model_type` field and returns one of two cases:
//
//   * `.expression(let bithuman)` — the existing audio→TTS→DiT actor
//     the macOS demo has always used. Wired through `VoiceChat`.
//
//   * `.essence(let essenceRuntime)` — the new on-device runtime that
//     pre-bakes its lip-sync at .imx pack time and produces frames
//     via an `AsyncStream<CGImage?>`. Rectangular full-frame avatar.
//
// **Why this lives in a separate file.** Keeps the boot-time call site
// in `BithumanMacApp.videoSessionLaunch` short and reads as one switch.
// The Essence wiring (audio capture → `pushAudio` → frame consumer →
// `AvatarWindow(targetSize:clipMode:)`) is a self-contained demo block
// rather than scattered branches inside the existing Expression flow.
//
// **Compile gate.** `BITHUMAN_KIT_ESSENCE` is set in this Mac SPM
// target's `swiftSettings` only when the SDK dependency exposes
// `Bithuman.createRuntime` + `EssenceRuntime` (i.e. bithuman-kit ≥ the
// commit that lands the Essence work — slated for the 0.10.0
// bithuman-sdk-public release). Until that release ships, the gate is
// off and the demo falls through to the existing Expression-only path
// — guaranteeing the reference Mac app keeps building against the
// current public binary distribution.

import AppKit
import bitHumanKit
import Foundation

// MARK: - Public dispatch outcome

/// What the auto-detect determined for a given `.imx`. Used by the
/// Mac app's launch path to decide whether to fall through to the
/// existing `VoiceChat` bootstrap or hand off to the Essence demo.
enum RuntimeDispatch {
    /// The `.imx` is an Expression model — proceed with the existing
    /// `VoiceChat`-driven demo path.
    case expression
    /// The `.imx` is an Essence model — caller should hand off to the
    /// Essence demo block (see `runEssenceDemo` below).
    case essence
}

// MARK: - Auto-detect entry point

/// Peek the `.imx` at `modelPath` and return whether the macOS demo
/// should take the Expression or Essence branch. Same code path
/// regardless of which kind of file the developer drops in — the
/// "one factory, both runtimes" SDK story.
///
/// Throws if the `.imx` is malformed or advertises an unknown
/// `model_type` (the SDK surfaces this as
/// `BithumanCreateError.wrongModelType`).
@MainActor
func detectRuntime(modelPath: URL) throws -> RuntimeDispatch {
    #if BITHUMAN_KIT_ESSENCE
    // The factory does the manifest peek, validates hardware, and
    // builds the runtime in one shot. For Expression we discard the
    // returned actor (VoiceChat will build its own internally — same
    // bytes, milliseconds of duplicate work, dwarfed by the multi-
    // second weight load). For Essence we pass the live runtime
    // through to the demo block.
    let runtime: BithumanRuntime = try Bithuman.createRuntime(modelPath: modelPath)
    switch runtime {
    case .expression:
        return .expression
    case .essence(let essenceRuntime):
        // Hand off — kicks the demo block off-thread; we return
        // `.essence` so the caller knows NOT to fall through to the
        // Expression bootstrap.
        Task { @MainActor in
            await runEssenceDemo(essenceRuntime: essenceRuntime, modelPath: modelPath)
        }
        return .essence
    }
    #else
    // SDK in use predates the Essence work. Fall through to the
    // Expression path — the existing demo continues to work
    // unchanged. Drop a one-line breadcrumb so a developer running
    // the demo against an Essence `.imx` here sees a clear hint.
    _ = modelPath
    NSLog("[BithumanMac] BITHUMAN_KIT_ESSENCE compile flag is off; assuming Expression `.imx`. Bump bithuman-sdk-public to ≥ 0.10.0 + enable the flag to demo Essence.")
    return .expression
    #endif
}

// MARK: - Essence demo block

#if BITHUMAN_KIT_ESSENCE
/// Drive the new Essence runtime to first pixels. This is intentionally
/// minimal — it's a reference-app demo, not a product:
///
///   1. Open the rectangular `AvatarWindow` at the runtime's native
///      resolution with `clipMode = .fill` (the new constructor
///      signature, distinct from the legacy circular Expression one).
///   2. Capture mic audio at 16 kHz int16 and forward to
///      `essenceRuntime.pushAudio(_:)`.
///   3. Drain `essenceRuntime.frames()` (`AsyncStream<CGImage?>`) into
///      the window's renderer; on `nil` we render the Essence-baked
///      idle frame the runtime emits when audio has been silent for
///      ≥100 ms.
///
/// External developers who want to layer ASR / LLM / TTS on top of
/// Essence can swap step (2) for a TTS-driven push pipeline — same
/// `pushAudio(_:)` API, same 16 kHz int16 contract.
@MainActor
private func runEssenceDemo(essenceRuntime: EssenceRuntime, modelPath: URL) async {
    let res = essenceRuntime.resolution
    let targetSize = CGSize(width: CGFloat(res.width), height: CGFloat(res.height))

    // The new rectangular full-frame init. `clipMode: .fill` skips the
    // circular crop the Expression demo uses — the Essence frame is
    // designed to fill its rectangle edge-to-edge.
    //
    // No coordinator: the existing AvatarCoordinator orchestrates
    // VoiceChat (ASR/LLM/TTS) which Essence's pushAudio path doesn't
    // touch. The convenience init that requires a coordinator is for
    // the legacy circular Expression path; we use the targetSize/
    // clipMode init that doesn't.
    let window = AvatarWindow(
        targetSize: targetSize,
        clipMode: .fill,
        idleFrame: nil,
        coordinator: nil
    )
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    // Frame consumer — drain the AsyncStream onto the renderer. A
    // detached Task because the actor's pump fires the stream from
    // off-MainActor; we re-hop with `await window.render(frame)` (the
    // window's `render` is MainActor-safe).
    let frameTask = Task { [weak window] in
        for await maybeFrame in await essenceRuntime.frames() {
            guard let window else { return }
            if let frame = maybeFrame {
                await MainActor.run { window.render(frame) }
            }
            // `nil` is the idle marker — on first build we don't have
            // a bundled idle frame to fall back to (Essence bakes its
            // own internal idle motion); just skip rather than blank
            // the window. A real product would render a held
            // portrait here.
        }
    }

    // Mic capture — 16 kHz mono int16 → pushAudio. Reuses the SDK's
    // mic helper if exposed, otherwise this is the place to plug in
    // AVAudioEngine. For Phase 1 we leave the mic block as a TODO so
    // the reference app boots Essence to first pixels without
    // requiring a full audio pipeline (the SDK's `MicCapture` API is
    // not yet part of the public surface in 0.10.0 candidate).
    //
    // TODO: wire AVAudioEngine input → 16 kHz int16 resampler →
    // `essenceRuntime.pushAudio(_:)`. Until that lands, the Essence
    // demo renders idle frames only — useful as a "the runtime is
    // alive, here is the resolution & clipMode" reference, not as a
    // talking-head demo. Tracked separately from this Phase 1 commit.

    NSLog("[BithumanMac] Essence demo started: \(res.width)×\(res.height), clipMode=.fill, source=\(modelPath.lastPathComponent)")

    // Park the task on the AppDelegate so it isn't deallocated on
    // function return.
    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
    }
    // The frameTask itself is rooted by the window's lifetime via
    // capture; the SDK actor cleans up its pump when the consumer
    // cancels the stream.
    _ = frameTask
}
#endif
