import Foundation

/// Bundled portraits the user can pick by name from the CLI:
///
///     bithuman-cli video --image Alice
///
/// Six starter faces (a quick selection from bitHuman's persona
/// catalogue, no IP-fragile likenesses). For anything else the user
/// supplies their own image with `--image /path/to/photo.jpg`.
public enum PortraitGallery {

    /// Canonical, case-sensitive preset names. The `--image` argv
    /// matcher is case-insensitive; this list is what shows up in
    /// the help text.
    public static let presetNames: [String] = [
        "Alice", "Marco", "Captain", "Nia", "Riley"
    ]

    /// Resolve a user-supplied `--image` argument to a bundled
    /// portrait URL, or `nil` if the argument doesn't match a
    /// preset (caller then treats it as a filesystem path).
    /// Case-insensitive — `Alice`, `alice`, `ALICE` all match.
    public static func presetURL(matching raw: String) -> URL? {
        let needle = raw.lowercased()
        guard presetNames.map({ $0.lowercased() }).contains(needle) else {
            return nil
        }
        // SPM `.process("Resources")` flattens the subdir into the
        // bundle root, so look up by name only — the `Portraits/`
        // dir is structural source-tree organisation, not a runtime
        // path.
        return Bundle.module.url(forResource: needle, withExtension: "jpg")
    }
}
