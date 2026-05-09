import CoreGraphics

/// Cross-platform sink for the FramePump's per-frame output.
///
/// On macOS the implementation is `AvatarWindow` — the borderless
/// circular NSWindow that hosts the AppKit `AvatarRendererView`.
/// `AvatarWindow.render(_:)` already exists and just forwards to the
/// renderer view's CALayer.
///
/// On iOS / iPadOS there is no separate window concept — SwiftUI's
/// `WindowGroup` owns the scene and the renderer IS the sink. The
/// UIKit branch of `AvatarRendererView` (UIView subclass, defined in
/// the same `AvatarRenderer.swift` file) conforms directly. The iPad
/// / Phone apps construct a `FramePump` with the renderer view itself
/// as the `AvatarFrameSink`.
///
/// Keeping the protocol surface minimal — just `render(_:)` — lets us
/// swap host types without bleeding AppKit or UIKit into FramePump.
@MainActor
public protocol AvatarFrameSink: AnyObject {
    /// Hand the next CGImage frame to the underlying renderer. Called
    /// from the FramePump's 25 FPS consumer timer on the main queue.
    func render(_ frame: CGImage)
}

/// Fans the same frame out to multiple sinks at once. Used on iPad to
/// drive the on-screen avatar renderer AND a Picture-in-Picture
/// `AvatarPiPController` from a single `FramePump` (which only takes
/// one sink). Both sinks receive each frame on the main queue, in
/// the order given.
@MainActor
public final class MultiAvatarFrameSink: AvatarFrameSink {
    private let sinks: [AvatarFrameSink]

    public init(_ sinks: [AvatarFrameSink]) {
        self.sinks = sinks
    }

    public func render(_ frame: CGImage) {
        for sink in sinks {
            sink.render(frame)
        }
    }
}
