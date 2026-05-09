// SPDX-License-Identifier: Apache-2.0
//
// AgentDownloader — fetch + cache `.imx` files for both Expression
// and Essence agents, by URL.
//
// Same lifecycle pattern as `ExpressionWeights` (download once,
// checksum-validate, cache; subsequent calls hit disk). Where this
// differs: Expression weights are a single shared 1.56 GB universal
// artifact; Essence `.imx` files are per-agent, smaller (typically
// 50–100 MB), and the caller knows which agent to fetch by code or
// URL.
//
// Why URL-based (vs agent-code-based) for v0.18: the bithuman.ai
// agent-by-code resolution endpoint requires authentication today and
// hasn't been exposed publicly yet. To avoid coupling this framework
// to an unstable API, we accept a direct URL + expected SHA-256 from
// the caller. The app can build the URL however it wants — bundled
// agent catalog, fetched from the user's bithuman.ai dashboard, etc.
// A future release will add agent-code dispatch when the API
// stabilises.

import CryptoKit
import Foundation

/// Phase signal for download progress.
public enum AgentDownloadPhase: Sendable {
    /// Cache lookup succeeded — file already on disk and checksum
    /// validated. No network involved.
    case cached(URL)
    /// HEAD request resolved size (or `nil` if the server didn't
    /// advertise `Content-Length`).
    case starting(expectedBytes: Int64?)
    /// Streaming download in progress.
    case progress(bytesReceived: Int64, totalBytes: Int64?)
    /// Download finished, checksum validating.
    case validating
    /// All done.
    case ready(URL)
}

/// Errors the downloader can raise.
public enum AgentDownloadError: LocalizedError {
    /// HTTP returned a non-2xx response.
    case httpError(statusCode: Int)
    /// Downloaded bytes didn't match `expectedSHA256`. The corrupt
    /// file is removed before throwing.
    case checksumMismatch(expected: String, got: String)
    /// The destination directory could not be created or written.
    case ioError(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "AgentDownloader: HTTP \(code) fetching agent .imx"
        case .checksumMismatch(let expected, let got):
            return "AgentDownloader: SHA-256 mismatch — expected \(expected), got \(got)"
        case .ioError(let err):
            return "AgentDownloader: IO error — \(err)"
        }
    }
}

/// Downloads + caches `.imx` agent bundles. Stateless; safe to call
/// from any actor.
public enum AgentDownloader {

    /// Default cache directory: `~/Library/Caches/com.bithuman.agents/`
    /// on Apple platforms. Created lazily on first use.
    ///
    /// Apps that want a different layout (e.g., a Documents-folder
    /// cache so the user can manage them via Files.app) pass an
    /// explicit `to:` parameter to ``ensureAvailable(url:expectedSHA256:to:filename:progress:)``.
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.bithuman.agents", isDirectory: true)
    }

    /// Fetch `.imx` from `url`, cache to `to`, validate checksum,
    /// return the local URL.
    ///
    /// - Parameters:
    ///   - url: Direct download URL for the `.imx` payload.
    ///   - expectedSHA256: SHA-256 hex string the downloaded file
    ///     must match. Pass `nil` to skip validation (only do this
    ///     for development — production should always pin a hash).
    ///   - cacheDirectory: Where to store the file. Defaults to
    ///     ``defaultCacheDirectory``.
    ///   - filename: Filename inside `cacheDirectory`. Defaults to
    ///     the URL's last path component.
    ///   - progress: Optional callback fired on `AgentDownloadPhase`
    ///     transitions. Called on an arbitrary queue.
    ///
    /// - Returns: Local file URL with validated content.
    /// - Throws: `AgentDownloadError` on HTTP / checksum / IO failure.
    public static func ensureAvailable(
        url: URL,
        expectedSHA256: String? = nil,
        cacheDirectory: URL? = nil,
        filename: String? = nil,
        progress: (@Sendable (AgentDownloadPhase) -> Void)? = nil
    ) async throws -> URL {
        let cacheDir = cacheDirectory ?? defaultCacheDirectory
        let name = filename ?? url.lastPathComponent
        let dest = cacheDir.appendingPathComponent(name, isDirectory: false)

        try createDirectoryIfNeeded(cacheDir)

        // Cache hit: file present and (if pinned) checksum matches.
        if FileManager.default.fileExists(atPath: dest.path) {
            if let expected = expectedSHA256 {
                if try sha256(of: dest).lowercased() == expected.lowercased() {
                    progress?(.cached(dest))
                    return dest
                }
                // Mismatch: a partial / corrupted prior download.
                // Remove and re-fetch.
                try? FileManager.default.removeItem(at: dest)
            } else {
                progress?(.cached(dest))
                return dest
            }
        }

        // Probe size (best-effort — some CDNs strip Content-Length on
        // HEAD; the streaming path also surfaces total bytes when
        // available).
        let expectedBytes: Int64? = await probeContentLength(url: url)
        progress?(.starting(expectedBytes: expectedBytes))

        // Stream to a temp file first so a network mid-download abort
        // doesn't leave a half-good file at the cache name.
        let tmp = dest.appendingPathExtension("part-\(UUID().uuidString)")
        do {
            try await streamDownload(
                url: url, to: tmp, expectedBytes: expectedBytes, progress: progress
            )
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }

        // Validate.
        progress?(.validating)
        if let expected = expectedSHA256 {
            let got = try sha256(of: tmp).lowercased()
            if got != expected.lowercased() {
                try? FileManager.default.removeItem(at: tmp)
                throw AgentDownloadError.checksumMismatch(
                    expected: expected.lowercased(),
                    got: got
                )
            }
        }

        // Move into place atomically.
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw AgentDownloadError.ioError(underlying: error)
        }

        progress?(.ready(dest))
        return dest
    }

    // MARK: - Helpers

    private static func createDirectoryIfNeeded(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true
                )
            } catch {
                throw AgentDownloadError.ioError(underlying: error)
            }
        }
    }

    private static func probeContentLength(url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let len = http.value(forHTTPHeaderField: "Content-Length"),
               let bytes = Int64(len) {
                return bytes
            }
        } catch {
            // Best-effort: nil means caller falls back to streaming
            // without a known total.
        }
        return nil
    }

    private static func streamDownload(
        url: URL,
        to dest: URL,
        expectedBytes: Int64?,
        progress: (@Sendable (AgentDownloadPhase) -> Void)?
    ) async throws {
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw AgentDownloadError.httpError(statusCode: http.statusCode)
        }

        // Open the destination for writing.
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: dest) else {
            throw AgentDownloadError.ioError(
                underlying: NSError(
                    domain: "AgentDownloader", code: -1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "could not open \(dest.path) for writing"
                    ]
                )
            )
        }
        defer { try? handle.close() }

        // Buffer in 256 KB chunks to keep `progress` callbacks at a
        // human-perceptible rate even on fast networks. (Per-byte
        // callbacks at 1 Gbps would fire 1B+ times per second.)
        let chunkSize = 256 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var received: Int64 = 0
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                handle.write(buffer)
                received &+= Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(.progress(bytesReceived: received, totalBytes: expectedBytes))
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
            received &+= Int64(buffer.count)
            progress?(.progress(bytesReceived: received, totalBytes: expectedBytes))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        // Stream the file rather than loading into RAM — `.imx`
        // bundles can be hundreds of MB and we don't want a peak
        // allocation spike just for the checksum.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
