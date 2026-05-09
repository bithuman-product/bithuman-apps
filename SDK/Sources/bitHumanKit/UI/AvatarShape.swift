import Foundation

/// Shape (and sizing strategy) the avatar window / renderer should
/// adopt for the loaded model.
///
/// `VoiceChatConfig.avatarShape` defaults to ``auto`` — the right
/// thing for the "load any `.imx` and it just works" path. The
/// resolver looks at the loaded model's `manifest.model_type` and
/// picks:
///
/// - `"essence"` → ``fill`` (rectangular full-frame, matches the
///   Essence runtime's 720p+ output where the rectangular video IS
///   the entire UI — no status pill, no circular crop).
/// - `"expression"` → ``circle`` (legacy 195pt circular floating
///   layout: avatar zone + status-label-pill zone, drag-by-background,
///   the original macOS Expression look).
///
/// Override only when the auto pick is wrong for your UI:
/// - Force ``fill`` on an Expression model to drop the circle clip
///   for, e.g., a rectangular Picture-in-Picture overlay.
/// - Force ``circle`` on an Essence model to crop a 720² render down
///   to a round portrait zone for, e.g., a chat-app contact avatar.
///
/// This enum mirrors `AvatarRendererView.ClipMode` 1:1 plus the
/// extra ``auto`` case; consumers that build an `AvatarWindow`
/// themselves can call ``resolve(modelType:)`` to flatten an
/// `AvatarShape` to the underlying `ClipMode` at construction time.
public enum AvatarShape: Sendable, Equatable {
    /// Derive the shape from the loaded model's `manifest.model_type`.
    /// Default for `VoiceChatConfig.avatarShape`. Resolves at runtime
    /// once the model is loaded — see ``resolve(modelType:)``.
    case auto

    /// Legacy Expression circular layout — avatar inscribed in a
    /// circle inside the host view's short side, status-label-pill
    /// zone reserved below. The macOS floating-circle Expression
    /// use case.
    case circle

    /// Essence rectangular full-frame — avatar layer stretches to
    /// the full host bounds with no corner rounding. The
    /// rectangular video IS the entire UI.
    case fill

    /// Resolve ``auto`` against the loaded model's `manifest.model_type`.
    ///
    /// - Parameter modelType: The string value of `manifest.model_type`
    ///   from the loaded `.imx`. Pass `nil` if unknown — the resolver
    ///   falls back to ``circle`` (matches existing behaviour: every
    ///   shipped `.imx` before Essence was Expression / circular).
    /// - Returns: A concrete shape — never ``auto``. Pass-through for
    ///   explicitly-set ``circle`` / ``fill`` so callers can apply
    ///   `resolve` unconditionally without branching on `.auto`.
    public func resolve(modelType: String?) -> AvatarShape {
        switch self {
        case .auto:
            switch modelType {
            case "essence":     return .fill
            case "expression":  return .circle
            default:            return .circle
            }
        case .circle, .fill:
            return self
        }
    }
}

#if canImport(AppKit) || canImport(UIKit)
extension AvatarShape {
    /// Flatten a resolved (i.e. non-`.auto`) shape to the renderer
    /// view's clip mode. Calling this on `.auto` is a programmer
    /// error — call ``resolve(modelType:)`` first. The trap surfaces
    /// the misuse instead of silently picking a default.
    public var clipMode: AvatarRendererView.ClipMode {
        switch self {
        case .circle: return .circle
        case .fill:   return .fill
        case .auto:
            preconditionFailure(
                "AvatarShape.clipMode called on .auto — call resolve(modelType:) first"
            )
        }
    }
}
#endif
