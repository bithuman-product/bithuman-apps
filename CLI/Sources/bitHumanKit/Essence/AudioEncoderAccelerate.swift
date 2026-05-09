/// Pure-Apple-Accelerate audio encoder for the Essence runtime.
///
/// Hand-implements the 13-conv-layer encoder against `cblas_sgemm` +
/// custom im2col, using only Accelerate / vDSP / BNNS — no ONNX
/// Runtime, no MLX. The point is twofold:
///
/// 1. **Drop the 80 MB ONNX Runtime SPM dependency** the ORT-based
///    `AudioEncoder` (in `AudioEncoder.swift`) re-introduced in
///    0.10.1 to get byte-equivalent embeddings vs Python. ORT's
///    static lib is fine for desktop but is half the binary on
///    iPhone, so a native path matters for mobile distribution.
///
/// 2. **Open the door to int8 quantization**. ORT's CPU INT8 EP is
///    fine but a hand-rolled BNNS path lets us pick quant schemes
///    that map exactly to the .imx pack pipeline.
///
/// Numerical fidelity: we run float32 cblas (Apple Accelerate) where
/// ORT runs float32 MLAS. Both are heavily-tuned NEON GEMMs; outputs
/// agree to ≤ 1e-4 max-abs in our cross-SDK comparator runs, which is
/// well below the KNN cluster-margin (~2-5 in distance²) for every
/// frame in the bench fixture. KNN cluster-pick agreement holds at
/// 100% on a 250-frame demo audio sweep.
///
/// ## Architecture
///
/// 13 blocks, channel ladder
/// `1 → 32 → 32 → 32 → 64 → 64 → 64 → 128 → 128 → 128 → 256 → 256 → 512 → 512`,
/// residuals on blocks 1, 2, 4, 5, 7, 8, 10. Each block is
/// `Conv2D + ReLU` (or `Conv2D + Add(input) + ReLU` for residuals).
/// All weights are 3×3 except block 12's 1×1. The implicit ReLU is
/// folded into the original ONNX QDQ quant op; we re-insert it
/// explicitly. Spec input/output: **NCHW** `(1, 1, 80, 16)` →
/// `(1, 512, 1, 1)`.
///
/// ## Layout
///
/// We work in NCHW throughout (planar-channels). The conv operator
/// uses an im2col → matmul strategy:
///   1. im2col(x: [in_C, H, W]) → [in_C * kH * kW, oH * oW]
///   2. cblas_sgemm: weight [out_C, in_C * kH * kW] × col → [out_C, oH * oW]
///   3. add bias and ReLU in-place
///
/// All buffers are `[Float]` allocated up-front and reused across
/// frames; each layer has a stable input/output shape so the encode
/// hot-path performs no heap allocation.

import Accelerate
import Foundation

// MARK: - Errors

internal enum AudioEncoderAccelerateError: Error, CustomStringConvertible {
    case shortRead(String)
    case badHeader(String)
    case unknownDtype(String)
    case missingTensor(String)
    case wrongShape(String, expected: [Int], got: [Int])

    internal var description: String {
        switch self {
        case .shortRead(let m):       return "AudioEncoder: safetensors short read — \(m)"
        case .badHeader(let m):       return "AudioEncoder: safetensors bad header — \(m)"
        case .unknownDtype(let s):    return "AudioEncoder: unknown dtype '\(s)'"
        case .missingTensor(let k):   return "AudioEncoder: missing tensor '\(k)'"
        case .wrongShape(let k, let want, let got):
            return "AudioEncoder: tensor '\(k)' shape \(got) ≠ expected \(want)"
        }
    }
}

// MARK: - Block table (one row per Conv2D layer)

/// Fixed block table for the 13-conv-layer encoder. Tuple is
/// `(inCh, outCh, kH, kW, sH, sW, pH, pW, residual)`.
/// Mirrors the table in the legacy MLX implementation.
private let kBlockTable: [(inCh: Int, outCh: Int, kH: Int, kW: Int, sH: Int, sW: Int, pH: Int, pW: Int, residual: Bool)] = [
    (1,    32, 3, 3, 1, 1, 1, 1, false), // 0: stem
    (32,   32, 3, 3, 1, 1, 1, 1, true),  // 1
    (32,   32, 3, 3, 1, 1, 1, 1, true),  // 2
    (32,   64, 3, 3, 3, 1, 1, 1, false), // 3
    (64,   64, 3, 3, 1, 1, 1, 1, true),  // 4
    (64,   64, 3, 3, 1, 1, 1, 1, true),  // 5
    (64,  128, 3, 3, 3, 3, 1, 1, false), // 6
    (128, 128, 3, 3, 1, 1, 1, 1, true),  // 7
    (128, 128, 3, 3, 1, 1, 1, 1, true),  // 8
    (128, 256, 3, 3, 3, 2, 1, 1, false), // 9
    (256, 256, 3, 3, 1, 1, 1, 1, true),  // 10
    (256, 512, 3, 3, 1, 1, 0, 0, false), // 11 (no padding)
    (512, 512, 1, 1, 1, 1, 0, 0, false), // 12 (1×1 head)
]

