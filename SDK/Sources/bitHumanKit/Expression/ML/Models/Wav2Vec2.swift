/// Wav2Vec2 audio feature extractor for FlashHead.
///
/// Ported from wav2vec2-base-960h. Extracts multi-layer hidden state
/// features from raw 16kHz audio for lip-sync video generation.
///
/// Architecture: 7-layer CNN (320x downsample) -> feature projection (512->768)
/// -> 12-layer transformer encoder -> all 13 hidden states output.

@_implementationOnly import MLX
@_implementationOnly import MLXNN
@_implementationOnly import MLXFast
import Foundation

// MARK: - CNN Feature Extractor

/// Single conv layer: Conv1d + optional GroupNorm + GELU
internal class Wav2Vec2ConvLayer: Module {
    @ModuleInfo var conv: Conv1d
    @ModuleInfo public var layerNorm: GroupNorm?

    internal init(inCh: Int, outCh: Int, kernel: Int, stride: Int, useNorm: Bool = false) {
        self._conv = ModuleInfo(wrappedValue: Conv1d(
            inputChannels: inCh, outputChannels: outCh,
            kernelSize: kernel, stride: stride, bias: false))
        // GroupNorm(512 groups, 512 channels) = per-channel normalization = LayerNorm on last dim
        self._layerNorm = ModuleInfo(wrappedValue: useNorm
            ? GroupNorm(groupCount: outCh, dimensions: outCh) : nil)
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = conv(x)  // [B, L, C]
        if let norm = layerNorm {
            out = norm(out)
        }
        return gelu(out)
    }
}

/// 7-layer CNN feature extractor (320x downsample).
internal class Wav2Vec2FeatureExtractorModule: Module {
    @ModuleInfo var convLayers: [Wav2Vec2ConvLayer]

    internal override init() {
        let kernels = [10, 3, 3, 3, 3, 2, 2]
        let strides = [5, 2, 2, 2, 2, 2, 2]
        var layers: [Wav2Vec2ConvLayer] = []
        // Layer 0 has LayerNorm weights; layers 1-6 do not
        layers.append(Wav2Vec2ConvLayer(inCh: 1, outCh: 512, kernel: kernels[0],
                                         stride: strides[0], useNorm: true))
        for i in 1...6 {
            layers.append(Wav2Vec2ConvLayer(inCh: 512, outCh: 512, kernel: kernels[i],
                                             stride: strides[i], useNorm: false))
        }
        self._convLayers = ModuleInfo(wrappedValue: layers)
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [B, numSamples] -> [B, numSamples, 1]
        var out = expandedDimensions(x, axis: -1)
        for layer in convLayers {
            out = layer(out)
        }
        return out  // [B, L', 512]
    }
}

// MARK: - Feature Projection

internal class Wav2Vec2FeatureProjectionModule: Module {
    @ModuleInfo public var layerNorm: LayerNorm
    @ModuleInfo var projection: Linear

    internal override init() {
        self._layerNorm = ModuleInfo(wrappedValue: LayerNorm(dimensions: 512, eps: 1e-5))
        self._projection = ModuleInfo(wrappedValue: Linear(512, 768))
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray {
        projection(layerNorm(x))
    }
}

// MARK: - Positional Convolutional Embedding

/// Convolutional positional embedding with weight normalization.
/// Conv1d(768 → 768, kernel=128, groups=16) + same-padding + GELU.
internal class Wav2Vec2PositionalConvEmbed: Module {
    @ModuleInfo var conv: Conv1d

    internal override init() {
        // groups=16: 768/16 = 48 channels per group
        self._conv = ModuleInfo(wrappedValue: Conv1d(
            inputChannels: 768, outputChannels: 768, kernelSize: 128,
            stride: 1, padding: 0, groups: 16))
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Match PyTorch exactly:
        // PyTorch Conv1d has padding=64 (both sides), kernel=128
        // Output length = L + 2*64 - 128 + 1 = L + 1
        // Then Wav2Vec2SamePadLayer removes 1 from end → output = L
        let L = x.dim(1)

        // Pad with 64 on each side (matching PyTorch padding=64)
        let w0 = IntOrPair((0, 0))
        let w1 = IntOrPair((64, 64))
        let xPadded = padded(x, widths: [w0, w1, w0])

        var out = conv(xPadded)  // [B, L+1, 768]

        // Remove last element (Wav2Vec2SamePadLayer with num_pad_remove=1)
        if out.dim(1) > L {
            out = out[0..., ..<L, 0...]
        }

        return gelu(out)
    }
}

// MARK: - Transformer Encoder Layer

internal class Wav2Vec2EncoderLayer: Module {
    let numHeads: Int
    let headDim: Int

