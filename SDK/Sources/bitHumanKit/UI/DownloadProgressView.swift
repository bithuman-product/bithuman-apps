// DownloadProgressView — first-run weight download UI for the iPad
// and iPhone apps. Replaces the bare LoadingParticleField when the
// app is downloading the ~3.7 GB engine bundle: shows a circular
// progress ring with the percentage in the middle, and a line of
// supplementary text below with bytes-downloaded / total + speed +
// ETA. Idle when phase != .downloading; the caller swaps to
// LoadingParticleField for the brief "warming models" stretch
// after the download completes.

import SwiftUI

public struct DownloadProgressView: View {
    private let phase: DownloadPhase
    private let side: CGFloat

    public init(phase: DownloadPhase, side: CGFloat = 220) {
        self.phase = phase
        self.side = side
    }

    public var body: some View {
        VStack(spacing: 18) {
            ProgressRing(fraction: fraction, side: side, label: centerLabel)
            VStack(spacing: 4) {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var fraction: Double {
        switch phase {
        case .verifying:           return 0.0
        case .downloading(let f, _, _, _, _): return f
        case .verifyingDownloaded: return 1.0
        case .ready:               return 1.0
        }
    }

    /// Text inside the ring. "n%" while downloading, dots otherwise.
    private var centerLabel: String {
        switch phase {
        case .verifying, .verifyingDownloaded: return "…"
        case .downloading(let f, _, _, _, _):  return "\(Int((f * 100).rounded()))%"
        case .ready:                            return "✓"
        }
    }

    /// First line — what step we're on.
    private var headline: String {
        switch phase {
        case .verifying:           return "Verifying cached model…"
        case .verifyingDownloaded: return "Verifying download…"
        case .ready:               return "Ready"
        case .downloading(_, let bytes, let total, _, _):
            return "Downloading model · \(formatGB(bytes)) of \(formatGB(total))"
        }
    }

    /// Second line — speed + ETA. Nil for non-download phases.
    private var detail: String? {
        guard case .downloading(_, _, _, let bps, let eta) = phase else { return nil }
        if bps <= 0 {
            return "estimating…"
        }
        let speed = formatSpeed(bps)
        guard let eta, eta.isFinite else { return speed }
        return "\(speed) · \(formatETA(eta)) remaining"
    }

    private func formatGB(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.2f GB", gb)
    }

    private func formatSpeed(_ bps: Double) -> String {
        if bps >= 1_048_576 {
            return String(format: "%.1f MB/s", bps / 1_048_576)
        }
        return String(format: "%.0f KB/s", bps / 1024)
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 60 {
            let m = s / 60
            return m == 1 ? "~1 min" : "~\(m) min"
        }
        if s <= 5 { return "almost there" }
        return "~\(s) s"
    }
}

/// Circular progress ring. Coral stroke over a thin track. The track
/// stays visible at 0% so the user has confirmation the ring is
/// "armed" and not just absent. Animation on `fraction` so the
/// 0.5 s sample cadence reads as motion, not a stutter.
private struct ProgressRing: View {
    let fraction: Double
    let side: CGFloat
    let label: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 4)
                .frame(width: side, height: side)
            Circle()
                .trim(from: 0, to: max(0.001, min(fraction, 1)))
                .stroke(BrandColors.coral, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: side, height: side)
                .animation(.easeOut(duration: 0.35), value: fraction)
            Text(label)
                .font(.system(size: side * 0.22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.35), value: label)
        }
    }
}
