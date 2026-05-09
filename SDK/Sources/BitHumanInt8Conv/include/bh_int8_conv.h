// SPDX-License-Identifier: Apache-2.0
//
// bh_int8_conv.h — int8 GEMM + per-channel requantize for the
// Essence audio encoder, hand-NEON on Apple Silicon.
//
// Function ABIs are stable; consume from Swift via the
// `BitHumanInt8Conv` SwiftPM module.

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Runtime check for the ARM v8.6 i8mm extension (FEAT_I8MM) — the
// gate for `vmmlaq_s32` / `vusmmlaq_s32`. On Apple Silicon: M2 / A15
// and later. Returns 1 iff `hw.optional.arm.FEAT_I8MM == 1`,
// 0 otherwise (older Apple Silicon, simulators, x86 hosts).
//
// Cheap: ~1 µs sysctl, called once at runtime init.
int bh_has_i8mm(void);

// Per-channel int32 → uint8 requantize. Folds the implicit ReLU
// into the [0, 255] clamp (output_zp = 0 in the QDQ encoder we
// ship; if zp is non-zero the clamp range stays the same uint8
// range and the zp shifts the output).
//
//   out[oc, j] = clamp(roundf(in[oc, j] * M[oc]) + output_zp, 0, 255)
//
// Vectorized over the outPx dimension (16-element NEON blocks of
// int32 → fp32 multiply → round → clamp → uint8 narrow). The
// per-channel scalar `M[oc]` is broadcast across each row.
void bh_requant_int32_to_uint8(
    const int32_t* in_int32,
    const float* M_per_channel,
    uint8_t* out_uint8,
    int outCh,
    int outPx,
    int32_t output_zp
);

// fp32 → uint8 quantize for the residual-add bridge. After we add
// the dequantized skip in fp32, this writes the result back to a
// uint8 buffer using the layer's output scale + zero-point.
//
//   out[i] = clamp(roundf(in[i] / output_scale) + output_zp, 0, 255)
//
// SIMD over the full buffer; same hot-path treatment as the
// requantize above.
void bh_quantize_float_to_uint8(
    const float* in_fp32,
    uint8_t* out_uint8,
    int n,
    float output_scale,
    int32_t output_zp
);

// fp32 conv-output build for residual blocks: dequantize int32
// conv output to fp32 using a per-channel multiplier
//   M[oc] = input_scale * weight_scale[oc]
// (NOT the requant multiplier — this skips the output-scale
// division so we can add the skip cleanly in the same fp32 space).
//
//   out[oc, j] = float(in_int32[oc, j]) * M[oc]
void bh_dequant_int32_to_float(
    const int32_t* in_int32,
    const float* M_per_channel,
    float* out_fp32,
    int outCh,
    int outPx
);

// uint8 → fp32 dequantize for the residual-add bridge.
//
//   out[i] = float(int32(in[i]) - input_zp) * input_scale
void bh_dequantize_uint8_to_float(
    const uint8_t* in_uint8,
    float* out_fp32,
    int n,
    float input_scale,
    int32_t input_zp
);

// Specialized im2col + pack for 3×3 stride-3 padding-1 layers (L3,
// L6, L9 — the encoder's three downsampling stages). The general
// kernel falls back to a scalar inner loop when sW != 1, costing
// ~52 µs combined across these layers in v0.16.0.
//
// Strategy: for each (oi, ic), load three source rows (si = 3·oi −
// 1, 3·oi, 3·oi + 1) and use `vqtbx1q_u8` byte-permute with a
// precomputed index table to gather the 9 K-vectors in registers.
// Then `vst4q_u8` interleave + scattered uint32 stores (same
// pattern as the stride-1 specialization) to write outW × 4 bytes
// per K-block.
//
// Same correctness contract as the general kernel: pad bytes use
// `pad_fill` (the layer's input zp byte), output is XOR-shifted
// int8, K is zero-padded to `kCh_padded`. Caller must guarantee the
// source buffer has ≥ 16 bytes of trailing slack.
void bh_im2col_pack_int8_3x3_s3_p1(
    const uint8_t* src,        // (inCh, inH, inW)
    int8_t*       dst,         // (outPx, kCh_padded)
    int inCh, int inH, int inW,
    int outH, int outW,        // == ceil((inH + 2 - 3)/3 + 1), same for W
    int kCh_padded,            // >= inCh * 9, multiple of 8
    uint8_t pad_fill
);

