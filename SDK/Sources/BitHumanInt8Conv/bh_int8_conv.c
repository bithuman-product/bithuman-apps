// SPDX-License-Identifier: Apache-2.0
//
// bh_int8_conv.c — hand-NEON int8 GEMM + per-channel requantize.
// Targets Apple Silicon (arm64 NEON). The kernels assume `__ARM_NEON`
// is set; on non-arm64 they fall back to scalar loops so the SwiftPM
// build still works on Linux/x86 hosts (CI).

#include "bh_int8_conv.h"

#include <math.h>
#include <stdint.h>
#include <stddef.h>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#if defined(__APPLE__)
#include <sys/sysctl.h>
#endif

// MARK: - Runtime CPU feature detection

int bh_has_i8mm(void) {
#if defined(__APPLE__) && defined(__aarch64__)
    int value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname("hw.optional.arm.FEAT_I8MM", &value, &size, NULL, 0) == 0) {
        return value;
    }
#endif
    return 0;
}


// MARK: - int32 → uint8 requantize (per-channel multiplier)

void bh_requant_int32_to_uint8(
    const int32_t* in_int32,
    const float* M_per_channel,
    uint8_t* out_uint8,
    int outCh,
    int outPx,
    int32_t output_zp
) {
#if defined(__ARM_NEON)
    const float32x4_t zp_v = vdupq_n_f32((float)output_zp);
    const float32x4_t lo_v = vdupq_n_f32(0.0f);
    const float32x4_t hi_v = vdupq_n_f32(255.0f);
#endif

    for (int oc = 0; oc < outCh; ++oc) {
        const int32_t* in_row  = in_int32 + (size_t)oc * outPx;
        uint8_t*       out_row = out_uint8 + (size_t)oc * outPx;
        const float    M       = M_per_channel[oc];

#if defined(__ARM_NEON)
        const float32x4_t M_v = vdupq_n_f32(M);
        int j = 0;
        for (; j + 16 <= outPx; j += 16) {
            // Load 16 int32, widen to four float32x4 lanes.
            int32x4_t x0 = vld1q_s32(in_row + j +  0);
            int32x4_t x1 = vld1q_s32(in_row + j +  4);
            int32x4_t x2 = vld1q_s32(in_row + j +  8);
            int32x4_t x3 = vld1q_s32(in_row + j + 12);

            float32x4_t f0 = vcvtq_f32_s32(x0);
            float32x4_t f1 = vcvtq_f32_s32(x1);
            float32x4_t f2 = vcvtq_f32_s32(x2);
            float32x4_t f3 = vcvtq_f32_s32(x3);

            // f * M + zp.
            f0 = vfmaq_f32(zp_v, f0, M_v);
            f1 = vfmaq_f32(zp_v, f1, M_v);
            f2 = vfmaq_f32(zp_v, f2, M_v);
            f3 = vfmaq_f32(zp_v, f3, M_v);

            // Round to nearest.
            f0 = vrndnq_f32(f0);
            f1 = vrndnq_f32(f1);
            f2 = vrndnq_f32(f2);
            f3 = vrndnq_f32(f3);

            // Clamp [0, 255].
            f0 = vminq_f32(vmaxq_f32(f0, lo_v), hi_v);
            f1 = vminq_f32(vmaxq_f32(f1, lo_v), hi_v);
            f2 = vminq_f32(vmaxq_f32(f2, lo_v), hi_v);
            f3 = vminq_f32(vmaxq_f32(f3, lo_v), hi_v);

            // Convert float → uint32 → narrow → uint8.
            uint32x4_t u0 = vcvtq_u32_f32(f0);
            uint32x4_t u1 = vcvtq_u32_f32(f1);
            uint32x4_t u2 = vcvtq_u32_f32(f2);
            uint32x4_t u3 = vcvtq_u32_f32(f3);

            // Pack: 4 uint32 → 4 uint16, two halves → 8 uint16, then 8+8 → 16 uint8.
            uint16x4_t h0 = vqmovn_u32(u0);
            uint16x4_t h1 = vqmovn_u32(u1);
            uint16x4_t h2 = vqmovn_u32(u2);
            uint16x4_t h3 = vqmovn_u32(u3);

            uint16x8_t h01 = vcombine_u16(h0, h1);
            uint16x8_t h23 = vcombine_u16(h2, h3);

            uint8x8_t  b01 = vqmovn_u16(h01);
            uint8x8_t  b23 = vqmovn_u16(h23);

            uint8x16_t out16 = vcombine_u8(b01, b23);
            vst1q_u8(out_row + j, out16);
        }
        for (; j < outPx; ++j) {
            float q = roundf((float)in_row[j] * M) + (float)output_zp;
            if (q < 0.0f) q = 0.0f;
            if (q > 255.0f) q = 255.0f;
            out_row[j] = (uint8_t)q;
        }
#else
        for (int j = 0; j < outPx; ++j) {
            float q = roundf((float)in_row[j] * M) + (float)output_zp;
            if (q < 0.0f) q = 0.0f;
            if (q > 255.0f) q = 255.0f;
            out_row[j] = (uint8_t)q;
        }
#endif
    }
}

// MARK: - fp32 → uint8 quantize (single tensor)

void bh_quantize_float_to_uint8(
    const float* in_fp32,
    uint8_t* out_uint8,
    int n,
    float output_scale,
    int32_t output_zp
) {
    const float inv_scale = 1.0f / output_scale;
    int i = 0;

#if defined(__ARM_NEON)
    const float32x4_t inv_v = vdupq_n_f32(inv_scale);
    const float32x4_t zp_v  = vdupq_n_f32((float)output_zp);
    const float32x4_t lo_v  = vdupq_n_f32(0.0f);
    const float32x4_t hi_v  = vdupq_n_f32(255.0f);

    for (; i + 16 <= n; i += 16) {
        float32x4_t f0 = vld1q_f32(in_fp32 + i +  0);
        float32x4_t f1 = vld1q_f32(in_fp32 + i +  4);
        float32x4_t f2 = vld1q_f32(in_fp32 + i +  8);
        float32x4_t f3 = vld1q_f32(in_fp32 + i + 12);

        f0 = vfmaq_f32(zp_v, f0, inv_v);
        f1 = vfmaq_f32(zp_v, f1, inv_v);
        f2 = vfmaq_f32(zp_v, f2, inv_v);
        f3 = vfmaq_f32(zp_v, f3, inv_v);

        f0 = vrndnq_f32(f0);
        f1 = vrndnq_f32(f1);
        f2 = vrndnq_f32(f2);
        f3 = vrndnq_f32(f3);

        f0 = vminq_f32(vmaxq_f32(f0, lo_v), hi_v);
        f1 = vminq_f32(vmaxq_f32(f1, lo_v), hi_v);
        f2 = vminq_f32(vmaxq_f32(f2, lo_v), hi_v);
        f3 = vminq_f32(vmaxq_f32(f3, lo_v), hi_v);

        uint32x4_t u0 = vcvtq_u32_f32(f0);
        uint32x4_t u1 = vcvtq_u32_f32(f1);
        uint32x4_t u2 = vcvtq_u32_f32(f2);
        uint32x4_t u3 = vcvtq_u32_f32(f3);

        uint16x4_t h0 = vqmovn_u32(u0);
        uint16x4_t h1 = vqmovn_u32(u1);
        uint16x4_t h2 = vqmovn_u32(u2);
        uint16x4_t h3 = vqmovn_u32(u3);

        uint8x8_t b01 = vqmovn_u16(vcombine_u16(h0, h1));
        uint8x8_t b23 = vqmovn_u16(vcombine_u16(h2, h3));

        vst1q_u8(out_uint8 + i, vcombine_u8(b01, b23));
    }
#endif
    for (; i < n; ++i) {
        float q = roundf(in_fp32[i] * inv_scale) + (float)output_zp;
        if (q < 0.0f) q = 0.0f;
        if (q > 255.0f) q = 255.0f;
        out_uint8[i] = (uint8_t)q;
    }
}

// MARK: - int32 → fp32 dequantize (per-channel scale)

void bh_dequant_int32_to_float(
    const int32_t* in_int32,
    const float* M_per_channel,
    float* out_fp32,
    int outCh,
    int outPx
) {
    for (int oc = 0; oc < outCh; ++oc) {
        const int32_t* in_row  = in_int32 + (size_t)oc * outPx;
        float*         out_row = out_fp32 + (size_t)oc * outPx;
        const float M = M_per_channel[oc];
        int j = 0;
#if defined(__ARM_NEON)
        const float32x4_t M_v = vdupq_n_f32(M);
        for (; j + 16 <= outPx; j += 16) {
            int32x4_t x0 = vld1q_s32(in_row + j +  0);
            int32x4_t x1 = vld1q_s32(in_row + j +  4);
            int32x4_t x2 = vld1q_s32(in_row + j +  8);
            int32x4_t x3 = vld1q_s32(in_row + j + 12);
            vst1q_f32(out_row + j +  0, vmulq_f32(vcvtq_f32_s32(x0), M_v));
            vst1q_f32(out_row + j +  4, vmulq_f32(vcvtq_f32_s32(x1), M_v));
            vst1q_f32(out_row + j +  8, vmulq_f32(vcvtq_f32_s32(x2), M_v));
            vst1q_f32(out_row + j + 12, vmulq_f32(vcvtq_f32_s32(x3), M_v));
        }
#endif
        for (; j < outPx; ++j) {
            out_row[j] = (float)in_row[j] * M;
        }
    }
}

// MARK: - uint8 → fp32 dequantize

void bh_dequantize_uint8_to_float(
    const uint8_t* in_uint8,
    float* out_fp32,
    int n,
    float input_scale,
    int32_t input_zp
) {
    int i = 0;
#if defined(__ARM_NEON)
    const float32x4_t scale_v = vdupq_n_f32(input_scale);
    const int16x8_t  zp_v    = vdupq_n_s16((int16_t)input_zp);
    for (; i + 16 <= n; i += 16) {
        uint8x16_t a_u8 = vld1q_u8(in_uint8 + i);
        int16x8_t a_lo = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(a_u8)));
        int16x8_t a_hi = vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(a_u8)));
        a_lo = vsubq_s16(a_lo, zp_v);
        a_hi = vsubq_s16(a_hi, zp_v);
        int32x4_t i0 = vmovl_s16(vget_low_s16 (a_lo));
        int32x4_t i1 = vmovl_s16(vget_high_s16(a_lo));
        int32x4_t i2 = vmovl_s16(vget_low_s16 (a_hi));
        int32x4_t i3 = vmovl_s16(vget_high_s16(a_hi));
        vst1q_f32(out_fp32 + i +  0, vmulq_f32(vcvtq_f32_s32(i0), scale_v));
        vst1q_f32(out_fp32 + i +  4, vmulq_f32(vcvtq_f32_s32(i1), scale_v));
        vst1q_f32(out_fp32 + i +  8, vmulq_f32(vcvtq_f32_s32(i2), scale_v));
        vst1q_f32(out_fp32 + i + 12, vmulq_f32(vcvtq_f32_s32(i3), scale_v));
    }
