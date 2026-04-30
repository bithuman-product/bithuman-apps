import AppKit
import bitHumanKit
import Foundation
import SwiftUI

/// `BithumanMac` is the .app shell for the bitHuman desktop product.
///
/// This target is a *thin wrapper* around the same `AvatarCoordinator`
/// + `AvatarWindow` + `FramePump` graph that powers `bithuman-cli video`.
/// All UI lives in `bitHumanKit/UI/`; we just translate the SwiftUI
/// `App` lifecycle into the same boot sequence `runVideoSession` runs.
///
/// We deliberately do NOT use `WindowGroup` here. The avatar surface is
/// an AppKit `NSWindow` (circular, borderless, custom drop shadow),
/// already hand-built in `AvatarWindow`. Letting SwiftUI also open a
/// stock chrome window on launch would give us two windows. `Settings`
/// is the only `Scene` that doesn't auto-open anything — we use it as
/// a no-op scene and let the AppDelegate create the real window from
/// `applicationDidFinishLaunching`, exactly like the CLI does.
///
/// Future entry-point switching (text mode / voice mode toggles inside
/// the app) can be done by wiring app-state @AppStorage flags into the
/// AppDelegate's `onLaunch` closure — but never via
/// `CommandLine.arguments`, since this binary is launched by Finder.
@main
struct BithumanMacApp: App {
    @NSApplicationDelegateAdaptor(BithumanMacAppDelegate.self) private var appDelegate

    init() {
        // The framework's main menu (Cmd-Q, edit menu, etc) — same one
        // the CLI installs. Safe to call from `init`; SwiftUI installs
        // its own menu items on top, but the file/edit/window/help
        // structure we want is already there.
        installMainMenu()
    }

    var body: some Scene {
        // No SwiftUI scene. AvatarWindow is created imperatively from
        // the AppDelegate. `Settings` registers no window on launch.
        // (If we ever want a real "Settings…" menu item, swap it for
        // an actual settings view.)
        Settings {
            EmptyView()
        }
    }
}

/// `NSApplicationDelegateAdaptor` requires a no-arg initialiser. The
/// existing `BithumanAppDelegate` takes an `onLaunch` closure (so the
/// CLI can hand it the video bootstrap). For the .app build we
/// subclass it with a fixed onLaunch that runs `videoSessionLaunch()`,
/// the .app's analogue of `runVideoSession`.
///
/// Why subclass instead of changing `BithumanAppDelegate`'s init:
/// the constraint says we must not modify `Sources/`. The framework's
/// delegate already exposes `retainSession`, `avatarWindow`, and the
/// terminate-grace shutdown path as `public` / `open`-friendly. We
/// extend by inheritance.
@MainActor
final class BithumanMacAppDelegate: BithumanAppDelegate {
    @MainActor
    init() {
        super.init(onLaunch: {
            try await videoSessionLaunch()
        })
    }
}

// MARK: - Video session bootstrap (the .app analogue of CLI's runVideoSession)

/// Mirrors `BithumanCLI.runVideoSession(args:)` but drops the CLIArgs
/// dependency: the .app launches with the default agent (Diego), the
/// default Kokoro voice, and no portrait override. User-driven
/// face/voice/prompt swaps happen at runtime through the existing
/// right-click menu the coordinator already exposes.
@MainActor
private func videoSessionLaunch() async throws {
    let weightsURL = try await ExpressionWeights.ensureAvailable()

    // Phase 1 Essence dispatch. Auto-detect on the `.imx` — same UX
    // whether the loaded file is Expression or Essence (the "one
    // factory, both runtimes" SDK story). When the SDK in use predates
    // the Essence work (BITHUMAN_KIT_ESSENCE flag off) the dispatcher
    // returns `.expression` unconditionally, so this branch is a true
    // no-op for the existing demo path.
    //
    // The pattern this commit demonstrates (mirrored in the iPad app):
    //
    //   ```swift
    //   let runtime = try Bithuman.createRuntime(modelPath: weightsURL)
    //   switch runtime {
    //   case .expression(let bithuman):
    //       // existing VoiceChat-driven path
    //   case .essence(let essenceRuntime):
    //       // new pushAudio + frames() AsyncStream path
    //   }
    //   ```
    //
    // For Essence, `runEssenceDemo` (in `RuntimeDispatch.swift`) builds
    // the rectangular `AvatarWindow(targetSize:clipMode:.fill)` and
    // returns; we early-out from this function so the existing
    // VoiceChat bootstrap below doesn't also fire.
    if try detectRuntime(modelPath: weightsURL) == .essence {
        return
    }

    let defaultAgent = AgentCatalog.defaultAgent
    let portraitURL = AgentCatalog.thumbnailURL(for: defaultAgent)
    let initialPrompt = defaultAgent.systemPrompt
    let voicePreset = defaultAgent.voicePreset

    var config = VoiceChatConfig()
    config.localeIdentifier = "en-US"
    config.systemPrompt = initialPrompt
    config.avatar = AvatarConfig(modelPath: weightsURL, portraitPath: portraitURL)

    let chat = VoiceChat(config: config)
    try await chat.start()

    guard let bh = chat.bithuman else {
        FileHandle.standardError.write(
            Data("error: avatar engine failed to initialise\n".utf8)
        )
        exit(1)
    }
    _ = bh.frameSize

    await chat.setVoicePreset(voicePreset)

    let coordinator = AvatarCoordinator(chat: chat)
    coordinator.bindToOrchestrator()
    coordinator.currentSystemPrompt = initialPrompt
    coordinator.currentVoicePreset = voicePreset
    coordinator.currentAgentCode = defaultAgent.code
    coordinator.prewarmPortraitURL = portraitURL

    let window = AvatarWindow(idleFrame: chat.initialIdleFrame, coordinator: coordinator)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    let pump = FramePump(bithuman: bh, chat: chat, window: window, coordinator: coordinator)
    coordinator.framePump = pump
    chat.onBargeIn = { [weak pump] in
        pump?.buffer.flushSpeech()
    }
    chat.onCheckSpeechBuffer = { [weak pump] in
        pump?.buffer.hasSpeech == false
    }

    if let delegate = NSApp.delegate as? BithumanAppDelegate {
        delegate.avatarWindow = window
        delegate.retainSession(chat: chat, pump: pump)
    }
}
