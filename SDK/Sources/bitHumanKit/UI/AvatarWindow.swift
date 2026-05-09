#if canImport(AppKit)
import AppKit
import CoreGraphics
import SwiftUI

/// Floating window that hosts the avatar. Two layouts:
///
/// - **Circular (Expression)** — the legacy 235×290pt floating
///   circle: 195pt avatar zone + 55pt status-label-pill zone. Drag-
///   by-background, fixed size, above normal windows. Closes on
///   ⌘Q / Ctrl-C. Sizing matches Halo's collapsed-circle layout: on
///   a 2× Retina that renders the avatar at 390 px, ~the same as
///   the engine's native 384 px output — minimal scaling, no
///   visible upscale blur.
///
/// - **Rectangular fill (Essence)** — full-frame video at the
///   manifest's output resolution (typically 720×720, 720×1280,
///   etc.). No status-label-pill zone, no circular clip; the
///   rectangular video IS the entire UI. Borderless and resizable.
@MainActor
public final class AvatarWindow: NSWindow {
    /// Window width for the circular Expression layout (also the
    /// avatar zone size — avatar + shadow margin).
    public static let windowSide: CGFloat = 235
    /// Reserved height below the avatar zone for the status label pill.
    static let labelZone: CGFloat = 55
    /// Total window height for the circular layout: avatar zone + label zone.
    public static let windowHeight: CGFloat = windowSide + labelZone
    /// Avatar circle diameter (and CALayer side length).
    static let avatarSide: CGFloat = 195
    /// Status ring sits just outside the avatar circle.
    static let ringSide: CGFloat = avatarSide + 4

    /// Owned by the window, also handed to SwiftUI / the FramePump
    /// for rendering frames + observing swap state. We keep a direct
    /// reference so the FramePump can call `render(_:)` without
    /// going through the SwiftUI view tree.
    let renderer: AvatarRendererView
    /// Optional in `.fill` mode — Essence has no status pill, no
    /// drag-drop / context-menu overlay, so the SwiftUI tree (which
    /// is the only thing that consumes the coordinator) isn't
    /// installed. The Expression circular path always supplies one.
    let coordinator: AvatarCoordinator?

    /// Canonical constructor. The Expression-circular convenience
    /// (`init(idleFrame:coordinator:)`) below delegates here with
    /// `targetSize = 235×290` and `clipMode = .circle`.
    ///
    /// - Parameters:
    ///   - targetSize: Initial content size. For Essence this is
    ///     typically the manifest's `output_resolution` (e.g.
    ///     720×720, 720×1280). For Expression this is the legacy
    ///     `windowSide × windowHeight` (235×290).
    ///   - clipMode: `.circle` reproduces the legacy Expression
    ///     layout (avatar zone + status-pill zone, hosted via
    ///     `AvatarRootView` for the drag-drop / context menu /
    ///     crafting-spinner overlays). `.fill` (default) is Essence:
    ///     borderless resizable window, no SwiftUI overlay, the
    ///     renderer view is the content view directly.
    ///   - idleFrame: First CGImage shown before the FramePump's
    ///     consumer starts ticking.
    ///   - coordinator: Required for `.circle`, ignored / may be nil
    ///     for `.fill` (no UI in Essence references it).
    public init(
        targetSize: CGSize,
        clipMode: AvatarRendererView.ClipMode = .fill,
        idleFrame: CGImage? = nil,
        coordinator: AvatarCoordinator? = nil
    ) {
        let rect = NSRect(origin: .zero, size: targetSize)
        let view = AvatarRendererView(frame: rect, idleFrame: idleFrame, clipMode: clipMode)
        self.renderer = view
        self.coordinator = coordinator

        let styleMask: NSWindow.StyleMask
        switch clipMode {
        case .circle:
            // `.titled` is needed under the hood for `miniaturize(_:)`
            // to work (Halo's pattern); we hide the title bar visually
            // so the window still reads as a clean floating circle.
            // `.miniaturizable` enables Cmd-M.
            // `.closable` enables Cmd-W.
            // `.fullSizeContentView` lets the avatar fill the whole
            // frame including the (hidden) title bar area.
            styleMask = [.titled, .miniaturizable, .closable, .fullSizeContentView]
        case .fill:
            // Essence: borderless resizable window. No title bar, no
            // traffic-light buttons. The user can still grab any edge
            // to resize and drag-by-background to move (set below).
            styleMask = [.borderless, .resizable, .miniaturizable, .closable]
        }

        super.init(
            contentRect: rect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        self.title = "bitHuman"
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.level = .floating
        // Drag-by-background works for both modes: the circular
        // layout's whole frame is draggable; the rectangular Essence
        // window has no title bar to grab, so background drag is the
        // only way to reposition.
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.center()

        switch clipMode {
        case .circle:
            // Hide the three traffic-light buttons — they'd punch a
            // square hole in the top-left of the borderless circle.
            // Keyboard shortcuts (Cmd-M, Cmd-W) still work.
            self.standardWindowButton(.closeButton)?.isHidden = true
            self.standardWindowButton(.miniaturizeButton)?.isHidden = true
            self.standardWindowButton(.zoomButton)?.isHidden = true

            // SwiftUI host wraps the renderer so we can layer a
            // context menu, drag-drop overlay, and a crafting spinner
            // on top of the AppKit CALayer. NSHostingView sized to
            // the full window content rect. Coordinator is required
            // for this path — `init(idleFrame:coordinator:)` enforces
            // that statically; this `precondition` catches misuse via
            // the new init.
            precondition(
                coordinator != nil,
                "AvatarWindow with clipMode=.circle requires a coordinator"
            )
            let root = AvatarRootView(rendererView: view, coordinator: coordinator!)
            let host = NSHostingView(rootView: root)
            host.frame = rect
            host.autoresizingMask = [.width, .height]
            self.contentView = host
        case .fill:
            // Essence: skip the SwiftUI overlay entirely — no status
            // pill, no drag-drop, no context menu. We host the
            // renderer in a transparent container so a small close
            // button can sit in the top-right corner; without it, the
            // borderless window has no visible affordance to dismiss
            // (Cmd-Q works but isn't discoverable). The container's
            // `autoresizingMask` keeps the renderer pinned to bounds
            // through window resizes; the close button is anchored to
            // the top-right via its own resize mask.
            let container = NSView(frame: rect)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            view.frame = rect
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)

            let closeBtn = EssenceCloseButton()
            closeBtn.target = self
            closeBtn.action = #selector(NSWindow.performClose(_:))
            // Anchor top-right with an 8pt inset.
            let inset: CGFloat = 8
            closeBtn.frame = NSRect(
                x: rect.width - EssenceCloseButton.side - inset,
                y: rect.height - EssenceCloseButton.side - inset,
                width: EssenceCloseButton.side,
                height: EssenceCloseButton.side
            )
            closeBtn.autoresizingMask = [.minXMargin, .minYMargin]
            container.addSubview(closeBtn)

            self.contentView = container
        }

        self.acceptsMouseMovedEvents = false
    }

