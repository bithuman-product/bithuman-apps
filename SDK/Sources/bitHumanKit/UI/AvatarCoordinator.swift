#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import Combine
import Foundation
import SwiftUI

/// Owns the avatar window's reactive UI state and exposes
/// commands the right-click menu and drag-drop handler call into.
/// Also forwards CGImage frames to the AppKit `AvatarRendererView`
/// (the underlying CALayer is faster to update directly than going
/// through SwiftUI's view tree at 25 FPS).
@MainActor
public final class AvatarCoordinator: ObservableObject {

    /// What's happening to the avatar identity right now. Drives
    /// the crafting-spinner overlay.
    public enum SwapState: Equatable {
        case idle
        case encoding(label: String)
    }

    @Published public var swapState: SwapState = .idle

    /// True while a face swap (drag-drop, agent pick, picker) is
    /// running. SwiftUI views read this to hide the status pill —
    /// the orchestrator state (typically `.listening`) is misleading
    /// while we're VAE-encoding a new face and dropping user turns.
    public var isSwapping: Bool {
        if case .encoding = swapState { return true }
        return false
    }

    /// True once the FramePump has rendered its first frame onto
    /// the avatar. Drives the LoadingParticleField fade-out.
    @Published public var isReady: Bool = false

    /// Idle-frame palindrome cache fill ratio in [0, 1]. The
    /// pre-chat splash binds to this so the user watches a real
    /// progress bar climb during the ~10 s warm-up instead of an
    /// indefinite spinner. Resets to 0 on portrait/agent swap.
    @Published public var idlePrewarmProgress: Double = 0

    /// True once the idle palindrome cache has filled (≥ 250
    /// frames). Splash overlays remain visible until this flips
    /// so the chat doesn't unblock before idle motion is buffered.
    @Published public var idlePrewarmReady: Bool = false

    /// True only when the prewarm UI is up because the user just
    /// swapped agents/portraits — the FramePump producer drops
    /// in-flight speech so the previous identity stops talking
    /// immediately and no new speech plays until the new identity's
    /// cache is ready. False on initial boot (where we still want
    /// the user to be able to talk to the agent through the splash
    /// instead of staring at a deaf face).
    @Published public var muteAgentDuringPrewarm: Bool = false

    /// Static portrait shown inside the warm-up splash so the user
    /// sees the agent they're switching to (or booting into) while
    /// the idle palindrome cache fills. Set to the bundled JPG for
    /// agent picks, the dropped image URL for portrait swaps, and
    /// the default-agent thumbnail at app launch.
    @Published public var prewarmPortraitURL: URL?

    /// Mirror of `chat.orchestrator?.state`. SwiftUI views observe
    /// this; we update it on every change of the orchestrator's
    /// own @Published state via a Combine subscription.
    @Published public var orchestratorState: VoiceChatOrchestrator.State = .idle

    /// Currently-committed Kokoro voice preset. The voice gallery
    /// reads this to highlight the active card.
    @Published public var currentVoicePreset: String = "af_heart"

    /// Code of the most recently applied bundled agent — drives the
    /// "active" highlight in the agent picker. Nil when the user has
    /// since drifted off-template by changing image, voice, or prompt
    /// individually.
    @Published public var currentAgentCode: String?

    /// VoiceChat is the bridge to the engine + TTS. Commands fire
    /// through this.
    /// Optional `VoiceChat`. Nil in cloud mode (`avatar --openai`)
    /// where the OpenAI Realtime client owns the conversation and
    /// the only role of this coordinator is to feed the SwiftUI
    /// avatar overlay (idle-prewarm bar, ready flag). Every method
    /// that mutates chat state (portrait swap, voice swap, prompt
    /// edit) silently no-ops when `chat` is nil — those features
    /// don't apply in cloud mode anyway.
    let chat: VoiceChat?
    /// Weak ref to the FramePump — used to invalidate the idle
    /// palindrome cache when the user swaps the portrait. Set by
    /// main.swift after `FramePump` is constructed.
    public weak var framePump: FramePump?
    private var stateSink: AnyCancellable?
    #if canImport(AppKit)
    /// Strong reference: the window is `isReleasedWhenClosed = false`
    /// so we own its lifetime. Reusing the same instance also
    /// preserves the user's audition state across hide/show.
    /// macOS-only — iPad/iOS use SwiftUI sheets driven by @Published bools.
    private var voicePickerWindow: VoicePickerWindow?
    private var promptEditorWindow: PromptEditorWindow?
    private var agentPickerWindow: AgentPickerWindow?
    #else
    /// iOS/iPadOS sheet-presentation flags. Toggled by the show*Picker
    /// methods; AvatarRootView reads them via .sheet(isPresented:).
    @Published public var voicePickerPresented: Bool = false
    @Published public var promptEditorPresented: Bool = false
    @Published public var agentPickerPresented: Bool = false
    @Published public var portraitPickerPresented: Bool = false
    #endif

