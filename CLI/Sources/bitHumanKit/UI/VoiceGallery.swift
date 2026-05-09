#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// User-facing metadata for the curated Kokoro voice presets. The IDs
/// must stay in sync with `KokoroTTSPlayer.voicePresets`; the rest
/// drives the gallery cards (display name, descriptor, icon, tint).
public enum VoiceCatalog {
    public enum Gender { case feminine, masculine }

    public struct Meta: Equatable {
        public let id: String
        public let displayName: String
        public let descriptor: String
        public let icon: String
        public let tint: Color
        public let gender: Gender

        public init(
            id: String,
            displayName: String,
            descriptor: String,
            icon: String,
            tint: Color,
            gender: Gender
        ) {
            self.id = id
            self.displayName = displayName
            self.descriptor = descriptor
            self.icon = icon
            self.tint = tint
            self.gender = gender
        }
    }

    public static let all: [Meta] = [
        .init(id: "af_heart",   displayName: "Heart",   descriptor: "American · warm, conversational", icon: "heart.fill",            tint: Color(red: 0.95, green: 0.40, blue: 0.50), gender: .feminine),
        .init(id: "af_alloy",   displayName: "Alloy",   descriptor: "American · bright, articulate",   icon: "sparkle",               tint: Color(red: 0.55, green: 0.74, blue: 0.95), gender: .feminine),
        .init(id: "af_aoede",   displayName: "Aoede",   descriptor: "American · lyrical, soft",        icon: "music.note",            tint: Color(red: 0.78, green: 0.55, blue: 0.96), gender: .feminine),
        .init(id: "af_kore",    displayName: "Kore",    descriptor: "American · youthful, energetic",  icon: "leaf.fill",             tint: Color(red: 0.45, green: 0.82, blue: 0.55), gender: .feminine),
        .init(id: "bf_emma",    displayName: "Emma",    descriptor: "British · polite, refined",       icon: "crown.fill",            tint: Color(red: 0.85, green: 0.65, blue: 0.45), gender: .feminine),
        .init(id: "am_adam",    displayName: "Adam",    descriptor: "American · calm, baritone",       icon: "waveform",              tint: Color(red: 0.40, green: 0.55, blue: 0.85), gender: .masculine),
        .init(id: "am_michael", displayName: "Michael", descriptor: "American · friendly, neutral",    icon: "person.fill",           tint: Color(red: 0.42, green: 0.65, blue: 0.78), gender: .masculine),
        .init(id: "am_echo",    displayName: "Echo",    descriptor: "American · deep, resonant",       icon: "speaker.wave.3.fill",   tint: Color(red: 0.30, green: 0.45, blue: 0.60), gender: .masculine),
        .init(id: "bm_george",  displayName: "George",  descriptor: "British · warm, gentlemanly",     icon: "books.vertical.fill",   tint: Color(red: 0.60, green: 0.50, blue: 0.40), gender: .masculine),
    ]

    public static var feminine: [Meta] { all.filter { $0.gender == .feminine } }
    public static var masculine: [Meta] { all.filter { $0.gender == .masculine } }

    public static func meta(for id: String) -> Meta? {
        all.first { $0.id == id }
    }
}

/// Floating SwiftUI panel that lets the user audition each Kokoro
/// voice and commit one. Cards are click-to-preview (auditions in
/// place) plus a dedicated play button. "Save" commits the highlighted
/// voice; "Cancel" leaves the persistent preset untouched.
public struct VoicePickerView: View {
    @ObservedObject var coordinator: AvatarCoordinator
    let onClose: () -> Void
    @State private var selectedPreset: String
    @State private var previewing: String?

    public init(coordinator: AvatarCoordinator, onClose: @escaping () -> Void) {
        self._coordinator = ObservedObject(wrappedValue: coordinator)
        self.onClose = onClose
        self._selectedPreset = State(initialValue: coordinator.currentVoicePreset)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                LazyVStack(spacing: 14) {
                    voiceSection("Feminine", voices: VoiceCatalog.feminine)
                    voiceSection("Masculine", voices: VoiceCatalog.masculine)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(BrandColors.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text("Choose a voice")
                    .font(.system(size: 15, weight: .semibold))
                Text("Click a voice to hear a sample.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { commit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func voiceSection(_ title: String, voices: [VoiceCatalog.Meta]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.leading, 4)
            VStack(spacing: 8) {
                ForEach(voices, id: \.id) { meta in
                    VoiceCard(
                        meta: meta,
                        selected: selectedPreset == meta.id,
                        previewing: previewing == meta.id,
                        onSelect: { selectAndPreview(meta.id) },
                        onPreview: { selectAndPreview(meta.id) }
                    )
                }
            }
        }
    }

    private func selectAndPreview(_ id: String) {
        selectedPreset = id
        previewing = id
        coordinator.previewVoice(id)
    }

    private func commit() {
        coordinator.setVoicePreset(selectedPreset)
        onClose()
    }
}

/// Single voice card row inside `VoicePickerView`. Highlights when
/// it's the current selection; the play icon doubles as a "currently
/// previewing" indicator.
public struct VoiceCard: View {
    let meta: VoiceCatalog.Meta
    let selected: Bool
    let previewing: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void

    public init(
        meta: VoiceCatalog.Meta,
        selected: Bool,
        previewing: Bool,
        onSelect: @escaping () -> Void,
        onPreview: @escaping () -> Void
    ) {
        self.meta = meta
        self.selected = selected
        self.previewing = previewing
        self.onSelect = onSelect
        self.onPreview = onPreview
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(meta.tint.opacity(selected ? 0.95 : 0.7))
                        .frame(width: 36, height: 36)
                        .shadow(color: meta.tint.opacity(selected ? 0.5 : 0.0), radius: 4)
                    Image(systemName: meta.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(meta.descriptor)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: onPreview) {
                    Image(systemName: previewing ? "speaker.wave.2.circle.fill" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(previewing ? meta.tint : Color.accentColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: previewing)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? meta.tint.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? meta.tint.opacity(0.85) : Color.white.opacity(0.07),
                        lineWidth: selected ? 1.4 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: selected)
        .animation(.easeInOut(duration: 0.18), value: previewing)
    }
}

#if canImport(AppKit)
/// Hosting window for `VoicePickerView`. Floats above the avatar
/// (level: .floating) and quits previewing on close.
///
/// macOS-only. iPad/iOS apps use a SwiftUI `.sheet` presentation
/// driven by an `@Published` bool on `AvatarCoordinator` instead;
/// see `Apps/BithumanPad/` and `Apps/BithumanPhone/`.
@MainActor
final class VoicePickerWindow: NSWindow {
    init(coordinator: AvatarCoordinator) {
        let rect = NSRect(x: 0, y: 0, width: 380, height: 520)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = "Voices"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.center()

        let view = VoicePickerView(coordinator: coordinator) { [weak self] in
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