#endif
    for (; i < n; ++i) {
        out_fp32[i] = (float)((int32_t)in_uint8[i] - input_zp) * input_scale;
    }
}

// MARK: - Fused residual-bridge combine (1-pass dequant+add+requant)

void bh_int8_residual_combine(
    const int32_t* in_int32,
    const uint8_t* in_skip,
    const float* M_conv_per_channel,
    float M_skip,
    int32_t skip_zp,
    int32_t output_zp,
    uint8_t* out_uint8,
    int outCh,
    int outPx
) {
#if defined(__ARM_NEON)
    const float32x4_t skip_zp_v = vdupq_n_f32((float)skip_zp);
    const float32x4_t M_skip_v  = vdupq_n_f32(M_skip);
    const float32x4_t out_zp_v  = vdupq_n_f32((float)output_zp);
    const float32x4_t lo_v      = vdupq_n_f32(0.0f);
    const float32x4_t hi_v      = vdupq_n_f32(255.0f);
#endif
    for (int oc = 0; oc < outCh; ++oc) {
        const int32_t* conv_row = in_int32 + (size_t)oc * outPx;
        const uint8_t* skip_row = in_skip  + (size_t)oc * outPx;
        uint8_t*       out_row  = out_uint8 + (size_t)oc * outPx;
        const float    M_conv   = M_conv_per_channel[oc];
        int j = 0;
#if defined(__ARM_NEON)
        const float32x4_t M_conv_v = vdupq_n_f32(M_conv);
        for (; j + 16 <= outPx; j += 16) {
            // Conv int32 → fp32 × M_conv.
            int32x4_t c0 = vld1q_s32(conv_row + j +  0);
            int32x4_t c1 = vld1q_s32(conv_row + j +  4);
            int32x4_t c2 = vld1q_s32(conv_row + j +  8);
            int32x4_t c3 = vld1q_s32(conv_row + j + 12);
            float32x4_t f0 = vmulq_f32(vcvtq_f32_s32(c0), M_conv_v);
            float32x4_t f1 = vmulq_f32(vcvtq_f32_s32(c1), M_conv_v);
            float32x4_t f2 = vmulq_f32(vcvtq_f32_s32(c2), M_conv_v);
            float32x4_t f3 = vmulq_f32(vcvtq_f32_s32(c3), M_conv_v);

            // Skip uint8 → fp32 × M_skip + already-included zp shift.
            uint8x16_t  s_u8 = vld1q_u8(skip_row + j);
            uint16x8_t  s_lo = vmovl_u8(vget_low_u8(s_u8));
            uint16x8_t  s_hi = vmovl_u8(vget_high_u8(s_u8));
            float32x4_t s0 = vcvtq_f32_u32(vmovl_u16(vget_low_u16 (s_lo)));
            float32x4_t s1 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(s_lo)));
            float32x4_t s2 = vcvtq_f32_u32(vmovl_u16(vget_low_u16 (s_hi)));
            float32x4_t s3 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(s_hi)));
            s0 = vsubq_f32(s0, skip_zp_v);
            s1 = vsubq_f32(s1, skip_zp_v);
            s2 = vsubq_f32(s2, skip_zp_v);
            s3 = vsubq_f32(s3, skip_zp_v);

            // Sum: f += s × M_skip; then add output_zp; round; clamp.
            f0 = vfmaq_f32(f0, s0, M_skip_v);
            f1 = vfmaq_f32(f1, s1, M_skip_v);
            f2 = vfmaq_f32(f2, s2, M_skip_v);
            f3 = vfmaq_f32(f3, s3, M_skip_v);

            f0 = vaddq_f32(f0, out_zp_v);
            f1 = vaddq_f32(f1, out_zp_v);
            f2 = vaddq_f32(f2, out_zp_v);
            f3 = vaddq_f32(f3, out_zp_v);

            f0 = vrndnq_f32(f0);
            f1 = vrndnq_f32(f1);
            f2 = vrndnq_f32(f2);
            f3 = vrndnq_f32(f3);

            f0 = vminq_f32(vmaxq_f32(f0, lo_v), hi_v);
            f1 = vminq_f32(vmaxq_f32(f1, lo_v), hi_v);
            f2 = vminq_f32(vmaxq_f32(f2, lo_v), hi_v);
            f3 = vminq_f32(vmaxq_f32(f3, lo_v), hi_v);

            uint32x4_t u0 = vcvtq_u32_f32(f0);
            uint32x4_t u1 = vcvtq_u32_f32(f1);
            uint32x4_t u2 = vcvtq_u32_f32(f2);
            uint32x4_t u3 = vcvtq_u32_f32(f3);

            uint16x4_t h0 = vqmovn_u32(u0);
            uint16x4_t h1 = vqmovn_u32(u1);
            uint16x4_t h2 = vqmovn_u32(u2);
            uint16x4_t h3 = vqmovn_u32(u3);

            uint8x8_t b01 = vqmovn_u16(vcombine_u16(h0, h1));
            uint8x8_t b23 = vqmovn_u16(vcombine_u16(h2, h3));
            vst1q_u8(out_row + j, vcombine_u8(b01, b23));
        }
#endif
        for (; j < outPx; ++j) {
            float c = (float)conv_row[j] * M_conv;
            float s = ((float)(int32_t)skip_row[j] - (float)skip_zp) * M_skip;
            float q = roundf(c + s) + (float)output_zp;
            if (q < 0.0f) q = 0.0f;
            if (q > 255.0f) q = 255.0f;
            out_row[j] = (uint8_t)q;
        }
    }
}

// Forward declaration — `bh_load_row_or_pad` is defined just below
// the stride-1 specialization but used by both. (Same one-liner;
// moving it above is awkward because of the `__ARM_NEON` gating.)
#if defined(__ARM_NEON)
static inline uint8x16_t bh_load_row_or_pad(
    const uint8_t* src, int si, int inH, int inW, uint8_t pad_fill
);
#endif

// MARK: - Specialized im2col-pack for 3×3 stride-3 padding-1 layers
//
// Encoder downsampling stages L3, L6, L9. The general kernel falls
// back to a scalar inner loop when sW != 1 (the stride-1 fast path
// doesn't apply), costing ~52 µs combined.
//
// Strategy: same vst4q_u8-based per-oj uint32 scatter as the
// stride-1 kernel, but the kj=0/1/2 K-vectors are built via
// `vqtbx1q_u8` byte-permute (rather than vextq_s8 shifts) since
// stride 3 means adjacent oj's read source positions 3 lanes
// apart, not 1. Per (oi, ic): 3 row loads + 9 vqtbx1q + 2 vst4q +
// outW × 2 uint32 stores + outW byte stores.

void bh_im2col_pack_int8_3x3_s3_p1(
    const uint8_t* src,
    int8_t* dst,
    int inCh, int inH, int inW,
    int outH, int outW,
    int kCh_padded,
    uint8_t pad_fill
) {
#if defined(__ARM_NEON)
    const int kCh = inCh * 9;
    const uint8_t pad_xor = pad_fill ^ (uint8_t)0x80;
    const uint8x16_t v_pad = vdupq_n_u8(pad_xor);

    // Zero K-padding tail (same pattern as stride-1 specialization).
    if (kCh_padded > kCh) {
        for (int j = 0; j < outH * outW; ++j) {
            for (int kk = kCh; kk < kCh_padded; ++kk) {
                dst[(size_t)j * kCh_padded + kk] = 0;
            }
        }
    }

    // Build per-kj index tables once for this layer. For oj=0..outW-1
    // and kj=0/1/2, sj = 3·oj − 1 + kj. Mark sj < 0 or sj >= inW with
    // 0xFF; vqtbx1q_u8 leaves the destination untouched for indices
    // ≥ 16, so OOB lanes pick up pad_xor (the destination's initial
    // value).
    uint8_t idx_kj0[16], idx_kj1[16], idx_kj2[16];
    for (int i = 0; i < 16; ++i) { idx_kj0[i] = idx_kj1[i] = idx_kj2[i] = 0xFF; }
    for (int oj = 0; oj < outW && oj < 16; ++oj) {
        const int sj0 = 3 * oj - 1 + 0;
        const int sj1 = 3 * oj - 1 + 1;
        const int sj2 = 3 * oj - 1 + 2;
        if (sj0 >= 0 && sj0 < inW) idx_kj0[oj] = (uint8_t)sj0;
        if (sj1 >= 0 && sj1 < inW) idx_kj1[oj] = (uint8_t)sj1;
        if (sj2 >= 0 && sj2 < inW) idx_kj2[oj] = (uint8_t)sj2;
    }
    const uint8x16_t v_idx_kj0 = vld1q_u8(idx_kj0);
    const uint8x16_t v_idx_kj1 = vld1q_u8(idx_kj1);
    const uint8x16_t v_idx_kj2 = vld1q_u8(idx_kj2);

    uint8_t temp[128] __attribute__((aligned(16)));

    for (int oi = 0; oi < outH; ++oi) {
        const int si0 = 3 * oi - 1 + 0;
        const int si1 = 3 * oi - 1 + 1;
        const int si2 = 3 * oi - 1 + 2;

        for (int ic = 0; ic < inCh; ++ic) {
            const uint8_t* ch = src + (size_t)ic * inH * inW;

            // Load 3 source rows. bh_load_row_or_pad masks lanes
            // >= inW to pad_fill so the table-lookup garbage is
            // pre-handled, then we XOR to int8 representation.
            uint8x16_t r0u = bh_load_row_or_pad(ch, si0, inH, inW, pad_fill);
            uint8x16_t r1u = bh_load_row_or_pad(ch, si1, inH, inW, pad_fill);
            uint8x16_t r2u = bh_load_row_or_pad(ch, si2, inH, inW, pad_fill);
            uint8x16_t r0 = veorq_u8(r0u, vdupq_n_u8(0x80));
            uint8x16_t r1 = veorq_u8(r1u, vdupq_n_u8(0x80));
            uint8x16_t r2 = veorq_u8(r2u, vdupq_n_u8(0x80));

            // 9 K-vectors. vqtbx1q_u8 keeps `v_pad` for indices ≥ 16,
            // so the tail lanes naturally land at pad_xor.
            uint8x16_t k0_0 = vqtbx1q_u8(v_pad, r0, v_idx_kj0);
            uint8x16_t k0_1 = vqtbx1q_u8(v_pad, r0, v_idx_kj1);
            uint8x16_t k0_2 = vqtbx1q_u8(v_pad, r0, v_idx_kj2);
            uint8x16_t k1_0 = vqtbx1q_u8(v_pad, r1, v_idx_kj0);
            uint8x16_t k1_1 = vqtbx1q_u8(v_pad, r1, v_idx_kj1);
            uint8x16_t k1_2 = vqtbx1q_u8(v_pad, r1, v_idx_kj2);
            uint8x16_t k2_0 = vqtbx1q_u8(v_pad, r2, v_idx_kj0);
            uint8x16_t k2_1 = vqtbx1q_u8(v_pad, r2, v_idx_kj1);
            uint8x16_t k2_2 = vqtbx1q_u8(v_pad, r2, v_idx_kj2);

            // Same vst4q-based interleave + per-oj uint32 scatter as
            // the stride-1 specialization.
            uint8x16x4_t bundle03 = {{ k0_0, k0_1, k0_2, k1_0 }};
            vst4q_u8(temp + 0, bundle03);
            uint8x16x4_t bundle47 = {{ k1_1, k1_2, k2_0, k2_1 }};
            vst4q_u8(temp + 64, bundle47);
            uint8_t k8_lanes[16] __attribute__((aligned(16)));
            vst1q_u8(k8_lanes, k2_2);

            int8_t* dst_base = dst + (size_t)(oi * outW) * kCh_padded + ic * 9;
            for (int oj = 0; oj < outW; ++oj) {
                int8_t* dst_oj = dst_base + (size_t)oj * kCh_padded;
                __builtin_memcpy(dst_oj + 0, temp + (size_t)oj * 4, 4);
                __builtin_memcpy(dst_oj + 4, temp + 64 + (size_t)oj * 4, 4);
                dst_oj[8] = (int8_t)k8_lanes[oj];
            }
        }
    }
#else
    bh_im2col_pack_int8(src, dst, inCh, inH, inW, 3, 3, 3, 3, 1, 1,
                        outH, outW, kCh_padded, pad_fill);
#endif
}

