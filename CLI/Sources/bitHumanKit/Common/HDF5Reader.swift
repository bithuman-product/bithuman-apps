import Compression
import Foundation

/// Minimal pure-Swift HDF5 reader, scoped to the dataset shapes the
/// Essence runtime needs from `lip_sync/<video_stem>.h5` files inside
/// `.imx` containers.
///
/// ## Why not libhdf5?
///
/// libhdf5 is ~1.5 MB of C, with a complex deployment story for
/// iOS (no system framework, can't link a static lib without
/// adding it to the SPM graph). The lip_sync .h5 files only use a
/// narrow subset of the format that h5py emits with default
/// settings, so a pure-Swift reader scoped to that subset is the
/// right cost: smaller, easier to audit, and uses only system
/// frameworks (`Foundation` + `Compression`).
///
/// ## Supported subset
///
/// - **Superblock V0** (h5py default — fixed 56-byte layout, then
///   the root symbol table entry).
/// - **8-byte offsets and lengths** (h5py default).
/// - **Object header V1** (the older format with no `OHDR` magic;
///   h5py emits this by default).
/// - **B-tree V1** (`TREE` magic) for group symbol tables and
///   chunk indices.
/// - **Symbol Table Node** (`SNOD` magic) — root group only.
/// - **Local Heap** (`HEAP` magic) — link names.
/// - **Global Heap** (`GCOL` magic) — variable-length data storage.
/// - **Datatypes**: fixed-point int32 (signed), floating-point
///   float32, variable-length uint8 (sequence of unsigned bytes).
/// - **Dataspaces**: rank 0 (scalar) or rank ≤ 8.
/// - **Data layout**: contiguous (class 1) or chunked (class 2).
/// - **Filters**: deflate / gzip (filter id 1) only.
/// - **Attributes** on the root group.
///
/// ## Explicitly NOT supported (throws `Error.unsupported…`)
///
/// - Superblock versions 1, 2, 3.
/// - Object header version 2 (`OHDR` magic).
/// - Compact data layout (class 0), virtual layout (class 3).
/// - Filters other than gzip (e.g. shuffle, szip, fletcher32).
/// - Datatypes other than the three above (no float64, int64,
///   uint8 fixed arrays, strings, compounds, references, …).
/// - Nested groups (only root-level datasets are looked up).
/// - Hard links / soft links / external links.
/// - Datasets with `MAXDIM` chunks or fancy chunk indexing (V2).
///
/// All "not supported" cases throw with a clear message rather
/// than silently misreading.
struct HDF5Reader {

    enum Error: Swift.Error, CustomStringConvertible {
        case fileTooSmall
        case badMagic(Data)
        case unsupportedSuperblockVersion(UInt8)
        case unsupportedOffsetSize(UInt8)
        case unsupportedLengthSize(UInt8)
        case unsupportedObjectHeaderVersion(UInt8)
        case unsupportedDataLayoutVersion(UInt8)
        case unsupportedDataLayoutClass(UInt8)
        case unsupportedDtype(String)
        case unsupportedFilter(id: UInt16)
        case unsupportedDataspaceRank(Int)
        case missingDataset(String)
        case truncated(at: Int, want: Int)
        case malformed(String)
        case decompressionFailed(String)

        var description: String {
            switch self {
            case .fileTooSmall:
                return "HDF5Reader: file too small to hold a superblock"
            case .badMagic(let m):
                return "HDF5Reader: bad magic \(m.map { String(format: "%02x", $0) }.joined()) — not an HDF5 file"
            case .unsupportedSuperblockVersion(let v):
                return "HDF5Reader: unsupported superblock version \(v) — only V0 is supported"
            case .unsupportedOffsetSize(let s):
                return "HDF5Reader: unsupported offset size \(s) — only 8 is supported"
            case .unsupportedLengthSize(let s):
                return "HDF5Reader: unsupported length size \(s) — only 8 is supported"
            case .unsupportedObjectHeaderVersion(let v):
                return "HDF5Reader: unsupported object header version \(v) — only V1 is supported"
            case .unsupportedDataLayoutVersion(let v):
                return "HDF5Reader: unsupported data layout message version \(v) — only V1/V2/V3 are supported"
            case .unsupportedDataLayoutClass(let c):
                return "HDF5Reader: unsupported data layout class \(c) — only contiguous (1) and chunked (2) are supported"
            case .unsupportedDtype(let detail):
                return "HDF5Reader: unsupported datatype — \(detail)"
            case .unsupportedFilter(let id):
                return "HDF5Reader: unsupported filter id \(id) — only gzip (1) is supported"
            case .unsupportedDataspaceRank(let r):
                return "HDF5Reader: unsupported dataspace rank \(r)"
            case .missingDataset(let n):
                return "HDF5Reader: dataset \"\(n)\" not found in root group"
            case .truncated(let at, let want):
                return "HDF5Reader: truncated read at offset \(at) (wanted \(want) bytes)"
            case .malformed(let m):
                return "HDF5Reader: malformed file — \(m)"
            case .decompressionFailed(let m):
                return "HDF5Reader: decompression failed — \(m)"
            }
        }
    }

