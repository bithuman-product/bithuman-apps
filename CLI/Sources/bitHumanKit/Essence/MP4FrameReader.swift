import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Immutable, shareable storage for the JPEG-encoded frames extracted
/// from an Essence container's MP4. Built once during fixture load and
/// then handed to one or many `MP4FrameReader` instances. Every field
/// is read-only after init; sharing the same storage across multiple
/// runtime instances saves the JPEG archive (~18 MB on the demo
/// fixture) per additional instance.
///
/// `[Data]` is value-type but uses CoW under the hood — the per-frame
/// JPEG `Data` instances are reference-counted and `let`-pinned, so
/// multiple readers reading from the same `[Data]` slot get exactly
/// the same backing buffer with no copy.
final class MP4FrameStorage: @unchecked Sendable {
    /// JPEG-encoded MP4 frames, indexed 0..<frameCount. Encoded once
    /// at fixture load (q=0.92, ~80–150 KB / frame). Stay-resident
    /// for the lifetime of the storage.
    let jpegFrames: [Data]
    /// Output `(width, height)` of frames decoded from `jpegFrames`.
    /// May differ from the MP4 track's natural size — when a fixture
    /// is loaded with a `preferredOutputSize` hint, AVAssetReader's
    /// hardware scaler produced buffers at that size during decode.
    let bgrFrameSize: (width: Int, height: Int)
    let frameCount: Int
    let resolution: (width: Int, height: Int)
    let frameRate: Double

    init(
        jpegFrames: [Data],
        bgrFrameSize: (width: Int, height: Int),
        frameCount: Int,
        resolution: (width: Int, height: Int),
        frameRate: Double
    ) {
        self.jpegFrames = jpegFrames
        self.bgrFrameSize = bgrFrameSize
        self.frameCount = frameCount
        self.resolution = resolution
        self.frameRate = frameRate
    }

    /// Approximate on-heap byte count of the JPEG archive. Used by the
    /// memory audit (per-fixture cost; doesn't include the per-instance
    /// LRU).
    func _archiveBytes() -> Int {
        var sum = 0
        for j in jpegFrames { sum &+= j.count }
        return sum
    }
}

/// Random-access frame reader for the H.264 MP4 stored inside an
/// Essence `.imx v2` container.
///
/// The reader owns:
///   - a strong ref to an immutable `MP4FrameStorage` (the JPEG
///     archive + frame metadata); shareable across instances
///   - a small per-instance LRU of decoded BGR buffers + a background
///     prefetch queue (NOT shareable — the prefetch hints are driven
///     by the caller's ping-pong walker, which is per-runtime state)
///
/// **Frame indexing.** Per `docs/architecture/essence-algorithm-spec.md`
/// §4, MP4 frames are at exactly 25 FPS and indexed from 0.
///
/// **Output.** `extractFrame(at:)` returns a `CGImage`; downstream
/// `ImageOps` converts to uint8 BGR bytes for the lip-patch
/// composition pipeline. The hot path (`extractFrameBGR(at:)`) skips
/// the CGImage round-trip and returns BGR uint8 bytes directly.
final class MP4FrameReader {

    enum Error: Swift.Error, CustomStringConvertible {
        case mp4EntryMissing(name: String)
        case noVideoTrack
        case generatorFailed(index: Int, underlying: Swift.Error)
        case indexOutOfRange(index: Int, frameCount: Int)

        var description: String {
            switch self {
            case .mp4EntryMissing(let name):
                return "MP4FrameReader: container has no entry named \"\(name)\""
            case .noVideoTrack:
                return "MP4FrameReader: MP4 has no video track"
            case .generatorFailed(let i, let e):
                return "MP4FrameReader: AVAssetImageGenerator failed at frame \(i) — \(e)"
            case .indexOutOfRange(let i, let fc):
                return "MP4FrameReader: frame index \(i) out of range [0, \(fc))"
            }
        }
    }

