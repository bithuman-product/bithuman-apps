import Foundation

/// Unified return type from ``Bithuman/createRuntime(modelPath:identity:quality:)``.
///
/// The two runtimes have genuinely different surfaces — Expression
/// yields ``TimedChunk`` instances via a sync `tryDequeueChunk()` poll
/// driven by the consumer's 25 FPS display tick; Essence yields
/// `CGImage?` frames via an `AsyncStream` whose pump runs inside the
/// actor on a 40 ms cadence. Hiding that asymmetry behind a synthetic
/// `protocol BithumanRuntimeProtocol` would either expose a least-common
/// denominator that crippled both, or carry a `where`-clause forest of
/// associated types that consumers would have to reconstruct anyway.
///
/// A sum type is honest: the consumer pattern-matches once, then talks
/// to the actor with its native API.
///
/// ```swift
/// switch try Bithuman.createRuntime(modelPath: url) {
/// case .expression(let bithuman):
///     // existing Halo-style path: tryDequeueChunk, generateIdleChunk
/// case .essence(let runtime):
///     for await frame in await runtime.frames() { … }
/// }
/// ```
public enum BithumanRuntime: Sendable {
    /// Audio-driven Expression avatar — `Bithuman` actor with
    /// `tryDequeueChunk()` + `generateIdleChunk()`.
    case expression(Bithuman)
    /// Audio-driven Essence avatar — `EssenceRuntime` actor with an
    /// `AsyncStream<CGImage?>` frame stream and an internal 40 ms pump.
    case essence(EssenceRuntime)
}

extension Bithuman {

    /// Unified factory: peek the `.imx` manifest's `model_type`,
    /// instantiate exactly the runtime the file was packed for, and
    /// return it wrapped in a ``BithumanRuntime`` sum.
    ///
    /// **Why peek the manifest before construction.** The two runtimes
    /// each spend hundreds of ms (and gigabytes of RAM, in the
    /// Expression case) on weight loading. Speculatively building both
    /// and discarding one would double both cost and contention against
    /// the single MLX command queue. Reading the 8-byte IMX header +
    /// the manifest.json blob is a few milliseconds of disk I/O.
    ///
    /// **Identity / quality forwarding.** Expression honors both;
    /// Essence's `.imx` baked them in at pack time and exposes neither
    /// knob, so the parameters are silently dropped on the Essence
    /// branch. Calling `createRuntime(modelPath:)` against an Essence
    /// `.imx` with non-default `identity` or `quality` is not an error
    /// — those parameters just don't apply to that runtime.
    ///
    /// **Errors.**
    /// - ``BithumanCreateError/invalidModelFile(message:)`` when the
    ///   container is malformed or has no manifest.
    /// - ``BithumanCreateError/wrongModelType(found:)`` when the
    ///   manifest advertises an unknown `model_type` (anything other
    ///   than `"expression"` or `"essence"`).
    /// - ``BithumanCreateError/unsupportedHardware(reason:)`` when the
    ///   chosen runtime's hardware gate fails (the underlying factory
    ///   surfaces it).
    /// - ``BithumanCreateError/loadFailed(message:)`` when weight
    ///   loading fails.
    /// Peek a packed `.imx` and return the manifest's `model_type`
    /// without paying the cost of weight loading. Useful for hosts
    /// that need to dispatch on the runtime kind BEFORE deciding how
    /// to build the rest of the session — for example, the CLI picks
    /// a circular vs rectangular avatar window from this string,
    /// hours before the runtime would otherwise have to be
    /// constructed.
    ///
    /// Returns the raw `model_type` string if the manifest declared
    /// one (`"expression"`, `"essence"`, or anything else a future
    /// runtime advertises); returns `nil` for valid containers whose
    /// manifest is silent on the question.
    ///
    /// **Errors.** Throws ``BithumanCreateError/invalidModelFile(message:)``
    /// for containers that fail to parse or have no manifest at all.
    /// Unknown-but-present `model_type` values do **not** throw —
    /// peek is informational, dispatch is the caller's choice. Use
    /// ``createRuntime(modelPath:identity:quality:)`` when you want
    /// the strict typed-error pattern (it throws `wrongModelType` for
    /// unknown values).
    public static func peekModelType(modelPath: URL) throws -> String? {
        let container: ImxContainer
        do {
            container = try ImxContainer(path: modelPath)
        } catch {
            throw BithumanCreateError.invalidModelFile(message: "\(error)")
        }
        guard let manifest = container.manifest else {
            throw BithumanCreateError.invalidModelFile(
                message: "Bithuman.peekModelType: container has no manifest.json"
            )
        }
        return manifest["model_type"] as? String
    }

