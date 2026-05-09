#if canImport(AppKit)
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Right-click context menu handler for the Essence
/// (`AvatarWindow.clipMode = .fill`) avatar window. Hosts the actions
/// the user can take without leaving the chat — swap the `.imx`,
/// hot-swap the Qwen3 voice, edit the system prompt, quit.
///
/// Why a dedicated NSObject: NSMenu's target/action plumbing requires
/// an `@objc`-callable receiver. The Essence avatar window is a
/// borderless NSWindow with an AppKit content view (the renderer view
/// hosts a CALayer that updates 25× / s — wrapping it in SwiftUI just
/// for a context menu would add layout churn). So we keep the menu
/// pure-AppKit and route every selection through a small Sendable
/// handler that translates back into ``VoiceChat`` and
/// ``AvatarCoordinator`` calls.
@MainActor
public final class EssenceMenuHandler: NSObject {

    /// Strong refs to the dependencies the menu actions need. Held
    /// for the life of the avatar window — the AppDelegate retains
    /// the handler alongside the chat session, mirroring the
    /// Expression path's coordinator.
    private let chat: VoiceChat
    private let coordinator: AvatarCoordinator
    private let currentModelPath: URL
    /// Re-launch the process with `--model <newPath>` when the user
    /// picks a different `.imx`. Hot-swap (tearing down the
    /// `EssenceRuntime` and rebuilding in place) is a v2 feature;
    /// for now we exec a fresh CLI invocation so the flow is
    /// trivially correct.
    private let relaunchWithModel: (URL) -> Void

    public init(
        chat: VoiceChat,
        coordinator: AvatarCoordinator,
        currentModelPath: URL,
        relaunchWithModel: @escaping (URL) -> Void
    ) {
        self.chat = chat
        self.coordinator = coordinator
        self.currentModelPath = currentModelPath
        self.relaunchWithModel = relaunchWithModel
        super.init()
    }

    // MARK: - Build

    /// Compose the right-click menu. Items wired to `@objc` selectors
    /// on `self`; voice presets are populated as a submenu so the
    /// user can pick a Qwen3 preset without a separate window.
    public func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let modelItem = NSMenuItem(
            title: "Choose model…",
            action: #selector(chooseModel(_:)),
            keyEquivalent: ""
        )
        modelItem.target = self
        menu.addItem(modelItem)

        menu.addItem(.separator())

        // Voice submenu — Qwen3 presets + "Clone from file…".
        let voiceItem = NSMenuItem(title: "Change voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu(title: "Change voice")
        for preset in VoiceChat.availableVoiceModePresets {
            let item = NSMenuItem(
                title: preset,
                action: #selector(pickPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset
            voiceMenu.addItem(item)
        }
        voiceMenu.addItem(.separator())
        let cloneItem = NSMenuItem(
            title: "Clone from audio file…",
            action: #selector(cloneVoice(_:)),
            keyEquivalent: ""
        )
        cloneItem.target = self
        voiceMenu.addItem(cloneItem)
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        let promptItem = NSMenuItem(
            title: "Change prompt…",
            action: #selector(changePrompt(_:)),
            keyEquivalent: ""
        )
        promptItem.target = self
        menu.addItem(promptItem)

        menu.addItem(.separator())

        // No "Choose agent…" item: the model picker is the agent
        // picker. Users download `.imx` files themselves and the
        // model picker walks the filesystem to load them — there's
        // no curated bundle the way Expression has its built-in
        // agent gallery, and there's no reason for two surfaces
        // that do the same thing.

        let quitItem = NSMenuItem(
            title: "Quit bitHuman",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func chooseModel(_ sender: Any?) {
        // Activate ourselves so the open panel ends up frontmost.
        // Without this, on a borderless `level = .floating` window
        // (the Essence avatar) the panel can appear *behind* the
        // avatar — looks like nothing happened to the user even
        // though the panel actually opened.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Choose Essence avatar model"
        panel.message = "Pick a `.imx` Essence avatar model file."
        panel.prompt = "Open"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // .imx is custom; accept any non-package file but seed the
        // panel in the directory of the currently-loaded model so
        // Quick Look filters by sibling .imx names alongside.
        panel.allowedContentTypes = [.data]
        panel.directoryURL = currentModelPath.deletingLastPathComponent()
        panel.level = .modalPanel  // float above the borderless avatar window
        // `runModal()` returns synchronously with the user's choice
        // — more robust than `begin(completionHandler:)` from a
        // context-menu action, where the panel's window-server
        // ordering can land it behind the avatar's `.floating`
        // level and the user never sees the panel at all.
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }
        do {
            let modelType = try Bithuman.peekModelType(modelPath: url)
            guard modelType == "essence" else {
                alertWrongModelType(found: modelType, url: url)
                return
            }
        } catch {
            alertGeneric(
                title: "Couldn't read this model",
                message: "\(url.lastPathComponent): \(error)"
            )
            return
        }
        relaunchWithModel(url)
    }

    @objc private func pickPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String else { return }
        Task { await self.chat.setVoicePreset(preset) }
        // Surface in the coordinator so a future status pill / log
        // line can show which voice is active.
        coordinator.currentVoicePreset = preset
    }

    @objc private func cloneVoice(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Clone voice from audio file"
        panel.message = "Pick a 6–20 s mono audio clip (WAV / AIFF / M4A)."
        panel.prompt = "Clone"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .wav, .aiff, .mp3, .mpeg4Audio]
        panel.level = .modalPanel
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else { return }
        runVoiceClone(audioURL: url)
    }

    private func runVoiceClone(audioURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            // ASR-transcribe the reference audio so prosody alignment
            // works. Reusing the CLI's transcript-resolver behaviour
            // would tightly couple us to BithumanCLI; instead we hand
            // the audio straight to Qwen3 with a sensible default
            // transcript and let the model derive prosody from the
            // audio embedding alone. (Empirically: a generic
            // transcript yields voices that sound right with a
            // subtle reduction in cadence faithfulness — acceptable
            // for hot-swap use.)
            let transcript = "Hello there. I'm ready to help you today."
            do {
                try await self.chat.setVoiceClone(
                    audioURL: audioURL,
                    transcript: transcript
                )
                self.coordinator.currentVoicePreset = "clone:\(audioURL.lastPathComponent)"
            } catch {
                self.alertGeneric(
                    title: "Couldn't clone voice",
                    message: "\(audioURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    @objc private func changePrompt(_ sender: Any?) {
        coordinator.showPromptEditor()
    }

    // MARK: - Alerts

    private func alertWrongModelType(found: String?, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Wrong model type"
        alert.informativeText = """
            \(url.lastPathComponent) has model_type=\(found ?? "<missing>").
            The Essence path needs an Essence-flavored .imx.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func alertGeneric(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