// MARK: - Safetensors loader (float32 only)

/// Parse the bare-minimum we need from the safetensors blob: a flat
/// `[Float]` plus a shape per named tensor. `bithuman pack ≥ 1.10.8`
/// dequantizes the int8 quant model to float32 in this entry, so the
/// dtype is always F32.
private func parseSafetensorsF32(
    _ data: Data
) throws -> [String: (shape: [Int], values: [Float])] {
    guard data.count >= 8 else {
        throw AudioEncoderAccelerateError.shortRead("header length")
    }
    let headerLen = data.prefix(8).withUnsafeBytes {
        $0.load(as: UInt64.self)
    }.littleEndian
    let headerEnd = 8 + Int(headerLen)
    guard data.count >= headerEnd else {
        throw AudioEncoderAccelerateError.shortRead("JSON header")
    }
    let jsonData = data.subdata(in: 8..<headerEnd)
    guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        throw AudioEncoderAccelerateError.badHeader("not a JSON object")
    }

    var out: [String: (shape: [Int], values: [Float])] = [:]
    out.reserveCapacity(json.count)
    for (key, meta) in json {
        if key == "__metadata__" { continue }
        guard let m = meta as? [String: Any],
              let dtype = m["dtype"] as? String,
              let shape = m["shape"] as? [Int],
              let offsets = m["data_offsets"] as? [Int], offsets.count == 2
        else {
            throw AudioEncoderAccelerateError.badHeader("bad entry for \(key)")
        }
        guard dtype == "F32" else {
            throw AudioEncoderAccelerateError.unknownDtype(dtype)
        }
        let byteStart = headerEnd + offsets[0]
        let byteEnd   = headerEnd + offsets[1]
        guard byteEnd <= data.count else {
            throw AudioEncoderAccelerateError.shortRead("tensor body \(key)")
        }
        let count = (byteEnd - byteStart) / MemoryLayout<Float>.size
        var values = [Float](repeating: 0, count: count)
        values.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst, from: byteStart..<byteEnd)
        }
        out[key] = (shape, values)
    }
    return out
}

// MARK: - Encoder

internal final class AudioEncoderAccelerate {

    /// Per-block weights (OIHW float32) and biases, plus output spatial
    /// dims after the layer. Computed at init and held forever.
    private struct Block {
        let inCh: Int
        let outCh: Int
        let kH: Int
        let kW: Int
        let sH: Int
        let sW: Int
        let pH: Int
        let pW: Int
        let residual: Bool
        /// Reshaped to (outCh, inCh*kH*kW) row-major so a single
        /// `cblas_sgemm` against the im2col matrix produces output.
        let weight: [Float]
        let bias: [Float]
        /// Spatial dims of input feeding this block.
        let inH: Int
        let inW: Int
        /// Spatial dims of output (= input dims of next block).
        let outH: Int
        let outW: Int
    }

    private let blocks: [Block]
    /// Pre-allocated working buffers reused across encode() calls.
    /// Size set to the largest tensor seen across all 13 layers so a
    /// single allocation services every block.
    private var actA: [Float]      // current activation (ping)
    private var actB: [Float]      // current activation (pong)
    private var im2colBuf: [Float] // reused im2col matrix