    /// A scalar attribute value. Limited to what h5py emits for
    /// the `frame_wh` attribute — extend as needed.
    enum HDF5Value: Equatable {
        case int32Array([Int32])
        case float32Array([Float])
    }

    /// A fully-decoded dataset payload. The variant carries the
    /// shape so callers can reconstruct N-D arrays when needed.
    enum HDF5Dataset {
        case int32(shape: [Int], data: [Int32])
        case float32(shape: [Int], data: [Float])
        case variableLengthBytes(count: Int, items: [Data])
    }

    let rootAttributes: [String: HDF5Value]

    private let bytes: Data
    /// Map dataset name → object header file offset, populated at init.
    private let datasetObjectHeaders: [String: Int]

    init(data: Data) throws {
        self.bytes = data

        let sb = try Self.parseSuperblock(data: data)
        let (rootAttrs, datasetMap) = try Self.parseRootGroup(
            data: data, rootObjectHeaderAddr: sb.rootObjectHeaderAddr)
        self.rootAttributes = rootAttrs
        self.datasetObjectHeaders = datasetMap
    }

    /// Read a top-level dataset by name. Throws
    /// `Error.missingDataset` if not found.
    func readDataset(_ name: String) throws -> HDF5Dataset {
        guard let oh = datasetObjectHeaders[name] else {
            throw Error.missingDataset(name)
        }
        let messages = try Self.readObjectHeaderMessages(data: bytes, at: oh)
        return try Self.materializeDataset(data: bytes, messages: messages)
    }

    // MARK: - Superblock --------------------------------------------------

    private struct Superblock {
        let rootObjectHeaderAddr: Int
    }

    /// Parse the superblock (V0 only). HDF5 spec
    /// (https://docs.hdfgroup.org/hdf5/v1_14/_f_m_t3.html) lists this
    /// as 56 bytes for V0 with 8-byte offsets/lengths, plus the
    /// 40-byte root group symbol table entry.
    private static func parseSuperblock(data: Data) throws -> Superblock {
        guard data.count >= 96 else { throw Error.fileTooSmall }
        let magic: [UInt8] = [0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a]
        for (i, m) in magic.enumerated() {
            if data[data.startIndex + i] != m {
                throw Error.badMagic(data.prefix(8))
            }
        }
        let sbVersion = data[data.startIndex + 8]
        guard sbVersion == 0 else {
            throw Error.unsupportedSuperblockVersion(sbVersion)
        }
        let offSize = data[data.startIndex + 13]
        let lenSize = data[data.startIndex + 14]
        guard offSize == 8 else { throw Error.unsupportedOffsetSize(offSize) }
        guard lenSize == 8 else { throw Error.unsupportedLengthSize(lenSize) }

        // Root group symbol table entry begins at byte 56.
        // Layout (V0, 8-byte offsets):
        //   u64 link_name_offset
        //   u64 object_header_address
        //   u32 cache_type
        //   u32 reserved
        //   u8[16] scratch
        let rootEntryStart = data.startIndex + 56
        let rootObjAddr = Self.readUInt64LE(data, at: rootEntryStart + 8)
        guard rootObjAddr != UInt64.max else {
            throw Error.malformed("root object header address is undefined")
        }
        return Superblock(rootObjectHeaderAddr: Int(rootObjAddr))
    }

    // MARK: - Root group --------------------------------------------------

    /// Parse the root group's object header to extract attributes
    /// (only `frame_wh` for our use case) and the symbol table B-tree
    /// → SNOD → dataset object header chain. Returns
    /// (rootAttributes, datasetName → objectHeaderOffset).
    private static func parseRootGroup(
        data: Data, rootObjectHeaderAddr: Int
    ) throws -> ([String: HDF5Value], [String: Int]) {
        let messages = try readObjectHeaderMessages(
            data: data, at: rootObjectHeaderAddr)

        var attrs: [String: HDF5Value] = [:]
        var btreeAddr: Int? = nil
        var heapAddr: Int? = nil

        for msg in messages {
            switch msg.type {
            case .symbolTable:
                let body = msg.body
                btreeAddr = Int(readUInt64LE(body, at: body.startIndex))
                heapAddr = Int(readUInt64LE(body, at: body.startIndex + 8))
            case .attribute:
                let (name, value) = try parseAttribute(body: msg.body)
                attrs[name] = value
            default:
                continue
            }
        }

        var datasetMap: [String: Int] = [:]
        if let btreeAddr, let heapAddr {
            try walkSymbolTreeV1(
                data: data, btreeAddr: btreeAddr, heapAddr: heapAddr,
                into: &datasetMap)
        }

        return (attrs, datasetMap)
    }

