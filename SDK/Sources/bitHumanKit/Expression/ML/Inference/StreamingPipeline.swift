/// Streaming inference pipeline: audio -> wav2vec2 -> DiT -> video latents.

@_implementationOnly import MLX
@_implementationOnly import MLXRandom
@_implementationOnly import MLXNN
import Foundation

/// Result from generating one video chunk.
internal struct ChunkResult {
    internal let latent: MLXArray
    internal let chunkIndex: Int
    internal let ditMs: Double
    internal let totalMs: Double
}

/// Full streaming FlashHead pipeline in pure Swift.
internal class StreamingPipeline {
    internal let dit: WanModelAudioProject
    internal let denoiser: CompiledDenoiser
    internal let wav2vec: Wav2Vec2AudioModel
    /// Optional ANE-resident audio encoder. When non-nil and the
    /// per-chunk audio length matches the model's expected sample
    /// count (21120), `processAudio` dispatches via Neural Engine
    /// instead of MLX/Metal — frees the GPU for DiT.
    internal let wav2vecANE: Wav2Vec2ANE?
    internal private(set) var refLatent: MLXArray
    internal let nSteps: Int

    var motionFrames: MLXArray
    var chunkIndex: Int = 0

    /// Replace the reference identity latent (e.g. after a VAE re-encode of
    /// a drag-dropped image). Resets chunk state so the next generation
    /// starts fresh from the new identity.
    internal func replaceRefLatent(_ newLatent: MLXArray) {
        let cast = newLatent.asType(.float16)
        MLX.eval(cast)
        refLatent = cast
        motionFrames = cast[0..., ..<1]
        chunkIndex = 0
    }

    internal init(
        ditWeightsPath: String,
        wav2vecWeightsPath: String,
        wav2vecANEPath: String? = nil,
        refLatentPath: String,
        nSteps: Int = 2
    ) throws {
        self.nSteps = nSteps

        self.wav2vec = try loadWav2Vec2Model(weightsPath: wav2vecWeightsPath, dtype: .float16)
        // Optional Neural-Engine audio encoder. Failure to load the
        // .mlpackage isn't fatal — the MLX path still works; we just
        // log and fall back so the user gets a working app even if
        // the bundle is missing or corrupt.
        if let aneURL = wav2vecANEPath {
            do {
                self.wav2vecANE = try Wav2Vec2ANE(path: aneURL)
                engineLog("  Wav2Vec2 ANE bridge ready")
            } catch {
                engineLog("  Wav2Vec2 ANE load failed (\(error)); falling back to MLX path")
                self.wav2vecANE = nil
            }
        } else {
            self.wav2vecANE = nil
        }
        self.dit = try loadDiTModel(weightsPath: ditWeightsPath, dtype: .float16)
        self.denoiser = CompiledDenoiser(model: dit)
        denoiser.warmup(dtype: .float16, latHw: 12)

        self.refLatent = try MLX.loadArray(url: URL(fileURLWithPath: refLatentPath)).asType(.float16)
        // MLX.eval() is a GPU synchronization barrier.
        MLX.eval(refLatent)
        self.motionFrames = refLatent[0..., ..<1]
    }