// Specialized im2col + pack for 3×3 stride-1 padding-1 layers (L1,
// L2, L4, L5 in the Essence encoder — together ~370 µs of the
// pre-v0.16 encoder time). Same semantics as `bh_im2col_pack_int8`
// but exploits the layer's structure for a ~2× speedup on the
// store-bound inner loop:
//
//   1. Loads three source rows (si = oi±1) per (oi, ic) once.
//   2. Computes the nine shifted views (ki × kj) entirely in-
//      register.
//   3. Uses `vst4q_u8` to interleave four K-columns at a time into a
//      64-byte temp buffer, then issues 16 strided 32-bit stores to
//      the destination — collapsing 4 single-byte writes into one
//      4-byte write per oj.
//
// Caller must guarantee the source buffer is padded by ≥ 16 bytes
// past the last row (so 16-byte loads on the trailing row don't fault
// — matters for layers with inW < 16). The Int8Forward scratch
// allocation already does this.
//
// Falls back to `bh_im2col_pack_int8` for any layer that doesn't
// match the 3×3-s1-p1 shape.
void bh_im2col_pack_int8_3x3_s1_p1(
    const uint8_t* src,        // (inCh, inH, inW) row-major uint8
    int8_t*       dst,         // (outPx, kCh_padded) row-major int8
    int inCh, int inH, int inW,
    int kCh_padded,            // == round_up_8(inCh * 9)
    uint8_t pad_fill
);

// Fused im2col + SDOT pack: writes (outPx, kCh_padded) int8 directly
// from the (inCh, inH, inW) uint8 input, applying the XOR-0x80 shift
// and K zero-pad along the way. Replaces the scalar Swift
// `im2colInt8Packed` — same semantics, NEON-accelerated.
//
// Hot path: for every output spatial position (oi, oj), every input
// channel ic, every kernel position (ki, kj), gather one byte from
// the input, XOR the sign bit, and write it to its K-column in the
// (outPx, kCh_padded) destination row. Total bytes moved per layer
// ≈ outPx × kCh — dominant cost on the 3×3-stride-1 layers (L1, L2,
// L4, L5) where the unrolled Swift version was 60% of encoder time.
//
// The NEON version batches the inner oj loop into 16-wide source
// loads when sW = 1 and the strided destination stores fit a single
// cache-line burst, with a scalar fallback for non-stride-1 / edge
// rows.
//
// Pad fill: the input zero-point byte (so the post-XOR pad fits the
// same algebra as in-bounds bytes — caller already passes the byte
// equal to the int8 layer's input zp).
void bh_im2col_pack_int8(
    const uint8_t* src,        // (inCh, inH, inW) row-major uint8
    int8_t*       dst,         // (outPx, kCh_padded) row-major int8
    int inCh, int inH, int inW,
    int kH, int kW,
    int sH, int sW,
    int pH, int pW,
    int outH, int outW,
    int kCh_padded,
    uint8_t pad_fill
);

// Fused residual-bridge combine: replaces three separate passes
// (dequant int32 → fp32, dequant uint8 → fp32, requant fp32 → uint8)
// with a single fp32 pass. For a residual block, this computes
//
//   out[oc, j] = clamp(
//       roundf(in_int32[oc, j] * M_conv[oc]
//              + (in_skip[oc, j] - skip_zp) * M_skip)
//       + output_zp,
//       0, 255)
//
// where:
//   M_conv[oc] = (input_scale × weight_scale[oc]) / output_scale
//                (same as the per-channel requant multiplier passed
//                to `bh_requant_int32_to_uint8` for non-residual
//                layers)
//   M_skip     = skip_input_scale / output_scale  (scalar)
//
// Vectorized over j; the per-channel scalar M_conv[oc] is broadcast
// across each row.
void bh_int8_residual_combine(
    const int32_t* in_int32,         // (outCh, outPx) conv output
    const uint8_t* in_skip,          // (outCh, outPx) residual skip
    const float* M_conv_per_channel, // (outCh,) — inputScale*weightScale[oc]/outputScale
    float M_skip,                    // skip_input_scale / output_scale
    int32_t skip_zp,                 // input zp of the skip tensor
    int32_t output_zp,
    uint8_t* out_uint8,              // (outCh, outPx)
    int outCh,
    int outPx
);

