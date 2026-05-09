// BootSplashView — single continuous animation shown while the
// avatar engine boots (cached weights → load → first frame). Replaces
// the older LoadingParticleField + wordmark stack which read as
// cluttered against the iPad widget window. One element: a slowly
// rotating coral aurora ring with the bitHuman glyph at its center,
// driven by `TimelineView(.animation)` so the motion never pauses.

import ImageIO
import SwiftUI

public struct BootSplashView: View {
    /// Optional progress (0.0–1.0). When provided the ring fills
    /// clockwise to indicate the actual download fraction; nil means
    /// the ring rotates indefinitely as a generic "loading" cue.
    private let progress: Double?
    /// Big percentage shown under the glyph during download. Nil for
    /// non-progressable phases (verifying / warming).
    private let percentText: String?
    /// Small line below the percentage — typically an ETA like
    /// "~3 min remaining" or a download speed.
    private let detailText: String?
    /// Uppercase tracked label at the very bottom (DOWNLOADING /
    /// VERIFYING / WARMING).
    private let label: String?
    /// File URL of the agent's portrait JPG. Shown inside the ring
    /// so the user can see who they're about to chat with while the
    /// avatar engine is still warming up. Falls back to the bitHuman
    /// glyph if nil.
    private let portraitURL: URL?

    public init(
        progress: Double? = nil,
        percentText: String? = nil,
        detailText: String? = nil,
        label: String? = nil,
        portraitURL: URL? = nil
    ) {
        self.progress = progress
        self.percentText = percentText
        self.detailText = detailText
        self.label = label
        self.portraitURL = portraitURL
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                ZStack {
                    aurora(t: t, side: side)
                    rotatingRing(t: t, side: side)
                    glyph(side: side)
                    bottomStack(side: side)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// Center: the agent's portrait clipped into a circle so the user
    /// sees who they're about to talk to. Falls back to the bitHuman
    /// glyph when no portrait URL is supplied.
    @ViewBuilder
    private func glyph(side: CGFloat) -> some View {
        if let portraitURL,
           let cgImage = loadCGImage(at: portraitURL) {
            Image(decorative: cgImage, scale: 1.0, orientation: .up)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side * 0.42, height: side * 0.42)
                .clipShape(Circle())
                .shadow(color: BrandColors.coral.opacity(0.5), radius: side * 0.05, y: side * 0.01)
        } else {
            Image("AppIcon", bundle: .module)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: side * 0.26, height: side * 0.26)
                .clipShape(RoundedRectangle(cornerRadius: side * 0.05, style: .continuous))
                .shadow(color: BrandColors.coral.opacity(0.4), radius: side * 0.05, y: side * 0.01)
        }
    }

    private func loadCGImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Bottom stack: percentage + detail + uppercase label, all
    /// stacked at the bottom of the window. Keeps the ring/glyph
    /// area uncluttered.
    @ViewBuilder
    private func bottomStack(side: CGFloat) -> some View {
        VStack {
            Spacer()
            VStack(spacing: side * 0.012) {
                if let percentText {
                    Text(percentText)
                        .font(.system(size: side * 0.10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: percentText)
                }
                if let detailText {
                    Text(detailText)
                        .font(.system(size: side * 0.035, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.70))
                        .animation(.easeOut(duration: 0.25), value: detailText)
                }
                if let label {
                    Text(label)
                        .font(.system(size: side * 0.030, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .tracking(1.2)
                        .textCase(.uppercase)
                }
            }
            .padding(.bottom, side * 0.08)
        }
    }

    // MARK: - Aurora bloom (slow, soft)

    private func aurora(t: Double, side: CGFloat) -> some View {
        let phase = sin(2.0 * .pi * t / 4.5)
        let scale = 1.0 + 0.05 * phase
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        BrandColors.coral.opacity(0.55),
                        BrandColors.coral.opacity(0.18),
                        .clear,
                    ],
                    center: .center,
                    startRadius: side * 0.05,
                    endRadius: side * 0.55
                )
            )
            .scaleEffect(scale)
            .blur(radius: side * 0.04)
            .frame(width: side, height: side)
    }

    // MARK: - Rotating progress ring

    private func rotatingRing(t: Double, side: CGFloat) -> some View {
        // 6 s rotation → reads as motion without distracting.
        let rotation = (t / 6.0).truncatingRemainder(dividingBy: 1.0) * 360
        let stroke = max(2.5, side * 0.012)
        // Ring trim length: if `progress` is provided, follow it
        // monotonically; otherwise cycle a 30%-arc indicator.
        let trim: CGFloat = {
            if let p = progress { return CGFloat(max(0.04, min(p, 1.0))) }
            return 0.30
        }()
        return Circle()
            .trim(from: 0, to: trim)
            .stroke(
                AngularGradient(
                    colors: [
                        BrandColors.coral.opacity(0.95),
                        BrandColors.coral.opacity(0.50),
                        BrandColors.coral.opacity(0.10),
                        BrandColors.coral.opacity(0.95),
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round)
            )
            .frame(width: side * 0.62, height: side * 0.62)
            .rotationEffect(.degrees(rotation))
    }

}
