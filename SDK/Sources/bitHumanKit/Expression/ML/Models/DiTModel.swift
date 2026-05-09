/// DiT model (WanModelAudioProject) for FlashHead.
///
/// Ported from models/dit.py. 1.3B parameter diffusion transformer with
/// audio conditioning via cross-attention.

@_implementationOnly import MLX
@_implementationOnly import MLXNN
@_implementationOnly import MLXFast
@_implementationOnly import MLXRandom
import Foundation

// MARK: - Sinusoidal Embedding

/// Sinusoidal timestep embedding.
/// - Parameters:
///   - dim: embedding dimension
///   - position: [N] timestep values
/// - Returns: [N, dim] embedding
internal func sinusoidalEmbedding1D(dim: Int, position: MLXArray) -> MLXArray {
    let half = dim / 2
    let exponents = MLXArray(Array(0..<half)).asType(.float32)
    let invFreq = pow(MLXArray(Float(10000.0)), -exponents / Float(half))
    let posFloat = position.asType(.float32)
    // [N] x [half] -> [N, half]
    let angles = expandedDimensions(posFloat, axis: 1) * expandedDimensions(invFreq, axis: 0)
    return concatenated([cos(angles), sin(angles)], axis: 1).asType(position.dtype)
}

// MARK: - Audio Embedding MLP

/// MLP used for audio/image embedding projection.
internal class EmbeddingMLP: Module {
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var linear1: Linear
    @ModuleInfo var linear2: Linear
    @ModuleInfo var norm2: LayerNorm

    internal init(inDim: Int, outDim: Int) {
        self._norm1 = ModuleInfo(wrappedValue: LayerNorm(dimensions: inDim))
        self._linear1 = ModuleInfo(wrappedValue: Linear(inDim, inDim))
        self._linear2 = ModuleInfo(wrappedValue: Linear(inDim, outDim))
        self._norm2 = ModuleInfo(wrappedValue: LayerNorm(dimensions: outDim))
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = norm1(x)
        out = gelu(linear1(out))
        out = linear2(out)
        out = norm2(out)
        return out
    }
}

// MARK: - DiT Audio Block

/// Single DiT block with self-attention, cross-attention, and FFN.
internal class DiTAudioBlock: Module {
    let dim: Int
    let numHeads: Int

    @ModuleInfo var selfAttn: SelfAttention
    @ModuleInfo var crossAttn: CrossAttention
    @ModuleInfo var norm1: LayerNorm
    @ModuleInfo var norm2: LayerNorm
    @ModuleInfo var norm3: LayerNorm
    @ModuleInfo var ffnLinear1: Linear
    @ModuleInfo var ffnLinear2: Linear

    /// AdaLN modulation parameter [1, 6, dim]
    var modulation: MLXArray

    internal init(hasImageInput: Bool, dim: Int, numHeads: Int, ffnDim: Int,
                eps: Float = 1e-6, i: Int = 0, numLayers: Int = 0) {
        self.dim = dim
        self.numHeads = numHeads

        self._selfAttn = ModuleInfo(wrappedValue: SelfAttention(dim: dim, numHeads: numHeads, eps: eps))
        self._crossAttn = ModuleInfo(wrappedValue: CrossAttention(dim: dim, numHeads: numHeads, eps: eps, hasImageInput: hasImageInput))
        self._norm1 = ModuleInfo(wrappedValue: LayerNorm(dimensions: dim, eps: eps, affine: false))
        self._norm2 = ModuleInfo(wrappedValue: LayerNorm(dimensions: dim, eps: eps, affine: false))
        self._norm3 = ModuleInfo(wrappedValue: LayerNorm(dimensions: dim, eps: eps))
        self._ffnLinear1 = ModuleInfo(wrappedValue: Linear(dim, ffnDim))
        self._ffnLinear2 = ModuleInfo(wrappedValue: Linear(ffnDim, dim))
        self.modulation = MLXRandom.normal([1, 6, dim]) / Float(dim).squareRoot()
        super.init()
    }

