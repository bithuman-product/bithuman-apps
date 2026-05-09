import CoreGraphics
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Animated particle field overlaid on the avatar during model load.
/// Breathing radial halo behind 48 orbiting "comets" with trails plus
/// periodic radial sparkle bursts, all tinted with the brand coral.
/// Runs at 60 FPS via `TimelineView(.animation)` + `Canvas`.
/// Deterministic per-particle parameters via index hashing — no RNG
/// state, idempotent across redraws.
public struct LoadingParticleField: View {
    let size: CGFloat
    let caption: String?
    /// Optional fill ratio in [0, 1]. When non-nil, the field
    /// renders a coral progress arc just inside its outer edge so
    /// the user reads a real "warming up — N%" instead of an
    /// indefinite spinner.
    let progress: Double?
    /// Optional static portrait shown behind the particles. Used
    /// during agent/portrait warm-up so the user can see who they
    /// are about to talk to instead of staring at an abstract
    /// halo. Rendered as a circle-clipped, slightly desaturated
    /// underlay; the comets and progress arc draw on top.
    let portraitURL: URL?

    public init(
        size: CGFloat,
        caption: String?,
        progress: Double? = nil,
        portraitURL: URL? = nil
    ) {
        self.size = size
        self.caption = caption
        self.progress = progress
        self.portraitURL = portraitURL
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if let portraitURL {
                    PortraitUnderlay(url: portraitURL, size: size)
                }
                breathingHalo(t: t)
                Canvas { ctx, csize in
                    let center = CGPoint(x: csize.width / 2, y: csize.height / 2)
                    drawComets(ctx: ctx, center: center, size: csize, t: t)
                    drawSparkleBurst(ctx: ctx, center: center, size: csize, t: t)
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
                if let progress {
                    progressArc(progress: progress)
                }
                if let caption {
                    VStack {
                        Spacer()
                        captionPill(caption).padding(.bottom, size * 0.12)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func progressArc(progress: Double) -> some View {
        let clamped = max(0, min(1, progress))
        return ZStack {
            // Faint full-circle track so the user can see how far
            // along the warm-up they are even at low fill ratios.
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 2)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            BrandColors.coral.opacity(0.9),
                            BrandColors.coral.opacity(0.6),
                            BrandColors.coral.opacity(0.9),
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: clamped)
                .shadow(color: BrandColors.coral.opacity(0.55), radius: 4)
        }
        .frame(width: size * 0.92, height: size * 0.92)
        .allowsHitTesting(false)
    }

    private func breathingHalo(t: Double) -> some View {
        let phase = sin(2.0 * .pi * t / 2.8)
        let pulse = 0.55 + 0.25 * phase
        let scale = 1.0 + 0.08 * phase
        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        BrandColors.coral.opacity(0.45 * pulse),
                        BrandColors.coral.opacity(0.12 * pulse),
                        .clear,
                    ],
                    center: .center,
                    startRadius: size * 0.18,
                    endRadius: size * 0.55
                )
            )
            .scaleEffect(scale)
            .blur(radius: 10)
            .allowsHitTesting(false)
    }

    private func captionPill(_ text: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(BrandColors.coral)
                .frame(width: 5, height: 5)
                .shadow(color: BrandColors.coral.opacity(0.8), radius: 3)
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.94))
                .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule(style: .continuous).fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }

    private static let cometCount = 48
    private static let trailSegments = 5
    private static let trailStepSeconds: Double = 0.032

    private func drawComets(ctx: GraphicsContext, center: CGPoint, size csize: CGSize, t: Double) {
        let minSide = Double(min(csize.width, csize.height))
        for i in 0..<Self.cometCount {
            let basePhase = Double(i) * 2.399
            let angularVelocity = 0.35 + hash(i, 11.0) * 0.75
            let direction: Double = (i % 5 == 0) ? -1.0 : 1.0
            let baseRadius = minSide * (0.34 + hash(i, 23.0) * 0.24)
            let jitterAmp = minSide * (0.01 + hash(i, 37.0) * 0.03)
            let jitterFreq = 0.6 + hash(i, 53.0) * 1.2
            let jitterPhase = hash(i, 71.0) * .pi * 2
            let dotSize = 1.6 + hash(i, 89.0) * 2.2
            let brightness = 0.65 + hash(i, 103.0) * 0.35
            for seg in 0..<Self.trailSegments {
                let tAtSeg = t - Double(seg) * Self.trailStepSeconds
                let angle = basePhase + direction * angularVelocity * tAtSeg
                let radius = baseRadius + jitterAmp * sin(jitterFreq * tAtSeg + jitterPhase)
                let x = center.x + CGFloat(radius * cos(angle))
                let y = center.y + CGFloat(radius * sin(angle))
                let segFade = 1.0 - Double(seg) / Double(Self.trailSegments)
                let opacity = brightness * segFade * segFade
                let segSize = dotSize * (1.0 - Double(seg) * 0.14)
                drawGlowDot(ctx: ctx, at: CGPoint(x: x, y: y), radius: segSize, opacity: opacity)
            }
        }
    }

    private static let burstInterval: Double = 1.7
    private static let burstLife: Double = 1.1
    private static let burstParticleCount = 14

    private func drawSparkleBurst(ctx: GraphicsContext, center: CGPoint, size csize: CGSize, t: Double) {
        let burstIndex = Int(floor(t / Self.burstInterval))
        let age = t - Double(burstIndex) * Self.burstInterval
        guard age < Self.burstLife else { return }
        let minSide = Double(min(csize.width, csize.height))
        let startAngle = hash(burstIndex, 191.0) * .pi * 2
        let startRadius = minSide * 0.44
        let start = CGPoint(
            x: center.x + CGFloat(startRadius * cos(startAngle)),
            y: center.y + CGFloat(startRadius * sin(startAngle))
        )
        let t01 = age / Self.burstLife
        let fade = 1.0 - t01
        for j in 0..<Self.burstParticleCount {
            let seed = burstIndex &* 31 &+ j
            let angleJ = Double(j) / Double(Self.burstParticleCount) * .pi * 2 + hash(seed, 211.0) * 0.4
            let speed = 55.0 + hash(seed, 233.0) * 70.0
            let dist = speed * age * (1.0 - 0.4 * t01)
            let x = start.x + CGFloat(dist * cos(angleJ))
            let y = start.y + CGFloat(dist * sin(angleJ))
            let dotSize = 1.2 + hash(seed, 257.0) * 1.6
            let opacity = fade * (0.75 + hash(seed, 277.0) * 0.25)
            drawGlowDot(ctx: ctx, at: CGPoint(x: x, y: y), radius: dotSize, opacity: opacity)
        }
    }

    private func drawGlowDot(ctx: GraphicsContext, at p: CGPoint, radius: Double, opacity: Double) {
        let r = CGFloat(radius)
        let halo = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ctx.fill(Circle().path(in: halo), with: .color(BrandColors.coral.opacity(opacity * 0.50)))
        let inset = r * 0.55
        let core = halo.insetBy(dx: inset, dy: inset)
        ctx.fill(Circle().path(in: core), with: .color(Color.white.opacity(opacity * 0.92)))
    }

    private func hash(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - floor(v)
    }
}

