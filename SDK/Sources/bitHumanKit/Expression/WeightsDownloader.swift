import CryptoKit
import Foundation

/// Phases the UI surfaces while resolving the expression weights.
/// Emitted via the `progress` closure on
/// ``ExpressionWeights/ensureAvailable(progress:)`` so iPad / iPhone
/// loading screens can show a real progress bar with bytes, speed,
/// and ETA — not just a "loading…" animation.
public enum DownloadPhase: Sendable, Equatable {
    /// Hashing a previously cached file before handing it to the engine.
    case verifying
    /// Streaming bytes from the CDN. `bytesPerSecond` is a 0.7/0.3
    /// EMA over 0.5 s windows. `etaSeconds` is nil only at the very
    /// first sample, before we have a rate.
    case downloading(
        fractionComplete: Double,
        bytesDownloaded: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double,
        etaSeconds: Double?
    )
    /// Download finished, sha256 still being verified.
    case verifyingDownloaded
    /// Cached + verified; the engine can load.
    case ready
}

/// Resolve / download / verify the expression engine `.bhx` weights
/// file. Single-purpose helper called from `bithuman-cli video` boot:
/// returns a local URL the engine can hand to `Bithuman.create`,
/// downloading if it's not on disk and verifying sha256 either way.
///
/// On-disk layout:
///
///     ~/.cache/bithuman/expression/expression-engine-1.0-int4.bhx
///
/// (Versioned filename so a future v1.1 can coexist with v1.0 during
/// rollout; the constant below is the only place the version lives.)
public enum ExpressionWeights {

    /// CDN URL for the canonical universal expression weights.
    ///
    /// Single shared artifact across iOS / iPadOS / macOS — the int4
    /// pre-quantized .bhx (DiT + Wav2Vec2 transformer Linears baked at
    /// int4 groupSize=64). At quality parity with runtime fp16+int4
    /// (PSNR > 60 dB / SSIM > 0.999) and ~63% smaller download. macOS
    /// has the GPU headroom to run fp16, but staying on int4 keeps
    /// the build matrix simple and shaves a couple of seconds off
    /// load time for everyone.
    ///
    /// Produced by `scripts/prequant_imx.py` from the upstream
    /// fp16 expression bundle.
    public static let remoteURL = URL(
        string: "https://pub-55f7db09b40d46e8a22a70ff6d49aeff.r2.dev/models/expression-384-int4.bhx"
    )!

    /// Expected SHA-256 of `remoteURL`'s content. Verified after
    /// download; mismatched bytes are deleted and the call throws.
    /// Update this string whenever `prequant_imx.py` is re-run + the
    /// file is re-uploaded.
    public static let expectedSHA256 = "419286d0bee1d7b7172378b45389cbc29f75567715e0c5e77bbce59a58be6bba"

    /// Approximate size for progress messaging — actual size is
    /// taken from the HTTP `Content-Length` at download time.
    public static let approximateBytes: Int64 = 1_560_000_000

    /// Local filename. The `.bhx` extension marks "pre-quantized
    /// universal engine artifact" — distinct from the per-identity
    /// `.imx` files the Python `bithuman pack` tool produces.
    /// Versioned so future engine releases can coexist on disk
    /// during rollout.
    public static let localFilename = "expression-engine-1.0-int4.bhx"

    /// Final on-disk path for the verified weights. Public so callers
    /// (and future maintenance commands like `bithuman-cli doctor`) can
    /// surface the location without re-implementing the path logic.
    public static var localURL: URL {
        cacheDirectory.appendingPathComponent(localFilename)
    }

    private static var cacheDirectory: URL {
        // macOS uses the Unix-style ~/.cache/ that other Apple-Silicon
        // tooling has trained users to expect (mlx-swift uses
        // ~/.cache/huggingface/hub/, etc.). iOS sandboxes us into the
        // app's container; Application Support/bithuman/expression/ is
        // the canonical location for downloaded model weights and is
        // exempt from "purgeable" backup.
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("bithuman", isDirectory: true)
            .appendingPathComponent("expression", isDirectory: true)
        #else
        // iOS 16+ has the typed URL accessors; iOS 26 is our floor.
        return URL.applicationSupportDirectory
            .appending(path: "bithuman", directoryHint: .isDirectory)
            .appending(path: "expression", directoryHint: .isDirectory)
        #endif
    }

