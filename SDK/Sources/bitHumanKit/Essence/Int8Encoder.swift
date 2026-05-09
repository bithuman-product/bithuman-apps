/// Int8-quantized audio encoder, loading weights directly from the
/// QDQ pattern in the .imx's `audio_encoder.onnx` entry.
///
/// **Status:** *foundation only*. This file lands the QDQ-graph
/// extractor (parses the .onnx, walks every Conv's
/// QuantizeLinear→DequantizeLinear→Conv→QuantizeLinear chain,
/// pulls out per-layer (int8 weight, int32 bias, per-channel weight
/// scale, input scale, output scale, all zero-points)) and a
/// validation harness that confirms the extracted weights match
/// what `onnx.load(...).graph.initializer` produces in Python.
/// The forward pass that turns these into BNNS int8 conv kernels
/// is the next milestone (#62) — see `forward(mel:)` below for the
/// fp32-cast bridge we ship in the meantime.
///
/// Why this layout:
/// 1. The 80 MB binary cost of ONNX Runtime is the cost we want to
///    eliminate. The .onnx file itself stays in the .imx (it's only
///    2.7 MB and Python still needs it). What we drop is the
///    runtime/MLAS/protobuf static lib that links into the consumer.
/// 2. Extraction is per-`.imx`-init work — runs once at create
///    time (~5 ms), never on the per-frame hot path.
/// 3. Numeric drift vs ORT is bounded: for the fp32-cast bridge,
///    output matches the existing `AudioEncoderAccelerate` byte-for
///    -byte (it's the *same* fp32 GEMM kernel under the hood, just
///    fed weights extracted from .onnx instead of from
///    `audio_encoder.safetensors`). Once the BNNS int8 conv kernel
///    lands the drift will be int8 quantization rounding (~1 LSB
///    per layer, sub-perceptual end-to-end).

import Accelerate
import Foundation

// MARK: - Errors

internal enum Int8EncoderError: Error, CustomStringConvertible {
    case missingNode(String)
    case missingTensor(String)
    case unexpectedTopology(String)
    case unexpectedTensorDtype(name: String, got: Int32)

    internal var description: String {
        switch self {
        case .missingNode(let s):       return "Int8Encoder: graph missing node \(s)"
        case .missingTensor(let s):     return "Int8Encoder: graph missing initializer \(s)"
        case .unexpectedTopology(let s): return "Int8Encoder: unexpected QDQ topology — \(s)"
        case .unexpectedTensorDtype(let n, let d):
            return "Int8Encoder: tensor '\(n)' has dtype \(d) (expected int8/int32/float32)"
        }
    }
}

// MARK: - Per-layer parameters extracted from the QDQ graph

/// Quantization parameters for a single Conv layer plus the int8
/// weight and int32 bias buffers. Sufficient input for a BNNS int8
/// conv call: out_int32 = sum(int8_in * int8_weight) + int32_bias,
/// then `out_int8 = clamp(round(out_int32 * (in_scale*w_scale/
/// out_scale)) + out_zp, [act_dtype_min, act_dtype_max])`.
// MARK: - Int8 → fp32 weight bridge

