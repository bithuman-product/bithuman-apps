// iPadAvatarRendererRepresentable.swift — UIKit twin of the macOS
// `AvatarRendererRepresentable` (in `bitHumanKit/UI/AvatarRootView.swift`).
//
// Now that the library exposes a public UIKit `AvatarRendererView`
// (in `bitHumanKit/UI/AvatarRenderer.swift`), this file is a thin
// passthrough — the FramePump in BithumanPadLifecycle drives the
// view directly via its AvatarFrameSink conformance, and SwiftUI
// just hosts it without re-creating it on view-tree updates (going
// through `updateUIView` at 25 FPS would tear the SwiftUI render
// graph).

#if canImport(UIKit)
import SwiftUI
import bitHumanKit

struct iPadAvatarRendererRepresentable: UIViewRepresentable {
    /// Pre-constructed by the lifecycle. SwiftUI does NOT own this
    /// view's lifetime; we just let the host display it.
    let view: AvatarRendererView

    func makeUIView(context: Context) -> AvatarRendererView { view }

    func updateUIView(_ uiView: AvatarRendererView, context: Context) {
        // No-op: CALayer updates are pushed imperatively from the
        // FramePump's consumer timer, NOT through SwiftUI diffing.
    }
}
#endif // canImport(UIKit)
