import Accelerate
import CoreGraphics
import Foundation
@_implementationOnly import MLX

/// Single-frame orchestrator for the Essence inference path.
///
/// Wires together the six already-shipped leaf modules into a per-chunk
/// `audio → CGImage` pipeline matching `docs/architecture/essence-algorithm-spec.md`
/// §7 ("Full End-to-End Pipeline"):
///
/// ```
/// audio16k(640 int16)
///   → mel(80×16) [vDSP STFT + Slaney mel + log + symmetric-[-4,+4] norm]
///   → AudioEncoder.encode(...)            (1, 1, 80, 16) -> (1, 512, 1, 1)
///   → AudioFeatureIndex.nearestCluster(...)              -> flat_index
///   → frame_idx = (flat // num_clusters) % num_frames
///     cluster_idx = flat % num_clusters
///   → if cluster_idx == 0: out = base[frame_idx]
///     else:                blend mouth-patch over base via mask + crop_bbox
///   → CGImage at manifest.output_resolution
/// ```
///
/// **Scope of this commit (10/19).** Just the orchestrator. The streaming
/// runtime (`EssenceRuntime` actor with `pushAudio` / `AsyncStream`) lands in
/// commit 11. All construction here is synchronous.
///
/// **Threading.** `EssenceGenerator` owns mutable state (audio buffer, frame
/// counter) and is **NOT** thread-safe. The runtime layer serializes calls
/// via its actor.
internal final class EssenceGenerator {

