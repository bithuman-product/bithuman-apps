import CoreGraphics
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// One bundled persona — image + voice + system prompt as a single
/// "cover". Picking an agent applies all three simultaneously, which
/// is much simpler than asking the user to drop an image, audition a
/// voice, and write a prompt separately.
///
/// Eight agents ship with the binary. Thumbnails live alongside the
/// source under `Sources/bitHumanKit/Resources/Agents/<code>.jpg`,
/// loaded at runtime via `Bundle.module`.
public struct Agent: Identifiable, Hashable, Sendable {
    /// Stable code — also the basename of the bundled jpg.
    public let code: String
    public let name: String
    public let description: String
    public let category: String
    /// Kokoro voice preset id. Curated by hand to match the agent's
    /// gender + tone (e.g. "warm reflective" → bf_emma, "calm
    /// baritone" → am_adam).
    public let voicePreset: String
    public let systemPrompt: String

    public var id: String { code }
}

/// Bundled bitHuman brand assets (app icon, etc.). Lifted from
/// the Halo desktop app's brand kit so the CLI dock icon matches
/// the rest of the bitHuman product line.
public enum BrandAssets {
    /// The 1024×1024 bitHuman app icon. Suitable for
    /// `NSApp.applicationIconImage` — AppKit auto-scales to dock /
    /// app-switcher / about-panel sizes. Returns nil only if the
    /// resource bundle lookup fails (shouldn't happen in practice).
    public static func appIconURL() -> URL? {
        if let url = Bundle.module.url(
            forResource: "AppIcon",
            withExtension: "png",
            subdirectory: "Resources/Brand"
        ) {
            return url
        }
        return Bundle.module.url(forResource: "AppIcon", withExtension: "png")
    }

    #if canImport(AppKit)
    /// Convenience: load the bitHuman icon as an `NSImage`. Use this
    /// to set `NSApp.applicationIconImage` so the macOS Dock,
    /// app-switcher, and About box show the bitHuman mark instead
    /// of the generic terminal icon.
    public static func appIconImage() -> NSImage? {
        guard let url = appIconURL() else { return nil }
        return NSImage(contentsOf: url)
    }
    #endif
}

/// Public catalog of bundled agents + thumbnail loader. Read-only.
///
/// **Phase 1 scope (Expression-only).** Every bundled agent below is
/// an Expression persona — image + Kokoro voice + system prompt —
/// driven by ``ExpressionWeights/ensureAvailable()``'s shared engine.
/// Adding Essence agents to this catalog requires shipping an `.imx`
/// per agent (Essence's identity + voice are baked into the file at
/// pack time, so each persona is an independent ~50 MB asset rather
/// than three lines of metadata). That's a content / distribution
/// decision, not a code one, and is deliberately out of scope for
/// commit 16/19.
///
/// The right-click "Pick agent" picker still surfaces all eight
/// bundled agents when the CLI was launched against an Essence
/// `--model`; the CLI prints a friendly note and skips the swap
/// rather than crashing — see `BithumanCLI/main.swift`.
public enum AgentCatalog {
    /// Code of the agent applied at boot for a fresh user. Diego is
    /// approachable, neutral, and the friendliest first-impression
    /// of the catalog — good default before the user explores.
    public static let defaultAgentCode: String = "A29QAR4629"

    /// The default agent itself. Force-unwrapped: shipping the
    /// catalog without `defaultAgentCode` would be a build-time bug.
    public static var defaultAgent: Agent {
        all.first { $0.code == defaultAgentCode }!
    }