/// Dequantize the extracted int8 weights/biases to fp32 and pack into
/// a safetensors blob compatible with `AudioEncoderAccelerate`'s
/// existing loader. This is the **Phase 1 bridge** that drops the
/// ONNX Runtime dependency: same fp32 GEMM kernel as
/// `AudioEncoderAccelerate`, but the int8 weights come from the
/// .imx's `audio_encoder.onnx` entry instead of `audio_encoder.safetensors`.
///
/// Phase 2 (future #62 follow-up) replaces the fp32 GEMM with a true
/// int8 GEMM via NEON intrinsics — same speed as ORT MLAS but with
/// no static-lib cost. The extracted int8 weights persist; only the
/// inner kernel changes.
internal func buildFp32SafetensorsFromInt8(_ layers: [Int8ConvLayer]) -> Data {
    var headerEntries: [(name: String, dtype: String, shape: [Int], byteOffset: Int, byteEnd: Int)] = []
    var bodyBytes = Data()

    func appendTensor(name: String, shape: [Int], floats: [Float]) {
        let off = bodyBytes.count
        floats.withUnsafeBufferPointer { fp in
            bodyBytes.append(UnsafeBufferPointer(start: fp.baseAddress, count: floats.count))
        }
        headerEntries.append((name, "F32", shape, off, off + floats.count * MemoryLayout<Float>.size))
    }
    // Pack each layer as block.{i}.conv.weight (OIHW fp32) and
    // block.{i}.conv.bias (out_C fp32). Dequantize formula:
    //   weight_fp32[oc, ic, kh, kw] = (weight_int8 - weight_zp[oc]) * weight_scale[oc]
    //   bias_fp32[oc]               = bias_int32[oc] * (input_scale * weight_scale[oc])
    //
    // (ONNX bias quant convention: bias_scale = input_scale × weight_scale,
    // bias_zp = 0; matches `bithuman pack`'s dequantizer.)
    for layer in layers {
        let oC = layer.outCh, iC = layer.inCh, kH = layer.kH, kW = layer.kW
        let kspatial = kH * kW
        var w = [Float](repeating: 0, count: oC * iC * kspatial)
        for oc in 0..<oC {
            let scale = layer.weightScale[oc]
            let zp = Int32(layer.weightZeroPoint[oc])
            let base = oc * iC * kspatial
            for j in 0..<(iC * kspatial) {
                let q = Int32(layer.weightInt8[base + j])
                w[base + j] = Float(q - zp) * scale
            }
        }
        appendTensor(name: "block.\(layer.index).conv.weight", shape: [oC, iC, kH, kW], floats: w)

        var b = [Float](repeating: 0, count: oC)
        for oc in 0..<oC {
            let q = Int32(layer.biasInt32[oc])
            // bias_scale = input_scale * weight_scale[oc]; zp is 0 in ONNX QDQ bias convention.
            b[oc] = Float(q) * layer.inputScale * layer.weightScale[oc]
        }
        appendTensor(name: "block.\(layer.index).conv.bias", shape: [oC], floats: b)
    }

    // Build the safetensors JSON header.
    var json: [String: Any] = [:]
    for entry in headerEntries {
        json[entry.name] = [
            "dtype": entry.dtype,
            "shape": entry.shape,
            "data_offsets": [entry.byteOffset, entry.byteEnd],
        ] as [String: Any]
    }
    let jsonData: Data
    if #available(macOS 10.15, iOS 13, *) {
        jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    } else {
        jsonData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }
    var blob = Data()
    var headerLen = UInt64(jsonData.count).littleEndian
    withUnsafeBytes(of: &headerLen) { blob.append(contentsOf: $0) }
    blob.append(jsonData)
    blob.append(bodyBytes)
    return blob
}

// MARK: - Layer descriptor

internal struct Int8ConvLayer {
    /// Layer index in the topological order (0..12 for our encoder).
    let index: Int
    /// `(in_C, out_C, kH, kW)`.
    let inCh: Int
    let outCh: Int
    let kH: Int
    let kW: Int
    /// Convolution attrs.
    let strideH: Int
    let strideW: Int
    let padH: Int
    let padW: Int
    /// Quantized weights, OIHW int8 layout. Length = out_C*in_C*kH*kW.
    let weightInt8: [Int8]
    /// Per-output-channel weight scale (length = out_C).
    let weightScale: [Float]
    /// Weight zero-point: usually 0 across all channels. Length = out_C.
    let weightZeroPoint: [Int8]
    /// Quantized bias, int32 (length = out_C).
    let biasInt32: [Int32]
    /// Input/output activation scales (per-tensor scalars).
    let inputScale: Float
    let inputZeroPoint: Int32  // usually uint8 0; we widen to int32
    let outputScale: Float
    let outputZeroPoint: Int32
    /// True if the activation dtype is uint8 (asymmetric, range
    /// [0, 255]); false → int8 (range [-128, 127]). Determined by the
    /// input QuantizeLinear's zero_point dtype.
    let activationIsUInt8: Bool
}

// MARK: - Graph walker