// MARK: - Specialized im2col-pack for 3×3 stride-1 padding-1 layers
//
// Encodes 4 of the encoder's 13 conv layers (L1, L2, L4, L5) which
// together accounted for ~370 µs of v0.15.0's per-encode time. The
// general kernel below issues 16 single-byte strided stores per
// (oi, ic, ki, kj) inner step — store-buffer pressure caps it at
// ~30% of theoretical throughput. This specialization:
//
//   1. Loads three source rows (si = oi±1, oi) per (oi, ic) once.
//   2. Builds the nine K-vectors (kj sweep × ki sweep) in-register
//      via `vextq_s8` shifts that auto-handle the kj edge padding.
//   3. Uses `vst4q_u8` to interleave four K-columns at a time into a
//      64-byte temp buffer, then issues `outW` strided 32-bit
//      stores per K-block of 4 — collapsing 4 byte-stores into 1
//      word-store per oj.
//
// Falls through to the general kernel when shape doesn't match.

#if defined(__ARM_NEON)
static inline uint8x16_t bh_load_row_or_pad(
    const uint8_t* src, int si, int inH, int inW, uint8_t pad_fill
) {
    if (si < 0 || si >= inH) {
        return vdupq_n_u8(pad_fill);
    }
    // Loading 16 bytes is safe iff caller padded the source buffer
    // by ≥ 16 bytes past its last row (Int8Forward scratch does).
    uint8x16_t v = vld1q_u8(src + (size_t)si * inW);
    if (inW < 16) {
        // Mask lanes [inW, 16) to pad_fill so the kj=0/2 shifts pull
        // padding (not garbage from the next row of the same channel).
        // Build a per-lane mask 0xFF for valid, 0x00 for invalid.
        const uint8_t lane_idx[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
        uint8x16_t idx_v = vld1q_u8(lane_idx);
        uint8x16_t inW_v = vdupq_n_u8((uint8_t)inW);
        uint8x16_t valid = vcltq_u8(idx_v, inW_v);  // 0xFF where lane < inW
        uint8x16_t pad_v = vdupq_n_u8(pad_fill);
        v = vbslq_u8(valid, v, pad_v);
    }
    return v;
}
#endif

void bh_im2col_pack_int8_3x3_s1_p1(
    const uint8_t* src,
    int8_t* dst,
    int inCh, int inH, int inW,
    int kCh_padded,
    uint8_t pad_fill
) {
#if defined(__ARM_NEON)
    const int outH = inH;
    const int outW = inW;
    const int kCh = inCh * 9;
    const uint8_t pad_xor = pad_fill ^ (uint8_t)0x80;
    const int8x16_t pad_s8_v = vreinterpretq_s8_u8(vdupq_n_u8(pad_xor));

    // Zero K-padded tail bytes once per row (kCh_padded - kCh ≤ 7).
    if (kCh_padded > kCh) {
        for (int j = 0; j < outH * outW; ++j) {
            for (int kk = kCh; kk < kCh_padded; ++kk) {
                dst[(size_t)j * kCh_padded + kk] = 0;
            }
        }
    }

    // 4-K-block staging buffer (must fit two vst4q_u8 worths = 128 B).
    // Reused across all (oi, ic).
    uint8_t temp[128] __attribute__((aligned(16)));

    for (int oi = 0; oi < outH; ++oi) {
        for (int ic = 0; ic < inCh; ++ic) {
            const uint8_t* ch = src + (size_t)ic * inH * inW;

            // Load 3 source rows, masked + pad-handled.
            uint8x16_t r0u = bh_load_row_or_pad(ch, oi - 1, inH, inW, pad_fill);
            uint8x16_t r1u = bh_load_row_or_pad(ch, oi    , inH, inW, pad_fill);
            uint8x16_t r2u = bh_load_row_or_pad(ch, oi + 1, inH, inW, pad_fill);

            // XOR to int8 representation.
            int8x16_t r0 = vreinterpretq_s8_u8(veorq_u8(r0u, vdupq_n_u8(0x80)));
            int8x16_t r1 = vreinterpretq_s8_u8(veorq_u8(r1u, vdupq_n_u8(0x80)));
            int8x16_t r2 = vreinterpretq_s8_u8(veorq_u8(r2u, vdupq_n_u8(0x80)));

            // Build the 9 K-vectors. For kj=0 (sj=oj-1) we shift the
            // row left by 1 lane, filling lane 0 with pad. For kj=2
            // (sj=oj+1) we shift right, filling lane 15 with pad.
            // `vextq_s8(a, b, n)` returns the 16 bytes from
            // a[n..15] || b[0..n-1].
            int8x16_t k0_0 = vextq_s8(pad_s8_v, r0, 15);  // ki=0, kj=0
            int8x16_t k0_1 = r0;                            // ki=0, kj=1
            int8x16_t k0_2 = vextq_s8(r0, pad_s8_v, 1);   // ki=0, kj=2
            int8x16_t k1_0 = vextq_s8(pad_s8_v, r1, 15);  // ki=1, kj=0
            int8x16_t k1_1 = r1;                            // ki=1, kj=1
            int8x16_t k1_2 = vextq_s8(r1, pad_s8_v, 1);   // ki=1, kj=2
            int8x16_t k2_0 = vextq_s8(pad_s8_v, r2, 15);  // ki=2, kj=0
            int8x16_t k2_1 = r2;                            // ki=2, kj=1
            int8x16_t k2_2 = vextq_s8(r2, pad_s8_v, 1);   // ki=2, kj=2

            // Interleave K=0..3 into the first 64 bytes of temp:
            //   temp[oj*4 + 0..3] = (k0_0[oj], k0_1[oj], k0_2[oj], k1_0[oj])
            uint8x16x4_t bundle03 = {{
                vreinterpretq_u8_s8(k0_0),
                vreinterpretq_u8_s8(k0_1),
                vreinterpretq_u8_s8(k0_2),
                vreinterpretq_u8_s8(k1_0)
            }};
            vst4q_u8(temp + 0, bundle03);

            // Interleave K=4..7 into the next 64 bytes:
            //   temp[64 + oj*4 + 0..3] = (k1_1[oj], k1_2[oj], k2_0[oj], k2_1[oj])
            uint8x16x4_t bundle47 = {{
                vreinterpretq_u8_s8(k1_1),
                vreinterpretq_u8_s8(k1_2),
                vreinterpretq_u8_s8(k2_0),
                vreinterpretq_u8_s8(k2_1)
            }};
            vst4q_u8(temp + 64, bundle47);

            // K=8 (kj=2 of ki=2) — last column. Spill to a 16-byte
            // scratch so we can do byte-indexed lookups by oj.
            uint8_t k8_lanes[16] __attribute__((aligned(16)));
            vst1q_u8(k8_lanes, vreinterpretq_u8_s8(k2_2));

            // Strided per-oj writes. For each oj, dst position is
            // (oi*outW + oj) * kCh_padded + ic*9.
            int8_t* dst_base = dst + (size_t)(oi * outW) * kCh_padded + ic * 9;
            for (int oj = 0; oj < outW; ++oj) {
                int8_t* dst_oj = dst_base + (size_t)oj * kCh_padded;
                // K=0..3 (4 bytes from first vst4q tile).
                __builtin_memcpy(dst_oj + 0, temp + (size_t)oj * 4, 4);
                // K=4..7 (4 bytes from second vst4q tile).
                __builtin_memcpy(dst_oj + 4, temp + 64 + (size_t)oj * 4, 4);
                // K=8 (1 byte).
                dst_oj[8] = (int8_t)k8_lanes[oj];
            }
        }
    }
#else
    // Non-NEON fallback — call the general kernel.
    bh_im2col_pack_int8(src, dst, inCh, inH, inW, 3, 3, 1, 1, 1, 1,
                        inH, inW, kCh_padded, pad_fill);
#endif
}

// MARK: - Fused im2col + pack (NEON, hot path for 3×3 layers)

void bh_im2col_pack_int8(
    const uint8_t* src,
    int8_t* dst,
    int inCh, int inH, int inW,
    int kH, int kW,
    int sH, int sW,
    int pH, int pW,
    int outH, int outW,
    int kCh_padded,
    uint8_t pad_fill
) {
    const int kCh    = inCh * kH * kW;
    const int outPx  = outH * outW;
    const int8_t pad_s8 = (int8_t)(pad_fill ^ 0x80);

    // Zero the K-padding tail of every output row once (cheap since
    // kCh_padded - kCh is at most 3 bytes per row).
    if (kCh_padded > kCh) {
        for (int j = 0; j < outPx; ++j) {
            for (int kk = kCh; kk < kCh_padded; ++kk) {
                dst[(size_t)j * kCh_padded + kk] = 0;
            }
        }
    }

    // Outer loop: (oi, ki, ic, kj). For each (oi, ki, ic, kj) the
    // inner oj loop is sequential in source (stride sW == 1 in the
    // common case) and stride kCh_padded in destination. We load 16
    // source bytes per chunk and scatter to 16 destinations via
    // single-byte stores; on Apple Silicon the LSU absorbs ~4
    // stores/cycle which is well within memory parallelism.
    for (int oi = 0; oi < outH; ++oi) {
        for (int ki = 0; ki < kH; ++ki) {
            const int si = oi * sH - pH + ki;
            const int validRow = (si >= 0 && si < inH);
            for (int ic = 0; ic < inCh; ++ic) {
                const int chBase = ic * inH * inW;
                const uint8_t* src_row = validRow ? &src[chBase + si * inW] : NULL;
                for (int kj = 0; kj < kW; ++kj) {
                    const int k_idx = ic * kH * kW + ki * kW + kj;
                    int8_t* dst_oj = dst + (size_t)(oi * outW) * kCh_padded + k_idx;

                    if (sW == 1) {
                        // sj = oj + (kj - pW). Range of valid oj where
                        // sj ∈ [0, inW) is oj ∈ [pW - kj, inW + pW - kj).
                        int oj_lo = pW - kj;
                        int oj_hi = inW + pW - kj;
                        if (oj_lo < 0) oj_lo = 0;
                        if (oj_hi > outW) oj_hi = outW;

                        int oj = 0;
                        // Pad-fill the [0, oj_lo) prefix.
                        for (; oj < oj_lo; ++oj) {
                            dst_oj[(size_t)oj * kCh_padded] = pad_s8;
                        }
                        if (validRow) {
                            const uint8_t* sp = src_row + (oj_lo + (kj - pW));
#if defined(__ARM_NEON)
                            // 16-byte vectorized middle: load 16 source
                            // bytes, XOR sign bit, scatter to 16
                            // strided dst positions.
                            for (; oj + 16 <= oj_hi; oj += 16) {
                                uint8x16_t v = vld1q_u8(sp);
                                v = veorq_u8(v, vdupq_n_u8(0x80));
                                int8x16_t s = vreinterpretq_s8_u8(v);
                                // Scatter 16 bytes to dst[oj..oj+15] *
                                // kCh_padded. Compiler emits one byte
                                // store per lane; LSU issues ~4/cycle.
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  0) * kCh_padded, s,  0);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  1) * kCh_padded, s,  1);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  2) * kCh_padded, s,  2);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  3) * kCh_padded, s,  3);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  4) * kCh_padded, s,  4);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  5) * kCh_padded, s,  5);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  6) * kCh_padded, s,  6);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  7) * kCh_padded, s,  7);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  8) * kCh_padded, s,  8);
                                vst1q_lane_s8(dst_oj + (size_t)(oj +  9) * kCh_padded, s,  9);
                                vst1q_lane_s8(dst_oj + (size_t)(oj + 10) * kCh_padded, s, 10);
                                vst1q_lane_s8(dst_oj + (size_t)(oj + 11) * kCh_padded, s, 11);
                                vst1q_lane_s8(dst_oj + (size_t)(oj + 12) * kCh_padded, s, 12);
                                vst1q_lane_s8(dst_oj + (size_t)(oj + 13) * kCh_padded, s, 13);
                                vst1q_lane_s8(dst_oj + (size_t)(oj + 14) * kCh_padded, s, 14);
                                vst1q_lane_s8(dst_oj + (size_t)(oj + 15) * kCh_padded, s, 15);
                                sp += 16;
                            }
