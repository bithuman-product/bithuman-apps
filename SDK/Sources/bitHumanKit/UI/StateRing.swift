import CoreGraphics
import Foundation
import SwiftUI

/// Colored stroke that sits just outside the avatar circle and
/// surfaces the orchestrator's current phase. Replaces the in-circle
/// StatePill from Phase 2b — the user reads phase from the ring's
/// hue and the matching label below the avatar instead of from a
/// floating capsule that crowded the face.
///
/// - listening / speaking: solid ring with a breathing glow
/// - thinking: solid ring + a fast-rotating chase arc on top
/// - idle: invisible (animation-driven fade so we don't flash)
public struct StateRing: View {
    let state: VoiceChatOrchestrator.State
    let visible: Bool
    /// Optional explicit ring diameter. macOS callers supply
    /// `AvatarWindow.ringSide` to keep the existing 199 pt look; iPad
    /// callers leave it nil and use a `.frame(...)` modifier outside
    /// to size the ring relative to the dynamically-sized avatar.
    let side: CGFloat?

    public init(state: VoiceChatOrchestrator.State, visible: Bool, side: CGFloat? = nil) {
        self.state = state
        self.visible = visible
        self.side = side
    }

    public var body: some View {
        let accent = BrandColors.accent(for: state)
        let active = visible && state != .idle
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = 0.5 + 0.5 * sin(2.0 * .pi * t / 1.4)
            let glowAlpha = active ? (0.45 + 0.45 * breath) : 0
            let glowRadius: CGFloat = active ? CGFloat(5 + 9 * breath) : 0
            ZStack {
                Circle()
                    .stroke(
                        accent.opacity(active ? 0.92 : 0.0),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .shadow(color: accent.opacity(glowAlpha), radius: glowRadius)

                if state == .thinking, active {
                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(
                            accent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(t * 220))
                        .shadow(color: accent.opacity(0.7), radius: 4)
                }
            }
            .frame(width: side, height: side)
            .animation(.easeInOut(duration: 0.45), value: state)
        }
        .allowsHitTesting(false)
    }
}

/// Status label below the avatar circle. Reads "listening",
/// "thinking…", or "speaking" with a tinted dot matching the ring.
/// Hidden in `.idle` so we never flash a stale phrase between turns.
public struct StateLabel: View {
    let state: VoiceChatOrchestrator.State
    let visible: Bool

    public init(state: VoiceChatOrchestrator.State, visible: Bool) {
        self.state = state
        self.visible = visible
    }

    public var body: some View {
        let accent = BrandColors.accent(for: state)
        let active = visible && state != .idle
        let txt = label(for: state)
        HStack(spacing: 7) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
                .shadow(color: accent.opacity(0.85), radius: 3)
            Text(txt)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.94))
                .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.32), radius: 4, y: 1)
        .opacity(active ? 1 : 0)
        .scaleEffect(active ? 1 : 0.92)
        .animation(.easeInOut(duration: 0.3), value: state)
        .animation(.easeInOut(duration: 0.3), value: visible)
    }

    private func label(for state: VoiceChatOrchestrator.State) -> String {
        switch state {
        case .idle:      return ""
        case .listening: return "listening"
        case .thinking:  return "thinking…"
        case .speaking:  return "speaking"
        }
    }
}