    /// Holds the temp-file URL and removes it from disk on deinit.
    /// Wrapping the path in a class lets the init body scope the
    /// lifetime of the extracted file via ARC: once init returns,
    /// no outer reference holds it and the temp file is deleted.
    fileprivate final class _TempFile {
        let url: URL
        init(url: URL) { self.url = url }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    // ─── Per-fixture, immutable (shared) ──────────────────────────
    /// Immutable JPEG archive + frame metadata. Shared across all
    /// readers built from the same fixture.
    let storage: MP4FrameStorage

    /// `(width, height)` of the BGR buffers returned by
    /// `extractFrameBGR(at:)`. Tracks `storage.bgrFrameSize`; can be
    /// overridden per-instance via `preResize(to:height:)` (legacy
    /// hint, mostly a no-op now that AVAssetReader's hardware scaler
    /// produces buffers at the manifest's frame_wh during decode).
    private(set) var bgrFrameSize: (width: Int, height: Int)
    var frameCount: Int { storage.frameCount }
    var resolution: (width: Int, height: Int) { storage.resolution }

    // ─── Per-instance, mutable ─────────────────────────────────────
    private var jpegLRU: [Int: [UInt8]] = [:]
    private var jpegRecency: [Int] = []
    private let jpegCap: Int = 4
    private let jpegLock = NSLock()
    private let prefetchQueue: DispatchQueue
    private var prefetchInFlight: Set<Int> = []

    /// Cold-load init — extracts the named MP4 from `container`, decodes
    /// every frame via AVAssetReader, JPEG-encodes them in batches, and
    /// hands the resulting archive to a new `MP4FrameStorage`. Heavy
    /// (~1.5–3 s on a 200-frame fixture); use the shared-fixture path
    /// (`init(sharing:)`) for additional instances.
    convenience init(
        container: ImxContainer,
        mp4EntryName: String,
        preferredOutputSize: (width: Int, height: Int)? = nil
    ) throws {
        let storage = try MP4FrameReader.buildStorage(
            container: container,
            mp4EntryName: mp4EntryName,
            preferredOutputSize: preferredOutputSize
        )
        self.init(sharing: storage)
    }

    /// Lightweight init from existing shared storage. Allocates only
    /// the per-instance LRU + prefetch queue; the JPEG archive is
    /// pinned by the caller's `MP4FrameStorage` reference.
    init(sharing storage: MP4FrameStorage) {
        self.storage = storage
        self.bgrFrameSize = storage.bgrFrameSize
        self.prefetchQueue = DispatchQueue(
            label: "ai.bithuman.mp4-prefetch", qos: .userInitiated
        )
    }

    /// Heavy decode path — runs once per fixture. Extracted as a static
    /// helper so the convenience `init(container:...)` and the public
    /// `EssenceFixture.load(...)` factory share one implementation.
    static func buildStorage(
        container: ImxContainer,
        mp4EntryName: String,
        preferredOutputSize: (width: Int, height: Int)? = nil
    ) throws -> MP4FrameStorage {
        guard container.hasFile(mp4EntryName) else {
            throw Error.mp4EntryMissing(name: mp4EntryName)
        }

        // Extract the MP4 to a unique temp file. The .imx itself is
        // a valid random-access blob, but AVAsset wants a real URL
        // (or a custom resource loader, which is the Phase 2 path).
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpURL = tmpDir.appendingPathComponent(
            "bithuman-mp4-\(UUID().uuidString).mp4"
        )
        try container.extractFile(mp4EntryName, to: tmpURL)
        let tempFile = _TempFile(url: tmpURL)

        let asset = AVURLAsset(url: tmpURL)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw Error.noVideoTrack
        }

        let nominalRate = Double(track.nominalFrameRate)
        if abs(nominalRate - 25.0) > 0.01 {
            FileHandle.standardError.write(
                "[MP4FrameReader] warning: track.nominalFrameRate=\(nominalRate), expected 25\n"
                    .data(using: .utf8) ?? Data()
            )
        }
        let rate = nominalRate > 0 ? nominalRate : 25.0
        let durationSeconds = track.timeRange.duration.seconds
        var frameCount = Int((durationSeconds * rate).rounded())

        let nat = track.naturalSize
        let resolution = (
            width: Int(nat.width.rounded()),
            height: Int(nat.height.rounded())
        )

        // --- Pre-decode every frame to JPEG via AVAssetReader -------------
        // AVAssetReader walks the GOP linearly, so we pay the H.264
        // decode cost ONCE for the whole clip. Output format is
        // 32BGRA so we get pre-aligned byte order; the strip pass
        // drops the alpha byte to leave tightly-packed BGR uint8.
        //
        // When `preferredOutputSize` is supplied (typically the
        // manifest's frame_wh), VideoToolbox's hardware scaler runs
        // the resize during decode (overlapped with H.264 work), so
        // the buffers come out at compose space directly.
        var outSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA,
        ]
        if let size = preferredOutputSize, size.width > 0, size.height > 0 {
            outSettings[kCVPixelBufferWidthKey as String] = size.width
            outSettings[kCVPixelBufferHeightKey as String] = size.height
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw Error.noVideoTrack
        }
        guard reader.canAdd(trackOutput) else { throw Error.noVideoTrack }
        reader.add(trackOutput)
        guard reader.startReading() else { throw Error.noVideoTrack }