#endif
                            for (; oj < oj_hi; ++oj, ++sp) {
                                dst_oj[(size_t)oj * kCh_padded] = (int8_t)((*sp) ^ 0x80);
                            }
                        } else {
                            // Whole row is pad — just fill with pad.
                            for (; oj < oj_hi; ++oj) {
                                dst_oj[(size_t)oj * kCh_padded] = pad_s8;
                            }
                        }
                        // Pad-fill the [oj_hi, outW) suffix.
                        for (; oj < outW; ++oj) {
                            dst_oj[(size_t)oj * kCh_padded] = pad_s8;
                        }
                    } else {
                        // General-stride scalar path.
                        for (int oj = 0; oj < outW; ++oj) {
                            const int sj = oj * sW - pW + kj;
                            uint8_t byte = pad_fill;
                            if (validRow && sj >= 0 && sj < inW) {
                                byte = src_row[sj];
                            }
                            dst_oj[(size_t)oj * kCh_padded] = (int8_t)(byte ^ 0x80);
                        }
                    }
                }
            }
        }
    }
}

// MARK: - SDOT-based int8 GEMM fused with per-channel requantize

#if defined(__ARM_FEATURE_DOTPROD)
// Convert one int32x4_t accumulator to uint8x8_t (lanes 0..3 hold the
// quantized output; lanes 4..7 are zero) using the same fp32-pipeline
// the requant kernel uses. Helper for the fused-requant store path.
static inline uint8x8_t bh_requant_lane(
    int32x4_t acc, float32x4_t M_v, float32x4_t zp_v,
    float32x4_t lo_v, float32x4_t hi_v
) {
    float32x4_t f = vfmaq_f32(zp_v, vcvtq_f32_s32(acc), M_v);
    f = vrndnq_f32(f);
    f = vminq_f32(vmaxq_f32(f, lo_v), hi_v);
    uint32x4_t u = vcvtq_u32_f32(f);
    uint16x4_t h = vqmovn_u32(u);
    return vqmovn_u16(vcombine_u16(h, vdup_n_u16(0)));  // low 4 lanes valid
}
#endif

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
) {
#if defined(__ARM_FEATURE_DOTPROD)
    const float32x4_t zp_v = vdupq_n_f32((float)output_zp);
    const float32x4_t lo_v = vdupq_n_f32(0.0f);
    const float32x4_t hi_v = vdupq_n_f32(255.0f);

    int oc = 0;
    for (; oc + 4 <= outCh; oc += 4) {
        const int8_t* w0 = weights + (size_t)(oc + 0) * kCh_padded;
        const int8_t* w1 = weights + (size_t)(oc + 1) * kCh_padded;
        const int8_t* w2 = weights + (size_t)(oc + 2) * kCh_padded;
        const int8_t* w3 = weights + (size_t)(oc + 3) * kCh_padded;
        uint8_t* o0 = out_uint8 + (size_t)(oc + 0) * outPx;
        uint8_t* o1 = out_uint8 + (size_t)(oc + 1) * outPx;
        uint8_t* o2 = out_uint8 + (size_t)(oc + 2) * outPx;
        uint8_t* o3 = out_uint8 + (size_t)(oc + 3) * outPx;
        const int32_t b0 = biases_corrected[oc + 0];
        const int32_t b1 = biases_corrected[oc + 1];
        const int32_t b2 = biases_corrected[oc + 2];
        const int32_t b3 = biases_corrected[oc + 3];
        const float32x4_t M0_v = vdupq_n_f32(M_per_channel[oc + 0]);
        const float32x4_t M1_v = vdupq_n_f32(M_per_channel[oc + 1]);
        const float32x4_t M2_v = vdupq_n_f32(M_per_channel[oc + 2]);
        const float32x4_t M3_v = vdupq_n_f32(M_per_channel[oc + 3]);

        int j = 0;
        for (; j + 16 <= outPx; j += 16) {
            int32x4_t a00 = vdupq_n_s32(b0), a01 = vdupq_n_s32(b0), a02 = vdupq_n_s32(b0), a03 = vdupq_n_s32(b0);
            int32x4_t a10 = vdupq_n_s32(b1), a11 = vdupq_n_s32(b1), a12 = vdupq_n_s32(b1), a13 = vdupq_n_s32(b1);
            int32x4_t a20 = vdupq_n_s32(b2), a21 = vdupq_n_s32(b2), a22 = vdupq_n_s32(b2), a23 = vdupq_n_s32(b2);
            int32x4_t a30 = vdupq_n_s32(b3), a31 = vdupq_n_s32(b3), a32_acc = vdupq_n_s32(b3), a33 = vdupq_n_s32(b3);

            const int8_t* act_base = activations_t + (size_t)j * kCh_padded;

            for (int k = 0; k + 4 <= kCh_padded; k += 4) {
                int32_t aq00, aq01, aq02, aq03;
                int32_t aq10, aq11, aq12, aq13;
                int32_t aq20, aq21, aq22, aq23;
                int32_t aq30, aq31, aq32, aq33;
                __builtin_memcpy(&aq00, act_base + (size_t) 0 * kCh_padded + k, 4);
                __builtin_memcpy(&aq01, act_base + (size_t) 1 * kCh_padded + k, 4);
                __builtin_memcpy(&aq02, act_base + (size_t) 2 * kCh_padded + k, 4);
                __builtin_memcpy(&aq03, act_base + (size_t) 3 * kCh_padded + k, 4);
                __builtin_memcpy(&aq10, act_base + (size_t) 4 * kCh_padded + k, 4);
                __builtin_memcpy(&aq11, act_base + (size_t) 5 * kCh_padded + k, 4);
                __builtin_memcpy(&aq12, act_base + (size_t) 6 * kCh_padded + k, 4);
                __builtin_memcpy(&aq13, act_base + (size_t) 7 * kCh_padded + k, 4);
                __builtin_memcpy(&aq20, act_base + (size_t) 8 * kCh_padded + k, 4);
                __builtin_memcpy(&aq21, act_base + (size_t) 9 * kCh_padded + k, 4);
                __builtin_memcpy(&aq22, act_base + (size_t)10 * kCh_padded + k, 4);
                __builtin_memcpy(&aq23, act_base + (size_t)11 * kCh_padded + k, 4);
                __builtin_memcpy(&aq30, act_base + (size_t)12 * kCh_padded + k, 4);
                __builtin_memcpy(&aq31, act_base + (size_t)13 * kCh_padded + k, 4);
                __builtin_memcpy(&aq32, act_base + (size_t)14 * kCh_padded + k, 4);
                __builtin_memcpy(&aq33, act_base + (size_t)15 * kCh_padded + k, 4);

                int32x4_t a32_0 = { aq00, aq01, aq02, aq03 };
                int32x4_t a32_1 = { aq10, aq11, aq12, aq13 };
                int32x4_t a32_2 = { aq20, aq21, aq22, aq23 };
                int32x4_t a32_3 = { aq30, aq31, aq32, aq33 };
                int8x16_t a_v0 = vreinterpretq_s8_s32(a32_0);
                int8x16_t a_v1 = vreinterpretq_s8_s32(a32_1);
                int8x16_t a_v2 = vreinterpretq_s8_s32(a32_2);
                int8x16_t a_v3 = vreinterpretq_s8_s32(a32_3);

                int32_t w0_q, w1_q, w2_q, w3_q;
                __builtin_memcpy(&w0_q, w0 + k, 4);
                __builtin_memcpy(&w1_q, w1 + k, 4);
                __builtin_memcpy(&w2_q, w2 + k, 4);
                __builtin_memcpy(&w3_q, w3 + k, 4);
                int8x16_t b0v = vreinterpretq_s8_s32(vdupq_n_s32(w0_q));
                int8x16_t b1v = vreinterpretq_s8_s32(vdupq_n_s32(w1_q));
                int8x16_t b2v = vreinterpretq_s8_s32(vdupq_n_s32(w2_q));
                int8x16_t b3v = vreinterpretq_s8_s32(vdupq_n_s32(w3_q));

                a00 = vdotq_s32(a00, a_v0, b0v);
                a01 = vdotq_s32(a01, a_v1, b0v);
                a02 = vdotq_s32(a02, a_v2, b0v);
                a03 = vdotq_s32(a03, a_v3, b0v);
                a10 = vdotq_s32(a10, a_v0, b1v);
                a11 = vdotq_s32(a11, a_v1, b1v);
                a12 = vdotq_s32(a12, a_v2, b1v);
                a13 = vdotq_s32(a13, a_v3, b1v);
                a20 = vdotq_s32(a20, a_v0, b2v);
                a21 = vdotq_s32(a21, a_v1, b2v);
                a22 = vdotq_s32(a22, a_v2, b2v);
                a23 = vdotq_s32(a23, a_v3, b2v);
                a30 = vdotq_s32(a30, a_v0, b3v);
                a31 = vdotq_s32(a31, a_v1, b3v);
                a32_acc = vdotq_s32(a32_acc, a_v2, b3v);
                a33 = vdotq_s32(a33, a_v3, b3v);
            }

            // Fused requant + store: convert each oc's 4×int32x4 acc
            // to one uint8x16 via fp32 multiply+zp+clamp+narrow.
            #define BH_PACK_OC(o, A, B, C, D, M_v) do {                            \
                float32x4_t f0 = vfmaq_f32(zp_v, vcvtq_f32_s32(A), (M_v));         \
                float32x4_t f1 = vfmaq_f32(zp_v, vcvtq_f32_s32(B), (M_v));         \
                float32x4_t f2 = vfmaq_f32(zp_v, vcvtq_f32_s32(C), (M_v));         \
                float32x4_t f3 = vfmaq_f32(zp_v, vcvtq_f32_s32(D), (M_v));         \
                f0 = vrndnq_f32(f0); f1 = vrndnq_f32(f1);                          \
                f2 = vrndnq_f32(f2); f3 = vrndnq_f32(f3);                          \
                f0 = vminq_f32(vmaxq_f32(f0, lo_v), hi_v);                         \
                f1 = vminq_f32(vmaxq_f32(f1, lo_v), hi_v);                         \
                f2 = vminq_f32(vmaxq_f32(f2, lo_v), hi_v);                         \
                f3 = vminq_f32(vmaxq_f32(f3, lo_v), hi_v);                         \
                uint32x4_t u0 = vcvtq_u32_f32(f0);                                 \
                uint32x4_t u1 = vcvtq_u32_f32(f1);                                 \
                uint32x4_t u2 = vcvtq_u32_f32(f2);                                 \
                uint32x4_t u3 = vcvtq_u32_f32(f3);                                 \
                uint8x8_t  b01 = vqmovn_u16(vcombine_u16(vqmovn_u32(u0), vqmovn_u32(u1))); \
                uint8x8_t  b23 = vqmovn_u16(vcombine_u16(vqmovn_u32(u2), vqmovn_u32(u3))); \
                vst1q_u8((o) + j, vcombine_u8(b01, b23));                          \
            } while (0)

            BH_PACK_OC(o0, a00, a01, a02, a03, M0_v);
            BH_PACK_OC(o1, a10, a11, a12, a13, M1_v);
            BH_PACK_OC(o2, a20, a21, a22, a23, M2_v);
            BH_PACK_OC(o3, a30, a31, a32_acc, a33, M3_v);

            #undef BH_PACK_OC
        }

        // 4-j tail and 1-j tail: fall through to scalar SDOT-equivalent
        // + scalar requant. Same algebra as the 16-j path.
        for (; j + 4 <= outPx; j += 4) {
            int32x4_t a0 = vdupq_n_s32(b0);
            int32x4_t a1 = vdupq_n_s32(b1);
            int32x4_t a2 = vdupq_n_s32(b2);
            int32x4_t a3 = vdupq_n_s32(b3);
            const int8_t* act0 = activations_t + (size_t)(j + 0) * kCh_padded;
            const int8_t* act1 = activations_t + (size_t)(j + 1) * kCh_padded;
            const int8_t* act2 = activations_t + (size_t)(j + 2) * kCh_padded;
            const int8_t* act3 = activations_t + (size_t)(j + 3) * kCh_padded;
            for (int k = 0; k + 4 <= kCh_padded; k += 4) {
                int32_t a0_q, a1_q, a2_q, a3_q;
                __builtin_memcpy(&a0_q, act0 + k, 4);
                __builtin_memcpy(&a1_q, act1 + k, 4);
                __builtin_memcpy(&a2_q, act2 + k, 4);
                __builtin_memcpy(&a3_q, act3 + k, 4);
                int32x4_t a32 = { a0_q, a1_q, a2_q, a3_q };
                int8x16_t a_v = vreinterpretq_s8_s32(a32);
                int32_t w0_q, w1_q, w2_q, w3_q;
                __builtin_memcpy(&w0_q, w0 + k, 4);
                __builtin_memcpy(&w1_q, w1 + k, 4);
                __builtin_memcpy(&w2_q, w2 + k, 4);
                __builtin_memcpy(&w3_q, w3 + k, 4);
                int8x16_t b0v = vreinterpretq_s8_s32(vdupq_n_s32(w0_q));
                int8x16_t b1v = vreinterpretq_s8_s32(vdupq_n_s32(w1_q));
                int8x16_t b2v = vreinterpretq_s8_s32(vdupq_n_s32(w2_q));
                int8x16_t b3v = vreinterpretq_s8_s32(vdupq_n_s32(w3_q));
                a0 = vdotq_s32(a0, a_v, b0v);
                a1 = vdotq_s32(a1, a_v, b1v);
                a2 = vdotq_s32(a2, a_v, b2v);
                a3 = vdotq_s32(a3, a_v, b3v);
            }
            uint8x8_t r0 = bh_requant_lane(a0, M0_v, zp_v, lo_v, hi_v);
            uint8x8_t r1 = bh_requant_lane(a1, M1_v, zp_v, lo_v, hi_v);
            uint8x8_t r2 = bh_requant_lane(a2, M2_v, zp_v, lo_v, hi_v);
            uint8x8_t r3 = bh_requant_lane(a3, M3_v, zp_v, lo_v, hi_v);
            // Each r* has the 4 valid lanes in bytes 0..3.
            __builtin_memcpy(o0 + j, &r0, 4);
            __builtin_memcpy(o1 + j, &r1, 4);
            __builtin_memcpy(o2 + j, &r2, 4);
            __builtin_memcpy(o3 + j, &r3, 4);
        }
        for (; j < outPx; ++j) {
            int32_t s0 = b0, s1 = b1, s2 = b2, s3 = b3;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                int32_t a = (int32_t)act[k];
                s0 += a * (int32_t)w0[k];
                s1 += a * (int32_t)w1[k];
                s2 += a * (int32_t)w2[k];
                s3 += a * (int32_t)w3[k];
            }
            #define BH_REQUANT_SCALAR(s, oc_idx, out_ptr) do {                     \
                float q = roundf((float)(s) * M_per_channel[(oc_idx)])             \
                          + (float)output_zp;                                       \
                if (q < 0.0f) q = 0.0f;                                            \
                if (q > 255.0f) q = 255.0f;                                        \
                (out_ptr)[j] = (uint8_t)q;                                         \
            } while (0)
            BH_REQUANT_SCALAR(s0, oc + 0, o0);
            BH_REQUANT_SCALAR(s1, oc + 1, o1);
            BH_REQUANT_SCALAR(s2, oc + 2, o2);
            BH_REQUANT_SCALAR(s3, oc + 3, o3);
            #undef BH_REQUANT_SCALAR
        }
    }

    // Single-oc tail.
    for (; oc < outCh; ++oc) {
        const int8_t* w_row = weights + (size_t)oc * kCh_padded;
        uint8_t* out_row = out_uint8 + (size_t)oc * outPx;
        const int32_t bias = biases_corrected[oc];
        const float M = M_per_channel[oc];
        for (int j = 0; j < outPx; ++j) {
            int32_t s = bias;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                s += (int32_t)act[k] * (int32_t)w_row[k];
            }
            float q = roundf((float)s * M) + (float)output_zp;
            if (q < 0.0f) q = 0.0f;
            if (q > 255.0f) q = 255.0f;
            out_row[j] = (uint8_t)q;
        }
    }
