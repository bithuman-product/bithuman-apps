/// CoreML ANE decoder bridge for VAE decoding.
///
/// Loads the pre-converted .mlpackage and runs inference on the Neural Engine.

import Accelerate
import CoreML
@_implementationOnly import MLX
import Foundation

/// Bridge between MLX latent arrays and CoreML ANE VAE decoder.
internal final class ANEDecoder {
    let coremlModel: MLModel
    let resolution: Int

    /// Load a CoreML ANE decoder model.
    /// - Parameter path: path to .mlpackage directory
    internal init(path: String) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // Enable ANE dispatch

        let url = URL(fileURLWithPath: path)

        // Compile .mlpackage → .mlmodelc, persisting the result
        // alongside the source so subsequent launches reuse it
        // instead of paying the multi-second compile every time.
        // ANE-cache reuse depends on the .mlmodelc file path
        // staying stable across launches; without persistent
        // caching `MLModel.compileModel` returns a fresh path each
        // call, ANED treats it as a new model, and the full
        // shader compile (~2 min on cold cache) re-runs.
        let compiledURL = try ANECoreMLCache.compiledMLModelC(forPackageAt: url)

        self.coremlModel = try MLModel(contentsOf: compiledURL, configuration: config)

        // Determine resolution from path name.
        if path.contains("384") {
            self.resolution = 384
        } else if path.contains("448") {
            self.resolution = 448
        } else {
            self.resolution = 512
        }
    }

    /// Decode a latent to video frames.
    ///
    /// - Parameter latent: MLXArray `[128, 5, H, W]` or `[1, 128, 5, H, W]`.
    /// - Returns: Float32 MLXArray `[1, 3, 33, resolution, resolution]` in `[-1, 1]`.
    /// - Throws: ``PipelineError/coremlBufferAllocationFailed``,
    ///   ``PipelineError/coremlPredictionFailed(underlying:)``,
    ///   ``PipelineError/coremlOutputMissing(key:)``,
    ///   ``PipelineError/coremlUnsupportedDataType(rawValue:)``.
    ///
    /// Every error path here is recoverable — the caller (typically
    /// `PipelineOps.processChunk`) can discard the failed chunk and
    /// continue with the next one rather than crash the session.
    internal func decode(_ latent: MLXArray) throws -> MLXArray {
        // Ensure [1, 128, 5, H, W]. Cast to float16 to match the ANE model spec.
        var latentInput = latent.asType(.float16)
        if latentInput.ndim == 4 {
            latentInput = expandedDimensions(latentInput, axis: 0)
        }
        MLX.eval(latentInput)

        let shape = latentInput.shape
        let nsShape = shape.map { NSNumber(value: $0) }

        guard let multiArray = try? MLMultiArray(shape: nsShape, dataType: .float16) else {
            throw PipelineError.coremlBufferAllocationFailed(shape: shape)
        }

        // Copy MLX float16 bytes directly into the CoreML buffer.
        let mlxBytes = latentInput.asData(access: .copy).data
        let totalElements = shape.reduce(1, *)
        let byteCount = totalElements * 2
        guard mlxBytes.count >= byteCount else {
            throw PipelineError.coremlBufferAllocationFailed(shape: shape)
        }
        mlxBytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            memcpy(multiArray.dataPointer, raw.baseAddress!, byteCount)
        }

        // Run CoreML prediction.
        let input: MLFeatureProvider
        do {
            input = try MLDictionaryFeatureProvider(
                dictionary: ["latent": MLFeatureValue(multiArray: multiArray)])
        } catch {
            throw PipelineError.coremlPredictionFailed(underlying: error)
        }
        let output: MLFeatureProvider
        do {
            output = try coremlModel.prediction(from: input)
        } catch {
            throw PipelineError.coremlPredictionFailed(underlying: error)
        }

        guard let videoArray = output.featureValue(for: "video")?.multiArrayValue else {
            throw PipelineError.coremlOutputMissing(key: "video")
        }

        // Read ANE float16 output, widen to float32 for MLX.
        let outputShape = (0..<videoArray.shape.count).map { videoArray.shape[$0].intValue }
        let count = outputShape.reduce(1, *)

        var floats = [Float](repeating: 0, count: count)
        switch videoArray.dataType {
        case .float16:
            // vImage does the fp16→fp32 widening in one accelerated call.
            var src = vImage_Buffer(
                data: videoArray.dataPointer,
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
            let ptr = videoArray.dataPointer.bindMemory(to: Float.self, capacity: count)
            floats.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: ptr, count: count)
            }
        default:
            throw PipelineError.coremlUnsupportedDataType(rawValue: videoArray.dataType.rawValue)
        }
        return MLXArray(floats).reshaped(outputShape)
    }
}