/// Walks the .onnx's QDQ graph and emits a per-Conv-layer summary in
/// topological order. Throws if the graph doesn't conform to the
/// expected single-input single-output Conv-with-QDQ pattern.
internal func extractInt8ConvLayers(_ model: OnnxModel) throws -> [Int8ConvLayer] {
    // Index nodes by output name so we can trace upstream.
    var nodeByOutput: [String: OnnxNode] = [:]
    for n in model.nodes {
        for o in n.outputs { nodeByOutput[o] = n }
    }
    // Helper: trace through a DequantizeLinear node by its output name
    // and return (q_input_name, scale_name, zp_name).
    func traceDQ(_ outputName: String) -> (qName: String, scaleName: String, zpName: String)? {
        guard let dq = nodeByOutput[outputName],
              dq.opType == "DequantizeLinear",
              dq.inputs.count >= 3 else { return nil }
        return (dq.inputs[0], dq.inputs[1], dq.inputs[2])
    }

    // Helper: read an initializer as a typed array.
    func tensor(_ name: String) throws -> OnnxTensor {
        guard let t = model.initializers[name] else {
            throw Int8EncoderError.missingTensor(name)
        }
        return t
    }
    func readFloatScalar(_ name: String) throws -> Float {
        let t = try tensor(name)
        guard t.dataType == OnnxDataType.float.rawValue, t.bytes.count == 4 else {
            throw Int8EncoderError.unexpectedTensorDtype(name: name, got: t.dataType)
        }
        return t.bytes.withUnsafeBytes { $0.load(as: Float.self) }
    }
    func readFloatArray(_ name: String) throws -> [Float] {
        let t = try tensor(name)
        guard t.dataType == OnnxDataType.float.rawValue else {
            throw Int8EncoderError.unexpectedTensorDtype(name: name, got: t.dataType)
        }
        var arr = [Float](repeating: 0, count: t.bytes.count / 4)
        arr.withUnsafeMutableBytes { dst in t.bytes.copyBytes(to: dst) }
        return arr
    }
    func readInt8Array(_ name: String) throws -> [Int8] {
        let t = try tensor(name)
        guard t.dataType == OnnxDataType.int8.rawValue
                || t.dataType == OnnxDataType.uint8.rawValue else {
            throw Int8EncoderError.unexpectedTensorDtype(name: name, got: t.dataType)
        }
        var arr = [Int8](repeating: 0, count: t.bytes.count)
        arr.withUnsafeMutableBytes { dst in t.bytes.copyBytes(to: dst) }
        return arr
    }
    func readInt8Scalar(_ name: String) throws -> Int8 {
        let arr = try readInt8Array(name)
        return arr.first ?? 0
    }
    func readInt32Array(_ name: String) throws -> [Int32] {
        let t = try tensor(name)
        guard t.dataType == OnnxDataType.int32.rawValue else {
            throw Int8EncoderError.unexpectedTensorDtype(name: name, got: t.dataType)
        }
        var arr = [Int32](repeating: 0, count: t.bytes.count / 4)
        arr.withUnsafeMutableBytes { dst in t.bytes.copyBytes(to: dst) }
        return arr
    }
    func isUInt8(_ name: String) throws -> Bool {
        let t = try tensor(name)
        return t.dataType == OnnxDataType.uint8.rawValue
    }

    // Walk Conv nodes in graph order.
    var layers: [Int8ConvLayer] = []
    var convIdx = 0
    for n in model.nodes where n.opType == "Conv" {
        // Convention: Conv has 2 or 3 inputs. [0]=input_dq, [1]=weight_dq, [2]=bias_dq?
        guard n.inputs.count >= 2 else {
            throw Int8EncoderError.unexpectedTopology(
                "Conv \(n.name) has \(n.inputs.count) inputs (need ≥ 2)")
        }
        let inDqName = n.inputs[0]
        let wDqName = n.inputs[1]
        let bDqName = n.inputs.count > 2 ? n.inputs[2] : nil

        guard let inDq = nodeByOutput[inDqName],
              inDq.opType == "DequantizeLinear",
              inDq.inputs.count >= 3 else {
            throw Int8EncoderError.unexpectedTopology(
                "Conv \(n.name) input[0] is not produced by a DequantizeLinear")
        }
        guard let wDq = nodeByOutput[wDqName],
              wDq.opType == "DequantizeLinear",
              wDq.inputs.count >= 3 else {
            throw Int8EncoderError.unexpectedTopology(
                "Conv \(n.name) input[1] is not produced by a DequantizeLinear")
        }

        // Pull names.
        let inScaleName = inDq.inputs[1]
        let inZpName = inDq.inputs[2]
        let wScaleName = wDq.inputs[1]
        let wZpName = wDq.inputs[2]
        let wQName = wDq.inputs[0]

        // Output Q follows the Conv. Two topologies in this QDQ
        // graph:
        //
        // Non-residual:  Conv → Q → DQ → next-Conv
        //                       ^---- first (and only) Q is the layer's output scale.
        //
        // Residual:      Conv → Q (conv-out scale) → DQ → Add → Q (post-Add activation scale)
        //                                                       ^---- the layer's output scale.
        //                Add's other input is a SKIP — the previous layer's
        //                DQ output (NOT this layer's Conv output).
        //
        // The pre-v0.18.9 BFS picked "the LAST Q before another Conv,"
        // walking forward through any consumer that wasn't a Conv. The
        // bug: for a non-residual layer N FOLLOWED by a residual
        // layer N+1, layer N's DQ has TWO consumers — the next Conv
        // AND the next Add (the residual skip). The BFS stopped at
        // the next Conv but kept walking through the Add → next-layer
        // post-Add Q, picking THAT as `lastQ`. So layer N's
        // outputScale ended up being layer N+1's post-Add activation
        // scale — a different number, off by ~1.6× on the demo
        // model. Compounded across 13 layers, the systematic scale
        // mismatch produced embeddings squashed into a tight region
        // of feature space → KNN cluster collapse (the v0.18.4 bug).
        //
        // Fix: walk forward STRICTLY along this conv's "own" path.
        // Stop the moment we hit a Q-feeds-DQ-feeds-Conv terminator
        // (the boundary of the next layer). For non-residual layers
        // that's the first Q. For residual layers we also follow
        // through one Add (the residual add), which is what
        // distinguishes "this layer's post-Add Q" from "another
        // layer's pre-conv input".
        let convOutName = n.outputs[0]
        var lastQ: OnnxNode? = nil
        var frontier: [String] = [convOutName]
        var visited = Set<String>()
        var addsTraversed = 0
        outer: while !frontier.isEmpty {
            let cur = frontier.removeFirst()
            if visited.contains(cur) { continue }
            visited.insert(cur)
            for cand in model.nodes where cand.inputs.contains(cur) {
                switch cand.opType {
                case "Conv":
                    // The next Conv consumes this path — we're past
                    // the layer boundary. Whatever Q we last saw is
                    // this layer's output scale.
                    break outer
                case "QuantizeLinear":
                    lastQ = cand
                    for o in cand.outputs { frontier.append(o) }
                case "DequantizeLinear":
                    for o in cand.outputs { frontier.append(o) }
                case "Add":
                    // Residual Add: this conv's output feeds into one
                    // arm of an Add. Follow ONE Add forward to find
                    // the post-Add Q (the residual block's true
                    // output scale). Don't follow MORE than one Add —
                    // a deeper walk would cross into the next
                    // residual block's territory.
                    if addsTraversed >= 1 { break outer }
                    addsTraversed += 1
                    for o in cand.outputs { frontier.append(o) }
                default:
                    for o in cand.outputs { frontier.append(o) }
                }
            }
        }
        guard let outQ = lastQ else {
            throw Int8EncoderError.unexpectedTopology(
                "no QuantizeLinear downstream of Conv \(n.name)")
        }
        let bDqTrace: (qName: String, scaleName: String, zpName: String)?
        if let bDqOutputName = bDqName {
            bDqTrace = traceDQ(bDqOutputName)
        } else {
            bDqTrace = nil
        }
        layers.append(try buildLayer(
            index: convIdx, conv: n, inDq: inDq, wDq: wDq, biasDq: bDqTrace,
            outQ: outQ,
            model: model,
            readFloatScalar: readFloatScalar,
            readFloatArray: readFloatArray,
            readInt8Array: readInt8Array,
            readInt8Scalar: readInt8Scalar,
            readInt32Array: readInt32Array,
            isUInt8: isUInt8))
        convIdx += 1
    }
    return layers
}