#else
    // Scalar fallback.
    for (int oc = 0; oc < outCh; ++oc) {
        const int8_t* w_row = weights + (size_t)oc * kCh_padded;
        uint8_t* out_row = out_uint8 + (size_t)oc * outPx;
        const int32_t bias = biases_corrected[oc];
        const float M = M_per_channel[oc];
        for (int j = 0; j < outPx; ++j) {
            int32_t s = bias;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                s += (int32_t)act[k] * (int32_t)w_row[k];
            }
            float q = roundf((float)s * M) + (float)output_zp;
            if (q < 0.0f) q = 0.0f;
            if (q > 255.0f) q = 255.0f;
            out_row[j] = (uint8_t)q;
        }
    }
#endif
}

// MARK: - SDOT-based int8 GEMM

void bh_int8_gemm_sdot(
    const int8_t* weights,
    const int8_t* activations_t,
    const int32_t* biases_corrected,
    int32_t* out,
    int outCh,
    int kCh_padded,
    int outPx
) {
#if defined(__ARM_FEATURE_DOTPROD)
    int oc = 0;

    // 4-oc × 4-j tile: 4 SDOT instructions per inner iteration share
    // one activation block (16 bytes spanning 4 j-positions × 4
    // k-values) across 4 output channels. Each oc has its own 4-byte
    // weight quad broadcast across 4 lanes.
    for (; oc + 4 <= outCh; oc += 4) {
        const int8_t* w0 = weights + (size_t)(oc + 0) * kCh_padded;
        const int8_t* w1 = weights + (size_t)(oc + 1) * kCh_padded;
        const int8_t* w2 = weights + (size_t)(oc + 2) * kCh_padded;
        const int8_t* w3 = weights + (size_t)(oc + 3) * kCh_padded;
        int32_t* o0 = out + (size_t)(oc + 0) * outPx;
        int32_t* o1 = out + (size_t)(oc + 1) * outPx;
        int32_t* o2 = out + (size_t)(oc + 2) * outPx;
        int32_t* o3 = out + (size_t)(oc + 3) * outPx;
        const int32_t b0 = biases_corrected[oc + 0];
        const int32_t b1 = biases_corrected[oc + 1];
        const int32_t b2 = biases_corrected[oc + 2];
        const int32_t b3 = biases_corrected[oc + 3];

        int j = 0;

        // 4-oc × 16-j main tile. 16 SDOT per inner K-step, sharing 4
        // weight loads across 4 j-blocks-of-4 lanes (16 lanes total).
        // Accumulators: 4 oc × 4 j-blocks = 16 int32x4 — fits inside
        // the 32-register NEON file with room for live loads.
        for (; j + 16 <= outPx; j += 16) {
            int32x4_t a00 = vdupq_n_s32(b0), a01 = vdupq_n_s32(b0), a02 = vdupq_n_s32(b0), a03 = vdupq_n_s32(b0);
            int32x4_t a10 = vdupq_n_s32(b1), a11 = vdupq_n_s32(b1), a12 = vdupq_n_s32(b1), a13 = vdupq_n_s32(b1);
            int32x4_t a20 = vdupq_n_s32(b2), a21 = vdupq_n_s32(b2), a22 = vdupq_n_s32(b2), a23 = vdupq_n_s32(b2);
            int32x4_t a30 = vdupq_n_s32(b3), a31 = vdupq_n_s32(b3), a32_acc = vdupq_n_s32(b3), a33 = vdupq_n_s32(b3);

            const int8_t* act_base = activations_t + (size_t)j * kCh_padded;

            for (int k = 0; k + 4 <= kCh_padded; k += 4) {
                // Four activation tiles (one per j-block-of-4).
                int32_t aq00, aq01, aq02, aq03;
                int32_t aq10, aq11, aq12, aq13;
                int32_t aq20, aq21, aq22, aq23;
                int32_t aq30, aq31, aq32, aq33;
                __builtin_memcpy(&aq00, act_base + (size_t) 0 * kCh_padded + k, 4);
                __builtin_memcpy(&aq01, act_base + (size_t) 1 * kCh_padded + k, 4);
                __builtin_memcpy(&aq02, act_base + (size_t) 2 * kCh_padded + k, 4);
                __builtin_memcpy(&aq03, act_base + (size_t) 3 * kCh_padded + k, 4);
                __builtin_memcpy(&aq10, act_base + (size_t) 4 * kCh_padded + k, 4);
                __builtin_memcpy(&aq11, act_base + (size_t) 5 * kCh_padded + k, 4);
                __builtin_memcpy(&aq12, act_base + (size_t) 6 * kCh_padded + k, 4);
                __builtin_memcpy(&aq13, act_base + (size_t) 7 * kCh_padded + k, 4);
                __builtin_memcpy(&aq20, act_base + (size_t) 8 * kCh_padded + k, 4);
                __builtin_memcpy(&aq21, act_base + (size_t) 9 * kCh_padded + k, 4);
                __builtin_memcpy(&aq22, act_base + (size_t)10 * kCh_padded + k, 4);
                __builtin_memcpy(&aq23, act_base + (size_t)11 * kCh_padded + k, 4);
                __builtin_memcpy(&aq30, act_base + (size_t)12 * kCh_padded + k, 4);
                __builtin_memcpy(&aq31, act_base + (size_t)13 * kCh_padded + k, 4);
                __builtin_memcpy(&aq32, act_base + (size_t)14 * kCh_padded + k, 4);
                __builtin_memcpy(&aq33, act_base + (size_t)15 * kCh_padded + k, 4);

                int32x4_t a32_0 = { aq00, aq01, aq02, aq03 };
                int32x4_t a32_1 = { aq10, aq11, aq12, aq13 };
                int32x4_t a32_2 = { aq20, aq21, aq22, aq23 };
                int32x4_t a32_3 = { aq30, aq31, aq32, aq33 };
                int8x16_t a_v0 = vreinterpretq_s8_s32(a32_0);
                int8x16_t a_v1 = vreinterpretq_s8_s32(a32_1);
                int8x16_t a_v2 = vreinterpretq_s8_s32(a32_2);
                int8x16_t a_v3 = vreinterpretq_s8_s32(a32_3);

                int32_t w0_q, w1_q, w2_q, w3_q;
                __builtin_memcpy(&w0_q, w0 + k, 4);
                __builtin_memcpy(&w1_q, w1 + k, 4);
                __builtin_memcpy(&w2_q, w2 + k, 4);
                __builtin_memcpy(&w3_q, w3 + k, 4);
                int8x16_t b0v = vreinterpretq_s8_s32(vdupq_n_s32(w0_q));
                int8x16_t b1v = vreinterpretq_s8_s32(vdupq_n_s32(w1_q));
                int8x16_t b2v = vreinterpretq_s8_s32(vdupq_n_s32(w2_q));
                int8x16_t b3v = vreinterpretq_s8_s32(vdupq_n_s32(w3_q));

                a00 = vdotq_s32(a00, a_v0, b0v);
                a01 = vdotq_s32(a01, a_v1, b0v);
                a02 = vdotq_s32(a02, a_v2, b0v);
                a03 = vdotq_s32(a03, a_v3, b0v);
                a10 = vdotq_s32(a10, a_v0, b1v);
                a11 = vdotq_s32(a11, a_v1, b1v);
                a12 = vdotq_s32(a12, a_v2, b1v);
                a13 = vdotq_s32(a13, a_v3, b1v);
                a20 = vdotq_s32(a20, a_v0, b2v);
                a21 = vdotq_s32(a21, a_v1, b2v);
                a22 = vdotq_s32(a22, a_v2, b2v);
                a23 = vdotq_s32(a23, a_v3, b2v);
                a30 = vdotq_s32(a30, a_v0, b3v);
                a31 = vdotq_s32(a31, a_v1, b3v);
                a32_acc = vdotq_s32(a32_acc, a_v2, b3v);
                a33 = vdotq_s32(a33, a_v3, b3v);
            }

            vst1q_s32(o0 + j +  0, a00); vst1q_s32(o0 + j +  4, a01);
            vst1q_s32(o0 + j +  8, a02); vst1q_s32(o0 + j + 12, a03);
            vst1q_s32(o1 + j +  0, a10); vst1q_s32(o1 + j +  4, a11);
            vst1q_s32(o1 + j +  8, a12); vst1q_s32(o1 + j + 12, a13);
            vst1q_s32(o2 + j +  0, a20); vst1q_s32(o2 + j +  4, a21);
            vst1q_s32(o2 + j +  8, a22); vst1q_s32(o2 + j + 12, a23);
            vst1q_s32(o3 + j +  0, a30); vst1q_s32(o3 + j +  4, a31);
            vst1q_s32(o3 + j +  8, a32_acc); vst1q_s32(o3 + j + 12, a33);
        }

        // 4-j tail (outPx % 16 ≥ 4).
        for (; j + 4 <= outPx; j += 4) {
            int32x4_t a0 = vdupq_n_s32(b0);
            int32x4_t a1 = vdupq_n_s32(b1);
            int32x4_t a2 = vdupq_n_s32(b2);
            int32x4_t a3 = vdupq_n_s32(b3);

            const int8_t* act0 = activations_t + (size_t)(j + 0) * kCh_padded;
            const int8_t* act1 = activations_t + (size_t)(j + 1) * kCh_padded;
            const int8_t* act2 = activations_t + (size_t)(j + 2) * kCh_padded;
            const int8_t* act3 = activations_t + (size_t)(j + 3) * kCh_padded;

            for (int k = 0; k + 4 <= kCh_padded; k += 4) {
                int32_t a0_q, a1_q, a2_q, a3_q;
                __builtin_memcpy(&a0_q, act0 + k, 4);
                __builtin_memcpy(&a1_q, act1 + k, 4);
                __builtin_memcpy(&a2_q, act2 + k, 4);
                __builtin_memcpy(&a3_q, act3 + k, 4);
                int32x4_t a32 = { a0_q, a1_q, a2_q, a3_q };
                int8x16_t a_v = vreinterpretq_s8_s32(a32);

                int32_t w0_q, w1_q, w2_q, w3_q;
                __builtin_memcpy(&w0_q, w0 + k, 4);
                __builtin_memcpy(&w1_q, w1 + k, 4);
                __builtin_memcpy(&w2_q, w2 + k, 4);
                __builtin_memcpy(&w3_q, w3 + k, 4);
                int8x16_t b0v = vreinterpretq_s8_s32(vdupq_n_s32(w0_q));
                int8x16_t b1v = vreinterpretq_s8_s32(vdupq_n_s32(w1_q));
                int8x16_t b2v = vreinterpretq_s8_s32(vdupq_n_s32(w2_q));
                int8x16_t b3v = vreinterpretq_s8_s32(vdupq_n_s32(w3_q));

                a0 = vdotq_s32(a0, a_v, b0v);
                a1 = vdotq_s32(a1, a_v, b1v);
                a2 = vdotq_s32(a2, a_v, b2v);
                a3 = vdotq_s32(a3, a_v, b3v);
            }

            vst1q_s32(o0 + j, a0);
            vst1q_s32(o1 + j, a1);
            vst1q_s32(o2 + j, a2);
            vst1q_s32(o3 + j, a3);
        }

        // 1-j tail for the remaining (outPx % 4) positions.
        for (; j < outPx; ++j) {
            int32_t s0 = b0, s1 = b1, s2 = b2, s3 = b3;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                int32_t a = (int32_t)act[k];
                s0 += a * (int32_t)w0[k];
                s1 += a * (int32_t)w1[k];
                s2 += a * (int32_t)w2[k];
                s3 += a * (int32_t)w3[k];
            }
            o0[j] = s0; o1[j] = s1; o2[j] = s2; o3[j] = s3;
        }
    }

    // Single-oc tail for (outCh % 4) channels.
    for (; oc < outCh; ++oc) {
        const int8_t* w_row = weights + (size_t)oc * kCh_padded;
        int32_t* out_row = out + (size_t)oc * outPx;
        const int32_t bias = biases_corrected[oc];

        int j = 0;
        for (; j + 4 <= outPx; j += 4) {
            int32x4_t acc = vdupq_n_s32(bias);
            const int8_t* act0 = activations_t + (size_t)(j + 0) * kCh_padded;
            const int8_t* act1 = activations_t + (size_t)(j + 1) * kCh_padded;
            const int8_t* act2 = activations_t + (size_t)(j + 2) * kCh_padded;
            const int8_t* act3 = activations_t + (size_t)(j + 3) * kCh_padded;
            for (int k = 0; k + 4 <= kCh_padded; k += 4) {
                int32_t a0_q, a1_q, a2_q, a3_q;
                __builtin_memcpy(&a0_q, act0 + k, 4);
                __builtin_memcpy(&a1_q, act1 + k, 4);
                __builtin_memcpy(&a2_q, act2 + k, 4);
                __builtin_memcpy(&a3_q, act3 + k, 4);
                int32x4_t a32 = { a0_q, a1_q, a2_q, a3_q };
                int8x16_t a_v = vreinterpretq_s8_s32(a32);
                int32_t w_q;
                __builtin_memcpy(&w_q, w_row + k, 4);
                int8x16_t b_v = vreinterpretq_s8_s32(vdupq_n_s32(w_q));
                acc = vdotq_s32(acc, a_v, b_v);
            }
            vst1q_s32(out_row + j, acc);
        }
        for (; j < outPx; ++j) {
            int32_t s = bias;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                s += (int32_t)act[k] * (int32_t)w_row[k];
            }
            out_row[j] = s;
        }
    }