/// Loads `url` once per URL change via `.task(id:)`, holds the
/// decoded image in `@State`, and renders it as a dimmed, circle-
/// clipped underlay. The split into its own `View` is what gives
/// us a stable `@State` storage — without this split, the parent
/// `LoadingParticleField`'s 60 FPS `TimelineView` body would
/// instantiate a fresh portrait closure each tick, re-decode the
/// JPG, and burn ~30 ms of CPU per frame.
private struct PortraitUnderlay: View {
    let url: URL
    let size: CGFloat
    #if canImport(UIKit)
    @State private var image: UIImage?
    #elseif canImport(AppKit)
    @State private var image: NSImage?
    #endif

    var body: some View {
        Group {
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            #elseif canImport(AppKit)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .opacity(0.85)
        .allowsHitTesting(false)
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        // Decode off the main thread — JPG decode is the slow
        // part; SwiftUI's render thread should never block on it.
        let path = url.path
        let decoded = await Task.detached(priority: .userInitiated) { () -> Sendable? in
            #if canImport(UIKit)
            return UIImage(contentsOfFile: path)
            #elseif canImport(AppKit)
            return NSImage(contentsOfFile: path)
            #else
            return nil
            #endif
        }.value
        await MainActor.run {
            #if canImport(UIKit)
            self.image = decoded as? UIImage
            #elseif canImport(AppKit)
            self.image = decoded as? NSImage
            #endif
        }
    }
}