        let nW = preferredOutputSize?.width ?? Int(nat.width.rounded())
        let nH = preferredOutputSize?.height ?? Int(nat.height.rounded())

        var inlineJpegs: [Data] = []
        inlineJpegs.reserveCapacity(frameCount)
        // Batch size 8 → ~21 MB peak buffer for raw frames during
        // encoding (8 × 2.6 MB). Empirically a sweet spot on M5:
        // encodes 8 frames in parallel in ~6 ms wall (vs 30 ms
        // sequential), so the loop's net cost is ~1 ms per frame
        // vs ~3 ms.
        let encodeBatchSize: Int = 8
        var pendingBatch: [[UInt8]] = []
        pendingBatch.reserveCapacity(encodeBatchSize)
        while let sample = trackOutput.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
            let src = base.assumingMemoryBound(to: UInt8.self)
            // BGRA → BGR: drop the trailing alpha byte per pixel.
            var bgr = [UInt8](repeating: 0, count: w * h * 3)
            bgr.withUnsafeMutableBufferPointer { dp in
                guard let dst = dp.baseAddress else { return }
                for y in 0..<h {
                    let s = src.advanced(by: y * stride)
                    let d = dst.advanced(by: y * w * 3)
                    for x in 0..<w {
                        d[x * 3 + 0] = s[x * 4 + 0]  // B
                        d[x * 3 + 1] = s[x * 4 + 1]  // G
                        d[x * 3 + 2] = s[x * 4 + 2]  // R
                    }
                }
            }
            // Defensive: if a frame's reported size differs from the
            // hint size (very rare; mid-stream resolution switches),
            // bilinear-resize. Common case is a no-op.
            if w != nW || h != nH {
                bgr = EssenceImageOps.bilinearResizeBGR(
                    src: bgr, srcW: w, srcH: h, dstW: nW, dstH: nH
                )
            }
            pendingBatch.append(bgr)
            if pendingBatch.count >= encodeBatchSize {
                encodeBatch(pendingBatch, w: nW, h: nH,
                            quality: 0.92, into: &inlineJpegs)
                pendingBatch.removeAll(keepingCapacity: true)
            }
        }
        if !pendingBatch.isEmpty {
            encodeBatch(pendingBatch, w: nW, h: nH,
                        quality: 0.92, into: &inlineJpegs)
            pendingBatch.removeAll(keepingCapacity: false)
        }
        if reader.status == .failed {
            throw Error.generatorFailed(
                index: inlineJpegs.count,
                underlying: reader.error ?? NSError(
                    domain: "MP4FrameReader", code: -1, userInfo: nil
                )
            )
        }
        // Some MP4s report a duration that's off-by-one vs the actual
        // sample count (FP rounding); align to what we actually decoded.
        if inlineJpegs.count != frameCount {
            frameCount = inlineJpegs.count
        }

        // tempFile drops out of scope here; its deinit removes the
        // temp .mp4 from disk. AVURLAsset / AVAssetReader retain it
        // until they're released along with this stack frame.
        _ = tempFile
        _ = asset
        _ = reader

        return MP4FrameStorage(
            jpegFrames: inlineJpegs,
            bgrFrameSize: (nW, nH),
            frameCount: frameCount,
            resolution: resolution,
            frameRate: rate
        )
    }

    /// Parallel-encode a small batch of decoded BGR frames to JPEG
    /// and append in-order to `output`.
    private static func encodeBatch(
        _ batch: [[UInt8]], w: Int, h: Int, quality: Double,
        into output: inout [Data]
    ) {
        var slots = [Data?](repeating: nil, count: batch.count)
        slots.withUnsafeMutableBufferPointer { sp in
            let ptr = sp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                ptr[i] = encodeBGRtoJPEG(batch[i], w: w, h: h, quality: quality)
            }
        }
        for slot in slots { if let j = slot { output.append(j) } }
    }

    /// Encode a tightly-packed BGR888 buffer to JPEG via ImageIO.
    private static func encodeBGRtoJPEG(
        _ bgr: [UInt8], w: Int, h: Int, quality: Double
    ) -> Data? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 3
        var rgb = [UInt8](repeating: 0, count: bytesPerRow * h)
        let permErr: vImage_Error = bgr.withUnsafeBufferPointer { sp in
            rgb.withUnsafeMutableBufferPointer { dp in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: sp.baseAddress!),
                    height: vImagePixelCount(h), width: vImagePixelCount(w),
                    rowBytes: bytesPerRow)
                var dstBuf = vImage_Buffer(
                    data: dp.baseAddress, height: vImagePixelCount(h),
                    width: vImagePixelCount(w), rowBytes: bytesPerRow)
                var permute: [UInt8] = [2, 1, 0]  // BGR → RGB
                return vImagePermuteChannels_RGB888(
                    &srcBuf, &dstBuf, &permute, vImage_Flags(kvImageNoFlags))
            }
        }
        guard permErr == kvImageNoError,
              let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let cg = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24,
            bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let mdata = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mdata, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Data(referencing: mdata)
    }

    /// Decode a stored JPEG → BGR888.
    private func decodeJPEGToBGR(_ jpeg: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var fmt = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 24,
            colorSpace: Unmanaged.passUnretained(cs),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buf = vImage_Buffer()
        let err = vImageBuffer_InitWithCGImage(
            &buf, &fmt, nil, cg, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError, let base = buf.data else { return nil }
        defer { free(buf.data) }
        let stride = buf.rowBytes
        let w = bgrFrameSize.width, h = bgrFrameSize.height
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        let src8 = base.assumingMemoryBound(to: UInt8.self)
        rgb.withUnsafeMutableBufferPointer { dp in
            let dst = dp.baseAddress!
            if stride == w * 3 {
                memcpy(dst, src8, w * h * 3)
            } else {
                for y in 0..<h {
                    memcpy(dst.advanced(by: y * w * 3),
                           src8.advanced(by: y * stride),
                           w * 3)
                }
            }
        }
        var permute: [UInt8] = [2, 1, 0]
        rgb.withUnsafeMutableBufferPointer { dp in
            var b = vImage_Buffer(
                data: dp.baseAddress, height: vImagePixelCount(h),
                width: vImagePixelCount(w), rowBytes: w * 3)
            _ = vImagePermuteChannels_RGB888(&b, &b, &permute,
                                              vImage_Flags(kvImageNoFlags))
        }
        return rgb
    }

    /// Predictive prefetch hint. EssenceGenerator calls this with the
    /// next frame_idx the ping-pong walker will request; a background
    /// JPEG decode runs so the result is in the LRU before the
    /// foreground asks for it.
    func prefetchFrame(at index: Int) {
        guard index >= 0, index < storage.jpegFrames.count else { return }
        jpegLock.lock()
        if jpegLRU[index] != nil || prefetchInFlight.contains(index) {
            jpegLock.unlock(); return
        }
        prefetchInFlight.insert(index)
        jpegLock.unlock()
        let jpeg = storage.jpegFrames[index]
        prefetchQueue.async { [weak self] in
            guard let self = self else { return }
            let bgr = self.decodeJPEGToBGR(jpeg)
            self.jpegLock.lock()
            self.prefetchInFlight.remove(index)
            if let bgr = bgr, self.jpegLRU[index] == nil {
                self.jpegLRU[index] = bgr
                self.jpegRecency.insert(index, at: 0)
                while self.jpegRecency.count > self.jpegCap {
                    let victim = self.jpegRecency.removeLast()
                    self.jpegLRU[victim] = nil
                }
            }
            self.jpegLock.unlock()
        }
    }

    /// Pre-resize hint, kept for API back-compat. Now that AVAssetReader
    /// produces buffers at the caller's preferred size at decode time,
    /// this is just a `bgrFrameSize` setter rather than an actual
    /// resize pass.
    func preResize(to width: Int, height: Int) {
        self.bgrFrameSize = (width, height)
    }

    /// Returns the frame at the given index as a `CGImage`. Decodes the
    /// stored JPEG via `CGImageSource`. Used by tests + the legacy
    /// CGImage accessor; the hot path goes through `extractFrameBGR`.
    func extractFrame(at index: Int) throws -> CGImage {
        guard index >= 0, index < frameCount else {
            throw Error.indexOutOfRange(index: index, frameCount: frameCount)
        }
        let jpeg = storage.jpegFrames[index]
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Error.generatorFailed(
                index: index,
                underlying: NSError(domain: "MP4FrameReader.jpegDecode",
                                    code: -1, userInfo: nil)
            )
        }
        return cg
    }

    /// Approximate per-instance LRU bytes (not the JPEG archive — that's
    /// owned by the shared storage and reported separately by
    /// `MP4FrameStorage._archiveBytes()`).
    func _mp4StorageBytes() -> Int {
        var sum = storage._archiveBytes()
        sum &+= jpegLRU.count * (bgrFrameSize.width * bgrFrameSize.height * 3)
        return sum
    }

    /// Hot-path accessor: returns the frame as a flat `width*height*3`
    /// BGR uint8 buffer. First call decodes the JPEG (~1-3 ms);
    /// subsequent calls hit the per-instance LRU (~10 µs). Predictive
    /// prefetch keeps the next-likely frame in the LRU.
    func extractFrameBGR(at index: Int) throws -> (bgr: [UInt8], width: Int, height: Int) {
        guard index >= 0, index < frameCount else {
            throw Error.indexOutOfRange(index: index, frameCount: frameCount)
        }
        jpegLock.lock()
        if let cached = jpegLRU[index] {
            if let i = jpegRecency.firstIndex(of: index) {
                jpegRecency.remove(at: i)
            }
            jpegRecency.insert(index, at: 0)
            jpegLock.unlock()
            return (cached, bgrFrameSize.width, bgrFrameSize.height)
        }
        // If a prefetch is in flight for this index, wait briefly for
        // it to finish — usually well under 1 ms since prefetch starts
        // during the previous frame's compose.
        let waitDeadline = Date().addingTimeInterval(0.005)
        while prefetchInFlight.contains(index) && Date() < waitDeadline {
            jpegLock.unlock()
            Thread.sleep(forTimeInterval: 0.0001)
            jpegLock.lock()
            if let cached = jpegLRU[index] {
                jpegLock.unlock()
                return (cached, bgrFrameSize.width, bgrFrameSize.height)
            }
        }
        let jpeg = storage.jpegFrames[index]
        jpegLock.unlock()
        guard let bgr = decodeJPEGToBGR(jpeg) else {
            throw Error.generatorFailed(
                index: index,
                underlying: NSError(domain: "MP4FrameReader.jpegDecode",
                                    code: -1, userInfo: nil)
            )
        }
        jpegLock.lock()
        if jpegLRU[index] == nil {
            jpegLRU[index] = bgr
            jpegRecency.insert(index, at: 0)
            while jpegRecency.count > jpegCap {
                let victim = jpegRecency.removeLast()
                jpegLRU[victim] = nil
            }
        }
        jpegLock.unlock()
        return (bgr, bgrFrameSize.width, bgrFrameSize.height)
    }
}
