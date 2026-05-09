/// 3D Rotary Position Embedding for FlashHead DiT.
///
/// Ported from models/rope.py. Uses element-wise ops that fuse well inside MLX.compile.

@_implementationOnly import MLX
import Foundation

// MARK: - Frequency Precomputation

/// Precompute 1D rotary embedding cos/sin frequencies.
/// Returns (cos, sin) each of shape [end, dim//2].
internal func precomputeFreqsCis(dim: Int, end: Int = 1024, theta: Float = 10000.0) -> (MLXArray, MLXArray) {
    let half = dim / 2
    let exponents = MLXArray(Array(stride(from: 0, to: dim, by: 2).prefix(half)))
        .asType(.float32)
    let freqs = 1.0 / pow(MLXArray(theta), exponents / Float(dim))
    let t = MLXArray(Array(0..<end)).asType(.float32)
    let angles = outer(t, freqs)
    return (cos(angles), sin(angles))
}

/// Precompute 3D rotary frequencies by splitting head dim into F/H/W thirds.
/// Returns (cos, sin) each of shape [end, dim//2].
internal func precomputeFreqsCis3D(dim: Int, end: Int = 1024, theta: Float = 10000.0) -> (MLXArray, MLXArray) {
    let fDim = dim - 2 * (dim / 3)
    let hDim = dim / 3
    let wDim = dim / 3

    let (fCos, fSin) = precomputeFreqsCis(dim: fDim, end: end, theta: theta)
    let (hCos, hSin) = precomputeFreqsCis(dim: hDim, end: end, theta: theta)
    let (wCos, wSin) = precomputeFreqsCis(dim: wDim, end: end, theta: theta)

    return (
        concatenated([fCos, hCos, wCos], axis: 1),
        concatenated([fSin, hSin, wSin], axis: 1)
    )
}

// MARK: - Grid Frequency Building

/// Build position-specific cos/sin for a fixed spatial grid.
/// Returns (posCos, posSin) each of shape [seqLen, 1, halfC].
internal func buildGridFreqs(
    cosFreqs: MLXArray,
    sinFreqs: MLXArray,
    gridSizes: (Int, Int, Int),
    headDim: Int
) -> (MLXArray, MLXArray) {
    let (f, h, w) = gridSizes
    let halfC = headDim / 2
    let fHalf = (headDim - 2 * (headDim / 3)) / 2
    let hHalf = (headDim / 3) / 2
    let wHalf = (headDim / 3) / 2
    let seqLen = f * h * w

    // Slice precomputed frequencies for each dimension
    let fCos = cosFreqs[0..<f, 0..<fHalf]
    let fSin = sinFreqs[0..<f, 0..<fHalf]
    let hCos = cosFreqs[0..<h, fHalf..<(fHalf + hHalf)]
    let hSin = sinFreqs[0..<h, fHalf..<(fHalf + hHalf)]
    let wCos = cosFreqs[0..<w, (fHalf + hHalf)..<(fHalf + hHalf + wHalf)]
    let wSin = sinFreqs[0..<w, (fHalf + hHalf)..<(fHalf + hHalf + wHalf)]

    // Broadcast to full grid [f, h, w, dim]
    let fc = broadcast(fCos.reshaped(f, 1, 1, fHalf), to: [f, h, w, fHalf])
    let fs = broadcast(fSin.reshaped(f, 1, 1, fHalf), to: [f, h, w, fHalf])
    let hc = broadcast(hCos.reshaped(1, h, 1, hHalf), to: [f, h, w, hHalf])
    let hs = broadcast(hSin.reshaped(1, h, 1, hHalf), to: [f, h, w, hHalf])
    let wc = broadcast(wCos.reshaped(1, 1, w, wHalf), to: [f, h, w, wHalf])
    let ws = broadcast(wSin.reshaped(1, 1, w, wHalf), to: [f, h, w, wHalf])

    // Concatenate and reshape to [seqLen, 1, halfC]
    let posCos = concatenated([fc, hc, wc], axis: -1).reshaped(seqLen, 1, halfC)
    let posSin = concatenated([fs, hs, ws], axis: -1).reshaped(seqLen, 1, halfC)
    return (posCos, posSin)
}

// MARK: - RoPE Application

/// Apply 3D RoPE using interleaved complex-pair rotation.
///
/// Uses element-wise ops that fuse well inside MLX.compile (no fusion barriers).
///
/// - Parameters:
///   - x: Input tensor [B, L, N, C]
///   - cosFreqs: Pre-built grid freqs [L, 1, C//2] or raw freqs [M, C//2]
///   - sinFreqs: Same shape as cosFreqs
///   - gridSizes: (F, H, W) spatial grid dimensions
/// - Returns: Rotated tensor [B, L, N, C]
internal func ropeApply(
    _ x: MLXArray,
    cosFreqs: MLXArray,
    sinFreqs: MLXArray,
    gridSizes: (Int, Int, Int)
) -> MLXArray {
    let shape = x.shape
    let B = shape[0], L = shape[1], N = shape[2], C = shape[3]
    let halfC = C / 2

    // Get or build grid frequencies
    let posCos: MLXArray
    let posSin: MLXArray
    if cosFreqs.ndim == 3 {
        posCos = cosFreqs
        posSin = sinFreqs
    } else {
        (posCos, posSin) = buildGridFreqs(
            cosFreqs: cosFreqs, sinFreqs: sinFreqs,
            gridSizes: gridSizes, headDim: C
        )
    }

    // Reshape to separate interleaved real/imag pairs: [B, L, N, halfC, 2]
    let xPairs = x.reshaped(B, L, N, halfC, 2)

    // Broadcast cos/sin: [L, 1, halfC] -> [1, L, 1, halfC, 1]
    let cosB = posCos.reshaped(1, L, 1, halfC, 1)
    let sinB = posSin.reshaped(1, L, 1, halfC, 1)

    // Split into real/imag halves along last axis (single op, no indexing)
    let parts = split(xPairs, parts: 2, axis: -1)
    let xReal = parts[0]
    let xImag = parts[1]

    // Apply rotation: (x_real * cos - x_imag * sin, x_real * sin + x_imag * cos)
    let rotated = concatenated([
        xReal * cosB - xImag * sinB,
        xReal * sinB + xImag * cosB,
    ], axis: -1)

    return rotated.reshaped(B, L, N, C)
}
