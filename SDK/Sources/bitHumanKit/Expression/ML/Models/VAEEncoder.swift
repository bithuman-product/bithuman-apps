/// LTX Video VAE Encoder — pure MLX Swift port of `flashhead_mlx/models/vae.py`.
///
/// Encodes a single reference image (tiled temporally to 33 frames) into the
/// `[128, F_lat, H_lat, W_lat]` latent consumed by the DiT. Runs once per
/// drag-drop, so correctness (cos_sim vs Python) is the priority — not speed.
///
/// Layer graph (from `LTXVideoEncoder`):
/// ```
///   input [1, 3, 33, H, W] in [-1, 1]
///     → patchify(4, 1)                       [1, 48, 33, H/4, W/4]
///     → NCDHW → NDHWC                        [1, 33, H/4, W/4, 48]
///     → conv_in (3×3×3, causal)              [1, 33, H/4, W/4, 128]
///     → down_blocks[0..9]                    [1, F_lat, H_lat, W_lat, 512]
///     → PixelNorm(channel dim)
///     → silu
///     → conv_out (→ 129)                     [1, F_lat, H_lat, W_lat, 129]
///     → NDHWC → NCDHW                        [1, 129, F_lat, H_lat, W_lat]
///     → mean = x[:, :128]  (mode decoding)
///     → (mean − mean_of_means) / std_of_means
///     → drop batch dim                       [128, F_lat, H_lat, W_lat]
/// ```
///
/// Down-block sequence (Python order preserved):
///   0: UNetMidBlock3D(128, 4 res)
///   1: CausalConv3d(128→128, stride 2)        (compress_all)
///   2: ResnetBlock3D(128→256)                 (res_x_y)
///   3: UNetMidBlock3D(256, 3 res)
///   4: CausalConv3d(256→256, stride 2)
///   5: ResnetBlock3D(256→512)
///   6: UNetMidBlock3D(512, 3 res)
///   7: CausalConv3d(512→512, stride 2)
///   8: UNetMidBlock3D(512, 3 res)
///   9: UNetMidBlock3D(512, 4 res)

import Foundation
@_implementationOnly import MLX
@_implementationOnly import MLXNN

// MARK: - Stateless PixelNorm

/// Channel-wise RMS normalization with no learnable params. Used inline from
/// ResnetBlock3D and the encoder head — no @ModuleInfo slot is needed.
internal enum PixelNormOp {
    internal static let eps: Float = 1e-8
    internal static func apply(_ x: MLXArray, axis: Int = -1) -> MLXArray {
        let dtype = x.dtype
        let xf = x.asType(.float32)
        let sq = xf * xf
        let mean = sq.mean(axis: axis, keepDims: true)
        let norm = MLX.rsqrt(mean + eps)
        return (xf * norm).asType(dtype)
    }
}

// MARK: - CausalConv3d

/// Conv3d with temporal replicate padding. Input/output are NDHWC.
internal class CausalConv3d: Module {
    @ModuleInfo public var conv: Conv3d
    let timeKernelSize: Int

    internal init(
        inChannels: Int,
        outChannels: Int,
        kernelSize: Int = 3,
        stride: Int = 1,
        bias: Bool = true
    ) {
        self.timeKernelSize = kernelSize
        let sp = kernelSize / 2
        self._conv.wrappedValue = Conv3d(
            inputChannels: inChannels,
            outputChannels: outChannels,
            kernelSize: IntOrTriple(kernelSize),
            stride: IntOrTriple(stride),
            padding: IntOrTriple((0, sp, sp)),
            bias: bias
        )
        super.init()
    }

    /// Run the conv with the specified temporal padding mode.
    internal func call(_ x: MLXArray, causal: Bool) -> MLXArray {
        guard timeKernelSize > 1 else { return conv(x) }

        let padded: MLXArray
        if causal {
            let k = timeKernelSize - 1
            let first = x[0..., ..<1]
            padded = MLX.concatenated(
                [MLX.concatenated(Array(repeating: first, count: k), axis: 1), x],
                axis: 1)
        } else {
            let p = (timeKernelSize - 1) / 2
            if p > 0 {
                let first = x[0..., ..<1]
                let last = x[0..., (x.dim(1) - 1)...]
                let firstTile = MLX.concatenated(Array(repeating: first, count: p), axis: 1)
                let lastTile = MLX.concatenated(Array(repeating: last, count: p), axis: 1)
                padded = MLX.concatenated([firstTile, x, lastTile], axis: 1)
            } else {
                padded = x
            }
        }
        return conv(padded)
    }
}

