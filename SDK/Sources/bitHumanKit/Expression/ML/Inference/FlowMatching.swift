/// Flow matching diffusion: timestep scheduling and SDE update.
///
/// Ported from infer.py: timestep_transform, get_timesteps, generate_chunk.

@_implementationOnly import MLX
@_implementationOnly import MLXRandom
import Foundation

// MARK: - Timestep Schedule

/// Shift timestep schedule with the flow matching shift parameter.
internal func timestepTransform(
    _ t: Float,
    shift: Float = Float(SAMPLE_SHIFT),
    numTimesteps: Int = NUM_TIMESTEPS
) -> Float {
    let tNorm = t / Float(numTimesteps)
    return shift * tNorm / (1 + (shift - 1) * tNorm) * Float(numTimesteps)
}

/// Get timestep schedule for given number of denoising steps.
internal func getTimesteps(nSteps: Int) -> [Float] {
    let raw: [Float]
    switch nSteps {
    case 1: raw = [1000]
    case 2: raw = [1000, 500]
    case 4: raw = [1000, 750, 500, 250]
    default:
        raw = stride(from: Float(NUM_TIMESTEPS), through: 1, by: -Float(NUM_TIMESTEPS - 1) / Float(nSteps - 1))
            .map { $0 }
    }
    return (raw + [0]).map { timestepTransform($0) }
}

// MARK: - Compiled Denoiser

/// Manages compiled step functions for efficient denoising.
///
/// Uses separate functions for step 0 (no KV cache) vs steps 1+
/// (with KV cache) to avoid recompilation when cache shape changes.
internal class CompiledDenoiser: @unchecked Sendable {
    internal let model: WanModelAudioProject

    // Compiled step functions using MLX.compile for kernel fusion
    let compiledStep0: @Sendable ([MLXArray]) -> [MLXArray]
    let compiledStepN: @Sendable ([MLXArray]) -> [MLXArray]
    let numLayers: Int

    internal init(model: WanModelAudioProject, useCompile: Bool = true) {
        self.model = model
        self.numLayers = model.blocks.count

        // Capture model as nonisolated(unsafe) to satisfy Sendable for compile closures
        nonisolated(unsafe) let unsafeModel = model

        if useCompile {
            // Step 0: inputs = [x, t, ctxPre, y], no KV cache
            self.compiledStep0 = compile(inputs: [], outputs: [], shapeless: false) { arrays in
                let (output, kvCache) = unsafeModel.forwardPrecomputed(
                    arrays[0], timestep: arrays[1], contextProj: arrays[2],
                    y: arrays[3], kvCache: nil)
                // Flatten output + KV cache into array
                var result = [output]
                if let kv = kvCache {
                    for (k, v) in kv {
                        result.append(k)
                        result.append(v)
                    }
                }
                return result
            }

            // Step N: inputs = [x, t, ctxPre, y, k0, v0, k1, v1, ...]
            // Uses forwardFast (no KV collection) for cleaner compile graph
            self.compiledStepN = compile(inputs: [], outputs: [], shapeless: false) { arrays in
                let nLayers = (arrays.count - 4) / 2
                var kvCache: [(MLXArray, MLXArray)] = []
                for i in 0..<nLayers {
                    kvCache.append((arrays[4 + i * 2], arrays[4 + i * 2 + 1]))
                }
                let output = unsafeModel.forwardFast(
                    arrays[0], timestep: arrays[1], contextProj: arrays[2],
                    y: arrays[3], kvCache: kvCache)
                return [output]
            }
        } else {
            self.compiledStep0 = { arrays in
                let (output, kvCache) = unsafeModel.forwardPrecomputed(
                    arrays[0], timestep: arrays[1], contextProj: arrays[2],
                    y: arrays[3], kvCache: nil)
                var result = [output]
                if let kv = kvCache {
                    for (k, v) in kv { result.append(k); result.append(v) }
                }
                return result
            }
            self.compiledStepN = { arrays in
                let nLayers = (arrays.count - 4) / 2
                var kvCache: [(MLXArray, MLXArray)] = []
                for i in 0..<nLayers {
                    kvCache.append((arrays[4 + i * 2], arrays[4 + i * 2 + 1]))
                }
                let output = unsafeModel.forwardFast(
                    arrays[0], timestep: arrays[1], contextProj: arrays[2],
                    y: arrays[3], kvCache: kvCache)
                return [output]
            }
        }
    }

    internal func precomputeAudio(_ audioContext: MLXArray) -> MLXArray {
        let ctxPre = model.prepareAudioContext(audioContext)
        MLX.eval(ctxPre)
        return ctxPre
    }

    /// Step 0: no KV cache, returns (output, kvCache)
    internal func step0(
        _ x: MLXArray, timestep t: MLXArray,
        contextProj ctxPre: MLXArray, reference y: MLXArray
    ) -> (MLXArray, [(MLXArray, MLXArray)]?) {
        let results = compiledStep0([x, t, ctxPre, y])
        let output = results[0]
        guard results.count > 1 else { return (output, nil) }
        var kvCache: [(MLXArray, MLXArray)] = []
        for i in stride(from: 1, to: results.count, by: 2) {
            kvCache.append((results[i], results[i + 1]))
        }
        return (output, kvCache)
    }