    @ModuleInfo public var layerNorm: LayerNorm
    @ModuleInfo var qProj: Linear
    @ModuleInfo var kProj: Linear
    @ModuleInfo var vProj: Linear
    @ModuleInfo var outProj: Linear
    @ModuleInfo var feedForwardIntermediateDense: Linear
    @ModuleInfo var feedForwardOutputDense: Linear
    @ModuleInfo var finalLayerNorm: LayerNorm

    internal init(dim: Int = 768, heads: Int = 12, ffn: Int = 3072) {
        self.numHeads = heads
        self.headDim = dim / heads
        self._layerNorm = ModuleInfo(wrappedValue: LayerNorm(dimensions: dim, eps: 1e-5))
        self._qProj = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._kProj = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._vProj = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._outProj = ModuleInfo(wrappedValue: Linear(dim, dim))
        self._feedForwardIntermediateDense = ModuleInfo(wrappedValue: Linear(dim, ffn))
        self._feedForwardOutputDense = ModuleInfo(wrappedValue: Linear(ffn, dim))
        self._finalLayerNorm = ModuleInfo(wrappedValue: LayerNorm(dimensions: dim, eps: 1e-5))
        super.init()
    }

    internal func callAsFunction(_ x: MLXArray) -> MLXArray {
        let B = x.dim(0), L = x.dim(1)
        let N = numHeads, D = headDim

        // Self-attention (POST-norm: attention first, then norm)
        let q = qProj(x).reshaped(B, L, N, D).transposed(0, 2, 1, 3)
        let k = kProj(x).reshaped(B, L, N, D).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(B, L, N, D).transposed(0, 2, 1, 3)

        let scale: Float = 1.0 / Float(D).squareRoot()
        let attn = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: nil)
        let attnOut = outProj(attn.transposed(0, 2, 1, 3).reshaped(B, L, N * D))

        // Residual + layer_norm (post-norm)
        var out = layerNorm(x + attnOut)

        // Feed-forward + residual + final_layer_norm (post-norm)
        let ffn = feedForwardOutputDense(gelu(feedForwardIntermediateDense(out)))
        out = finalLayerNorm(out + ffn)

        return out
    }
}

// MARK: - Full Encoder

internal class Wav2Vec2EncoderModule: Module {
    @ModuleInfo public var posConvEmbed: Wav2Vec2PositionalConvEmbed
    @ModuleInfo public var layers: [Wav2Vec2EncoderLayer]
    @ModuleInfo public var layerNorm: LayerNorm

    internal init(numLayers: Int = 12) {
        self._posConvEmbed = ModuleInfo(wrappedValue: Wav2Vec2PositionalConvEmbed())
        self._layers = ModuleInfo(wrappedValue: (0..<numLayers).map { _ in Wav2Vec2EncoderLayer() })
        self._layerNorm = ModuleInfo(wrappedValue: LayerNorm(dimensions: 768, eps: 1e-5))
        super.init()
    }

    /// Returns all 13 hidden states (projection + 12 layers).
    internal func callAsFunction(_ x: MLXArray) -> [MLXArray] {
        // Add positional embedding + layer norm before transformer
        let posEmbed = posConvEmbed(x)
        var current = layerNorm(x + posEmbed)

        var states = [x]  // hidden_state[0] = projection output (before pos embed)
        for layer in layers {
            current = layer(current)
            states.append(current)
        }
        // Apply final layer norm to last state
        states[states.count - 1] = layerNorm(current)
        return states
    }
}

// MARK: - Linear Interpolation

/// Resample features to target length (matches PyTorch F.interpolate align_corners=True).
internal func linearInterpolateFeatures(_ features: MLXArray, targetLength: Int) -> MLXArray {
    let L = features.dim(1)
    if L == targetLength { return features }

    // Build interpolation indices and weights
    var indices: [Int] = []
    var weights: [Float] = []
    for t in 0..<targetLength {
        let srcPos = targetLength == 1 ? Float(0) : Float(t) * Float(L - 1) / Float(targetLength - 1)
        let idx = min(Int(srcPos), L - 2)
        indices.append(idx)
        weights.append(srcPos - Float(idx))
    }

    // Gather left and right frames
    let idxArr = MLXArray(indices)
    let idxArr1 = MLXArray(indices.map { min($0 + 1, L - 1) })
    let wArr = MLXArray(weights).reshaped(1, targetLength, 1)

    let left = features.take(idxArr, axis: 1)
    let right = features.take(idxArr1, axis: 1)
    return left * (1 - wArr) + right * wArr
}