    /// Walk a "TREE" V1 group node (signature `TREE`, node type 0 =
    /// group symbol table). For our minimal scope we only handle
    /// leaf-level trees (height 0), which is what h5py emits for the
    /// 2-or-3 datasets in lip_sync .h5 files.
    private static func walkSymbolTreeV1(
        data: Data, btreeAddr: Int, heapAddr: Int,
        into datasets: inout [String: Int]
    ) throws {
        try expectMagic(data, at: btreeAddr, magic: "TREE")
        let nodeType = data[data.startIndex + btreeAddr + 4]
        let nodeLevel = data[data.startIndex + btreeAddr + 5]
        let entriesUsed = readUInt16LE(data, at: btreeAddr + 6)
        guard nodeType == 0 else {
            throw Error.malformed("B-tree node type \(nodeType) not supported")
        }
        guard nodeLevel == 0 else {
            // Internal nodes would require recursion through child
            // pointers. h5py only emits leaves for tiny groups; reject
            // loudly otherwise so we don't silently miss datasets.
            throw Error.malformed(
                "B-tree node level \(nodeLevel) not supported (only leaves)")
        }

        // V1 leaf layout: magic(4) + type(1) + level(1) + n_used(2) +
        // left sibling(8) + right sibling(8) + 2K+1 keys interleaved
        // with 2K children. For type 0 (group), keys are 8-byte offsets
        // into the local heap (link name offsets). Children are 8-byte
        // file addresses pointing to SNOD nodes.
        var p = btreeAddr + 24  // skip magic+type+level+used+L+R
        // First key (skip)
        p += 8
        for _ in 0..<entriesUsed {
            let snodAddr = Int(readUInt64LE(data, at: p))
            p += 8
            // Skip the next key
            p += 8
            try parseSnod(
                data: data, snodAddr: snodAddr, heapAddr: heapAddr,
                into: &datasets)
        }
    }

    /// Symbol Table Node (SNOD): local heap of group entries.
    private static func parseSnod(
        data: Data, snodAddr: Int, heapAddr: Int,
        into datasets: inout [String: Int]
    ) throws {
        try expectMagic(data, at: snodAddr, magic: "SNOD")
        let version = data[data.startIndex + snodAddr + 4]
        guard version == 1 else {
            throw Error.malformed("SNOD version \(version) not supported")
        }
        let numSymbols = readUInt16LE(data, at: snodAddr + 6)
        // Each symbol entry (40 bytes for 8-byte offsets):
        //   u64 link_name_offset
        //   u64 object_header_address
        //   u32 cache_type
        //   u32 reserved
        //   u8[16] scratch
        var p = snodAddr + 8
        for _ in 0..<numSymbols {
            let linkOffset = Int(readUInt64LE(data, at: p))
            let objHeader = Int(readUInt64LE(data, at: p + 8))
            p += 40
            let name = try readNullTerminatedString(
                data: data, at: heapDataAddr(data: data, heapAddr: heapAddr) + linkOffset)
            datasets[name] = objHeader
        }
    }

    /// Local heap data starts at the heap's data segment address
    /// (`HEAP` magic header points to where the heap data lives).
    /// h5py writes the heap data after the heap header; the offset is
    /// stored in the heap header.
    private static func heapDataAddr(data: Data, heapAddr: Int) -> Int {
        // HEAP layout: magic(4) + version(1) + reserved(3) +
        // segment_size(8) + freelist_head_offset(8) + data_segment_addr(8)
        return Int(readUInt64LE(data, at: heapAddr + 24))
    }

    // MARK: - Object header (V1) -----------------------------------------

    /// Type codes for the object header messages we care about.
    private enum MessageType: UInt16 {
        case nilMsg = 0x0000
        case dataspace = 0x0001
        case datatype = 0x0003
        case fillValueOld = 0x0004
        case fillValue = 0x0005
        case dataLayout = 0x0008
        case filterPipeline = 0x000B
        case attribute = 0x000C
        case continuation = 0x0010
        case symbolTable = 0x0011
    }

    private struct Message {
        let type: MessageType
        let body: Data
    }

    /// Parse all messages from a V1 object header, transparently
    /// following continuation (0x0010) messages. Unknown types are
    /// silently skipped — the format requires that.
    private static func readObjectHeaderMessages(
        data: Data, at address: Int
    ) throws -> [Message] {
        // V1 prefix:
        //   u8 version (=1)
        //   u8 reserved
        //   u16 num_messages
        //   u32 obj_reference_count
        //   u32 obj_header_size  (bytes of message data in this chunk)
        //   u32 padding (to 16-byte alignment)
        let version = data[data.startIndex + address]
        guard version == 1 else {
            throw Error.unsupportedObjectHeaderVersion(version)
        }
        // The "OHDR" magic (V2) starts with bytes 'O','H','D','R'
        // (0x4F 0x48 0x44 0x52). V1 just starts with version 1; if
        // someone hands us a V2 header the version byte will be 'O'
        // (0x4F), which would have hit the guard above.

        let numMsgs = Int(readUInt16LE(data, at: address + 2))
        let chunkSize = Int(readUInt32LE(data, at: address + 8))

        var messages: [Message] = []
        // Process the initial chunk; continuations append more.
        var pendingChunks: [(start: Int, end: Int)] =
            [(start: address + 16, end: address + 16 + chunkSize)]
        var msgsRead = 0

        while !pendingChunks.isEmpty {
            let (start, end) = pendingChunks.removeFirst()
            var p = start
            while p < end && msgsRead < numMsgs {
                guard p + 8 <= end else { break }
                let typeRaw = readUInt16LE(data, at: p)
                let bodySize = Int(readUInt16LE(data, at: p + 2))
                // flags(1) + reserved(3) round out 8-byte header.
                let bodyStart = p + 8
                let bodyEnd = bodyStart + bodySize
                guard bodyEnd <= data.startIndex + data.endIndex - data.startIndex else {
                    throw Error.truncated(at: bodyStart, want: bodySize)
                }
                let body = data.subdata(
                    in: (data.startIndex + bodyStart)..<(data.startIndex + bodyEnd))
                msgsRead += 1
                // Continuation messages tell us where more messages
                // live; read them after this chunk so order is stable
                // (matches h5py's expectation).
                if let mt = MessageType(rawValue: typeRaw) {
                    if mt == .continuation {
                        let contAddr = Int(readUInt64LE(body, at: body.startIndex))
                        let contLen = Int(readUInt64LE(body, at: body.startIndex + 8))
                        pendingChunks.append(
                            (start: contAddr, end: contAddr + contLen))
                    } else if mt == .nilMsg {
                        // skip
                    } else {
                        messages.append(Message(type: mt, body: body))
                    }
                }
                // Advance past body, then align p to 8-byte multiple
                // relative to the chunk start. h5py emits messages
                // with 8-byte alignment.
                p = bodyEnd
                let consumed = p - start
                let aligned = (consumed + 7) & ~7
                p = start + aligned
            }
        }

        return messages
    }

