#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// Grid of bundled `Agent`s. Picking a card applies image + voice +
/// prompt all at once via `AvatarCoordinator.applyAgent`. Tracks the
/// currently-applied agent so the active card stays visually marked
/// across the user's session.
public struct AgentPickerView: View {
    @ObservedObject var coordinator: AvatarCoordinator
    let onClose: () -> Void

    public init(coordinator: AvatarCoordinator, onClose: @escaping () -> Void) {
        self._coordinator = ObservedObject(wrappedValue: coordinator)
        self.onClose = onClose
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(AgentCatalog.all) { agent in
                        AgentCard(
                            agent: agent,
                            selected: coordinator.currentAgentCode == agent.code,
                            onPick: {
                                coordinator.applyAgent(agent)
                                // Auto-close — picking already commits
                                // the change, no separate Save / Close
                                // step needed.
                                onClose()
                            }
                        )
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.crop.square.stack.fill")
                .font(.system(size: 20))
                .foregroundStyle(BrandColors.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text("Choose an agent")
                    .font(.system(size: 14, weight: .semibold))
                Text("Each agent comes with its own face, voice, and personality.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

}

/// Single card: square portrait above two text lines (name +
/// short blurb). Highlighted with a coral border + glow when this
/// agent is the active one.
public struct AgentCard: View {
    let agent: Agent
    let selected: Bool
    let onPick: () -> Void

    public init(agent: Agent, selected: Bool, onPick: @escaping () -> Void) {
        self.agent = agent
        self.selected = selected
        self.onPick = onPick
    }

    public var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 8) {
                portrait
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(BrandColors.coral)
                        }
                        Spacer()
                    }
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(minHeight: 28, alignment: .topLeading)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? BrandColors.coral.opacity(0.12) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        selected ? BrandColors.coral.opacity(0.85) : Color.white.opacity(0.10),
                        lineWidth: selected ? 1.4 : 0.6
                    )
            )
            .shadow(color: selected ? BrandColors.coral.opacity(0.4) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
        .help(agent.description)
        .animation(.easeInOut(duration: 0.18), value: selected)
    }

    private var portraitPlaceholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "person.crop.square")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            )
    }

    @ViewBuilder
    private var portrait: some View {
        // GeometryReader gives us the column-allocated width so the
        // image scales-and-clips to fit. Without an explicit width
        // bound, `.aspectRatio(.fill)` lets a tall portrait spill
        // sideways into the next column — that was the v0.4.0
        // overlap bug.
        GeometryReader { geo in
            Group {
                #if canImport(AppKit)
                if let nsImage = AgentCatalog.thumbnailImage(for: agent) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    portraitPlaceholder
                }
                #elseif canImport(UIKit)
                // UIKit branch: load thumbnail from the bundle URL via
                // UIImage. NSImage isn't available here; the AgentCatalog
                // helper that returns NSImage is gated to AppKit too.
                if let url = AgentCatalog.thumbnailURL(for: agent),
                   let uiImage = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    portraitPlaceholder
                }
                #else
                portraitPlaceholder
                #endif
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .frame(height: 150)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
    }
}

#if canImport(AppKit)
/// Hosting window for `AgentPickerView`. Same lifetime contract as
/// the voice + prompt panels — coordinator owns the strong ref,
/// `isReleasedWhenClosed = false` so the user's pick state survives
/// hide/show.
///
/// macOS-only; iPad/iOS use a `.sheet` instead.
@MainActor
final class AgentPickerWindow: NSWindow {
    init(coordinator: AvatarCoordinator) {
        let rect = NSRect(x: 0, y: 0, width: 540, height: 540)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = "Agents"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.center()

        let view = AgentPickerView(coordinator: coordinator) { [weak self] in
            self?.close()
        }
        let host = NSHostingView(rootView: view)
        host.frame = rect
        host.autoresizingMask = [.width, .height]
        self.contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
#endif
