// Wav2Vec2ANE — CoreML/ANE replacement for the MLX-Swift Wav2Vec2
// audio encoder. Loads `wav2vec2-base-960h.mlpackage` and runs the
// CNN feature extractor + 12-layer transformer encoder on the
// Neural Engine (~92% ANE / 8% CPU per ComputePlan), freeing the GPU
// entirely for DiT inference.
//
// Inference contract (matches the MLX path's `Wav2Vec2AudioModel`):
//   input  audio: MLXArray  shape [1, 21120] Float32 — one 33-frame
//                            chunk of 16 kHz audio (21120 = 33 frames
//                            × SAMPLE_RATE/TGT_FPS)
//   output hidden_states: [MLXArray] of length 13, each shape
//                            [1, seqLen, 768], where the CoreML model
//                            returns 65 raw CNN frames per chunk and
//                            this bridge interpolates to `seqLen`
//                            (typically 33) before returning.
//
// CoreML output keys are `hidden_state_0` through `hidden_state_12`
// (set in `scripts/convert_w2v2_coreml.py`'s wrapper module). Order
// matches HuggingFace `Wav2Vec2Model(output_hidden_states=True)`,
// which is what our MLX port mirrors — `[0]` is the post-projection
// pre-encoder state, `[12]` is the final layer-norm output.

import Accelerate
import CoreML
@_implementationOnly import MLX
import Foundation

internal final class Wav2Vec2ANE {
    private let coremlModel: MLModel
    /// Number of hidden state outputs the model exposes (embedding +
    /// 12 transformer layers). Matches the MLX path's return count.
    private static let hiddenStateCount = 13
    /// Static input shape baked into the .mlpackage. The ANE compiler
    /// picks the best kernel for one shape; reconverting with
    /// EnumeratedShapes is the path forward if we ever stream
    /// non-33-frame chunks.
    private static let expectedSampleCount = 21120
    /// Pre-allocated input buffer. Reused across every `predict`
    /// call — without this we'd churn ~84 KB per call (25× per
    /// second during speech), forcing the allocator to keep up
    /// with the audio stream and inflating transient peak memory.
    /// The buffer's contents are overwritten on each call; the
    /// MLDictionaryFeatureProvider holds it for the duration of
    /// the prediction, after which we own it again.
    private let inputBuffer: MLMultiArray
    /// Pre-allocated provider keyed on `inputBuffer`. Reused too —
    /// the provider just wraps the buffer in an MLFeatureValue.
    private let inputProvider: MLDictionaryFeatureProvider
    /// Pre-allocated receiver buffer for the float widening of
    /// each hidden-state. Sized to the largest single output
    /// (65×768 = 49,920 floats). Re-used per hidden state per
    /// chunk; was allocated 13× per call before.
    private let floatScratch: UnsafeMutableBufferPointer<Float>
    private static let maxHiddenFloats = 65 * 768

    internal init(path: String) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // CoreML picks ANE for the 92% it can route there

        let url = URL(fileURLWithPath: path)
        // See `ANECoreMLCache` — keep the compiled mlmodelc next to
        // the source so ANED's per-path shader cache stays warm.
        let compiledURL = try ANECoreMLCache.compiledMLModelC(forPackageAt: url)
        self.coremlModel = try MLModel(contentsOf: compiledURL, configuration: config)

        // Pool the input MLMultiArray + the wrapping feature
        // provider so per-chunk steady-state allocation in the
        // ANE path is essentially zero.
        guard let buf = try? MLMultiArray(
            shape: [1, NSNumber(value: Self.expectedSampleCount)],
            dataType: .float32
        ) else {
            throw PipelineError.coremlBufferAllocationFailed(shape: [1, Self.expectedSampleCount])
        }
        self.inputBuffer = buf
        self.inputProvider = try MLDictionaryFeatureProvider(
            dictionary: ["audio": MLFeatureValue(multiArray: buf)]
        )
        self.floatScratch = UnsafeMutableBufferPointer<Float>.allocate(
            capacity: Self.maxHiddenFloats
        )
    }

    deinit {
        floatScratch.deallocate()
    }

    /// Run the audio encoder and resample its hidden states to
    /// `seqLen`. Mirrors `Wav2Vec2AudioModel.callAsFunction(_:seqLen:)`.
    ///
    /// The CoreML graph emits 65 frames per 21120-sample chunk
    /// (Wav2Vec2's natural CNN downsampling); we interpolate to
    /// `seqLen` here so the rest of the pipeline (DiT audio_emb
    /// proj) sees the same shape it gets from the MLX path.
    internal func predict(audio: MLXArray, seqLen: Int) throws -> [MLXArray] {
        var input = audio.asType(.float32)
        if input.ndim == 1 {
            input = expandedDimensions(input, axis: 0)
        }
        MLX.eval(input)

        guard input.shape == [1, Self.expectedSampleCount] else {
            throw PipelineError.coremlBufferAllocationFailed(shape: input.shape)
        }

        // Copy the input MLX bytes into the pooled MLMultiArray.
        // Using a scoped `Data` view drops the reference the moment
        // the memcpy returns — the source MLXArray's backing slab
        // can be reclaimed before we wait on the prediction.
        let byteCount = Self.expectedSampleCount * 4
        do {
            let bytes = input.asData(access: .copy).data
            bytes.withUnsafeBytes { raw -> Void in
                memcpy(inputBuffer.dataPointer, raw.baseAddress!, byteCount)
            }
        }
        // Done with the MLX input; explicitly drop our reference so
        // MLX's allocator can reclaim the 21k-float slab while the
        // ANE prediction is in flight.
        input = MLXArray(0)

        let output: MLFeatureProvider
        do {
            output = try coremlModel.prediction(from: inputProvider)
        } catch {
            throw PipelineError.coremlPredictionFailed(underlying: error)
        }

        var hiddenStates: [MLXArray] = []
        hiddenStates.reserveCapacity(Self.hiddenStateCount)
        for i in 0..<Self.hiddenStateCount {
            let key = "hidden_state_\(i)"
            guard let arr = output.featureValue(for: key)?.multiArrayValue else {
                throw PipelineError.coremlOutputMissing(key: key)
            }
            let mlxArr = try mlxArrayFromMultiArray(arr)
            let resampled = linearInterpolateFeatures(mlxArr, targetLength: seqLen)
            hiddenStates.append(resampled)
        }
        return hiddenStates
    }

    /// Convert a CoreML `MLMultiArray` (Float16 or Float32) into an
    /// `MLXArray` of Float32. Uses vImage to widen fp16 in one
    /// vectorised pass — same trick the ANE decoder uses.
    private func mlxArrayFromMultiArray(_ arr: MLMultiArray) throws -> MLXArray {
        let shape = (0..<arr.shape.count).map { arr.shape[$0].intValue }
        let count = shape.reduce(1, *)
        var floats = [Float](repeating: 0, count: count)
        switch arr.dataType {
        case .float16:
            var src = vImage_Buffer(
                data: arr.dataPointer,
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * 2)
            floats.withUnsafeMutableBufferPointer { dst in
                var dstBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(dst.baseAddress!),
                    height: 1,
                    width: vImagePixelCount(count),
                    rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&src, &dstBuf, vImage_Flags(kvImageNoFlags))
            }
        case .float32:
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
            floats.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: ptr, count: count)
            }
        default:
            throw PipelineError.coremlUnsupportedDataType(rawValue: arr.dataType.rawValue)
        }
        return MLXArray(floats).reshaped(shape)
    }
}
