import Foundation

/// Filesystem paths to the weights the streaming pipeline needs at
/// initialization. Fully internal — the public factory
/// `Bithuman.create(modelPath:)` unpacks a `.bit` container into a
/// `ModelPaths` before calling `PipelineOps.load`; external consumers
/// never interact with this type.
internal struct ModelPaths: Sendable {
    internal let ditWeights: String
    internal let wav2vecWeights: String
    /// Optional path to the ANE-resident Wav2Vec2 .mlpackage. When
    /// present, the streaming pipeline runs the audio encoder on the
    /// Neural Engine instead of MLX/Metal — frees the GPU for DiT.
    /// Falls back to the MLX path (`wav2vecWeights`) when nil.
    internal let wav2vecAne: String?
    internal let refLatent: String
    internal let aneDecoder: String
    internal let vaeEncoder: String
    internal let nSteps: Int

    internal init(
        ditWeights: String,
        wav2vecWeights: String,
        wav2vecAne: String? = nil,
        refLatent: String,
        aneDecoder: String,
        vaeEncoder: String,
        nSteps: Int
    ) {
        self.ditWeights = ditWeights
        self.wav2vecWeights = wav2vecWeights
        self.wav2vecAne = wav2vecAne
        self.refLatent = refLatent
        self.aneDecoder = aneDecoder
        self.vaeEncoder = vaeEncoder
        self.nSteps = nSteps
    }
}
