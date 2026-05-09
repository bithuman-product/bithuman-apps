/// Native int8 forward pass for the Essence audio encoder.
///
/// Operates directly on the int8 weights extracted from the .imx's
/// `audio_encoder.onnx` QDQ graph (see `Int8Encoder.swift`) — no
/// fp32 dequantization at init, no ONNX Runtime dependency.
///
/// Inner GEMM is a tight Swift loop with int32 accumulator,
/// structured to autovectorize cleanly on Apple Silicon NEON
/// (LLVM picks this up at `-O` with widening multiply +
/// horizontal sum). For the bench fixture's 13-layer encoder this
/// runs ~0.8-1.0 ms per inference on M5 — recovering most of the
/// per-frame speed gap to v0.10.x's ORT MLAS path while keeping
/// v0.11.0's binary-size win (no static-lib cost beyond Accelerate
/// which is already linked).
///
/// **Forward pipeline (per Conv layer):**
///
///   1. **im2col** rearranges the uint8 input activations into a
///      `(in_C * kH * kW, out_pixels)` matrix so the conv can be
///      expressed as a matmul.
///   2. **int8 GEMM** computes `int32_out = int8_w · (uint8_x −
///      input_zp)` per output element.
///   3. **Bias add** in int32 space.
///   4. **Residual add** (residual blocks only) — performed in
///      fp32 across the QDQ boundary because the skip and conv
///      generally have different scales.
///   5. **Requantize** int32 → uint8 with per-channel multiplier
///      `M[oc] = (input_scale × weight_scale[oc]) / output_scale`.
///      The clamp range `[0, 255]` folds in the implicit ReLU
///      (output_zp = 0 in this graph).
///
/// **Output**: the final layer (block 12) emits a uint8 tensor of
/// shape `(1, 512, 1, 1)`. We dequantize via
/// `fp32 = (uint8 − output_zp) × output_scale` to produce the
/// 512-element embedding the KNN consumes.
///
/// **Numeric drift vs ORT**: per-frame KNN agreement holds because
/// the int8 weights and per-tensor scales are taken directly from
/// the QDQ graph; the only freedom is in the int32 → uint8
/// requantization rounding (we use round-to-nearest-even to match
/// MLAS' typical mode). End-to-end PSNR unchanged from the fp32
/// bridge path (validated by the cross-SDK fixture corpus).

import Accelerate
import BitHumanInt8Conv
import Foundation

// MARK: - Per-layer descriptor (compute-ready form of Int8ConvLayer)

internal struct Int8ForwardLayer {
    let inCh: Int
    let outCh: Int
    let kH: Int
    let kW: Int
    let sH: Int
    let sW: Int
    let pH: Int
    let pW: Int
    /// Spatial dims of input feeding this layer.
    let inH: Int
    let inW: Int
    /// Spatial dims of output (= input dims of next layer).
    let outH: Int
    let outW: Int
    /// True if this layer's output is `relu(conv(x) + x)` — i.e. the
    /// pre-conv activation is added back in fp32 before the output
    /// quantize.
    let residual: Bool

    /// kCh = inCh * kH * kW.
    let kCh: Int
    /// kCh rounded up to multiple of 4 — required by the SDOT inner
    /// loop. Pad K bytes hold 0 (weights pad to 0; the matching
    /// activation pad bytes are also 0 after the XOR-128 shift).
    let kChPadded: Int
    /// Quantized weights, (outCh, kChPadded) row-major, K-zero-padded.
    /// Length = outCh * kChPadded.
    let weightPadded: [Int8]
    /// Bias with the input-zp shift folded in:
    ///   biasCorrected[oc] = bias[oc] + (128 - inputZp) * sum_k(weights[oc][k])
    /// SDOT operates on `act_s8 = act_u8 - 128`; this term plus the
    /// pure dot product reconstructs the original `(act_u8 - inputZp)
    /// · w` formulation. Length = outCh.
    let biasCorrected: [Int32]
    /// Per-output-channel requant multiplier (input_scale ×
    /// weight_scale[oc] / output_scale) — applied as
    /// `out_int8 ≈ round(int32_acc × M[oc]) + output_zp`.
    let requantMul: [Float]
    /// Per-tensor input zero-point. Folded into `biasCorrected` for
    /// the SDOT path; kept here for the residual-bridge dequant
    /// (which still references the original scale + zp).
    let inputZp: Int32
    /// Output zero point — added after the requant multiply, then
    /// the value is clamped to `[0, 255]` (uint8 range).
    let outputZp: Int32
    /// Input/output dequantization scales used at the residual-add
    /// boundary (residual blocks only).
    let inputScale: Float
    let outputScale: Float
}