    // MARK: - Attribute parsing ------------------------------------------

    private static func parseAttribute(body: Data) throws -> (String, HDF5Value) {
        // Attribute message V1 layout:
        //   u8 version (=1)
        //   u8 reserved
        //   u16 name_size  (bytes including NUL terminator)
        //   u16 datatype_size
        //   u16 dataspace_size
        // Followed by name (padded to 8), datatype (padded to 8),
        // dataspace (padded to 8), and the attribute data itself.
        let version = body[body.startIndex]
        guard version == 1 else {
            throw Error.malformed("attribute message version \(version) not supported")
        }
        let nameSize = Int(readUInt16LE(body, at: body.startIndex + 2))
        let dtSize = Int(readUInt16LE(body, at: body.startIndex + 4))
        let dsSize = Int(readUInt16LE(body, at: body.startIndex + 6))

        var p = body.startIndex + 8
        let nameBytes = body.subdata(in: p..<(p + nameSize))
        p += paddedTo8(nameSize)
        let dtBytes = body.subdata(in: p..<(p + dtSize))
        p += paddedTo8(dtSize)
        let dsBytes = body.subdata(in: p..<(p + dsSize))
        p += paddedTo8(dsSize)

        let name = String(
            data: nameBytes.prefix(while: { $0 != 0 }), encoding: .utf8
        ) ?? ""
        let dt = try parseDatatype(dtBytes)
        let ds = try parseDataspace(dsBytes, version: 1)
        let count = ds.shape.reduce(1, *)
        let dataBytes = body.subdata(in: p..<(p + dt.size * count))

        let value: HDF5Value
        switch dt.kind {
        case .int32:
            value = .int32Array(decodeInt32Array(dataBytes, count: count))
        case .float32:
            value = .float32Array(decodeFloat32Array(dataBytes, count: count))
        case .vlenBytes:
            throw Error.unsupportedDtype(
                "variable-length attribute values are not used in lip_sync HDF5 files")
        }
        return (name, value)
    }

    // MARK: - Datatype + dataspace ---------------------------------------

    private struct ParsedDatatype {
        enum Kind { case int32, float32, vlenBytes }
        let kind: Kind
        /// Width in bytes of one element as stored in the dataset
        /// body (NOT the element's value width — for vlen this is 16,
        /// the size of the (length, heap_addr, obj_index) descriptor).
        let size: Int
    }

