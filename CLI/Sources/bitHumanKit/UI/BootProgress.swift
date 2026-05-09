import Combine
import Foundation

/// Single source of truth for "what's the app doing right now" during
/// the cold-start window between launch and the moment the avatar
/// (video mode) or the conversation prompt (voice mode) becomes
/// usable.
///
/// **Why a dedicated type instead of just printing.** Each loading
/// stage was historically a one-shot `print(...)` line in
/// `VoiceChat.start()` plus a few ad-hoc download bars in `LLMClient`
/// and `ExpressionWeights`. The user sees a wall of scrolling text
/// during a 30+ s first-run boot and has no idea whether anything is
/// progressing or if the process is stuck. Funneling every stage
/// through a single ``Phase`` value lets:
///
/// - **voice mode** render one self-overwriting stderr line with
///   bar + rate + ETA across every download/load step (see
///   ``TerminalProgressRenderer``);
/// - **video mode** open the AvatarWindow at process start with a
///   `LoadingParticleField` splash bound to the same `Phase`, so the
///   user has a graphical bar from the very first moment instead of
///   waiting through a blank screen until the engine is ready.
///
/// **Thread model.** ``BootProgress`` is `@MainActor` so SwiftUI's
/// `@Published` observer fires on the main run loop. Updates from
/// background download tasks (URLSession callbacks, hub-downloader
/// progress closures) call ``update(_:)`` from any thread — the
/// implementation hops to main internally.
@MainActor
public final class BootProgress: ObservableObject {

    /// Discrete stages the boot pipeline walks through. Order is the
    /// canonical sequence; not every run hits every stage (cached
    /// runs skip the download phases). Cases carry whatever progress
    /// payload that stage has — bytes + rate + ETA for downloads,
    /// 0..1 for fraction-only loaders, nil-progress for opaque steps.
    public enum Phase: Equatable, Sendable {
        case idle
        /// Streaming the expression-engine weights from the CDN.
        case downloadingEngine(
            received: Int64,
            total: Int64,
            bytesPerSecond: Double,
            etaSeconds: Double?
        )
        /// SHA-256 verifying a freshly downloaded engine archive.
        case verifyingEngine
        /// First-run SpeechAnalyzer model fetch. The macOS API doesn't
        /// expose granular byte progress, so this phase is opaque.
        case loadingSpeechModel
        /// On-device LLM (Gemma 4) load — first run downloads ~2 GB,
        /// subsequent runs mmap from disk in a few seconds. Progress
        /// is the hub-downloader fraction.
        case loadingLLM(progress: Double)
        /// Audio engine init — opening AVAudioEngine, mic + output
        /// nodes, voice-processing IO unit. Fast (~0.5 s), opaque.
        case openingAudioGraph
        /// Kokoro / Qwen3 TTS load + first-run download. `progress`
        /// is nil when no granular fraction is available.
        case loadingTTS(progress: Double?)
        /// Authenticating the API key against the bitHuman billing
        /// service. ~1 s, opaque.
        case authenticating
        /// Final stage of the engine load — mmap, int4 dequantize,
        /// VAE bake. ~5–10 s on Apple Silicon, opaque (the engine
        /// runs synchronous Metal work that doesn't surface a
        /// fraction).
        case loadingExpressionEngine
        /// Essence runtime load — unpack `.imx`, mmap weights, build
        /// LRU. Faster than Expression (~0.3 s warm) since the heavy
        /// face decoding happens at frame time, not load time.
        case loadingEssenceRuntime
        /// Opening the OpenAI Realtime WebSocket and exchanging the
        /// initial `session.update`. ~0.5 s on a healthy connection.
        case connectingRealtime
        /// AvatarWindow is up, engine is producing frames, but the
        /// idle palindrome cache is still filling. `progress` is the
        /// 0..1 fill ratio. Drives the existing splash bar.
        case prewarmingIdle(progress: Double)
        /// Ready to talk. Splash dismissed, terminal renderer stops
        /// repainting.
        case ready
    }

    @Published public private(set) var phase: Phase = .idle

    /// True iff this run hit the engine-download path (i.e., the
    /// `.bhx` weights were not yet on disk). Auto-set when the
    /// pipeline observes a ``Phase/downloadingEngine`` transition.
    /// The splash uses this to surface "first-run ANE shader
    /// compilation can take 60–120 s" guidance immediately during
    /// the subsequent ``Phase/loadingExpressionEngine`` step,
    /// instead of waiting for the elapsed-time escalation threshold
    /// — on the SECOND run the ANE bundle cache is warm and the
    /// load completes in ~10 s, so we don't want to alarm those
    /// users with a "this can take 2 min" message.
    @Published public private(set) var engineFirstRun: Bool = false

    public init() {}