// MARK: - Forward kernel

internal final class Int8Forward {

    private let blocks: [Int8ForwardLayer]

    /// True iff the host CPU supports the ARM v8.6 i8mm extension
    /// (FEAT_I8MM, available on Apple M2 / A15 and later). Selects
    /// the SMMLA-based GEMM kernel in `forwardBlock`; otherwise the
    /// SDOT path runs.
    private let hasI8mm: Bool

    // MARK: - Profiling (BITHUMAN_PROFILE=1)
    //
    // Per-stage cumulative timers in nanoseconds. Sampled inside
    // `forwardBlock` when the env-var gate fires once at init.
    // Print via `dumpProfile()`.
    static let profileEnabled: Bool = ProcessInfo.processInfo.environment["BITHUMAN_PROFILE"] == "1"
    var profQuantize: UInt64 = 0
    var profIm2colPack: [UInt64]
    var profGemm: [UInt64]
    var profRequant: [UInt64]
    var profResidualSnap: [UInt64]
    var profDequantize: UInt64 = 0
    var profSamples: UInt64 = 0
    @inline(__always) static func nowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }
    func dumpProfile() {
        guard Self.profileEnabled, profSamples > 0 else { return }
        let n = Double(profSamples)
        let nsToUs = { (v: UInt64) -> Double in Double(v) / n / 1000.0 }
        print("=== Int8Forward profile (\(profSamples) samples, µs/encode) ===")
        print(String(format: "  quantize input mel:    %7.2f µs", nsToUs(profQuantize)))
        var totalIm2col: UInt64 = 0, totalGemm: UInt64 = 0, totalRequant: UInt64 = 0, totalSnap: UInt64 = 0
        for i in 0..<blocks.count {
            let snapStr: String = blocks[i].residual ? String(format: "snap=%5.2f ", nsToUs(profResidualSnap[i])) : ""
            print(String(format: "  L%-2d %@%@i2c=%5.2f gemm=%6.2f reqOrRes=%5.2f total=%6.2f",
                i,
                blocks[i].residual ? "[R] " : "    ",
                snapStr,
                nsToUs(profIm2colPack[i]),
                nsToUs(profGemm[i]),
                nsToUs(profRequant[i]),
                nsToUs(profIm2colPack[i] &+ profGemm[i] &+ profRequant[i] &+ profResidualSnap[i])
            ))
            totalIm2col &+= profIm2colPack[i]
            totalGemm &+= profGemm[i]
            totalRequant &+= profRequant[i]
            totalSnap &+= profResidualSnap[i]
        }
        print(String(format: "  dequantize output:     %7.2f µs", nsToUs(profDequantize)))
        let total = totalIm2col &+ totalGemm &+ totalRequant &+ totalSnap &+ profQuantize &+ profDequantize
        print(String(format: "  --- totals ---"))
        print(String(format: "    im2col-pack:         %7.2f µs (%.1f%%)", nsToUs(totalIm2col), 100*Double(totalIm2col)/Double(total)))
        print(String(format: "    GEMM (SDOT):         %7.2f µs (%.1f%%)", nsToUs(totalGemm),    100*Double(totalGemm)/Double(total)))
        print(String(format: "    requant/residual:    %7.2f µs (%.1f%%)", nsToUs(totalRequant), 100*Double(totalRequant)/Double(total)))
        print(String(format: "    residual snap copy:  %7.2f µs (%.1f%%)", nsToUs(totalSnap),    100*Double(totalSnap)/Double(total)))
        print(String(format: "    sum:                 %7.2f µs", nsToUs(total)))
    }

    /// Reused scratch buffers across `encode()` calls; max sizes
    /// computed at init from the layer table.
    private var actA: [UInt8]
    private var actB: [UInt8]
    /// Packed activations for the SDOT kernel: int8 (after XOR 0x80
    /// shift), transposed to (outPx, kChPadded), K-zero-padded.
    /// Filled in one pass by `bh_im2col_pack_int8`. Sized at init for
    /// the largest layer's outPx × kChPadded.
    private var actInt8T: [Int8]
    private var int32Out: [Int32]
    private var residualSkip: [UInt8]
    /// fp32 scratch for residual blocks where we cross the QDQ
    /// boundary to add the skip cleanly.
    private var fp32A: [Float]
    private var fp32B: [Float]

    /// Final layer's output scale and zero-point — used to
    /// dequantize the (1, 512, 1, 1) tensor at the end.
    private let finalOutputScale: Float
    private let finalOutputZp: Int32

    /// Builds an int8 forward kernel from the QDQ graph extraction.
    ///
    /// The `Int8ConvLayer` array comes from
    /// `extractInt8ConvLayers(parseOnnxModel(...))`. The constructor
    /// derives per-layer compute dims (inH/inW/outH/outW), residual
    /// flags, and the requantize multipliers, and pre-allocates
    /// every scratch buffer the encode hot path will need.
    internal init(layers: [Int8ConvLayer]) throws {
        precondition(!layers.isEmpty, "no layers")

        // Architecture-fixed residual table — same as the legacy MLX
        // implementation in AudioEncoder.swift (now removed). Encoded
        // here so we don't have to re-walk the .onnx graph at init
        // just to find Add ops. Block indices: 1, 2, 4, 5, 7, 8, 10.
        let residualBlocks: Set<Int> = [1, 2, 4, 5, 7, 8, 10]

        var built: [Int8ForwardLayer] = []
        built.reserveCapacity(layers.count)
        // Spatial dims at the encoder's input.
        var H = 80, W = 16
        var maxAct = 0
        var maxInt8T = 0
        var maxInt32 = 0
        var maxFp32 = 0
        for layer in layers {
            let outH = (H + 2 * layer.padH - layer.kH) / layer.strideH + 1
            let outW = (W + 2 * layer.padW - layer.kW) / layer.strideW + 1
            let kCh = layer.inCh * layer.kH * layer.kW
            // Round up to multiple of 8 — SMMLA's K-block is 8 (vs 4
            // for SDOT). Padding to 8 keeps both kernels happy with
            // a single layout; the few extra zero bytes (≤ 7 per
            // channel) cost nothing in the dot product.
            let kChPadded = (kCh + 7) & ~7
            // Per-channel requant multiplier.
            var M = [Float](repeating: 0, count: layer.outCh)
            for oc in 0..<layer.outCh {
                M[oc] = layer.inputScale * layer.weightScale[oc] / layer.outputScale
            }
            // Pad weights from (outCh, kCh) to (outCh, kChPadded)
            // with trailing zeros, so the SDOT inner loop can stride
            // through K in groups of 4 with no scalar tail.
            var weightPadded = [Int8](repeating: 0, count: layer.outCh * kChPadded)
            for oc in 0..<layer.outCh {
                let srcBase = oc * kCh
                let dstBase = oc * kChPadded
                for k in 0..<kCh {
                    weightPadded[dstBase + k] = layer.weightInt8[srcBase + k]
                }
            }
            // Fold the input-zp shift into the bias:
            //   biasCorrected[oc] = bias[oc] + (128 - inputZp)
            //                       * sum_k(weights[oc][k])
            // Padded weights contribute 0 to the sum, so iterate the
            // unpadded K range.
            let zpShift = 128 - layer.inputZeroPoint
            var biasCorrected = [Int32](repeating: 0, count: layer.outCh)
            for oc in 0..<layer.outCh {
                let base = oc * kCh
                var wsum: Int32 = 0
                for k in 0..<kCh {
                    wsum &+= Int32(layer.weightInt8[base + k])
                }
                biasCorrected[oc] = layer.biasInt32[oc] &+ zpShift &* wsum
            }
            let entry = Int8ForwardLayer(
                inCh: layer.inCh, outCh: layer.outCh,
                kH: layer.kH, kW: layer.kW,
                sH: layer.strideH, sW: layer.strideW,
                pH: layer.padH, pW: layer.padW,
                inH: H, inW: W,
                outH: outH, outW: outW,
                residual: residualBlocks.contains(layer.index),
                kCh: kCh,
                kChPadded: kChPadded,
                weightPadded: weightPadded,
                biasCorrected: biasCorrected,
                requantMul: M,
                inputZp: layer.inputZeroPoint,
                outputZp: layer.outputZeroPoint,
                inputScale: layer.inputScale,
                outputScale: layer.outputScale
            )
            built.append(entry)
            maxAct = max(maxAct, max(layer.inCh * H * W, layer.outCh * outH * outW))
            maxInt8T = max(maxInt8T, kChPadded * outH * outW)
            maxInt32 = max(maxInt32, layer.outCh * outH * outW)
            if residualBlocks.contains(layer.index) {
                maxFp32 = max(maxFp32, layer.outCh * outH * outW)
            }
            H = outH; W = outW
        }
        self.blocks = built
        // +16 bytes of trailing slack so the specialized
        // `bh_im2col_pack_int8_3x3_s1_p1` kernel can issue a 16-byte
        // `vld1q_u8` past the last source row of a channel without
        // touching unmapped memory. Lanes ≥ inW are masked to
        // `pad_fill` inside the kernel.
        self.actA = [UInt8](repeating: 0, count: maxAct + 16)
        self.actB = [UInt8](repeating: 0, count: maxAct + 16)
        self.residualSkip = [UInt8](repeating: 0, count: maxAct + 16)
        self.actInt8T = [Int8](repeating: 0, count: maxInt8T)
        self.int32Out = [Int32](repeating: 0, count: maxInt32)
        self.fp32A = [Float](repeating: 0, count: maxFp32)
        self.fp32B = [Float](repeating: 0, count: maxFp32)

        // Per-block profile counters (zero-initialized, written iff
        // BITHUMAN_PROFILE=1).
        let n = built.count
        self.profIm2colPack = [UInt64](repeating: 0, count: n)
        self.profGemm = [UInt64](repeating: 0, count: n)
        self.profRequant = [UInt64](repeating: 0, count: n)
        self.profResidualSnap = [UInt64](repeating: 0, count: n)

        let last = built.last!
        self.finalOutputScale = last.outputScale
        self.finalOutputZp = last.outputZp

        // Detect i8mm once at init. The C `bh_has_i8mm` reads
        // `hw.optional.arm.FEAT_I8MM` via sysctl on Apple Silicon
        // (returns 0 on M1/A14, 1 on M2/A15+); other platforms always
        // 0. Cheap (~1 µs).
        //
        // `BITHUMAN_DISABLE_I8MM=1` forces the SDOT fallback path
        // even on M2+, used by the regression-guard tests to exercise
        // the M1 dispatch on capable hardware.
        let detected = bh_has_i8mm() != 0
        let forceSdot = ProcessInfo.processInfo.environment["BITHUMAN_DISABLE_I8MM"] == "1"
        self.hasI8mm = detected && !forceSdot

        // Diagnostic: BITHUMAN_DUMP_INT8_SCALES=1 prints each layer's
        // input/output scales + zero points + (255-zp)*scale clamp.
        // Used to verify QDQ scale extraction matches the ONNX graph
        // ground-truth (compare to ORT's intermediate-tap dump).
        if ProcessInfo.processInfo.environment["BITHUMAN_DUMP_INT8_SCALES"] == "1" {
            for (i, b) in built.enumerated() {
                let cap = (255.0 - Float(b.outputZp)) * b.outputScale
                FileHandle.standardError.write(Data(
                    String(format: "L%02d  inScale=%.6f inZp=%3d  outScale=%.6f outZp=%3d  cap=%.4f  residual=%@\n",
                           i, b.inputScale, b.inputZp, b.outputScale, b.outputZp, cap,
                           b.residual ? "Y" : "N").utf8
                ))
            }
        }
    }

    /// Run the encoder on a flat (80*16) row-major float32 mel chunk.
    /// Returns the (1, 512, 1, 1) embedding flattened to 512 floats.
    internal func encode(mel: [Float]) -> [Float] {
        precondition(mel.count == 80 * 16, "mel must be 80*16 floats; got \(mel.count)")

        // 1. Quantize fp32 mel → uint8 using layer 0's input scale/zp.
        let t0 = Self.profileEnabled ? Self.nowNs() : 0
        let firstScale = blocks[0].inputScale
        let firstZp = blocks[0].inputZp
        let invFirstScale = 1.0 / firstScale
        let melCount = mel.count
        actA.withUnsafeMutableBufferPointer { dst in
            mel.withUnsafeBufferPointer { src in
                let s = src.baseAddress!
                let d = dst.baseAddress!
                for i in 0..<melCount {
                    let q = Int32((s[i] * invFirstScale).rounded()) + firstZp
                    d[i] = UInt8(clamping: q)
                }
            }
        }
        if Self.profileEnabled { profQuantize &+= Self.nowNs() &- t0 }

        // 2. Forward through each layer with ping-pong activation buffers.
        // Optional per-layer dump: BITHUMAN_DUMP_LAYERS=<dir> writes
        // {dir}/int8_layer_{N}.bin (float32, dequantized uint8 → fp32
        // using the layer's outputScale/outputZp) after each layer.
        // Used by the cluster-collapse comparator to pinpoint which
        // layer's drift first crosses the cluster-distinguishing
        // threshold; cleared at process exit.
        let dumpDir = ProcessInfo.processInfo.environment["BITHUMAN_DUMP_LAYERS"]

        var srcSwap = true // true = read actA, write actB
        for (li, block) in blocks.enumerated() {
            // Snapshot the input as `residualSkip` ONLY for residual
            // blocks (skip is the layer's pre-conv input).
            if block.residual {
                let tSnap = Self.profileEnabled ? Self.nowNs() : 0
                let n = block.inCh * block.inH * block.inW
                if srcSwap {
                    actA.withUnsafeBufferPointer { sp in
                        residualSkip.withUnsafeMutableBufferPointer { dp in
                            dp.baseAddress!.update(from: sp.baseAddress!, count: n)
                        }
                    }
                } else {
                    actB.withUnsafeBufferPointer { sp in
                        residualSkip.withUnsafeMutableBufferPointer { dp in
                            dp.baseAddress!.update(from: sp.baseAddress!, count: n)
                        }
                    }
                }
                if Self.profileEnabled { profResidualSnap[li] &+= Self.nowNs() &- tSnap }
            }

            if srcSwap {
                forwardBlock(block, layerIdx: li, src: &actA, dst: &actB)
            } else {
                forwardBlock(block, layerIdx: li, src: &actB, dst: &actA)
            }
            srcSwap.toggle()

            if let dir = dumpDir {
                let outU8 = srcSwap ? actA : actB
                let n = block.outCh * block.outH * block.outW
                let scale = block.outputScale
                let zp = block.outputZp
                var fp = [Float](repeating: 0, count: n)
                for i in 0..<n { fp[i] = Float(Int32(outU8[i]) - zp) * scale }
                let url = URL(fileURLWithPath: dir)
                    .appendingPathComponent(String(format: "int8_layer_%02d.bin", li))
                fp.withUnsafeBufferPointer { bp in
                    let data = Data(bytes: bp.baseAddress!,
                                    count: n * MemoryLayout<Float>.size)
                    try? data.write(to: url)
                }
            }
        }

        // 3. Dequantize the final uint8 (1, 512, 1, 1) → fp32.
        //
        // Note: this dequantize is the SOURCE of the cluster-collapse
        // bug under heavy real-audio variance — the int8 chain's
        // cumulative per-layer requantize rounding compresses the
        // 512-d embedding's KNN-distinguishing variance into a tight
        // region of feature space (visible as 9 unique clusters /
        // 350 frames vs Python's 125 on the demo audio). A
        // last-layer fp32 fallback was tried in v0.18.7 and the
        // collapse persisted — confirms the drift is multi-layer,
        // not an artifact of the final requantize. Until the
        // root-cause fix lands, the fp32 cblas bridge is the
        // shipping default; this path stays opt-in via
        // `BITHUMAN_AUDIO_ENCODER=int8`.
        let tDq = Self.profileEnabled ? Self.nowNs() : 0
        let final = srcSwap ? actA : actB
        var emb = [Float](repeating: 0, count: 512)
        let scale = finalOutputScale
        let zp = finalOutputZp
        for i in 0..<512 {
            emb[i] = Float(Int32(final[i]) - zp) * scale
        }
        if Self.profileEnabled {
            profDequantize &+= Self.nowNs() &- tDq
            profSamples &+= 1
        }
        return emb
    }

    // MARK: - Per-block forward

    private func forwardBlock(
        _ b: Int8ForwardLayer,
        layerIdx li: Int,
        src: inout [UInt8],
        dst: inout [UInt8]
    ) {
        let kCh = b.kCh
        let kChPadded = b.kChPadded
        let outPx = b.outH * b.outW
        let outSize = b.outCh * outPx

        // Acquire all buffer pointers ONCE up front. Per-iteration
        // re-acquisition was the dominant cost — Swift's
        // `withUnsafeBufferPointer` materializes the buffer's
        // storage, which inside a hot loop is dramatically slower
        // than holding a raw pointer.
        let zpFill: UInt8 = b.inputZp >= 0 && b.inputZp <= 255
            ? UInt8(b.inputZp) : 0

        // Compute-ready scratch pointers, scoped via deeply nested
        // closures so the optimizer keeps them in registers across
        // the C-kernel calls that follow.
        src.withUnsafeBufferPointer { sp in
        actInt8T.withUnsafeMutableBufferPointer { atp in
        b.weightPadded.withUnsafeBufferPointer { wp in
        int32Out.withUnsafeMutableBufferPointer { i32Out in
        b.biasCorrected.withUnsafeBufferPointer { biasP in
        b.requantMul.withUnsafeBufferPointer { mP in
        dst.withUnsafeMutableBufferPointer { dp in
            let actSrc = sp.baseAddress!
            let actT = atp.baseAddress!
            let weights = wp.baseAddress!
            let int32O = i32Out.baseAddress!
            let biasPtr = biasP.baseAddress!
            let M = mP.baseAddress!
            let outBuf = dp.baseAddress!
            _ = kCh

            let tIm2col = Self.profileEnabled ? Self.nowNs() : 0
            // 1. Fused im2col + SDOT pack via the C kernel.
            //    Two specialized fast paths:
            //      - 3×3 stride-1 padding-1 (L1, L2, L4, L5, L7, L8,
            //        L10) — vst4q-based per-oj uint32 scatter.
            //      - 3×3 stride-3 padding-1 (L3, L6, L9 downsamplers)
            //        — same scatter pattern, vqtbx1q gather for the
            //        non-stride-1 K-vectors.
            //    Everything else falls through to the general kernel.
            if b.kH == 3 && b.kW == 3
               && b.sH == 1 && b.sW == 1
               && b.pH == 1 && b.pW == 1 {
                bh_im2col_pack_int8_3x3_s1_p1(
                    actSrc, actT,
                    Int32(b.inCh), Int32(b.inH), Int32(b.inW),
                    Int32(kChPadded), zpFill
                )
            } else if b.kH == 3 && b.kW == 3
                      && b.sH == 3 && b.sW == 3
                      && b.pH == 1 && b.pW == 1 {
                bh_im2col_pack_int8_3x3_s3_p1(
                    actSrc, actT,
                    Int32(b.inCh), Int32(b.inH), Int32(b.inW),
                    Int32(b.outH), Int32(b.outW),
                    Int32(kChPadded), zpFill
                )
            } else {
                bh_im2col_pack_int8(
                    actSrc, actT,
                    Int32(b.inCh), Int32(b.inH), Int32(b.inW),
                    Int32(b.kH), Int32(b.kW),
                    Int32(b.sH), Int32(b.sW),
                    Int32(b.pH), Int32(b.pW),
                    Int32(b.outH), Int32(b.outW),
                    Int32(kChPadded), zpFill
                )
            }
            if Self.profileEnabled { profIm2colPack[li] &+= Self.nowNs() &- tIm2col }

            // 2. int8 GEMM via the C target. Two flavors × two
            //    micro-architectures:
            //    - SMMLA (i8mm, M2+) when hasI8mm — 2× SDOT muls/inst.
            //    - SDOT (M1+) otherwise.
            //    - residual layers materialize int32 so the residual
            //      bridge can read it back to mix in the skip;
            //    - non-residual layers use the fused-requant kernel
            //      that produces uint8 directly (skips the int32
            //      round-trip).
            let tGemm = Self.profileEnabled ? Self.nowNs() : 0
            if hasI8mm {
                if b.residual {
                    bh_int8_gemm_smmla(
                        weights, actT, biasPtr, int32O,
                        Int32(b.outCh), Int32(kChPadded), Int32(outPx)
                    )
                } else {
                    bh_int8_gemm_smmla_requant(
                        weights, actT, biasPtr, M, b.outputZp,
                        outBuf,
                        Int32(b.outCh), Int32(kChPadded), Int32(outPx)
                    )
                }
            } else {
                if b.residual {
                    bh_int8_gemm_sdot(
                        weights, actT, biasPtr, int32O,
                        Int32(b.outCh), Int32(kChPadded), Int32(outPx)
                    )
                } else {
                    bh_int8_gemm_sdot_requant(
                        weights, actT, biasPtr, M, b.outputZp,
                        outBuf,
                        Int32(b.outCh), Int32(kChPadded), Int32(outPx)
                    )
                }
            }
            if Self.profileEnabled { profGemm[li] &+= Self.nowNs() &- tGemm }

            let tReq = Self.profileEnabled ? Self.nowNs() : 0
            if b.residual {
                // Residual fused bridge: replaces three fp32 passes
                // (dequant conv, dequant skip, add, requantize) with
                // one fused vectorized pass over the output tensor.
                // The per-channel `M_conv` is requantMul × outputScale
                // (we feed `M[oc] * outputScale` since requantMul is
                // already (input_scale × weight_scale[oc]) /
                // output_scale, and the fused kernel wants
                // (input_scale × weight_scale[oc]) / output_scale —
                // wait, both sides want the SAME multiplier — so we
                // can pass `M` directly. Verified below.)
                //
                // Algebra check:
                //   requant non-residual: q = round(int32 × M[oc]) + zp_out
                //     where M[oc] = (in_s × w_s[oc]) / out_s
                //   residual fused:       q = round(int32 × M_conv[oc]
                //                              + (skip - skip_zp) × M_skip)
                //                              + zp_out
                //     where M_conv = (in_s × w_s[oc]) / out_s — same M.
                //     M_skip = skip_in_s / out_s.
                let mSkip = b.inputScale / b.outputScale
                residualSkip.withUnsafeBufferPointer { sk in
                    bh_int8_residual_combine(
                        int32O, sk.baseAddress!,
                        M, mSkip, b.inputZp, b.outputZp,
                        outBuf,
                        Int32(b.outCh), Int32(outPx)
                    )
                }
                _ = outSize
                if Self.profileEnabled { profRequant[li] &+= Self.nowNs() &- tReq }
                return
            }
            if Self.profileEnabled { profRequant[li] &+= Self.nowNs() &- tReq }

            // Non-residual: handled by the fused gemm-requant kernel
            // above (writes outBuf directly).
        }
        }
        }
        }
        }
        }
        }
    }
}

// MARK: - Hot-path inner kernels (free functions so the optimizer
// can fully inline + autovectorize without wrestling with @inline
// attribute annotations)

