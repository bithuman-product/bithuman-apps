// MacOSStub.swift — placeholder `@main` for the macOS swift-build path.
//
// See `Apps/BithumanPad/Sources/MacOSStub.swift` for the rationale.
// `BithumanPhone` is iOS-only; on macOS hosts the real
// `BithumanPhoneApp` is gated out and SPM needs *some* `_main`
// symbol to link the executable. This stub provides one. Never run.

#if !canImport(UIKit)
@main
struct BithumanPhoneStub {
    static func main() {
        // Never invoked.
    }
}
#endif
