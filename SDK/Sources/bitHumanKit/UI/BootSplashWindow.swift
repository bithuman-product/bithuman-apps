#if canImport(AppKit)
import AppKit
import Combine
import SwiftUI

/// Small floating splash window shown during the cold-start window —
/// from process launch through the moment the ``AvatarWindow`` is up
/// and producing frames. Bound to a ``BootProgress`` so the same
/// caption + bar a voice-mode user sees in stderr is mirrored in a
/// SwiftUI surface for video-mode users, who would otherwise stare
/// at a blank screen for 30+ s on first run.
///
/// Sizing matches ``AvatarWindow``'s circular layout (235 × 290) so
/// the splash sits in roughly the spot the avatar will replace it,
/// minimising the visual jump when it dismisses. Borderless,
/// floating, draggable by background — same chrome the avatar
/// window adopts. Uses the existing ``BootSplashView`` (the same
/// rotating coral-ring layout the iPad app shows during boot) so
/// macOS and iPad stay visually unified.
@MainActor
public final class BootSplashWindow: NSWindow {

    private let progress: BootProgress
    private let portraitURL: URL?

    public init(progress: BootProgress, portraitURL: URL? = nil) {
        self.progress = progress
        self.portraitURL = portraitURL
        let side = AvatarWindow.windowSide
        let height = AvatarWindow.windowHeight
        let rect = NSRect(x: 0, y: 0, width: side, height: height)

        super.init(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.title = "bitHuman"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.center()

        let host = NSHostingView(rootView: BootSplashHost(progress: progress, portraitURL: portraitURL))
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        self.contentView = host
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// SwiftUI host that observes ``BootProgress`` and renders a compact
/// splash with the descriptive caption front-and-centre — so even
/// during opaque phases (audio graph init, auth, expression load)
/// where there's no percentage, the user always reads in plain
/// English what's currently happening.
///
/// Layout (top → bottom):
///   - Continuously spinning ring (always present so the user knows
///     the process is alive even between phases)
///   - Determinate progress arc layered on top of the ring when the
///     phase exposes a 0..1 fraction
///   - Big percentage text inside the ring (download / LLM / TTS /
///     prewarm only)
///   - Caption ("loading expression engine…") below the ring —
///     biggest single piece of feedback
///   - Detail line (rate + ETA for downloads) below the caption
///   - Step indicator: "step 4 of 8" so the user reads progress
///     even during opaque phases
private struct BootSplashHost: View {
    @ObservedObject var progress: BootProgress
    let portraitURL: URL?
    /// Wall-clock anchor for the current phase. Reset on every
    /// phase transition so opaque phases (engine load, auth) can
    /// surface "n.n s" elapsed and the user has visible motion
    /// even when there's no fraction to render.
    @State private var phaseStart: Date = Date()
    @State private var phaseTag: String = ""

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5)) { context in
            VStack(spacing: 14) {
                ringStack(elapsed: context.date.timeIntervalSince(phaseStart))
                    .frame(width: 120, height: 120)

                VStack(spacing: 4) {
                    Text(captionWithEscalation(elapsed: context.date.timeIntervalSince(phaseStart)))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: AvatarWindow.windowSide - 24)

                    Text(secondaryLine(now: context.date))
                        .font(.system(size: 10, weight: .regular).monospacedDigit())
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)

                    Text(stepIndicator)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .tracking(1.2)
                        .padding(.top, 2)
                }
            }
            .padding(20)
            .frame(width: AvatarWindow.windowSide, height: AvatarWindow.windowHeight)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(white: 0.08).opacity(0.95))
            )
            .onChange(of: phaseTagFor(progress.phase)) { _, newTag in
                phaseTag = newTag
                phaseStart = Date()
            }
        }
    }

    /// Caption that escalates with elapsed time inside opaque slow
    /// phases — specifically `.loadingExpressionEngine`, where first-
    /// run ANE shader compilation can take 60–120 s and the user
    /// would otherwise believe the process is stuck. Fast phases
    /// just return ``BootProgress/caption``.
    ///
    /// When ``BootProgress/engineFirstRun`` is true (we just
    /// downloaded the engine in the prior phase, so ANE bundle
    /// cache is empty), the "compiling ANE shaders" message fires
    /// immediately rather than after 15 s — the user knows up
    /// front what's coming.
    private func captionWithEscalation(elapsed: TimeInterval) -> String {
        switch progress.phase {
        case .loadingExpressionEngine:
            if progress.engineFirstRun || elapsed > 15 {
                if elapsed > 90 {
                    return "still compiling ANE shaders…\nalmost there — hang tight"
                }
                return "compiling ANE shaders for the engine\n(first-run only — can take 60–120 s)"
            }
            return progress.caption
        default:
            return progress.caption
        }
    }

    /// What we render in the line below the caption. Priority:
    ///   1. Download rate/ETA detail (when `BootProgress.detail`
    ///      is non-nil — only fires for `.downloadingEngine`).
    ///   2. Elapsed seconds + a "typically ~Xs" expectation so
    ///      opaque phases (audio graph, auth, engine load) read
    ///      as progressing rather than frozen — and the user has
    ///      a reference point if they're a few seconds past the
    ///      typical duration ("11.4 s · usually ~10 s").
    private func secondaryLine(now: Date) -> String {
        if let detail = progress.detail { return detail }
        let elapsed = now.timeIntervalSince(phaseStart)
        if elapsed < 0.1 { return " " }   // hold a non-empty line so the layout doesn't jump
        let elapsedStr = String(format: "%.1f s", elapsed)
        if let typical = typicalDurationSeconds(progress.phase) {
            return "\(elapsedStr) · usually ~\(typical) s"
        }
        return elapsedStr
    }

    /// Conservative empirical "this typically completes within
    /// ~N s on Apple Silicon" hints for the opaque phases. Used
    /// purely for user expectation-setting — no behaviour
    /// branches off these numbers.
    ///
    /// Note: `.loadingExpressionEngine` is a tale of two costs.
    /// On a steady-state run with a warm ANE bundle cache it's
    /// 5–10 s. On the FIRST load of a freshly-downloaded engine
    /// it's 60–120 s while Apple's H17G ANE compiler emits new
    /// `.e5` bundles into `~/Library/Caches/flashhead-cli/`.
    /// We don't know which kind of run this is from inside the
    /// splash, so the hint stays at 10 s and `captionWithEscalation`
    /// switches to the "compiling ANE shaders" message after 15 s
    /// of elapsed time so the user learns it's first-run cost
    /// without us being misleading on warm runs.
    private func typicalDurationSeconds(_ phase: BootProgress.Phase) -> Int? {
        switch phase {
        case .openingAudioGraph:        return 1
        case .authenticating:           return 1
        case .loadingExpressionEngine:
            // First run hits the ANE compile cold-path (60-120 s);
            // warm runs ~10 s. Pick the right anchor so the
            // "X.Xs · usually ~Ns" label doesn't read as wrong.
            return progress.engineFirstRun ? 90 : 10
        case .verifyingEngine:          return 6
        case .loadingSpeechModel:       return 2
        default:                         return nil
        }
    }

    /// Stable per-phase tag for `onChange` — comparing the enum
    /// payload directly would re-fire on every byte tick of a
    /// download, defeating the elapsed-time anchor reset.
    private func phaseTagFor(_ phase: BootProgress.Phase) -> String {
        switch phase {
        case .idle:                    return "idle"
        case .downloadingEngine:       return "downloadingEngine"
        case .verifyingEngine:         return "verifyingEngine"
        case .loadingSpeechModel:      return "loadingSpeechModel"
        case .loadingLLM:              return "loadingLLM"
        case .openingAudioGraph:       return "openingAudioGraph"
        case .loadingTTS:              return "loadingTTS"
        case .authenticating:          return "authenticating"
        case .loadingExpressionEngine: return "loadingExpressionEngine"
        case .loadingEssenceRuntime:   return "loadingEssenceRuntime"
        case .connectingRealtime:      return "connectingRealtime"
        case .prewarmingIdle:          return "prewarmingIdle"
        case .ready:                   return "ready"
        }
    }

    @ViewBuilder
    private func ringStack(elapsed: TimeInterval) -> some View {
        ZStack {
            // Background track — always visible.
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 5)

            // Ambient spinner — runs continuously so the splash
            // always reads as alive even during opaque phases.
            SpinningArc()

            // Determinate fill when the phase exposes a fraction.
            // Solid coral instead of an AngularGradient — the conic
            // shader is CPU-rasterised by CoreGraphics and was
            // burning ~13% of main-thread time per `sample`. A flat
            // colour renders as a single CALayer mask and costs
            // essentially nothing.
            if let p = progress.progress {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, p)))
                    .stroke(
                        Color(red: 1.0, green: 0.45, blue: 0.35),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: p)
            }

            // Percentage in the centre when we have one; "Xs"
            // elapsed for opaque slow phases (so the centre always
            // shows MOTION); the brand glyph for fast opaque phases.
            if let p = progress.progress {
                Text("\(Int((p * 100).rounded()))%")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
            } else if isSlowOpaquePhase, elapsed >= 1 {
                Text("\(Int(elapsed))s")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
            } else {
                Text("bH")
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    /// True for phases that can take >5 s and have no granular
    /// progress hook — we centre the elapsed-seconds counter
    /// inside the ring so the splash always shows visible motion.
    private var isSlowOpaquePhase: Bool {
        switch progress.phase {
        case .loadingExpressionEngine, .verifyingEngine, .loadingSpeechModel:
            return true
        default:
            return false
        }
    }

    /// "step N of 8" — gives the user a sense of forward motion
    /// even in opaque phases. Bumps every time `phase` advances.
    private var stepIndicator: String {
        let total = 8
        let n: Int
        switch progress.phase {
        case .idle:                    n = 0
        case .downloadingEngine:       n = 1
        case .verifyingEngine:         n = 2
        case .loadingSpeechModel:      n = 2
        case .loadingLLM:              n = 3
        case .openingAudioGraph:       n = 4
        case .loadingTTS:              n = 5
        case .authenticating:          n = 6
        case .loadingExpressionEngine: n = 7
        case .loadingEssenceRuntime:   n = 7
        case .connectingRealtime:      n = 6
        case .prewarmingIdle:          n = 8
        case .ready:                   n = 8
        }
        return "STEP \(n) OF \(total)"
    }
}

/// Continuously rotating arc layered behind the determinate fill,
/// so the splash always reads as "alive" even during opaque phases
/// that have no percentage.
private struct SpinningArc: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(
                Color.white.opacity(0.55),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
#endif
