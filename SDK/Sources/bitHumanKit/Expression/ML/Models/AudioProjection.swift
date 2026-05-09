/// AudioProjModel — projects wav2vec2 features to DiT cross-attention context.
///
/// Ported from models/audio_proj.py.

@_implementationOnly import MLX
@_implementationOnly import MLXNN
import Foundation

/// Projects wav2vec2 audio embeddings to cross-attention context tokens.
///
/// Takes [B, 1, 5, 12, 768] first-frame audio and [B, N, 12, 12, 768] subsequent-frame audio,
/// outputs [B, video_length, 32, 1536] context tokens for DiT cross-attention.
internal class AudioProjModel: Module {
    let seqLen: Int
    let blocks: Int
    let channels: Int
    let inputDim: Int      // seqLen * blocks * channels = 46080
    let inputDimVf: Int    // seqLenVf * blocks * channels = 110592
    let intermediateDim: Int
    let contextTokens: Int
    let outputDim: Int

    @ModuleInfo var proj1: Linear
    @ModuleInfo var proj1Vf: Linear
    @ModuleInfo var proj2: Linear
    @ModuleInfo var proj3: Linear
    @ModuleInfo var norm: LayerNorm?

    internal init(
        seqLen: Int = 5,
        seqLenVf: Int = 12,
        blocks: Int = 12,
        channels: Int = 768,
        intermediateDim: Int = 512,
        outputDim: Int = 1536,
        contextTokens: Int = 32,
        normOutputAudio: Bool = true
    ) {
        self.seqLen = seqLen
        self.blocks = blocks
        self.channels = channels
        self.inputDim = seqLen * blocks * channels
        self.inputDimVf = seqLenVf * blocks * channels
        self.intermediateDim = intermediateDim
        self.contextTokens = contextTokens
        self.outputDim = outputDim

        self._proj1 = ModuleInfo(wrappedValue: Linear(inputDim, intermediateDim))
        self._proj1Vf = ModuleInfo(wrappedValue: Linear(inputDimVf, intermediateDim))
        self._proj2 = ModuleInfo(wrappedValue: Linear(intermediateDim, intermediateDim))
        self._proj3 = ModuleInfo(wrappedValue: Linear(intermediateDim, contextTokens * outputDim))
        self._norm = ModuleInfo(wrappedValue: normOutputAudio
            ? LayerNorm(dimensions: outputDim) : nil)
        super.init()
    }

    /// Forward pass.
    /// - Parameters:
    ///   - audioEmbeds: [B, 1, window, blocks, channels] first frame audio
    ///   - audioEmbedsVf: [B, N_latent, window_vf, blocks, channels] subsequent frames
    /// - Returns: [B, video_length, contextTokens, outputDim]
    internal func callAsFunction(
        _ audioEmbeds: MLXArray,
        audioEmbedsVf: MLXArray
    ) -> MLXArray {
        let B = audioEmbeds.dim(0)
        let nFirst = audioEmbeds.dim(1)
        let nVf = audioEmbedsVf.dim(1)
        let videoLength = nFirst + nVf

        // First frame: [B, 1, W, S, C] -> [B*1, W*S*C]
        var af = relu(proj1(audioEmbeds.reshaped(B * nFirst, -1)))
        // Subsequent frames: [B, N, W_vf, S, C] -> [B*N, W_vf*S*C]
        var avf = relu(proj1Vf(audioEmbedsVf.reshaped(B * nVf, -1)))

        // Reshape and concatenate
        af = af.reshaped(B, nFirst, intermediateDim)
        avf = avf.reshaped(B, nVf, intermediateDim)
        var combined = concatenated([af, avf], axis: 1)  // [B, videoLength, intermediateDim]

        // Second and third projections
        combined = combined.reshaped(B * videoLength, intermediateDim)
        combined = relu(proj2(combined))
        var tokens = proj3(combined).reshaped(B * videoLength, contextTokens, outputDim)

        // LayerNorm in float32
        if let norm = norm {
            tokens = norm(tokens.asType(.float32)).asType(tokens.dtype)
        }

        return tokens.reshaped(B, videoLength, contextTokens, outputDim)
    }
}