    /// Resolve to a local file path that's guaranteed to exist and
    /// pass the sha256 check. If the file's already cached and valid,
    /// returns immediately. Otherwise streams it down from `remoteURL`,
    /// printing a progress line to stderr AND emitting structured
    /// `DownloadPhase` events through the optional `progress` closure
    /// so app UIs can render a real progress bar.
    ///
    /// The closure is called from a background async context. Hop to
    /// the main actor inside it if you're updating `@Published` state.
    ///
    /// Throws ``WeightsError`` on network / disk / verify failures.
    /// Caller is responsible for any UI before / after the download
    /// (e.g. a banner reminding users it's a one-time 3.7 GB pull).
    public static func ensureAvailable(
        progress: (@Sendable (DownloadPhase) -> Void)? = nil,
        silenceStderr: Bool = false
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true
        )

        // Purge any older cached engine artifacts (e.g. previous-
        // generation `expression-engine-1.0.bit` after we migrate to
        // `-int4.bhx`). Without this an app upgrading from a prior
        // build leaves multi-GB of dead weights on the device.
        purgeOldCachedEngines(keeping: localFilename)

        // `silenceStderr` is set by callers that own the boot UI
        // (e.g., bithuman-cli with a `BootProgress` renderer); they
        // present progress through their own surface and the legacy
        // stderr lines would otherwise paint over them. The progress
        // closure ALWAYS fires regardless, so iOS apps reading
        // `DownloadPhase` directly are unaffected.
        let log: (String) -> Void = silenceStderr ? { _ in } : { stderr($0) }

        let final = localURL
        if FileManager.default.fileExists(atPath: final.path) {
            // File is on disk — verify before handing it to the
            // engine. A corrupted .bhx (interrupted previous run,
            // disk error, transit damage) crashes the MLX loader
            // with a far less actionable error than a clean
            // "redownload required" message here.
            log("🔍 verifying cached expression weights…")
            progress?(.verifying)
            if try await sha256(of: final) == expectedSHA256 {
                log(" ✓ ok\n")
                progress?(.ready)
                return final
            }
            log(" ✗ checksum mismatch — redownloading.\n")
            try? FileManager.default.removeItem(at: final)
        }