    public init(chat: VoiceChat) {
        self.chat = chat
    }

    /// Cloud-mode init. No `VoiceChat` — the OpenAI Realtime client
    /// is the conversation engine. Right-click persona menu, drag-
    /// drop portrait swap, and live voice/prompt edits all no-op
    /// because they only make sense for the local pipeline.
    public init() {
        self.chat = nil
    }

    /// Called after `chat.start()` returns, when the orchestrator
    /// exists and is ready to be observed.
    public func bindToOrchestrator() {
        guard let orchestrator = chat?.orchestrator else { return }
        // Mirror the orchestrator's @Published state into ours.
        // Direct re-publishing is needed because the orchestrator
        // is in bitHumanKit and AvatarCoordinator is in BithumanCLI;
        // SwiftUI's $-binding doesn't cross modules cleanly.
        stateSink = orchestrator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                self?.orchestratorState = newState
            }
    }

    /// Called by FramePump on first frame render so the loading
    /// particle field can fade out.
    func markEngineReady() {
        if !isReady {
            withAnimation(.easeOut(duration: 0.3)) {
                isReady = true
            }
        }
    }

    /// Called by FramePump after every idle-cache absorb so the
    /// splash bar can advance. `count` is the current frame count
    /// in the palindrome cache; `total` is `IdleFrameCache.targetCount`.
    func updateIdlePrewarm(count: Int, total: Int) {
        let p = total > 0 ? min(1, Double(count) / Double(total)) : 1
        idlePrewarmProgress = p
        if !idlePrewarmReady && count >= total {
            withAnimation(.easeOut(duration: 0.4)) {
                idlePrewarmReady = true
            }
            // Re-enable speech audio. Initial boot leaves
            // muteAgentDuringPrewarm at its default (false), so this
            // is a no-op on the first fill; on a swap it lifts the
            // gate the FramePump producer is checking.
            muteAgentDuringPrewarm = false
        }
    }

    /// Roll prewarm state back to "filling" so the splash returns
    /// after a portrait/agent swap. Called from FramePump's
    /// `resetIdleCache` since both the cache and the UI gate move
    /// in lockstep. Also raises the audio mute gate — the previous
    /// agent's voice stops mid-sentence; the new agent stays silent
    /// until its cache is ready.
    func resetIdlePrewarm() {
        idlePrewarmProgress = 0
        idlePrewarmReady = false
        muteAgentDuringPrewarm = true
    }

    /// Drag-dropped or picker-selected portrait. Runs the engine's
    /// VAE encode (~5 s) on a Task so the UI can show a crafting
    /// overlay, then falls back to idle on completion. Voice and
    /// prompt are NOT touched — the user can swap those separately
    /// via the voice gallery / prompt editor or pick an `Agent`
    /// (which bundles all three).
    public func swapPortrait(url: URL) {
        guard case .idle = swapState else { return }
        swapState = .encoding(label: "encoding face…")
        currentAgentCode = nil
        prewarmPortraitURL = url
        // Order matters here:
        //   1. swapActivity true → producer's NEXT iteration skips
        //      idle DiT.
        //   2. resetIdleCache → bumps the cache epoch so any
        //      already-in-flight `generateIdleChunk` returning
        //      OLD-identity frames can't poison the new cache.
        chat?.swapActivity.set(true)
        framePump?.resetIdleCache()
        Task { [weak self] in
            guard let self else { return }
            defer { self.chat?.swapActivity.set(false) }
            do {
                _ = try await chat!.swapAvatarPortrait(url: url)
            } catch {
                FileHandle.standardError.write(Data(
                    "error: portrait swap failed: \(error.localizedDescription)\n".utf8
                ))
            }
            self.swapState = .idle
        }
    }

    /// Apply a bundled `Agent`: hot-swap the avatar portrait, the
    /// Kokoro voice preset, and the LLM system prompt all at once.
    /// Picture, voice, and personality stay coherent — no manual
    /// matching for the user.
    func applyAgent(_ agent: Agent) {
        guard case .idle = swapState else { return }
        guard let url = AgentCatalog.thumbnailURL(for: agent) else {
            FileHandle.standardError.write(Data(
                "error: agent \(agent.code) thumbnail missing from bundle\n".utf8
            ))
            return
        }
        swapState = .encoding(label: "becoming \(agent.name)…")
        // Voice + prompt are instant; only the face encode is slow.
        // Use the underlying chat directly so we don't bounce
        // through `setVoicePreset`/`setSystemPrompt`, which would
        // null out `currentAgentCode` mid-apply.
        currentVoicePreset = agent.voicePreset
        currentSystemPrompt = agent.systemPrompt
        currentAgentCode = agent.code
        prewarmPortraitURL = url
        // Block idle DiT and incoming turns first, then bump the
        // cache epoch — same ordering rationale as
        // `swapPortrait(url:)`. With activity gated, any in-flight
        // `generateIdleChunk` call returning OLD frames will fail
        // the absorb's epoch check and leave the new cache empty
        // for the producer to refill from this agent's identity.
        chat?.swapActivity.set(true)
        framePump?.resetIdleCache()
        Task { [weak self] in
            guard let self else { return }
            defer { self.chat?.swapActivity.set(false) }
            await self.chat?.setVoicePreset(agent.voicePreset)
            await self.chat?.setSystemPrompt(agent.systemPrompt)
            do {
                _ = try await chat!.swapAvatarPortrait(url: url)
            } catch {
                FileHandle.standardError.write(Data(
                    "error: agent face swap failed: \(error.localizedDescription)\n".utf8
                ))
            }
            self.swapState = .idle
        }
    }

    /// Hot-swap the TTS voice preset (Kokoro). Effective on the
    /// next utterance. Clears `currentAgentCode` since the user is
    /// stepping off the bundled template.
    func setVoicePreset(_ preset: String) {
        currentVoicePreset = preset
        currentAgentCode = nil
        Task { await chat?.setVoicePreset(preset) }
    }

    /// Audition `preset` once without committing. Cancels any prior
    /// preview so back-to-back gallery clicks stay clean.
    func previewVoice(_ preset: String) {
        Task { await chat?.previewVoice(preset) }
    }

    /// Open the voice gallery. macOS pops a floating NSWindow;
    /// iPad/iOS toggle a SwiftUI sheet flag (consumed in
    /// AvatarRootView's `.sheet(isPresented:)`).
    public func showVoicePicker() {
        #if canImport(AppKit)
        if let win = voicePickerWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = VoicePickerWindow(coordinator: self)
        voicePickerWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #else
        voicePickerPresented = true
        #endif
    }

    /// Open the system-prompt editor. macOS pops a floating NSWindow;
    /// iPad/iOS toggle a SwiftUI sheet flag.
    public func showPromptEditor() {
        #if canImport(AppKit)
        if let win = promptEditorWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = PromptEditorWindow(coordinator: self)
        promptEditorWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #else
        promptEditorPresented = true
        #endif
    }

    /// Open the bundled-agents picker. macOS pops a floating NSWindow;
    /// iPad/iOS toggle a SwiftUI sheet flag.
    public func showAgentPicker() {
        #if canImport(AppKit)
        if let win = agentPickerWindow {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = AgentPickerWindow(coordinator: self)
        agentPickerWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #else
        agentPickerPresented = true
        #endif
    }

    /// Last system prompt the user typed, surfaced back to the
    /// editor on next open. Initial value is the chat's current
    /// prompt at construction (the launch-time `--prompt` value or
    /// the bundled default).
    @Published public var currentSystemPrompt: String = ""

    /// Hot-swap the LLM system prompt. Effective on the next user
    /// turn. The chat's underlying ChatSession is rebuilt with the
    /// new instructions. Clears `currentAgentCode` since the user is
    /// stepping off the bundled template.
    func setSystemPrompt(_ prompt: String) {
        currentSystemPrompt = prompt
        currentAgentCode = nil
        Task { await chat?.setSystemPrompt(prompt) }
    }

    /// Pick a portrait from disk. macOS uses NSOpenPanel; iPad/iOS
    /// trigger a `.fileImporter` modifier in AvatarRootView via the
    /// `portraitPickerPresented` flag.
    public func showPortraitPicker() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Choose a portrait"
        panel.allowedContentTypes = [.image, .jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            swapPortrait(url: url)
        }
        #else
        portraitPickerPresented = true
        #endif
    }
}