    /// Process audio end-to-end: wav2vec2 -> sliding window -> DiT chunks.
    ///
    /// - Parameters:
    ///   - rawAudio: 1D float32 audio at `SAMPLE_RATE` (16 kHz).
    ///   - maxSeconds: optional cap on input duration.
    ///   - maxChunks: optional cap on the number of output chunks. The
    ///     streaming caller passes `maxChunks: 1` so a 33-frame input
    ///     produces exactly one chunk instead of iterating again at
    ///     `offset=24` and generating a mostly-padded second chunk that
    ///     gets thrown away. Default `nil` preserves the batch behavior
    ///     used by the CLI tools.
    internal func processAudio(_ rawAudio: MLXArray,
                             maxSeconds: Float? = nil,
                             maxChunks: Int? = nil) -> [ChunkResult] {
        var audio = rawAudio
        if let ms = maxSeconds {
            let maxN = Int(ms * Float(SAMPLE_RATE))
            if audio.dim(audio.ndim - 1) > maxN {
                audio = audio.ndim == 1 ? audio[..<maxN] : audio[0..., ..<maxN]
            }
        }
        if audio.ndim == 1 { audio = expandedDimensions(audio, axis: 0) }

        let nSamples = audio.dim(1)
        let durSec = Float(nSamples) / Float(SAMPLE_RATE)
        let nVideoFrames = Int(durSec * Float(TGT_FPS))

        // wav2vec2 — prefer the ANE path when available AND the chunk
        // shape matches (21120 samples = one 33-frame chunk). For
        // batch / non-streaming callers passing longer audio we fall
        // through to the MLX implementation which can handle any size.
        let hs: [MLXArray]
        if let ane = wav2vecANE, audio.dim(1) == 21120 {
            do {
                hs = try ane.predict(audio: audio, seqLen: nVideoFrames)
            } catch {
                engineLog("  wav2vec ANE predict failed (\(error)); falling back to MLX")
                hs = wav2vec(audio, seqLen: nVideoFrames)
            }
        } else {
            hs = wav2vec(audio, seqLen: nVideoFrames)
        }
        let stacked = MLX.stacked(Array(hs[1...]), axis: 1)
        let emb = stacked.squeezed(axis: 0).transposed(1, 0, 2) // [seq, 12, 768]
        MLX.eval(emb)

        // Sliding window context [1, total, 5, 12, 768]
        let total = emb.dim(0)
        var frames: [MLXArray] = []
        for f in 0..<total {
            var w: [MLXArray] = []
            for d in -2...2 {
                w.append(emb[max(0, min(total-1, f+d))])
            }
            frames.append(MLX.stacked(w, axis: 0))
        }
        let ctx = expandedDimensions(MLX.stacked(frames, axis: 0), axis: 0)
        // Drop the per-frame embedding stacks now that ctx owns
        // its own copy. Otherwise `frames` (~33 × small MLXArrays)
        // and the parent `emb`/`stacked` slabs linger through
        // every chunk in the loop below — at 5+ chunks per turn
        // that's ~50 MB of retained intermediates we don't need.
        frames.removeAll(keepingCapacity: false)
        MLX.Memory.clearCache()
        MLX.eval(ctx)

        // Generate chunks
        var results: [ChunkResult] = []
        var offset = 0

        while offset < total {
            if let maxChunks, results.count >= maxChunks { break }
            // Pre-chunk reclaim — give back any pool slabs left over from
            // the previous chunk's denoise loop before allocating the new
            // chunk's. Per-step clearCache inside `generateChunk` covers
            // intra-chunk transients; this covers chunk-to-chunk tail.
            MLX.Memory.clearCache()
            let end = min(offset + FRAME_NUM, total)
            var ca = ctx[0..., offset..<end]
            if ca.dim(1) < FRAME_NUM {
                let p = MLXArray.zeros([1, FRAME_NUM-ca.dim(1), ca.dim(2), ca.dim(3), ca.dim(4)]).asType(ca.dtype)
                ca = concatenated([ca, p], axis: 1)
            }

            let tc = CFAbsoluteTimeGetCurrent()
            let (lat, timing) = generateChunk(
                denoiser: denoiser, refLatent: refLatent,
                motionFrames: motionFrames, audioContext: ca,
                dtype: .float16, seed: 42 + chunkIndex, nSteps: nSteps)
            MLX.eval(lat)
            let ms = (CFAbsoluteTimeGetCurrent() - tc) * 1000

            results.append(ChunkResult(
                latent: lat, chunkIndex: chunkIndex,
                ditMs: (timing["total_denoise"] ?? 0) * 1000, totalMs: ms))

            motionFrames = lat[0..., (-MOTION_FRAMES_LATENT_NUM)...]
            offset += NEW_FRAMES_PER_CHUNK
            chunkIndex += 1
        }
        return results
    }

    internal func reset() {
        motionFrames = refLatent[0..., ..<1]
        chunkIndex = 0
    }
}