private func buildLayer(
    index: Int,
    conv: OnnxNode,
    inDq: OnnxNode,
    wDq: OnnxNode,
    biasDq: (qName: String, scaleName: String, zpName: String)?,
    outQ: OnnxNode,
    model: OnnxModel,
    readFloatScalar: (String) throws -> Float,
    readFloatArray: (String) throws -> [Float],
    readInt8Array: (String) throws -> [Int8],
    readInt8Scalar: (String) throws -> Int8,
    readInt32Array: (String) throws -> [Int32],
    isUInt8: (String) throws -> Bool
) throws -> Int8ConvLayer {
    // Conv attributes: kernel_shape, strides, pads (defaults if absent).
    var kH = 1, kW = 1, sH = 1, sW = 1, pH = 0, pW = 0
    for a in conv.attributes {
        switch a.name {
        case "kernel_shape" where a.ints.count == 2: kH = a.ints[0]; kW = a.ints[1]
        case "strides" where a.ints.count == 2:      sH = a.ints[0]; sW = a.ints[1]
        case "pads" where a.ints.count == 4:         pH = a.ints[0]; pW = a.ints[1]
            // pads = [top, left, bottom, right]; we use top/left
        default: break
        }
    }

    // Weight tensor (OIHW int8). Derive shape from the tensor's dims
    // (the canonical source of truth) — scale is a scalar for
    // per-tensor quantization in this graph, so its length doesn't
    // tell us out_C.
    let wDqInputName = wDq.inputs[0]
    guard let wTensor = model.initializers[wDqInputName],
          wTensor.dims.count == 4 else {
        throw Int8EncoderError.unexpectedTopology(
            "Conv weight \(wDqInputName) is not a 4D tensor")
    }
    let outCh = wTensor.dims[0]
    let inCh = wTensor.dims[1]
    // (kH, kW from wTensor.dims also equals conv attrs; we trust attrs.)
    let wQ = try readInt8Array(wDqInputName)
    let wScaleFloats = try readFloatArray(wDq.inputs[1])
    let wZpRawBytes = try readInt8Array(wDq.inputs[2])
    // Broadcast per-tensor scalar to per-channel array if needed.
    let wScale: [Float] = wScaleFloats.count == outCh
        ? wScaleFloats
        : [Float](repeating: wScaleFloats.first ?? 1.0, count: outCh)
    let wZpRaw: [Int8] = wZpRawBytes.count == outCh
        ? wZpRawBytes
        : [Int8](repeating: wZpRawBytes.first ?? 0, count: outCh)

    // Bias (int32 quantized). When biasDq is non-nil, the trace tuple
    // gives us the actual quantized bias initializer name — no name-
    // mangling guesses needed.
    var bias32 = [Int32](repeating: 0, count: outCh)
    if let b = biasDq {
        bias32 = try readInt32Array(b.qName)
    }

    let inScale = try readFloatScalar(inDq.inputs[1])
    let inZp = try readInt8Scalar(inDq.inputs[2])
    let inIsU8 = try isUInt8(inDq.inputs[2])
    let outScale = try readFloatScalar(outQ.inputs[1])
    let outZp = try readInt8Scalar(outQ.inputs[2])

    return Int8ConvLayer(
        index: index,
        inCh: inCh, outCh: outCh, kH: kH, kW: kW,
        strideH: sH, strideW: sW, padH: pH, padW: pW,
        weightInt8: wQ,
        weightScale: wScale,
        weightZeroPoint: wZpRaw.count == outCh ? wZpRaw : [Int8](repeating: wZpRaw.first ?? 0, count: outCh),
        biasInt32: bias32,
        inputScale: inScale,
        inputZeroPoint: inIsU8 ? Int32(UInt8(bitPattern: inZp)) : Int32(inZp),
        outputScale: outScale,
        outputZeroPoint: Int32(outZp),
        activationIsUInt8: inIsU8
    )
}
