import Foundation
import CoreGraphics
@_implementationOnly import MLX

/// Errors thrown by `PipelineOps` operations. Narrow set — just the
/// cases a caller might want to distinguish when deciding whether
/// to retry, fall back, or surface a user-facing message.
public enum PipelineError: Error, Sendable {
    /// `PipelineOps.swapIdentity` called before `load` set up the
    /// StreamingPipeline + ANEDecoder on the box.
    case pipelineNotReady
    /// Identity swap requires the VAE encoder, which needs a weights
    /// path recorded by `load`. Neither was set.
    case vaeEncoderMissingWeightsPath
    /// VAE encoder weights could not be loaded from disk.
    case vaeEncoderLoadFailed(underlying: Error)
    /// Image decode / face-crop / VAE encode raised an error during
    /// identity swap.
    case preprocessFailed(underlying: Error)

    // MARK: - ANE decoder failures
    //
    // These are recoverable — a caller that catches any of them can
    // discard the in-flight chunk and continue with the next one.
    // Previously these paths were `fatalError()` which crashed the
    // whole session on any CoreML hiccup.

    /// CoreML MLMultiArray allocation failed (typically OOM) or the
    /// MLX-to-CoreML byte-count conversion didn't match.
    case coremlBufferAllocationFailed(shape: [Int])
    /// `MLModel.prediction(from:)` threw — often transient ANE busy
    /// or a memory pressure condition.
    case coremlPredictionFailed(underlying: Error)
    /// The CoreML output dictionary didn't contain the expected key
    /// (typically `"video"`). Weight file mismatch with the runtime.
    case coremlOutputMissing(key: String)
    /// The CoreML output MLMultiArray came back in a dtype the SDK
    /// doesn't know how to widen to Float32.
    case coremlUnsupportedDataType(rawValue: Int)
}

/// Error surfaced by ``Bithuman/create(modelPath:identity:quality:chunkProcessor:)``
/// and ``Bithuman/createRuntime(modelPath:identity:quality:)``.
public enum BithumanCreateError: Error, CustomStringConvertible, LocalizedError, Sendable {
    /// `PipelineOps.load` returned a non-nil error message. The
    /// message is preserved verbatim for diagnostics — downstream
    /// logging can emit it directly.
    case loadFailed(message: String)
    /// The `.imx` container could not be opened, did not carry a
    /// manifest, or was missing a required weight entry. (Wrong
    /// `model_type` is now ``wrongModelType(found:)`` — kept distinct
    /// so the unified `createRuntime` factory can route a "this is the
    /// other runtime" error to a different UX than "this file is
    /// corrupt".)
    case invalidModelFile(message: String)
    /// The host doesn't meet the minimum-spec guarantee (macOS on
    /// Apple M3+, or iPad with M-series Apple Silicon). Carries a
    /// one-line human-readable reason so callers can surface it.
    case unsupportedHardware(reason: String)
    /// The container's `manifest.model_type` is not a value this
    /// build knows how to instantiate. `found` carries the offending
    /// string verbatim, or `nil` when the manifest had no `model_type`
    /// key at all.
    ///
    /// Thrown by ``Bithuman/createRuntime(modelPath:identity:quality:)``
    /// for any `model_type` other than `"expression"` or `"essence"`,
    /// and by ``EssenceRuntime/create(modelPath:)`` when the file
    /// carries a non-`"essence"` `model_type` (so the per-runtime
    /// factory and the unified factory surface the same typed error
    /// for the same situation).
    case wrongModelType(found: String?)

    /// Billing authentication failed before the runtime could start.
    /// Thrown by ``EssenceRuntime/create(modelPath:apiSecret:)`` when
    /// the up-front heartbeat (which validates the api-secret + balance
    /// + suspension state) returns a fatal billing error. Carries the
    /// underlying ``BithumanAuthError`` so consumers can route 402
    /// (insufficient balance) and 403 (account suspended) to distinct
    /// UX without re-parsing strings.
    case authenticationFailed(underlying: BithumanAuthError)

