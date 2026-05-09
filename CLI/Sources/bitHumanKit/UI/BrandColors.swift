import SwiftUI

/// bitHuman brand palette — single source of truth for the SwiftUI
/// overlays (state pill, loading field, accents). Mirrors Halo's
/// Theme.swift structure but trimmed to just the hues this app uses.
public enum BrandColors {
    /// Primary coral — bitHuman brand mark.
    public static let coral = Color(red: 0.98, green: 0.36, blue: 0.34)
    /// Per-state accent. Maps 1:1 to `VoiceChatOrchestrator.State`.
    public static let listening = Color(red: 0.32, green: 0.78, blue: 0.88)  // cyan
    public static let thinking  = Color(red: 0.71, green: 0.50, blue: 0.97)  // violet
    public static let speaking  = Color(red: 0.98, green: 0.72, blue: 0.36)  // amber

    public static func accent(for state: VoiceChatOrchestrator.State) -> Color {
        switch state {
        case .idle:      return coral
        case .listening: return listening
        case .thinking:  return thinking
        case .speaking:  return speaking
        }
    }
}
