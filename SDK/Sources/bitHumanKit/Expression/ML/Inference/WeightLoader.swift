/// Weight loading for FlashHead models.
///
/// Loads .safetensors files and maps PyTorch key naming to Swift model structure.

@_implementationOnly import MLX
@_implementationOnly import MLXNN
import Foundation

// MARK: - Streaming safetensors loader
//
// `MLX.loadArrays(url:)` pulls every tensor in a .safetensors file into
// the MLX allocator pool in one shot, and `model.apply { asType(dtype) }`
// then runs an `MLX.eval` that materialises the downcast tensors
// alongside the original-dtype source buffers — 2× peak memory for the
// duration of the load. For the 5.7 GB bf16 DiT that briefly puts the
// process at ~8.5 GB, which on iOS crosses the app's foreground jetsam
// limit and the OS kills the process with SIGKILL during load. (iPad
// apps need the `com.apple.developer.kernel.increased-memory-limit`
// entitlement in addition to this fix; without it the default cap is
// well under the 2.8 GB fp16 steady-state footprint.) On macOS there's
// no jetsam but the 2× transient is still wasted headroom that affects
// users running the app alongside memory-hungry workloads.
//
// `loadSafetensorsStreaming` walks the safetensors header and materialises
// one tensor at a time: read the tensor's bytes, build an `MLXArray`,
// optionally downcast to `targetDtype` and `MLX.eval` it, drop the source.
// Peak additional dirty memory over the accumulated target-dtype result
// is bounded by the largest single tensor (~30 MB for a DMD-2 FFN weight),
// not the whole file. Runtime cost is negligible — many small reads
// through the page cache instead of one big mmap.
//
// Safetensors wire format: 8-byte little-endian uint64 = JSON header
// length; JSON header with `{ "<name>": { "dtype": "BF16", "shape": [...],
// "data_offsets": [start, end] } }` (offsets are relative to the start
// of the data section, which follows the JSON header).

private enum SafetensorsError: Error, CustomStringConvertible {
    case shortRead(String)
    case badHeader(String)
    case unknownDtype(String)
    var description: String {
        switch self {
        case .shortRead(let m):    return "safetensors: short read — \(m)"
        case .badHeader(let m):    return "safetensors: bad header — \(m)"
        case .unknownDtype(let s): return "safetensors: unknown dtype '\(s)'"
        }
    }
}

private func dtypeFromSafetensorsString(_ s: String) throws -> DType {
    switch s {
    case "BF16": return .bfloat16
    case "F16":  return .float16
    case "F32":  return .float32
    case "F64":  return .float64
    case "I8":   return .int8
    case "I16":  return .int16
    case "I32":  return .int32
    case "I64":  return .int64
    case "U8":   return .uint8
    case "U16":  return .uint16
    case "U32":  return .uint32
    case "U64":  return .uint64
    default:     throw SafetensorsError.unknownDtype(s)
    }
}

