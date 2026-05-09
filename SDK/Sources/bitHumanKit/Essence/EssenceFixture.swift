import CoreGraphics
import Foundation

/// Immutable, shareable bundle of every per-fixture buffer the Essence
/// runtime needs. Built once via ``load(modelPath:)``; one fixture can
/// then back many concurrent ``EssenceRuntime`` instances without
/// duplicating the (~200 MB) MP4 archive + patches archive + base
/// frames + face masks + KNN feature index.
///
/// ## Why this exists
///
/// Each ``EssenceRuntime`` instance pre-decodes ~200 MP4 frames,
/// pre-decrypts the BJPG patches archive, and pre-decodes every face
/// mask. On the demo fixture that's ~200 MB of resident memory before
/// any audio gets pushed in. Hosting multiple concurrent avatars on
/// one machine — even when they share the same `.imx` file — would
/// linearly multiply that. This class lets the heavy buffers live in
/// one place; per-instance state (the running audio buffer, the
/// composed-frame LRU, the MP4 decode scratch LRU) is what each
/// runtime allocates fresh.
///
/// ## Cost split (demo fixture, ~225×329 head crop, 200 frames)
///
/// |                            | Per-fixture (shared) | Per-instance |
/// |----------------------------|---------------------:|-------------:|
/// | MP4 base frames (JPEG)     |             ~18 MB   |              |
/// | patches archive (BJPG)     |            ~128 MB   |              |
/// | bases archive (BJPG)       |              ~1 MB   |              |
/// | base BGR cache             |             ~43 MB   |              |
/// | face masks (gray)          |             ~14 MB   |              |
/// | KNN feature index          |              ~3 MB   |              |
/// | int8 encoder weights       |              ~1 MB   |              |
/// | composedCache (CGImage)    |                      |     ~21 MB   |
/// | int8 encoder scratch       |                      |    ~5–10 MB  |
/// | MP4 frame decode LRU       |                      |     ~10 MB   |
/// | audioBuffer (fp32)         |                      |     ~0.2 MB  |
///
/// ## Thread safety
///
/// Every stored property is one of:
///   - a value type with `let`-pinned fields
///   - a reference type whose mutating ops are lock-protected
///     (`PatchReader`'s base/baseBGR caches; the post-init mutation
///     paths there are dead-code in practice — every base is
///     pre-decoded at init — so the lock only contends on the
///     legacy CGImage path used by tests)
///
/// Multiple ``EssenceRuntime`` instances reading from the same fixture
/// concurrently are safe. The fixture itself is `Sendable`.
public final class EssenceFixture: @unchecked Sendable {

    // MARK: - Errors

    public enum LoadError: Swift.Error, CustomStringConvertible {
        case invalidContainer(String)
        case wrongModelType(found: String?)
        case loadFailed(String)

        public var description: String {
            switch self {
            case .invalidContainer(let m):
                return "EssenceFixture: invalid container — \(m)"
            case .wrongModelType(let found):
                return "EssenceFixture: model_type=\(found ?? "<nil>"); expected \"essence\""
            case .loadFailed(let m):
                return "EssenceFixture: load failed — \(m)"
            }
        }
    }

    // MARK: - Per-fixture immutable state

    let manifest: [String: Any]
    /// Audio-encoder backend selection — captured at load time from
    /// `BITHUMAN_AUDIO_ENCODER` so every runtime spun off this fixture
    /// uses the same backend even if the env var changes later.
    enum EncoderBackend { case int8, accelerate }
    let encoderBackend: EncoderBackend
    /// Parsed int8 conv layers. The per-instance Int8Forward will
    /// pad/repack these into its own scratch-resident layout. The
    /// underlying `[Int8]` weight arrays are CoW so the per-layer
    /// raw-weights buffer is shared even after `Int8Forward.init`
    /// runs (it allocates a *new* `weightPadded` buffer though, so
    /// per-instance overhead is the padded weights ≈ 1–3 MB).
    let audioEncoderLayers: [Int8ConvLayer]
    let featureIndex: AudioFeatureIndex
    let patchReader: PatchReader
    let mp4Storage: MP4FrameStorage
    let faceCoords: [(x1: Int, y1: Int, x2: Int, y2: Int)]
    let faceMasks: [(width: Int, height: Int, gray: [UInt8])]
    let frameWH: (width: Int, height: Int)?
    let outputResolution: (width: Int, height: Int)
    let patchPasteBbox: (x1: Int, y1: Int, x2: Int, y2: Int)
    let numFrames: Int
    let numClusters: Int
    let pingPongLoop: Bool
    /// Idle frame computed once at fixture load from the silent mel
    /// embedding. Shared verbatim across runtimes — every instance's
    /// idle frame is byte-identical (same encoder weights, same KNN,
    /// same fixture-1 base + mask), so caching it here saves the
    /// ~5 ms compose work per runtime construction.
    let idleFrame: CGImage