#else
    // Scalar fallback (CI Linux x86 / non-DOTPROD arm64).
    for (int oc = 0; oc < outCh; ++oc) {
        const int8_t* w_row = weights + (size_t)oc * kCh_padded;
        int32_t* out_row = out + (size_t)oc * outPx;
        const int32_t bias = biases_corrected[oc];
        for (int j = 0; j < outPx; ++j) {
            int32_t s = bias;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                s += (int32_t)act[k] * (int32_t)w_row[k];
            }
            out_row[j] = s;
        }
    }
#endif
}

// MARK: - SMMLA (i8mm) int8 GEMM — M2+ / A15+ fast path
//
// vmmlaq_s32 semantics:
//   int32x4_t vmmlaq_s32(int32x4_t r, int8x16_t a, int8x16_t b);
//   a as 2 rows of 8 int8 (a[0..7] = row0, a[8..15] = row1)
//   b as 2 rows of 8 int8 (b[0..7] = row0, b[8..15] = row1)
//   r += outer-product:
//     r[0] += sum_{k=0..7} a[k]   * b[k]      (oc0 × j0)
//     r[1] += sum_{k=0..7} a[k]   * b[8+k]    (oc0 × j1)
//     r[2] += sum_{k=0..7} a[8+k] * b[k]      (oc1 × j0)
//     r[3] += sum_{k=0..7} a[8+k] * b[8+k]    (oc1 × j1)
//
// We pack weights as the `a` argument (rows = oc) and activations
// as the `b` argument (rows = j). Each SMMLA covers a 2×2 (oc, j)
// tile over an 8-byte K segment — 32 byte multiplies per
// instruction, exactly 2× SDOT's 16.
//
// Per-function attribute lets us emit i8mm code without enabling
// it globally for the TU; the binary loads on M1 (the function
// just won't be called there per `bh_has_i8mm()`).

