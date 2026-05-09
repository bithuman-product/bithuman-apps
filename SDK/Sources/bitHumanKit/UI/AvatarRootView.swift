#if canImport(AppKit)
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI tree the window's NSHostingView renders. Adds context
/// menu, drag-drop overlay, and a crafting spinner over the AppKit
/// `AvatarRendererView`.
struct AvatarRootView: View {
    let rendererView: AvatarRendererView
    @ObservedObject var coordinator: AvatarCoordinator
    @State private var dropTargeted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            avatarZone
            StateLabel(
                state: coordinator.orchestratorState,
                visible: coordinator.idlePrewarmReady && !coordinator.isSwapping
            )
            .frame(width: AvatarWindow.windowSide, height: AvatarWindow.labelZone)
        }
        .frame(
            width: AvatarWindow.windowSide,
            height: AvatarWindow.windowHeight
        )
        // The whole window is draggable. The right-click menu only
        // applies in local mode where `coordinator.chat` is non-nil
        // — its actions (swap portrait, audition voice, edit prompt)
        // mutate VoiceChat state, which doesn't exist in cloud mode.
        // Hiding the menu in cloud mode prevents users from
        // discovering features that silently no-op.
        .modifier(MenuIfChatPresent(coordinator: coordinator) {
            avatarContextMenu
        })
    }

    private var avatarZone: some View {
        ZStack {
            // Loading particle field — held until the idle
            // palindrome cache has filled (~10 s past first
            // frame), so the user sees a real progress bar rather
            // than the avatar going live before idle motion is
            // buffered.
            if !coordinator.idlePrewarmReady {
                LoadingParticleField(
                    size: AvatarWindow.avatarSide,
                    caption: prewarmCaption,
                    progress: coordinator.isReady ? coordinator.idlePrewarmProgress : nil,
                    portraitURL: coordinator.prewarmPortraitURL
                )
                .transition(.opacity)
            }

            AvatarRendererRepresentable(view: rendererView)
                .frame(width: AvatarWindow.avatarSide, height: AvatarWindow.avatarSide)
                .clipShape(Circle())
                .opacity(coordinator.idlePrewarmReady ? 1 : 0)

            // State ring — sits just outside the avatar circle and
            // takes on the per-phase accent color. Replaces the
            // in-circle StatePill from Phase 2b.
            StateRing(
                state: coordinator.orchestratorState,
                visible: coordinator.idlePrewarmReady,
                side: AvatarWindow.ringSide
            )

            if dropTargeted {
                DropHintOverlay()
            }

            if case .encoding(let label) = coordinator.swapState {
                CraftingSpinner(label: label)
            }
        }
        .frame(width: AvatarWindow.windowSide, height: AvatarWindow.windowSide)
        .contentShape(Circle().inset(by: 20))
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// Splash caption — switches from the boot phrasing to a
    /// "warming up — N%" once the engine has produced its first
    /// frame and the idle cache is actively filling.
    private var prewarmCaption: String {
        if !coordinator.isReady { return "warming models…" }
        let pct = Int(coordinator.idlePrewarmProgress * 100)
        return "warming up — \(pct)%"
    }

    @ViewBuilder
    private var avatarContextMenu: some View {
        Button("Choose agent…") { coordinator.showAgentPicker() }
        Divider()
        Section("Customize") {
            Button("Change image…") { coordinator.showPortraitPicker() }
            Button("Change voice…") { coordinator.showVoicePicker() }
            Button("Change prompt…") { coordinator.showPromptEditor() }
        }
        Divider()
        Button("Quit bitHuman") { NSApp.terminate(nil) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // .fileURL is the canonical type for "a file dragged from
        // Finder". Older / cross-platform drops can carry just the
        // image bits; we fall through to .image in that case.
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in coordinator.swapPortrait(url: url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bithuman-cli-drop-\(UUID().uuidString).jpg")
                try? data.write(to: tmp)
                Task { @MainActor in coordinator.swapPortrait(url: tmp) }
            }
            return true
        }
        return false
    }
}

/// Tiny `NSViewRepresentable` adapter — embeds the AppKit
/// AvatarRendererView verbatim. We never let SwiftUI re-create it
/// (the CALayer's `contents` updates 25× / s and a remount would
/// drop frames).
struct AvatarRendererRepresentable: NSViewRepresentable {
    let view: AvatarRendererView
    func makeNSView(context: Context) -> AvatarRendererView { view }
    func updateNSView(_ nsView: AvatarRendererView, context: Context) {}
}

/// Visual feedback when a file is being dragged over the window.
/// Halo's pattern: dim the avatar + a friendly "drop to change"
/// label centred over the circle.
struct DropHintOverlay: View {
    var body: some View {
        ZStack {
            // Darken the avatar so the label reads cleanly.
            Color.black.opacity(0.45)
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white)
                Text("drop to change")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .frame(width: AvatarWindow.avatarSide, height: AvatarWindow.avatarSide)
        .clipShape(Circle())
        .transition(.opacity)
    }
}

/// Counter-rotating dual-arc spinner with a one-line label,
/// shown over the avatar while the engine VAE-encodes a new face.
/// Lifted from Halo's `AvatarView.CraftingSpinner` (~50 lines).
struct CraftingSpinner: View {
    let label: String
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black.opacity(0.55)
                    .frame(width: AvatarWindow.avatarSide, height: AvatarWindow.avatarSide)
                    .clipShape(Circle())
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [.white.opacity(0.9), .white.opacity(0.1)]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(t * 140))
                        Circle()
                            .trim(from: 0, to: 0.45)
                            .stroke(.white.opacity(0.65), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-t * 210))
                    }
                    .frame(width: 56, height: 56)
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: AvatarWindow.avatarSide, height: AvatarWindow.avatarSide)
            .clipShape(Circle())
        }
        .transition(.opacity)
    }
}

/// View modifier that attaches a `.contextMenu` only when the
/// coordinator has a backing `VoiceChat` (local mode). Cloud
/// avatar mode passes a chatless coordinator; its menu actions
/// are no-ops there, so we hide the menu entirely.
private struct MenuIfChatPresent<Menu: View>: ViewModifier {
    @ObservedObject var coordinator: AvatarCoordinator
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if coordinator.chat != nil {
            content.contextMenu { menu() }
        } else {
            content
        }
    }
}
#endif