        let partial = final.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)

        log("""
            📥 first-run: downloading expression engine (~3.7 GB) from
               \(remoteURL.host ?? "bitHuman CDN") to
               \(final.path)
               This is a one-time pull. Resume on rerun if interrupted.

            """)
        try await streamDownload(
            from: remoteURL, to: partial,
            progress: progress, silenceStderr: silenceStderr
        )

        log("🔍 verifying expression engine sha256…")
        progress?(.verifyingDownloaded)
        let actual = try await sha256(of: partial)
        if actual != expectedSHA256 {
            try? FileManager.default.removeItem(at: partial)
            log(" ✗\n")
            throw WeightsError.checksumMismatch(expected: expectedSHA256, actual: actual)
        }
        log(" ✓ ok\n")

        try FileManager.default.moveItem(at: partial, to: final)
        progress?(.ready)
        return final
    }

    /// Delete any cached engine artifacts in the cache directory that
    /// don't match the current `localFilename`. Called once at the
    /// top of `ensureAvailable` so an app upgrading from a previous
    /// engine version (or the fp16 build) doesn't leave multi-GB
    /// stale weights stranded on disk.
    private static func purgeOldCachedEngines(keeping currentName: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
        for entry in entries {
            // Match the same `expression-engine-*.{bit,bhx,imx}`
            // family the app has historically written; skip the
            // current artifact, partial download, and unrelated files.
            guard entry.hasPrefix("expression-engine-"),
                  entry != currentName,
                  entry != currentName + ".partial"
            else { continue }
            let lower = entry.lowercased()
            guard lower.hasSuffix(".bit") || lower.hasSuffix(".bhx") || lower.hasSuffix(".imx") || lower.hasSuffix(".partial")
            else { continue }
            let url = cacheDirectory.appendingPathComponent(entry)
            try? fm.removeItem(at: url)
            stderr("🧹 purged stale cached engine: \(entry)\n")
        }
    }

    // MARK: - Download

    private static func streamDownload(
        from remote: URL,
        to dest: URL,
        progress: (@Sendable (DownloadPhase) -> Void)?,
        silenceStderr: Bool
    ) async throws {
        let session = URLSession(configuration: .default)
        let (bytesStream, response) = try await session.bytes(from: remote)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WeightsError.httpStatus(code: code, url: remote)
        }
        let total = http.expectedContentLength > 0
            ? http.expectedContentLength
            : approximateBytes

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)  // 1 MiB scratch
        var lastReportedPercent: Int = -1
        var lastReportedTime = Date()

        // Speed/ETA accounting — sample every 0.5 s and feed an EMA
        // so the displayed rate doesn't whip around with TCP burstiness.
        let sampleStart = Date()
        var lastSampleTime = sampleStart
        var lastSampleBytes: Int64 = 0
        var bytesPerSecond: Double = 0

        for try await byte in bytesStream {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {  // flush every MiB
                try handle.write(contentsOf: buffer)
                written &+= Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let now = Date()
                let dt = now.timeIntervalSince(lastSampleTime)
                if dt >= 0.5 {
                    let dBytes = Double(written - lastSampleBytes)
                    let instant = dBytes / dt
                    bytesPerSecond = bytesPerSecond == 0
                        ? instant
                        : 0.7 * bytesPerSecond + 0.3 * instant
                    lastSampleBytes = written
                    lastSampleTime = now

                    let frac = Double(written) / Double(total)
                    let remaining = Double(total - written)
                    let eta: Double? = bytesPerSecond > 0 ? remaining / bytesPerSecond : nil
                    progress?(.downloading(
                        fractionComplete: frac,
                        bytesDownloaded: written,
                        totalBytes: total,
                        bytesPerSecond: bytesPerSecond,
                        etaSeconds: eta
                    ))
                }

                // Throttle stderr to once per second OR per percent —
                // fast pipes would otherwise spam stderr 1000+ times.
                let pct = Int((Double(written) / Double(total)) * 100)
                if pct != lastReportedPercent && now.timeIntervalSince(lastReportedTime) > 1.0 {
                    let mb = Double(written) / 1_048_576
                    let totalMb = Double(total) / 1_048_576
                    if !silenceStderr {
                        stderr("\r📥 \(pct)%  (\(String(format: "%.0f", mb)) / \(String(format: "%.0f", totalMb)) MiB)  ")
                    }
                    lastReportedPercent = pct
                    lastReportedTime = now
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written &+= Int64(buffer.count)
        }
        if !silenceStderr {
            stderr("\r📥 100%  download complete (\(String(format: "%.0f", Double(written) / 1_048_576)) MiB)\n")
        }
        progress?(.downloading(
            fractionComplete: 1.0,
            bytesDownloaded: written,
            totalBytes: total,
            bytesPerSecond: bytesPerSecond,
            etaSeconds: 0
        ))
    }

    // MARK: - SHA-256

    private static func sha256(of url: URL) async throws -> String {
        // Hash on a background queue — a 3.7 GB read on the calling
        // queue would block whatever's awaiting it for several
        // seconds. Hop off, hop back when done.
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while autoreleasepool(invoking: { () -> Bool in
                let chunk = handle.readData(ofLength: 4 << 20)  // 4 MiB
                if chunk.isEmpty { return false }
                hasher.update(data: chunk)
                return true
            }) { }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    // MARK: - stderr helper

    private static func stderr(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}

public enum WeightsError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case httpStatus(code: Int, url: URL)
    case checksumMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .httpStatus(let code, let url):
            return "expression weights download failed (HTTP \(code) from \(url.absoluteString))"
        case .checksumMismatch(let expected, let actual):
            return """
                expression weights sha256 mismatch.
                  expected: \(expected)
                  actual:   \(actual)
                Re-run `bithuman-cli video` to retry the download.
                """
        }
    }
    public var errorDescription: String? { description }
}
