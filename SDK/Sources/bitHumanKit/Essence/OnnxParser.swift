/// Minimal ONNX protobuf reader.
///
/// We only extract what the Essence audio encoder needs: top-level
/// `ModelProto.graph`, then `GraphProto.node` and
/// `GraphProto.initializer`. Inside each `NodeProto` we keep
/// `op_type`, `name`, `input`, `output`, and a small whitelist of
/// `attribute` fields (kernel_shape, strides, pads). Inside each
/// `TensorProto` we keep `name`, `dims`, `data_type`, and the bytes
/// from `raw_data` / `int32_data` / `float_data`.
///
/// Why hand-rolled instead of pulling in SwiftProtobuf:
/// - SwiftProtobuf is ~1.5 MB compiled (relative to our 80 MB
///   savings target the cost is small, but…)
/// - We only need ~10 protobuf fields total. The full library + a
///   generated `Onnx.pb.swift` is overkill, hard to audit, and
///   harder to vendor than the ~150 LoC below.
/// - Hand-rolled keeps the .imx-time-of-init path observable and
///   debuggable: every byte we read is in this file.
///
/// Wire format reference: <https://protobuf.dev/programming-guides/encoding/>.
/// ONNX schema: <https://github.com/onnx/onnx/blob/main/onnx/onnx.proto>.

import Foundation

internal enum OnnxParseError: Error, CustomStringConvertible {
    case truncated(String)
    case unsupportedWireType(Int, field: Int)

    internal var description: String {
        switch self {
        case .truncated(let s):                 return "OnnxParser: truncated reading \(s)"
        case .unsupportedWireType(let w, let f): return "OnnxParser: wire-type \(w) on field \(f)"
        }
    }
}

internal enum OnnxDataType: Int32 {
    case float = 1
    case uint8 = 2
    case int8 = 3
    case uint16 = 4
    case int16 = 5
    case int32 = 6
    case int64 = 7
    case string = 8
    case bool = 9
    case float16 = 10
    case double = 11
    case uint32 = 12
    case uint64 = 13
}

internal struct OnnxTensor {
    let name: String
    let dims: [Int]
    let dataType: Int32
    /// The exact bytes from `raw_data` if present; otherwise the
    /// packed bytes from one of the typed-data fields. Caller maps
    /// to the appropriate Swift type using `dataType`.
    let bytes: Data
}

internal struct OnnxAttribute {
    let name: String
    /// One of the typed payloads (we only care about ints/strings).
    let ints: [Int]
    let str: String
}

internal struct OnnxNode {
    let name: String
    let opType: String
    let inputs: [String]
    let outputs: [String]
    let attributes: [OnnxAttribute]
}

internal struct OnnxModel {
    let nodes: [OnnxNode]
    let initializers: [String: OnnxTensor]
}

// MARK: - Parser

/// A single byte cursor over `Data`. Methods throw if reads run off
/// the end. Pure value type — clones are independent.
private struct ByteReader {
    let data: Data
    var pos: Int = 0
    var remaining: Int { data.count - pos }

    mutating func read(_ n: Int) throws -> Data {
        guard remaining >= n else { throw OnnxParseError.truncated("read \(n) at pos \(pos)") }
        let s = data.startIndex + pos
        let slice = data[s..<(s + n)]
        pos += n
        return slice
    }

    /// Protobuf varint: 7-bit groups, MSB indicates continuation.
    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard remaining >= 1 else { throw OnnxParseError.truncated("varint at pos \(pos)") }
            let b = data[data.startIndex + pos]
            pos += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 { return result }
            shift += 7
            if shift >= 64 { throw OnnxParseError.truncated("varint overflow at pos \(pos)") }
        }
    }

    /// Length-delimited field body: varint length then `length` bytes.
    mutating func readLengthDelimited() throws -> Data {
        let len = Int(try readVarint())
        return try read(len)
    }

    mutating func readString() throws -> String {
        let bytes = try readLengthDelimited()
        return String(data: bytes, encoding: .utf8) ?? ""
    }

    /// Skip the value of a field given its wire type. Used for
    /// fields we don't care about.
    mutating func skipField(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            _ = try read(8)
        case 2:
            _ = try readLengthDelimited()
        case 5:
            _ = try read(4)
        default:
            throw OnnxParseError.unsupportedWireType(wireType, field: -1)
        }
    }
}

internal func parseOnnxModel(_ data: Data) throws -> OnnxModel {
    var reader = ByteReader(data: data)
    var model: OnnxModel? = nil

    while reader.remaining > 0 {
        let tag = try reader.readVarint()
        let field = Int(tag >> 3)
        let wt = Int(tag & 0x7)
        // ModelProto.graph is field 7 (length-delimited).
        if field == 7 && wt == 2 {
            let body = try reader.readLengthDelimited()
            model = try parseGraphProto(body)
        } else {
            try reader.skipField(wireType: wt)
        }
    }
    guard let m = model else {
        throw OnnxParseError.truncated("ModelProto.graph (field 7) not found")
    }
    return m
}