    public static func createRuntime(
        modelPath: URL,
        identity: Bithuman.Identity = .default,
        quality: Bithuman.Quality = .medium
    ) throws -> BithumanRuntime {
        // Open the container and peek the manifest. We *only* read
        // the manifest here — extracting weights / building the model
        // belongs to the per-runtime factory, which we delegate to
        // below once we know the right one to call.
        let container: ImxContainer
        do {
            container = try ImxContainer(path: modelPath)
        } catch {
            throw BithumanCreateError.invalidModelFile(message: "\(error)")
        }
        guard let manifest = container.manifest else {
            throw BithumanCreateError.invalidModelFile(
                message: "Bithuman.createRuntime: container has no manifest.json"
            )
        }
        let modelType = manifest["model_type"] as? String

        switch modelType {
        case "expression":
            // Expression's factory returns a `CreateResult` (the actor
            // plus the static idle frame). The unified dispatcher only
            // promises the actor — callers that need the static idle
            // frame should still go through `Bithuman.create` directly.
            // This is deliberate: the two runtimes have different
            // initial-state shapes and trying to thread both through a
            // sum type would just push the asymmetry one layer down.
            let result = try Bithuman.create(
                modelPath: modelPath,
                identity: identity,
                quality: quality
            )
            return .expression(result.bithuman)

        case "essence":
            // Essence ignores `identity` / `quality` — the .imx baked
            // them in at pack time. Documented on `createRuntime`
            // above. This sync path constructs the runtime UNMETERED
            // (no heartbeat). Production callers that need billing
            // should use `createRuntime(modelPath:identity:quality:apiSecret:)`
            // — the async overload — which routes through
            // `EssenceRuntime.create(modelPath:apiSecret:)` and
            // installs the heartbeat (`billing_type =
            // self-hosted-essence-model`, 1 cr/min).
            let runtime = try EssenceRuntime.create(modelPath: modelPath)
            return .essence(runtime)

        default:
            throw BithumanCreateError.wrongModelType(found: modelType)
        }
    }

    /// Async variant of ``createRuntime(modelPath:identity:quality:)`` that
    /// additionally authenticates the session against the bitHuman billing
    /// service for runtimes that meter on a heartbeat (currently Essence;
    /// Expression's heartbeat is owned by VoiceChat at session-start time).
    ///
    /// **Behaviour by branch.**
    /// - `expression`: identical to the sync overload — Expression's
    ///   heartbeat is wired up at the VoiceChat layer because it shares
    ///   timing with the audio engine and barge-in logic, not at the
    ///   actor-construction layer. The `apiSecret` argument is ignored
    ///   for this branch (kept on the signature so a single call site can
    ///   handle both runtimes).
    /// - `essence`: routes through ``EssenceRuntime/create(modelPath:apiSecret:)``,
    ///   which authenticates up-front (catching 402/403 before the
    ///   consumer wires the frame stream) and arms a 60 s heartbeat that
    ///   resumes once `frames()` is subscribed. Pass `nil` to construct
    ///   the runtime unmetered.
    public static func createRuntime(
        modelPath: URL,
        identity: Bithuman.Identity = .default,
        quality: Bithuman.Quality = .medium,
        apiSecret: String?
    ) async throws -> BithumanRuntime {
        let container: ImxContainer
        do {
            container = try ImxContainer(path: modelPath)
        } catch {
            throw BithumanCreateError.invalidModelFile(message: "\(error)")
        }
        guard let manifest = container.manifest else {
            throw BithumanCreateError.invalidModelFile(
                message: "Bithuman.createRuntime: container has no manifest.json"
            )
        }
        let modelType = manifest["model_type"] as? String

        switch modelType {
        case "expression":
            let result = try Bithuman.create(
                modelPath: modelPath,
                identity: identity,
                quality: quality
            )
            return .expression(result.bithuman)

        case "essence":
            let runtime = try await EssenceRuntime.create(
                modelPath: modelPath,
                apiSecret: apiSecret
            )
            return .essence(runtime)

        default:
            throw BithumanCreateError.wrongModelType(found: modelType)
        }
    }

    // MARK: - Shared-fixture API (Essence multi-instance hosting)

    /// Pre-load an Essence `.imx` into a shared, immutable
    /// ``EssenceFixture`` that can back many concurrent runtimes.
    ///
    /// Heavy: pre-decodes the MP4, decrypts both BJPG archives,
    /// decodes every face mask, computes the idle frame. ~1–2 s on a
    /// 200-frame fixture. The returned fixture is `Sendable` and
    /// reference-counted; once every runtime built from it has been
    /// released, the fixture deallocates.
    ///
    /// Use ``createRuntime(fixture:)`` to spin up runtime instances
    /// off it. Per-instance overhead is ~30–40 MB (composed-frame
    /// LRU + audio buffer + MP4 decode LRU + encoder scratch); the
    /// shared fixture is ~200 MB on the demo, so hosting N concurrent
    /// avatars costs roughly `200 + 30 N` MB instead of `230 N`.
    ///
    /// **Errors.** Surfaces ``EssenceFixture/LoadError`` for invalid
    /// containers / wrong model_type / decode failures.
    public static func loadEssenceFixture(modelPath: URL) throws -> EssenceFixture {
        try EssenceFixture.load(modelPath: modelPath)
    }

    /// Build an Essence runtime from a pre-loaded fixture. Cheap (~50–
    /// 100 ms): only allocates per-instance state. The fixture's
    /// archive is reused — every runtime built from the same fixture
    /// shares the JPEG MP4 storage, patches archive, base BGR cache,
    /// face masks, and KNN feature index.
    ///
    /// This entry point is for callers that have already opened
    /// the fixture via ``loadEssenceFixture(modelPath:)``. For a
    /// single-instance load-and-go, ``createRuntime(modelPath:identity:quality:)``
    /// is simpler.
    public static func createRuntime(fixture: EssenceFixture) throws -> EssenceRuntime {
        try EssenceRuntime.create(fixture: fixture)
    }
}