    /// Constructs from a safetensors blob (the .imx's
    /// `audio_encoder.safetensors` entry). Tensors must be named
    /// `block.{i}.conv.weight` (out_ch, in_ch, kH, kW) and
    /// `block.{i}.conv.bias` (out_ch,).
    internal init(safetensorsBytes: Data) throws {
        let dict = try parseSafetensorsF32(safetensorsBytes)
        // Build blocks following the fixed table.
        var built: [Block] = []
        built.reserveCapacity(kBlockTable.count)
        var H = 80, W = 16
        var maxAct = 0
        var maxIm2col = 0
        for (i, t) in kBlockTable.enumerated() {
            let wKey = "block.\(i).conv.weight"
            let bKey = "block.\(i).conv.bias"
            guard let weightT = dict[wKey] else {
                throw AudioEncoderAccelerateError.missingTensor(wKey)
            }
            guard let biasT = dict[bKey] else {
                throw AudioEncoderAccelerateError.missingTensor(bKey)
            }
            let wantW: [Int] = [t.outCh, t.inCh, t.kH, t.kW]
            let wantB: [Int] = [t.outCh]
            guard weightT.shape == wantW else {
                throw AudioEncoderAccelerateError.wrongShape(wKey, expected: wantW, got: weightT.shape)
            }
            guard biasT.shape == wantB else {
                throw AudioEncoderAccelerateError.wrongShape(bKey, expected: wantB, got: biasT.shape)
            }
            // Compute output dims for the whole pipeline up front so
            // we know the largest activation buffer we'll ever need.
            let outH = (H + 2 * t.pH - t.kH) / t.sH + 1
            let outW = (W + 2 * t.pW - t.kW) / t.sW + 1
            let inSize = t.inCh * H * W
            let outSize = t.outCh * outH * outW
            let im2colSize = (t.inCh * t.kH * t.kW) * (outH * outW)
            maxAct = max(maxAct, max(inSize, outSize))
            maxIm2col = max(maxIm2col, im2colSize)
            built.append(Block(
                inCh: t.inCh, outCh: t.outCh,
                kH: t.kH, kW: t.kW,
                sH: t.sH, sW: t.sW,
                pH: t.pH, pW: t.pW,
                residual: t.residual,
                weight: weightT.values, bias: biasT.values,
                inH: H, inW: W, outH: outH, outW: outW
            ))
            H = outH; W = outW
        }
        self.blocks = built
        self.actA = [Float](repeating: 0, count: maxAct)
        self.actB = [Float](repeating: 0, count: maxAct)
        self.im2colBuf = [Float](repeating: 0, count: maxIm2col)
    }