    /// Backwards-compatible Expression-circular convenience. Existing
    /// `BithumanMacApp` / `BithumanCLI` call sites continue to work
    /// unchanged — this thin wrapper forwards into the canonical init
    /// with the legacy 235×290 frame and `.circle` clip mode.
    public convenience init(idleFrame: CGImage?, coordinator: AvatarCoordinator) {
        self.init(
            targetSize: CGSize(width: Self.windowSide, height: Self.windowHeight),
            clipMode: .circle,
            idleFrame: idleFrame,
            coordinator: coordinator
        )
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func miniaturize(_ sender: Any?) {
        orderOut(sender)
    }

    public override func performClose(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    /// Hand the next CGImage frame to the renderer.
    public func render(_ frame: CGImage) {
        renderer.show(frame)
    }
}

/// `AvatarWindow` is the macOS sink for the FramePump. The protocol's
/// `render(_:)` requirement matches the existing method exactly, so
/// the conformance is trivial.
extension AvatarWindow: AvatarFrameSink {}

/// Translucent circular close button overlaid on the Essence
/// rectangular window. The borderless `.fill` window has no native
/// title bar, so without this the only way to dismiss it is Cmd-Q —
/// not discoverable for casual demo users. Sits in the top-right at
/// half opacity until hovered, then fully opaque (mirrors the iOS
/// system "Done" button affordance).
@MainActor
final class EssenceCloseButton: NSButton {
    static let side: CGFloat = 24

    private let trackingTagBox = NSObject()
    private var trackingArea: NSTrackingArea?
    private var hovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        isBordered = false
        title = ""
        wantsLayer = true
        // No system-supplied background; we draw a soft black disc in
        // `draw(_:)`. Opacity ramps from 0.45 → 0.85 on hover.
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = "Close (⌘Q)"
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        guard let ctx else { return }
        let alpha: CGFloat = hovered ? 0.85 : 0.45
        ctx.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
        ctx.fillEllipse(in: bounds)

        // White × glyph (line strokes) — 8 px from each edge so the
        // cross fits inside a 24 pt disc cleanly.
        let inset: CGFloat = 8
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: inset, y: inset))
        ctx.addLine(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset))
        ctx.move(to: CGPoint(x: bounds.width - inset, y: inset))
        ctx.addLine(to: CGPoint(x: inset, y: bounds.height - inset))
        ctx.strokePath()
    }
}

/// Build and install the standard application/window menus. Without
/// a main menu, AppKit silently drops keyboard shortcuts — that's why
/// Cmd-M / Cmd-Q / Cmd-W don't work in a bare CLI-bootstrapped app.
@MainActor
public func installMainMenu() {
    let mainMenu = NSMenu()

    // Application menu (the bold one with the app's name). The first
    // top-level menu item is canonically the application menu, even
    // if it's empty — AppKit auto-titles it after the binary.
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(
        title: "Quit bitHuman",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    ))
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    // Window menu — gives us standard Minimize / Close shortcuts.
    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(NSMenuItem(
        title: "Minimize",
        action: #selector(NSWindow.miniaturize(_:)),
        keyEquivalent: "m"
    ))
    let close = NSMenuItem(
        title: "Close",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )
    windowMenu.addItem(close)
    windowItem.submenu = windowMenu
    mainMenu.addItem(windowItem)
    NSApp.mainMenu = mainMenu
    NSApp.windowsMenu = windowMenu
}
#endif