#if defined(__aarch64__)
__attribute__((target("arch=armv8.6-a+i8mm")))
void bh_int8_gemm_smmla(
    const int8_t* weights,
    const int8_t* activations_t,
    const int32_t* biases_corrected,
    int32_t* out,
    int outCh,
    int kCh_padded,
    int outPx
) {
    int oc = 0;
    // 4-oc × 8-j tile. Per inner K=8 step:
    //   - Load 4 weight rows packed into 2 oc-pair tiles (16 bytes each)
    //   - Load 8 activation rows packed into 4 j-pair tiles (16 bytes each)
    //   - 8 SMMLA accumulating into 8 int32x4 (one per oc-pair × j-pair)
    for (; oc + 4 <= outCh; oc += 4) {
        const int8_t* w0 = weights + (size_t)(oc + 0) * kCh_padded;
        const int8_t* w1 = weights + (size_t)(oc + 1) * kCh_padded;
        const int8_t* w2 = weights + (size_t)(oc + 2) * kCh_padded;
        const int8_t* w3 = weights + (size_t)(oc + 3) * kCh_padded;
        int32_t* o0 = out + (size_t)(oc + 0) * outPx;
        int32_t* o1 = out + (size_t)(oc + 1) * outPx;
        int32_t* o2 = out + (size_t)(oc + 2) * outPx;
        int32_t* o3 = out + (size_t)(oc + 3) * outPx;
        const int32_t b0 = biases_corrected[oc + 0];
        const int32_t b1 = biases_corrected[oc + 1];
        const int32_t b2 = biases_corrected[oc + 2];
        const int32_t b3 = biases_corrected[oc + 3];
        const int32x4_t bias01 = { b0, b0, b1, b1 };
        const int32x4_t bias23 = { b2, b2, b3, b3 };

        int j = 0;
        for (; j + 8 <= outPx; j += 8) {
            int32x4_t r01_01 = vdupq_n_s32(0), r01_23 = vdupq_n_s32(0);
            int32x4_t r01_45 = vdupq_n_s32(0), r01_67 = vdupq_n_s32(0);
            int32x4_t r23_01 = vdupq_n_s32(0), r23_23 = vdupq_n_s32(0);
            int32x4_t r23_45 = vdupq_n_s32(0), r23_67 = vdupq_n_s32(0);

            const int8_t* aj0 = activations_t + (size_t)(j + 0) * kCh_padded;
            const int8_t* aj1 = activations_t + (size_t)(j + 1) * kCh_padded;
            const int8_t* aj2 = activations_t + (size_t)(j + 2) * kCh_padded;
            const int8_t* aj3 = activations_t + (size_t)(j + 3) * kCh_padded;
            const int8_t* aj4 = activations_t + (size_t)(j + 4) * kCh_padded;
            const int8_t* aj5 = activations_t + (size_t)(j + 5) * kCh_padded;
            const int8_t* aj6 = activations_t + (size_t)(j + 6) * kCh_padded;
            const int8_t* aj7 = activations_t + (size_t)(j + 7) * kCh_padded;

            for (int k = 0; k < kCh_padded; k += 8) {
                int8x16_t w01 = vcombine_s8(vld1_s8(w0 + k), vld1_s8(w1 + k));
                int8x16_t w23 = vcombine_s8(vld1_s8(w2 + k), vld1_s8(w3 + k));
                int8x16_t a01 = vcombine_s8(vld1_s8(aj0 + k), vld1_s8(aj1 + k));
                int8x16_t a23 = vcombine_s8(vld1_s8(aj2 + k), vld1_s8(aj3 + k));
                int8x16_t a45 = vcombine_s8(vld1_s8(aj4 + k), vld1_s8(aj5 + k));
                int8x16_t a67 = vcombine_s8(vld1_s8(aj6 + k), vld1_s8(aj7 + k));

                r01_01 = vmmlaq_s32(r01_01, w01, a01);
                r01_23 = vmmlaq_s32(r01_23, w01, a23);
                r01_45 = vmmlaq_s32(r01_45, w01, a45);
                r01_67 = vmmlaq_s32(r01_67, w01, a67);
                r23_01 = vmmlaq_s32(r23_01, w23, a01);
                r23_23 = vmmlaq_s32(r23_23, w23, a23);
                r23_45 = vmmlaq_s32(r23_45, w23, a45);
                r23_67 = vmmlaq_s32(r23_67, w23, a67);
            }

            // Repack each 4-element acc to a row-major 4-int32 chunk
            // for one oc and two consecutive j-pairs:
            //   r01_01: lanes 0..1 = oc0 at j0..j1, lanes 2..3 = oc1 at j0..j1
            //   r01_23:                ... j2..j3,                 ... j2..j3
            // -> oc0 j 0..3 = vcombine(low(r01_01), low(r01_23))
            // -> oc1 j 0..3 = vcombine(high(r01_01), high(r01_23))
            int32x4_t oc0_03 = vcombine_s32(vget_low_s32(r01_01), vget_low_s32(r01_23));
            int32x4_t oc0_47 = vcombine_s32(vget_low_s32(r01_45), vget_low_s32(r01_67));
            int32x4_t oc1_03 = vcombine_s32(vget_high_s32(r01_01), vget_high_s32(r01_23));
            int32x4_t oc1_47 = vcombine_s32(vget_high_s32(r01_45), vget_high_s32(r01_67));
            int32x4_t oc2_03 = vcombine_s32(vget_low_s32(r23_01), vget_low_s32(r23_23));
            int32x4_t oc2_47 = vcombine_s32(vget_low_s32(r23_45), vget_low_s32(r23_67));
            int32x4_t oc3_03 = vcombine_s32(vget_high_s32(r23_01), vget_high_s32(r23_23));
            int32x4_t oc3_47 = vcombine_s32(vget_high_s32(r23_45), vget_high_s32(r23_67));

            // Add bias (single scalar broadcast per oc).
            const int32x4_t b0v = vdupq_n_s32(b0), b1v = vdupq_n_s32(b1);
            const int32x4_t b2v = vdupq_n_s32(b2), b3v = vdupq_n_s32(b3);
            (void)bias01; (void)bias23;
            vst1q_s32(o0 + j + 0, vaddq_s32(oc0_03, b0v));
            vst1q_s32(o0 + j + 4, vaddq_s32(oc0_47, b0v));
            vst1q_s32(o1 + j + 0, vaddq_s32(oc1_03, b1v));
            vst1q_s32(o1 + j + 4, vaddq_s32(oc1_47, b1v));
            vst1q_s32(o2 + j + 0, vaddq_s32(oc2_03, b2v));
            vst1q_s32(o2 + j + 4, vaddq_s32(oc2_47, b2v));
            vst1q_s32(o3 + j + 0, vaddq_s32(oc3_03, b3v));
            vst1q_s32(o3 + j + 4, vaddq_s32(oc3_47, b3v));
        }

        // 8-j tail: handle remaining (outPx % 8) positions for these
        // 4 ocs with scalar SDOT-equivalent reduction.
        for (; j < outPx; ++j) {
            int32_t s0 = b0, s1 = b1, s2 = b2, s3 = b3;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                int32_t a = (int32_t)act[k];
                s0 += a * (int32_t)w0[k];
                s1 += a * (int32_t)w1[k];
                s2 += a * (int32_t)w2[k];
                s3 += a * (int32_t)w3[k];
            }
            o0[j] = s0; o1[j] = s1; o2[j] = s2; o3[j] = s3;
        }
    }

    // Single-oc tail for (outCh % 4) channels.
    for (; oc < outCh; ++oc) {
        const int8_t* w_row = weights + (size_t)oc * kCh_padded;
        int32_t* out_row = out + (size_t)oc * outPx;
        const int32_t bias = biases_corrected[oc];
        for (int j = 0; j < outPx; ++j) {
            int32_t s = bias;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                s += (int32_t)act[k] * (int32_t)w_row[k];
            }
            out_row[j] = s;
        }
    }
}