// SDOT GEMM fused with the per-channel requantize, producing
// uint8 output directly — skips writing the int32 conv output to
// memory, then reading it back for the requant pass. Use this for
// non-residual layers; residual layers still need the int32 path so
// the fused-residual-combine kernel can mix in the skip.
//
// Caller responsibilities (same as `bh_int8_gemm_sdot`) plus:
//   - `M_per_channel[oc]` = (input_scale × weight_scale[oc]) /
//                          output_scale (== `M` from
//                          `bh_requant_int32_to_uint8`)
//
// Inner loop computes per-row int32 accumulators in registers, then
// applies fp32 multiply + zp + clamp + narrow before storing uint8.
void bh_int8_gemm_sdot_requant(
    const int8_t* weights,
    const int8_t* activations_t,
    const int32_t* biases_corrected,
    const float* M_per_channel,
    int32_t output_zp,
    uint8_t* out_uint8,
    int outCh,
    int kCh_padded,
    int outPx
);

// SDOT-based int8 GEMM. Operates on shifted int8 activations
// (uint8 ^ 0x80 = uint8 − 128) and absorbs the input zero-point
// into a pre-computed bias correction at the caller, so the inner
// loop is a pure SDOT tile.
//
// Caller responsibilities:
//   - weights packed (outCh, kCh_padded) row-major, K-padded with 0
//     so the dot product zero-extends. Same dtype int8.
//   - activations produced by `bh_im2col_pack_int8` — (outPx,
//     kCh_padded) int8, K-padded with 0.
//   - biases_corrected[oc] = bias[oc] + (128 - input_zp)
//                          * sum_k(weights[oc][k])  (sum over the
//                          UNPADDED K range).
//
//   out[oc][j] = biases_corrected[oc]
//                + sum_k act_s8_t[j][k] * weights[oc][k]
//
// Algebraic equivalence to the original (act_u8 − input_zp) · w:
//   sum_k (act_u8[k][j] - input_zp) * w[oc][k]
//   = sum_k (act_s8_t[j][k] + 128 - input_zp) * w[oc][k]
//   = (sum_k act_s8_t[j][k] * w[oc][k])
//     + (128 - input_zp) * sum_k(w[oc][k])
//
// Hot path: 4-oc × 16-j × 4-k tile, 16 vdotq_s32 per inner iteration
// (256 byte multiplies) with 4 weight loads shared across 4 j-blocks.
void bh_int8_gemm_sdot(
    const int8_t* weights,             // (outCh, kCh_padded)
    const int8_t* activations_t,       // (outPx, kCh_padded)
    const int32_t* biases_corrected,   // (outCh,)
    int32_t* out,                      // (outCh, outPx)
    int outCh,
    int kCh_padded,                    // multiple of 4
    int outPx
);

// SMMLA-based int8 GEMM. Same caller contract as `bh_int8_gemm_sdot`
// (shifted int8 activations, K-padded weights, zp-corrected biases),
// but the inner kernel uses `vmmlaq_s32` (ARM v8.6 i8mm) which
// computes a 2×2 int32 outer product over an 8-byte K segment per
// instruction (32 byte multiplies — 2× SDOT throughput).
//
// **kCh_padded must be a multiple of 8**, not 4 (caller handles).
//
// Only call this if `bh_has_i8mm()` returned 1; on M1 / A14 the
// SMMLA instruction is undefined.
void bh_int8_gemm_smmla(
    const int8_t* weights,
    const int8_t* activations_t,
    const int32_t* biases_corrected,
    int32_t* out,
    int outCh,
    int kCh_padded,                    // multiple of 8
    int outPx
);

// SMMLA GEMM fused with the per-channel requantize (uint8 output).
// Non-residual analogue of `bh_int8_gemm_sdot_requant`.
void bh_int8_gemm_smmla_requant(
    const int8_t* weights,
    const int8_t* activations_t,
    const int32_t* biases_corrected,
    const float* M_per_channel,
    int32_t output_zp,
    uint8_t* out_uint8,
    int outCh,
    int kCh_padded,                    // multiple of 8
    int outPx
);

#ifdef __cplusplus
}
#endif
