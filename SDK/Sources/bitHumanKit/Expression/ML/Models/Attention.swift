/// Self-Attention and Cross-Attention modules for FlashHead DiT.
///
/// Ported from models/attention.py.

@_implementationOnly import MLX
@_implementationOnly import MLXNN
@_implementationOnly import MLXFast
import Foundation

// MARK: - Self-Attention

/// Multi-head self-attention with 3D RoPE and QK-normalization.
internal class SelfAttention: Module {
    let dim: Int
    let numHeads: Int
    let headDim: Int

    @ModuleInfo var q: Linear
    @ModuleInfo var k: Linear
    @ModuleInfo var v: Linear
    @ModuleInfo var o: Linear
    @ModuleInfo var normQ: RMSNorm
    @ModuleInfo var normK: RMSNorm

    internal init(dim: Int, numHeads: Int, eps: Float = 1e-6) {
        self.dim = dim
        self.numHeads = numHeads
        self.headDim = dim / numHeads

        self._q = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._k = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._v = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._o = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._normQ = ModuleInfo(wrappedValue: RMSNorm(dimensions: dim, eps: eps))
        self._normK = ModuleInfo(wrappedValue: RMSNorm(dimensions: dim, eps: eps))
        super.init()
    }

    /// Forward pass.
    /// - Parameters:
    ///   - x: [B, L, C] input tokens
    ///   - cosFreqs: precomputed RoPE cos frequencies
    ///   - sinFreqs: precomputed RoPE sin frequencies
    ///   - gridSizes: (F, H, W) spatial grid
    /// - Returns: [B, L, C] output
    internal func callAsFunction(
        _ x: MLXArray,
        cosFreqs: MLXArray,
        sinFreqs: MLXArray,
        gridSizes: (Int, Int, Int)
    ) -> MLXArray {
        let B = x.dim(0), L = x.dim(1)
        let N = numHeads, D = headDim

        // QKV projections with QK-norm
        var qArr = normQ(q(x)).reshaped(B, L, N, D)
        var kArr = normK(k(x)).reshaped(B, L, N, D)
        let vArr = v(x)

        // Apply 3D RoPE
        qArr = ropeApply(qArr, cosFreqs: cosFreqs, sinFreqs: sinFreqs, gridSizes: gridSizes)
        kArr = ropeApply(kArr, cosFreqs: cosFreqs, sinFreqs: sinFreqs, gridSizes: gridSizes)

        // Reshape for attention: [B, N, L, D]
        let qH = qArr.reshaped(B, L, N, D).transposed(0, 2, 1, 3)
        let kH = kArr.reshaped(B, L, N, D).transposed(0, 2, 1, 3)
        let vH = vArr.reshaped(B, L, N, D).transposed(0, 2, 1, 3)

        let scale = 1.0 / Float(D).squareRoot()
        let out = MLXFast.scaledDotProductAttention(
            queries: qH, keys: kH, values: vH, scale: scale, mask: nil)

        // Reshape back: [B, L, C]
        let outReshaped = out.transposed(0, 2, 1, 3).reshaped(B, L, N * D)
        return o(outReshaped)
    }
}

// MARK: - Cross-Attention

/// Multi-head cross-attention with optional KV caching and image input branch.
internal class CrossAttention: Module {
    let dim: Int
    let numHeads: Int
    let headDim: Int
    let hasImageInput: Bool

    @ModuleInfo var q: Linear
    @ModuleInfo var k: Linear
    @ModuleInfo var v: Linear
    @ModuleInfo var o: Linear
    @ModuleInfo var normQ: RMSNorm
    @ModuleInfo var normK: RMSNorm

    // Optional image input branch
    @ModuleInfo var kImg: Linear?
    @ModuleInfo var vImg: Linear?
    @ModuleInfo var normKImg: RMSNorm?

    internal init(dim: Int, numHeads: Int, eps: Float = 1e-6, hasImageInput: Bool = false) {
        self.dim = dim
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self.hasImageInput = hasImageInput

        self._q = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._k = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._v = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._o = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._normQ = ModuleInfo(wrappedValue: RMSNorm(dimensions: dim, eps: eps))
        self._normK = ModuleInfo(wrappedValue: RMSNorm(dimensions: dim, eps: eps))

        if hasImageInput {
            self._kImg = ModuleInfo(wrappedValue: Linear(dim, dim))
            self._vImg = ModuleInfo(wrappedValue: Linear(dim, dim))
            self._normKImg = ModuleInfo(wrappedValue: RMSNorm(dimensions: dim, eps: eps))
        } else {
            self._kImg = ModuleInfo(wrappedValue: nil)
            self._vImg = ModuleInfo(wrappedValue: nil)
            self._normKImg = ModuleInfo(wrappedValue: nil)
        }
        super.init()
    }

    /// Forward pass with optional KV caching.
    /// - Parameters:
    ///   - x: [B, L, C] query tokens (video latents)
    ///   - y: [B, S, C] context tokens (audio, optionally image)
    ///   - kvCache: optional (k, v) from previous denoising step
    /// - Returns: (output [B, L, C], kvToCache: (k, v)? or nil)
    internal func callAsFunction(
        _ x: MLXArray,
        context y: MLXArray,
        kvCache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)?) {
        let B = x.dim(0)
        let N = numHeads, D = headDim

        let ctx: MLXArray
        let img: MLXArray?
        if hasImageInput {
            img = y[0..., ..<257]
            ctx = y[0..., 257...]
        } else {
            ctx = y
            img = nil
        }

        let qProj = normQ(q(x))
        let Lq = qProj.dim(1)
        let qH = qProj.reshaped(B, Lq, N, D).transposed(0, 2, 1, 3)

        let kH: MLXArray
        let vH: MLXArray
        let kvToCache: (MLXArray, MLXArray)?

        if let (cachedK, cachedV) = kvCache {
            kH = cachedK
            vH = cachedV
            kvToCache = nil
        } else {
            let kProj = normK(k(ctx))
            let vProj = v(ctx)
            let Lk = kProj.dim(1)
            kH = kProj.reshaped(B, Lk, N, D).transposed(0, 2, 1, 3)
            vH = vProj.reshaped(B, Lk, N, D).transposed(0, 2, 1, 3)
            kvToCache = (kH, vH)
        }

        let scale = 1.0 / Float(D).squareRoot()
        var out = MLXFast.scaledDotProductAttention(
            queries: qH, keys: kH, values: vH, scale: scale, mask: nil)
        out = out.transposed(0, 2, 1, 3).reshaped(B, Lq, N * D)

        // Optional image branch
        if hasImageInput, let img = img, let kImgLayer = kImg,
           let vImgLayer = vImg, let normKImgLayer = normKImg {
            let kImgProj = normKImgLayer(kImgLayer(img))
            let vImgProj = vImgLayer(img)
            let Limg = kImgProj.dim(1)
            let kImgH = kImgProj.reshaped(B, Limg, N, D).transposed(0, 2, 1, 3)
            let vImgH = vImgProj.reshaped(B, Limg, N, D).transposed(0, 2, 1, 3)
            var outImg = MLXFast.scaledDotProductAttention(
                queries: qH, keys: kImgH, values: vImgH, scale: scale, mask: nil)
            outImg = outImg.transposed(0, 2, 1, 3).reshaped(B, Lq, N * D)
            out = out + outImg
        }

        return (o(out), kvToCache)
    }
}