// SMMLA + per-channel requantize fused (uint8 output, no int32
// round-trip). For non-residual layers.
__attribute__((target("arch=armv8.6-a+i8mm")))
void bh_int8_gemm_smmla_requant(
    const int8_t* weights,
    const int8_t* activations_t,
    const int32_t* biases_corrected,
    const float* M_per_channel,
    int32_t output_zp,
    uint8_t* out_uint8,
    int outCh,
    int kCh_padded,
    int outPx
) {
    const float32x4_t zp_v = vdupq_n_f32((float)output_zp);
    const float32x4_t lo_v = vdupq_n_f32(0.0f);
    const float32x4_t hi_v = vdupq_n_f32(255.0f);

    int oc = 0;
    for (; oc + 4 <= outCh; oc += 4) {
        const int8_t* w0 = weights + (size_t)(oc + 0) * kCh_padded;
        const int8_t* w1 = weights + (size_t)(oc + 1) * kCh_padded;
        const int8_t* w2 = weights + (size_t)(oc + 2) * kCh_padded;
        const int8_t* w3 = weights + (size_t)(oc + 3) * kCh_padded;
        uint8_t* o0 = out_uint8 + (size_t)(oc + 0) * outPx;
        uint8_t* o1 = out_uint8 + (size_t)(oc + 1) * outPx;
        uint8_t* o2 = out_uint8 + (size_t)(oc + 2) * outPx;
        uint8_t* o3 = out_uint8 + (size_t)(oc + 3) * outPx;
        const int32_t bb0 = biases_corrected[oc + 0];
        const int32_t bb1 = biases_corrected[oc + 1];
        const int32_t bb2 = biases_corrected[oc + 2];
        const int32_t bb3 = biases_corrected[oc + 3];
        const float32x4_t M0 = vdupq_n_f32(M_per_channel[oc + 0]);
        const float32x4_t M1 = vdupq_n_f32(M_per_channel[oc + 1]);
        const float32x4_t M2 = vdupq_n_f32(M_per_channel[oc + 2]);
        const float32x4_t M3 = vdupq_n_f32(M_per_channel[oc + 3]);

        int j = 0;
        for (; j + 8 <= outPx; j += 8) {
            int32x4_t r01_01 = vdupq_n_s32(0), r01_23 = vdupq_n_s32(0);
            int32x4_t r01_45 = vdupq_n_s32(0), r01_67 = vdupq_n_s32(0);
            int32x4_t r23_01 = vdupq_n_s32(0), r23_23 = vdupq_n_s32(0);
            int32x4_t r23_45 = vdupq_n_s32(0), r23_67 = vdupq_n_s32(0);

            const int8_t* aj0 = activations_t + (size_t)(j + 0) * kCh_padded;
            const int8_t* aj1 = activations_t + (size_t)(j + 1) * kCh_padded;
            const int8_t* aj2 = activations_t + (size_t)(j + 2) * kCh_padded;
            const int8_t* aj3 = activations_t + (size_t)(j + 3) * kCh_padded;
            const int8_t* aj4 = activations_t + (size_t)(j + 4) * kCh_padded;
            const int8_t* aj5 = activations_t + (size_t)(j + 5) * kCh_padded;
            const int8_t* aj6 = activations_t + (size_t)(j + 6) * kCh_padded;
            const int8_t* aj7 = activations_t + (size_t)(j + 7) * kCh_padded;

            for (int k = 0; k < kCh_padded; k += 8) {
                int8x16_t w01 = vcombine_s8(vld1_s8(w0 + k), vld1_s8(w1 + k));
                int8x16_t w23 = vcombine_s8(vld1_s8(w2 + k), vld1_s8(w3 + k));
                int8x16_t a01 = vcombine_s8(vld1_s8(aj0 + k), vld1_s8(aj1 + k));
                int8x16_t a23 = vcombine_s8(vld1_s8(aj2 + k), vld1_s8(aj3 + k));
                int8x16_t a45 = vcombine_s8(vld1_s8(aj4 + k), vld1_s8(aj5 + k));
                int8x16_t a67 = vcombine_s8(vld1_s8(aj6 + k), vld1_s8(aj7 + k));
                r01_01 = vmmlaq_s32(r01_01, w01, a01);
                r01_23 = vmmlaq_s32(r01_23, w01, a23);
                r01_45 = vmmlaq_s32(r01_45, w01, a45);
                r01_67 = vmmlaq_s32(r01_67, w01, a67);
                r23_01 = vmmlaq_s32(r23_01, w23, a01);
                r23_23 = vmmlaq_s32(r23_23, w23, a23);
                r23_45 = vmmlaq_s32(r23_45, w23, a45);
                r23_67 = vmmlaq_s32(r23_67, w23, a67);
            }

            // Recombine to row-major per oc, add bias, fp32 requantize, narrow to uint8.
            #define BH_PACK_U8_8(out_ptr, R03, R47, BIAS_SCALAR, M_v) do {       \
                int32x4_t a03 = vaddq_s32((R03), vdupq_n_s32(BIAS_SCALAR));       \
                int32x4_t a47 = vaddq_s32((R47), vdupq_n_s32(BIAS_SCALAR));       \
                float32x4_t f03 = vfmaq_f32(zp_v, vcvtq_f32_s32(a03), (M_v));     \
                float32x4_t f47 = vfmaq_f32(zp_v, vcvtq_f32_s32(a47), (M_v));     \
                f03 = vrndnq_f32(f03); f47 = vrndnq_f32(f47);                     \
                f03 = vminq_f32(vmaxq_f32(f03, lo_v), hi_v);                      \
                f47 = vminq_f32(vmaxq_f32(f47, lo_v), hi_v);                      \
                uint16x4_t h03 = vqmovn_u32(vcvtq_u32_f32(f03));                  \
                uint16x4_t h47 = vqmovn_u32(vcvtq_u32_f32(f47));                  \
                uint8x8_t u8 = vqmovn_u16(vcombine_u16(h03, h47));                \
                vst1_u8((out_ptr) + j, u8);                                       \
            } while (0)

            int32x4_t oc0_03 = vcombine_s32(vget_low_s32 (r01_01), vget_low_s32 (r01_23));
            int32x4_t oc0_47 = vcombine_s32(vget_low_s32 (r01_45), vget_low_s32 (r01_67));
            int32x4_t oc1_03 = vcombine_s32(vget_high_s32(r01_01), vget_high_s32(r01_23));
            int32x4_t oc1_47 = vcombine_s32(vget_high_s32(r01_45), vget_high_s32(r01_67));
            int32x4_t oc2_03 = vcombine_s32(vget_low_s32 (r23_01), vget_low_s32 (r23_23));
            int32x4_t oc2_47 = vcombine_s32(vget_low_s32 (r23_45), vget_low_s32 (r23_67));
            int32x4_t oc3_03 = vcombine_s32(vget_high_s32(r23_01), vget_high_s32(r23_23));
            int32x4_t oc3_47 = vcombine_s32(vget_high_s32(r23_45), vget_high_s32(r23_67));

            BH_PACK_U8_8(o0, oc0_03, oc0_47, bb0, M0);
            BH_PACK_U8_8(o1, oc1_03, oc1_47, bb1, M1);
            BH_PACK_U8_8(o2, oc2_03, oc2_47, bb2, M2);
            BH_PACK_U8_8(o3, oc3_03, oc3_47, bb3, M3);
            #undef BH_PACK_U8_8
        }

        // Tail: scalar reduction + scalar requant.
        for (; j < outPx; ++j) {
            int32_t s0 = bb0, s1 = bb1, s2 = bb2, s3 = bb3;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                int32_t a = (int32_t)act[k];
                s0 += a * (int32_t)w0[k];
                s1 += a * (int32_t)w1[k];
                s2 += a * (int32_t)w2[k];
                s3 += a * (int32_t)w3[k];
            }
            #define BH_SCALAR_REQUANT(s_acc, oc_idx, out_ptr) do {                \
                float q = roundf((float)(s_acc) * M_per_channel[(oc_idx)])         \
                          + (float)output_zp;                                      \
                if (q < 0.0f) q = 0.0f;                                            \
                if (q > 255.0f) q = 255.0f;                                        \
                (out_ptr)[j] = (uint8_t)q;                                         \
            } while (0)
            BH_SCALAR_REQUANT(s0, oc + 0, o0);
            BH_SCALAR_REQUANT(s1, oc + 1, o1);
            BH_SCALAR_REQUANT(s2, oc + 2, o2);
            BH_SCALAR_REQUANT(s3, oc + 3, o3);
            #undef BH_SCALAR_REQUANT
        }
    }

    // Single-oc tail for (outCh % 4) channels.
    for (; oc < outCh; ++oc) {
        const int8_t* w_row = weights + (size_t)oc * kCh_padded;
        uint8_t* out_row = out_uint8 + (size_t)oc * outPx;
        const int32_t bias = biases_corrected[oc];
        const float M = M_per_channel[oc];
        for (int j = 0; j < outPx; ++j) {
            int32_t s = bias;
            const int8_t* act = activations_t + (size_t)j * kCh_padded;
            for (int k = 0; k < kCh_padded; ++k) {
                s += (int32_t)act[k] * (int32_t)w_row[k];
            }
            float q = roundf((float)s * M) + (float)output_zp;
            if (q < 0.0f) q = 0.0f;
            if (q > 255.0f) q = 255.0f;
            out_row[j] = (uint8_t)q;
        }
    }
}
#else
// Non-aarch64 (CI Linux x86): no SMMLA path. Stubs panic-free no-op
// fallback to satisfy the linker; bh_has_i8mm() returns 0 so these
// are never actually called.
void bh_int8_gemm_smmla(
    const int8_t* w, const int8_t* a, const int32_t* b,
    int32_t* out, int outCh, int kCh_padded, int outPx
) {
    bh_int8_gemm_sdot(w, a, b, out, outCh, kCh_padded, outPx);
}
void bh_int8_gemm_smmla_requant(
    const int8_t* w, const int8_t* a, const int32_t* b,
    const float* M, int32_t zp, uint8_t* out,
    int outCh, int kCh_padded, int outPx
) {
    bh_int8_gemm_sdot_requant(w, a, b, M, zp, out, outCh, kCh_padded, outPx);
}
#endif