    private static func parseDatatype(_ data: Data) throws -> ParsedDatatype {
        // Datatype message:
        //   byte 0: low 4 bits = class, high 4 bits = version
        //   bytes 1-3: class-specific bit fields
        //   bytes 4-7: total element size (uint32 LE)
        //   bytes 8+: class-specific properties
        let clsVer = data[data.startIndex]
        let cls = Int(clsVer & 0x0F)
        let size = Int(readUInt32LE(data, at: data.startIndex + 4))

        switch cls {
        case 0:  // fixed-point
            // bit 0 of byte 1 = byte order (0=LE, 1=BE)
            // bit 3 = signed/unsigned
            let bf0 = data[data.startIndex + 1]
            let isLE = (bf0 & 0x01) == 0
            let isSigned = (bf0 & 0x08) != 0
            guard isLE else {
                throw Error.unsupportedDtype("big-endian fixed-point")
            }
            if size == 4 && isSigned {
                return ParsedDatatype(kind: .int32, size: 4)
            }
            // h5py represents uint8 as size=1 unsigned for vlen base
            // type — surface those via vlenBytes path, not here.
            throw Error.unsupportedDtype(
                "fixed-point size=\(size) signed=\(isSigned)")
        case 1:  // floating-point
            let bf0 = data[data.startIndex + 1]
            let isLE = (bf0 & 0x01) == 0
            guard isLE else {
                throw Error.unsupportedDtype("big-endian float")
            }
            if size == 4 {
                return ParsedDatatype(kind: .float32, size: 4)
            }
            throw Error.unsupportedDtype("float size=\(size)")
        case 9:  // variable-length
            // bit fields: low 4 bits of byte 1 = type (0=sequence, 1=string)
            let bf0 = data[data.startIndex + 1]
            let vtype = bf0 & 0x0F
            guard vtype == 0 else {
                throw Error.unsupportedDtype("variable-length string")
            }
            // Properties = base datatype, starting at byte 8.
            let baseStart = data.startIndex + 8
            let baseClsVer = data[baseStart]
            let baseCls = Int(baseClsVer & 0x0F)
            let baseSize = Int(readUInt32LE(data, at: baseStart + 4))
            let baseBf0 = data[baseStart + 1]
            let baseSigned = (baseBf0 & 0x08) != 0
            guard baseCls == 0, baseSize == 1, !baseSigned else {
                throw Error.unsupportedDtype(
                    "variable-length base must be uint8 (got class=\(baseCls) size=\(baseSize) signed=\(baseSigned))")
            }
            // Stored on disk as 16-byte (length:u32, addr:u64, idx:u32)
            // descriptors per element.
            return ParsedDatatype(kind: .vlenBytes, size: 16)
        default:
            throw Error.unsupportedDtype("class \(cls)")
        }
    }

    private struct ParsedDataspace {
        let shape: [Int]
    }

    private static func parseDataspace(_ data: Data, version: Int) throws
        -> ParsedDataspace
    {
        // V1 dataspace: ver(1) + dim(1) + flags(1) + reserved(1) +
        //               reserved(4) + dims[ndim] + maxdims[ndim]? + perm?
        let dsv = data[data.startIndex]
        guard dsv == 1 else {
            throw Error.malformed("dataspace version \(dsv) not supported")
        }
        let ndim = Int(data[data.startIndex + 1])
        guard ndim <= 8 else {
            throw Error.unsupportedDataspaceRank(ndim)
        }
        var p = data.startIndex + 8
        var shape: [Int] = []
        for _ in 0..<ndim {
            shape.append(Int(readUInt64LE(data, at: p)))
            p += 8
        }
        return ParsedDataspace(shape: shape)
    }

    // MARK: - Dataset materialization ------------------------------------

    private struct DataLayout {
        enum Kind {
            case contiguous(addr: Int, size: Int)
            case chunked(treeAddr: Int, chunkDims: [Int], elementSize: Int)
        }
        let kind: Kind
    }

    private struct FilterPipeline {
        let filters: [UInt16]
    }

    private static func materializeDataset(
        data: Data, messages: [Message]
    ) throws -> HDF5Dataset {
        var dt: ParsedDatatype? = nil
        var ds: ParsedDataspace? = nil
        var layout: DataLayout? = nil
        var filters = FilterPipeline(filters: [])

        for msg in messages {
            switch msg.type {
            case .datatype:
                dt = try parseDatatype(msg.body)
            case .dataspace:
                ds = try parseDataspace(msg.body, version: 1)
            case .dataLayout:
                layout = try parseDataLayout(msg.body)
            case .filterPipeline:
                filters = try parseFilterPipeline(msg.body)
            default:
                continue
            }
        }

        guard let dt, let ds, let layout else {
            throw Error.malformed(
                "dataset object header missing datatype, dataspace, or data layout")
        }

        let totalElems = ds.shape.reduce(1, *)
        let rawBytes = try readDatasetRawBytes(
            data: data, layout: layout, filters: filters,
            elementSize: dt.size, shape: ds.shape)

        switch dt.kind {
        case .int32:
            let arr = decodeInt32Array(rawBytes, count: totalElems)
            return .int32(shape: ds.shape, data: arr)
        case .float32:
            let arr = decodeFloat32Array(rawBytes, count: totalElems)
            return .float32(shape: ds.shape, data: arr)
        case .vlenBytes:
            // Each 16-byte descriptor: u32 length + u64 heap addr + u32 obj index.
            var items: [Data] = []
            items.reserveCapacity(totalElems)
            for i in 0..<totalElems {
                let p = rawBytes.startIndex + i * 16
                let length = Int(readUInt32LE(rawBytes, at: p))
                let heapAddr = Int(readUInt64LE(rawBytes, at: p + 4))
                let objIdx = Int(readUInt32LE(rawBytes, at: p + 12))
                if length == 0 {
                    items.append(Data())
                } else {
                    items.append(try readGlobalHeapObject(
                        data: data, heapAddr: heapAddr, objectIndex: objIdx,
                        expectedSize: length))
                }
            }
            return .variableLengthBytes(count: totalElems, items: items)
        }
    }