/// Stream a .safetensors file tensor-by-tensor. Each tensor is read
/// from disk, materialised as an `MLXArray`, optionally cast to
/// `targetDtype` (evaluated inline so the source buffer can be
/// released), and collected into the returned dict.
///
/// Call `MLX.Memory.clearCache()` after consuming the returned dict
/// if you want to drop the MLX allocator's internal pool of source-
/// dtype buffers accumulated during the load.
internal func loadSafetensorsStreaming(
    url: URL,
    targetDtype: DType? = nil
) throws -> [String: MLXArray] {
    let fh = try FileHandle(forReadingFrom: url)
    defer { try? fh.close() }

    // 1. Read header length (8 bytes, little-endian uint64).
    guard let sizeData = try fh.read(upToCount: 8), sizeData.count == 8 else {
        throw SafetensorsError.shortRead("header length")
    }
    let headerLen = sizeData.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian

    // 2. Read JSON header.
    guard let jsonData = try fh.read(upToCount: Int(headerLen)),
          jsonData.count == Int(headerLen) else {
        throw SafetensorsError.shortRead("JSON header (\(headerLen) bytes)")
    }
    guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
        throw SafetensorsError.badHeader("not a JSON object")
    }

    let dataBase: UInt64 = 8 + headerLen  // start of tensor data in the file

    // 3. Sort entries by file offset so reads are monotonic — better
    //    page-cache behaviour on first read, no impact once cached.
    struct Entry {
        let key: String
        let dtype: DType
        let shape: [Int]
        let byteOffset: UInt64
        let byteLen: Int
    }
    var entries: [Entry] = []
    entries.reserveCapacity(json.count)
    for (key, meta) in json {
        if key == "__metadata__" { continue }
        guard let m = meta as? [String: Any],
              let dtypeStr = m["dtype"] as? String,
              let shape = m["shape"] as? [Int],
              let offsets = m["data_offsets"] as? [Int], offsets.count == 2 else {
            throw SafetensorsError.badHeader("bad entry for \(key)")
        }
        entries.append(Entry(
            key: key,
            dtype: try dtypeFromSafetensorsString(dtypeStr),
            shape: shape,
            byteOffset: dataBase + UInt64(offsets[0]),
            byteLen: offsets[1] - offsets[0]
        ))
    }
    entries.sort { $0.byteOffset < $1.byteOffset }

    // 4. Stream each tensor: read → materialise → optionally cast+eval.
    //    Memory-map the file so tensor bytes stay file-backed (not
    //    anonymous dirty pages) and we only pay dirty-RAM cost for
    //    the MLXArray copies we actually need.
    let mapped = try Data(contentsOf: url, options: [.alwaysMapped, .uncached])
    var result: [String: MLXArray] = [:]
    result.reserveCapacity(entries.count)
    var loadedCount = 0
    for e in entries {
        let end = Int(e.byteOffset) + e.byteLen
        let range = Int(e.byteOffset)..<end
        // Copy the tensor's bytes into an MLXArray. We use
        // `withUnsafeBytes` + raw buffer pointer to avoid the
        // double-copy path (Data.read → Data slice → MLX copy); the
        // mapped file stays referenced only via `mapped` until the
        // function returns.
        var arr: MLXArray = mapped.withUnsafeBytes { ptr -> MLXArray in
            let base = ptr.baseAddress!.advanced(by: range.lowerBound)
            // Non-copying Data view over the mapped region; MLXArray's
            // Data initialiser copies the bytes into its allocator.
            let view = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                            count: e.byteLen, deallocator: .none)
            return MLXArray(view, e.shape, dtype: e.dtype)
        }
        if let target = targetDtype, target != e.dtype {
            // Only cast float dtypes — uint32 entries are int4-packed
            // quantized weights from a pre-quant .bhx file and must
            // pass through untouched (a numeric cast to fp16 would
            // corrupt the packing).
            let isFloat = (e.dtype == .float16 || e.dtype == .bfloat16 || e.dtype == .float32)
            if isFloat {
                arr = arr.asType(target)
                MLX.eval(arr)  // GPU sync barrier so the source bytes can be reclaimed
            }
        }
        result[e.key] = arr
        loadedCount += 1
        if loadedCount % 100 == 0 {
            MLX.Memory.clearCache()
            engineLog("    streaming: \(loadedCount)/\(entries.count) tensors loaded")
        }
    }
    MLX.Memory.clearCache()
    return result
}

// MARK: - Safetensors Loading

