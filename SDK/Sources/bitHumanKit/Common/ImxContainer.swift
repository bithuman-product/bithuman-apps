import Foundation

/// Read-only view over a bitHuman `.imx v2` container.
///
/// Mirrors the Python `ImxContainer` implementation in the
/// `bithuman` Python SDK package. The file layout is intentionally
/// minimal so the same 20-line reader works in any language:
///
/// ```text
/// +----------+-----------+------------+ ------ header (8 bytes)
/// | "IMX\0"  | u16 ver=2 | u16 count  |
/// +----------+-----------+------------+ ------ file table (variable)
/// | repeat count times:                |
/// |   u16  nameLen                     |
/// |   name (UTF-8, nameLen bytes)      |
/// |   u64  offset (absolute)           |
/// |   u64  size                        |
/// +------------------------------------+ ------ data blob
/// | concatenated file bodies at each   |
/// | entry's (offset, size)             |
/// +------------------------------------+
/// ```
///
/// `manifest.json`, when present as an entry, is eagerly decoded on
/// construction so callers can dispatch on `model_type` before paying
/// the cost of extracting weights.
struct ImxContainer {

    enum Error: Swift.Error, CustomStringConvertible {
        case fileTooSmall
        case badMagic(Data)
        case legacyV1Container
        case unsupportedVersion(UInt16)
        case truncated(offset: Int)
        case invalidName(underlying: Swift.Error)
        case manifestDecodeFailed(underlying: Swift.Error)
        case entryMissing(name: String)

        var description: String {
            switch self {
            case .fileTooSmall:
                return "ImxContainer: file too small to hold an IMX header"
            case .badMagic(let m):
                return "ImxContainer: bad magic \(m.map { String(format: "%02x", $0) }.joined()) — not an IMX file"
            case .legacyV1Container:
                return "ImxContainer: legacy IMX v1 container — upgrade with `bithuman convert`"
            case .unsupportedVersion(let v):
                return "ImxContainer: unsupported container version \(v)"
            case .truncated(let o):
                return "ImxContainer: file truncated at byte offset \(o)"
            case .invalidName(let e):
                return "ImxContainer: invalid UTF-8 in file table entry name — \(e)"
            case .manifestDecodeFailed(let e):
                return "ImxContainer: manifest.json decode failed — \(e)"
            case .entryMissing(let name):
                return "ImxContainer: entry not found — \(name)"
            }
        }
    }

    private static let magic: [UInt8] = [0x49, 0x4D, 0x58, 0x00]  // "IMX\0"
    private static let legacyV1Magic: [UInt8] = [0x42, 0x49, 0x4D, 0x58]  // "BIMX"

    /// Absolute path to the backing `.imx` file.
    let path: URL

    /// Container format version (always 2 for supported files).
    let version: UInt16

    /// (offset, size) for every entry, keyed by name.
    private let entries: [String: (offset: UInt64, size: UInt64)]

    /// Parsed `manifest.json` if the container carries one. Decoded
    /// lazily-eagerly: read from disk once during init so the hot
    /// path (dispatch on `model_type`) is an in-memory dictionary
    /// lookup.
    let manifest: [String: Any]?

    init(path: URL) throws {
        self.path = path
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }

        let header = try Self.readExactly(handle, count: 8, offset: 0)
        let magicBytes = [UInt8](header.prefix(4))
        if magicBytes == Self.legacyV1Magic {
            throw Error.legacyV1Container
        }
        guard magicBytes == Self.magic else {
            throw Error.badMagic(Data(magicBytes))
        }
        self.version = header.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian
        }
        guard version == 2 else { throw Error.unsupportedVersion(version) }
        let fileCount: UInt16 = header.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self).littleEndian
        }

        var cursorOffset: UInt64 = 8
        var entries: [String: (UInt64, UInt64)] = [:]
        entries.reserveCapacity(Int(fileCount))
        for _ in 0..<fileCount {
            let lenBytes = try Self.readExactly(handle, count: 2, offset: cursorOffset)
            cursorOffset += 2
            let nameLen: UInt16 = lenBytes.withUnsafeBytes { raw in
                raw.loadUnaligned(as: UInt16.self).littleEndian
            }
            let nameBytes = try Self.readExactly(handle, count: Int(nameLen), offset: cursorOffset)
            cursorOffset += UInt64(nameLen)
            guard let name = String(data: nameBytes, encoding: .utf8) else {
                throw Error.invalidName(
                    underlying: NSError(
                        domain: "ImxContainer", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "non-UTF-8 entry name"]
                    )
                )
            }
            let offsetSize = try Self.readExactly(handle, count: 16, offset: cursorOffset)
            cursorOffset += 16
            let (dataOffset, dataSize): (UInt64, UInt64) = offsetSize.withUnsafeBytes { raw in
                let o = raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self).littleEndian
                let s = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self).littleEndian
                return (o, s)
            }
            entries[name] = (dataOffset, dataSize)
        }
        self.entries = entries

        if let (off, size) = entries["manifest.json"] {
            let body = try Self.readExactly(handle, count: Int(size), offset: off)
            do {
                let json = try JSONSerialization.jsonObject(with: body, options: [])
                self.manifest = json as? [String: Any]
            } catch {
                throw Error.manifestDecodeFailed(underlying: error)
            }
        } else {
            self.manifest = nil
        }
    }

    // MARK: - Entry access

    func hasFile(_ name: String) -> Bool { entries[name] != nil }

    var entryNames: [String] { Array(entries.keys) }

    /// Read an entry's bytes. Reopens the backing file, seeks to the
    /// stored offset, reads `size` bytes. Not cached — the common case
    /// is to write the bytes straight to disk and be done with it.
    func readFile(_ name: String) throws -> Data {
        guard let (off, size) = entries[name] else { throw Error.entryMissing(name: name) }
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        return try Self.readExactly(handle, count: Int(size), offset: off)
    }

    /// Write an entry's bytes to a destination URL. Streams through a
    /// 1 MiB buffer so large weight entries (the DiT safetensors is
    /// ~2.8 GB) don't need to sit in memory twice.
    func extractFile(_ name: String, to destination: URL) throws {
        guard let (off, size) = entries[name] else { throw Error.entryMissing(name: name) }
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        try input.seek(toOffset: off)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var remaining = Int(size)
        let chunkCap = 1 << 20  // 1 MiB
        while remaining > 0 {
            let want = min(remaining, chunkCap)
            let chunk = try input.read(upToCount: want) ?? Data()
            if chunk.isEmpty { throw Error.truncated(offset: Int(off) + Int(size) - remaining) }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    // MARK: - Helpers

    private static func readExactly(
        _ handle: FileHandle,
        count: Int,
        offset: UInt64
    ) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Error.truncated(offset: Int(offset))
        }
        return data
    }
}