    /// Step N: reuse KV cache (uses forwardFast — no KV collection overhead)
    internal func stepN(
        _ x: MLXArray, timestep t: MLXArray,
        contextProj ctxPre: MLXArray, reference y: MLXArray,
        kvCache: [(MLXArray, MLXArray)]
    ) -> (MLXArray, [(MLXArray, MLXArray)]?) {
        // Compile-friendly path: flatten KV cache to array, compile the forward
        var inputs = [x, t, ctxPre, y]
        for (k, v) in kvCache { inputs.append(k); inputs.append(v) }
        let results = compiledStepN(inputs)
        return (results[0], nil)
    }

    internal func warmup(dtype: DType, latHw: Int = 16) {
        let x = MLXRandom.normal([1, 128, 5, latHw, latHw]).asType(dtype)
        let t = MLXArray([Float(937.0)])
        let ctxPre = MLXRandom.normal([1, 5, 32, 1536]).asType(dtype)
        let y = MLXRandom.normal([1, 128, 5, latHw, latHw]).asType(dtype)

        let (out0, kv0) = step0(x, timestep: t, contextProj: ctxPre, reference: y)
        MLX.eval(out0)
        if let kv0 = kv0 {
            for (k, v) in kv0 { MLX.eval(k, v) }
        }
        let (outN, _) = stepN(x, timestep: t, contextProj: ctxPre, reference: y,
                               kvCache: kv0 ?? [])
        MLX.eval(outN)
        engineLog("  Denoiser warmup complete")
    }
}

// MARK: - Chunk Generation

/// Timing info from a generation chunk.
internal typealias ChunkTiming = [String: Double]

/// Generate one chunk of video latents using the DiT.
internal func generateChunk(
    denoiser: CompiledDenoiser,
    refLatent: MLXArray,
    motionFrames: MLXArray,
    audioContext: MLXArray,
    dtype: DType = .float16,
    seed: Int = 42,
    nSteps: Int = 4
) -> (MLXArray, ChunkTiming) {
    var timing: ChunkTiming = [:]

    let fLat = refLatent.dim(1), hLat = refLatent.dim(2), wLat = refLatent.dim(3)
    let timesteps = getTimesteps(nSteps: nSteps)

    MLXRandom.seed(UInt64(seed))
    var noise = MLXRandom.normal([128, fLat, hLat, wLat]).asType(dtype)
    let ref = refLatent.asType(dtype)

    let t0Audio = CFAbsoluteTimeGetCurrent()
    let ctxPre = denoiser.precomputeAudio(audioContext.asType(dtype))
    timing["audio_proj"] = CFAbsoluteTimeGetCurrent() - t0Audio

    let M = motionFrames.dim(1)
    let motion = motionFrames.asType(dtype)

    var kvCache: [(MLXArray, MLXArray)]? = nil

    for i in 0..<(timesteps.count - 1) {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Insert motion frames
        noise = concatenated([motion, noise[0..., M...]], axis: 1)
        let tVal = MLXArray([timesteps[i]])

        let result: MLXArray
        if i == 0 {
            let (r, kv) = denoiser.step0(
                expandedDimensions(noise, axis: 0), timestep: tVal,
                contextProj: ctxPre, reference: expandedDimensions(ref, axis: 0))
            result = r
            kvCache = kv
            if let kv = kv {
                for (k, v) in kv { MLX.eval(k, v) }
            }
        } else {
            let (r, _) = denoiser.stepN(
                expandedDimensions(noise, axis: 0), timestep: tVal,
                contextProj: ctxPre, reference: expandedDimensions(ref, axis: 0),
                kvCache: kvCache ?? [])
            result = r
        }

        let flowPred = result.squeezed(axis: 0)

        // SDE flow matching update
        let tI = timesteps[i] / Float(NUM_TIMESTEPS)
        let tNext = timesteps[i + 1] / Float(NUM_TIMESTEPS)
        let x0 = noise - flowPred * tI

        if tNext > 0 {
            let z = MLXRandom.normal(x0.shape).asType(dtype)
            noise = (1 - tNext) * x0 + tNext * z
        } else {
            noise = x0
        }

        MLX.eval(noise)
        // Drop per-step intermediates from MLX's buffer pool
        // BEFORE the next iteration allocates more. Without this,
        // `flowPred`, `x0`, and `z` linger in the pool through
        // every step of the denoise loop — ~100-300 MB of
        // transient peak per chunk that we can give back. Cost
        // is a few ms per step (well within the engine's 1.6×
        // RTF headroom) for a much lower memory ceiling on iPhone.
        MLX.Memory.clearCache()
        timing["step_\(i)"] = CFAbsoluteTimeGetCurrent() - t0
    }

    // Final cleanup: the KV cache (~70 MB at fp16, 12 layers) is
    // no longer needed once the chunk's denoise loop completes.
    // The next chunk allocates fresh entries on its first step;
    // holding the previous chunk's cache through the chunk
    // boundary stacks ~70 MB onto the next chunk's peak.
    kvCache = nil
    MLX.Memory.clearCache()

    let output = concatenated([motion, noise[0..., M...]], axis: 1)
    let totalDenoise = timing.filter { $0.key.hasPrefix("step_") }.values.reduce(0, +)
    timing["total_denoise"] = totalDenoise
    timing["fps"] = Double(NEW_FRAMES_PER_CHUNK) / totalDenoise

    return (output, timing)
}