// MARK: - Full Model

internal class Wav2Vec2AudioModel: Module {
    @ModuleInfo public var featureExtractor: Wav2Vec2FeatureExtractorModule
    @ModuleInfo public var featureProjection: Wav2Vec2FeatureProjectionModule
    @ModuleInfo public var encoder: Wav2Vec2EncoderModule

    internal override init() {
        self._featureExtractor = ModuleInfo(wrappedValue: Wav2Vec2FeatureExtractorModule())
        self._featureProjection = ModuleInfo(wrappedValue: Wav2Vec2FeatureProjectionModule())
        self._encoder = ModuleInfo(wrappedValue: Wav2Vec2EncoderModule())
        super.init()
    }

    /// Extract audio features for FlashHead.
    /// - Parameters:
    ///   - inputValues: [B, numSamples] raw audio at 16kHz
    ///   - seqLen: target video frame count
    /// - Returns: all hidden states (13 arrays of [B, seqLen, 768])
    internal func callAsFunction(_ inputValues: MLXArray, seqLen: Int) -> [MLXArray] {
        var features = featureExtractor(inputValues)
        features = linearInterpolateFeatures(features, targetLength: seqLen)
        let projected = featureProjection(features)
        return encoder(projected)
    }
}

// MARK: - Weight Loading

