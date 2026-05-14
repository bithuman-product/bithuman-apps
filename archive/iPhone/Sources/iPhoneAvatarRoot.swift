//
//  iPhoneAvatarRoot.swift
//  BithumanPhone — phone-specific layout shell.
//
//  Phone layout intent (differs from iPad — see docs/phone-vs-pad.md):
//
//    1. Full-screen avatar by default. Single-pane, no sidebar,
//       no NavigationSplitView. The phone is held close and mostly
//       used hands-free or one-handed; immersive trumps multitasking.
//       Phone screens are smaller in absolute terms than iPad, so
//       the upscale-from-384px feels different — texture-of-skin
//       softness reads more like motion blur than visible pixelation.
//
//    2. A single tap on the avatar collapses it into a 120 pt floating
//       circle in the bottom-right — FaceTime PiP energy. A second
//       tap re-expands.
//
//    3. Customization opens as `.sheet(isPresented:)` modals with a
//       compact `TabView` switching between the three customization
//       surfaces (Agents / Voice / Prompt). One sheet, three tabs —
//       no stacked modals.
//

#if canImport(UIKit)
import SwiftUI
import UIKit
import bitHumanKit

// MARK: - Root shell

struct iPhoneAvatarRoot: View {
    @ObservedObject var lifecycle: BithumanPhoneLifecycle

    /// `true` → avatar fills the screen. `false` → collapsed PiP
    /// circle in the bottom-right corner.
    @State private var isExpanded: Bool = true