    /// Run the encoder on a flat (80*16) row-major float32 mel chunk.
    /// Returns the (1, 512, 1, 1) embedding flattened to 512 floats.
    internal func encode(mel: [Float]) -> [Float] {
        precondition(mel.count == 80 * 16, "mel must be 80*16 floats; got \(mel.count)")
        // Initial copy: mel layout is (H=80, W=16) C-order, in_C=1 so
        // NCHW packing is identical to the row-major mel.
        let firstSize = 1 * 80 * 16
        actA.withUnsafeMutableBufferPointer { dst in
            mel.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress!, count: firstSize)
            }
        }
        var (inBuf, outBuf) = (UnsafeRawBufferPointer(start: nil, count: 0),
                               UnsafeRawBufferPointer(start: nil, count: 0))
        _ = (inBuf, outBuf)

        // Optional per-layer dump — pair of `BITHUMAN_DUMP_LAYERS=<dir>`
        // with the int8 path; comparator sees both encoders' fp32 layer
        // outputs side-by-side.
        let dumpDir = ProcessInfo.processInfo.environment["BITHUMAN_DUMP_LAYERS"]

        var srcSwap = true // true = read from actA, write to actB
        for (li, b) in blocks.enumerated() {
            if srcSwap {
                forwardBlock(b, src: &actA, dst: &actB)
            } else {
                forwardBlock(b, src: &actB, dst: &actA)
            }
            srcSwap.toggle()

            if let dir = dumpDir {
                let out = srcSwap ? actA : actB
                let n = b.outCh * b.outH * b.outW
                let url = URL(fileURLWithPath: dir)
                    .appendingPathComponent(String(format: "fp32_layer_%02d.bin", li))
                out.prefix(n).withUnsafeBufferPointer { bp in
                    let data = Data(bytes: bp.baseAddress!,
                                    count: n * MemoryLayout<Float>.size)
                    try? data.write(to: url)
                }
            }
        }
        // After the final iteration `srcSwap` toggled past the final
        // dest, so the latest output lives in whichever buffer was
        // the dst on the last block.
        let result = srcSwap ? actA : actB
        // Block 12's output is (1, 512, 1, 1) — first 512 floats.
        return Array(result.prefix(512))
    }

    /// One-block forward pass: im2col → cblas_sgemm → bias + ReLU
    /// (+ residual add for residual blocks).
    private func forwardBlock(
        _ b: Block,
        src: inout [Float],
        dst: inout [Float]
    ) {
        let inSize = b.inCh * b.inH * b.inW
        let outSize = b.outCh * b.outH * b.outW
        let kSize = b.kH * b.kW
        let kCh = b.inCh * kSize
        let outPx = b.outH * b.outW

        // im2col: for each output pixel and each (kH, kW, in_C), gather
        // the corresponding input value. Output shape (kCh, outPx)
        // row-major; column j corresponds to output pixel (j / outW,
        // j % outW).
        src.withUnsafeBufferPointer { sp in
            im2colBuf.withUnsafeMutableBufferPointer { ip in
                let s = sp.baseAddress!, im = ip.baseAddress!
                im2col(
                    src: s, dst: im,
                    inCh: b.inCh, inH: b.inH, inW: b.inW,
                    kH: b.kH, kW: b.kW,
                    sH: b.sH, sW: b.sW,
                    pH: b.pH, pW: b.pW,
                    outH: b.outH, outW: b.outW
                )
            }
        }

        // matmul: weight (outCh, kCh) × im2col (kCh, outPx) → out (outCh, outPx)
        b.weight.withUnsafeBufferPointer { wp in
            im2colBuf.withUnsafeBufferPointer { ip in
                dst.withUnsafeMutableBufferPointer { dp in
                    cblas_sgemm(
                        CblasRowMajor, CblasNoTrans, CblasNoTrans,
                        Int32(b.outCh), Int32(outPx), Int32(kCh),
                        1.0,
                        wp.baseAddress, Int32(kCh),
                        ip.baseAddress, Int32(outPx),
                        0.0,
                        dp.baseAddress, Int32(outPx)
                    )
                }
            }
        }

        // Add bias (broadcast across spatial), optional residual add,
        // ReLU. All in-place on the output buffer.
        dst.withUnsafeMutableBufferPointer { dp in
            let d = dp.baseAddress!
            // Bias: each of outCh rows gets b.bias[oc] added to all outPx.
            for oc in 0..<b.outCh {
                var v = b.bias[oc]
                vDSP_vsadd(d.advanced(by: oc * outPx), 1, &v,
                           d.advanced(by: oc * outPx), 1, vDSP_Length(outPx))
            }
            // Residual: y = y + x (broadcast over the same shape).
            // Only valid when in_dims == out_dims AND in_C == out_C —
            // which the block table guarantees for residual blocks.
            if b.residual {
                src.withUnsafeBufferPointer { sp in
                    let s = sp.baseAddress!
                    vDSP_vadd(d, 1, s, 1, d, 1, vDSP_Length(outSize))
                }
            }
            // ReLU: max(x, 0). vDSP_vthr clips below the threshold to
            // the threshold; with threshold=0 that's exactly ReLU.
            var zero: Float = 0
            vDSP_vthr(d, 1, &zero, d, 1, vDSP_Length(outSize))
        }
        _ = inSize // silence unused-var warning while keeping doc
    }
}

// MARK: - im2col

/// Rearranges a `(inCh, inH, inW)` NCHW activation into a
/// `(inCh*kH*kW, outH*outW)` matrix where each column j corresponds
/// to the receptive field of output pixel `(j / outW, j % outW)`. The
/// matmul `weight × im2col` then produces the conv output as
/// `(outCh, outH*outW)`. Standard im2col, well-understood; the
/// scalar loop is trivially compiled to NEON loads.
@inline(__always)
private func im2col(
    src: UnsafePointer<Float>,
    dst: UnsafeMutablePointer<Float>,
    inCh: Int, inH: Int, inW: Int,
    kH: Int, kW: Int,
    sH: Int, sW: Int,
    pH: Int, pW: Int,
    outH: Int, outW: Int
) {
    let outPx = outH * outW
    var rowIdx = 0
    for ic in 0..<inCh {
        let chBase = ic * inH * inW
        for ki in 0..<kH {
            for kj in 0..<kW {
                let dstRow = dst.advanced(by: rowIdx * outPx)
                var col = 0
                for oi in 0..<outH {
                    let si = oi * sH - pH + ki
                    let validRow = si >= 0 && si < inH
                    let rowBase = chBase + si * inW
                    for oj in 0..<outW {
                        let sj = oj * sW - pW + kj
                        if validRow && sj >= 0 && sj < inW {
                            dstRow[col] = src[rowBase + sj]
                        } else {
                            dstRow[col] = 0
                        }
                        col &+= 1
                    }
                }
                rowIdx &+= 1
            }
        }
    }
}