    // MARK: - Profiling (BITHUMAN_PROFILE=1)
    static let profileEnabled: Bool = ProcessInfo.processInfo.environment["BITHUMAN_PROFILE"] == "1"
    var profMel: UInt64 = 0
    var profEncode: UInt64 = 0
    var profKnn: UInt64 = 0
    var profComposeMiss: UInt64 = 0
    var profComposeHit: UInt64 = 0
    var profSamples: UInt64 = 0
    var profSamplesMiss: UInt64 = 0
    var profSamplesHit: UInt64 = 0
    // Compose-stage breakdown (only populated when profileEnabled).
    static var profComposeMP4: UInt64 = 0
    static var profComposeMP4Resize: UInt64 = 0
    static var profComposeAvatar: UInt64 = 0
    static var profComposeLipResize: UInt64 = 0
    static var profComposeMaskResize: UInt64 = 0
    static var profComposeBlend: UInt64 = 0
    static var profComposeFinalResize: UInt64 = 0
    static var profComposeBytesToCG: UInt64 = 0
    // Avatar/patch substeps (only populated when profileEnabled).
    static var profAvatarBaseFetch: UInt64 = 0
    static var profAvatarPatchDecode: UInt64 = 0
    static var profAvatarPatchToBGR: UInt64 = 0
    static var profAvatarWriteRegion: UInt64 = 0
    @inline(__always) static func nowNs() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    }
    func dumpFrameProfile() {
        guard Self.profileEnabled, profSamples > 0 else { return }
        let n = Double(profSamples)
        let toUs = { (v: UInt64) -> Double in Double(v) / n / 1000.0 }
        print("=== EssenceGenerator per-frame profile (\(profSamples) frames) ===")
        print(String(format: "  mel:           %6.2f µs", toUs(profMel)))
        print(String(format: "  encode:        %6.2f µs", toUs(profEncode)))
        print(String(format: "  knn:           %6.2f µs", toUs(profKnn)))
        if profSamplesMiss > 0 {
            let nm = Double(profSamplesMiss)
            print(String(format: "  compose miss:  %6.2f µs (avg of %d miss frames, %.0f%% of total)",
                Double(profComposeMiss) / nm / 1000.0,
                profSamplesMiss,
                100 * Double(profSamplesMiss) / n
            ))
        }
        if profSamplesHit > 0 {
            let nh = Double(profSamplesHit)
            print(String(format: "  compose hit:   %6.2f µs (avg of %d hit frames)",
                Double(profComposeHit) / nh / 1000.0,
                profSamplesHit
            ))
        }
        let total = profMel &+ profEncode &+ profKnn &+ profComposeMiss &+ profComposeHit
        print(String(format: "  sum:           %6.2f µs / frame", toUs(total)))
        if profSamplesMiss > 0 {
            let nm = Double(profSamplesMiss)
            let stage = { (v: UInt64) -> Double in Double(v) / nm / 1000.0 }
            print("  compose miss breakdown (avg per miss):")
            print(String(format: "    mp4 decode/get  %6.2f µs", stage(Self.profComposeMP4)))
            print(String(format: "    mp4 resize      %6.2f µs", stage(Self.profComposeMP4Resize)))
            print(String(format: "    avatar (patch)  %6.2f µs", stage(Self.profComposeAvatar)))
            print(String(format: "    lip resize      %6.2f µs", stage(Self.profComposeLipResize)))
            print(String(format: "    mask resize     %6.2f µs", stage(Self.profComposeMaskResize)))
            print(String(format: "    blend           %6.2f µs", stage(Self.profComposeBlend)))
            print(String(format: "    final resize    %6.2f µs", stage(Self.profComposeFinalResize)))
            print(String(format: "    bytes→CGImage   %6.2f µs", stage(Self.profComposeBytesToCG)))
            print("  avatar (patch) breakdown (avg per miss):")
            print(String(format: "    base fetch      %6.2f µs", stage(Self.profAvatarBaseFetch)))
            print(String(format: "    patch decode    %6.2f µs", stage(Self.profAvatarPatchDecode)))
            print(String(format: "    patch → BGR     %6.2f µs", stage(Self.profAvatarPatchToBGR)))
            print(String(format: "    write region    %6.2f µs", stage(Self.profAvatarWriteRegion)))
        }
    }

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case manifestMissing
        case lipSyncEntryMissing(String)
        case noLipSyncVideo
        case malformedManifest(String)
        case maskShapeMismatch(maskW: Int, maskH: Int, faceW: Int, faceH: Int)
        case faceCoordOutOfRange(idx: Int, available: Int)
        case bgrToCGImageFailed

        var description: String {
            switch self {
            case .manifestMissing:
                return "EssenceGenerator: container has no manifest.json"
            case .lipSyncEntryMissing(let n):
                return "EssenceGenerator: container missing lip-sync entry '\(n)'"
            case .noLipSyncVideo:
                return "EssenceGenerator: manifest has no video with lip_sync data"
            case .malformedManifest(let detail):
                return "EssenceGenerator: malformed manifest — \(detail)"
            case .maskShapeMismatch(let mw, let mh, let fw, let fh):
                return
                    "EssenceGenerator: mask size (\(mw)×\(mh)) does not match face region (\(fw)×\(fh))"
            case .faceCoordOutOfRange(let i, let n):
                return "EssenceGenerator: face_coords index \(i) out of range [0, \(n))"
            case .bgrToCGImageFailed:
                return "EssenceGenerator: failed to materialize CGImage from BGR buffer"
            }
        }
    }

    // MARK: - Audio constants (algo spec §1)

    /// Spec-required sample rate — 16 kHz.
    static let sampleRate: Int = 16_000
    /// Spec-required pacing — 25 FPS.
    static let fps: Int = 25
    /// 640 samples per video frame at 25 FPS / 16 kHz.
    static let samplesPerFrame: Int = sampleRate / fps  // 640
    /// Mel time-steps fed to the encoder.
    static let melStepSize: Int = 16
    /// `80 / fps` (Python float). At 25 FPS this is 3.2.
    static let melIdxMultiplier: Double = 80.0 / Double(fps)
    /// Maximum samples the running audio buffer holds before old
    /// samples get trimmed off the front. Each mel chunk only needs
    /// ~16×200 = 3.2k samples of look-back; cap at 10 s = 160 k for
    /// generous head-room. Without this the buffer grows linearly with
    /// session length — at 1 hour of audio that's 230 MB of float
    /// retained for no reason, plus an O(N) STFT cost per frame.
    static let audioBufferCapSamples: Int = 160_000

    /// STFT params — must match `bithuman/audio/hparams.py`.
    private static let nFFT: Int = 800
    private static let hopSize: Int = 200
    private static let winSize: Int = 800
    private static let preemphasisCoeff: Float = 0.97
    private static let numMels: Int = 80
    private static let fmin: Double = 55
    private static let fmax: Double = 7600
    private static let minLevelDB: Double = -100
    private static let refLevelDB: Double = 20
    internal static let maxAbsValue: Double = 4.0

    /// Below this RMS the chunk is treated as silent at the very start of
    /// a stream (we still produce a frame, but route it through the idle
    /// path so the very first audio chunk doesn't see a noisy mel from
    /// a half-filled buffer). Roughly -84 dBFS.
    private static let silenceRMSThreshold: Float = 5.0 / 32767.0

    // MARK: - Owned subsystems

    /// Strong ref to the immutable per-fixture state. Pinning this on
    /// the generator keeps the shared archive resident while at least
    /// one runtime is using it, even if the original
    /// ``EssenceFixture`` reference goes out of scope at the call
    /// site.
    private let fixture: EssenceFixture
    /// Audio encoder dispatch wrapper. Two backends:
    ///
    /// - **`int8`** (default, v0.18.9+): native int8 SDOT/SMMLA
    ///   forward via `Int8Forward` + `BitHumanInt8Conv`. ~0.8 ms /
    ///   encode on M-series with cluster-pick parity vs the fp32
    ///   bridge (102/350 unique on the demo fixture vs fp32's
    ///   103/350). The v0.18.4–v0.18.8 cluster-collapse bug was
    ///   root-caused to the Int8Encoder ONNX BFS overshooting
    ///   through residual `Add` ops and picking the next layer's
    ///   post-Add Q as the current layer's output scale — fixed in
    ///   v0.18.9 by gating the forward walk to follow at most one
    ///   `Add` and stopping at the first Conv terminator.
    /// - **`accelerate`**: fp32 cblas_sgemm bridge via
    ///   `AudioEncoderAccelerate`. Dequantizes the int8 QDQ weights
    ///   to fp32 once at load and runs Accelerate's vectorized
    ///   GEMM. Slower (~1.7 ms / encode) and ~2× peak RSS, but a
    ///   useful baseline for byte-equivalence checks. Opt-in via
    ///   `BITHUMAN_AUDIO_ENCODER=accelerate`.
    private let audioEncoder: AnyAudioEncoder
    private let featureIndex: AudioFeatureIndex
    private let patchReader: PatchReader
    private let baseFrames: MP4FrameReader
    private let faceCoords: [(x1: Int, y1: Int, x2: Int, y2: Int)]
    /// Per-frame face mask, pre-decoded at init into BGR uint8 form.
    /// Decoding the JPEG once at startup (~9 MB total for a 200-frame
    /// fixture at 60×60) avoids the 0.5-1 ms `decodeJPEG` cost on
    /// every cache-miss frame.
    /// Per-frame face mask in 1-channel grayscale storage. The H5
    /// stores these as JPEG (originally encoded as RGB888 with R==G==B
    /// — verified across every mask in the v2 corpus); decoding
    /// directly into Planar8 saves 2/3 of the mask memory and lets
    /// the blend kernel read one mask byte per BGR pixel.
    private let faceMasks: [(width: Int, height: Int, gray: [UInt8])]
    private let frameWH: (width: Int, height: Int)?
    private let _outputResolution: (width: Int, height: Int)
    /// Manifest's `lip_sync.crop_bbox` — the box on the bases-archive
    /// head crop where mouth patches get pasted (Python's
    /// `PatchReader._crop_bbox`). **NOT** the per-frame face-placement
    /// region — the lip overlay is later blended into the original
    /// frame at `face_coords[frame_idx]`, which is loaded from the
    /// lip-sync HDF5 and varies per frame.
    private let patchPasteBbox: (x1: Int, y1: Int, x2: Int, y2: Int)
    private let numFrames: Int
    /// Whether the talking video plays as a ping-pong loop (forward
    /// → reverse → forward, seamless) vs a hard-cut loop (forward
    /// only, wrap from N-1 back to 0). True iff manifest declares
    /// `type=LoopingVideo` AND `single_direction=false` (the v2
    /// fixture default).
    private let pingPongLoop: Bool
    private let _idleFrame: CGImage

    // MARK: - Composed-frame cache
    //
    // The compose pipeline is deterministic in (frameIdx, clusterIdx):
    // same inputs → same output CGImage. The KNN tends to repeatedly
    // pick the same source frames over short audio windows, especially
    // for silent or sustained-vowel passages — measured ~67% repeat
    // ratio on a 250-frame demo clip with 83 unique clusters. Caching
    // the composed CGImage drops per-frame work to "audio encode + KNN
    // + lookup" (~1-2 ms) on cache hits, matching the Python SDK's
    // observed 1.65 ms / 235 FPS on the same fixture (Python caches at
    // the same boundary).
    //
    // 128-entry LRU. Each entry is one CGImage at output_resolution
    // (~3.5 MB at 1248×704 RGBA), so the upper bound is ~450 MB.
    // Empirical: a 250-frame demo clip touches ~83 unique clusters; 128
    // capacity covers that without eviction, and lifts cache-hit ratio
    // from ~50% (cap=64, evicting late entries) to ~67%. Going higher
    // costs more memory without proportional FPS gain on typical clips.
    private struct ComposedCache {
        var capacity: Int
        var images: [Int64: CGImage] = [:]
        var recency: [Int64] = []
        /// Approximate per-entry size in bytes for the dump audit.
        /// Set when we install the cache (knows the output frame's
        /// pixel count).
        var bytesPerEntry: Int = 0

        @inline(__always) static func key(_ frameIdx: Int, _ clusterIdx: Int) -> Int64 {
            (Int64(frameIdx) << 32) | Int64(clusterIdx & 0xFFFF_FFFF)
        }

        mutating func get(_ k: Int64) -> CGImage? {
            guard let img = images[k] else { return nil }
            if let i = recency.firstIndex(of: k) { recency.remove(at: i) }
            recency.insert(k, at: 0)
            return img
        }

        mutating func put(_ k: Int64, _ img: CGImage) {
            if images[k] != nil, let i = recency.firstIndex(of: k) {
                recency.remove(at: i)
            }
            images[k] = img
            recency.insert(k, at: 0)
            while recency.count > capacity {
                images[recency.removeLast()] = nil
            }
        }

        func approximateBytes() -> Int {
            // CGImage backing memory is opaque; report w*h*4 as an
            // upper bound (each entry is a CGImage with a CGDataProvider
            // owning an Int8 buffer of width * height * 3 bytes —
            // matches the BGR888 path in `bgrBytesToCGImage`).
            var sum = 0
            for (_, img) in images {
                sum &+= img.width * img.height * 3
            }
            return sum
        }
    }
    // v0.18.10: capacity dropped from 128 to 8. The cluster pick
    // varies almost every frame on real audio (KNN diversity ≈ 100
    // unique on a 350-frame demo), so the (frame_idx, cluster_idx)
    // cache key collides only when two consecutive ticks happen to
    // land on the same combo. Bench at capacity 128 showed 6/300
    // hits = 2%, with ~338 MB of dead-memory weight. Capacity 8
    // captures every same-cluster-burst pattern that actually fires
    // and caps the cache at ~21 MB on the demo fixture.
    private var composedCache = ComposedCache(capacity: 8)

    // MARK: - Audio buffering (running)

    private var audioBuffer: [Float] = []

    /// Mel-frame index of `audioBuffer[0]`. Advances when we trim
    /// older samples off the front of the buffer to keep memory
    /// bounded. The compose pipeline subtracts this from the absolute
    /// `frame * melIdxMultiplier` index to look up its 16-frame mel
    /// slice in the trimmed buffer's local mel coordinates.
    private var audioBufferOriginMelFrame: Int = 0
    private var frameCounter: Int = 0

    // MARK: - Mel basis (cached)

    private static let melBasis: [Float] = computeSlaneyMelBasis()
    private static let hannWindow: [Float] = {
        let n = winSize
        var w = [Float](repeating: 0, count: n)
        for i in 0..<n {
            w[i] = 0.5 * (1.0 - Float(cos(2.0 * .pi * Double(i) / Double(n))))
        }
        return w
    }()
    /// vDSP only supports power-of-two FFT sizes; nFFT=800 is not. We
    /// zero-pad each frame to fftSize=1024 and run a 1024-point FFT,
    /// then keep the first `nFFT/2 + 1` bins. See ALGO-NOTE-1 below.
    private static let fftLog2N: vDSP_Length = 10  // 2^10 = 1024
    private static let fftSize: Int = 1024

    /// Bluestein 800-pt DFT — used to bit-match `numpy.fft.rfft(800)`
    /// when `BITHUMAN_MEL_FFT=bluestein` is set. The default keeps
    /// the faster 1024-pt zero-padded path; see ALGO-NOTE-1 for why
    /// the byte-exact alternative is kept opt-in (15 µs vs 1 µs per
    /// STFT frame, and on its own doesn't close the residual face-
    /// area PSNR gap — the rest of the mel pipeline drifts too).
    private static let bluestein800: BluesteinDFT = BluesteinDFT(length: 800)

    // MARK: - Init

    /// Back-compat convenience: build a fixture from the container, then
    /// hand off to ``init(fixture:)``. Each call does the full heavy
    /// load — for hosting many concurrent runtimes against the same
    /// `.imx`, prefer ``EssenceFixture/load(modelPath:)`` once and
    /// pass the result here multiple times.
    convenience init(container: ImxContainer) throws {
        let fixture = try EssenceFixture(container: container)
        try self.init(fixture: fixture)
    }

    /// Lightweight init from a shared fixture. Allocates only per-
    /// instance mutable state (audio buffer, composed-frame LRU,
    /// MP4 frame decode LRU + prefetch queue, encoder scratch
    /// buffers) — every immutable archive is reused from the
    /// fixture.
    init(fixture: EssenceFixture) throws {
        let profileInit = ProcessInfo.processInfo.environment["BITHUMAN_PROFILE_INIT"] == "1"
        @inline(__always) func tick() -> UInt64 { Self.nowNs() }
        @inline(__always) func report(_ name: String, _ start: UInt64) {
            guard profileInit else { return }
            let ms = Double(Self.nowNs() &- start) / 1_000_000.0
            FileHandle.standardError.write(Data(
                String(format: "  [init] %-30s %7.2f ms\n", (name as NSString).utf8String!, ms).utf8
            ))
        }
        let initT0 = profileInit ? tick() : 0

        self.fixture = fixture
        self.pingPongLoop = fixture.pingPongLoop

        // --- Per-instance audio encoder -------------------------------------
        // The forward kernels (Int8Forward / AudioEncoderAccelerate)
        // carry mutable scratch buffers — quantize/im2col workspaces
        // for the int8 path, fp32 GEMM workspaces for the accelerate
        // path. They aren't safely shareable across concurrent
        // encode() calls, so each runtime gets its own. The weights
        // themselves are CoW slices of the layer table the fixture
        // parsed once.
        let tEnc = profileInit ? tick() : 0
        switch fixture.encoderBackend {
        case .accelerate:
            let stBlob = buildFp32SafetensorsFromInt8(fixture.audioEncoderLayers)
            self.audioEncoder = .accelerate(try AudioEncoderAccelerate(safetensorsBytes: stBlob))
        case .int8:
            self.audioEncoder = .int8(try Int8Forward(layers: fixture.audioEncoderLayers))
        }
        report("audioEncoder build", tEnc)

        // --- Wire fixture refs (immutable per-fixture state) ---------------
        self.featureIndex = fixture.featureIndex
        self.patchReader = fixture.patchReader
        self.faceCoords = fixture.faceCoords
        self.faceMasks = fixture.faceMasks
        self.frameWH = fixture.frameWH
        self._outputResolution = fixture.outputResolution
        self.patchPasteBbox = fixture.patchPasteBbox
        self.numFrames = fixture.numFrames

        // --- Per-instance MP4 reader (sharing the fixture's storage) -------
        // The JPEG archive lives in `fixture.mp4Storage`; this
        // instance only owns the per-frame decode LRU + prefetch
        // queue. Apply the compose-space preResize hint so
        // `baseFrames.bgrFrameSize` matches what `composeFrame`
        // expects. Typically a no-op (storage was built at
        // frame_wh) but kept for defensive parity.
        let tMp4 = profileInit ? tick() : 0
        let baseFrames = MP4FrameReader(sharing: fixture.mp4Storage)
        let composeW: Int
        let composeH: Int
        if let fwh = fixture.frameWH, fwh.width > 0, fwh.height > 0 {
            composeW = fwh.width
            composeH = fwh.height
        } else if fixture.outputResolution.width > 0, fixture.outputResolution.height > 0 {
            composeW = fixture.outputResolution.width
            composeH = fixture.outputResolution.height
        } else {
            composeW = fixture.mp4Storage.resolution.width
            composeH = fixture.mp4Storage.resolution.height
        }
        baseFrames.preResize(to: composeW, height: composeH)
        self.baseFrames = baseFrames
        report("MP4FrameReader (per-instance)", tMp4)

        // --- Idle frame (shared from the fixture) --------------------------
        // The idle frame is a function of the encoder weights, KNN
        // centers, base frame 0, face mask 0, and patch-paste box
        // — all of which are fixture-immutable. The fixture computes
        // it once at load and we just adopt the CGImage here.
        self._idleFrame = fixture.idleFrame

        report("TOTAL EssenceGenerator init", initT0)
    }

    // MARK: - Public surface

    /// Idle frame — algo spec §4. Returned by callers when no audio is
    /// being driven; computed once at init from the silent embedding.
    var idleFrame: CGImage { _idleFrame }

    /// Output frame size. Sourced from `manifest.output_resolution`,
    /// falling back to the MP4's native size.
    var resolution: (width: Int, height: Int) { _outputResolution }

    /// Per-frame diagnostic payload — used by the bench harness and
    /// fixture-corpus comparator to surface KNN cluster picks alongside
    /// the rendered image. Not part of the public SDK surface; the
    /// runtime exposes this only through internal/test-seam accessors
    /// (see `EssenceRuntime.generateFrameDetailedForBench`).
    struct FrameDetail {
        let image: CGImage
        let frameIdx: Int
        let clusterIdx: Int
        /// Flat KNN index pre-translation. Useful for byte-identity
        /// checks when both runtimes use the same audio_feature table.
        let flatIndex: Int
        /// True if the silence-guard fast-path took over and `image` is
        /// the prebuilt idle frame.
        let isSilenceGuarded: Bool
        /// L2 norm of the 512-d encoder embedding. Used by the cross-
        /// path comparator to verify int8 vs fp32 encoder agreement on
        /// real audio (the test mel hits values near zero where both
        /// paths happen to agree; on real audio the int8 path's
        /// per-layer requantize rounding can compound enough to map to
        /// a different KNN cluster). Populated only when
        /// `BITHUMAN_PROFILE=1` since it costs an L2 reduction.
        let embedNorm: Float
    }

    /// Process one audio chunk and return the rendered `CGImage`.
    ///
    /// Per algo spec §6, the canonical chunk is 640 int16 samples (40 ms
    /// at 16 kHz / 25 FPS), but this method tolerates other chunk sizes —
    /// the running buffer accumulates them and the mel slice is taken
    /// per-frame against the full history.
    func generateFrame(audioChunk: [Int16]) throws -> CGImage {
        try generateFrameDetailed(audioChunk: audioChunk).image
    }

    /// Bench-only seam: run the audio encoder on a fixed (1, 1, 80, 16)
    /// mel input and return the (1, 512, 1, 1) embedding as flat
    /// row-major float32. Lets the cross-SDK comparator verify the
    /// Swift MLX embedding matches the ONNX reference; if KNN cluster
    /// picks differ, drift starts here.
    func _encodeMelForBench(mel: [Float]) -> [Float] {
        audioEncoder.encode(mel: mel)
    }

    /// Dump the per-stage profile counters accumulated when
    /// `BITHUMAN_PROFILE=1` is set. Forwarded by `EssenceRuntime`'s
    /// bench-only helper.
    func _dumpProfileForBench() {
        guard Self.profileEnabled else { return }
        dumpFrameProfile()
        // Forward to the int8 encoder if that path is in use.
        if case .int8(let e) = audioEncoder {
            e.dumpProfile()
        }
        dumpMemoryAudit()
    }

    /// Approximate memory (bytes) held by each major owned buffer.
    /// Triple-checks our model of where peak RSS is going so we don't
    /// optimize the wrong cache. Numbers are storage-only — no
    /// allocator overhead, no CGImage's IOSurface backing memory,
    /// no Accelerate workspace pools.
    func dumpMemoryAudit() {
        var total: Int = 0
        func line(_ name: String, _ bytes: Int) {
            total &+= bytes
            let mb = Double(bytes) / (1024.0 * 1024.0)
            let padded = name.padding(toLength: 32, withPad: " ", startingAt: 0)
            FileHandle.standardError.write(Data(
                String(format: "  \(padded)  %10.2f MB\n", mb).utf8
            ))
        }
        FileHandle.standardError.write(Data(
            "=== EssenceGenerator memory audit ===\n".utf8
        ))
        // MP4 base frames: in default mode this is raw BGR; in
        // low-memory mode (BITHUMAN_LOW_MEMORY=1) it's JPEG bytes.
        let mp4Bytes = baseFrames._mp4StorageBytes()
        line("MP4 base frames", mp4Bytes)
        // PatchReader: bases archive (raw bytes), patches archive (raw
        // bytes), per-base BGR, per-base CGImage cache.
        let pr = patchReader._memoryAudit()
        line("patches archive bytes", pr.patchesBytes)
        line("bases archive bytes", pr.basesBytes)
        line("baseBGRCache (uint8)", pr.baseBGRBytes)
        line("baseCache (CGImage)", pr.baseCGBytes)
        // Face masks: 1-channel grayscale (one byte per pixel).
        var maskBytes = 0
        for m in faceMasks { maskBytes &+= m.gray.count }
        line("faceMasks (gray)", maskBytes)
        // Composed cache (LRU, holds ready-to-render CGImages —
        // dominant single allocation in long sessions).
        let composedBytes = composedCache.approximateBytes()
        line("composedCache (CGImage)", composedBytes)
        // Audio buffer (running fp32 mel input).
        line("audioBuffer (fp32)", audioBuffer.count * MemoryLayout<Float>.size)
        let totMB = Double(total) / (1024.0 * 1024.0)
        let totName = "TOTAL (buffers only)".padding(toLength: 32, withPad: " ", startingAt: 0)
        FileHandle.standardError.write(Data(
            String(format: "  \(totName)  %10.2f MB\n", totMB).utf8
        ))
    }


    /// Same pipeline as ``generateFrame(audioChunk:)`` but returns the
    /// KNN cluster pick alongside the rendered image. Used by the
    /// `bench-essence` harness (Examples/BenchEssence) so the cross-SDK
    /// fixture comparator can record `cluster_idx` per frame and check
    /// drift against the Python ONNX reference.
    func generateFrameDetailed(audioChunk: [Int16]) throws -> FrameDetail {
        // 1. int16 → float32 (algo spec §1: divide by INT16_MAX = 32767).
        var fchunk = [Float](repeating: 0, count: audioChunk.count)
        let invMax: Float = 1.0 / 32767.0
        audioChunk.withUnsafeBufferPointer { ib in
            fchunk.withUnsafeMutableBufferPointer { fb in
                vDSP_vflt16(ib.baseAddress!, 1, fb.baseAddress!, 1, vDSP_Length(audioChunk.count))
                var s = invMax
                vDSP_vsmul(fb.baseAddress!, 1, &s, fb.baseAddress!, 1, vDSP_Length(audioChunk.count))
            }
        }
        audioBuffer.append(contentsOf: fchunk)

        // Cap the running buffer at `audioBufferCapSamples` worth of
        // history. Without this, a long-running session leaks memory
        // (the buffer grows by 640 floats per call, forever) and the
        // STFT cost becomes O(N) per frame. We trim in multiples of
        // hopSize so the FFT-frame grid stays aligned, and advance
        // `audioBufferOriginMelFrame` by the corresponding number of
        // mel frames so absolute-frame indexing remains correct.
        if audioBuffer.count > Self.audioBufferCapSamples {
            let excess = audioBuffer.count - Self.audioBufferCapSamples
            let trimFrames = excess / Self.hopSize
            let trimSamples = trimFrames * Self.hopSize
            if trimSamples > 0 {
                audioBuffer.removeFirst(trimSamples)
                audioBufferOriginMelFrame &+= trimFrames
            }
        }

        // Initial-window silence guard: if this is the very first chunk
        // and it's silent, route through idle so we don't run an under-
        // primed mel buffer through the encoder.
        let rms = chunkRMS(fchunk)
        if rms < Self.silenceRMSThreshold && frameCounter == 0 && audioBufferOriginMelFrame == 0 {
            frameCounter += 1
            // Silence-guard returns the idle frame; bench consumers
            // should treat `isSilenceGuarded == true` as the signal that
            // cluster_idx is degenerate for this frame (the silent
            // embedding's flat index was computed at init but isn't
            // stored, so we report 0 here).
            return FrameDetail(
                image: idleFrame,
                frameIdx: 0,
                clusterIdx: 0,
                flatIndex: 0,
                isSilenceGuarded: true,
                embedNorm: 0
            )
        }

        // 2. Compute mel for this frame.
        let tMel = Self.profileEnabled ? Self.nowNs() : 0
        let mel80x16 = makeMelChunk(
            forFrame: frameCounter,
            originMelFrame: audioBufferOriginMelFrame,
            buffer: audioBuffer
        )
        frameCounter += 1
        if Self.profileEnabled { profMel &+= Self.nowNs() &- tMel }

        // 3. AudioEncoder — (1, 1, 80, 16) → (1, 512, 1, 1).
        let tEnc = Self.profileEnabled ? Self.nowNs() : 0
        let embeddingFloats = audioEncoder.encode(mel: mel80x16)
        if Self.profileEnabled { profEncode &+= Self.nowNs() &- tEnc }

        // 4. KNN — picks ONLY the cluster index. The KNN feature
        //    centers are `(num_clusters, embedding_dim)` so the
        //    return is in `[0, num_clusters)`. Earlier Swift
        //    treated the return as a `(frame, cluster)` flat index
        //    and computed `frame_idx = flat // num_clusters` — which
        //    rounded to 0 always (since flat < num_clusters), so
        //    every render used `bases[0]`. That's the freeze the
        //    user observed.
        let tKnn = Self.profileEnabled ? Self.nowNs() : 0
        let clusterIdx = featureIndex.nearestCluster(embedding: embeddingFloats)
        let flatIndex = clusterIdx  // kept for the FrameDetail ABI
        if Self.profileEnabled { profKnn &+= Self.nowNs() &- tKnn }

        // 5. Frame index walk. Two policies, per Python's video_graph:
        //    - **Ping-pong** (`type=LoopingVideo` &&
        //      `single_direction=false`): forward 0 → N-1 → reverse
        //      → N-2 → … → 1 → forward 0 → 1 → …, period 2(N-1).
        //      Seamless loop — no visible cut at the wraparound,
        //      which is the v2 fixture default and what Python emits
        //      for `LoopingVideo` clips.
        //    - **Forward-only** (`single_direction=true`): plain
        //      `frameCounter % N` modulo, hard-cut wrap.
        //
        //    Earlier Swift always used the forward-only modulo, so
        //    every N ticks the avatar visibly snapped from the last
        //    frame back to frame 0. The ping-pong walk fixes that.
        let tick = max(0, frameCounter - 1)
        let frameIdx: Int
        if pingPongLoop && numFrames > 1 {
            // Triangle wave with period 2*(N-1):
            //   t mod 2(N-1) ∈ [0, N-1]    → forward (t mod 2(N-1))
            //   t mod 2(N-1) ∈ [N, 2(N-1)-1] → reverse (2(N-1) - t mod ...)
            let period = 2 * (numFrames - 1)
            let phase = tick % period
            frameIdx = phase < numFrames ? phase : (period - phase)
        } else {
            frameIdx = tick % max(1, numFrames)
        }

        // Predictive prefetch hint for low-memory mode. The next
        // `frameCounter` is `tick + 2` (since tick = frameCounter - 1
        // and we already incremented frameCounter at the top of this
        // function). For ping-pong walks the next frame_idx is
        // deterministic; we tell `MP4FrameReader.prefetchFrame` so
        // its background queue can JPEG-decode the predicted next
        // frame DURING this frame's compose. By the time the runtime
        // asks for it on the next tick, the BGR is already in the
        // LRU cache and there's no decode latency in the hot path.
        // No-op when low-memory mode is off.
        if numFrames > 1 {
            let nextTick = tick &+ 1
            let nextIdx: Int
            if pingPongLoop {
                let period = 2 * (numFrames - 1)
                let phase = nextTick % period
                nextIdx = phase < numFrames ? phase : (period - phase)
            } else {
                nextIdx = nextTick % numFrames
            }
            baseFrames.prefetchFrame(at: nextIdx)
        }

        // 6. Compose. Hit the per-(frame_idx, cluster_idx) cache first.
        let cacheKey = ComposedCache.key(frameIdx, clusterIdx)
        let image: CGImage
        let tCompose = Self.profileEnabled ? Self.nowNs() : 0
        if let cached = composedCache.get(cacheKey) {
            image = cached
            if Self.profileEnabled {
                profComposeHit &+= Self.nowNs() &- tCompose
                profSamplesHit &+= 1
            }
        } else {
            image = try Self.composeFrame(
                frameIdx: frameIdx,
                clusterIdx: clusterIdx,
                patchReader: patchReader,
                baseFrames: baseFrames,
                faceCoords: faceCoords,
                faceMasks: faceMasks,
                patchPasteBbox: patchPasteBbox,
                frameWH: frameWH,
                outputResolution: _outputResolution
            )
            composedCache.put(cacheKey, image)
            if Self.profileEnabled {
                profComposeMiss &+= Self.nowNs() &- tCompose
                profSamplesMiss &+= 1
            }
        }
        if Self.profileEnabled { profSamples &+= 1 }
        var embNorm: Float = 0
        if Self.profileEnabled {
            var ssq: Float = 0
            for v in embeddingFloats { ssq += v * v }
            embNorm = ssq.squareRoot()
        }
        return FrameDetail(
            image: image,
            frameIdx: frameIdx,
            clusterIdx: clusterIdx,
            flatIndex: flatIndex,
            isSilenceGuarded: false,
            embedNorm: embNorm
        )
    }

    // MARK: - Frame index translation (exposed for tests)

    /// Pure-arithmetic helper covering the algo spec §4 frame translation.
    /// Returns `(frame_idx, cluster_idx)` for a given flat KNN index, the
    /// cluster count, and the source frame count.
    static func translateFlatIndex(
        _ flat: Int, numClusters: Int, numFrames: Int
    ) -> (frameIdx: Int, clusterIdx: Int) {
        let nc = max(1, numClusters)
        let nf = max(1, numFrames)
        let frameIdx = (flat / nc) % nf
        let clusterIdx = flat % nc
        return (frameIdx, clusterIdx)
    }

    // MARK: - Compose (shared by init + per-frame path)

    /// Per-frame composite — direct port of Python's
    /// `bithuman/engine/video_data.py:get_blended_frame`.
    ///
    /// Pipeline (matches Python step-for-step):
    ///   1. **Original frame** — full MP4 frame from `MP4FrameReader`,
    ///      resized to `frame_wh` (HDF5 attr) if it differs.
    ///   2. **Lip / avatar overlay** — head crop returned by
    ///      `getAvatarFrame`. For cluster 0 this is the bases archive
    ///      entry; for cluster ≥ 1 it's the bases entry with the mouth
    ///      patch pasted at the patch reader's stored crop_bbox (mirrors
    ///      `PatchReader.get` in patch_reader.py).
    ///   3. **Face box** — `face_coords[frame_idx]` from the lip-sync
    ///      HDF5. **NOT** the manifest `crop_bbox` (which is only the
    ///      first face_coord and changes nothing per-frame).
    ///   4. **Mask** — `face_masks[frame_idx]` JPEG, decoded.
    ///   5. **Resize** lip overlay and mask to face-box dims if they
    ///      differ (defensive — Python errors out instead, so in the
    ///      byte-exact case both are no-ops).
    ///   6. **Blend** lip into the original frame's face-box region
    ///      using `EssenceImageOps.blendFaceRegion` (bit-exact div255).
    ///   7. **Resize** final full frame to manifest `output_resolution`
    ///      if it differs from `frame_wh`.
    internal static func composeFrame(
        frameIdx: Int,
        clusterIdx: Int,
        patchReader: PatchReader,
        baseFrames: MP4FrameReader,
        faceCoords: [(x1: Int, y1: Int, x2: Int, y2: Int)],
        faceMasks: [(width: Int, height: Int, gray: [UInt8])],
        patchPasteBbox: (x1: Int, y1: Int, x2: Int, y2: Int),
        frameWH: (width: Int, height: Int)?,
        outputResolution: (width: Int, height: Int)
    ) throws -> CGImage {
        // v0.18.1+: compose at `frame_wh` (the lip-sync authoring
        // resolution), then resize the composed frame to
        // `output_resolution` at the end. This exactly mirrors
        // Python's pipeline (`get_original_frame` resizes MP4 →
        // frame_wh, `get_blended_frame` composes at frame_wh, the
        // generator's `_output_size` does a final resize). Composing
        // at output_resolution directly with pre-scaled face_coords
        // (the v0.16-v0.18.0 approach) introduced mouth-position
        // offsets of ~10 px because rounding scaled coords +
        // bilinear-resizing each mask + bilinear-resizing each lip
        // patch isn't equivalent to composing once at frame_wh and
        // resizing the whole frame at the end.

        // -------- 1. MP4 frame at `frame_wh` ------------------------
        // Resize the cached MP4 frame to frame_wh if frame_wh is set
        // and differs from the MP4 native. Mirrors Python's
        // `get_original_frame`. When frame_wh is nil (a fixture
        // without an H5 frame_wh attr), use the output_resolution as
        // the compose space — same fallback as Python's "treat
        // _output_size as the compose space when frame_wh is unset".
        let _t1 = Self.profileEnabled ? Self.nowNs() : 0
        let (mp4BGR, mp4W, mp4H) = try baseFrames.extractFrameBGR(at: frameIdx)
        if Self.profileEnabled { Self.profComposeMP4 &+= Self.nowNs() &- _t1 }
        let composeW: Int
        let composeH: Int
        if let fwh = frameWH, fwh.width > 0, fwh.height > 0 {
            composeW = fwh.width
            composeH = fwh.height
        } else if outputResolution.width > 0, outputResolution.height > 0 {
            composeW = outputResolution.width
            composeH = outputResolution.height
        } else {
            composeW = mp4W
            composeH = mp4H
        }
        var composeBGR: [UInt8]
        let _t2 = Self.profileEnabled ? Self.nowNs() : 0
        if composeW == mp4W && composeH == mp4H {
            composeBGR = mp4BGR
        } else {
            composeBGR = EssenceImageOps.bilinearResizeBGR(
                src: mp4BGR, srcW: mp4W, srcH: mp4H,
                dstW: composeW, dstH: composeH
            )
        }
        if Self.profileEnabled { Self.profComposeMP4Resize &+= Self.nowNs() &- _t2 }

        // -------- 2. Lip / avatar overlay (head crop, BGR uint8) -----
        let _t3 = Self.profileEnabled ? Self.nowNs() : 0
        let lipRaw = try Self.getAvatarFrameBGR(
            patchReader: patchReader,
            frameIdx: frameIdx,
            clusterIdx: clusterIdx,
            patchPasteBbox: patchPasteBbox
        )
        if Self.profileEnabled { Self.profComposeAvatar &+= Self.nowNs() &- _t3 }

        // -------- 3. Face bounding box at frame_wh coords -----------
        guard frameIdx >= 0 && frameIdx < faceCoords.count else {
            throw Error.faceCoordOutOfRange(idx: frameIdx, available: faceCoords.count)
        }
        let box = faceCoords[frameIdx]
        let faceW = box.x2 - box.x1
        let faceH = box.y2 - box.y1
        guard faceW > 0, faceH > 0 else {
            throw Error.malformedManifest(
                "face_coords[\(frameIdx)]=\(box) yields non-positive dimensions"
            )
        }

        // -------- 4. Per-frame face mask (raw, at H5 dims) ----------
        guard frameIdx < faceMasks.count else {
            throw Error.faceCoordOutOfRange(idx: frameIdx, available: faceMasks.count)
        }
        let mask = faceMasks[frameIdx]

        // -------- 5. Lip + mask to face-box dims --------------------
        // Match Python's `_blend_numpy`: `lip[:roi_h, :roi_w]` slices
        // the head crop to face-box dims. If the head crop is at
        // least as large as the face box on both axes, truncate
        // (matches Python). Otherwise resize (defensive fallback for
        // malformed fixtures).
        if frameIdx == 0,
           ProcessInfo.processInfo.environment["BITHUMAN_VERBOSE"] == "1" {
            FileHandle.standardError.write(Data(
                "🔍 compose frame 0: mp4=\(mp4W)×\(mp4H); composeWH=\(composeW)×\(composeH); outputResolution=\(outputResolution.width)×\(outputResolution.height); face_box=(\(box.x1),\(box.y1))-(\(box.x2),\(box.y2)) faceW=\(faceW) faceH=\(faceH); lipRaw=\(lipRaw.width)×\(lipRaw.height); mask=\(mask.width)×\(mask.height); patchPasteBbox=\(patchPasteBbox)\n".utf8
            ))
        }
        let _t4 = Self.profileEnabled ? Self.nowNs() : 0
        let lipBGR: [UInt8]
        if lipRaw.width >= faceW && lipRaw.height >= faceH {
            if lipRaw.width == faceW && lipRaw.height == faceH {
                lipBGR = lipRaw.bgr
            } else {
                lipBGR = EssenceImageOps.cropTopLeftBGR(
                    src: lipRaw.bgr, srcW: lipRaw.width, srcH: lipRaw.height,
                    dstW: faceW, dstH: faceH
                )
            }
        } else {
            lipBGR = EssenceImageOps.bilinearResizeBGR(
                src: lipRaw.bgr, srcW: lipRaw.width, srcH: lipRaw.height,
                dstW: faceW, dstH: faceH
            )
        }
        if Self.profileEnabled { Self.profComposeLipResize &+= Self.nowNs() &- _t4 }
        let _t5 = Self.profileEnabled ? Self.nowNs() : 0
        let maskGray: [UInt8]
        if mask.width == faceW && mask.height == faceH {
            maskGray = mask.gray
        } else {
            maskGray = EssenceImageOps.bilinearResizeGrayscale(
                src: mask.gray, srcW: mask.width, srcH: mask.height,
                dstW: faceW, dstH: faceH
            )
        }
        if Self.profileEnabled { Self.profComposeMaskResize &+= Self.nowNs() &- _t5 }

        // -------- 6. Alpha-blend at face_coords (in frame_wh space) -
        let _t6 = Self.profileEnabled ? Self.nowNs() : 0
        EssenceImageOps.blendFaceRegionInPlace(
            frame: &composeBGR,
            frameW: composeW, frameH: composeH,
            patch: lipBGR, mask: maskGray,
            x: box.x1, y: box.y1, w: faceW, h: faceH
        )
        if Self.profileEnabled { Self.profComposeBlend &+= Self.nowNs() &- _t6 }

        // -------- 7. Final resize to output_resolution (if needed) --
        let _t7 = Self.profileEnabled ? Self.nowNs() : 0
        let outW = outputResolution.width > 0 ? outputResolution.width : composeW
        let outH = outputResolution.height > 0 ? outputResolution.height : composeH
        let finalBGR: [UInt8]
        let finalW: Int
        let finalH: Int
        if outW == composeW && outH == composeH {
            finalBGR = composeBGR
            finalW = composeW
            finalH = composeH
        } else {
            finalBGR = EssenceImageOps.bilinearResizeBGR(
                src: composeBGR, srcW: composeW, srcH: composeH,
                dstW: outW, dstH: outH
            )
            finalW = outW
            finalH = outH
        }
        if Self.profileEnabled { Self.profComposeFinalResize &+= Self.nowNs() &- _t7 }

        // -------- 8. Materialize CGImage ---------------------------
        let _t8 = Self.profileEnabled ? Self.nowNs() : 0
        guard let composed = finalBGR.withUnsafeBufferPointer({ bp -> CGImage? in
            EssenceImageOps.bgrBytesToCGImage(bp.baseAddress!, width: finalW, height: finalH)
        }) else { throw Error.bgrToCGImageFailed }
        if Self.profileEnabled { Self.profComposeBytesToCG &+= Self.nowNs() &- _t8 }
        return composed
    }

    /// Reproduces the per-frame head-crop the Python `VideoData
    /// .get_avatar_frame` returns — i.e. `PatchReader.get(index)` after
    /// the FEATURE_FIRST flat-index translation.
    ///
    /// - cluster 0 → the bases-archive frame as-is (BGR bytes).
    /// - cluster ≥ 1 → bases frame with the mouth patch pasted at the
    ///   patch reader's authoring crop_bbox.
    ///
    /// Returns BGR uint8 bytes directly (no CGImage round-trip); the
    /// compose pipeline operates on uint8 buffers, and the previous
    /// CGImage→BGR→CGImage→BGR ping-pong was costing ~1 ms per miss.
    private static func getAvatarFrameBGR(
        patchReader: PatchReader,
        frameIdx: Int,
        clusterIdx: Int,
        patchPasteBbox cb: (x1: Int, y1: Int, x2: Int, y2: Int)
    ) throws -> (bgr: [UInt8], width: Int, height: Int) {
        let _t0 = Self.profileEnabled ? Self.nowNs() : 0
        let baseBGR = try patchReader.baseBGR(at: frameIdx)
        if Self.profileEnabled { Self.profAvatarBaseFetch &+= Self.nowNs() &- _t0 }
        if clusterIdx == 0 {
            return baseBGR
        }
        let _t1 = Self.profileEnabled ? Self.nowNs() : 0
        guard let patchCG = try patchReader.patch(frame: frameIdx, cluster: clusterIdx) else {
            return baseBGR
        }
        if Self.profileEnabled { Self.profAvatarPatchDecode &+= Self.nowNs() &- _t1 }
        let pasteW = cb.x2 - cb.x1
        let pasteH = cb.y2 - cb.y1
        guard pasteW > 0, pasteH > 0 else { return baseBGR }

        // Match Python's behavior: `result[y1:y2, x1:x2] = patch` —
        // numpy slicing silently clips the LHS slice to the array's
        // actual bounds, then the patch dims must match the clipped
        // slice. In our v2 fixtures, crop_bbox describes the
        // INTENDED paste rectangle (e.g., 241×213) but the bases
        // archive is smaller (e.g., 225×329) and the patches archive
        // matches the CLIPPED region (e.g., 225×197). Effectively
        // the patch always lands at (cb.x1, cb.y1) using its native
        // dimensions, ignoring the larger crop_bbox dims.
        //
        // Pre-fix Swift bilinear-resized the patch from 225×197 →
        // 241×213, then writeRegion clipped to 225×197 of base
        // bounds — producing a SCALED+CLIPPED patch (~10 px shifted
        // visually). Now we paste at native dims directly.
        let _t2 = Self.profileEnabled ? Self.nowNs() : 0
        let patchBGRBytes = [UInt8](EssenceImageOps.cgImageToBGRBytes(patchCG))
        if Self.profileEnabled { Self.profAvatarPatchToBGR &+= Self.nowNs() &- _t2 }
        let _t3 = Self.profileEnabled ? Self.nowNs() : 0
        var bytes = baseBGR.bgr
        writeRegion(
            into: &bytes, baseW: baseBGR.width, baseH: baseBGR.height,
            region: patchBGRBytes, x: cb.x1, y: cb.y1,
            w: patchCG.width, h: patchCG.height
        )
        if Self.profileEnabled { Self.profAvatarWriteRegion &+= Self.nowNs() &- _t3 }
        return (bytes, baseBGR.width, baseBGR.height)
    }

    private static func resizeIfNeeded(
        _ image: CGImage, to res: (width: Int, height: Int)
    ) -> CGImage {
        if res.width <= 0 || res.height <= 0 { return image }
        if image.width == res.width && image.height == res.height { return image }
        return EssenceImageOps.resize(image, width: res.width, height: res.height) ?? image
    }

    // MARK: - Mel preprocessing (vDSP STFT + Slaney mel + log + sym-norm)

    /// Build the (80 × 16) mel chunk for `frame` from the running float32
    /// buffer. Matches `bithuman/audio/audio.py:get_mel_chunks` (one mel
    /// frame per `int(frame * 3.2)` step).
    ///
    /// `originMelFrame` is the absolute mel-frame index of `buffer[0]`
    /// — non-zero once the streaming buffer trim has discarded older
    /// samples. We compute `relativeStartIdx = absoluteStartIdx -
    /// originMelFrame` so the slice happens at the right offset within
    /// the trimmed buffer.
    func makeMelChunk(
        forFrame frame: Int, originMelFrame: Int = 0, buffer: [Float]
    ) -> [Float] {
        // ---- v0.15.0 mel-slice optimization ---------------------------
        //
        // Compute mel only over the audio window the encoder actually
        // needs (~3800 samples, the 16-mel-frame window plus the
        // n_fft/2 STFT centering pad on each side) — vs the original
        // implementation which ran melSpectrogram over the full 10 s
        // audio buffer every frame and discarded ~98% of the output.
        // Mel cost: 558 µs → 75 µs / frame (~7.4×).
        //
        // v0.17 attempted a per-frame chunk-shift cache (recompute
        // only the trailing 3 columns and reuse the rest from the
        // previous frame) but the per-call array overhead consistently
        // outweighed the saved STFT/melBasis work, so we reverted.
        // See `docs/architecture/essence-port-plan.md` for follow-up
        // notes if mel ever becomes the bottleneck again.

        let absoluteStartIdx = Int(Double(frame) * Self.melIdxMultiplier)
        let bufferStartMelFrame = originMelFrame
        let bufferEndMelFrame = originMelFrame + (buffer.count - Self.winSize / 2) / Self.hopSize
            // Approximate count of mel frames present in the buffer
            // under the standard `center=true` STFT framing.

        // Tail-align fallback: if the requested startIdx lands past
        // the end of buffered mel, snap back to the last 16 frames.
        // (Matches the Python reference.)
        var sliceMelStart = absoluteStartIdx
        if bufferEndMelFrame >= bufferStartMelFrame + Self.melStepSize,
           absoluteStartIdx + Self.melStepSize > bufferEndMelFrame {
            sliceMelStart = bufferEndMelFrame - Self.melStepSize
        }
        let sliceMelEnd = sliceMelStart + Self.melStepSize  // exclusive

        // Convert mel-frame range to audio-sample range with the
        // n_fft/2 STFT centering pad on each side. Then express in
        // buffer-relative coordinates.
        let halfFFT = Self.winSize / 2  // == nFFT/2 for our config
        let audioStartAbs = sliceMelStart * Self.hopSize - halfFFT
        let audioEndAbs = (sliceMelEnd - 1) * Self.hopSize + halfFFT  // exclusive
        let bufferStartAbs = originMelFrame * Self.hopSize
        let sliceStart = audioStartAbs - bufferStartAbs
        let sliceEnd = audioEndAbs - bufferStartAbs

        // Clip to actual buffer extents. If the requested window
        // entirely precedes the buffer (early-frame silence path),
        // return all-silence; the per-frame caller already gates with
        // a silence check, so this is rare.
        let clipStart = max(0, sliceStart)
        let clipEnd = max(clipStart, min(buffer.count, sliceEnd))
        if clipEnd - clipStart < Self.winSize {
            // Insufficient samples for even one full STFT frame;
            // return silence.
            return [Float](repeating: -Float(Self.maxAbsValue),
                           count: Self.numMels * Self.melStepSize)
        }

        // Take the slice. For a typical mid-stream call this is
        // ~3800 samples (= 0.24 s at 16 kHz) instead of 160 000.
        let audioSlice = Array(buffer[clipStart..<clipEnd])
        let mel = Self.melSpectrogram(audioSlice)
        let nMelFrames = mel.isEmpty ? 0 : mel.count / Self.numMels

        // The slice's first mel frame index in absolute coords.
        let sliceStartAbsMel = (clipStart + bufferStartAbs) / Self.hopSize

        // Now copy 16 mel frames starting at sliceMelStart (absolute)
        // = sliceMelStart - sliceStartAbsMel (slice-relative).
        var out = [Float](repeating: -Float(Self.maxAbsValue),
                          count: Self.numMels * Self.melStepSize)
        let localStart = sliceMelStart - sliceStartAbsMel
        if localStart >= 0 && localStart + Self.melStepSize <= nMelFrames {
            for m in 0..<Self.numMels {
                let srcRow = m * nMelFrames + localStart
                let dstRow = m * Self.melStepSize
                for t in 0..<Self.melStepSize {
                    out[dstRow + t] = mel[srcRow + t]
                }
            }
        } else {
            // Partial overlap — fill what we can, leave the rest at
            // silence. Same shape as the original "not enough mel"
            // branch.
            for m in 0..<Self.numMels {
                for t in 0..<Self.melStepSize {
                    let s = localStart + t
                    if s >= 0 && s < nMelFrames {
                        out[m * Self.melStepSize + t] = mel[m * nMelFrames + s]
                    }
                }
            }
        }
        return out
    }

    /// Compute the full mel spectrogram for `audio` matching the Python
    /// reference's `melspectrogram(wav)`. Returns row-major
    /// `(numMels × T)` float32. Static so unit tests can exercise it
    /// without constructing a full generator instance.
    static func melSpectrogram(_ audio: [Float], preLookback: Float? = nil) -> [Float] {
        // 1. Preemphasis: y[n] = x[n] - 0.97 * x[n-1].
        // `preLookback` is the audio sample immediately preceding
        // `audio[0]` in the original sequence. When provided (e.g.,
        // for incremental mel computation on a slice), pre[0] uses
        // it; otherwise the original "no lookback" semantics apply
        // (pre[0] = audio[0]).
        var pre = [Float](repeating: 0, count: audio.count)
        if !audio.isEmpty {
            if let lookback = preLookback {
                pre[0] = audio[0] - Self.preemphasisCoeff * lookback
            } else {
                pre[0] = audio[0]
            }
            for n in 1..<audio.count {
                pre[n] = audio[n] - Self.preemphasisCoeff * audio[n - 1]
            }
        }
        // 2. STFT magnitude (n_fft=800, hop=200, periodic Hann, center=true).
        let stftMag = computeSTFTMagnitude(pre)
        let nBins = Self.nFFT / 2 + 1
        let T = stftMag.isEmpty ? 0 : stftMag.count / nBins
        // 3. Linear → mel: melBasis @ |STFT|. melBasis is (numMels × nBins).
        var mel = [Float](repeating: 0, count: Self.numMels * T)
        if T > 0 {
            mel.withUnsafeMutableBufferPointer { mb in
                Self.melBasis.withUnsafeBufferPointer { bb in
                    stftMag.withUnsafeBufferPointer { sb in
                        cblas_sgemm(
                            CblasRowMajor, CblasNoTrans, CblasNoTrans,
                            Int32(Self.numMels), Int32(T), Int32(nBins),
                            1.0,
                            bb.baseAddress, Int32(nBins),
                            sb.baseAddress, Int32(T),
                            0.0,
                            mb.baseAddress, Int32(T)
                        )
                    }
                }
            }
        }
        // 4. Amp → dB: 20 * log10(max(min_level, mel)) - ref_level_db.
        let minLevel = Float(exp(Self.minLevelDB / 20.0 * log(10.0)))
        for i in 0..<mel.count {
            let v = max(minLevel, mel[i])
            mel[i] = 20.0 * log10f(v) - Float(Self.refLevelDB)
        }
        // 5. Symmetric normalization:
        //    clip(8 * (S + 100) / 100 - 4, -4, 4).
        let maxAbs = Float(Self.maxAbsValue)
        let invDB = 1.0 / Float(-Self.minLevelDB)
        for i in 0..<mel.count {
            let v = (2.0 * maxAbs) * ((mel[i] - Float(Self.minLevelDB)) * invDB) - maxAbs
            mel[i] = min(maxAbs, max(-maxAbs, v))
        }
        return mel
    }

    /// Magnitude STFT: returns `(nBins × T)` float32 (row-major).
    ///
    /// Default: 1024-point vDSP FFT (zero-padded from 800). Per-call
    /// cost ~1 µs per STFT frame.
    ///
    /// Opt-in via `BITHUMAN_MEL_FFT=bluestein`: 800-point Bluestein /
    /// chirp-z DFT, bit-matching `numpy.fft.rfft(800)`. ~15 µs per
    /// STFT frame (15× more expensive). Available so the cross-SDK
    /// comparator can isolate FFT-length contributions to mel drift,
    /// but on its own doesn't close the residual face-area PSNR gap
    /// — the Slaney mel basis, log-norm constants, and streaming-vs-
    /// batch buffer state are all separate drift sources we'd need
    /// to align before the byte-exact mel pipeline pays off.
    ///
    /// ALGO-NOTE-1: the 1024-pt zero-pad has a built-in cost — its
    /// spectrum is a denser sampling than the 800-pt DFT, so each
    /// mel-bin reading drifts ~1 LSB from numpy. The encoder is
    /// trained against the 800-pt grid and is robust to small
    /// resolution mismatches in practice. Bench-validated:
    /// face-area PSNR ~22 dB either way; visually identical.
    private static func computeSTFTMagnitude(_ audio: [Float]) -> [Float] {
        let useBluestein = ProcessInfo.processInfo.environment["BITHUMAN_MEL_FFT"] == "bluestein"
        if useBluestein {
            return computeSTFTMagnitudeBluestein(audio)
        }
        return computeSTFTMagnitudePow2(audio)
    }

    /// 1024-pt zero-padded FFT — fast path.
    private static func computeSTFTMagnitudePow2(_ audio: [Float]) -> [Float] {
        let nFFT = Self.nFFT
        let hop = Self.hopSize
        let nBins = nFFT / 2 + 1
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        for i in 0..<audio.count { padded[pad + i] = audio[i] }
        if padded.count < nFFT { return [] }
        let T = 1 + (padded.count - nFFT) / hop

        guard let setup = vDSP_create_fftsetup(Self.fftLog2N, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: nBins * T)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let fftSize = Self.fftSize
        let half = fftSize / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        let window = Self.hannWindow
        var frame = [Float](repeating: 0, count: fftSize)
        var mag = [Float](repeating: 0, count: nBins * T)

        for t in 0..<T {
            let off = t * hop
            for i in 0..<nFFT {
                frame[i] = padded[off + i] * window[i]
            }
            for i in nFFT..<fftSize { frame[i] = 0 }

            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: half
                        ) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, Self.fftLog2N, FFTDirection(FFT_FORWARD))

                    let dc = abs(rp.baseAddress![0]) * 0.5
                    mag[0 * T + t] = dc
                    let kMax = min(half - 1, nBins - 1)
                    for k in 1...kMax {
                        let re = rp.baseAddress![k] * 0.5
                        let im = ip.baseAddress![k] * 0.5
                        mag[k * T + t] = sqrtf(re * re + im * im)
                    }
                    if nBins > half {
                        let nyq = abs(ip.baseAddress![0]) * 0.5
                        mag[half * T + t] = nyq
                    }
                }
            }
        }
        return mag
    }

    /// 800-pt Bluestein DFT — opt-in path used by the cross-SDK
    /// comparator to byte-match `numpy.fft.rfft(800)`. About 15× more
    /// expensive per STFT frame than the default; not enabled by
    /// default because it doesn't on its own close the residual
    /// face-area PSNR gap.
    private static func computeSTFTMagnitudeBluestein(_ audio: [Float]) -> [Float] {
        let nFFT = Self.nFFT
        let hop = Self.hopSize
        let nBins = nFFT / 2 + 1
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        for i in 0..<audio.count { padded[pad + i] = audio[i] }
        if padded.count < nFFT { return [] }
        let T = 1 + (padded.count - nFFT) / hop

        let window = Self.hannWindow
        var frame = [Float](repeating: 0, count: nFFT)
        var bins = [Float](repeating: 0, count: nBins)
        var mag = [Float](repeating: 0, count: nBins * T)
        let dft = Self.bluestein800

        for t in 0..<T {
            let off = t * hop
            for i in 0..<nFFT { frame[i] = padded[off + i] * window[i] }
            frame.withUnsafeBufferPointer { fp in
                bins.withUnsafeMutableBufferPointer { bp in
                    dft.magnitude(input: fp.baseAddress!, output: bp.baseAddress!)
                }
            }
            for k in 0..<nBins { mag[k * T + t] = bins[k] }
        }
        return mag
    }

    // MARK: - Slaney mel basis

    private static func computeSlaneyMelBasis() -> [Float] {
        let n = numMels
        let nBins = nFFT / 2 + 1
        let melMin = hzToMelSlaney(fmin)
        let melMax = hzToMelSlaney(fmax)
        var melPoints = [Double](repeating: 0, count: n + 2)
        for i in 0..<(n + 2) {
            let t = Double(i) / Double(n + 1)
            melPoints[i] = melMin + (melMax - melMin) * t
        }
        var hzPoints = [Double](repeating: 0, count: n + 2)
        for i in 0..<(n + 2) { hzPoints[i] = melToHzSlaney(melPoints[i]) }

        var fftFreqs = [Double](repeating: 0, count: nBins)
        let sr = Double(sampleRate)
        for k in 0..<nBins {
            fftFreqs[k] = Double(k) * sr / Double(nFFT)
        }

        var weights = [Float](repeating: 0, count: n * nBins)
        for i in 0..<n {
            let lo = hzPoints[i]
            let mid = hzPoints[i + 1]
            let hi = hzPoints[i + 2]
            let invLow = 1.0 / (mid - lo)
            let invHigh = 1.0 / (hi - mid)
            let enorm = 2.0 / (hi - lo)
            for k in 0..<nBins {
                let f = fftFreqs[k]
                let lower = (f - lo) * invLow
                let upper = (hi - f) * invHigh
                let w = max(0.0, min(lower, upper))
                weights[i * nBins + k] = Float(w * enorm)
            }
        }
        return weights
    }

    private static func hzToMelSlaney(_ hz: Double) -> Double {
        let fSp = 200.0 / 3.0
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logstep = log(6.4) / 27.0
        if hz >= minLogHz {
            return minLogMel + log(hz / minLogHz) / logstep
        }
        return hz / fSp
    }
    private static func melToHzSlaney(_ mel: Double) -> Double {
        let fSp = 200.0 / 3.0
        let minLogHz = 1000.0
        let minLogMel = minLogHz / fSp
        let logstep = log(6.4) / 27.0
        if mel >= minLogMel {
            return minLogHz * exp(logstep * (mel - minLogMel))
        }
        return fSp * mel
    }

    // MARK: - Tiny helpers

    private func chunkRMS(_ buf: [Float]) -> Float {
        guard !buf.isEmpty else { return 0 }
        var sum: Float = 0
        buf.withUnsafeBufferPointer { p in
            vDSP_dotpr(p.baseAddress!, 1, p.baseAddress!, 1, &sum, vDSP_Length(buf.count))
        }
        return sqrtf(sum / Float(buf.count))
    }

    private static func extractRegion(
        from src: [UInt8], baseW: Int, baseH: Int,
        x: Int, y: Int, w: Int, h: Int
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for row in 0..<h {
            guard y + row >= 0, y + row < baseH else { continue }
            let srcRow = (y + row) * baseW * 3 + x * 3
            let dstRow = row * w * 3
            for col in 0..<w {
                guard x + col >= 0, x + col < baseW else { continue }
                let s = srcRow + col * 3
                let d = dstRow + col * 3
                out[d + 0] = src[s + 0]
                out[d + 1] = src[s + 1]
                out[d + 2] = src[s + 2]
            }
        }
        return out
    }

    private static func writeRegion(
        into dst: inout [UInt8], baseW: Int, baseH: Int,
        region: [UInt8], x: Int, y: Int, w: Int, h: Int
    ) {
        for row in 0..<h {
            guard y + row >= 0, y + row < baseH else { continue }
            let dstRow = (y + row) * baseW * 3 + x * 3
            let srcRow = row * w * 3
            for col in 0..<w {
                guard x + col >= 0, x + col < baseW else { continue }
                let d = dstRow + col * 3
                let s = srcRow + col * 3
                dst[d + 0] = region[s + 0]
                dst[d + 1] = region[s + 1]
                dst[d + 2] = region[s + 2]
            }
        }
    }

    // MARK: - Manifest extraction

    internal struct LipSyncMeta {
        let h5File: String
        let basesFile: String
        let patchesFile: String
        let cropBbox: (x1: Int, y1: Int, x2: Int, y2: Int)
        let numClusters: Int
        let numSourceFrames: Int
        /// `manifest.videos[*].type == "LoopingVideo"` (the only type
        /// the v2 fixtures use for talking sources). When `true`, the
        /// video is meant to play in a loop; the bases archive holds
        /// `num_source_frames` distinct frames that we walk through.
        let isLoopingVideo: Bool
        /// `manifest.videos[*].single_direction`. `false` (the default
        /// for `LoopingVideo`) means PING-PONG playback: forward 0 →
        /// N-1 → backward N-2 → ... → 1 → forward 0 → 1 → ... — the
        /// seamless loop Python's video_graph implements (see
        /// `bithuman/video_graph/clip.py` lines 485-491). `true`
        /// means hard-cut wrap-around (forward 0 → N-1 → 0 →
        /// 1 → ...).
        let singleDirection: Bool
    }

    /// Locate the first video in the manifest's `videos` map that carries
    /// `lip_sync` metadata. For Phase 1 we don't switch between multiple
    /// talking videos at runtime (the video graph's job — out of scope per
    /// algo spec §4 "Action Triggers"), so the first match is sufficient.
    internal static func firstVideoWithLipSync(
        in manifest: [String: Any]
    ) throws -> (videoFile: String, lipSync: LipSyncMeta) {
        let videos = manifest["videos"]
        var entries: [(String, [String: Any])] = []
        if let dict = videos as? [String: Any] {
            for (k, v) in dict {
                if let vmeta = v as? [String: Any] { entries.append((k, vmeta)) }
            }
        } else if let arr = videos as? [[String: Any]] {
            for vmeta in arr {
                let name = (vmeta["name"] as? String) ?? ""
                entries.append((name, vmeta))
            }
        }
        for (_, vmeta) in entries {
            guard let lip = vmeta["lip_sync"] as? [String: Any] else { continue }
            guard let h5 = lip["h5_file"] as? String,
                  let bases = lip["bases_file"] as? String,
                  let patches = lip["patches_file"] as? String else {
                throw Error.malformedManifest(
                    "lip_sync entry missing one of {h5_file, bases_file, patches_file}"
                )
            }
            let cropArr: [Int] = (lip["crop_bbox"] as? [Int]) ?? {
                let raw = lip["crop_bbox"] as? [Any] ?? []
                return raw.compactMap { ($0 as? NSNumber)?.intValue }
            }()
            guard cropArr.count == 4 else {
                throw Error.malformedManifest(
                    "lip_sync.crop_bbox must be 4 ints; got \(cropArr)"
                )
            }
            let nc: Int = (lip["num_clusters"] as? Int)
                ?? ((lip["num_clusters"] as? NSNumber)?.intValue ?? 0)
            let ns: Int = (lip["num_source_frames"] as? Int)
                ?? ((lip["num_source_frames"] as? NSNumber)?.intValue ?? 0)
            guard nc > 0 else {
                throw Error.malformedManifest("lip_sync.num_clusters must be > 0")
            }
            let videoFile = (vmeta["video_file"] as? String) ?? ""
            guard !videoFile.isEmpty else {
                throw Error.malformedManifest("video has lip_sync but no video_file")
            }
            // Optional fields: video `type` and `single_direction`.
            // Default to ping-pong-looping behavior since that's what
            // the v2 fixtures all use.
            let videoType = (vmeta["type"] as? String) ?? "LoopingVideo"
            let singleDir: Bool
            if let b = vmeta["single_direction"] as? Bool {
                singleDir = b
            } else if let n = vmeta["single_direction"] as? NSNumber {
                singleDir = n.boolValue
            } else {
                singleDir = false
            }
            return (
                videoFile,
                LipSyncMeta(
                    h5File: h5,
                    basesFile: bases,
                    patchesFile: patches,
                    cropBbox: (cropArr[0], cropArr[1], cropArr[2], cropArr[3]),
                    numClusters: nc,
                    numSourceFrames: ns,
                    isLoopingVideo: videoType == "LoopingVideo",
                    singleDirection: singleDir
                )
            )
        }
        throw Error.noLipSyncVideo
    }
}