    /// Replace the current phase. Safe to call from any thread.
    public nonisolated func update(_ next: Phase) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Once we observe a download, mark this as a first run
            // — the subsequent engine-load step will hit the slow
            // ANE-compile path. Stays sticky for the whole session.
            if case .downloadingEngine = next {
                self.engineFirstRun = true
            }
            self.phase = next
        }
    }

    // MARK: - Derived UI fields

    /// Single-line caption suitable for both the terminal renderer
    /// and the splash text. Includes inline progress where the phase
    /// has it (`"downloading expression engine — 78%"`); leaves
    /// rate/ETA to ``detail`` so the splash doesn't get noisy.
    public var caption: String { Self.caption(for: phase) }

    /// Phase-derived caption helper. Static so the terminal
    /// renderer's `@Published.sink` callback can compute it from
    /// the new-value argument without racing the willSet/didSet
    /// commit on `phase` (Combine fires the publisher during
    /// willSet, before the stored property has been updated).
    public static func caption(for phase: Phase) -> String {
        return caption(for: phase, engineFirstRun: false)
    }

    /// Caption variant that switches loading-engine messaging based
    /// on whether the engine weights were just downloaded (cold ANED
    /// cache → multi-minute compile) or were already on disk (warm
    /// cache → ~5 s mmap+load). Static so the terminal renderer can
    /// recompute it from a `(phase, firstRun)` pair without racing
    /// the `@Published` observer.
    public static func caption(for phase: Phase, engineFirstRun: Bool) -> String {
        switch phase {
        case .idle:
            return "starting up…"
        case .downloadingEngine(let received, let total, _, _):
            let pct = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
            return "downloading expression engine — \(pct)%"
        case .verifyingEngine:
            return "verifying expression engine…"
        case .loadingSpeechModel:
            return "downloading speech model… (~30 s ONE-TIME first run)"
        case .loadingLLM(let p):
            let pct = Int(p * 100)
            return p > 0 ? "loading on-device LLM — \(pct)% (~5 s warm)" : "loading on-device LLM… (~30 s ONE-TIME first run)"
        case .openingAudioGraph:
            return "opening audio graph…"
        case .loadingTTS(let p):
            if let p, p > 0 {
                return "loading TTS voice — \(Int(p * 100))% (~5 s warm)"
            }
            return "loading TTS voice… (~10 s ONE-TIME first run)"
        case .authenticating:
            return "authenticating with bitHuman billing service…"
        case .loadingExpressionEngine:
            // Expression engine load splits into two paths: a cold
            // ANED cache compiles ANE shaders for several minutes
            // ONE TIME per Mac and stashes them in /var/db/com.apple.aned/cache;
            // every subsequent launch (warm cache) just mmaps the
            // result in ~5 s. We can tell which we're on because
            // `engineFirstRun` flips when we observe a weights
            // download earlier in the boot — only first runs hit
            // that path, since cached binaries skip download.
            if engineFirstRun {
                return "loading expression engine — compiling ANE shaders… (~2–3 min ONE-TIME first run)"
            } else {
                return "loading expression engine — loading from ANED cache… (~5 s, cached on first run)"
            }
        case .loadingEssenceRuntime:
            return "loading essence runtime…"
        case .connectingRealtime:
            return "connecting to OpenAI Realtime…"
        case .prewarmingIdle(let p):
            return "warming up models — \(Int(p * 100))% (~10 s)"
        case .ready:
            return "ready"
        }
    }

    /// Optional secondary line — bytes / rate / ETA for downloads,
    /// nil for opaque phases. Rendered after the caption in terminal
    /// mode and tucked under the splash bar in video mode.
    public var detail: String? { Self.detail(for: phase) }

    public static func detail(for phase: Phase) -> String? {
        switch phase {
        case .downloadingEngine(let received, let total, let bps, let eta):
            let mibR = Double(received) / 1_048_576
            let mibT = Double(total) / 1_048_576
            let mbps = bps / 1_000_000
            var s = String(format: "%.0f / %.0f MiB · %.1f MB/s", mibR, mibT, mbps)
            if let eta {
                s += " · ETA \(formatETA(eta))"
            }
            return s
        default:
            return nil
        }
    }

    /// 0..1 progress fraction for phases that have one; nil for
    /// opaque or download phases (which surface `received/total` via
    /// ``detail`` instead of a single fraction). Lets the splash
    /// pick determinate vs indeterminate spinner.
    public var progress: Double? { Self.progress(for: phase) }

    public static func progress(for phase: Phase) -> Double? {
        switch phase {
        case .downloadingEngine(let received, let total, _, _):
            return total > 0 ? Double(received) / Double(total) : nil
        case .loadingLLM(let p):
            return p
        case .loadingTTS(let p):
            return p
        case .prewarmingIdle(let p):
            return p
        case .idle, .verifyingEngine, .loadingSpeechModel,
             .openingAudioGraph, .authenticating,
             .loadingExpressionEngine, .loadingEssenceRuntime,
             .connectingRealtime, .ready:
            return nil
        }
    }

    /// True once the conversation surface is interactive. Splash +
    /// terminal renderer both drop their UI on this transition.
    public var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private static func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        return r == 0 ? "\(m)m" : "\(m)m\(r)s"
    }
}
