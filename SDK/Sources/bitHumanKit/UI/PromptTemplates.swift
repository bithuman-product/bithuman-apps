#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// Curated starter prompts surfaced as pills in the prompt editor.
/// Clicking a pill overwrites the editor with the template body —
/// users can still edit before saving.
public struct PromptTemplate {
    public let title: String
    public let body: String
    public let icon: String
    public let tint: Color

    public init(title: String, body: String, icon: String, tint: Color) {
        self.title = title
        self.body = body
        self.icon = icon
        self.tint = tint
    }

    public static let curated: [PromptTemplate] = [
        .init(
            title: "Companion",
            body: "You are a warm, attentive companion who chats casually with the user. Keep replies short, natural, and engaged. Ask thoughtful follow-ups. Avoid formal language unless the user shifts tone.",
            icon: "bubble.left.and.bubble.right.fill",
            tint: Color(red: 0.95, green: 0.40, blue: 0.50)
        ),
        .init(
            title: "Coach",
            body: "You are a focused coach. The user will share goals, tasks, or blockers. Ask clarifying questions, suggest concrete next steps, and gently hold them accountable. Keep replies short and actionable.",
            icon: "target",
            tint: Color(red: 0.45, green: 0.82, blue: 0.55)
        ),
        .init(
            title: "Tutor",
            body: "You are a patient, Socratic tutor. Explain concepts step by step, check understanding with short questions, and adapt to the user's level. Use concrete examples and avoid jargon.",
            icon: "book.fill",
            tint: Color(red: 0.55, green: 0.74, blue: 0.95)
        ),
        .init(
            title: "Storyteller",
            body: "You are a vivid storyteller. The user names a setting, character, or mood; you craft short, evocative scenes. Keep momentum, hand control back often, and let the user steer the plot.",
            icon: "wand.and.stars",
            tint: Color(red: 0.78, green: 0.55, blue: 0.96)
        ),
        .init(
            title: "Coding buddy",
            body: "You are a senior engineer pair-programming with the user. Be terse, opinionated, and concrete. Reference real APIs, suggest small steps, and name tradeoffs explicitly.",
            icon: "chevron.left.forwardslash.chevron.right",
            tint: Color(red: 0.40, green: 0.55, blue: 0.85)
        ),
        .init(
            title: "Calm listener",
            body: "You are a calm, non-judgmental listener. Reflect what you hear, ask gentle clarifying questions, and validate feelings. Avoid prescriptive advice unless the user asks for it.",
            icon: "ear.fill",
            tint: Color(red: 0.85, green: 0.65, blue: 0.45)
        ),
    ]
}

/// Floating SwiftUI panel for editing the system prompt. Replaces
/// the prior NSAlert design — the new layout puts curated template
/// pills above a roomy text editor with Cancel / Save in the footer.
public struct PromptEditorView: View {
    @ObservedObject var coordinator: AvatarCoordinator
    let onClose: () -> Void
    @State private var draft: String
    @State private var activeTemplate: String?

    public init(coordinator: AvatarCoordinator, onClose: @escaping () -> Void) {
        self._coordinator = ObservedObject(wrappedValue: coordinator)
        self.onClose = onClose
        self._draft = State(initialValue: coordinator.currentSystemPrompt)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            editor
            templates
            Divider().opacity(0.25)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 20))
                .foregroundStyle(BrandColors.coral)
            VStack(alignment: .leading, spacing: 1) {
                Text("System prompt")
                    .font(.system(size: 14, weight: .semibold))
                Text("How the assistant behaves. Effective on the next reply.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// Roomy text editor takes the prominent spot — the user's
    /// own prompt is what they're working on, templates are just
    /// an inspiration shelf below.
    private var editor: some View {
        TextEditor(text: $draft)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.6)
                    )
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .frame(maxHeight: .infinity)
            .onChange(of: draft) { _, _ in activeTemplate = nil }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BrandColors.coral.opacity(0.85))
                Text("INSPIRATION")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PromptTemplate.curated, id: \.title) { tmpl in
                        templatePill(tmpl)
                    }
                }
                .padding(.bottom, 2)  // breathing room for shadow
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private func templatePill(_ tmpl: PromptTemplate) -> some View {
        let isActive = activeTemplate == tmpl.title
        return Button {
            draft = tmpl.body
            activeTemplate = tmpl.title
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tmpl.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : tmpl.tint)
                Text(tmpl.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Color.white : Color.primary.opacity(0.88))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? tmpl.tint.opacity(0.95) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule().stroke(
                    isActive ? tmpl.tint.opacity(0.95) : Color.white.opacity(0.12),
                    lineWidth: 0.7
                )
            )
            .shadow(color: isActive ? tmpl.tint.opacity(0.5) : .clear, radius: 4)
        }
        .buttonStyle(.plain)
        .help(tmpl.body)
        .animation(.easeInOut(duration: 0.18), value: isActive)
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

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        coordinator.setSystemPrompt(trimmed)
        onClose()
    }
}

#if canImport(AppKit)
/// Hosting window for `PromptEditorView`. Same lifetime contract as
/// `VoicePickerWindow` — strongly retained by the coordinator,
/// `isReleasedWhenClosed = false` so its draft survives hide/show.
///
/// macOS-only; iPad/iOS use a `.sheet` instead.
@MainActor
final class PromptEditorWindow: NSWindow {
    init(coordinator: AvatarCoordinator) {
        let rect = NSRect(x: 0, y: 0, width: 520, height: 480)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.title = "System Prompt"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.level = .floating
        self.isReleasedWhenClosed = false
        self.center()

        let view = PromptEditorView(coordinator: coordinator) { [weak self] in
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
