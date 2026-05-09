// Build-time-substituted bitHuman API key for the bundled CLI
// distribution. The literal `__BITHUMAN_EMBEDDED_KEY__` below is a
// placeholder; `release.sh` rewrites it with the actual key just
// before signing + notarising the binary, then restores the
// placeholder afterwards. This way:
//
//   - The committed source contains no real secret. `git log`,
//     `gh repo view`, and any source-code search return only the
//     placeholder.
//   - The compiled binary that ships in the Homebrew tap / DMG has
//     the key hard-coded as a string literal — accessible to
//     `bithuman-cli` at runtime without any user configuration.
//   - End users running the CLI never see the key (it's bytes in
//     the Mach-O binary; `strings` reveals it but no normal user
//     workflow exposes it).
//
// Developers integrating bitHumanKit into their own apps need
// their own key — they can't reuse the bundled one because they
// don't have the binary build pipeline that injects it.
//
// The `internal` visibility keeps this constant invisible to SDK
// consumers: only the BithumanCLI target (this file's owner) can
// reference it.
internal enum BithumanEmbeddedKey {

    /// The substituted key, or nil if the placeholder is still in
    /// place (development builds, source checkouts, CI without the
    /// release secret). Callers fall back to `BITHUMAN_API_KEY`
    /// env vars or whatever else they configure when this is nil.
    ///
    /// The placeholder check uses `hasPrefix` against a substring
    /// of the placeholder rather than full-string equality. This
    /// matters because the build script's sed pattern targets the
    /// exact quoted literal `"__BITHUMAN_EMBEDDED_KEY__"`, so a
    /// `==` check would also be rewritten. `hasPrefix` checks an
    /// unquoted prefix — sed leaves it untouched — and reliably
    /// distinguishes a real key (which won't start with the
    /// `__BITHUMAN_` namespace) from the placeholder.
    ///
    /// `@inline(never)` keeps the Swift optimizer from inlining
    /// the constant string into the (single) call site and then
    /// DCE'ing the symbol — observed on the SwiftUI Mac target
    /// where the resulting binary had no trace of the key. The
    /// CLI happens to survive inlining today, but the attribute
    /// is cheap insurance against the optimizer changing its mind.
    @inline(never)
    internal static var value: String? {
        let bundled = "__BITHUMAN_EMBEDDED_KEY__"
        if bundled.isEmpty || bundled.hasPrefix("__BITHUMAN_") {
            return nil
        }
        return bundled
    }
}