    private static func parseDataLayout(_ body: Data) throws -> DataLayout {
        // Versions 1-3 differ in header layout:
        //   V1/V2: byte0 ver, byte1 ndims, byte2 class, then 5 reserved,
        //          then class-specific (V1 had implicit address fields)
        //   V3:    byte0 ver=3, byte1 class, then class-specific.
        // h5py 3.x emits V3 by default, but older files in the wild
        // may use V1/V2 — so accept any of them.
        let ver = body[body.startIndex]
        switch ver {
        case 1, 2:
            let ndims = Int(body[body.startIndex + 1])
            let cls = body[body.startIndex + 2]
            var p = body.startIndex + 8  // 1+1+1+5 reserved
            switch cls {
            case 1:  // contiguous
                let addr = Int(readUInt64LE(body, at: p))
                p += 8
                // dims: ndims u32 (V1) — total size = product * elem
                // Since we know shape from the dataspace message, we
                // don't need to recompute it here. But we DO need a
                // size — for contiguous V1/V2 the spec stores dim
                // sizes (not bytes). Compute size lazily in
                // readDatasetRawBytes via the dataspace.
                var dims: [Int] = []
                for _ in 0..<ndims {
                    dims.append(Int(readUInt32LE(body, at: p)))
                    p += 4
                }
                _ = dims  // placeholder
                return DataLayout(kind: .contiguous(addr: addr, size: -1))
            case 2:  // chunked
                let treeAddr = Int(readUInt64LE(body, at: p))
                p += 8
                var chunkDims: [Int] = []
                // V1/V2 chunk has ndims dimension sizes (each u32), and
                // the trailing one is the element size.
                for _ in 0..<ndims {
                    chunkDims.append(Int(readUInt32LE(body, at: p)))
                    p += 4
                }
                let elemSize = chunkDims.removeLast()
                return DataLayout(
                    kind: .chunked(
                        treeAddr: treeAddr, chunkDims: chunkDims,
                        elementSize: elemSize))
            default:
                throw Error.unsupportedDataLayoutClass(cls)
            }
        case 3:
            let cls = body[body.startIndex + 1]
            var p = body.startIndex + 2
            switch cls {
            case 0:
                throw Error.unsupportedDataLayoutClass(0)
            case 1:  // contiguous
                let addr = Int(readUInt64LE(body, at: p))
                p += 8
                let size = Int(readUInt64LE(body, at: p))
                return DataLayout(kind: .contiguous(addr: addr, size: size))
            case 2:  // chunked
                let ndims = Int(body[p])
                p += 1
                let treeAddr = Int(readUInt64LE(body, at: p))
                p += 8
                // ndims dim sizes (u32 each); last entry is the
                // element size as h5py V3 spec says: "Chunk
                // dimensionality + 1" — so total dims is ndims, with
                // the trailing one being the bytes-per-element.
                var chunkDims: [Int] = []
                for _ in 0..<ndims {
                    chunkDims.append(Int(readUInt32LE(body, at: p)))
                    p += 4
                }
                let elemSize = chunkDims.removeLast()
                return DataLayout(
                    kind: .chunked(
                        treeAddr: treeAddr, chunkDims: chunkDims,
                        elementSize: elemSize))
            default:
                throw Error.unsupportedDataLayoutClass(cls)
            }
        default:
            throw Error.unsupportedDataLayoutVersion(ver)
        }
    }

    private static func parseFilterPipeline(_ body: Data) throws
        -> FilterPipeline
    {
        // Filter pipeline message:
        //   V1: u8 version, u8 nfilters, u8[6] reserved, then per-filter:
        //       u16 id, u16 name_length, u16 flags, u16 nclient_values,
        //       name (padded to 8), client values (padded to 8)
        //   V2: u8 version (=2), u8 nfilters, then per-filter:
        //       u16 id, u16 name_length (omitted if id<256), ...
        let ver = body[body.startIndex]
        let nFilters = Int(body[body.startIndex + 1])
        var ids: [UInt16] = []
        var p: Data.Index
        switch ver {
        case 1:
            p = body.startIndex + 8
            for _ in 0..<nFilters {
                let id = readUInt16LE(body, at: p)
                let nameLen = Int(readUInt16LE(body, at: p + 2))
                _ = readUInt16LE(body, at: p + 4)  // flags
                let nclient = Int(readUInt16LE(body, at: p + 6))
                p += 8 + paddedTo8(nameLen) + paddedTo8(nclient * 4)
                ids.append(id)
            }
        case 2:
            p = body.startIndex + 2
            for _ in 0..<nFilters {
                let id = readUInt16LE(body, at: p)
                p += 2
                var nameLen = 0
                if id >= 256 {
                    nameLen = Int(readUInt16LE(body, at: p))
                    p += 2
                }
                _ = readUInt16LE(body, at: p)  // flags
                p += 2
                let nclient = Int(readUInt16LE(body, at: p))
                p += 2
                p += nameLen
                p += nclient * 4
                ids.append(id)
            }
        default:
            throw Error.malformed("filter pipeline version \(ver) not supported")
        }
        for id in ids where id != 1 {
            throw Error.unsupportedFilter(id: id)
        }
        return FilterPipeline(filters: ids)
    }

