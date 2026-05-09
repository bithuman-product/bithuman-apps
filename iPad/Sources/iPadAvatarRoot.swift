// iPadAvatarRoot.swift — iPad-shaped recomposition of the avatar UI.
//
// Design rationale: the avatar engine outputs 384×384 frames. At 2×
// retina (iPad's pixel ratio) that's pixel-clean at ~192 pt; we scale
// up to ~280 pt for visual presence, well within the ≤1.5× upscale
// where softness stays imperceptible. Filling the iPad screen would
// scale 3-4× and visibly blur — so instead we treat the iPad like a
// "desk for the avatar": a centered companion card on a branded dark
// canvas, with the avatar at near-native size and lots of intentional
// negative space.
//
// Reuses the cross-platform SwiftUI views from `bitHumanKit/UI/`
// verbatim — `AgentPickerView`, `VoicePickerView`, `PromptEditorView`,
// `LoadingParticleField`, `StateRing`, `StateLabel`. Customization
// opens as `.sheet(presentationDetents:)` modals — the iOS analog of
// the macOS NSWindow panels.

#if canImport(UIKit)
import PhotosUI
import SwiftUI
import UIKit
import bitHumanKit

struct iPadAvatarRoot: View {
    @ObservedObject var lifecycle: BithumanPadLifecycle

    /// Sheet routing — equivalent to the macOS NSWindow panels.
    @State private var presentedSheet: PadSheet?

    enum PadSheet: Identifiable {
        case agents
        case voice
        case prompt
        case portraitPicker
        var id: Int {
            switch self {
            case .agents:          return 0
            case .voice:           return 1
            case .prompt:          return 2
            case .portraitPicker:  return 3
            }
        }
    }

    /// Floating-panel size — matches the scene delegate's
    /// `sizeRestrictions` (400×400). Stage Manager paints chrome
    /// around it; we deliberately don't draw an inner panel frame
    /// so the user sees one frame.
    private let panelSide: CGFloat = 320
    /// Avatar circle diameter. 250 pt = 500 px native at 2× retina,
    /// ~1.30× upscale from the 384 px engine output — pixel-clean.
    /// 25% smaller than the prior 330 pt sizing for a tighter widget
    /// footprint.
    private let avatarSide: CGFloat = 250
    private var ringSide: CGFloat { avatarSide + 6 }

