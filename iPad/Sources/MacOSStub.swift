// MacOSStub.swift — placeholder `@main` for the macOS swift-build path.
//
// `BithumanPad` is an iOS / iPadOS executable. SPM builds it on macOS
// during `swift test` (because there's no per-target platform filter
// in Package.swift). When `canImport(UIKit)` is false the real
// `BithumanPadApp` entry point is gated out, leaving the linker
// without a `_main` symbol. This file supplies a no-op `@main` for
// that case so the package as a whole still compiles + links on
// macOS — the produced binary is never run, it's just there to keep
// the build graph green.
//
// On the iOS triple (`canImport(UIKit)` is true) this file is empty
// and `BithumanPadApp` is the real entry point.

#if !canImport(UIKit)
@main
struct BithumanPadStub {
    static func main() {
        // Never invoked. The macOS-side Mach-O exists only so SPM
        // can finish linking the Pad target during a `swift test`
        // run on macOS hosts.
    }
}
#endif