private func parseGraphProto(_ data: Data) throws -> OnnxModel {
    var reader = ByteReader(data: data)
    var nodes: [OnnxNode] = []
    var initializers: [String: OnnxTensor] = [:]
    while reader.remaining > 0 {
        let tag = try reader.readVarint()
        let field = Int(tag >> 3)
        let wt = Int(tag & 0x7)
        switch (field, wt) {
        case (1, 2): // node — repeated NodeProto
            let body = try reader.readLengthDelimited()
            nodes.append(try parseNodeProto(body))
        case (5, 2): // initializer — repeated TensorProto
            let body = try reader.readLengthDelimited()
            let t = try parseTensorProto(body)
            initializers[t.name] = t
        default:
            try reader.skipField(wireType: wt)
        }
    }
    return OnnxModel(nodes: nodes, initializers: initializers)
}

private func parseNodeProto(_ data: Data) throws -> OnnxNode {
    var reader = ByteReader(data: data)
    var inputs: [String] = []
    var outputs: [String] = []
    var name = ""
    var opType = ""
    var attrs: [OnnxAttribute] = []
    while reader.remaining > 0 {
        let tag = try reader.readVarint()
        let field = Int(tag >> 3)
        let wt = Int(tag & 0x7)
        switch (field, wt) {
        case (1, 2): inputs.append(try reader.readString())
        case (2, 2): outputs.append(try reader.readString())
        case (3, 2): name = try reader.readString()
        case (4, 2): opType = try reader.readString()
        case (5, 2):
            let body = try reader.readLengthDelimited()
            attrs.append(try parseAttributeProto(body))
        default:
            try reader.skipField(wireType: wt)
        }
    }
    return OnnxNode(name: name, opType: opType, inputs: inputs, outputs: outputs, attributes: attrs)
}

private func parseAttributeProto(_ data: Data) throws -> OnnxAttribute {
    // We only care about ints (kernel_shape/strides/pads, packed
    // int64) and strings. Float/tensor/etc. are skipped.
    var reader = ByteReader(data: data)
    var name = ""
    var ints: [Int] = []
    var str = ""
    while reader.remaining > 0 {
        let tag = try reader.readVarint()
        let field = Int(tag >> 3)
        let wt = Int(tag & 0x7)
        switch (field, wt) {
        case (1, 2): name = try reader.readString()
        case (4, 0): str = try reader.readString() // shouldn't normally hit
        case (8, 0): ints.append(Int(Int64(bitPattern: try reader.readVarint())))
        case (8, 2):
            // packed repeated int64
            let body = try reader.readLengthDelimited()
            var br = ByteReader(data: body)
            while br.remaining > 0 {
                ints.append(Int(Int64(bitPattern: try br.readVarint())))
            }
        case (4, 2):
            str = try reader.readString()
        default:
            try reader.skipField(wireType: wt)
        }
    }
    return OnnxAttribute(name: name, ints: ints, str: str)
}

private func parseTensorProto(_ data: Data) throws -> OnnxTensor {
    var reader = ByteReader(data: data)
    var dims: [Int] = []
    var dataType: Int32 = 0
    var name = ""
    var rawData = Data()
    var int32Bytes = Data()
    var floatBytes = Data()

    while reader.remaining > 0 {
        let tag = try reader.readVarint()
        let field = Int(tag >> 3)
        let wt = Int(tag & 0x7)
        switch (field, wt) {
        case (1, 0): dims.append(Int(try reader.readVarint())) // unpacked
        case (1, 2):
            // packed int64 dims
            let body = try reader.readLengthDelimited()
            var br = ByteReader(data: body)
            while br.remaining > 0 {
                dims.append(Int(try br.readVarint()))
            }
        case (2, 0): dataType = Int32(try reader.readVarint())
        case (8, 2): name = try reader.readString()
        case (9, 2): rawData = try reader.readLengthDelimited() // raw_data
        case (4, 2): int32Bytes.append(try reader.readLengthDelimited()) // packed int32_data
        case (5, 2): floatBytes.append(try reader.readLengthDelimited()) // packed float_data
        default:
            try reader.skipField(wireType: wt)
        }
    }
    // Prefer raw_data; fall back to typed-data fields.
    let bytes: Data
    if !rawData.isEmpty       { bytes = rawData }
    else if !floatBytes.isEmpty { bytes = floatBytes }
    else if !int32Bytes.isEmpty { bytes = int32Bytes }
    else                       { bytes = Data() }
    return OnnxTensor(name: name, dims: dims, dataType: dataType, bytes: bytes)
}