    var body: some View {
        ZStack {
            // While PiP is active, hide our main UI completely so the
            // iPadOS desktop bleeds through (only the PiP circle
            // remains visible). The UIWindow is set to clear in
            // BithumanPadSceneDelegate so Color.clear here actually
            // shows the desktop, not a black slab.
            if lifecycle.pipIsActive {
                Color.clear
                    .ignoresSafeArea()
            } else if let coordinator = lifecycle.coordinator {
                // Wrap the avatar panel in its own ObservableObject
                // observer so changes to the coordinator's
                // `orchestratorState` (.listening → .thinking →
                // .speaking) re-render the StateLabel + StateRing.
                // Reading `coordinator.foo` at this level wouldn't
                // trigger updates because we only @ObservedObject
                // the lifecycle.
                floatingPanel {
                    AvatarPanelView(
                        coordinator: coordinator,
                        rendererView: lifecycle.rendererView,
                        avatarSide: avatarSide,
                        ringSide: ringSide,
                        menuButton: AnyView(menuButton)
                    )
                }
            } else if let err = lifecycle.bootError {
                floatingPanel { bootErrorView(err) }
            } else {
                floatingPanel { bootView }
            }

            // PiP host — keeps `AvatarPiPController.displayLayer` in
            // the live view hierarchy so the controller's
            // `isPictureInPicturePossible` can flip true. Sits at 1×1
            // / alpha 0 in the corner; the system PiP system renders
            // its own floating window from the SDL contents.
            if let pip = lifecycle.pipController {
                PiPHostRepresentable(view: pip.hostView)
                    .frame(width: 1, height: 1)
                    .position(x: 0, y: 0)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(sheet)
        }
    }

    /// Container that fills the scene window. iPadOS Stage Manager
    /// paints its own rounded-rect chrome around every floating
    /// window — we can't suppress that — so we deliberately do NOT
    /// add our own rounded-rect background here. The user sees ONE
    /// frame: Stage Manager's. Inside it: the avatar circle, menu,
    /// state label on a transparent background that lets the system
    /// chrome's color show through.
    @ViewBuilder
    private func floatingPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Fill whatever the scene window's content area is rather
        // than constraining to a fixed `panelSide`. Stage Manager
        // sometimes clamps our 300×300 size restriction to a larger
        // value (system minimum is roughly 320 pt on one axis); a
        // fixed 300×300 panel inside a 320×360 window leaves visible
        // black bars. Filling means the avatar reaches every edge
        // of the window content area regardless of clamping.
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// First-launch UI. One continuously-animating splash: aurora
    /// bloom + rotating coral ring + bitHuman glyph at center, with
    /// percentage + ETA stacked below the glyph during download.
    /// The ring reflects download progress when known, otherwise
    /// rotates as a generic "loading" cue.
    @ViewBuilder
    private var bootView: some View {
        BootSplashView(
            progress: bootProgress,
            percentText: bootPercentText,
            detailText: bootDetailText,
            label: bootLabel,
            portraitURL: lifecycle.bootPortraitURL
        )
    }

    /// Progress fraction for the ring's trim. Combines the download
    /// phase fraction with the wall-clock-based warming estimate so
    /// the ring fills continuously across both phases.
    private var bootProgress: Double? {
        switch lifecycle.downloadPhase {
        case .downloading(let f, _, _, _, _): return f
        case .verifyingDownloaded:             return 1.0
        case .verifying:                       return nil
        case .ready:                           return lifecycle.warmingProgress
        @unknown default:                      return nil
        }
    }

    /// Big percentage shown beneath the glyph during both download
    /// and warming phases.
    private var bootPercentText: String? {
        switch lifecycle.downloadPhase {
        case .downloading(let f, _, _, _, _):
            return "\(Int((f * 100).rounded()))%"
        case .ready:
            return "\(Int((lifecycle.warmingProgress * 100).rounded()))%"
        case .verifyingDownloaded, .verifying:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Detail line below the percentage — download size+ETA, or a
    /// time-based ETA estimate during warming.
    private var bootDetailText: String? {
        switch lifecycle.downloadPhase {
        case .downloading(_, let bytes, let total, let bps, let eta):
            let mbDone = Double(bytes) / 1_048_576
            let mbTotal = Double(total) / 1_048_576
            let size = String(format: "%.0f / %.0f MB", mbDone, mbTotal)
            if let eta, eta.isFinite, eta > 0 {
                return "\(size) · \(formatETA(eta))"
            }
            if bps > 0 {
                let mbps = bps / 1_048_576
                return String(format: "%@ · %.1f MB/s", size, mbps)
            }
            return size
        case .ready:
            // Detail line is intentionally agnostic of the curve's
            // wall-clock — first-run engine load varies wildly
            // (8–120 s depending on hub cache state) so a synthesised
            // ETA would lie. Show a calm, present-tense status that
            // reads honestly at any progress value.
            return "warming up the engine…"
        case .verifyingDownloaded, .verifying:
            return nil
        @unknown default:
            return nil
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 60 {
            let m = s / 60
            return m == 1 ? "~1 min remaining" : "~\(m) min remaining"
        }
        if s <= 5 { return "almost there" }
        return "~\(s) s remaining"
    }

    /// Uppercase tracked label at the bottom of the splash.
    private var bootLabel: String? {
        switch lifecycle.downloadPhase {
        case .downloading:          return nil  // percentage replaces it
        case .verifyingDownloaded:  return "verifying"
        case .verifying:            return nil
        case .ready:                return nil  // percentage replaces it
        @unknown default:           return nil
        }
    }

    // (Avatar panel layout lives in `AvatarPanelView` below — extracted
    // so it can `@ObservedObject` the coordinator and re-render when
    // its @Published properties — orchestratorState, isSwapping,
    // currentAgentCode — change.)

    /// Compact ⋯ menu — one entry per sheet. Top-right of the 512×512
    /// panel. Replaces the always-visible action bar.
    private var menuButton: some View {
        Menu {
            Button {
                presentedSheet = .agents
            } label: {
                Label("Agents", systemImage: "person.2.crop.square.stack")
            }
            Button {
                presentedSheet = .voice
            } label: {
                Label("Voice", systemImage: "waveform")
            }
            Button {
                presentedSheet = .prompt
            } label: {
                Label("Prompt", systemImage: "text.bubble")
            }
            Button {
                presentedSheet = .portraitPicker
            } label: {
                Label("Portrait", systemImage: "photo")
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.92), .black.opacity(0.45))
                .symbolRenderingMode(.palette)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: PadSheet) -> some View {
        // The lifecycle.coordinator is non-nil while these sheets are
        // presentable — they're only accessible after boot.
        if let coordinator = lifecycle.coordinator {
            switch sheet {
            case .agents:
                AgentPickerView(coordinator: coordinator) {
                    presentedSheet = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .voice:
                VoicePickerView(coordinator: coordinator) {
                    presentedSheet = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .prompt:
                PromptEditorView(coordinator: coordinator) {
                    presentedSheet = nil
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .portraitPicker:
                PortraitPickerSheet(coordinator: coordinator) {
                    presentedSheet = nil
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Boot error

    @ViewBuilder
    private func bootErrorView(_ err: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Couldn't start bitHuman")
                .font(.title3.weight(.semibold))
            Text(err)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

/// Avatar fills the entire window edge-to-edge; state label
/// overlays at the bottom-left, menu icon at the bottom-right.
/// `@ObservedObject coordinator` so the state label live-updates as
/// the orchestrator transitions through .listening / .thinking /
/// .speaking — the parent view's @ObservedObject lifecycle wouldn't
/// notice changes to the coordinator's @Published properties.
private struct AvatarPanelView: View {
    @ObservedObject var coordinator: AvatarCoordinator
    let rendererView: AvatarRendererView?
    let avatarSide: CGFloat
    let ringSide: CGFloat
    let menuButton: AnyView

    /// Caption shown inside the LoadingParticleField. Switches from
    /// the boot phrasing to a "warming up — N%" once the engine has
    /// rendered its first frame and the idle palindrome cache is
    /// actively filling — same wording as the macOS root.
    private var prewarmCaption: String {
        if !coordinator.isReady { return "warming models…" }
        let pct = Int(coordinator.idlePrewarmProgress * 100)
        return "warming up — \(pct)%"
    }

    var body: some View {
        ZStack {
            // Centred avatar circle + state ring around the edge.
            // Fixed `avatarSide` so the 384-px engine output renders
            // close to native pixel density (no upscale blur)
            // regardless of how big the iPad scene window is.
            ZStack {
                if let renderer = rendererView {
                    iPadAvatarRendererRepresentable(view: renderer)
                        .frame(width: avatarSide, height: avatarSide)
                        .clipShape(Circle())
                        .opacity(coordinator.idlePrewarmReady ? 1 : 0)
                } else {
                    BootSplashView(label: "warming")
                        .frame(width: avatarSide, height: avatarSide)
                        .clipShape(Circle())
                }
                // Idle palindrome cache hasn't filled yet — keep the
                // particle splash up with a real progress arc so the
                // user sees the agent "warming up" instead of an
                // unloaded face popping in cold.
                if rendererView != nil && !coordinator.idlePrewarmReady {
                    LoadingParticleField(
                        size: avatarSide,
                        caption: prewarmCaption,
                        progress: coordinator.isReady ? coordinator.idlePrewarmProgress : nil,
                        portraitURL: coordinator.prewarmPortraitURL
                    )
                    .frame(width: avatarSide, height: avatarSide)
                    .clipShape(Circle())
                    .transition(.opacity)
                }
                StateRing(
                    state: coordinator.orchestratorState,
                    visible: coordinator.idlePrewarmReady,
                    side: ringSide
                )
            }
            .frame(width: avatarSide + 12, height: avatarSide + 12)

            // State label overlay — bottom-left. Drops a soft
            // backdrop pill behind it so it stays legible against
            // any avatar pixels behind.
            VStack {
                Spacer()
                HStack {
                    StateLabel(
                        state: coordinator.orchestratorState,
                        visible: coordinator.idlePrewarmReady && !coordinator.isSwapping
                    )
                    .padding(.leading, 14)
                    .padding(.bottom, 14)
                    Spacer()
                }
            }

            // Menu icon overlay — bottom-right.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    menuButton
                        .padding(.bottom, 14)
                        .padding(.trailing, 14)
                }
            }

            // Drag-handle hint — small pill at the top-center so the
            // user knows where to grab the floating window. Stage
            // Manager only allows window-dragging from the top edge,
            // and that's invisible by default — this pill makes it
            // discoverable. Drawn at low opacity so it doesn't
            // distract once you know what it is.
            VStack {
                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 44, height: 5)
                    .padding(.top, 8)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                Spacer()
            }
            .allowsHitTesting(false)

            // Identity-swap overlay — visible while the engine is
            // VAE-encoding a new portrait or applying a new agent.
            // Soft frosted blur over the avatar with a centered
            // crafting label keeps the user oriented during the
            // ~5 s encode instead of feeling like the swap is broken.
            if case .encoding(let label) = coordinator.swapState {
                IdentitySwapOverlay(label: label)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.swapState)
    }
}

/// Frosted overlay shown while the avatar engine encodes a new
/// portrait or applies a new agent. Uses ultraThinMaterial over the
/// avatar so the previous frame is still faintly visible (sense of
/// continuity), with a small spinner + label centered.
private struct IdentitySwapOverlay: View {
    let label: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(BrandColors.coral)
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .tracking(0.3)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                Capsule(style: .continuous).fill(.black.opacity(0.55))
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 0.5))
            )
        }
    }
}

/// Hosts `AvatarPiPController.hostView` (a UIView containing the
/// `AVSampleBufferDisplayLayer`) inside the SwiftUI tree so the layer
/// is parented under a live UIWindow. Required for
/// `AVPictureInPictureController.isPictureInPicturePossible` to flip
/// true. The view itself is invisible (alpha 0, 1×1).
private struct PiPHostRepresentable: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Translucent dark canvas with a faint coral bloom. With the scene's
/// UIWindow set to clear/non-opaque (see `BithumanPadSceneDelegate`),
/// the .opacity here lets the iPad desktop wallpaper bleed through —
/// the floating panel reads as a soft glassy window rather than a
/// black slab covering the screen.
private struct BackdropCanvas: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            RadialGradient(
                colors: [
                    BrandColors.coral.opacity(0.15),
                    BrandColors.coral.opacity(0.04),
                    .clear,
                ],
                center: .center,
                startRadius: 60,
                endRadius: 600
            )
            .blur(radius: 40)
        }
    }
}

/// Photos-library picker for swapping the avatar's portrait. Uses
/// SwiftUI's `PhotosPicker`; on selection, copies the image bytes
/// into a temporary file (the engine's setIdentity API takes a URL,
/// not a UIImage) and calls `coordinator.swapPortrait(url:)`.
struct PortraitPickerSheet: View {
    let coordinator: AvatarCoordinator
    let onClose: () -> Void

    @State private var selection: PhotosPickerItem?
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case loading
        case applied
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("Choose a portrait")
                    .font(.system(size: 17, weight: .semibold))
                Text("Pick a photo. Best results: well-lit, front-facing.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 16)

            PhotosPicker(
                selection: $selection,
                matching: .images,
                photoLibrary: .shared()
            ) {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(BrandColors.coral)
                    Text(status == .loading ? "Crafting…" : "Open Photos")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(BrandColors.coral.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(BrandColors.coral.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        )
                )
                .padding(.horizontal, 24)
            }
            .disabled(status == .loading)

            // Status line — communicates loading / success / failure
            // without taking focus from the picker.
            statusLine
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 24)

            Spacer()

            Button("Done", action: onClose)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task { await apply(item: item) }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Encoding portrait…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .applied:
            Label("Portrait applied", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        case .failed(let msg):
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func apply(item: PhotosPickerItem) async {
        await MainActor.run { status = .loading }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                await MainActor.run { status = .failed("Unsupported image type.") }
                return
            }
            // Normalise EXIF orientation BEFORE handing the bytes to
            // the engine. JPEGs from iPhone Photos commonly carry an
            // orientation tag (e.g. portrait shots are stored as
            // landscape with `.right`); the avatar's image-preprocess
            // path doesn't honour that tag, so without normalisation
            // the avatar comes out sideways or upside-down.
            guard let uiImage = UIImage(data: data),
                  let normalized = uiImage.normalizedUpright(),
                  let jpegData = normalized.jpegData(compressionQuality: 0.92)
            else {
                await MainActor.run { status = .failed("Couldn't decode that image.") }
                return
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("bithuman-portrait", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("portrait-\(UUID().uuidString).jpg")
            try jpegData.write(to: url)
            await MainActor.run {
                coordinator.swapPortrait(url: url)
                status = .applied
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run { onClose() }
        } catch {
            await MainActor.run { status = .failed("Couldn't load that image: \(error.localizedDescription)") }
        }
    }
}

private extension UIImage {
    /// Re-render the image with a corrected `.up` orientation by
    /// drawing it into a fresh context. Without this, JPEGs from the
    /// camera roll keep their EXIF rotation tag and downstream
    /// consumers that don't honour it (the avatar's VAE preprocessor)
    /// see the raw pixels, resulting in a sideways / upside-down face.
    func normalizedUpright() -> UIImage? {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif // canImport(UIKit)