    /// Forward pass.
    /// - Returns: (output [B, L, C], kvToCache: (k, v)? or nil)
    internal func callAsFunction(
        _ x: MLXArray,
        context: MLXArray,
        tMod: MLXArray,
        cosFreqs: MLXArray,
        sinFreqs: MLXArray,
        gridSizes: (Int, Int, Int),
        kvCache: (MLXArray, MLXArray)? = nil
    ) -> (MLXArray, (MLXArray, MLXArray)?) {
        // 6 modulation parameters from AdaLN — use direct slicing
        let e = modulation.asType(tMod.dtype) + tMod  // [B, 6, C]
        // Split along dim 1 into 6 chunks of [B, 1, C]
        let eSlices = split(e, parts: 6, axis: 1)
        let e0 = eSlices[0]
        let e1 = eSlices[1]
        let e2 = eSlices[2]
        let e3 = eSlices[3]
        let e4 = eSlices[4]
        let e5 = eSlices[5]

        var xOut = x

        // Self-attention with AdaLN
        let saInput = norm1(xOut) * (1 + e1) + e0
        let saOut = selfAttn(saInput, cosFreqs: cosFreqs, sinFreqs: sinFreqs,
                             gridSizes: gridSizes)
        xOut = xOut + saOut * e2

        // Cross-attention (per-frame) with KV caching
        let fCtx = context.dim(1)
        let B = xOut.dim(0), L = xOut.dim(1), C = xOut.dim(2)
        let spatial = L / fCtx

        let xNormed = norm3(xOut)
        let xFrames = xNormed.reshaped(B, fCtx, spatial, C).reshaped(B * fCtx, spatial, C)
        let ctx = context.reshaped(B * fCtx, context.dim(2), C)

        let (crossOut, kvToCache) = crossAttn(xFrames, context: ctx, kvCache: kvCache)
        xOut = xOut + crossOut.reshaped(B, fCtx * spatial, C)

        // FFN with AdaLN
        let ffnInput = norm2(xOut) * (1 + e4) + e3
        let ffnOut = ffnLinear2(geluFastApproximate(ffnLinear1(ffnInput)))
        xOut = xOut + ffnOut * e5

        return (xOut, kvToCache)
    }
}

// MARK: - Output Head

/// Output head: unpatchify latent tokens back to latent space.
internal class Head: Module {
    let dim: Int
    let patchSize: (Int, Int, Int)

    @ModuleInfo var norm: LayerNorm
    @ModuleInfo var head: Linear
    var modulation: MLXArray

    internal init(dim: Int, outDim: Int, patchSize: (Int, Int, Int), eps: Float) {
        self.dim = dim
        self.patchSize = patchSize
        self._norm = ModuleInfo(wrappedValue: LayerNorm(dimensions: dim, eps: eps, affine: false))
        self._head = ModuleInfo(wrappedValue: Linear(dim, outDim * patchSize.0 * patchSize.1 * patchSize.2))
        self.modulation = MLXRandom.normal([1, 2, dim]) / Float(dim).squareRoot()
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray, t: MLXArray) -> MLXArray {
        let B = x.dim(0), L = x.dim(1), D = x.dim(2)
        let F = t.dim(0) / B

        let tBf = expandedDimensions(t.reshaped(B, F, D), axis: 2)  // [B, F, 1, D]
        let mod = expandedDimensions(modulation.asType(t.dtype), axis: 1)  // [1, 1, 2, D]
        let combined = mod + tBf  // [B, F, 2, D]
        let slices = split(combined, parts: 2, axis: 2)
        let shift = slices[0]  // [B, F, 1, D]
        let scale = slices[1]  // [B, F, 1, D]

        let spatial = L / F
        var xOut = x.reshaped(B, F, spatial, D)
        xOut = head(norm(xOut) * (1 + scale) + shift)
        return xOut.reshaped(B, F * spatial, -1)
    }
}

// MARK: - Full DiT Model

/// Full FlashHead DiT model with audio projection.
/// 1.3B parameters, 30 transformer layers, 1536 hidden dim, 12 heads.
internal class WanModelAudioProject: Module {
    let dim: Int
    let freqDim: Int
    let hasImageInput: Bool
    let patchSize: (Int, Int, Int)
    let outDim: Int
    let vaeStride: (Int, Int, Int)
    let audioWindow: Int
    let vaeScale: Int

    // Patch embedding
    var patchEmbeddingWeight: MLXArray
    var patchEmbeddingBias: MLXArray

    // Embeddings
    @ModuleInfo var textEmbeddingLinear1: Linear
    @ModuleInfo var textEmbeddingLinear2: Linear
    @ModuleInfo var timeEmbeddingLinear1: Linear
    @ModuleInfo var timeEmbeddingLinear2: Linear
    @ModuleInfo var timeProjectionLinear: Linear

    // Transformer blocks
    @ModuleInfo var blocks: [DiTAudioBlock]

    // Output head
    @ModuleInfo var ditHead: Head

    // Precomputed RoPE
    var cosFreqs: MLXArray
    var sinFreqs: MLXArray

    // Audio
    @ModuleInfo var audioEmb: EmbeddingMLP
    @ModuleInfo var audioProj: AudioProjModel