    // MARK: - Public introspection

    /// `(width, height)` of frames returned by ``EssenceRuntime``
    /// runtimes built from this fixture. Sourced from the lip-sync
    /// HDF5's `frame_wh` (the authoring resolution); falls back to
    /// the manifest's `output_resolution` and finally to the MP4
    /// track's natural size.
    public var resolution: (width: Int, height: Int) { outputResolution }

    /// Number of distinct source frames the lip-sync archive holds.
    /// Consumers who want to size capacity buffers (e.g., a UI
    /// progress hint over a fixed playback window) can read this.
    public var sourceFrameCount: Int { numFrames }

    // MARK: - Public factory

    /// Loads an `.imx` v2 Essence container into a shared, immutable
    /// fixture suitable for backing one or many concurrent runtimes.
    /// Heavy: pre-decodes every MP4 frame, decrypts both BJPG
    /// archives, decodes every face mask, computes the idle frame.
    /// Typically takes 1–2 s on a 200-frame fixture.
    public static func load(modelPath: URL) throws -> EssenceFixture {
        let container: ImxContainer
        do {
            container = try ImxContainer(path: modelPath)
        } catch {
            throw LoadError.invalidContainer("\(error)")
        }
        return try EssenceFixture(container: container)
    }

    // MARK: - Internal factory (for back-compat call sites)