    public var description: String {
        switch self {
        case .loadFailed(let message):           return "Bithuman.create: load failed — \(message)"
        case .invalidModelFile(let message):     return "Bithuman.create: invalid model file — \(message)"
        case .unsupportedHardware(let reason):   return "Bithuman.create: unsupported hardware — \(reason)"
        case .wrongModelType(let found):
            let f = found.map { "\"\($0)\"" } ?? "<missing>"
            return "Bithuman.create: wrong model_type=\(f) — expected \"expression\" or \"essence\""
        case .authenticationFailed(let err):     return "Bithuman.create: authentication failed — \(err)"
        }
    }
    public var errorDescription: String? { description }
}

/// Static background operations on the streaming avatar pipeline.
/// All functions are pure-ish — they mutate the passed `PipelineBox`
/// state where necessary (loading models, replacing the reference
/// latent, clearing chunks) but don't retain internal state. Safe
/// to call from any DispatchQueue context.
internal enum PipelineOps {

    struct LoadResult: Sendable {
        let staticIdleImage: CGImage?
    }

    /// Load models into `box`, render one static idle frame, record
    /// the VAE-encoder weights path for lazy swap-on-demand. Returns
    /// `(nil, errorDescription)` on failure so the caller can log
    /// and surface a user-facing message without needing to catch.
    ///
    /// The public factory path is
    /// ``Bithuman/create(modelPath:identity:quality:chunkProcessor:)``,
    /// which unpacks the model container into a ``ModelPaths`` before
    /// reaching this call site.
    static func load(
        box: PipelineBox,
        paths: ModelPaths
    ) -> (LoadResult?, String?) {
        do {
            let pipeline = try StreamingPipeline(
                ditWeightsPath: paths.ditWeights,
                wav2vecWeightsPath: paths.wav2vecWeights,
                wav2vecANEPath: paths.wav2vecAne,
                refLatentPath: paths.refLatent,
                nSteps: paths.nSteps
            )
            let decoder = try ANEDecoder(path: paths.aneDecoder)
            box.pipeline = pipeline
            box.decoder = decoder
            box.encoderWeightsPath = paths.vaeEncoder
            let result = LoadResult(
                staticIdleImage: generateStaticIdleFrame(pipeline: pipeline, decoder: decoder)
            )
            return (result, nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    /// Render one still avatar frame from silent audio. Seeds the
    /// display before the pipeline starts producing real chunks and
    /// serves as the fallback when the chunk queue empties outside
    /// of an active response.
    static func generateStaticIdleFrame(
        pipeline: StreamingPipeline,
        decoder: ANEDecoder
    ) -> CGImage? {
        let zeros = MLXArray.zeros(
            [1, FRAME_NUM, AUDIO_WINDOW_SIZE, AUDIO_NUM_LAYERS, AUDIO_EMB_DIM]
        ).asType(.float16)
        MLX.eval(zeros)
        let (latent, _) = generateChunk(
            denoiser: pipeline.denoiser,
            refLatent: pipeline.refLatent,
            motionFrames: pipeline.refLatent[0..., ..<1],
            audioContext: zeros,
            dtype: .float16,
            seed: 42,
            nSteps: pipeline.nSteps
        )
        MLX.eval(latent)
        guard let video = try? decoder.decode(latent) else {
            // Idle-frame failure is non-fatal — caller handles nil by
            // keeping the previous frame or falling back to the
            // default portrait image.
            return nil
        }
        return FrameConverter.videoToImages(video).first
    }

    /// Run one pipeline dispatch (FRAME_NUM audio frames) and return
    /// the resulting TimedChunk. Caller is responsible for enqueueing
    /// on the box (so a main-actor epoch check can discard stale
    /// chunks after an interrupt).
    ///
    /// `audio16` must be exactly `FRAME_NUM * SAMPLE_RATE / TGT_FPS`
    /// samples (21 120). `audio24` is the matching 24 kHz slice
    /// (31 680). `isIdle=true` returns a chunk with `audio24k=nil`,
    /// meaning "render frames but play no audio."
    static func processChunk(
        box: PipelineBox,
        audio16: [Float],
        audio24: [Float],
        isIdle: Bool
    ) -> TimedChunk? {
        // Composed of the two stages below — retained as a
        // single-thread convenience path for the default chunk
        // processor and the mock-processor test hook. The pipelined
        // dispatch path in Bithuman goes through the stages directly
        // so the ANE decode queue can overlap with the next DiT
        // dispatch on the GPU.
        guard let stage1 = produceLatent(
            box: box, audio16: audio16, audio24: audio24, isIdle: isIdle
        ) else { return nil }
        return decodeLatentToChunk(box: box, stage1: stage1)
    }

    /// Output of ``produceLatent``. Held between the DiT queue and
    /// the ANE decode queue while Stage 2 of chunk N runs in
    /// parallel with Stage 1 of chunk N+1. MLXArray is not formally
    /// `Sendable` but the latent buffer is read-only after
    /// `MLX.eval` returns on the producer side.
    struct Stage1Output: @unchecked Sendable {
        let latent: MLXArray
        let startFrame: Int
        let audio24: [Float]
        let isIdle: Bool
    }

    /// Stage 1: audio → video latent (wav2vec2 + DiT on the GPU).
    static func produceLatent(
        box: PipelineBox,
        audio16: [Float],
        audio24: [Float],
        isIdle: Bool
    ) -> Stage1Output? {
        guard let pipeline = box.pipeline else { return nil }
        let audio = MLXArray(audio16)
        MLX.eval(audio)
        let results = pipeline.processAudio(audio, maxChunks: 1)
        guard let r = results.first else { return nil }
        MLX.eval(r.latent)  // materialise before handing across queues
        let startFrame = (r.chunkIndex == 0) ? 0 : MOTION_FRAMES_NUM
        return Stage1Output(
            latent: r.latent, startFrame: startFrame,
            audio24: audio24, isIdle: isIdle
        )
    }

    /// Stage 2: video latent → TimedChunk (ANE decode + FrameConverter).
    static func decodeLatentToChunk(
        box: PipelineBox, stage1: Stage1Output
    ) -> TimedChunk? {
        guard let decoder = box.decoder else { return nil }
        guard let video = try? decoder.decode(stage1.latent) else { return nil }
        let frames = FrameConverter.videoToImages(video, startFrame: stage1.startFrame)
        let audioForDisplay: [Float]? = {
            guard !stage1.isIdle, frames.count > 0 else { return nil }
            let samplesPer24kFrame = 24_000 / TGT_FPS  // 960
            let startSample = stage1.startFrame * samplesPer24kFrame
            let endSample = startSample + frames.count * samplesPer24kFrame
            guard endSample <= stage1.audio24.count else { return nil }
            return Array(stage1.audio24[startSample..<endSample])
        }()
        return TimedChunk(frames: frames, audio24k: audioForDisplay)
    }

    /// Encode a new reference image into the pipeline, replacing the
    /// active identity latent. Throws a `PipelineError` with specific
    /// cause on failure so the caller can log with context.
    ///
    /// Side effects: clears the box's chunk queue (chunks computed
    /// against the old latent are now invalid). Does NOT touch the
    /// pending audio buffers or the generation epoch — that's
    /// `Bithuman.prepareForIdentitySwap()`'s job, called by the
    /// caller on the actor side after this function returns.
    static func swapIdentity(
        box: PipelineBox,
        imageURL: URL
    ) throws -> LoadResult {
        guard let pipeline = box.pipeline, let decoder = box.decoder else {
            throw PipelineError.pipelineNotReady
        }

        let encoder: LTXVideoEncoder
        if let cached = box.encoder {
            encoder = cached
        } else {
            guard let path = box.encoderWeightsPath else {
                throw PipelineError.vaeEncoderMissingWeightsPath
            }
            do {
                encoder = try loadLTXVideoEncoder(weightsPath: path, dtype: .float16)
                box.encoder = encoder
            } catch {
                throw PipelineError.vaeEncoderLoadFailed(underlying: error)
            }
        }

        do {
            let resolution = pipeline.refLatent.dim(2) * 32
            let video = try ImagePreprocess.loadReferenceVideo(
                from: imageURL, resolution: resolution, frameCount: FRAME_NUM
            )
            let videoF16 = video.asType(.float16)
            MLX.eval(videoF16)
            let latent = encoder(videoF16)
            MLX.eval(latent)
            pipeline.replaceRefLatent(latent)
            // Drop the encoder once the latent is in the pipeline. Steady
            // state never needs it again — only the next face swap does,
            // and the reload (~2-3 s) happens behind the same "crafting"
            // overlay that already covers the encode pass.
            box.encoder = nil
            MLX.Memory.clearCache()
            box.clearChunks()
            return LoadResult(
                staticIdleImage: generateStaticIdleFrame(pipeline: pipeline, decoder: decoder)
            )
        } catch let err as PipelineError {
            throw err
        } catch {
            throw PipelineError.preprocessFailed(underlying: error)
        }
    }

    /// Variant of ``swapIdentity(box:imageURL:)`` that accepts an
    /// already-encoded identity (`.npy` produced by `encode-ref-latent`
    /// or a previous cached swap). Skips the face-encoder pass, so
    /// the swap is effectively free — just a weight load + chunk-queue
    /// reset.
    ///
    /// The file must decode to a 4-D Float32 array shaped
    /// `[128, 5, S, S]` where `S × 32` matches the face renderer's
    /// output resolution (12 for a 384×384 renderer, etc.); mismatches
    /// throw ``PipelineError/invalidReferenceLatentShape``.
    static func swapIdentity(
        box: PipelineBox,
        preEncodedLatentURL url: URL
    ) throws {
        guard let pipeline = box.pipeline else {
            throw PipelineError.pipelineNotReady
        }
        let latent: MLXArray
        do {
            latent = try MLX.loadArray(url: url)
        } catch {
            throw PipelineError.preprocessFailed(underlying: error)
        }
        // Expected shape: [128, 5, S, S]. The load may yield either
        // [128, 5, S, S] (Halo's bundled file) or [1, 128, 5, S, S]
        // (encoder output that was saved without squeezing). Handle
        // both — the pipeline wants the unbatched shape.
        let reshaped: MLXArray
        switch latent.shape.count {
        case 4: reshaped = latent
        case 5 where latent.shape[0] == 1: reshaped = latent.squeezed(axis: 0)
        default:
            throw PipelineError.preprocessFailed(underlying: NSError(
                domain: "PipelineOps", code: 9,
                userInfo: [NSLocalizedDescriptionKey:
                    "pre-encoded identity has shape \(latent.shape); expected [128,5,S,S] or [1,128,5,S,S]"]
            ))
        }
        let expectedSpatial = pipeline.refLatent.dim(2)
        guard reshaped.dim(2) == expectedSpatial else {
            throw PipelineError.preprocessFailed(underlying: NSError(
                domain: "PipelineOps", code: 10,
                userInfo: [NSLocalizedDescriptionKey:
                    "pre-encoded identity spatial dim \(reshaped.dim(2)) ≠ pipeline dim \(expectedSpatial) — renderer resolution mismatch"]
            ))
        }
        let f16 = reshaped.asType(.float16)
        MLX.eval(f16)
        pipeline.replaceRefLatent(f16)
        box.clearChunks()
    }
}
