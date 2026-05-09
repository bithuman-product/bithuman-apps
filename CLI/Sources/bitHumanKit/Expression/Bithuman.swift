import AVFoundation
import CoreGraphics
import Foundation
@_implementationOnly import MLX

/// Audio-driven avatar animation runtime. The public SDK entry
/// point — construct via ``create(modelPath:)``, push speech audio
/// through ``pushAudio(audio24k:audio16k:)``, and dequeue rendered
/// chunks via ``tryDequeueChunk()`` on a 25 FPS display timer.
///
/// **Responsibilities:**
/// - Audio-dispatch state: pending 16 kHz + 24 kHz buffers, the
///   in-flight flag, the generation epoch used to discard chunks
///   from before an interrupt, and the tail-flush gate.
/// - Chunk queue + MLX pipeline + VAE decoder + VAE encoder,
///   kept behind an internal ``PipelineBox`` consumers never see.
///
/// **Consumer responsibilities (not ours):**
/// - Display timer / CALayer frame handoff — the 25 FPS draw loop
///   is the app's job; this actor just hands you chunks.
/// - Cadence for ``generateIdleChunk()`` — schedule it yourself
///   whenever the avatar is idle.
///
/// **Note on auth:** the upstream `bithuman-expression-swift`
/// library exposes a metered `create(modelPath:apiSecret:…)` that
/// authenticates against the bitHuman billing service. bithuman-cli
/// ships the unmetered factory only — distribution is open and
/// consumers don't need an API key.
public actor Bithuman {

    // MARK: - Plumbing

    /// Chunk queue + MLX state container. Internal — consumers never
    /// need direct access; everything flows through the public
    /// ``Bithuman`` actor API.
    internal nonisolated let pipelineBox: PipelineBox

    /// Runs one pipeline dispatch on the background queue. Internal
    /// DI seam so tests can inject a mock processor without real MLX
    /// weights. External consumers always get the default.
    internal typealias ChunkProcessor = @Sendable (
        _ box: PipelineBox,
        _ audio16: [Float],
        _ audio24: [Float],
        _ isIdle: Bool
    ) -> TimedChunk?

    /// Default ChunkProcessor used in production — forwards to the
    /// real `PipelineOps.processChunk`.
    internal static let defaultChunkProcessor: ChunkProcessor = { box, a16, a24, isIdle in
        PipelineOps.processChunk(box: box, audio16: a16, audio24: a24, isIdle: isIdle)
    }

    private let chunkProcessor: ChunkProcessor

    /// Internal init used by the factory methods and by the SDK's own
    /// tests / benchmarks / examples. Takes ownership of the extracted
    /// ``ExpressionModel`` so the temp directory outlives every frame
    /// the pipeline will ever render from it.
    internal init(
        pipelineBox: PipelineBox,
        chunkProcessor: @escaping ChunkProcessor = Bithuman.defaultChunkProcessor,
        expressionModel: ExpressionModel? = nil
    ) {
        self.pipelineBox = pipelineBox
        self.chunkProcessor = chunkProcessor
        self.expressionModel = expressionModel
    }

    /// Temp-directory owner for the extracted `.imx` contents. Held
    /// for the lifetime of the actor so the files the MLX pipeline
    /// mmaps stay on disk until ``shutdown()`` releases everything.
    /// Nil when the actor is constructed directly for testing.
    private let expressionModel: ExpressionModel?

    // MARK: - Convenience factories

    /// Result of ``Bithuman/create(modelPath:chunkProcessor:)``.
    public struct CreateResult: Sendable {
        /// The ready-to-use avatar runtime.
        public let bithuman: Bithuman
        /// The first static idle frame rendered from the loaded
        /// reference latent. Use as a backdrop while buffering starts.
        public let staticIdleImage: CGImage?
    }

    /// One-call bootstrap from a packed `.imx` avatar model file.
    ///
    /// The model file bundles everything the runtime needs: the
    /// animator, speech encoder, face encoder, face renderer, and a
    /// baked reference face. Build one with `bithuman pack` from the
    /// Python SDK; see the SDK README for the exact CLI.
    ///
    /// > Important: Expression models only run on macOS with Apple
    /// > Silicon (M3 or later). The rendering pipeline needs the
    /// > GPU + Neural Engine bandwidth that M1 and M2 can't sustain
    /// > at 25 FPS.
    ///
    /// - Parameters:
    ///   - modelPath: Path to a `.imx` file produced by `bithuman pack`
    ///     with `model_type: "expression"`.
    ///   - chunkProcessor: Override for tests. Production callers can
    ///     leave as the default.
    /// - Throws: ``BithumanCreateError/invalidModelFile(message:)`` when
    ///   the container is malformed or isn't an Expression model;
    ///   ``BithumanCreateError/loadFailed(message:)`` when weight
    ///   loading fails.
    ///
    /// Render quality preset. ``medium`` is the realtime-safe default
    /// used by the streaming pipeline. ``high`` roughly doubles render
    /// time for visibly crisper output — recommended for offline video
    /// generation on hardware with headroom.
    public enum Quality: String, Sendable {
        /// Realtime-safe default. ~1.8× realtime at 384×384 output,
        /// ~1.1× at 512×512 on M5. Use for live streaming.
        case medium
        /// Higher visual quality. ~1.0× realtime at 384×384, ~0.7×
        /// at 512×512 on M5. Sub-realtime at 512 — offline video
        /// generation only unless the host is markedly faster than
        /// an M5.
        case high

        /// Number of rendering passes this quality level runs. Exposed
        /// for diagnostics / profiling; callers should use the enum
        /// case, not this integer.
        public var nSteps: Int {
            switch self {
            case .medium: return 2
            case .high:   return 4
            }
        }
    }

    /// Identity — the face the avatar animates.
    ///
    /// Separated from the model so developers can ship one ~3.5 GB
    /// `.imx` bundle (weights only) and parameterize the avatar face
    /// with either a portrait image or a pre-encoded latent. Mental
    /// model: the model is the *capability*; the identity is the
    /// *look*.
    public enum Identity: Sendable {
        /// Use the default identity baked into the `.imx` bundle at
        /// pack time. Errors at ``setIdentity(_:)`` if the bundle
        /// has no baked-in default (v2 weights-only bundles).
        case `default`
        /// Encode a portrait image on the fly via the face-encoder
        /// shipping in the `.imx`. Adds ~200-500 ms on M3+ at load /
        /// swap time but lets callers ship unlimited agent faces
        /// from a single bundle.
        case image(URL)
        /// Use a pre-encoded identity `.npy`. Zero encoding cost at
        /// load — produce these via the `encode-ref-latent` tool, or
        /// cache the output of a previous ``Identity/image(_:)`` load.
        case preEncoded(URL)
    }

    /// Boot the avatar runtime from a `.bit` model file.
    ///
    /// The model file bundles everything the runtime needs: the
    /// animator, speech encoder, face encoder, face renderer, and a
    /// baked default reference face. bitHumanKit downloads this file from
    /// bitHuman's CDN on first `bithuman-cli video` launch and caches it
    /// under `~/.cache/bithuman/expression/`.
    ///
    /// Hardware-gates on M3+ Apple Silicon — throws
    /// ``BithumanCreateError/unsupportedHardware(reason:)`` on M1/M2
    /// or Intel rather than crashing somewhere in MLX land.
    ///
    /// - Parameters:
    ///   - modelPath: Path to the `.bit` (or `.imx`) container.
    ///   - identity: Which face the avatar wears. Defaults to the
    ///     baked-in face from the model file. Pass `.image(URL)` to
    ///     animate a custom portrait (auto-cropped via Vision face
    ///     detection; ~200–500 ms encoding on M3+).
    ///   - quality: ``Quality/medium`` is the realtime-safe default.
    public static func create(
        modelPath: URL,
        identity: Identity = .default,
        quality: Quality = .medium
    ) throws -> CreateResult {
        try _create(
            modelPath: modelPath,
            identity: identity,
            quality: quality,
            chunkProcessor: Bithuman.defaultChunkProcessor
        )
    }

    /// Internal factory with a `chunkProcessor` injection seam for
    /// unit tests. External consumers go through ``create(modelPath:identity:quality:)``,
    /// which forwards to this with the production processor.
    internal static func _create(
        modelPath: URL,
        identity: Identity = .default,
        quality: Quality = .medium,
        chunkProcessor: @escaping ChunkProcessor
    ) throws -> CreateResult {
        // Hardware gate first — cheaper than touching weights, and
        // surfaces a clean typed error so callers can route users
        // to the support matrix rather than hitting a `fatalError`
        // somewhere in MLX land.
        if case .unsupported(let reason) = HardwareSupport.check() {
            throw BithumanCreateError.unsupportedHardware(reason: reason)
        }

        let model = try loadExpressionModel(at: modelPath, nSteps: quality.nSteps)
        let box = PipelineBox()
        let (loadResult, errorMessage) = PipelineOps.load(box: box, paths: model.paths)
        if let errorMessage {
            model.cleanup()
            throw BithumanCreateError.loadFailed(message: errorMessage)
        }
        // Apply the override identity (if any) synchronously so the
        // first frame we hand back already animates the right face.
        var staticIdle = loadResult?.staticIdleImage
        if case .default = identity {
            // .default → the pipeline is already loaded with the
            // bundle's baked-in reference latent. Nothing to do.
        } else {
            do {
                let swapResult = try Self.applyIdentityOverride(identity, box: box)
                if let idle = swapResult?.staticIdleImage {
                    staticIdle = idle  // regenerate idle frame against the new face
                }
            } catch {
                model.cleanup()
                throw BithumanCreateError.loadFailed(message: "identity override failed: \(error)")
            }
        }
        return CreateResult(
            bithuman: Bithuman(
                pipelineBox: box,
                chunkProcessor: chunkProcessor,
                expressionModel: model
            ),
            staticIdleImage: staticIdle
        )
    }

    /// Wrap ``ExpressionModel/load(from:nSteps:)`` errors in
    /// ``BithumanCreateError/invalidModelFile(message:)`` so the caller
    /// sees one typed error surface regardless of how the container
    /// is broken.
    /// Replace the currently-loaded identity without restarting the
    /// pipeline or reloading weights. Takes ~200-500 ms on M3+ for
    /// the `.image(_)` case (face-encoder pass); instant for
    /// `.preEncoded(_)`. Calling with `.default` when the bundle has
    /// a baked-in default restores that; with a v2 weights-only
    /// bundle (no baked default) `.default` throws.
    ///
    /// In-flight audio is associated with the old identity — callers
    /// who want a clean swap should call ``interrupt()`` first, wait
    /// for the in-flight chunk to drain, then `setIdentity`.
    /// Returns the newly rendered static idle frame for the new
    /// identity when one is available — callers (Halo) use it to
    /// swap the display layer's backdrop before the first real
    /// audio-driven frame lands. `nil` for pre-encoded identities
    /// (no re-render happens) and for `.default` (baseline
    /// restoration does not currently regenerate the idle frame).
    @discardableResult
    public func setIdentity(_ identity: Identity) async throws -> CGImage? {
        // Post-shutdown no-op. The pipeline box's weights are nil'd
        // out in `shutdown()`, so swapIdentity would throw
        // `.pipelineNotReady` anyway — returning nil is a cleaner
        // contract than making callers distinguish that from a real
        // identity-load failure.
        if didShutdown { return nil }
        let result = try Self.applyIdentityOverride(identity, box: pipelineBox)
        return result?.staticIdleImage
    }

    /// Synchronous implementation of the identity-swap primitive.
    /// Shared by ``create(modelPath:identity:quality:chunkProcessor:)``
    /// and ``setIdentity(_:)``.
    private static func applyIdentityOverride(
        _ identity: Identity,
        box: PipelineBox
    ) throws -> PipelineOps.LoadResult? {
        switch identity {
        case .default:
            // Caller should have guarded this branch (no-op at load,
            // no effect at runtime without a cached baseline). We
            // reach here only when setIdentity(.default) is called;
            // error out so the bug surfaces instead of silently
            // doing nothing.
            throw IdentityError.noBaselineForDefault
        case .image(let url):
            return try PipelineOps.swapIdentity(box: box, imageURL: url)
        case .preEncoded(let url):
            try PipelineOps.swapIdentity(box: box, preEncodedLatentURL: url)
            return nil  // no new staticIdleImage — caller keeps the previous one
        }
    }

    /// Errors specific to identity management.
    public enum IdentityError: Swift.Error, CustomStringConvertible {
        /// `setIdentity(.default)` was called but no baseline identity
        /// is cached (the bundle was weights-only, or `.default` was
        /// called without ever having swapped to a real identity).
        case noBaselineForDefault

        public var description: String {
            switch self {
            case .noBaselineForDefault:
                return "setIdentity(.default) has no baseline identity to restore"
            }
        }
    }

    private static func loadExpressionModel(
        at url: URL,
        nSteps: Int = Quality.medium.nSteps
    ) throws -> ExpressionModel {
        do {
            return try ExpressionModel.load(from: url, nSteps: nSteps)
        } catch {
            throw BithumanCreateError.invalidModelFile(message: "\(error)")
        }
    }

    // MARK: - Public lifecycle (Phase 0 draft API)

    /// Output frame dimensions. Mirrors Python's `get_frame_size()`.
    ///
    /// Derived from the reference-face resolution the model was packed
    /// with — 384×384, 448×448, or 512×512 are the standard sizes.
    /// Callers that pack with a different face-renderer + matching
    /// reference-face get the corresponding output size automatically.
    /// Defaults to 512×512 if the pipeline hasn't loaded yet (the
    /// `ready` event on the daemon sends this, but chunk headers
    /// carry the actual per-chunk dims anyway).
    public nonisolated var frameSize: FrameSize {
        guard let pipeline = pipelineBox.pipeline else {
            return FrameSize(width: 512, height: 512)
        }
        let s = pipeline.refLatent.dim(2) * 32
        return FrameSize(width: s, height: s)
    }

    public struct FrameSize: Sendable, Equatable {
        public let width: Int
        public let height: Int
    }

    /// Lifecycle hook for the Phase 0 public API. Mirrors Python's
    /// `await runtime.start()`. Currently a no-op — models are loaded
    /// via `PipelineOps.load` which the Halo caller invokes before
    /// reaching the streaming API. Phase 2 folds model loading into
    /// `start()` so the external SDK consumer has a single entry
    /// point.
    public func start() async throws {
        // Placeholder for Phase 2. Halo's init sequence already runs
        // PipelineOps.load; the public SDK will call it here.
    }

    /// Release GPU memory and cancel in-flight inference. Mirrors
    /// the Phase 0 draft's `shutdown()`. Currently idempotent +
    /// best-effort: clears pending buffers and the chunk queue so
    /// no further frames leak to the display. MLX weight release
    /// lands in Phase 2 when `start()` owns model loading.
    ///
    /// After `shutdown()` returns:
    /// - The MLX pipeline + ANE decoder references are released — the
    ///   underlying ~3.5 GB of weight memory is freed by ARC rather
    ///   than waiting for the actor itself to deinit.
    /// - All subsequent mutating calls (`pushAudio`, `flush`,
    ///   `flushTailIfNeeded`, `setIdentity`, …) become silent no-ops.
    ///   `tryDequeueChunk` keeps working while the consumer drains
    ///   any already-queued chunks.
    /// - Repeat calls are idempotent.
    public func shutdown() async {
        if didShutdown { return }
        didShutdown = true

        pendingAudio16.removeAll(keepingCapacity: true)
        pendingAudio24.removeAll(keepingCapacity: true)
        tailFlushedThisResponse = false
        pipelineBox.clearChunks()
        publishSnapshot()

        // Release MLX / ANE / VAE handles serially on the pipeline
        // queue so any in-flight dispatch finishes first. Without
        // this, `shutdown()` left the pipeline alive and a stray
        // `pushAudio` call would happily run inference against the
        // already-deleted temp-dir-backed weights.
        //
        // After dropping the Swift references we also explicitly
        // clear MLX's GPU allocator cache — MLX pools freed buffers
        // for reuse, so the ~3 GB of DiT weights stay resident in
        // the allocator even after their owner is released. The
        // process-memory drop observable from `task_info` is what
        // users actually notice; the cache clear is what makes it
        // show up.
        let box = pipelineBox
        // Drain the DiT queue first — any in-flight DiT completes
        // against the (still-live) pipeline, then we can nil it.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.queue.async {
                let hadPipeline = box.pipeline != nil
                box.pipeline = nil
                box.decoder = nil
                box.encoder = nil
                // Only trigger MLX's allocator cache clear if we
                // actually used MLX — unit tests construct Bithuman
                // with a test processor that never loads a pipeline,
                // and calling clearCache cold tries to load the Metal
                // library (which fails outside an SPM Metal bundle).
                if hadPipeline {
                    MLX.Memory.clearCache()
                }
                cont.resume()
            }
        }
        // Also drain the decode queue. In pipelined mode a Stage 2
        // may still be running on the ANE after the DiT queue has
        // quiesced — blocking here makes `shutdown()`'s return a
        // guarantee that no background work is outstanding, which
        // callers rely on for bounded teardown (e.g. tagging the
        // output file, releasing the temp dir).
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            box.decodeQueue.async { cont.resume() }
        }
        // Delete the extracted temp directory last — the MLX / CoreML
        // handles captured by the pipeline box above pointed at those
        // files until the nil-out above dropped them.
        expressionModel?.cleanup()
    }

    /// Sentinel flagged by ``shutdown()`` to make every mutating entry
    /// point a no-op afterwards. Actor-isolated, so the read/write
    /// serialises with every other mutation without needing a lock.
    private var didShutdown = false

    // MARK: - Nonisolated snapshot for the display tick
    //
    // Halo's 25 FPS onTick runs on the main actor and needs to peek
    // at dispatch state (inFlight, pendingAudio counts, tail-flush
    // gate) several times per tick. Doing that through `await` on
    // this actor would cost an actor hop per read — 100+ async
    // boundary crossings per second for advisory checks.
    //
    // Instead we maintain a `Snapshot` struct updated inside every
    // actor-isolated mutation and read via a nonisolated getter
    // that takes a cheap lock. The snapshot is advisory: reads
    // might race with a concurrent mutation by one tick, but every
    // decision it gates (tail-flush, burst-end) is idempotent or
    // self-correcting on the next tick.
    //
    // Commit D replaces this with a proper Frame-stream API; the
    // snapshot goes away once the display consumes frames via the
    // stream rather than peeking at dispatch internals.

    public struct Snapshot: Sendable {
        public var inFlight: Bool = false
        public var pendingAudio16Count: Int = 0
        public var pendingAudio24Count: Int = 0
        public var tailFlushedThisResponse: Bool = false
        /// Monotonic counter bumped by `interrupt()` and
        /// `prepareForIdentitySwap()`. Exposed so tests can observe
        /// epoch transitions; a display-side consumer has no reason
        /// to look at this.
        public var generationEpoch: Int = 0
    }

    private let snapshotLock = NSLock()
    nonisolated(unsafe) private var _snapshot: Snapshot = Snapshot()

    /// Nonisolated snapshot of dispatch state. Safe to call from any
    /// actor. Returns a value copy; holds the lock only long enough
    /// to read the backing struct.
    public nonisolated var snapshot: Snapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return _snapshot
    }

    // MARK: - Chunk consumption

    /// Synchronous non-blocking poll. Returns the oldest ready chunk,
    /// or nil if the queue is empty. This is the path Halo's 25 FPS
    /// display tick uses — sync read, no actor hop.
    ///
    /// Phase 2 adds a Frame-level `run() -> AsyncThrowingStream<Frame>`
    /// for external consumers who don't have a sync tick driving them.
    public nonisolated func tryDequeueChunk() -> TimedChunk? {
        pipelineBox.dequeueChunk()
    }

    /// Current chunk-queue depth. Used by Halo's 2-chunk first-burst
    /// gate to hold the first frame of a burst until DiT has generated
    /// enough headroom for a slow second dispatch not to underflow the
    /// display.
    public nonisolated var chunkQueueCount: Int {
        pipelineBox.chunkCount
    }

    private func publishSnapshot() {
        let snap = Snapshot(
            inFlight: inFlight,
            pendingAudio16Count: pendingAudio16.count,
            pendingAudio24Count: pendingAudio24.count,
            tailFlushedThisResponse: tailFlushedThisResponse,
            generationEpoch: generationEpoch
        )
        snapshotLock.lock()
        _snapshot = snap
        snapshotLock.unlock()
    }

    // MARK: - Actor-isolated state

    /// Rolling 16 kHz buffer fed to wav2vec2. Advanced by
    /// `advanceSamples16` per dispatch so a `MOTION_FRAMES_NUM`
    /// tail overlaps into the next window for temporal continuity.
    private var pendingAudio16: [Float] = []

    /// Matching 24 kHz buffer carried alongside so each TimedChunk
    /// can ship the exact audio slice that generated its frames.
    private var pendingAudio24: [Float] = []

    /// Dispatch-in-flight gate. Only one chunk compute at a time —
    /// MLX + ANE are serialized through `pipelineBox.queue`.
    private var inFlight = false

    /// Monotonic epoch bumped on interrupt + identity swap. Each
    /// dispatched chunk captures the epoch at dispatch time; results
    /// arriving with a stale epoch are discarded without enqueue so
    /// pre-interrupt video never leaks into post-interrupt playback.
    private var generationEpoch: Int = 0

    /// One-shot gate: tail-flush runs at most once per response, reset
    /// by `pushAudio` (fresh audio = new response or mid-response).
    private var tailFlushedThisResponse = false

    /// Concurrent-MLX gate. When `true`, `maybeDispatchChunk` defers
    /// starting a new DiT dispatch so wav2vec2 + DiT don't contend
    /// with the caller's other MLX workload (typically an LLM token
    /// loop) for the single Metal command queue. Audio continues to
    /// buffer in `pendingAudio16/24`; `setLLMGenerating(false)` drains
    /// the backlog on the falling edge. Callers that don't serialize
    /// against another MLX model can leave this untouched (default
    /// false) and the gate is a no-op.
    private var isLLMGenerating = false

    // MARK: - Derived constants (from FlashHeadCore/Constants.swift)

    /// Full dispatch window in 16 kHz samples (33 frames × 16 kHz / 25 FPS).
    private let dispatchSamples16: Int = FRAME_NUM * SAMPLE_RATE / TGT_FPS

    /// Full dispatch window in 24 kHz samples (33 frames × 24 kHz / 25 FPS).
    private let dispatchSamples24: Int = FRAME_NUM * 24_000 / TGT_FPS

    /// Advance per dispatch at 16 kHz (24 frames × 16 kHz / 25 FPS).
    /// The remaining 9 frames stay as motion overlap.
    private let advanceSamples16: Int = NEW_FRAMES_PER_CHUNK * SAMPLE_RATE / TGT_FPS

    /// Advance per dispatch at 24 kHz.
    private let advanceSamples24: Int = NEW_FRAMES_PER_CHUNK * 24_000 / TGT_FPS

    /// Safety cap so a stalled dispatch can't balloon memory — drop
    /// oldest samples past 10 min worth. The old 10 s cap silently
    /// truncated video-generation callers who pushed a full utterance
    /// in one shot, so they only got the last 10 s rendered. 10 min
    /// is still a hard ceiling that prevents unbounded memory growth
    /// but accommodates realistic batch + streaming workloads.
    private static let maxPendingSamples16 = SAMPLE_RATE * 600

    /// Matching cap at 24 kHz.
    private static let maxPendingSamples24 = 24_000 * 600

    // MARK: - Audio input

    /// Queue real speech audio. `samples24` carries the audio slice
    /// the speakers will play; `samples16` is wav2vec2's input. They
    /// cover the same time span — the SDK resamples internally in
    /// future commits, but for now Halo pre-resamples and passes both.
    ///
    /// This method only manages the buffers and kicks dispatch. It
    /// does NOT touch display-side state (isSpeaking, lastRealPushTime)
    /// — those remain on the main actor in AvatarStreamController.
    public func pushAudio(
        audio24k samples24: [Float],
        audio16k samples16: [Float]
    ) async throws {
        // Post-shutdown entry points are silent no-ops. Consumers
        // treat `shutdown()` as terminal — we don't want to throw and
        // force a new error-handling branch on every call site that
        // already handles the happy path's exceptions.
        if didShutdown { return }

        tailFlushedThisResponse = false
        pendingAudio16.append(contentsOf: samples16)
        pendingAudio24.append(contentsOf: samples24)

        // Drop oldest samples past the safety cap.
        if pendingAudio16.count > Self.maxPendingSamples16 {
            pendingAudio16.removeFirst(pendingAudio16.count - Self.maxPendingSamples16)
        }
        if pendingAudio24.count > Self.maxPendingSamples24 {
            pendingAudio24.removeFirst(pendingAudio24.count - Self.maxPendingSamples24)
        }

        publishSnapshot()
        maybeDispatchChunk()
    }

    /// Signal audio-input completion for the current utterance.
    /// Mirrors the Python `AsyncBithuman.flush()` entry point.
    ///
    /// Resets the StreamingPipeline's chunk counter + motion-frames
    /// state so the NEXT burst's first dispatch emits a full 33-frame
    /// chunk 0. Without this reset, chunkIndex carries over and the
    /// next burst silently drops its first 9 frames (360 ms).
    public func flush() {
        if didShutdown { return }
        pendingAudio16.removeAll(keepingCapacity: true)
        pendingAudio24.removeAll(keepingCapacity: true)
        tailFlushedThisResponse = false
        publishSnapshot()

        let box = pipelineBox
        box.queue.async {
            box.pipeline?.reset()
        }
    }

    /// Mid-response barge-in. Invalidate everything in flight or in
    /// the chunk queue, reset the pipeline, bump the epoch so any
    /// dispatch currently running on `pipelineBox.queue` discards its
    /// result instead of enqueueing it.
    ///
    /// Display-side cleanup (currentChunk / burstInProgress /
    /// lastRenderedFrame) is the caller's concern — Halo's
    /// `AvatarStreamController.interruptSpeech()` invokes this after
    /// doing its own cleanup on the main actor.
    public func interrupt() {
        if didShutdown { return }
        generationEpoch &+= 1
        pendingAudio16.removeAll(keepingCapacity: true)
        pendingAudio24.removeAll(keepingCapacity: true)
        tailFlushedThisResponse = false
        pipelineBox.clearChunks()
        publishSnapshot()

        let box = pipelineBox
        box.queue.async {
            box.pipeline?.reset()
        }
    }

    /// Mark the LLM as entering or leaving its MLX generation loop.
    /// While `generating == true`, `maybeDispatchChunk` won't start a
    /// new DiT dispatch — wav2vec2 + DiT share the same Metal device
    /// as the LLM, and M3/M4 lack the bandwidth headroom to run both
    /// concurrently without the 25 FPS animator missing frames.
    /// On the falling edge we kick `maybeDispatchChunk` so any audio
    /// that buffered during generation drains immediately.
    public func setLLMGenerating(_ generating: Bool) {
        if didShutdown { return }
        let wasGenerating = isLLMGenerating
        isLLMGenerating = generating
        if wasGenerating && !generating {
            maybeDispatchChunk()
        }
    }

    /// Identity-swap hook. A new portrait has been VAE-encoded and
    /// the `StreamingPipeline.refLatent` has been replaced; any
    /// audio already buffered or any dispatch currently running was
    /// computed against the old latent and is now invalid.
    ///
    /// Does NOT reset the pipeline or clear the chunk queue —
    /// `PipelineOps.swapIdentity` already does both before calling
    /// this.
    public func prepareForIdentitySwap() {
        if didShutdown { return }
        generationEpoch &+= 1
        pendingAudio16.removeAll(keepingCapacity: true)
        pendingAudio24.removeAll(keepingCapacity: true)
        tailFlushedThisResponse = false
        publishSnapshot()
    }

    // MARK: - Tail flush (called from the display tick when audio goes quiet)

    /// Flush the response tail using low-amplitude noise padding
    /// rather than zero-padding. Wav2vec2 sees "ambient quiet" and
    /// the DiT emits a smooth closed-mouth final frame instead of
    /// the hard snap produced by literal silence.
    ///
    /// Only runs once per response, gated by `tailFlushedThisResponse`.
    /// The gate is only tripped when padding actually happens — an
    /// early call with pendingAudio still above dispatchSamples is a
    /// no-op that leaves the gate open for a later call to pad.
    public func flushTailIfNeeded() {
        if didShutdown { return }
        guard !tailFlushedThisResponse, !pendingAudio16.isEmpty else { return }

        let deficit16 = dispatchSamples16 - pendingAudio16.count
        let deficit24 = dispatchSamples24 - pendingAudio24.count
        // If buffers still have a full chunk's worth, natural dispatch
        // will consume them — don't pad yet, don't trip the gate.
        guard deficit16 > 0 || deficit24 > 0 else { return }
        tailFlushedThisResponse = true

        if deficit16 > 0 {
            // Pink-ish noise at ~-34 dB — matches the FlashHead idle
            // generator's ambient floor. Wav2vec2 recognizes it as
            // "quiet room" rather than true silence.
            var pad = [Float](repeating: 0, count: deficit16)
            var prev: Float = 0
            for i in 0..<deficit16 {
                let w = Float.random(in: -1...1)
                prev = 0.92 * prev + 0.08 * w
                pad[i] = prev * 0.02
            }
            pendingAudio16.append(contentsOf: pad)
        }

        if deficit24 > 0 {
            // Count-gating only; the audio the user actually hears
            // comes from the TTS path upstream, not this slice.
            pendingAudio24.append(contentsOf: [Float](repeating: 0, count: deficit24))
        }

        publishSnapshot()
        maybeDispatchChunk()
    }

    // MARK: - Dispatch

    /// Pipelined dispatch is on by default as of v0.6.4: Stage 1
    /// (wav2vec2 + DiT on the GPU) and Stage 2 (ANE decode +
    /// FrameConverter) run on separate dispatch queues so chunk N's
    /// ANE decode can overlap with chunk N+1's DiT on independent
    /// silicon. On M5 this cuts per-chunk inter-arrival by ~15% at
    /// p50 (513 ms → 434 ms) with zero quality impact — the math is
    /// identical, only the dispatch scheduling differs.
    ///
    /// `FH_DISABLE_PIPELINE=1` is a reverse kill switch that
    /// restores the pre-v0.6.4 single-queue path for diagnostic use.
    /// First-frame latency is unchanged in either mode; only the
    /// steady-state inter-arrival shifts.
    private static let pipelineDecodeEnabled: Bool = {
        ProcessInfo.processInfo.environment["FH_DISABLE_PIPELINE"] != "1"
    }()

    /// `inFlight` in the ``Snapshot`` is the OR of these two — a
    /// consumer draining via the snapshot wants to see "still
    /// working" until both DiT and decode are quiet.
    ///
    /// `decodeInFlight` is a counter rather than a flag because in
    /// the pipelined path a DiT dispatch can finish and submit the
    /// next chunk's decode while the previous chunk's decode is
    /// still on the decode queue. Only when the counter drops to
    /// zero is the decode lane truly idle.
    private var ditBusy = false
    private var decodeInFlight: Int = 0
    private var decodeBusy: Bool { decodeInFlight > 0 }

    private func maybeDispatchChunk() {
        // Cap how far ahead we render. Each queued chunk holds ~24 frames
        // of decoded latents + display surfaces; on iPhone the lower
        // per-app jetsam ceiling means runaway DiT-ahead-of-display burns
        // the headroom we need for the next inference. 4 chunks ≈ 4 s of
        // buffered avatar at 25 FPS — comfortably above the ASR/LLM
        // turn-around so playback never underflows.
        #if os(iOS)
        let maxAheadChunks = 4
        if pipelineBox.chunkCount >= maxAheadChunks { return }
        #endif
        guard !didShutdown,
              !isLLMGenerating,
              !ditBusy,
              pipelineBox.pipeline != nil,
              pipelineBox.decoder != nil,
              pendingAudio16.count >= dispatchSamples16,
              pendingAudio24.count >= dispatchSamples24 else {
            return
        }

        let audio16 = Array(pendingAudio16.prefix(dispatchSamples16))
        let audio24 = Array(pendingAudio24.prefix(dispatchSamples24))
        pendingAudio16.removeFirst(advanceSamples16)
        pendingAudio24.removeFirst(advanceSamples24)
        let myEpoch = generationEpoch

        ditBusy = true
        inFlight = true
        publishSnapshot()
        let box = pipelineBox

        if Self.pipelineDecodeEnabled {
            // Two-stage path. Stage 1 runs on the pipeline queue
            // (GPU + DiT); Stage 2 runs on the decode queue (ANE +
            // FrameConverter). The next Stage 1 can start as soon as
            // this one returns, even while the previous chunk's
            // Stage 2 is still in flight.
            box.queue.async {
                let stage1 = PipelineOps.produceLatent(
                    box: box, audio16: audio16, audio24: audio24, isIdle: false
                )
                Task { [weak self] in
                    await self?.onDitStageComplete(
                        stage1: stage1, dispatchEpoch: myEpoch
                    )
                }
            }
        } else {
            // Existing serial path — preserved so the default build
            // behaves identically to pre-pipelining releases, and so
            // the `chunkProcessor` DI seam keeps working for tests
            // that inject a mock processor.
            let processor = chunkProcessor
            box.queue.async {
                let chunk = processor(box, audio16, audio24, false)
                Task { [weak self] in
                    await self?.onChunkDispatchComplete(chunk: chunk, dispatchEpoch: myEpoch)
                }
            }
        }
    }

    /// Called back on the actor when DiT finishes producing a latent
    /// (pipelined path only). Releases the DiT lane — which lets the
    /// next chunk's Stage 1 start immediately — and hands the latent
    /// off to the decode queue.
    private func onDitStageComplete(
        stage1: PipelineOps.Stage1Output?, dispatchEpoch: Int
    ) {
        ditBusy = false

        // Stale-epoch or shutdown paths: drop the latent, update
        // flags, and try to drain any pending audio.
        guard !didShutdown, generationEpoch == dispatchEpoch, let stage1 else {
            inFlight = ditBusy || decodeBusy  // may still be draining previous decode
            publishSnapshot()
            maybeDispatchChunk()
            return
        }

        decodeInFlight += 1
        inFlight = true
        publishSnapshot()
        let box = pipelineBox
        box.decodeQueue.async {
            let chunk = PipelineOps.decodeLatentToChunk(box: box, stage1: stage1)
            Task { [weak self] in
                await self?.onDecodeStageComplete(chunk: chunk, dispatchEpoch: dispatchEpoch)
            }
        }
        // Kick the next DiT — it can run on the GPU queue while the
        // current decode runs on the ANE queue.
        maybeDispatchChunk()
    }

    /// Called back on the actor when Stage 2 (ANE decode) finishes.
    /// Same ordering guarantee as the serial path: the chunk is
    /// enqueued BEFORE `inFlight` flips to false, so external drain
    /// loops can't observe `inFlight==false && queue empty` in the
    /// middle of a landing chunk.
    private func onDecodeStageComplete(chunk: TimedChunk?, dispatchEpoch: Int) {
        let isStale = generationEpoch != dispatchEpoch || didShutdown
        if !isStale, let chunk {
            pipelineBox.enqueueChunk(chunk)
        }
        decodeInFlight = max(0, decodeInFlight - 1)
        inFlight = ditBusy || decodeBusy  // may still have later decodes
        publishSnapshot()
        maybeDispatchChunk()
    }

    private func onChunkDispatchComplete(chunk: TimedChunk?, dispatchEpoch: Int) {
        // Enqueue the chunk FIRST, then flip inFlight + publish the
        // snapshot. An external drain loop using the snapshot as its
        // "any work in flight?" gate needs to see the chunk in the
        // queue by the time inFlight transitions to false — otherwise
        // it can observe `inFlight==false && queueCount==0` in the
        // gap between these steps and exit prematurely, losing the
        // final chunk. Ordering matters on the consumer side even
        // though the actor is single-threaded.
        let isStale = generationEpoch != dispatchEpoch || didShutdown
        if !isStale, let chunk {
            pipelineBox.enqueueChunk(chunk)
        }
        ditBusy = false
        inFlight = false
        publishSnapshot()
        // Drain any further-buffered speech audio. Deliberately do
        // not self-kick idle here — sustained back-to-back dispatch
        // on MLX / ANE has been observed to destabilize the runtime
        // after ~100 dispatches.
        maybeDispatchChunk()
    }

    // MARK: - Idle chunk generation
    //
    // Consumers drive the avatar's "breathing while not speaking" look
    // by calling ``generateIdleChunk()`` on their own schedule. The
    // SDK doesn't internally tick idle — the consumer decides cadence
    // so it can be adapted to scene state (paused when the window is
    // backgrounded, etc.).

    /// Produce one idle chunk — ~1.3 s of subtly-breathing frames
    /// driven by low-amplitude noise through the same DiT pipeline
    /// that handles real speech. Returns `nil` if models aren't loaded
    /// or the dispatch queue is currently busy with a speech chunk
    /// (the caller should simply retry on its next tick; serializing
    /// idle behind speech would stall the conversation).
    ///
    /// Call rate: one chunk produces ~33 frames at 25 FPS (≈ 1.3 s of
    /// display time). Schedule generation on a cadence slightly
    /// faster than consumption so you always have the next chunk
    /// queued — e.g. a `Task` that invokes this in a loop with a
    /// 100–200 ms sleep between calls.
    public func generateIdleChunk() async -> TimedChunk? {
        guard !didShutdown,
              pipelineBox.pipeline != nil,
              pipelineBox.decoder != nil,
              !ditBusy else {
            return nil
        }

        // Low-amplitude pink-ish noise (matches the tail-flush floor)
        // at 16 kHz drives wav2vec2 to produce subtle blink/breathing
        // motion without forming mouth shapes for speech.
        let noise16 = Self.generateIdleNoise(count: dispatchSamples16)
        let silent24 = [Float](repeating: 0, count: dispatchSamples24)

        ditBusy = true
        inFlight = true
        publishSnapshot()

        let box = pipelineBox
        let processor = chunkProcessor
        let chunk: TimedChunk? = await withCheckedContinuation { cont in
            box.queue.async {
                let result = processor(box, noise16, silent24, true)
                cont.resume(returning: result)
            }
        }

        ditBusy = false
        inFlight = decodeBusy  // may still be draining a prior decode
        publishSnapshot()

        return chunk
    }

    /// Generate `count` samples of idle audio at 16 kHz to drive
    /// wav2vec2 during silent moments. We use bithuman-cli's bundled
    /// `idle.wav` (a 15 s loop of breath / room tone borrowed from
    /// Halo) because synthetic pink noise produces only minimal
    /// face motion — wav2vec2 reads it as flat ambience and the
    /// avatar looks nearly static. Real audio with subtle vocal
    /// energy gives wav2vec2 something to chew on, so the avatar
    /// breathes / blinks / micro-expresses naturally.
    ///
    /// Falls back to the synthetic pink-noise floor if the bundled
    /// idle.wav can't be decoded (build issue).
    private static func generateIdleNoise(count: Int) -> [Float] {
        let bundled = Self.idleAudioSamples
        guard !bundled.isEmpty else {
            // Fallback: synthetic pink-ish noise at ~-34 dB.
            var buf = [Float](repeating: 0, count: count)
            var prev: Float = 0
            for i in 0..<count {
                let w = Float.random(in: -1...1)
                prev = 0.92 * prev + 0.08 * w
                buf[i] = prev * 0.02
            }
            return buf
        }
        var buf = [Float](repeating: 0, count: count)
        let cursor = Self.idleCursor.advance(by: count, modulo: bundled.count)
        for i in 0..<count {
            buf[i] = bundled[(cursor + i) % bundled.count]
        }
        return buf
    }

    /// Lazy-decoded idle.wav samples at 16 kHz mono Float32. Loaded
    /// on first idle generation; cached for the process lifetime.
    private static let idleAudioSamples: [Float] = {
        guard let url = Bundle.module.url(forResource: "idle", withExtension: "wav"),
              let samples = decodeMonoFloat(at: url, targetRate: 16_000)
        else { return [] }
        return samples
    }()

    /// Atomic cursor into `idleAudioSamples` so back-to-back idle
    /// chunks read contiguously through the loop.
    private static let idleCursor = AtomicCursor()

    private final class AtomicCursor {
        private var value: Int = 0
        private let lock = NSLock()
        func advance(by n: Int, modulo m: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let start = value
            value = (value + n) % m
            return start
        }
    }

    /// Read a WAV file and return mono Float32 samples at the given
    /// target rate. Used both for `idle.wav` and (future) any other
    /// bundled reference audio. AVAudioConverter does the resample.
    private static func decodeMonoFloat(at url: URL, targetRate: Int) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frames) else { return nil }
        do { try file.read(into: inBuf) } catch { return nil }
        guard let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetRate),
            channels: 1,
            interleaved: false
        ) else { return nil }
        let ratio = outFmt.sampleRate / inFmt.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return nil }
        let conv = AVAudioConverter(from: inFmt, to: outFmt)
        var fed = false
        var err: NSError?
        let status = conv?.convert(to: outBuf, error: &err) { _, st in
            if fed { st.pointee = .endOfStream; return nil }
            fed = true
            st.pointee = .haveData
            return inBuf
        }
        guard status != .error, err == nil,
              let ptr = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(outBuf.frameLength)))
    }
}