// MARK: - LayerNormND

/// LayerNorm over the last (channel) dim of an NDHWC tensor.
internal class LayerNormND: Module, UnaryLayer {
    @ModuleInfo public var norm: LayerNorm

    internal init(dim: Int, eps: Float = 1e-6) {
        self._norm.wrappedValue = LayerNorm(dimensions: dim, eps: eps)
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray { norm(x) }
}

// MARK: - ResnetBlock3D

internal class ResnetBlock3D: Module {
    @ModuleInfo public var conv1: CausalConv3d
    @ModuleInfo public var conv2: CausalConv3d
    @ModuleInfo public var norm3: LayerNormND?
    @ModuleInfo(key: "conv_shortcut") public var convShortcut: Conv3d?

    internal init(inChannels: Int, outChannels: Int? = nil, eps: Float = 1e-6) {
        let out = outChannels ?? inChannels
        self._conv1.wrappedValue = CausalConv3d(
            inChannels: inChannels, outChannels: out, kernelSize: 3)
        self._conv2.wrappedValue = CausalConv3d(
            inChannels: out, outChannels: out, kernelSize: 3)

        if inChannels != out {
            self._norm3.wrappedValue = LayerNormND(dim: inChannels, eps: eps)
            self._convShortcut.wrappedValue = Conv3d(
                inputChannels: inChannels,
                outputChannels: out,
                kernelSize: IntOrTriple(1),
                stride: IntOrTriple(1),
                padding: IntOrTriple(0),
                bias: true
            )
        } else {
            self._norm3.wrappedValue = nil
            self._convShortcut.wrappedValue = nil
        }
        super.init()
    }

    internal func call(_ x: MLXArray, causal: Bool) -> MLXArray {
        var h = PixelNormOp.apply(x)
        h = silu(h)
        h = conv1.call(h, causal: causal)

        h = PixelNormOp.apply(h)
        h = silu(h)
        h = conv2.call(h, causal: causal)

        var residual = x
        if let norm3, let convShortcut {
            residual = norm3(residual)
            residual = convShortcut(residual)
        }
        return residual + h
    }
}

// MARK: - UNetMidBlock3D

internal class UNetMidBlock3D: Module {
    @ModuleInfo(key: "res_blocks") public var resBlocks: [ResnetBlock3D]

    internal init(channels: Int, numLayers: Int) {
        self._resBlocks.wrappedValue = (0..<numLayers).map { _ in
            ResnetBlock3D(inChannels: channels, outChannels: channels)
        }
        super.init()
    }

    internal func call(_ x: MLXArray, causal: Bool) -> MLXArray {
        var h = x
        for block in resBlocks {
            h = block.call(h, causal: causal)
        }
        return h
    }
}

// MARK: - Patchify

/// Python `patchify` equivalent. Input NCDHW; output NCDHW with channels
/// expanded by `patch_t × patch_hw × patch_hw`.
func patchify(_ x: MLXArray, patchHW: Int, patchT: Int) -> MLXArray {
    guard patchHW != 1 || patchT != 1 else { return x }
    let b = x.dim(0), c = x.dim(1), f = x.dim(2), h = x.dim(3), w = x.dim(4)
    var y = x.reshaped(b, c, f / patchT, patchT, h / patchHW, patchHW, w / patchHW, patchHW)
    y = y.transposed(0, 1, 3, 7, 5, 2, 4, 6)
    y = y.reshaped(b, c * patchT * patchHW * patchHW, f / patchT, h / patchHW, w / patchHW)
    return y
}

// MARK: - LTXVideoEncoder

/// Top-level encoder. Uses 10 individually-named down-block fields so that
/// the weight loader can remap `down_blocks.N.*` unambiguously (MLXNN
/// module arrays must be homogeneous).
internal class LTXVideoEncoder: Module {
    // Statistics (bare params — loaded explicitly, not via @ModuleInfo)
    internal var meanOfMeans: MLXArray
    internal var stdOfMeans: MLXArray

    @ModuleInfo(key: "conv_in")  public var convIn:  CausalConv3d
    @ModuleInfo(key: "conv_out") public var convOut: CausalConv3d