internal func loadWav2Vec2Model(weightsPath: String, dtype: DType = .float16) throws -> Wav2Vec2AudioModel {
    let model = Wav2Vec2AudioModel()

    let weights = try loadSafetensorsStreaming(
        url: URL(fileURLWithPath: weightsPath),
        targetDtype: dtype
    )

    var remapped: [String: MLXArray] = [:]
    for (key, value) in weights {
        var k = key
        if k.hasPrefix("wav2vec2.") { k = String(k.dropFirst(9)) }

        // Feature extractor
        k = k.replacingOccurrences(of: "feature_extractor.conv_layers.", with: "featureExtractor.convLayers.")
        k = k.replacingOccurrences(of: ".layer_norm.", with: ".layerNorm.")

        // Feature projection
        k = k.replacingOccurrences(of: "feature_projection.", with: "featureProjection.")

        // Encoder
        k = k.replacingOccurrences(of: ".attention.q_proj.", with: ".qProj.")
        k = k.replacingOccurrences(of: ".attention.k_proj.", with: ".kProj.")
        k = k.replacingOccurrences(of: ".attention.v_proj.", with: ".vProj.")
        k = k.replacingOccurrences(of: ".attention.out_proj.", with: ".outProj.")
        k = k.replacingOccurrences(of: ".feed_forward.intermediate_dense.", with: ".feedForwardIntermediateDense.")
        k = k.replacingOccurrences(of: ".feed_forward.output_dense.", with: ".feedForwardOutputDense.")
        k = k.replacingOccurrences(of: ".final_layer_norm.", with: ".finalLayerNorm.")
        k = k.replacingOccurrences(of: "encoder.layer_norm.", with: "encoder.layerNorm.")

        // Positional conv embed: handle weight normalization
        k = k.replacingOccurrences(of: "encoder.pos_conv_embed.", with: "encoder.posConvEmbed.")

        // Skip lm_head, masked_spec_embed
        if k.contains("lm_head") || k.contains("masked_spec_embed") {
            continue
        }

        // Conv1d weights: PyTorch [outCh, inCh, kernel] -> MLX [outCh, kernel, inCh]
        var v = value
        if k.contains(".conv.weight") && k.contains("convLayers") && v.ndim == 3 {
            v = v.transposed(0, 2, 1)  // [outCh, inCh, K] -> [outCh, K, inCh]
        }

        remapped[k] = v
    }

    // Separate weight-norm params (bare vars) from module params
    var moduleParams: [String: MLXArray] = [:]
    var bareParams: [String: MLXArray] = [:]
    for (k, v) in remapped {
        if k.contains("weight_g") || k.contains("weight_v") || k.contains("parametrizations") {
            bareParams[k] = v
        } else {
            moduleParams[k] = v
        }
    }

    // Detect a pre-quantized .bhx and replace Linears with
    // QuantizedLinear BEFORE applying weights, so the int4-packed
    // .weight + .scales + .biases entries flow into the correct
    // module type. Doing this AFTER update would corrupt the plain
    // Linear's `weight` (uint32 in a fp16 slot) and the subsequent
    // forward pass would crash with a shape mismatch in addmm.
    let preQuantized = remapped.keys.contains { $0.hasSuffix(".scales") }
    if preQuantized {
        quantize(model: model, filter: { _, m -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
            // Match the Python prequant tool's guards
            // (`scripts/prequant_imx.py`) so Swift only quantizes
            // Linears the .bhx actually has scales/biases for.
            // Tiny projection heads stay fp16 on both sides.
            guard let lin = m as? Linear, !(lin is Quantized) else { return nil }
            let dt = lin.weight.dtype
            let isFloat = (dt == .float16 || dt == .bfloat16 || dt == .float32)
            guard isFloat,
                  lin.weight.shape.count >= 2,
                  lin.weight.shape[0] >= 64,
                  let lastDim = lin.weight.shape.last,
                  lastDim >= 64,
                  lastDim % 64 == 0
            else { return nil }
            return (groupSize: 64, bits: 4, mode: .affine)
        })
    }

    let nested = ModuleParameters.unflattened(moduleParams)
    try model.update(parameters: nested, verify: .none)

    // Apply weight normalization: use pre-computed weight if available,
    // otherwise compute from g and v
    let precomputedPath = weightsPath.replacingOccurrences(of: "wav2vec2.safetensors",
                                                            with: "pos_conv_weight.npy")
    // First try to load pre-computed weight (from Python)
    // The weight normalization computation is complex; using the pre-computed
    // weight from PyTorch ensures exact numerical match
    // Try loading pre-computed pos conv weight (avoids weight_norm computation)
    let posWeightPath = (weightsPath as NSString).deletingLastPathComponent + "/pos_conv_weight.npy"
    if FileManager.default.fileExists(atPath: posWeightPath) {
        let pyWeight = try MLX.loadArray(url: URL(fileURLWithPath: posWeightPath))
        // PyTorch [768, 48, 128] → MLX Conv1d [768, 128, 48]
        let mlxWeight = pyWeight.transposed(0, 2, 1)
        let convParams = ModuleParameters.unflattened(["encoder.posConvEmbed.conv.weight": mlxWeight])
        try model.update(parameters: convParams, verify: .none)
    } else {
        // Compute from weight_g and weight_v
        let wgKey = "encoder.posConvEmbed.conv.parametrizations.weight.original0"
        let wvKey = "encoder.posConvEmbed.conv.parametrizations.weight.original1"
        if let wg = bareParams[wgKey], let wv = bareParams[wvKey] {
            // weight_norm: w = g * (v / ||v||) where ||v|| is over all but dim 0
            let vNorm = sqrt(sum(wv * wv, axes: [1, 2], keepDims: true) + 1e-12)
            let normalizedW = wg * wv / vNorm
            let mlxWeight = normalizedW.transposed(0, 2, 1)
            let convParams = ModuleParameters.unflattened(["encoder.posConvEmbed.conv.weight": mlxWeight])
            try model.update(parameters: convParams, verify: .none)
        }
    }

    // Cast to target dtype, skipping uint32 (quantized weight tensors).
    model.apply { param in
        if param.dtype == .uint32 { return param }
        return param.dtype != dtype ? param.asType(dtype) : param
    }

    // GPU sync barrier
    MLX.eval(model.parameters())

    if !preQuantized {
        maybeQuantizeWav2Vec2(model)
    }

    var dtypes: [String: Int] = [:]
    for (_, arr) in model.parameters().flattened(prefix: "") {
        dtypes[String(describing: arr.dtype), default: 0] += 1
    }
    return model
}

/// Optional int4/int8 quantization of the transformer Linear layers in
/// Wav2Vec2 (q/k/v/out projections + FFN), driven by the
/// FH_QUANTIZE_W2V2 env var (values "int4", "int8", "4", or "8"). Uses
/// MLXNN.quantize with groupSize=64.
///
/// The 7 CNN feature-extractor convs at the front stay fp16 — Conv1D
/// isn't a quantizable layer in MLXNN. The transformer encoder (12
/// layers × 768 hidden) is the bulk of the parameter count anyway,
/// so quantizing only Linears still recovers most of the savings:
/// ~190 MB fp16 → ~50 MB int4.
private func maybeQuantizeWav2Vec2(_ model: Wav2Vec2AudioModel) {
    guard let mode = ProcessInfo.processInfo.environment["FH_QUANTIZE_W2V2"] else { return }
    let bits: Int
    switch mode {
    case "int4", "4": bits = 4
    case "int8", "8": bits = 8
    default: return
    }
    quantize(model: model, groupSize: 64, bits: bits)
    MLX.eval(model.parameters())
    // Same hygiene as the DiT path — released fp16 buffers stay in
    // MLX's allocator cache forever without this.
    MLX.Memory.clearCache()
}
