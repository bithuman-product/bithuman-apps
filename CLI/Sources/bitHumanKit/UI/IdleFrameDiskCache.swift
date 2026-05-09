// Persistent JPEG cache for the idle-palindrome frame buffer.
//
// `FramePump.IdleFrameCache` populates 250 frames (10 s @ 25 FPS)
// during cold-start by calling the avatar engine's
// `generateIdleChunk` ~30 times — burns ~5–10 s of GPU on every
// launch with the same identity, just to produce frames that are
// (by design) deterministic for that engine + portrait pair. This
// helper persists the prewarmed frames after the first run so
// subsequent launches load them off disk in <1 s.
//
// **Identity hash** is over `(weightsURL, portraitURL?)` plus
// their mtime/size. Re-rendered when either changes (engine
// update, custom portrait swap). Stored under
// `~/Library/Application Support/com.bithuman.cli/idle-frames/<hash>/`.
//
// **Format** is JPEG via `CGImageDestination` (q=0.9 — visually
// indistinguishable from the original at avatar window sizes).
// 250 frames × ~50 KB each ≈ 12 MB per identity. Cheap.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IdleFrameDiskCache {

    /// Compute a stable identity hash from the engine `.imx` file
    /// path and an optional portrait. mtime+size catches "user
    /// re-extracted the .imx" / "user replaced the portrait" without
    /// a costly content-hash on multi-MB inputs.
    public static func identityKey(
        weightsURL: URL,
        portraitURL: URL?
    ) -> String {
        var fp = ""
        appendFingerprint(of: weightsURL, into: &fp)
        if let portraitURL {
            fp += "|"
            appendFingerprint(of: portraitURL, into: &fp)
        }
        let hash = SHA256.hash(data: Data(fp.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return hash
    }

    private static func appendFingerprint(of url: URL, into out: inout String) {
        let resolved = url.resolvingSymlinksInPath().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        out += "\(resolved)|\(Int(mtime))|\(size)"
    }

    /// Cache directory for `identityKey`. Created on demand.
    private static func directory(for identityKey: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.bithuman.cli", isDirectory: true)
            .appendingPathComponent("idle-frames", isDirectory: true)
            .appendingPathComponent(identityKey, isDirectory: true)
    }

    /// Load the previously-saved idle frames for `identityKey`.
    /// Returns nil when no cache exists yet, or when the saved
    /// frame count is below 80% of the target — better to
    /// regenerate than to ship a partial loop the user would see
    /// jump.
    public static func load(identityKey: String) -> [CGImage]? {
        let dir = directory(for: identityKey)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let entries = (try? FileManager.default
            .contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".jpg") }
            .sorted() ?? []
        guard entries.count >= 200 else { return nil }
        var frames: [CGImage] = []
        frames.reserveCapacity(entries.count)
        for name in entries {
            let url = dir.appendingPathComponent(name)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else { continue }
            frames.append(img)
        }
        return frames.isEmpty ? nil : frames
    }

    /// Persist `frames` under `identityKey`. Writes one JPEG per
    /// frame as `frame-NNN.jpg`. Atomic at the file level (each
    /// frame writes via tmp + rename) so a kill mid-save doesn't
    /// leave a half-good directory that masquerades as a cache hit.
    @discardableResult
    public static func save(_ frames: [CGImage], identityKey: String) -> Bool {
        let dir = directory(for: identityKey)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        let utType = UTType.jpeg.identifier as CFString
        for (i, frame) in frames.enumerated() {
            let url = dir.appendingPathComponent(String(format: "frame-%03d.jpg", i))
            guard let dst = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
                return false
            }
            let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
            CGImageDestinationAddImage(dst, frame, opts as CFDictionary)
            if !CGImageDestinationFinalize(dst) {
                return false
            }
        }
        return true
    }
}