    internal init(
        dim: Int = 1536,
        inDim: Int = 256,
        ffnDim: Int = 8960,
        outDim: Int = 128,
        textDim: Int = 4096,
        freqDim: Int = 256,
        eps: Float = 1e-6,
        vaeStride: (Int, Int, Int) = (8, 32, 32),
        patchSize: (Int, Int, Int) = (1, 1, 1),
        numHeads: Int = 12,
        numLayers: Int = 30,
        hasImageInput: Bool = false
    ) {
        self.dim = dim
        self.freqDim = freqDim
        self.hasImageInput = hasImageInput
        self.patchSize = patchSize
        self.outDim = outDim
        self.vaeStride = vaeStride
        self.audioWindow = 5
        self.vaeScale = vaeStride.0

        // Patch embedding
        self.patchEmbeddingWeight = MLXArray.zeros([dim, inDim, patchSize.0, patchSize.1, patchSize.2])
        self.patchEmbeddingBias = MLXArray.zeros([dim])

        // Embeddings
        self._textEmbeddingLinear1 = ModuleInfo(wrappedValue: Linear(textDim, dim))
        self._textEmbeddingLinear2 = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._timeEmbeddingLinear1 = ModuleInfo(wrappedValue: Linear(freqDim, dim))
        self._timeEmbeddingLinear2 = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._timeProjectionLinear = ModuleInfo(wrappedValue: Linear(dim, dim * 6))

        // Blocks
        self._blocks = ModuleInfo(wrappedValue: (0..<numLayers).map { i in
            DiTAudioBlock(hasImageInput: hasImageInput, dim: dim, numHeads: numHeads,
                         ffnDim: ffnDim, eps: eps, i: i, numLayers: numLayers)
        })

        // Head
        self._ditHead = ModuleInfo(wrappedValue: Head(dim: dim, outDim: outDim,
                                                       patchSize: patchSize, eps: eps))

        // RoPE
        let headDim = dim / numHeads
        let (c, s) = precomputeFreqsCis3D(dim: headDim)
        self.cosFreqs = c
        self.sinFreqs = s

        // Audio
        self._audioEmb = ModuleInfo(wrappedValue: EmbeddingMLP(inDim: 768, outDim: dim))
        self._audioProj = ModuleInfo(wrappedValue: AudioProjModel(
            seqLen: audioWindow,
            seqLenVf: audioWindow + vaeScale - 1,
            intermediateDim: 512,
            outputDim: 1536,
            contextTokens: 32,
            normOutputAudio: true
        ))

        super.init()
    }

    // MARK: - Patchify / Unpatchify

    internal func patchify(_ x: MLXArray) -> (MLXArray, (Int, Int, Int)) {
        let B = x.dim(0), cIn = x.dim(1), F = x.dim(2), H = x.dim(3), W = x.dim(4)
        let (pf, ph, pw) = patchSize
        let fOut = F / pf, hOut = H / ph, wOut = W / pw

        let result: MLXArray
        if pf == 1 && ph == 1 && pw == 1 {
            let flat = x.reshaped(B, cIn, F * H * W).transposed(0, 2, 1)
            let weight = patchEmbeddingWeight.reshaped(dim, cIn)
            result = matmul(flat, weight.T) + patchEmbeddingBias
        } else {
            let patches = x.reshaped(B, cIn, fOut, pf, hOut, ph, wOut, pw)
                .transposed(0, 2, 4, 6, 1, 3, 5, 7)
                .reshaped(B, fOut * hOut * wOut, cIn * pf * ph * pw)
            let weight = patchEmbeddingWeight.reshaped(dim, -1)
            result = matmul(patches, weight.T) + patchEmbeddingBias
        }

        return (result, (fOut, hOut, wOut))
    }

    internal func unpatchify(_ x: MLXArray, gridSize: (Int, Int, Int)) -> MLXArray {
        let B = x.dim(0)
        let (F, H, W) = gridSize
        let (pf, ph, pw) = patchSize

        return x.reshaped(B, F, H, W, outDim, pf, ph, pw)
            .transposed(0, 4, 1, 5, 2, 6, 3, 7)
            .reshaped(B, outDim, F * pf, H * ph, W * pw)
    }

    // MARK: - Audio Context

