import CoreGraphics
import Foundation

/// Audio-driven Essence avatar runtime — the public top-level actor for
/// the Essence inference path. Mirrors the public shape of the
/// Expression-side ``Bithuman`` actor so consumers can dispatch on
/// `manifest.model_type` at the factory boundary and pick the right
/// runtime.
///
/// **Differences from ``Bithuman``.** The Expression actor exposes
/// `tryDequeueChunk()` (a sync poll the Halo display tick reads on
/// every frame) and a separate `generateIdleChunk()` API the consumer
/// schedules; Essence is dramatically cheaper per frame and produces
/// images one-at-a-time, so this actor instead owns the 25 FPS frame
/// pump itself and surfaces an ``AsyncStream`` of frames. Consumers
/// just iterate.
///
/// **Public shape.**
/// - ``create(modelPath:)`` — hardware-gated factory.
/// - ``pushAudio(_:)`` — feed 16 kHz int16 samples in any chunk size;
///   the runtime accumulates and the pump consumes 640-sample (40 ms)
///   chunks at 25 FPS.
/// - ``frames()`` — `AsyncStream<CGImage?>`. `nil` is the idle marker
///   emitted when no audio has arrived for >100 ms; the consumer
///   typically renders the bundled idle frame on `nil`.
/// - ``stop()`` — cancel + finish the stream.
/// - ``resolution`` — frame dimensions from `manifest.output_resolution`.
///
/// **Single-consumer pattern.** ``frames()`` returns the actor's one
/// stream; calling it more than once replaces the previous stream's
/// continuation, which finishes immediately. If you need fan-out, do
/// it on the consumer side (subscribe once, push frames into your own
/// downstream subjects).
public actor EssenceRuntime {

    // MARK: - Tuning constants
    //
    // Surfaced as static lets so tests + diagnostics can reason about
    // the timing contract without grepping for magic numbers in the
    // body of this file.

    /// Target frame interval — 40 ms = 25 FPS, the canonical Essence
    /// pacing per algo spec §6 ("25 FPS Pacing").
    public static let frameIntervalNanoseconds: UInt64 = 40_000_000

    /// How long the audio queue can stay empty before the pump
    /// switches to idle output. Algo spec §4 ("Idle Handling") doesn't
    /// pin a number — 100 ms is a tight enough threshold that the
    /// avatar feels live (≤2.5 frames of stale lip motion), wide
    /// enough that a single mid-utterance gap from upstream resampling
    /// or jitter doesn't flap us between speech and idle.
    public static let idleThresholdNanoseconds: UInt64 = 100_000_000

    /// Audio buffer cap. 16 kHz × 15 s = 240,000 samples. The pump
    /// consumes 640 samples per tick (40 ms = 1× realtime); upstream
    /// (Qwen3 / Kokoro TTS) typically bursts an entire utterance's
    /// worth of audio into the buffer in ~10–20% of its playback
    /// duration, then goes quiet. With a tight 1 s cap (the pre-
    /// v0.18.5 setting) those bursts overflowed: the head got
    /// trimmed before the pump drained it, so the avatar tick pulled
    /// audio that was still queued in the speaker's playback buffer
    /// — visually the mouth raced ~3–4 s **ahead** of the sound.
    /// 15 s of headroom covers any single utterance the LLM emits
    /// in one burst (~2 MB of memory; trivial); for any plausible
    /// long monologue the user pauses naturally, so the cap holds.
    public static let audioBufferCapacity: Int = 240_000

    /// Per-tick consumption — algo spec §1: 640 samples = 40 ms at
    /// 16 kHz, exactly one video frame at 25 FPS.
    public static let samplesPerFrame: Int = EssenceGenerator.samplesPerFrame  // 640

    // MARK: - Errors

    /// Errors specific to Essence-runtime construction. These
    /// piggyback on the shared ``BithumanCreateError`` enum (which the
    /// Expression actor also throws) so consumers have a single
    /// catch-all error surface for "create failed". Wrong-model-type
    /// flows through ``BithumanCreateError/wrongModelType(found:)`` so
    /// the per-runtime factory and the unified `createRuntime` factory
    /// surface the same typed error for the same situation — consumers
    /// can pattern-match once and route both paths the same way.
    static func wrongModelTypeError(found: String?) -> BithumanCreateError {
        .wrongModelType(found: found)
    }

    // MARK: - Stored state
    //
    // All state below is actor-isolated. The frame pump is a detached
    // Task that re-enters the actor (via `await self.tick()`) every
    // 40 ms; nothing here is touched off-actor.

    /// The wrapped per-frame orchestrator. Reference type, not
    /// `Sendable`, lives entirely behind this actor.
    private let generator: EssenceGenerator

    /// Container's manifest output resolution, snapshotted at create
    /// time so the nonisolated ``resolution`` accessor doesn't need an
    /// actor hop.
    private nonisolated let _resolution: (width: Int, height: Int)

    /// Static idle frame snapshotted at create time. Lets display-side
    /// code (e.g., ``EssenceVoiceChatSession``) render something the
    /// instant the window opens, instead of leaving it black until
    /// the first audio chunk arrives. CGImage is thread-safe, so
    /// `nonisolated` access is OK.
    private nonisolated let _idleFrame: CGImage

    /// Circular-ish int16 buffer. We append to the tail; the pump
    /// pulls 640 samples off the head per tick. When the buffer
    /// outgrows ``audioBufferCapacity`` we drop the oldest samples —
    /// upstream pushed faster than 25 FPS for over a second, which
    /// only happens on a stalled consumer (we'd rather render fresh
    /// audio than render a second-old vowel).
    private var audioBuffer: [Int16] = []

    /// Wall-clock of the most recent ``pushAudio`` call. The pump uses
    /// `now - lastAudioPush > idleThresholdNanoseconds` to flip to
    /// idle output.
    private var lastAudioPushNanos: UInt64 = 0

    /// Wall-clock of the first ``pushAudio`` call after a quiet
    /// period. Used by the pump to compute "where the speaker should
    /// be in the audio timeline by now" so it can align frame
    /// generation to playback position. Reset when the buffer drains
    /// fully so a fresh utterance starts a new alignment cycle.
    private var alignmentEpochNanos: UInt64 = 0

    /// Total samples consumed by the pump since ``alignmentEpochNanos``
    /// was last set. Compared against the expected consumption (based
    /// on wall-clock elapsed × 16 kHz) to decide whether the pump is
    /// behind realtime and needs to skip-ahead.
    private var consumedSinceEpoch: Int = 0

    /// The pump task. Held so ``stop()`` can cancel it; nilled out
    /// after cancellation so a second `stop()` is a no-op.
    private var pumpTask: Task<Void, Never>?

    /// Active stream continuation. Set by ``frames()``, cleared by
    /// ``stop()``. Single-consumer — calling ``frames()`` twice
    /// finishes the previous stream and replaces it.
    private var frameContinuation: AsyncStream<CGImage?>.Continuation?

    /// Sticky shutdown gate. Once set, every mutating entry point
    /// (`pushAudio`, future `setIdentity`-style calls) becomes a
    /// silent no-op. Mirrors `Bithuman.didShutdown`.
    private var didStop: Bool = false

    /// Billing heartbeat for this runtime, when an api-secret was
    /// supplied at create time. Resumed lazily on the first
    /// ``frames()`` subscription (which is when the pump starts and
    /// the runtime is actually doing work) and stopped from
    /// ``stop()``. Nil when running unmetered (no api-secret given +
    /// no `BITHUMAN_API_KEY` env var) — mirrors VoiceChat's behavior
    /// for the Expression path.
    private var heartbeat: BithumanHeartbeat?

    // MARK: - Init (private — go through `create`)

    private init(
        generator: EssenceGenerator,
        resolution: (width: Int, height: Int),
        heartbeat: BithumanHeartbeat? = nil
    ) {
        self.generator = generator
        self._resolution = resolution
        self._idleFrame = generator.idleFrame
        self.heartbeat = heartbeat
    }

    // MARK: - Public factory

    /// Construct an ``EssenceRuntime`` from a packed `.imx` Essence
    /// avatar bundle.
    ///
    /// **What this validates, in order:**
    /// 1. Hardware: Apple Silicon M3+ on macOS, M-series iPad on iOS.
    ///    Throws ``BithumanCreateError/unsupportedHardware(reason:)``
    ///    on M1/M2 / Intel / iPhone — surfaces a typed error rather
    ///    than letting the runtime crash deeper.
    /// 2. Container parse: throws ``BithumanCreateError/invalidModelFile(message:)``
    ///    if the file isn't a valid IMX v2.
    /// 3. `model_type == "essence"`: throws ``BithumanCreateError/wrongModelType(found:)``
    ///    if the manifest advertises a different model type. Same
    ///    typed error the unified ``Bithuman/createRuntime(modelPath:identity:quality:)``
    ///    factory throws for unknown model types — consumers can
    ///    pattern-match once.
    /// 4. ``EssenceGenerator`` construction: throws
    ///    ``BithumanCreateError/loadFailed(message:)`` wrapping any
    ///    error from missing entries / malformed lip-sync metadata.
    /// Async factory that additionally authenticates the session
    /// against the bitHuman billing service before returning the
    /// runtime. The on-device Essence pipeline is metered at 1 credit
    /// per active minute (vs Expression's 2 cr/min) — distinct
    /// `billing_type` strings keep the auth-service's per-runtime
    /// pricing apart.
    ///
    /// **API-secret resolution.** `apiSecret` parameter wins; falls
    /// back to the `BITHUMAN_API_KEY` env var; if both are nil/empty
    /// the runtime is constructed unmetered (no heartbeat task is
    /// spawned). Unmetered mode mirrors VoiceChat's behaviour for
    /// development and first-party consumers.
    ///
    /// **When the up-front authenticate succeeds**, the heartbeat is
    /// armed but NOT yet resumed — the periodic 60 s loop kicks in
    /// once the consumer subscribes to ``frames()`` (which is when the
    /// runtime is actually doing work). ``stop()`` cancels both the
    /// pump and the heartbeat.
    ///
    /// **Errors.** All synchronous ``create(modelPath:)`` errors plus
    /// ``BithumanCreateError/authenticationFailed(underlying:)`` for
    /// 402 (insufficient balance) / 403 (account suspended) responses
    /// from the up-front heartbeat.
    public static func create(
        modelPath: URL,
        apiSecret: String?
    ) async throws -> EssenceRuntime {
        // Build the runtime first (hardware gate, manifest validation,
        // weight load) — we want a bad model file to surface as
        // `invalidModelFile` regardless of billing state.
        let runtime = try create(modelPath: modelPath)

        // Resolve the api-secret. Same precedence as VoiceChat's
        // Expression path: explicit param → env var → unmetered.
        let resolved = (apiSecret ?? ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"])?
            .trimmingCharacters(in: .whitespaces)
        guard let key = resolved, !key.isEmpty else {
            // Unmetered mode — no heartbeat. Documented and matches
            // the Expression-side behaviour when no api key is given.
            return runtime
        }

        let heartbeat = BithumanHeartbeat(
            config: BithumanAuthConfig(
                apiSecret: key,
                billingType: BithumanAuthConfig.selfHostedEssenceModel
            )
        )
        do {
            try await heartbeat.authenticate()
        } catch let err as BithumanAuthError {
            throw BithumanCreateError.authenticationFailed(underlying: err)
        }
        await runtime.attachHeartbeat(heartbeat)
        return runtime
    }

    /// Internal test seam — inject a pre-built ``BithumanHeartbeat``
    /// (which can wrap a stubbed `URLSession` and a sub-second
    /// interval) without going through env-var lookup or network
    /// authentication. Tests construct one of these to verify the
    /// outgoing payload + cadence + stop semantics; production
    /// callers should always go through ``create(modelPath:apiSecret:)``.
    internal static func _testCreate(
        modelPath: URL,
        heartbeat: BithumanHeartbeat
    ) async throws -> EssenceRuntime {
        let runtime = try create(modelPath: modelPath)
        await runtime.attachHeartbeat(heartbeat)
        return runtime
    }

    /// Install (or replace) the billing heartbeat on this runtime.
    /// Internal-only; the public path is `create(modelPath:apiSecret:)`.
    internal func attachHeartbeat(_ hb: BithumanHeartbeat) {
        self.heartbeat = hb
    }

    /// Test-only accessor — returns the currently-attached heartbeat
    /// (or nil for an unmetered runtime). Lets tests assert lifecycle
    /// transitions (`stop()` clears it) without prying into the
    /// heartbeat actor's private state.
    internal var _heartbeatForTesting: BithumanHeartbeat? { heartbeat }

    public static func create(modelPath: URL) throws -> EssenceRuntime {
        // 1. Hardware gate first — cheaper than touching the
        // container, surfaces the support-matrix error before any
        // I/O.
        if case .unsupported(let reason) = HardwareSupport.check() {
            throw BithumanCreateError.unsupportedHardware(reason: reason)
        }

        // 2. Open the container.
        let container: ImxContainer
        do {
            container = try ImxContainer(path: modelPath)
        } catch {
            throw BithumanCreateError.invalidModelFile(message: "\(error)")
        }

        // 3. Validate model_type. We read directly from the raw
        // manifest dict rather than going through `EssenceManifest`
        // because the manifest may not satisfy the schema-version /
        // runtime-version-min checks the strongly-typed decoder
        // enforces, and we want a wrong-model-type error to win over
        // those (the consumer at the dispatch layer is asking "is
        // this Essence?" first, "is the schema something I can read?"
        // second).
        guard let manifest = container.manifest else {
            throw BithumanCreateError.invalidModelFile(
                message: "EssenceRuntime: container has no manifest.json"
            )
        }
        let modelType = manifest["model_type"] as? String
        guard modelType == "essence" else {
            throw wrongModelTypeError(found: modelType)
        }

        // 4. Construct the generator. Wrap any failure in
        // `loadFailed` so consumers can route a single error case to
        // their "model is bad" UI.
        let generator: EssenceGenerator
        do {
            generator = try EssenceGenerator(container: container)
        } catch {
            throw BithumanCreateError.loadFailed(message: "\(error)")
        }

        let res = generator.resolution
        return EssenceRuntime(generator: generator, resolution: res)
    }

    /// Build a runtime against a pre-loaded ``EssenceFixture``. Use
    /// when hosting many concurrent runtimes against the same `.imx`
    /// — the fixture pins the heavy archives once, each call here
    /// only allocates the per-instance audio buffer + composed-frame
    /// LRU + MP4 frame decode LRU + encoder scratch (~30–40 MB).
    ///
    /// The hardware gate + model_type validation already ran at
    /// fixture-load time, so this factory is purely a per-instance
    /// allocator and won't surface ``BithumanCreateError/unsupportedHardware``
    /// or ``BithumanCreateError/wrongModelType``.
    public static func create(fixture: EssenceFixture) throws -> EssenceRuntime {
        let generator: EssenceGenerator
        do {
            generator = try EssenceGenerator(fixture: fixture)
        } catch {
            throw BithumanCreateError.loadFailed(message: "\(error)")
        }
        return EssenceRuntime(generator: generator, resolution: generator.resolution)
    }

    // MARK: - Public API

    /// Container's `manifest.output_resolution`. Sourced once at
    /// create time and surfaced nonisolated so display-side code can
    /// size its drawing surface without an actor hop.
    public nonisolated var resolution: (width: Int, height: Int) {
        _resolution
    }

    /// Static idle frame for this avatar (the bundle's identity image
    /// — neutral, mouth-closed). Available before any audio is
    /// pushed; ``EssenceVoiceChatSession`` uses it to seed the window
    /// so it isn't black between launch and the first TTS chunk.
    /// CGImage is thread-safe; nonisolated access is fine.
    public nonisolated var idleFrame: CGImage {
        _idleFrame
    }

    /// Push a chunk of 16 kHz int16 audio (algo spec §1). Any
    /// chunk size is accepted — the runtime buffers and the pump
    /// pulls 640-sample slices on its 40 ms cadence.
    ///
    /// Post-``stop()`` calls are silent no-ops, matching the
    /// Expression actor's contract (`Bithuman.pushAudio` after
    /// `shutdown` does the same; consumers shouldn't have to wrap
    /// every push in a "did I stop?" check).
    public func pushAudio(_ samples: [Int16]) async {
        if didStop { return }
        if samples.isEmpty { return }

        // First push of a fresh utterance — start a new alignment
        // epoch so the pump's catch-up math is anchored to "speaker
        // started playing roughly now". Detected as "buffer was empty
        // before this push", which corresponds to either a cold start
        // or the end of a quiet idle period.
        if audioBuffer.isEmpty {
            alignmentEpochNanos = Self.nowNanos()
            consumedSinceEpoch = 0
        }

        audioBuffer.append(contentsOf: samples)
        // Trim the head if upstream over-buffered. Anything past this
        // is dropped on the floor (older lip shapes are stale by the
        // time they'd render anyway).
        if audioBuffer.count > Self.audioBufferCapacity {
            let dropped = audioBuffer.count - Self.audioBufferCapacity
            audioBuffer.removeFirst(dropped)
            // Trimmed samples count toward "consumed" from the
            // alignment math's perspective — they'll never be played
            // through the lipsync pipeline, but the wall-clock
            // expectation already accounts for their elapsed time.
            consumedSinceEpoch &+= dropped
        }

        lastAudioPushNanos = Self.nowNanos()
    }

    /// Subscribe to the 25 FPS stream of rendered frames.
    ///
    /// Yields a `CGImage` when the pump has audio to drive a frame,
    /// `nil` when the audio buffer has been empty for longer than
    /// ``idleThresholdNanoseconds`` (100 ms). Consumers render the
    /// bundle's idle frame (or whatever local placeholder they
    /// prefer) on `nil`.
    ///
    /// **Single-consumer.** Calling this method again finishes the
    /// previous stream and returns a fresh one — the second consumer
    /// gets the live feed from that point on, the first sees its
    /// `for await` loop exit cleanly. Fan-out to multiple consumers
    /// is the caller's responsibility.
    public func frames() -> AsyncStream<CGImage?> {
        // Tear down any previous subscription. Single-consumer: the
        // old listener exits its `for await` cleanly; new listener
        // gets the live feed.
        frameContinuation?.finish()
        frameContinuation = nil

        let stream = AsyncStream<CGImage?>(bufferingPolicy: .bufferingNewest(2)) { cont in
            self.frameContinuation = cont
            cont.onTermination = { [weak self] _ in
                // Consumer cancelled (Task cancelled, broke the loop,
                // etc.). Hop back into the actor to clear our
                // continuation reference so a future `frames()` call
                // doesn't try to finish a dead continuation.
                Task { [weak self] in
                    await self?.handleConsumerTermination(cont)
                }
            }
        }
        // Lazily start the pump on first subscribe. Construction
        // doesn't kick the pump because there's no consumer yet —
        // a generator without a consumer would just spin frames into
        // /dev/null.
        if pumpTask == nil && !didStop {
            startPump()
        }
        return stream
    }

    /// Cancel the frame pump, drain any pending audio, and finish
    /// the active ``frames()`` stream. Idempotent.
    public func stop() async {
        if didStop { return }
        didStop = true

        pumpTask?.cancel()
        pumpTask = nil

        audioBuffer.removeAll(keepingCapacity: false)

        frameContinuation?.finish()
        frameContinuation = nil

        // End the billing heartbeat so the metering session closes.
        // Safe regardless of whether `resume()` was ever called — the
        // heartbeat actor's `stop()` is idempotent.
        if let hb = heartbeat {
            await hb.stop()
        }
        heartbeat = nil
    }

    // MARK: - Bench / fixture-corpus test seam
    //
    // These accessors are NOT part of the public SDK surface. They
    // exist so the `bench-essence` harness (Examples/BenchEssence/) and
    // the cross-SDK fixture-corpus comparator can drive the generator
    // synchronously, one audio chunk at a time, and capture the KNN
    // cluster pick that the public `frames()` AsyncStream hides behind
    // a `CGImage?`. The pump's 40 ms cadence is the wrong measurement
    // surface for "per-frame inference cost" (it bakes in the
    // `Task.sleep`); the bench harness therefore bypasses the pump and
    // calls into the generator directly.
    //
    // Marked `internal` deliberately — same-module callers (the bench
    // example target depends on `bitHumanKit`, so it sees `internal`
    // declarations from this module) can use it; downstream products
    // see the public API only.

    /// Per-frame diagnostic payload exposed for the bench harness.
    /// Mirrors `EssenceGenerator.FrameDetail` but flattened so callers
    /// don't need to import the internal generator type.
    ///
    /// Not `Sendable` because `CGImage` isn't Sendable; the bench
    /// harness consumes this synchronously inside the actor context
    /// returned by the await call, so cross-actor transit isn't needed.
    public struct BenchFrameDetail {
        public let image: CGImage
        public let frameIdx: Int
        public let clusterIdx: Int
        public let flatIndex: Int
        public let isSilenceGuarded: Bool
        public let embedNorm: Float
    }

    /// Drive a single 640-sample (40 ms) audio chunk through the
    /// generator synchronously, returning the rendered frame plus the
    /// KNN cluster pick. Bypasses the `frames()` pump — caller is
    /// responsible for pacing and audio chunking.
    ///
    /// **Bench-only — not part of the stable public API.** Marked
    /// `public` so the out-of-module `BenchEssence` executable target
    /// (which depends on `bitHumanKit` like any external consumer) can
    /// reach it; the leading `_` and `ForBench` suffix flag this as a
    /// test seam that may change at any time. Production consumers
    /// should use `pushAudio` + `frames()`. The seam exists so
    /// per-frame inference cost can be measured without `Task.sleep`
    /// jitter polluting the timing window.
    public func _generateFrameDetailedForBench(
        audioChunk: [Int16]
    ) throws -> BenchFrameDetail {
        let detail = try generator.generateFrameDetailed(audioChunk: audioChunk)
        return BenchFrameDetail(
            image: detail.image,
            frameIdx: detail.frameIdx,
            clusterIdx: detail.clusterIdx,
            flatIndex: detail.flatIndex,
            isSilenceGuarded: detail.isSilenceGuarded,
            embedNorm: detail.embedNorm
        )
    }

    /// Run the audio encoder once on a fixed (1, 1, 80, 16) mel input and
    /// return the resulting (1, 512, 1, 1) embedding as flat row-major
    /// float32. Used by the cross-SDK comparator to verify the Swift
    /// embedding agrees byte-equivalent with the ONNX reference; KNN
    /// drift in the compose pipeline traces back to drift here.
    ///
    /// **Bench-only — not part of the stable public API.**
    public func _encodeMelForBench(mel: [Float]) -> [Float] {
        generator._encodeMelForBench(mel: mel)
    }

    /// Dump the per-stage profile counters accumulated by the
    /// generator + audio encoder when `BITHUMAN_PROFILE=1` is set.
    /// No-op otherwise.
    ///
    /// **Bench-only — not part of the stable public API.**
    public func _dumpProfileForBench() {
        generator._dumpProfileForBench()
    }

    // MARK: - Pump

    /// Spawn the 40 ms detached frame-pump task. Held by `pumpTask`
    /// so `stop()` can cancel; the task itself loops on
    /// `Task.isCancelled` for clean teardown.
    ///
    /// **Backpressure.** The continuation is created with
    /// `.bufferingNewest(2)` so a slow consumer drops old frames
    /// rather than the actor's internal pump blocking on a full
    /// buffer. Same policy as the Expression actor's "freshness
    /// matters more than completeness" — a stale frame is worse than
    /// a skipped one.
    private func startPump() {
        // Reset the audio-push timestamp so the first tick after
        // start has a sensible baseline ("never pushed yet" → idle).
        lastAudioPushNanos = 0
        // Kick the billing heartbeat in lockstep with the pump — the
        // two have the same lifetime (active driving session). The
        // up-front `authenticate()` call has already validated the
        // api-secret, so this `resume()` is just spawning the
        // periodic 60 s loop. `resume()` is idempotent on the
        // heartbeat actor, so a `frames()` re-subscribe (which
        // re-enters this path) doesn't double-arm.
        if let hb = heartbeat {
            Task { await hb.resume() }
        }
        let pump = Task.detached { [weak self] in
            // Deadline-tracked cadence: each cycle ends 40 ms after
            // the previous cycle's deadline, NOT 40 ms after the
            // previous tick returned. The pre-v0.18.5 pump did
            // `sleep(40 ms); await tick()`, which means a 25 ms tick
            // turned into a 65 ms cycle — the avatar consumed audio
            // at ~0.62× realtime, so over a multi-second utterance
            // the visual fell behind the speaker by hundreds of ms
            // (compounded by the runtime audio-buffer trim, which
            // dropped the oldest samples when the buffer overflowed
            // — visible to the user as "mouth races ahead of sound"
            // because the pump ended up pulling future audio after
            // the head got cut). Tracking deadlines makes the cycle
            // exactly 40 ms steady-state and self-correcting if a
            // tick takes >40 ms (the next sleep is short or zero).
            var nextDeadline = DispatchTime.now().uptimeNanoseconds
                &+ Self.frameIntervalNanoseconds
            while !Task.isCancelled {
                let now = DispatchTime.now().uptimeNanoseconds
                if nextDeadline > now {
                    try? await Task.sleep(nanoseconds: nextDeadline &- now)
                }
                if Task.isCancelled { break }
                nextDeadline &+= Self.frameIntervalNanoseconds
                await self?.tick()
            }
        }
        self.pumpTask = pump
    }

    /// Single tick of the pump. Pulls 640 samples if available,
    /// renders a frame; otherwise emits `nil` if we've been silent
    /// long enough.
    private func tick() async {
        // Defensive — if `stop()` raced with an in-flight tick,
        // abort cleanly.
        guard !didStop, let cont = frameContinuation else { return }

        if audioBuffer.count >= Self.samplesPerFrame {
            // **Wall-clock-aligned A/V sync.** The speaker plays the
            // pushed audio at exactly 16 kHz starting around the
            // alignment epoch (first push). To keep the lip shape
            // matched to what the speaker is playing right now, the
            // pump computes the expected sample-position based on
            // elapsed wall-clock and skips ahead in the lipsync
            // buffer if it's behind. Without this, slow `generateFrame`
            // (~50 ms instead of 40 ms on iPhone) makes the pump
            // process audio at <1× realtime, so frames cumulatively
            // lag the speaker (~1 s drift over a 4 s reply at 20 fps).
            //
            // Skip is bounded per tick — we drop at most the number
            // of samples we're behind, then process the next 640 to
            // generate the frame. So a 20 fps actual rate skips
            // ~160 samples per tick (~10 ms of lipsync per 50 ms
            // wallclock = 20%), not whole bursts. The speaker route
            // is independent and never has samples removed.
            if alignmentEpochNanos > 0 {
                let elapsedNs = Self.nowNanos() &- alignmentEpochNanos
                // 16 kHz: samples = elapsed_ns × 16_000 / 1_000_000_000
                let expectedConsumed = Int(elapsedNs / 62_500)  // 1e9 / 16000 = 62500 ns/sample
                // We're about to consume ONE chunk this tick; only
                // skip the EXTRA backlog beyond that.
                let extra = expectedConsumed - consumedSinceEpoch - Self.samplesPerFrame
                if extra > 0 {
                    let toSkip = min(extra, audioBuffer.count - Self.samplesPerFrame)
                    if toSkip > 0 {
                        audioBuffer.removeFirst(toSkip)
                        consumedSinceEpoch &+= toSkip
                    }
                }
            }

            let chunk = Array(audioBuffer.prefix(Self.samplesPerFrame))
            audioBuffer.removeFirst(Self.samplesPerFrame)
            consumedSinceEpoch &+= Self.samplesPerFrame
            do {
                let img = try generator.generateFrame(audioChunk: chunk)
                cont.yield(img)
            } catch {
                // Drop the frame on render failure rather than
                // tearing the stream down — a single malformed mel
                // chunk shouldn't end the conversation. We still
                // surface idle so the consumer sees a coherent stream.
                cont.yield(nil)
            }
            return
        }

        // No audio chunk ready. Match the Python SDK's "looping idle"
        // behavior — Python's frame counter advances every tick
        // regardless of audio state, and silent input naturally
        // routes through encoder → KNN → cluster 0 → bases[frame_idx]
        // (the looped source video plays through), so the user sees
        // continuous body motion (blinking, breathing, head sway)
        // even when the bot is silent.
        //
        // Our pump previously emitted `nil` here, which the Swift
        // session then renders as a single static `idleFrame` —
        // freezing the avatar instead of letting the looping video
        // play. Matching Python: synthesise a 640-sample silent
        // chunk and run it through the generator. Cluster 0 hits
        // bases[frameCounter % numFrames]; frameCounter advances
        // inside the generator just like a real audio chunk, so the
        // looping video keeps cycling.
        //
        // The tiny extra inference cost (~1 ms/frame for silence) is
        // negligible compared to the visual win.
        let now = Self.nowNanos()
        let quietForNanos = lastAudioPushNanos == 0
            ? UInt64.max
            : now &- lastAudioPushNanos
        if quietForNanos >= Self.idleThresholdNanoseconds {
            // Silent chunk — 640 samples of zero. Drives the bases
            // archive forward without producing lipsync motion.
            let silent = [Int16](repeating: 0, count: Self.samplesPerFrame)
            do {
                let img = try generator.generateFrame(audioChunk: silent)
                cont.yield(img)
            } catch {
                cont.yield(nil)
            }
        } else {
            // Audio is in flight but we don't have a full 640-sample
            // chunk yet — skip the tick rather than yield a partial
            // or stale frame. The next tick (40 ms out) will see the
            // buffer fill.
        }
    }

    /// Called from the continuation's `onTermination` callback when
    /// a consumer cancels their iteration. Not the same as `stop()` —
    /// the runtime keeps the pump alive (a future `frames()` call can
    /// re-subscribe). We just clear the dangling reference.
    private func handleConsumerTermination(
        _ terminated: AsyncStream<CGImage?>.Continuation
    ) {
        // Only clear if the terminated continuation IS the one we
        // currently hold — a `frames()` call that immediately
        // installed a new continuation will have already replaced
        // `frameContinuation`, and we don't want to wipe the new one.
        // AsyncStream.Continuation is not Equatable, so we identify
        // the previous one by reference via this clearing pass.
        // Practically: the only path that races us here is a
        // back-to-back `frames()` rebuild, which already finished the
        // old continuation explicitly — by the time `onTermination`
        // fires for that old one, `frameContinuation` is the new
        // one. Skipping the clear in that case is the correct
        // behavior. Without an identity check, rely on the fact that
        // `finish()` is idempotent and a stale clear is harmless.
        _ = terminated
        // Conservative: don't clear unconditionally; let the next
        // `stop()` or `frames()` rebuild the continuation. A stale
        // ref here just means `frameContinuation?.finish()` runs on
        // an already-finished continuation, which is documented as
        // safe.
    }

    // MARK: - Helpers

    /// Monotonic clock in nanoseconds. `DispatchTime.now()` is the
    /// cheapest cross-platform monotonic timer that doesn't require
    /// pulling in `Clock` (Swift 5.7+ but still mostly main-actor
    /// flavored). The exact reference epoch is irrelevant — we only
    /// ever take differences.
    nonisolated private static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