    /// Build a fixture from an already-opened container. Used by
    /// ``EssenceGenerator/init(container:)``'s back-compat path so
    /// callers that haven't migrated to the shared-fixture API still
    /// flow through one canonical load implementation.
    internal init(container: ImxContainer) throws {
        let profileInit = ProcessInfo.processInfo.environment["BITHUMAN_PROFILE_INIT"] == "1"
        @inline(__always) func tick() -> UInt64 { EssenceGenerator.nowNs() }
        @inline(__always) func report(_ name: String, _ start: UInt64) {
            guard profileInit else { return }
            let ms = Double(EssenceGenerator.nowNs() &- start) / 1_000_000.0
            FileHandle.standardError.write(Data(
                String(format: "  [fixture] %-30s %7.2f ms\n",
                       (name as NSString).utf8String!, ms).utf8
            ))
        }
        let initT0 = profileInit ? tick() : 0

        guard let manifest = container.manifest else {
            throw EssenceGenerator.Error.manifestMissing
        }
        // Validate model_type defensively. EssenceRuntime.create also
        // checks; mirroring it here lets `EssenceFixture.load(...)`
        // surface a clean error before any heavy I/O fires.
        let modelType = manifest["model_type"] as? String
        guard modelType == "essence" else {
            throw LoadError.wrongModelType(found: modelType)
        }
        self.manifest = manifest

        let (videoFile, lipSync) = try EssenceGenerator.firstVideoWithLipSync(in: manifest)
        self.numClusters = lipSync.numClusters
        self.pingPongLoop = lipSync.isLoopingVideo && !lipSync.singleDirection

        // --- Output resolution from manifest --------------------------------
        var outRes: (width: Int, height: Int) = (0, 0)
        if let arr = manifest["output_resolution"] as? [Int], arr.count >= 2,
           arr[0] > 0, arr[1] > 0 {
            outRes = (arr[0], arr[1])
        } else if let arr = manifest["output_resolution"] as? [Any], arr.count >= 2,
                  let w = (arr[0] as? NSNumber)?.intValue,
                  let h = (arr[1] as? NSNumber)?.intValue,
                  w > 0, h > 0 {
            outRes = (w, h)
        }

        // --- AudioEncoder layers --------------------------------------------
        // Parsed once at fixture load. Each runtime builds its own
        // Int8Forward (or AudioEncoderAccelerate) from these layers
        // — those forward kernels carry per-instance scratch buffers
        // that aren't safely shareable across concurrent encode()
        // calls.
        guard container.hasFile("audio_encoder.onnx") else {
            throw EssenceGenerator.Error.lipSyncEntryMissing("audio_encoder.onnx")
        }
        let tEnc = profileInit ? tick() : 0
        let onnxBytes = try container.readFile("audio_encoder.onnx")
        let model = try parseOnnxModel(onnxBytes)
        self.audioEncoderLayers = try extractInt8ConvLayers(model)
        self.encoderBackend =
            ProcessInfo.processInfo.environment["BITHUMAN_AUDIO_ENCODER"] == "accelerate"
            ? .accelerate : .int8
        report("audioEncoder layers", tEnc)

        // --- AudioFeatureIndex ----------------------------------------------
        guard container.hasFile("audio_feature.f32") else {
            throw EssenceGenerator.Error.lipSyncEntryMissing("audio_feature.f32")
        }
        let tFeat = profileInit ? tick() : 0
        self.featureIndex = try AudioFeatureIndex(from: container)
        report("AudioFeatureIndex", tFeat)

        // --- PatchReader ----------------------------------------------------
        guard container.hasFile(lipSync.basesFile) else {
            throw EssenceGenerator.Error.lipSyncEntryMissing(lipSync.basesFile)
        }
        guard container.hasFile(lipSync.patchesFile) else {
            throw EssenceGenerator.Error.lipSyncEntryMissing(lipSync.patchesFile)
        }
        let basesData = try container.readFile(lipSync.basesFile)
        let patchesData = try container.readFile(lipSync.patchesFile)
        let tPatch = profileInit ? tick() : 0
        self.patchReader = try PatchReader(
            basesData: basesData,
            patchesData: patchesData,
            numClusters: lipSync.numClusters
        )
        report("PatchReader (incl. base pre-decode)", tPatch)

        // --- Lip-sync HDF5 --------------------------------------------------
        guard container.hasFile(lipSync.h5File) else {
            throw EssenceGenerator.Error.lipSyncEntryMissing(lipSync.h5File)
        }
        let tH5 = profileInit ? tick() : 0
        let h5Bytes = try container.readFile(lipSync.h5File)
        let h5Reader = try HDF5Reader(data: h5Bytes)
        report("HDF5 read", tH5)

        let earlyFrameWH: (width: Int, height: Int)?
        if let attr = h5Reader.rootAttributes["frame_wh"], case .int32Array(let arr) = attr,
           arr.count >= 2, arr[0] > 0, arr[1] > 0 {
            earlyFrameWH = (Int(arr[0]), Int(arr[1]))
        } else {
            earlyFrameWH = nil
        }

        // --- MP4 base frames (shareable storage) ----------------------------
        guard container.hasFile(videoFile) else {
            throw EssenceGenerator.Error.lipSyncEntryMissing(videoFile)
        }
        let tMp4 = profileInit ? tick() : 0
        let mp4Hint: (width: Int, height: Int)? =
            earlyFrameWH ?? ((outRes.width > 0 && outRes.height > 0) ? outRes : nil)
        self.mp4Storage = try MP4FrameReader.buildStorage(
            container: container, mp4EntryName: videoFile,
            preferredOutputSize: mp4Hint
        )
        report("MP4FrameStorage (h264 pre-decode)", tMp4)
        self.numFrames = mp4Storage.frameCount

        let coordsDS = try h5Reader.readDataset("face_coords")
        var coords: [(Int, Int, Int, Int)] = []
        if case .int32(let shape, let data) = coordsDS, shape.count == 2, shape[1] == 4 {
            coords.reserveCapacity(shape[0])
            for i in 0..<shape[0] {
                let p = i * 4
                coords.append((Int(data[p]), Int(data[p + 1]), Int(data[p + 2]), Int(data[p + 3])))
            }
        } else {
            throw EssenceGenerator.Error.malformedManifest(
                "face_coords must be int32 (N, 4); got \(coordsDS)"
            )
        }
        self.faceCoords = coords

        let masksDS = try h5Reader.readDataset("face_masks")
        guard case .variableLengthBytes(_, let maskBlobs) = masksDS else {
            throw EssenceGenerator.Error.malformedManifest(
                "face_masks must be variable-length bytes; got \(masksDS)"
            )
        }
        let tMasks = profileInit ? tick() : 0
        let maskCount = maskBlobs.count
        var decodedMasks = [(width: Int, height: Int, gray: [UInt8])](
            repeating: (0, 0, []), count: maskCount
        )
        let maskLock = NSLock()
        var maskError: Swift.Error? = nil
        decodedMasks.withUnsafeMutableBufferPointer { mp in
            let ptr = mp.baseAddress!
            DispatchQueue.concurrentPerform(iterations: maskCount) { i in
                do {
                    let cg = try EssenceImageOps.decodeJPEG(maskBlobs[i])
                    let gray = [UInt8](EssenceImageOps.cgImageToGrayscaleBytes(cg))
                    ptr[i] = (cg.width, cg.height, gray)
                } catch {
                    maskLock.lock()
                    if maskError == nil { maskError = error }
                    maskLock.unlock()
                }
            }
        }
        if let e = maskError { throw e }
        report("face_masks JPEG decode", tMasks)
        self.faceMasks = decodedMasks

        // Resolve the canonical compose space + output resolution.
        // Compose at frame_wh (the lip-sync authoring resolution) and
        // resize to manifest.output_resolution at the end — matches
        // Python's pipeline. Pre-Swift-v0.18.1 we composed at
        // output_resolution directly with pre-scaled face_coords;
        // that produced ~10 px mouth-position offsets vs Python.
        if let fwh = earlyFrameWH, fwh.width > 0, fwh.height > 0 {
            outRes = fwh
        } else if outRes.width == 0 || outRes.height == 0 {
            outRes = mp4Storage.resolution
        }
        self.outputResolution = outRes
        self.frameWH = earlyFrameWH

        // Validate the patch-paste bbox.
        let pasteW = lipSync.cropBbox.x2 - lipSync.cropBbox.x1
        let pasteH = lipSync.cropBbox.y2 - lipSync.cropBbox.y1
        guard pasteW > 0, pasteH > 0 else {
            throw EssenceGenerator.Error.malformedManifest(
                "crop_bbox=\(lipSync.cropBbox) yields non-positive dimensions"
            )
        }
        self.patchPasteBbox = lipSync.cropBbox

        // --- Idle frame -----------------------------------------------------
        // Algo spec §4: silent input → zeroed mel chunk → encode →
        // KNN → compose. The idle frame depends only on per-fixture
        // state (encoder weights, KNN centers, base frame 0, face
        // mask 0), so we compute it here and share verbatim.
        let tIdle = profileInit ? tick() : 0
        let idleEncoder: AnyAudioEncoder
        switch self.encoderBackend {
        case .int8:
            idleEncoder = .int8(try Int8Forward(layers: self.audioEncoderLayers))
        case .accelerate:
            let stBlob = buildFp32SafetensorsFromInt8(self.audioEncoderLayers)
            idleEncoder = .accelerate(try AudioEncoderAccelerate(safetensorsBytes: stBlob))
        }
        let silentMel = [Float](
            repeating: -Float(EssenceGenerator.maxAbsValue),
            count: 80 * EssenceGenerator.melStepSize
        )
        let embeddingFloats = idleEncoder.encode(mel: silentMel)
        let clusterSilent = self.featureIndex.nearestCluster(embedding: embeddingFloats)
        let composeReader = MP4FrameReader(sharing: self.mp4Storage)
        // Apply the same preResize hint EssenceGenerator's per-instance
        // path uses — keeps `bgrFrameSize` consistent with what the
        // compose pipeline expects (frame_wh, with output_resolution
        // as fallback).
        let composeW: Int
        let composeH: Int
        if let fwh = earlyFrameWH, fwh.width > 0, fwh.height > 0 {
            composeW = fwh.width
            composeH = fwh.height
        } else if outRes.width > 0, outRes.height > 0 {
            composeW = outRes.width
            composeH = outRes.height
        } else {
            composeW = mp4Storage.resolution.width
            composeH = mp4Storage.resolution.height
        }
        composeReader.preResize(to: composeW, height: composeH)
        self.idleFrame = try EssenceGenerator.composeFrame(
            frameIdx: 0,
            clusterIdx: clusterSilent,
            patchReader: self.patchReader,
            baseFrames: composeReader,
            faceCoords: self.faceCoords,
            faceMasks: self.faceMasks,
            patchPasteBbox: lipSync.cropBbox,
            frameWH: self.frameWH,
            outputResolution: outRes
        )
        report("idle frame compose", tIdle)
        report("TOTAL EssenceFixture init", initT0)
    }
}

// MARK: - Encoder backend dispatch (used by both fixture + generator)

/// Internal sum type for the audio-encoder forward path. Used by the
/// fixture (to compute the idle frame at load time) and the per-
/// instance ``EssenceGenerator``. Each variant carries its own
/// scratch buffers — the wrapper exists so call sites can switch on
/// the backend selection without copy-pasting the dispatch.
internal enum AnyAudioEncoder {
    case int8(Int8Forward)
    case accelerate(AudioEncoderAccelerate)

    func encode(mel: [Float]) -> [Float] {
        switch self {
        case .int8(let e):       return e.encode(mel: mel)
        case .accelerate(let e): return e.encode(mel: mel)
        }
    }
}