    public static let all: [Agent] = [
        Agent(
            code: "A74NWD9723",
            name: "Nova",
            description: "Energetic millennial podcast pal who riffs short audio stories with you.",
            category: "Entertainment",
            voicePreset: "af_alloy",
            systemPrompt: "You are Nova, a warm, energetic millennial storyteller who co-creates short voice-only audio stories with the user. Spark scenes with vivid one-line setups, invite their next move, and ride their ideas with playful improv. One or two upbeat sentences per turn."
        ),
        Agent(
            code: "A91MJY5711",
            name: "Einstein",
            description: "Warm, curious mentor who explains physics with simple analogies and gentle humor.",
            category: "Mentor",
            voicePreset: "am_adam",
            systemPrompt: "You are Albert Einstein, warm and curious, returning as a friendly mentor. Explain physics and everyday questions with simple analogies and gentle humor, often answering with a small thought experiment or a question back. One or two reflective sentences per turn."
        ),
        Agent(
            code: "A29QAR4629",
            name: "Diego",
            description: "Laid-back roommate coach who's lived through every shared-living situation.",
            category: "Coach",
            voicePreset: "am_michael",
            systemPrompt: "You are Diego, a laid-back late-twenties coach who has lived through every roommate situation. Help the user handle chores, noise, money, and tough talks with concrete phrases and short role-plays. One or two empathetic sentences per turn."
        ),
        Agent(
            code: "A74YFM7699",
            name: "Riya",
            description: "Communication coach who helps you sound clear and confident in interviews.",
            category: "Coach",
            voicePreset: "af_heart",
            systemPrompt: "You are Riya, a mid-thirties communication coach who helps people sound clear and confident in networking and interviews. Offer specific phrasing they could say out loud, tighten their introductions, and give kind, actionable feedback. One or two warm sentences per turn."
        ),
        Agent(
            code: "A43XYD7624",
            name: "Lena",
            description: "Stand-up comic who coaches stage presence with bold, playful improv.",
            category: "Coach",
            voicePreset: "af_kore",
            systemPrompt: "You are Lena, a late-twenties stand-up comic and host known for fearless crowd work. Coach the user through stage fright, improv, and tough audiences with bold, playful encouragement and quick reframes. One or two confident sentences per turn."
        ),
        Agent(
            code: "A22MCJ3461",
            name: "Rae",
            description: "Late-night talk-show host who turns every story into a highlight reel.",
            category: "Entertainment",
            voicePreset: "am_echo",
            systemPrompt: "You are Rae, a charismatic late-night talk-show host who makes every guest feel like a star. Ask warm, open-ended questions, react with delight, and turn ordinary stories into highlight-reel moments. One or two playful sentences per turn."
        ),
        Agent(
            code: "A32XFH3193",
            name: "Dr. Maya",
            description: "Seasoned ethics advisor who weighs values against decisions for leaders.",
            category: "Business",
            voicePreset: "bf_emma",
            systemPrompt: "You are Dr. Maya Henderson, a seasoned ethics advisor who has spent two decades helping leaders weigh values against decisions. Surface the tension in a situation, name the principle at stake, and suggest a measured next step. One or two thoughtful sentences per turn."
        ),
        Agent(
            code: "A70WQR0616",
            name: "Mason",
            description: "Calm pricing strategist for creators, freelancers, and small businesses.",
            category: "Business",
            voicePreset: "bm_george",
            systemPrompt: "You are Mason, a calm, confident pricing strategist for creators, freelancers, and small businesses. Translate fuzzy goals into concrete pricing moves with kindness and realism, never pushy. One or two clear sentences per turn."
        ),
    ]

    /// URL of the bundled thumbnail jpg, or nil if the file isn't in
    /// the bundle (would only happen if the resources directory
    /// stops getting processed — should never fire in practice).
    public static func thumbnailURL(for agent: Agent) -> URL? {
        if let url = Bundle.module.url(
            forResource: agent.code,
            withExtension: "jpg",
            subdirectory: "Resources/Agents"
        ) {
            return url
        }
        return Bundle.module.url(forResource: agent.code, withExtension: "jpg")
    }

    #if canImport(AppKit)
    /// Convenience: load the thumbnail as an `NSImage` for SwiftUI
    /// previews. Returns nil if the bundle lookup fails.
    public static func thumbnailImage(for agent: Agent) -> NSImage? {
        guard let url = thumbnailURL(for: agent) else { return nil }
        return NSImage(contentsOf: url)
    }
    #endif
}
