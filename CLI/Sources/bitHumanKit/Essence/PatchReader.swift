import CoreGraphics
import Foundation

/// Reader for the Essence runtime's `BJPG`-magic blob archives.
///
/// At runtime each lip-sync variant of an avatar ships as two of these
/// archives, embedded in the parent `.imx` container:
///
///   - **bases**   one full face crop per source frame.
///   - **patches** one mouth region per `(source_frame, cluster ≥ 1)` pair,
///     pasted onto the corresponding base at composition time.
///
/// The container format (24-byte header, encrypted offset index, encrypted
/// JPEG / WebP payloads) is fully specified in
/// `docs/architecture/essence-algorithm-spec.md` §5. The Python reference
/// is `bithuman/engine/patch_reader.py` (BlobReader + PatchReader).
///
/// **Encryption.** Each archive is XOR-obfuscated with a fixed key in a
/// rolling-alignment scheme: byte at file-offset `o` is XORed with
/// `key[o % key.count]`. The header bytes start at offset 0; the offset
/// table starts at offset 24; the image-data section starts at the
/// `dataOffset` field carried in the (decrypted) header.
///
/// **Decoding.** Image bytes are JPEG or WebP encoded; ImageIO sniffs the
/// magic, so this reader just dispatches by inspecting the first few
/// decrypted bytes (`FFD8FF…` → JPEG, `RIFF…WEBP` → WebP). The header's
/// `quality` byte is an authoring-time hint; it doesn't change which
/// codec to use.
///
/// **Caching.** Cluster ladders walk the same source frame multiple
/// times in a row (cluster 0, 1, 2, …, K-1 all share the same base),
/// so decoded base `CGImage`s are kept in a small LRU. Patches are
/// touched once per frame in normal playback and aren't cached.
internal final class PatchReader {

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case truncatedHeader
        case badMagic(Data)
        case unsupportedVersion(UInt16)
        case truncatedIndex
        case frameOutOfRange(Int, Int)
        case clusterOutOfRange(Int, Int)
        case basesAndPatchesDisagree(bases: Int, patches: Int, expected: Int)
        case unrecognizedImageMagic(Data)

