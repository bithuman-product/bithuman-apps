import CoreML
import Foundation

/// Persistent cache for the `.mlpackage → .mlmodelc` compile step.
///
/// `MLModel.compileModel(at:)` is documented as a one-time operation,
/// but Apple's API returns the compiled artifact in a fresh
/// `NSTemporaryDirectory()` subdirectory on every call — so the
/// returned `mlmodelc` path is brand-new each launch, the file is
/// gone after the next macOS temp-dir purge, and ANED's compiled-
/// shader cache (which keys on the mlmodelc path) misses every time.
/// Net effect: every cold start triggers the full multi-minute ANE
/// shader recompile, even though the source weights haven't changed.
///
/// This helper compiles once and stores the result alongside the
/// source `.mlpackage` (e.g., `…/turbo_vaed_ane_384.mlmodelc/` next
/// to `…/turbo_vaed_ane_384.mlpackage/`). Subsequent launches detect
/// the cached `mlmodelc`, skip the compile, and ANED reuses its
/// shader cache because the path is byte-identical.
///
/// Cache invalidation: we read the source `.mlpackage`'s modification
/// date and store it in a sentinel file inside the cached
/// `mlmodelc`. If the package's mtime changes (re-extracted from a
/// new `.imx`, or the user upgraded the SDK and re-downloaded
/// weights), we discard the stale cache and recompile.
internal enum ANECoreMLCache {

    /// Cache key sentinel embedded in the compiled directory so we
    /// know when to invalidate.
    private static let sentinelFilename = ".bithuman-source-mtime"

    /// Return a stable mlmodelc URL for the given source. If a valid
    /// cache exists, we return that path directly. Otherwise we
    /// compile the source, copy the result into the cache slot, and
    /// return the cached path.
    static func compiledMLModelC(forPackageAt source: URL) throws -> URL {
        let path = source.path

        // Already compiled — caller passed an mlmodelc directly.
        if path.hasSuffix(".mlmodelc") {
            return source
        }

        // Derive the sibling cache slot. `foo.mlpackage` →
        // `foo.mlmodelc` next to it. Lives inside the same stable
        // extraction directory the `.imx` was unpacked into, so it
        // survives across launches just like the weights themselves.
        let cachedURL = source
            .deletingPathExtension()
            .appendingPathExtension("mlmodelc")

        // Cache hit if (a) the directory exists and (b) the recorded
        // source mtime matches. Otherwise nuke and recompile.
        let sourceMtime = (try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0

        if FileManager.default.fileExists(atPath: cachedURL.path) {
            let sentinelURL = cachedURL.appendingPathComponent(sentinelFilename)
            if let stored = try? String(contentsOf: sentinelURL),
               let storedMtime = TimeInterval(stored.trimmingCharacters(in: .whitespacesAndNewlines)),
               abs(storedMtime - sourceMtime) < 1.0 {
                return cachedURL
            }
            // Stale cache — fall through and recompile.
            try? FileManager.default.removeItem(at: cachedURL)
        }

        // Compile (multi-second on warm Apple Silicon). The first
        // launch after upgrade pays this cost once; subsequent
        // launches hit the cached path above.
        let tempCompiled = try MLModel.compileModel(at: source)

        // Move the compiled artifact into the cache slot. `moveItem`
        // is atomic on the same volume; if MLModel.compileModel chose
        // a different volume (rare), fall back to copy.
        do {
            try FileManager.default.moveItem(at: tempCompiled, to: cachedURL)
        } catch {
            try? FileManager.default.removeItem(at: cachedURL)
            try FileManager.default.copyItem(at: tempCompiled, to: cachedURL)
            try? FileManager.default.removeItem(at: tempCompiled)
        }

        // Stamp the source mtime so the next launch can validate.
        let sentinelURL = cachedURL.appendingPathComponent(sentinelFilename)
        try? "\(sourceMtime)".write(to: sentinelURL, atomically: true, encoding: .utf8)

        return cachedURL
    }
}