    internal func prepareAudioContext(_ context: MLXArray) -> MLXArray {
        let firstFrameAudio = context[0..., ..<1]
        let latter = context[0..., 1...]
        let bA = latter.dim(0)
        let nTotal = latter.dim(1)
        let nLatent = nTotal / vaeScale
        let latterReshaped = latter.reshaped(bA, nLatent, vaeScale,
                                              latter.dim(2), latter.dim(3), latter.dim(4))

        let midIdx = audioWindow / 2  // = 2
        let firstOfGroup = latterReshaped[0..., 0..., ..<1, ..<(midIdx + 1)]
        let middleOfGroup = latterReshaped[0..., 0..., 1..<(vaeScale - 1), midIdx..<(midIdx + 1)]
        let lastOfGroup = latterReshaped[0..., 0..., (vaeScale - 1)..., midIdx...]

        let fog = firstOfGroup.reshaped(bA, nLatent, -1, firstOfGroup.dim(4), firstOfGroup.dim(5))
        let mog = middleOfGroup.reshaped(bA, nLatent, -1, middleOfGroup.dim(4), middleOfGroup.dim(5))
        let logArr = lastOfGroup.reshaped(bA, nLatent, -1, lastOfGroup.dim(4), lastOfGroup.dim(5))

        let latterProcessed = concatenated([fog, mog, logArr], axis: 2)
        return audioProj(firstFrameAudio, audioEmbedsVf: latterProcessed)
    }

    /// Fast forward without KV cache collection — for step N (reuses cached KV).
    /// Returns just the output, no KV cache.
    internal func forwardFast(
        _ x: MLXArray,
        timestep: MLXArray,
        contextProj: MLXArray,
        y: MLXArray,
        kvCache: [(MLXArray, MLXArray)]
    ) -> MLXArray {
        var xCat = concatenated([x, y], axis: 1)
        let gridSizes: (Int, Int, Int)
        (xCat, gridSizes) = patchify(xCat)

        let tEmb = sinusoidalEmbedding1D(dim: freqDim, position: timestep.asType(xCat.dtype))
        var t = silu(timeEmbeddingLinear1(tEmb))
        t = timeEmbeddingLinear2(t)
        var tMod = silu(t)
        tMod = timeProjectionLinear(tMod)
        tMod = tMod.reshaped(-1, 6, dim)

        let ctxProj = contextProj.asType(xCat.dtype)
        let headDim = dim / blocks[0].numHeads
        let (gridCos, gridSin) = buildGridFreqs(
            cosFreqs: cosFreqs, sinFreqs: sinFreqs,
            gridSizes: gridSizes, headDim: headDim)

        for i in 0..<blocks.count {
            let (blockOut, _) = blocks[i](
                xCat, context: ctxProj, tMod: tMod,
                cosFreqs: gridCos, sinFreqs: gridSin,
                gridSizes: gridSizes, kvCache: kvCache[i])
            xCat = blockOut
        }

        xCat = ditHead(xCat, t: t)
        return unpatchify(xCat, gridSize: gridSizes)
    }

    // MARK: - Forward

    internal func forwardPrecomputed(
        _ x: MLXArray,
        timestep: MLXArray,
        contextProj: MLXArray,
        y: MLXArray,
        kvCache: [(MLXArray, MLXArray)]? = nil
    ) -> (MLXArray, [(MLXArray, MLXArray)]?) {
        // Concatenate noise and reference
        var xCat = concatenated([x, y], axis: 1)  // [B, 2*outDim, F, H, W]

        // Patchify
        let gridSizes: (Int, Int, Int)
        (xCat, gridSizes) = patchify(xCat)

        // Timestep embedding
        let tEmb = sinusoidalEmbedding1D(dim: freqDim, position: timestep.asType(xCat.dtype))
        var t = silu(timeEmbeddingLinear1(tEmb))
        t = timeEmbeddingLinear2(t)

        var tMod = silu(t)
        tMod = timeProjectionLinear(tMod)
        tMod = tMod.reshaped(-1, 6, dim)

        let ctxProj = contextProj.asType(xCat.dtype)

        // Grid-specific RoPE
        let headDim = dim / blocks[0].numHeads
        let (gridCos, gridSin) = buildGridFreqs(
            cosFreqs: cosFreqs, sinFreqs: sinFreqs,
            gridSizes: gridSizes, headDim: headDim)

        // Run through DiT blocks
        var newKvCache: [(MLXArray, MLXArray)] = []
        for i in 0..<blocks.count {
            let layerCache = kvCache?[i]
            let (blockOut, kvToCache) = blocks[i](
                xCat, context: ctxProj, tMod: tMod,
                cosFreqs: gridCos, sinFreqs: gridSin,
                gridSizes: gridSizes, kvCache: layerCache)
            xCat = blockOut
            if let kv = kvToCache {
                newKvCache.append(kv)
            }
        }

        // Output head
        xCat = ditHead(xCat, t: t)

        // Unpatchify
        let output = unpatchify(xCat, gridSize: gridSizes)

        return (output, newKvCache.isEmpty ? nil : newKvCache)
    }
}