    // down_blocks.0..9 — heterogeneous sequence flattened into named fields.
    @ModuleInfo(key: "down_blocks_0") public var downBlock0: UNetMidBlock3D
    @ModuleInfo(key: "down_blocks_1") public var downBlock1: CausalConv3d
    @ModuleInfo(key: "down_blocks_2") public var downBlock2: ResnetBlock3D
    @ModuleInfo(key: "down_blocks_3") public var downBlock3: UNetMidBlock3D
    @ModuleInfo(key: "down_blocks_4") public var downBlock4: CausalConv3d
    @ModuleInfo(key: "down_blocks_5") public var downBlock5: ResnetBlock3D
    @ModuleInfo(key: "down_blocks_6") public var downBlock6: UNetMidBlock3D
    @ModuleInfo(key: "down_blocks_7") public var downBlock7: CausalConv3d
    @ModuleInfo(key: "down_blocks_8") public var downBlock8: UNetMidBlock3D
    @ModuleInfo(key: "down_blocks_9") public var downBlock9: UNetMidBlock3D

    internal let patchSize = 4
    internal let latentChannels = 128

    internal override init() {
        self.meanOfMeans = MLXArray.zeros([128])
        self.stdOfMeans  = MLXArray.ones([128])

        self._convIn.wrappedValue  = CausalConv3d(
            inChannels: 3 * 4 * 4, outChannels: 128, kernelSize: 3)
        self._convOut.wrappedValue = CausalConv3d(
            inChannels: 512, outChannels: 129, kernelSize: 3)

        self._downBlock0.wrappedValue = UNetMidBlock3D(channels: 128, numLayers: 4)
        self._downBlock1.wrappedValue = CausalConv3d(
            inChannels: 128, outChannels: 128, kernelSize: 3, stride: 2)
        self._downBlock2.wrappedValue = ResnetBlock3D(inChannels: 128, outChannels: 256)
        self._downBlock3.wrappedValue = UNetMidBlock3D(channels: 256, numLayers: 3)
        self._downBlock4.wrappedValue = CausalConv3d(
            inChannels: 256, outChannels: 256, kernelSize: 3, stride: 2)
        self._downBlock5.wrappedValue = ResnetBlock3D(inChannels: 256, outChannels: 512)
        self._downBlock6.wrappedValue = UNetMidBlock3D(channels: 512, numLayers: 3)
        self._downBlock7.wrappedValue = CausalConv3d(
            inChannels: 512, outChannels: 512, kernelSize: 3, stride: 2)
        self._downBlock8.wrappedValue = UNetMidBlock3D(channels: 512, numLayers: 3)
        self._downBlock9.wrappedValue = UNetMidBlock3D(channels: 512, numLayers: 4)

        super.init()
    }

    /// Encode a reference video `[B, 3, F, H, W]` in [-1, 1] to the DiT
    /// latent `[128, F_lat, H_lat, W_lat]` (batch dim squeezed out).
    internal func callAsFunction(_ video: MLXArray) -> MLXArray {
        var x = (video.ndim == 4) ? video.expandedDimensions(axis: 0) : video

        // Patchify then NCDHW → NDHWC
        x = patchify(x, patchHW: patchSize, patchT: 1)
        x = x.transposed(0, 2, 3, 4, 1)

        // Encoder trunk (all causal)
        x = convIn.call(x, causal: true)
        x = downBlock0.call(x, causal: true)
        x = downBlock1.call(x, causal: true)
        x = downBlock2.call(x, causal: true)
        x = downBlock3.call(x, causal: true)
        x = downBlock4.call(x, causal: true)
        x = downBlock5.call(x, causal: true)
        x = downBlock6.call(x, causal: true)
        x = downBlock7.call(x, causal: true)
        x = downBlock8.call(x, causal: true)
        x = downBlock9.call(x, causal: true)

        // Head
        x = PixelNormOp.apply(x)
        x = silu(x)
        x = convOut.call(x, causal: true)

        // NDHWC → NCDHW, take mean channels, normalize, squeeze batch.
        x = x.transposed(0, 4, 1, 2, 3)
        let mean = x[0..., ..<128]
        let std = stdOfMeans.reshaped(1, -1, 1, 1, 1)
        let meanStat = meanOfMeans.reshaped(1, -1, 1, 1, 1)
        return ((mean - meanStat) / std)[0]
    }
}