/// Load a DiT model with weights from a .safetensors file.
internal func loadDiTModel(
    weightsPath: String,
    dtype: DType = .float16
) throws -> WanModelAudioProject {
    engineLog("  Loading DiT model from \(weightsPath)...")

    let model = WanModelAudioProject(
        dim: DIT_DIM,
        inDim: DIT_OUT_DIM * 2,  // 256 (concat noise + ref)
        ffnDim: DIT_FFN_DIM,
        outDim: DIT_OUT_DIM,
        textDim: 4096,
        freqDim: 256,
        eps: 1e-6,
        vaeStride: (8, 32, 32),
        patchSize: (1, 1, 1),
        numHeads: DIT_NUM_HEADS,
        numLayers: DIT_NUM_LAYERS,
        hasImageInput: false
    )

    // Dump model parameter keys for debugging
    let modelKeys = model.parameters().flattened(prefix: "")
    engineLog("  Model has \(modelKeys.count) parameter keys")
    if CommandLine.arguments.contains("--dump-keys") {
        engineLog("  First 20 model keys:")
        for (key, arr) in modelKeys.prefix(20) {
            engineLog("    \(key): \(arr.shape)")
        }
    }

    let url = URL(fileURLWithPath: weightsPath)
    // Stream-load and downcast inline — bounded peak memory vs the
    // whole-file MLX.loadArrays path (which OOMs on iPad, see the
    // loadSafetensorsStreaming doc comment above for details).
    let weights = try loadSafetensorsStreaming(url: url, targetDtype: dtype)
    engineLog("  Loaded \(weights.count) weight tensors from file")

    // Remap PyTorch naming to Swift model naming.
    let remapped = remapToSwiftKeys(weights)
    engineLog("  Remapped to \(remapped.count) Swift keys")

    // Detect a pre-quantized .bhx file: the safetensors carries
    // `.scales` siblings for every Linear `.weight`, meaning the
    // tool already ran `mx.quantize` offline and the runtime just
    // needs to load int4-packed values into QuantizedLinear modules.
    let preQuantized = remapped.keys.contains { $0.hasSuffix(".scales") }
    if preQuantized {
        engineLog("  detected pre-quantized weights (.scales present) — replacing Linear with QuantizedLinear before update")
        // Replace Linears in-place with QuantizedLinear so the
        // pre-quantized .weight / .scales / .biases load correctly
        // via update(parameters:). Skip Linears whose in-features
        // aren't divisible by groupSize=64 — `mx.quantize` errors on
        // those, and the matching pre-quant tool also skips them
        // (their weights stay fp16 in the .bhx file).
        quantize(model: model, filter: { _, m -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
            // Only quantize plain (non-Quantized) Linears with float
            // weights and 64-aligned inner dim; everything else falls
            // through unchanged. The size-floor mirrors the
            // Python-side `is_quantizable_linear_weight` guard
            // (`scripts/prequant_imx.py`) which skips tiny
            // projection heads — without this Swift would replace
            // a small fp16 Linear with QuantizedLinear and the
            // matching `.scales` / `.biases` would be missing from
            // the .bhx, leaving them at default-zero and corrupting
            // that layer's output.
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

    // Drop the bf16 pool slack accumulated while casting each tensor.
    MLX.Memory.clearCache()

    if CommandLine.arguments.contains("--dump-keys") {
        engineLog("  First 20 remapped keys:")
        for (key, arr) in remapped.sorted(by: { $0.key < $1.key }).prefix(20) {
            engineLog("    \(key): \(arr.shape)")
        }
    }

    // Check key matching
    let modelKeySet = Set(modelKeys.map { $0.0.hasPrefix(".") ? String($0.0.dropFirst()) : $0.0 })
    let fileKeySet = Set(remapped.keys)
    let matched = modelKeySet.intersection(fileKeySet)
    let inModelOnly = modelKeySet.subtracting(fileKeySet)
    let inFileOnly = fileKeySet.subtracting(modelKeySet)
    engineLog("  Key matching: \(matched.count) matched, \(inModelOnly.count) model-only, \(inFileOnly.count) file-only")
    if !inModelOnly.isEmpty {
        engineLog("  Model-only keys (first 10):")
        for k in inModelOnly.sorted().prefix(10) { engineLog("    \(k)") }
    }
    if !inFileOnly.isEmpty {
        engineLog("  File-only keys (first 10):")
        for k in inFileOnly.sorted().prefix(10) { engineLog("    \(k)") }
    }

    // Separate modulation and bare array parameters from module parameters
    var moduleParams: [String: MLXArray] = [:]
    var bareParams: [String: MLXArray] = [:]
    for (key, value) in remapped {
        if key.contains("modulation") || key == "patchEmbeddingWeight" || key == "patchEmbeddingBias" || key == "cosFreqs" || key == "sinFreqs" {
            bareParams[key] = value
        } else {
            moduleParams[key] = value
        }
    }

    // Apply module parameters (via MLXNN update system)
    let nestedParams = ModuleParameters.unflattened(moduleParams)
    try model.update(parameters: nestedParams, verify: .none)

    // Manually apply bare array parameters (not @ModuleInfo wrapped)
    if let w = bareParams["patchEmbeddingWeight"] {
        model.patchEmbeddingWeight = w
    }
    if let b = bareParams["patchEmbeddingBias"] {
        model.patchEmbeddingBias = b
    }
    // Apply block modulations
    for i in 0..<DIT_NUM_LAYERS {
        if let m = bareParams["blocks.\(i).modulation"] {
            model.blocks[i].modulation = m
        }
    }
    // Apply head modulation
    if let m = bareParams["ditHead.modulation"] ?? bareParams["head.modulation"] {
        model.ditHead.modulation = m
    }
    engineLog("  Applied \(moduleParams.count) module params + \(bareParams.count) bare params")

    // Check dtypes
    let params = model.parameters().flattened(prefix: "")
    var dtypeCounts: [String: Int] = [:]
    for (_, arr) in params {
        let dt = String(describing: arr.dtype)
        dtypeCounts[dt, default: 0] += 1
    }
    engineLog("  Parameter dtypes (before cast): \(dtypeCounts)")

    // Cast all parameters to target dtype (weights are bf16, we need fp16).
    // Skip uint32 params — those are int4-packed quantized weights from a
    // pre-quantized .bhx file; casting them to fp16 would dequantize-as-
    // numeric and corrupt the data.
    model.apply { param in
        if param.dtype == .uint32 { return param }
        return param.dtype != dtype ? param.asType(dtype) : param
    }

    // Also cast bare params
    model.patchEmbeddingWeight = model.patchEmbeddingWeight.asType(dtype)
    model.patchEmbeddingBias = model.patchEmbeddingBias.asType(dtype)
    for i in 0..<model.blocks.count {
        model.blocks[i].modulation = model.blocks[i].modulation.asType(dtype)
    }
    model.ditHead.modulation = model.ditHead.modulation.asType(dtype)

    // Note: MLX eval() is GPU synchronization, not code execution
    MLX.eval(model.parameters())

    // Release the bf16 source buffers that MLX has pooled in its
    // allocator cache after the asType → fp16 cast above. Those
    // source tensors are no longer reachable from Swift, but MLX
    // keeps them in the cache pool for reuse until the next major
    // allocation forces reclamation. Clearing inline saves ~100 MB
    // of pool slack from the post-load footprint.
    MLX.Memory.clearCache()

    // Verify
    var dtypeCountsAfter: [String: Int] = [:]
    for (_, arr) in model.parameters().flattened(prefix: "") {
        let dt = String(describing: arr.dtype)
        dtypeCountsAfter[dt, default: 0] += 1
    }
    engineLog("  Parameter dtypes (after cast):  \(dtypeCountsAfter)")
    engineLog("  DiT loaded (\(dtype))")

    // Runtime quantize is a no-op if the file was already pre-quantized
    // (we instantiated QuantizedLinear modules above + populated them).
    if !preQuantized {
        maybeQuantizeDiT(model)
    }

    return model
}

/// Optional int4/int8 quantization of all Linear layers in the DiT,
/// driven by the FH_QUANTIZE_DIT env var (values "int4", "int8",
/// "4", or "8"). Uses MLXNN.quantize with groupSize=64.
///
/// At 4 bits on an M5 this cuts DiT parameter memory from ~2.6 GB
/// fp16 to ~750 MB int4+scales and typically yields a 1.5-2x
/// speedup on matmul-heavy layers. Quality is caller-visible —
/// exposed via env flag until we have a proper quality preset.
private func maybeQuantizeDiT(_ model: WanModelAudioProject) {
    guard let mode = ProcessInfo.processInfo.environment["FH_QUANTIZE_DIT"] else { return }
    let bits: Int
    switch mode {
    case "int4", "4": bits = 4
    case "int8", "8": bits = 8
    default: return
    }
    engineLog("  Quantizing DiT: bits=\(bits), groupSize=64")
    quantize(model: model, groupSize: 64, bits: bits)
    MLX.eval(model.parameters())
    // quantize() replaces every Linear's fp16 weight with a fresh
    // int4 uint32-packed tensor + scales + biases. The old fp16
    // weights become unreachable from Swift but stay in MLX's
    // allocator cache — without this call the freed fp16 buffers
    // haunt the process as "cacheMemory" forever, adding ~3 GB to
    // the observable footprint even though they're not in use.
    MLX.Memory.clearCache()
    var counts: [String: Int] = [:]
    for (_, arr) in model.parameters().flattened(prefix: "") {
        counts[String(describing: arr.dtype), default: 0] += 1
    }
    engineLog("  Parameter dtypes (quantized): \(counts)")
}

/// Load the LTX Video VAE encoder. Produces a [128, F_lat, H_lat, W_lat]
/// latent from a [1, 3, 33, H, W] video, used to generate the avatar's
/// reference identity latent from a drag-dropped image.
internal func loadLTXVideoEncoder(
    weightsPath: String,
    dtype: DType = .float16
) throws -> LTXVideoEncoder {
    engineLog("  Loading VAE encoder from \(weightsPath)...")

    let model = LTXVideoEncoder()
    let modelKeys = model.parameters().flattened(prefix: "")
    engineLog("  Model has \(modelKeys.count) parameter keys")

    let weights = try loadSafetensorsStreaming(
        url: URL(fileURLWithPath: weightsPath),
        targetDtype: dtype
    )
    engineLog("  Loaded \(weights.count) weight tensors from file")

    // Remap file keys (down_blocks.N.*) to Swift module names (down_blocks_N.*)
    // so they fit homogeneous @ModuleInfo fields. Statistics tensors are
    // bare parameters applied manually below.
    var remapped: [String: MLXArray] = [:]
    var bare: [String: MLXArray] = [:]
    for (key, arr) in weights {
        if key == "mean_of_means" || key == "std_of_means" {
            bare[key] = arr
            continue
        }
        var newKey = key
        for i in 0..<10 {
            newKey = newKey.replacingOccurrences(
                of: "down_blocks.\(i).", with: "down_blocks_\(i).")
        }
        remapped[newKey] = arr
    }

    let modelKeySet = Set(modelKeys.map { $0.0.hasPrefix(".") ? String($0.0.dropFirst()) : $0.0 })
    let fileKeySet = Set(remapped.keys)
    let matched = modelKeySet.intersection(fileKeySet)
    let modelOnly = modelKeySet.subtracting(fileKeySet)
    let fileOnly = fileKeySet.subtracting(modelKeySet)
    engineLog("  Key matching: \(matched.count) matched, \(modelOnly.count) model-only, \(fileOnly.count) file-only")
    if !modelOnly.isEmpty {
        engineLog("  Model-only (first 10):")
        for k in modelOnly.sorted().prefix(10) { engineLog("    \(k)") }
    }
    if !fileOnly.isEmpty {
        engineLog("  File-only (first 10):")
        for k in fileOnly.sorted().prefix(10) { engineLog("    \(k)") }
    }

    let nested = ModuleParameters.unflattened(remapped)
    try model.update(parameters: nested, verify: .none)

    if let m = bare["mean_of_means"] { model.meanOfMeans = m }
    if let s = bare["std_of_means"]  { model.stdOfMeans  = s }
    engineLog("  Applied \(remapped.count) module params + \(bare.count) bare params")

    model.apply { param in param.dtype != dtype ? param.asType(dtype) : param }
    model.meanOfMeans = model.meanOfMeans.asType(dtype)
    model.stdOfMeans  = model.stdOfMeans.asType(dtype)
    MLX.eval(model.parameters())

    var dtypeCounts: [String: Int] = [:]
    for (_, arr) in model.parameters().flattened(prefix: "") {
        dtypeCounts[String(describing: arr.dtype), default: 0] += 1
    }
    engineLog("  Parameter dtypes: \(dtypeCounts)")
    engineLog("  VAE encoder loaded (\(dtype))")
    return model
}

/// Remap weight keys from PyTorch/safetensors naming to Swift model structure.
internal func remapToSwiftKeys(_ weights: [String: MLXArray]) -> [String: MLXArray] {
    var result: [String: MLXArray] = [:]

    for (key, value) in weights {
        var newKey = key

        // DMD2 Sequential-style FFN naming
        newKey = newKey.replacingOccurrences(of: ".ffn.0.", with: ".ffnLinear1.")
        newKey = newKey.replacingOccurrences(of: ".ffn.2.", with: ".ffnLinear2.")
        newKey = newKey.replacingOccurrences(of: ".ffn_linear1.", with: ".ffnLinear1.")
        newKey = newKey.replacingOccurrences(of: ".ffn_linear2.", with: ".ffnLinear2.")

        // DMD2 audio embedding naming
        newKey = newKey.replacingOccurrences(of: "audio_emb.proj.0.", with: "audioEmb.norm1.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.proj.1.", with: "audioEmb.linear1.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.proj.3.", with: "audioEmb.linear2.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.proj.4.", with: "audioEmb.norm2.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.norm1.", with: "audioEmb.norm1.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.linear1.", with: "audioEmb.linear1.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.linear2.", with: "audioEmb.linear2.")
        newKey = newKey.replacingOccurrences(of: "audio_emb.norm2.", with: "audioEmb.norm2.")

        // Python snake_case to Swift camelCase
        newKey = newKey.replacingOccurrences(of: "self_attn.", with: "selfAttn.")
        newKey = newKey.replacingOccurrences(of: "cross_attn.", with: "crossAttn.")
        newKey = newKey.replacingOccurrences(of: "norm_q.", with: "normQ.")
        newKey = newKey.replacingOccurrences(of: "norm_k.", with: "normK.")
        newKey = newKey.replacingOccurrences(of: "norm_k_img.", with: "normKImg.")
        newKey = newKey.replacingOccurrences(of: "k_img.", with: "kImg.")
        newKey = newKey.replacingOccurrences(of: "v_img.", with: "vImg.")
        newKey = newKey.replacingOccurrences(of: "audio_proj.", with: "audioProj.")

        // Patch embedding: patch_embedding.weight → patchEmbeddingWeight
        newKey = newKey.replacingOccurrences(of: "patch_embedding.weight", with: "patchEmbeddingWeight")
        newKey = newKey.replacingOccurrences(of: "patch_embedding.bias", with: "patchEmbeddingBias")

        // Text embedding: text_embedding.0. → textEmbeddingLinear1., .2. → Linear2
        newKey = newKey.replacingOccurrences(of: "text_embedding.0.", with: "textEmbeddingLinear1.")
        newKey = newKey.replacingOccurrences(of: "text_embedding.2.", with: "textEmbeddingLinear2.")

        // Time embedding: time_embedding.0. → timeEmbeddingLinear1., .2. → Linear2
        newKey = newKey.replacingOccurrences(of: "time_embedding.0.", with: "timeEmbeddingLinear1.")
        newKey = newKey.replacingOccurrences(of: "time_embedding.2.", with: "timeEmbeddingLinear2.")

        // Time projection: time_projection.0. or time_projection.1. → timeProjectionLinear.
        // (Python uses nn.Sequential or direct linear, numbering varies)
        newKey = newKey.replacingOccurrences(of: "time_projection.0.", with: "timeProjectionLinear.")
        newKey = newKey.replacingOccurrences(of: "time_projection.1.", with: "timeProjectionLinear.")
        newKey = newKey.replacingOccurrences(of: "time_projection.linear.", with: "timeProjectionLinear.")

        // Head
        newKey = newKey.replacingOccurrences(of: "head.head.", with: "ditHead.head.")
        newKey = newKey.replacingOccurrences(of: "head.norm.", with: "ditHead.norm.")
        newKey = newKey.replacingOccurrences(of: "head.modulation", with: "ditHead.modulation")

        // Audio proj sub-keys
        newKey = newKey.replacingOccurrences(of: "proj1_vf.", with: "proj1Vf.")

        // Skip precomputed RoPE (we compute these in Swift)
        if newKey.contains("cos_freqs") || newKey.contains("sin_freqs") {
            continue
        }

        result[newKey] = value
    }

    return result
}