    /// Read the (possibly compressed and chunked) dataset bytes into a
    /// single linear buffer in row-major order.
    private static func readDatasetRawBytes(
        data: Data, layout: DataLayout, filters: FilterPipeline,
        elementSize: Int, shape: [Int]
    ) throws -> Data {
        let totalElems = shape.reduce(1, *)
        let totalBytes = totalElems * elementSize

        switch layout.kind {
        case .contiguous(let addr, let storedSize):
            let size = storedSize > 0 ? storedSize : totalBytes
            let start = data.startIndex + addr
            return data.subdata(in: start..<(start + size))
        case .chunked(let treeAddr, let chunkDims, _):
            // For our scoped use case (face_coords with default
            // chunking) the auto-chunker often picks "the whole
            // dataset" as one chunk. We still walk the B-tree V1
            // chunk index generically. Each leaf entry carries the
            // chunk's stored size, filter mask, and chunk offset
            // (one u64 per chunk dim + one trailing 0).
            return try readChunkedDataset(
                data: data, treeAddr: treeAddr, chunkDims: chunkDims,
                filters: filters, elementSize: elementSize, shape: shape)
        }
    }

    private static func readChunkedDataset(
        data: Data, treeAddr: Int, chunkDims: [Int],
        filters: FilterPipeline, elementSize: Int, shape: [Int]
    ) throws -> Data {
        try expectMagic(data, at: treeAddr, magic: "TREE")
        let nodeType = data[data.startIndex + treeAddr + 4]
        let nodeLevel = data[data.startIndex + treeAddr + 5]
        let entriesUsed = Int(readUInt16LE(data, at: treeAddr + 6))
        guard nodeType == 1 else {
            throw Error.malformed(
                "chunk B-tree node type \(nodeType) (expected 1)")
        }
        guard nodeLevel == 0 else {
            throw Error.malformed(
                "chunked B-tree internal nodes not supported")
        }

        let totalElems = shape.reduce(1, *)
        var output = Data(count: totalElems * elementSize)

        // V1 chunk leaf layout: magic(4) + type(1) + level(1) +
        // nused(2) + Lsib(8) + Rsib(8), then keys interleaved with
        // child pointers. For chunks (type 1):
        //   key = u32 chunk_size + u32 filter_mask + u64 offset[ndim+1]
        //   child = u64 chunk_data_address
        // (offsets has ndim+1 entries, one per dim plus a trailing 0)
        let ndim = chunkDims.count
        let keyBytes = 4 + 4 + 8 * (ndim + 1)
        var p = treeAddr + 24

        // The B-tree has entriesUsed children; key/child layout is
        // K0 C0 K1 C1 ... K(n-1) C(n-1) Kn.
        for _ in 0..<entriesUsed {
            // Read key
            let chunkSize = Int(readUInt32LE(data, at: p))
            let filterMask = readUInt32LE(data, at: p + 4)
            var chunkOffsets: [Int] = []
            for i in 0..<ndim {
                chunkOffsets.append(
                    Int(readUInt64LE(data, at: p + 8 + i * 8)))
            }
            p += keyBytes
            let chunkAddr = Int(readUInt64LE(data, at: p))
            p += 8

            let chunkLo = data.startIndex + chunkAddr
            let chunkHi = chunkLo + chunkSize
            let chunkRaw = data.subdata(in: chunkLo..<chunkHi)
            let chunkBytes = try applyFilters(
                chunkRaw, filters: filters, mask: filterMask)

            // Copy chunk into output at the right N-D offset.
            try copyChunkIntoOutput(
                chunk: chunkBytes, chunkOffsets: chunkOffsets,
                chunkDims: chunkDims, shape: shape,
                elementSize: elementSize, output: &output)
        }

        // Skip trailing key
        // (no-op; we already advanced p past the last child)
        _ = p

        return output
    }

    private static func copyChunkIntoOutput(
        chunk: Data, chunkOffsets: [Int], chunkDims: [Int], shape: [Int],
        elementSize: Int, output: inout Data
    ) throws {
        // For each cell within the chunk's bounding box, copy
        // elementSize bytes to the output's row-major position.
        // Cells past the dataset edge are skipped (chunks may
        // extend past shape).
        let ndim = shape.count
        precondition(chunkDims.count == ndim)
        precondition(chunkOffsets.count == ndim)
        var idx = [Int](repeating: 0, count: ndim)
        let chunkElems = chunkDims.reduce(1, *)

        // Strides for shape (row-major).
        var shapeStrides = [Int](repeating: 1, count: ndim)
        for i in (0..<ndim - 1).reversed() {
            shapeStrides[i] = shapeStrides[i + 1] * shape[i + 1]
        }

        for c in 0..<chunkElems {
            // Compute idx within the chunk.
            var rem = c
            for d in (0..<ndim).reversed() {
                idx[d] = rem % chunkDims[d]
                rem /= chunkDims[d]
            }
            // Translate to dataset coords.
            var inBounds = true
            var flat = 0
            for d in 0..<ndim {
                let coord = chunkOffsets[d] + idx[d]
                if coord >= shape[d] { inBounds = false; break }
                flat += coord * shapeStrides[d]
            }
            if !inBounds { continue }
            let src = c * elementSize
            let dst = flat * elementSize
            chunk.withUnsafeBytes { srcBuf in
                output.withUnsafeMutableBytes { dstBuf in
                    let srcPtr = srcBuf.baseAddress!.advanced(by: src)
                    let dstPtr = dstBuf.baseAddress!.advanced(by: dst)
                    memcpy(dstPtr, srcPtr, elementSize)
                }
            }
        }
    }