    /// Drives `.sheet(item:)` for the customization stack.
    @State private var customizationSheet: CustomizationTab? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let coordinator = lifecycle.coordinator {
                content(coordinator: coordinator)
            } else if let err = lifecycle.bootError {
                bootErrorView(err)
            } else {
                bootView
            }
        }
        .animation(.spring(duration: 0.35), value: isExpanded)
        .sheet(item: $customizationSheet) { tab in
            if let coordinator = lifecycle.coordinator {
                CustomizationSheet(initialTab: tab, coordinator: coordinator)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// First-launch UI. While weights are downloading or verifying,
    /// show the structured DownloadProgressView (ring + speed + ETA).
    /// After the download lands and we move into engine load, fall
    /// back to the particle field — that stretch is short and has
    /// no progress signal worth surfacing.
    @ViewBuilder
    private var bootView: some View {
        VStack(spacing: 36) {
            BithumanWordmark()
            switch lifecycle.downloadPhase {
            case .downloading, .verifyingDownloaded:
                DownloadProgressView(phase: lifecycle.downloadPhase, side: 240)
            case .verifying, .ready:
                LoadingParticleField(size: 280, caption: "warming models…")
            @unknown default:
                LoadingParticleField(size: 280, caption: "warming models…")
            }
        }
    }

    // MARK: Avatar zones

    @ViewBuilder
    private func content(coordinator: AvatarCoordinator) -> some View {
        ZStack {
            if isExpanded {
                fullscreenAvatar(coordinator: coordinator)
            } else {
                pipAvatar(coordinator: coordinator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 32)
            }

            // Top-overlay menu button — only visible while the avatar
            // is expanded. When PiP'd we surface a tap on the small
            // circle to re-expand instead.
            if isExpanded {
                VStack {
                    HStack {
                        Spacer()
                        menuButton
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                    StateLabel(
                        state: coordinator.orchestratorState,
                        visible: coordinator.idlePrewarmReady && !coordinator.isSwapping
                    )
                    .padding(.bottom, 28)
                }
            }
        }
    }

    /// Full-screen avatar. We don't reuse the macOS `AvatarRootView` —
    /// that view is sized to `AvatarWindow.avatarSide` (the macOS
    /// floating circle) and embeds context menus that don't apply on
    /// iPhone. Instead we host the library's `AvatarRendererView`
    /// directly via a UIViewRepresentable.
    @ViewBuilder
    private func fullscreenAvatar(coordinator: AvatarCoordinator) -> some View {
        ZStack {
            Group {
                if let renderer = lifecycle.rendererView {
                    PhoneAvatarRendererRepresentable(view: renderer)
                        .opacity(coordinator.idlePrewarmReady ? 1 : 0)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()

            // Idle palindrome cache hasn't filled yet — keep the
            // particle splash up with a real progress arc so the
            // user sees the agent "warming up" instead of the avatar
            // popping in cold and immediately accepting voice input.
            if lifecycle.rendererView != nil && !coordinator.idlePrewarmReady {
                LoadingParticleField(
                    size: 280,
                    caption: prewarmCaption(coordinator),
                    progress: coordinator.isReady ? coordinator.idlePrewarmProgress : nil,
                    portraitURL: coordinator.prewarmPortraitURL
                )
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isExpanded = false
        }
    }

    /// Collapsed picture-in-picture circle. ~120 pt diameter, fixed.
    /// Tap to re-expand to full-screen.
    @ViewBuilder
    private func pipAvatar(coordinator: AvatarCoordinator) -> some View {
        ZStack {
            Group {
                if let renderer = lifecycle.rendererView {
                    PhoneAvatarRendererRepresentable(view: renderer)
                        .opacity(coordinator.idlePrewarmReady ? 1 : 0)
                } else {
                    Color.black
                }
            }
            if lifecycle.rendererView != nil && !coordinator.idlePrewarmReady {
                LoadingParticleField(
                    size: 120,
                    caption: nil,
                    progress: coordinator.isReady ? coordinator.idlePrewarmProgress : nil,
                    portraitURL: coordinator.prewarmPortraitURL
                )
                .transition(.opacity)
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(.white.opacity(0.25), lineWidth: 1)
        )
        .shadow(radius: 12, y: 6)
        .onTapGesture {
            isExpanded = true
        }
    }

    /// Splash caption — switches from boot phrasing to a percentage
    /// once the engine has produced its first frame and the idle
    /// palindrome cache is actively filling.
    private func prewarmCaption(_ coordinator: AvatarCoordinator) -> String {
        if !coordinator.isReady { return "warming models…" }
        let pct = Int(coordinator.idlePrewarmProgress * 100)
        return "warming up — \(pct)%"
    }

    // MARK: Menu

    private var menuButton: some View {
        Menu {
            Button {
                customizationSheet = .agents
            } label: {
                Label("Choose agent", systemImage: "person.crop.circle")
            }
            Button {
                customizationSheet = .voice
            } label: {
                Label("Change voice", systemImage: "waveform")
            }
            Button {
                customizationSheet = .prompt
            } label: {
                Label("Edit prompt", systemImage: "text.bubble")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .shadow(radius: 6)
                .padding(8)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
    }

    // MARK: Boot error

    @ViewBuilder
    private func bootErrorView(_ err: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't start bitHuman")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(err)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Customization sheet
//
// One sheet, tabbed across the three customization surfaces. Reuses
// the library's existing public SwiftUI views verbatim.

enum CustomizationTab: String, Identifiable, CaseIterable {
    case agents
    case voice
    case prompt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: return "Agents"
        case .voice:  return "Voice"
        case .prompt: return "Prompt"
        }
    }
    var icon: String {
        switch self {
        case .agents: return "person.crop.circle"
        case .voice:  return "waveform"
        case .prompt: return "text.bubble"
        }
    }
}

struct CustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: AvatarCoordinator
    @State private var tab: CustomizationTab

    init(initialTab: CustomizationTab, coordinator: AvatarCoordinator) {
        self.coordinator = coordinator
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $tab) {
                AgentPickerView(coordinator: coordinator) { dismiss() }
                    .tabItem { Label(CustomizationTab.agents.title, systemImage: CustomizationTab.agents.icon) }
                    .tag(CustomizationTab.agents)

                VoicePickerView(coordinator: coordinator) { dismiss() }
                    .tabItem { Label(CustomizationTab.voice.title, systemImage: CustomizationTab.voice.icon) }
                    .tag(CustomizationTab.voice)

                PromptEditorView(coordinator: coordinator) { dismiss() }
                    .tabItem { Label(CustomizationTab.prompt.title, systemImage: CustomizationTab.prompt.icon) }
                    .tag(CustomizationTab.prompt)
            }
            .navigationTitle(tab.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Renderer representable

/// Phone variant of `AvatarRendererRepresentable`. Hosts the
/// pre-constructed `AvatarRendererView` from `BithumanPhoneLifecycle`;
/// the FramePump drives it via its AvatarFrameSink conformance.
/// SwiftUI never re-creates it (going through `updateUIView` at
/// 25 FPS would tear the SwiftUI render graph).
struct PhoneAvatarRendererRepresentable: UIViewRepresentable {
    let view: AvatarRendererView

    func makeUIView(context: Context) -> AvatarRendererView { view }

    func updateUIView(_ uiView: AvatarRendererView, context: Context) {}
}

#endif // canImport(UIKit)