        var description: String {
            switch self {
            case .truncatedHeader:
                return "PatchReader: archive shorter than the 24-byte BJPG header"
            case .badMagic(let m):
                return "PatchReader: bad BJPG magic \(m as NSData)"
            case .unsupportedVersion(let v):
                return "PatchReader: unsupported BJPG version \(v)"
            case .truncatedIndex:
                return "PatchReader: archive truncated mid-index"
            case .frameOutOfRange(let i, let n):
                return "PatchReader: frame index \(i) out of range [0, \(n))"
            case .clusterOutOfRange(let c, let n):
                return "PatchReader: cluster index \(c) out of range [0, \(n))"
            case .basesAndPatchesDisagree(let b, let p, let e):
                return
                    "PatchReader: patches count \(p) ≠ bases (\(b)) × (numClusters - 1); expected \(e)"
            case .unrecognizedImageMagic(let head):
                return
                    "PatchReader: cannot detect codec from leading bytes \(head as NSData) (not JPEG/WebP)"
            }
        }
    }

    // MARK: - Encryption key
    //
    // Sourced from `bithuman/engine/video_reader.py:17` in the private
    // bithuman-product/bithuman-python-sdk repo:
    //
    //     ENCRYPT_KEY = b"bithuman_video_data_key"
    //
    // The 23 raw bytes (UTF-8) are inlined here intentionally: this
    // repo (`bithuman-kit`) is private, exactly like
    // `bithuman/engine/auth.py` carries its JWT signing bytes inline
    // in the Python SDK. Keeping it in source means the IMX archives
    // ship without a sidecar key file.
    private static let encryptionKey: [UInt8] = Array("bithuman_video_data_key".utf8)

    // MARK: - Header layout (matches Python BlobReader exactly)

    private static let blobMagic: [UInt8] = Array("BJPG".utf8)
    private static let blobVersion: UInt16 = 1
    private static let blobHeaderSize: Int = 24

    private struct Archive {
        let data: Data            // raw, still XOR-encrypted (we decrypt slices on access)
        let frameCount: Int
        let width: Int
        let height: Int
        let dataOffset: Int       // byte offset inside `data` where image payloads start
        let offsets: [UInt64]     // decrypted per-frame start offsets, length == frameCount
    }

    private let bases: Archive
    private let patches: Archive
    private let numClusters: Int

    // MARK: - Base cache (LRU, capacity 64)
    //
    // The Essence runtime walks all clusters of a given source frame
    // in tight succession (one frame's cluster ladder = up to ~K
    // accesses, all hitting the same base), so even a tiny cache
    // turns the worst-case "decode N times" into "decode once". 64
    // entries comfortably covers a few seconds of 25 FPS playback
    // without holding much memory: a 384x384 BGRA CGImage backed by
    // ImageIO is ~600 KB, so 64 entries ≈ 38 MB upper bound.
    //
    // Implementation: dictionary + recency list. Patches deliberately
    // don't get a cache — they're hit once per frame in normal play.
    private struct BaseCache {
        let capacity: Int
        var images: [Int: CGImage] = [:]
        // recency[0] = most recently used; recency[last] = LRU victim.
        var recency: [Int] = []

        mutating func get(_ key: Int) -> CGImage? {
            guard let image = images[key] else { return nil }
            if let idx = recency.firstIndex(of: key) {
                recency.remove(at: idx)
            }
            recency.insert(key, at: 0)
            return image
        }

        mutating func put(_ key: Int, _ image: CGImage) {
            if images[key] != nil {
                if let idx = recency.firstIndex(of: key) {
                    recency.remove(at: idx)
                }
            }
            images[key] = image
            recency.insert(key, at: 0)
            while recency.count > capacity {
                let victim = recency.removeLast()
                images[victim] = nil
            }
        }
    }

    // Base cache sized lazily in init: the bench fixture has 202
    // unique source frames and was thrashing at the previous cap=64.
    // Sizing to the actual frame count keeps memory bounded by the
    // archive (each base frame is ~60×60×4 = ~14 KB once decoded
    // into a CGImage's IOSurface, so 200 frames ≈ 2.8 MB).
    private var baseCache = BaseCache(capacity: 64)
    /// Mirrors `baseCache` but stores BGR uint8 bytes — the form the
    /// downstream compose pipeline actually consumes. Sized once at
    /// init to cover all source frames; ~14 KB per entry at 60×60.
    private var baseBGRCache: [Int: (bgr: [UInt8], width: Int, height: Int)] = [:]
    private let cacheLock = NSLock()

    // MARK: - Init

    /// Parses the two BJPG archives and validates that their counts agree
    /// with the FEATURE_FIRST contract: `patches == bases * (numClusters - 1)`.
    ///
    /// - Parameters:
    ///   - basesData:   raw on-disk bytes of the bases archive (still encrypted).
    ///   - patchesData: raw on-disk bytes of the patches archive (still encrypted).
    ///   - numClusters: total number of KNN clusters (cluster 0 = base, 1..K-1 = patch).
    init(basesData: Data, patchesData: Data, numClusters: Int) throws {
        precondition(numClusters >= 1, "numClusters must be ≥ 1")
        self.numClusters = numClusters
        self.bases = try Self.parseArchive(basesData)
        self.patches = try Self.parseArchive(patchesData)
        // Right-size the cache so a single sweep over all source
        // frames doesn't thrash. Capped at 1024 to bound memory on
        // unusually long fixtures.
        self.baseCache = BaseCache(capacity: min(1024, max(64, self.bases.frameCount)))

        let expectedPatches = self.bases.frameCount * (numClusters - 1)
        guard self.patches.frameCount == expectedPatches else {
            throw Error.basesAndPatchesDisagree(
                bases: self.bases.frameCount,
                patches: self.patches.frameCount,
                expected: expectedPatches
            )
        }

        // v0.18.8+: pre-decode every base face-crop to BGR uint8 at
        // init. The bases archive holds the head crops the lip-patch
        // gets glued onto; in the per-frame compose hot path,
        // `baseBGR(at:)` was running a JPEG decode → CGImage →
        // CGContext draw the first time each frame_idx was hit
        // (~500 µs / call). With ping-pong playback over a 202-frame
        // archive plus a 50-frame warmup, only ~25% of measured
        // frames hit the cache; the other 75% paid the cold-decode
        // cost. Pre-decoding upfront is ~50 ms one-time (203 small
        // JPEGs), bounded memory (~45 MB / 200 frames at 225×329
        // BGR), and turns the runtime cost into an O(1) dict
        // lookup (~50 ns).
        //
        // v0.18.10: only populate `baseBGRCache` here. The
        // `baseCache` (CGImage) is kept on the type for the legacy
        // `base(at:)` accessor (used by tests + debug paths) but
        // intentionally *not* pre-populated — the compose pipeline
        // never calls `base(at:)`, so eagerly seeding the CGImage
        // cache was 57 MB of dead memory on the demo fixture.
        // v0.18.11: parallelize the per-frame JPEG decode + BGR
        // conversion. Each frame is independent; on M5's 10 cores
        // this drops the bench fixture's 88 ms sequential cost to
        // ~12 ms wall.
        let baseCount = self.bases.frameCount
        var entries = [(bgr: [UInt8], width: Int, height: Int)?](repeating: nil, count: baseCount)
        let firstError = NSLock()
        var caughtError: Swift.Error? = nil
        entries.withUnsafeMutableBufferPointer { ep in
            let ptr = ep.baseAddress!
            DispatchQueue.concurrentPerform(iterations: baseCount) { i in
                do {
                    let blob = try self.decryptedBlob(in: self.bases, at: i)
                    let cg = try Self.decodeImage(blob)
                    let bgr = [UInt8](EssenceImageOps.cgImageToBGRBytes(cg))
                    ptr[i] = (bgr: bgr, width: cg.width, height: cg.height)
                } catch {
                    firstError.lock()
                    if caughtError == nil { caughtError = error }
                    firstError.unlock()
                }
            }
        }
        if let e = caughtError { throw e }
        for i in 0..<baseCount {
            if let entry = entries[i] {
                self.baseBGRCache[i] = entry
            }
        }
    }

    // MARK: - Public surface

    /// Number of unique source frames (== entries in the bases archive).
    var basesCount: Int { bases.frameCount }

    /// Number of patches in the patches archive.
    /// Equals `basesCount * (numClusters - 1)` per the FEATURE_FIRST layout.
    var patchesCount: Int { patches.frameCount }

    /// Approximate buffer sizes for `EssenceGenerator.dumpMemoryAudit`.
    /// The CGImage byte count is best-effort: each cached entry's
    /// `dataProvider` may or may not reflect the real backing store
    /// (CG can lazy-decode, render to IOSurface, etc), so we report
    /// the upper bound `width × height × 4`.
    func _memoryAudit() -> (
        patchesBytes: Int, basesBytes: Int,
        baseBGRBytes: Int, baseCGBytes: Int
    ) {
        let pBytes = patches.data.count
        let bBytes = bases.data.count
        var bgr = 0
        for (_, v) in baseBGRCache { bgr &+= v.bgr.count }
        var cg = 0
        for (_, image) in baseCache.images {
            cg &+= image.width * image.height * 4
        }
        return (pBytes, bBytes, bgr, cg)
    }

    /// Decode the base face crop for source `frameIndex`. Cached.
    func base(at frameIndex: Int) throws -> CGImage {
        guard frameIndex >= 0 && frameIndex < bases.frameCount else {
            throw Error.frameOutOfRange(frameIndex, bases.frameCount)
        }

        cacheLock.lock()
        if let hit = baseCache.get(frameIndex) {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let blob = try decryptedBlob(in: bases, at: frameIndex)
        let image = try Self.decodeImage(blob)

        cacheLock.lock()
        baseCache.put(frameIndex, image)
        cacheLock.unlock()
        return image
    }

    /// Decode the base face crop and return its BGR uint8 bytes. The
    /// downstream compose pipeline operates on uint8 buffers directly,
    /// so this avoids the per-call `cgImageToBGRBytes` round-trip
    /// (~0.5-1 ms each) that was happening on every cache miss. Caches
    /// the BGR bytes alongside the CGImage cache; once decoded the
    /// second access for any (frame_idx, cluster_idx) hits in
    /// nanoseconds.
    func baseBGR(at frameIndex: Int) throws -> (bgr: [UInt8], width: Int, height: Int) {
        guard frameIndex >= 0 && frameIndex < bases.frameCount else {
            throw Error.frameOutOfRange(frameIndex, bases.frameCount)
        }

        cacheLock.lock()
        if let hit = baseBGRCache[frameIndex] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let cg = try base(at: frameIndex) // populates the CGImage cache too
        let bytes = [UInt8](EssenceImageOps.cgImageToBGRBytes(cg))
        let entry = (bgr: bytes, width: cg.width, height: cg.height)

        cacheLock.lock()
        baseBGRCache[frameIndex] = entry
        cacheLock.unlock()
        return entry
    }

    /// Decode the mouth patch for source `frameIndex`, KNN-cluster `clusterIndex`.
    ///
    /// Returns `nil` for `clusterIndex == 0`: cluster 0 is the silent /
    /// rest-pose anchor and uses the base frame directly with no patch
    /// applied (per algo spec §5).
    func patch(frame frameIndex: Int, cluster clusterIndex: Int) throws -> CGImage? {
        guard frameIndex >= 0 && frameIndex < bases.frameCount else {
            throw Error.frameOutOfRange(frameIndex, bases.frameCount)
        }
        guard clusterIndex >= 0 && clusterIndex < numClusters else {
            throw Error.clusterOutOfRange(clusterIndex, numClusters)
        }
        if clusterIndex == 0 {
            return nil
        }
        let flat = frameIndex * (numClusters - 1) + (clusterIndex - 1)
        let blob = try decryptedBlob(in: patches, at: flat)
        return try Self.decodeImage(blob)
    }

    // MARK: - Archive parsing

    private static func parseArchive(_ data: Data) throws -> Archive {
        guard data.count >= blobHeaderSize else { throw Error.truncatedHeader }

        // Decrypt the header in place (offset 0 → key starts at index 0).
        var headerBytes = [UInt8](repeating: 0, count: blobHeaderSize)
        data.copyBytes(to: &headerBytes, count: blobHeaderSize)
        decryptInPlace(&headerBytes, fileOffset: 0)

        // magic[0..4]
        guard Array(headerBytes[0..<4]) == blobMagic else {
            throw Error.badMagic(Data(headerBytes[0..<4]))
        }
        let version = readUInt16LE(headerBytes, at: 4)
        guard version == blobVersion else {
            throw Error.unsupportedVersion(version)
        }
        let frameCount = Int(readUInt32LE(headerBytes, at: 6))
        let width = Int(readUInt16LE(headerBytes, at: 10))
        let height = Int(readUInt16LE(headerBytes, at: 12))
        // headerBytes[14] = quality, [15] = reserved — ignored by reader.
        let dataOffset = Int(readUInt64LE(headerBytes, at: 16))

        // Decrypt the offset index (count * 8 bytes immediately following the header).
        let indexSize = frameCount * 8
        guard data.count >= blobHeaderSize + indexSize else { throw Error.truncatedIndex }
        var indexBytes = [UInt8](repeating: 0, count: indexSize)
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<indexSize { indexBytes[i] = src[blobHeaderSize + i] }
        }
        decryptInPlace(&indexBytes, fileOffset: blobHeaderSize)

        var offsets = [UInt64](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            offsets[i] = readUInt64LE(indexBytes, at: i * 8)
        }

        return Archive(
            data: data,
            frameCount: frameCount,
            width: width,
            height: height,
            dataOffset: dataOffset,
            offsets: offsets
        )
    }

    // MARK: - Per-frame decrypt

    /// Read, slice, and XOR-decrypt the raw image blob for `index`.
    private func decryptedBlob(in archive: Archive, at index: Int) throws -> Data {
        let start = Int(archive.offsets[index])
        let end: Int
        if index + 1 < archive.frameCount {
            end = Int(archive.offsets[index + 1])
        } else {
            end = archive.data.count
        }
        let count = end - start
        var buf = [UInt8](repeating: 0, count: count)
        archive.data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count { buf[i] = src[start + i] }
        }
        Self.decryptInPlace(&buf, fileOffset: start)
        return Data(buf)
    }

    // MARK: - Codec dispatch

    /// Sniff the leading bytes and dispatch to ImageIO.
    /// JPEG starts `FF D8 FF`; WebP starts `RIFF....WEBP` (12 bytes).
    private static func decodeImage(_ blob: Data) throws -> CGImage {
        if blob.count >= 3,
           blob[blob.startIndex] == 0xFF,
           blob[blob.startIndex.advanced(by: 1)] == 0xD8,
           blob[blob.startIndex.advanced(by: 2)] == 0xFF {
            return try EssenceImageOps.decodeJPEG(blob)
        }
        if blob.count >= 12 {
            let r = blob.startIndex
            let isRiff = blob[r] == 0x52 && blob[r.advanced(by: 1)] == 0x49
                && blob[r.advanced(by: 2)] == 0x46 && blob[r.advanced(by: 3)] == 0x46
            let isWebp = blob[r.advanced(by: 8)] == 0x57 && blob[r.advanced(by: 9)] == 0x45
                && blob[r.advanced(by: 10)] == 0x42 && blob[r.advanced(by: 11)] == 0x50
            if isRiff && isWebp {
                return try EssenceImageOps.decodeWebP(blob)
            }
        }
        let head = blob.prefix(min(8, blob.count))
        throw Error.unrecognizedImageMagic(Data(head))
    }

    // MARK: - XOR cipher

    /// XOR each byte of `buf[i]` with `key[(fileOffset + i) % key.count]`.
    /// The cipher is its own inverse, so encrypt and decrypt share this body.
    static func decryptInPlace(_ buf: inout [UInt8], fileOffset: Int) {
        let key = encryptionKey
        let keyLen = key.count
        let start = ((fileOffset % keyLen) + keyLen) % keyLen
        var k = start
        for i in 0..<buf.count {
            buf[i] ^= key[k]
            k += 1
            if k == keyLen { k = 0 }
        }
    }

    // MARK: - Little-endian decoders

    @inline(__always)
    private static func readUInt16LE(_ b: [UInt8], at offset: Int) -> UInt16 {
        return UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
    }

    @inline(__always)
    private static func readUInt32LE(_ b: [UInt8], at offset: Int) -> UInt32 {
        return UInt32(b[offset])
            | (UInt32(b[offset + 1]) << 8)
            | (UInt32(b[offset + 2]) << 16)
            | (UInt32(b[offset + 3]) << 24)
    }

    @inline(__always)
    private static func readUInt64LE(_ b: [UInt8], at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(b[offset + i]) << (8 * i)
        }
        return v
    }
}