    private static func applyFilters(
        _ data: Data, filters: FilterPipeline, mask: UInt32
    ) throws -> Data {
        var current = data
        // Filters apply in REVERSE pipeline order on read.
        for (i, id) in filters.filters.enumerated().reversed() {
            // Per spec, bit i of the filter mask says "skip filter
            // i on this chunk". We skip if so.
            if (mask & (UInt32(1) << UInt32(i))) != 0 { continue }
            switch id {
            case 1:
                current = try inflateDeflate(current)
            default:
                throw Error.unsupportedFilter(id: id)
            }
        }
        return current
    }

    /// Inflate zlib-format data (deflate with a 2-byte zlib header +
    /// Adler-32 trailer) using the system Compression framework.
    private static func inflateDeflate(_ src: Data) throws -> Data {
        // The zlib header is 2 bytes; Apple's Compression framework
        // operates on raw deflate, so strip header + trailing Adler.
        guard src.count >= 6 else {
            throw Error.decompressionFailed("zlib stream too short")
        }
        let raw = src.subdata(in: (src.startIndex + 2)..<(src.endIndex - 4))

        // Decompress in a growing output buffer.
        var capacity = max(raw.count * 4, 1024)
        for _ in 0..<8 {
            var out = Data(count: capacity)
            let written: Int = out.withUnsafeMutableBytes { outBuf in
                raw.withUnsafeBytes { srcBuf in
                    let outPtr = outBuf.bindMemory(to: UInt8.self).baseAddress!
                    let srcPtr = srcBuf.bindMemory(to: UInt8.self).baseAddress!
                    return compression_decode_buffer(
                        outPtr, capacity, srcPtr, raw.count, nil,
                        COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity {
                out.removeSubrange(written..<out.count)
                return out
            }
            // 0 = error or buffer too small. For minimal scope, treat
            // both the "exactly-fits" boundary and "too small" as
            // "grow buffer and retry" — extremely unlikely on the tiny
            // chunks we see.
            capacity *= 2
        }
        throw Error.decompressionFailed("inflate exceeded retry budget")
    }

    // MARK: - Global heap (vlen storage) ---------------------------------

    private static func readGlobalHeapObject(
        data: Data, heapAddr: Int, objectIndex: Int, expectedSize: Int
    ) throws -> Data {
        try expectMagic(data, at: heapAddr, magic: "GCOL")
        let version = data[data.startIndex + heapAddr + 4]
        guard version == 1 else {
            throw Error.malformed("GCOL version \(version) not supported")
        }
        let totalSize = Int(readUInt64LE(data, at: heapAddr + 8))
        var p = heapAddr + 16
        let end = heapAddr + totalSize
        while p < end {
            // Each object: u16 idx, u16 ref_count, u32 reserved, u64 size, data, padded to 8.
            let idx = Int(readUInt16LE(data, at: p))
            if idx == 0 {
                // Free space marker — rest of the heap is unused.
                break
            }
            let size = Int(readUInt64LE(data, at: p + 8))
            if idx == objectIndex {
                let dataStart = data.startIndex + p + 16
                let payload = data.subdata(in: dataStart..<(dataStart + size))
                if size != expectedSize {
                    throw Error.malformed(
                        "vlen size mismatch: descriptor says \(expectedSize), heap says \(size)")
                }
                return payload
            }
            p += 16 + paddedTo8(size)
        }
        throw Error.malformed(
            "global heap object \(objectIndex) not found at \(String(format: "0x%x", heapAddr))")
    }

    // MARK: - Byte helpers -----------------------------------------------

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        let i = data.startIndex + offset
        var v: UInt64 = 0
        for k in 0..<8 {
            v |= UInt64(data[i + k]) << (8 * k)
        }
        return v
    }

    private static func decodeInt32Array(_ data: Data, count: Int) -> [Int32] {
        var out = [Int32](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            data.copyBytes(
                to: dst.bindMemory(to: UInt8.self), count: count * 4)
        }
        return out
    }

    private static func decodeFloat32Array(_ data: Data, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            data.copyBytes(
                to: dst.bindMemory(to: UInt8.self), count: count * 4)
        }
        return out
    }

    private static func paddedTo8(_ n: Int) -> Int { (n + 7) & ~7 }

    private static func expectMagic(
        _ data: Data, at offset: Int, magic: String
    ) throws {
        let expected = Array(magic.utf8)
        for (i, b) in expected.enumerated() {
            if data[data.startIndex + offset + i] != b {
                throw Error.malformed(
                    "expected \(magic) magic at \(String(format: "0x%x", offset))")
            }
        }
    }

    private static func readNullTerminatedString(
        data: Data, at offset: Int
    ) throws -> String {
        var p = data.startIndex + offset
        while p < data.endIndex && data[p] != 0 {
            p += 1
        }
        let bytes = data.subdata(in: (data.startIndex + offset)..<p)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw Error.malformed("non-UTF8 link name at \(offset)")
        }
        return s
    }
}
