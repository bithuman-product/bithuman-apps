import AVFoundation
import CoreGraphics
import Foundation
import MLX
import Speech

/// Configuration for a `VoiceChat` session.
///
/// Every field has a sensible default — `VoiceChatConfig()` runs the
/// stack as it ships (English locale, bundled cloned voice, built-in
/// system prompt). Override only what you need to.
public struct VoiceChatConfig: Sendable {
    /// BCP-47 locale identifier (e.g. `"en-US"`, `"ja-JP"`). Drives
    /// both ASR (Apple SpeechAnalyzer) and TTS language hints.
    public var localeIdentifier: String = "en-US"

    /// Voice for TTS. `.default` uses the bundled reference clip;
    /// `.preset(name)` picks a Qwen3-TTS built-in speaker;
    /// `.clone(URL, transcript)` clones a user-supplied recording.
    public var voice: VoiceSelection = .default

    /// LLM system prompt. `nil` uses the library's default (a short
    /// conversational assistant prompt). Pass any string to override.
    public var systemPrompt: String? = nil

    /// When true, install the process-wide stdout filter that strips
    /// noisy `print()` chatter from mlx-audio-swift. CLI use wants
    /// this on; embedded library use may want it off so the host app
    /// keeps full control of stdout.
    public var installStdoutFilter: Bool = true

    /// Optional avatar configuration. When set, `VoiceChat.start()`
    /// loads the bitHuman expression engine and pumps live TTS audio
    /// through it; the rendered chunks are exposed via the public
    /// `bithuman` property for the consumer to drain on its own
    /// display timer. Nil = audio-only chat (the original behaviour).
    public var avatar: AvatarConfig? = nil

    /// Shape the avatar window / renderer should adopt. Defaults to
    /// ``AvatarShape/auto``, which derives from the loaded model's
    /// `manifest.model_type`: Essence → ``AvatarShape/fill``
    /// (rectangular full-frame), Expression → ``AvatarShape/circle``
    /// (legacy round window). Override only if you want, e.g.,
    /// Expression in a rectangular Picture-in-Picture, or an Essence
    /// portrait cropped into a circular contact-card zone.
    public var avatarShape: AvatarShape = .auto

    /// **Required for the avatar pipeline.** bitHuman developer API
    /// secret — get one at https://www.bithuman.ai → Developer →
    /// API Keys. The SDK runs a heartbeat to the bitHuman billing
    /// service every 60 s while the avatar engine is alive, charging
    /// 2 credits per active minute against this key's balance.
    ///
    /// If `apiKey` is nil at `start()` time, the SDK falls back to
    /// the `BITHUMAN_API_KEY` environment variable. If both are
    /// empty AND `avatar` is set, `start()` throws
    /// `VoiceChatError.missingAPIKey`. Audio-only mode (no `avatar`)
    /// runs unmetered; only the avatar pipeline is billed.
    public var apiKey: String? = nil

    /// Optional ``BootProgress`` sink. When non-nil, every cold-start
    /// stage (LLM load, TTS load, audio graph, auth, expression
    /// engine load, idle prewarm) updates this object instead of
    /// being printed straight to stderr. Hosts (CLI / .app) attach
    /// either ``TerminalProgressRenderer`` or a SwiftUI splash to
    /// the same instance so the user has a unified progress UI
    /// during the long boot pipeline.
    public var bootProgress: BootProgress? = nil

    public init() {}
}

/// Configuration for the optional avatar pipeline. Only consumed when
/// attached to a `VoiceChatConfig.avatar`.
public struct AvatarConfig: Sendable {
    /// Path to the expression weights file (`.bhx` for the
    /// universal pre-quantized artifact, `.imx` for legacy fp16
    /// per-identity bundles — both parse the same; the loader
    /// detects pre-quantization at extract time).
    /// Use `ExpressionWeights.ensureAvailable()` to download / cache /
    /// verify on first run.
    public var modelPath: URL

    /// Optional portrait image to clone the bot's face from. Auto-
    /// cropped via Vision face detection. `nil` uses the bundled
    /// default identity baked into the model file.
    public var portraitPath: URL? = nil

    /// Render quality. `.medium` is realtime-safe at 384x384 on M3+;
    /// `.high` is offline-only on most hardware.
    public var quality: Bithuman.Quality = .medium

    public init(modelPath: URL, portraitPath: URL? = nil, quality: Bithuman.Quality = .medium) {
        self.modelPath = modelPath
        self.portraitPath = portraitPath
        self.quality = quality
    }
}

/// Default LLM persona used when `VoiceChatConfig.systemPrompt` is nil.
public let defaultSystemPrompt: String = """
You are a friendly voice assistant on a Mac. Keep replies short — 1 to 3 sentences.
Speak naturally, like a conversation. Don't read long lists or code blocks aloud.
If a question is ambiguous, ask a brief clarifying question instead of guessing.
"""

/// Suffix appended to every system prompt before it reaches the LLM.
/// The TTS pipeline (Kokoro / Qwen3-TTS) reads emojis and symbols
/// literally — "smile face emoji", random clicks, dropped phrasing,
/// or just awkward pauses. Applies whether the persona is the
/// default, a bundled `Agent.systemPrompt`, or a user override
/// from the prompt editor; the suffix is appended in `VoiceChat`'s
/// `LLMClient` construction and in `setSystemPrompt`, so the rule
/// holds across hot-swaps too.
internal let ttsStyleSuffix: String = """

Spoken-output rules: never include emoji, emoticons, or decorative symbols (★ ✓ → etc.) in your replies. Don't use markdown formatting (no asterisks for emphasis, no bullet points, no headers). Don't read URLs aloud unless asked. Write as if every word will be spoken by a text-to-speech voice.
"""

/// Compose the final instruction string handed to the LLM —
/// caller-supplied prompt + the TTS-friendly suffix. Public so
/// host apps can reuse the exact wording when they need to inspect
/// or display "what the LLM is told"; internal callers go through
/// `VoiceChat`'s constructor / `setSystemPrompt`.
public func composeLLMInstructions(_ prompt: String) -> String {
    prompt + ttsStyleSuffix
}

/// High-level entry point. One instance owns one live conversation
/// session — the audio engine, the speech analyzer, the LLM, and the
/// TTS pipeline. Construct, call `start()`, talk to your laptop. Call
/// `stop()` (or let the process exit) when you're done.
///
/// Use:
/// ```swift
/// import bitHumanKit
///
/// let chat = await VoiceChat()
/// try await chat.start()
/// // …live conversation runs until the process exits…
/// ```
@MainActor
public final class VoiceChat {
    private let config: VoiceChatConfig
    /// The active orchestrator. Public so SwiftUI consumers can
    /// observe its `@Published var state` for the UI state pill.
    /// Nil until `start()` has run.
    public private(set) var orchestrator: VoiceChatOrchestrator?
    private var avatarBridge: AvatarAudioBridge?
    private var graph: AudioGraph?
    private var tts: (any TTSPlayer)?
    private var llm: LLMClient?

    /// The avatar engine, if `config.avatar` was set. Consumers poll
    /// `tryDequeueChunk()` on this from a 25 FPS display timer to
    /// drive a window. `nil` for audio-only sessions.
    public private(set) var bithuman: Bithuman?

    /// First static idle frame rendered after the engine boots. Use
    /// as a backdrop while audio-driven frames start streaming. Nil
    /// when `config.avatar` is unset OR the bundle has no baked-in
    /// idle face.
    public private(set) var initialIdleFrame: CGImage?

    /// Billing heartbeat for the avatar pipeline. Non-nil only
    /// when `config.avatar` is set and `start()` has succeeded.
    /// Public so callers can poll `heartbeat?.fatalError` to detect
    /// a session that's been terminated mid-conversation by
    /// 402 (insufficient balance) or 403 (account suspended).
    public private(set) var heartbeat: BithumanHeartbeat?

    /// Fired right after barge-in cancels TTS + the avatar engine.
    /// Consumers (the FramePump in CLI) use this to flush already-
    /// buffered speech frames so the avatar transitions to idle
    /// motion immediately instead of finishing a reply that was
    /// interrupted seconds ago.
    public var onBargeIn: (@Sendable () -> Void)?

    /// Polled by `awaitAvatarDrain()` once per check. Consumers
    /// (the FramePump) return `true` when they have no buffered
    /// speech frames left to render. Used to decide that the
    /// pipeline has fully drained and the orchestrator can flip
    /// back to `.listening`.
    public var onCheckSpeechBuffer: (@Sendable () -> Bool)?

    /// Streaming user-speech caption hook. Each ASR partial fires
    /// this with the rolling text. Set this from the host UI to
    /// render live captions while the user is speaking.
    public var onUserPartial: (@Sendable (String) -> Void)?

    /// Final user transcript, called once per utterance after the
    /// ASR `.final` event. The host UI typically replaces the
    /// rolling partial display with this.
    public var onUserFinal: (@Sendable (String) -> Void)?

    /// Streaming bot-text hook. Each LLM token chunk fires this in
    /// the order produced. Use to drive a live bot-caption overlay.
    public var onBotChunk: (@Sendable (String) -> Void)?

    /// Bot turn boundary, fired once when the LLM stream ends or
    /// is cancelled by barge-in. Use to decide when to clear the
    /// rolling bot-caption display.
    public var onBotTurnEnd: (@Sendable () -> Void)?

    /// Swap the avatar's face on the fly. The engine VAE-encodes
    /// the new portrait (~5 s on M5) and starts rendering with the
    /// new identity. Returns the new static idle frame on success
    /// (a backdrop the caller can flash before the audio-driven
    /// frames pick up). `nil` for image URLs that couldn't be
    /// face-detected; the engine falls back to a centre crop.
    @discardableResult
    public func swapAvatarPortrait(url: URL) async throws -> CGImage? {
        guard let bh = bithuman else { return nil }
        return try await bh.setIdentity(.image(url))
    }

    /// Hot-swap the TTS voice preset on whichever backend is active.
    /// `preset` is interpreted by the active player:
    ///   - **Kokoro** (Expression video mode): one of
    ///     ``availableAvatarVoices`` (`af_heart`, `am_michael`, …).
    ///   - **Qwen3** (voice mode + Essence video mode): one of
    ///     ``availableVoiceModePresets`` (`Cherry`, `Aiden`, …);
    ///     re-runs the speaker-embedding warmup against the preset
    ///     name so the timbre locks for the rest of the session.
    /// Effective on the next utterance; in-flight speak calls
    /// finish on the prior voice.
    public func setVoicePreset(_ preset: String) async {
        if let kokoro = tts as? KokoroTTSPlayer {
            await kokoro.setVoicePreset(preset)
        } else if let qwen3 = tts as? Qwen3TTSPlayer {
            try? await qwen3.setVoiceSelection(.preset(preset))
        }
    }

    /// Hot-swap the Qwen3 speaker reference to a cloned voice from
    /// an audio file. `transcript` is what's actually said in the
    /// audio; passing the right transcript helps prosody alignment.
    /// The Essence right-click "Clone voice from file…" menu uses
    /// this; the user picks a 6-20 s mono audio clip via NSOpenPanel
    /// and the CLI ASR-transcribes it before calling here.
    ///
    /// No-op when Kokoro is the active backend (no cloning support).
    public func setVoiceClone(audioURL: URL, transcript: String) async throws {
        if let qwen3 = tts as? Qwen3TTSPlayer {
            try await qwen3.setVoiceSelection(
                .clone(referenceAudio: audioURL, transcript: transcript)
            )
        }
    }

    /// True iff the active TTS backend supports voice cloning from
    /// a user-supplied reference audio file. UI surfaces (right-click
    /// menus) gate the "Clone from file…" item on this.
    public var supportsVoiceCloning: Bool {
        tts is Qwen3TTSPlayer
    }

    /// Curated list of Qwen3 voice presets. Mirrors
    /// ``availableAvatarVoices`` but for the cloning-capable backend
    /// (voice mode + Essence video mode). `nonisolated` because it
    /// reads a `static let` constant on `VoiceSelection`.
    public nonisolated static var availableVoiceModePresets: [String] {
        VoiceSelection.presetNames
    }

    /// Attach (or detach with `nil`) a PCM observer on the active TTS.
    /// Each emitted ``AVAudioPCMBuffer`` is the same chunk being
    /// scheduled to the speaker. Used by the Essence CLI path to fan
    /// out TTS audio into ``EssenceRuntime/pushAudio(_:)`` without
    /// going through the Expression-only ``AvatarConfig`` plumbing —
    /// Essence is wired up by the CLI host, not by `VoiceChat.start()`,
    /// because the two avatar runtimes drain audio at different rates
    /// (16 kHz Int16 for Essence vs the paired 24 kHz/16 kHz Float32
    /// the Expression engine wants), and trying to express both shapes
    /// through ``AvatarConfig`` is more complexity than it's worth for
    /// Phase 1. No-op until ``start()`` has wired up TTS.
    public func setPCMObserver(_ observer: (@Sendable (AVAudioPCMBuffer) -> Void)?) async {
        await tts?.setPCMObserver(observer)
    }

    /// Configure whether the TTS player suppresses its direct speaker
    /// route while a PCM observer is installed.
    ///
    /// `true` (the default the player initialises with) is correct
    /// for the Expression avatar pipeline — `AvatarAudioBridge`
    /// observes the audio for the engine, and the `FramePump`
    /// replays it in lockstep with rendered frames. Letting the TTS
    /// player play directly too would cause the audio to fire twice.
    ///
    /// `false` is correct for the Essence pipeline — there's no
    /// FramePump, so the user only hears the bot if the TTS player
    /// keeps playing directly. `EssencePCMBridge` just taps the
    /// audio for the runtime's per-frame lipsync.
    ///
    /// This is a separate setter from ``setPCMObserver(_:)`` so
    /// callers can change the policy at any time without re-installing
    /// the observer (and so existing call sites that only want the
    /// observer keep the old, suppress-default behavior).
    public func setSuppressDirectPlaybackWhenObserved(_ suppress: Bool) async {
        await tts?.setSuppressDirectPlaybackWhenObserved(suppress)
    }

    /// Curated list of Kokoro voice presets, exposed publicly so
    /// CLI consumers can populate UI pickers without reaching into
    /// the internal TTS player. `nonisolated` because the underlying
    /// `KokoroTTSPlayer.voicePresets` is a `static let` constant —
    /// no actor state involved, safe to read from anywhere.
    public nonisolated static var availableAvatarVoices: [String] {
        KokoroTTSPlayer.voicePresets
    }

    /// Block the calling thread until MLX's GPU stream has finished
    /// every pending command buffer. Call this from
    /// `applicationWillTerminate` so the process doesn't exit while
    /// the avatar's DiT or the chat LLM still has live command
    /// buffers — when those buffers complete after MLX's static
    /// scheduler has been torn down, their completion handler hits
    /// a destroyed `std::mutex`, throws `std::system_error`, and
    /// the process aborts with SIGABRT (a familiar entry in
    /// `~/Library/Logs/DiagnosticReports`). Drain first, then exit.
    public nonisolated static func drainGPU() {
        Stream.gpu.synchronize()
    }

    /// Audition `preset` by speaking `sample` through the speaker
    /// without committing the choice. Avatar lipsync is intentionally
    /// bypassed so the preview reads cleanly.
    public func previewVoice(_ preset: String, sample: String = "Hi! I'm here whenever you'd like to chat.") async {
        if let kokoro = tts as? KokoroTTSPlayer {
            await kokoro.preview(text: sample, voice: preset)
        }
    }

    /// Submit a user message as if the speech transcriber had
    /// produced it. Lets the CLI host route stdin lines into the
    /// orchestrator so users can type during a video session — same
    /// turn flow as a spoken utterance, just without the ASR step.
    public func inject(userText: String) async {
        await orchestrator?.inject(userText: userText)
    }

    /// Sendable, thread-safe flag set true while the LLM (Gemma) is
    /// generating tokens. The avatar `FramePump` reads it every
    /// producer-loop iteration to skip idle DiT dispatches when the
    /// LLM owns MLX. Without this gate, MLX's shared global compiler
    /// cache races between the chat-LLM thread and the avatar's
    /// flashhead.pipeline thread, segfaulting under load (observed
    /// in v0.4.1 crash report). Halo solves the same issue with its
    /// own setLLMGenerating(true/false) gate.
    public nonisolated let llmActivity = ActivityFlag()

    /// Sendable, thread-safe flag set true while the avatar's VAE
    /// face encoder is running (drag-drop / agent pick / picker).
    /// Producer skips idle DiT and orchestrator skips taking new
    /// turns while this is set — VAE + idle DiT + LLM streaming all
    /// dispatch through MLX, and concurrent dispatches race the
    /// shared compiler cache. UI-side, the CraftingSpinner overlay
    /// is shown so the user knows the system is busy.
    public nonisolated let swapActivity = ActivityFlag()

    /// Set while the bot is speaking (and ~250 ms after, for the
    /// speaker-echo tail). The mic pump skips pushing buffers to
    /// ASR while this is set, breaking the self-talk loop where
    /// AEC residual of the bot's own voice gets transcribed back
    /// as user input and triggers an infinite reply chain.
    public nonisolated let botSpeaking = ActivityFlag()

    /// Hot-swap the LLM system prompt. The next user utterance
    /// uses the new instructions; in-flight generation is
    /// cancelled so the next reply starts under the new persona.
    public func setSystemPrompt(_ prompt: String) async {
        await llm?.updateInstructions(composeLLMInstructions(prompt))
    }

    public init(config: VoiceChatConfig = VoiceChatConfig()) {
        self.config = config
    }

    /// Schedule a chunk of avatar-rendered audio (24 kHz mono Float32)
    /// for playback through the shared audio graph, in lockstep with
    /// the chunk's frame display. Avatar mode only — in audio-only
    /// mode the TTS player drives the speaker directly and this is a
    /// no-op. Returns once the buffer is queued on the player; the
    /// caller can immediately schedule the next chunk and the player
    /// will play them contiguously without gaps. Calls MUST be
    /// serialised by the caller — concurrent calls race and reorder.
    /// Schedule a chunk of avatar-rendered audio (24 kHz mono Float32)
    /// for playback through the shared audio graph, in lockstep with
    /// the chunk's frame display. Returns when the buffer is queued
    /// on the player; serialise calls (the avatar runloop does so).
    public func playAvatarAudio(samples24k: [Float]) async {
        guard let graph, let tts else { return }
        guard let pcm = makePCMBuffer(samples24k: samples24k) else { return }
        await tts.notifyAvatarScheduledBuffer()
        await graph.schedulePlayback(pcm) {
            Task { await tts.notifyAvatarPlayedBuffer() }
        }
    }


    /// Wrap a Float32 mono 24 kHz array as an AVAudioPCMBuffer.
    /// Same shape as `Qwen3TTSPlayer.makePCMBuffer` but for `[Float]`
    /// rather than MLXArray, so the avatar audio path can reuse the
    /// graph's existing format converter (24 kHz → 48 kHz VP-IO out).
    private func makePCMBuffer(samples24k: [Float]) -> AVAudioPCMBuffer? {
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )
        guard let fmt,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples24k.count)),
              let dst = buf.floatChannelData?[0]
        else { return nil }
        buf.frameLength = AVAudioFrameCount(samples24k.count)
        samples24k.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples24k.count)
        }
        return buf
    }

    /// Boot every component (mic permissions, ASR model, LLM model,
    /// TTS model, audio graph) and start the listen → reply loop.
    /// Returns once `🎙️  Listening` is printed and the orchestrator
    /// is processing speech events. Throws if mic access is denied
    /// or any model fails to load.
    public func start() async throws {
        // Hardware / OS preflight FIRST so a misconfigured machine
        // exits with a clear "macOS 26 needed" or "Apple Silicon
        // only" error instead of crashing 30 s into a model download.
        try Preflight.run()

        if config.installStdoutFilter {
            StdoutFilter.install()
        }
        try await requestPermissions()

        // Boot-progress wiring. When the host (CLI / .app) supplied a
        // BootProgress, we drive its phase through every cold-start
        // step instead of emitting bare print lines — the host's
        // renderer (terminal or SwiftUI splash) shows ONE unified UI
        // covering every download + load. Falls back to legacy
        // print()s when no progress sink is attached, so existing
        // library consumers see no behaviour change.
        let boot = config.bootProgress
        let silentBoot = boot != nil
        if silentBoot {
            boot?.update(.loadingSpeechModel)
        } else {
            print("🧠 initialising speech analyzer (first run may download a model)…")
        }
        let speech = try await SpeechPipeline(locale: Locale(identifier: config.localeIdentifier))

        if !silentBoot {
            print("🤖 loading on-device LLM (Gemma 4 E2B 4-bit, ~2 GB first run)…")
        }
        let llm = LLMClient(
            instructions: composeLLMInstructions(config.systemPrompt ?? defaultSystemPrompt),
            bootProgress: boot
        )
        self.llm = llm
        await llm.prewarm()

        if silentBoot {
            boot?.update(.openingAudioGraph)
        } else {
            print("🎚️  opening audio graph (mic + TTS, voice-processing on)…")
        }
        let graph = AudioGraph()
        self.graph = graph

        // TTS choice depends on whether the avatar is on. Qwen3 is
        // higher quality and supports voice cloning, but its 0.6 B
        // params contend with the avatar engine on Metal so audio
        // chops in video mode. Kokoro (~80 M) coexists cleanly.
        let tts: any TTSPlayer
        if silentBoot {
            boot?.update(.loadingTTS(progress: nil))
        }
        #if os(iOS)
        // iPhone always uses Kokoro regardless of `config.avatar`. The
        // Qwen3-TTS backend is too heavy for the per-app jetsam cap
        // (~700 MB resident, doesn't pair well with E2B + Essence) and
        // AVSpeechSynthesizer's system voices are too flat for
        // conversational use. Kokoro at ~80 MB is the right balance
        // for both Expression and Essence consumers on iPhone.
        if !silentBoot {
            print("🗣️  TTS: Kokoro 82M 4-bit (light, on-device)…")
        }
        tts = KokoroTTSPlayer(graph: graph)
        #else
        if config.avatar != nil {
            if !silentBoot {
                print("🗣️  TTS: Kokoro 82M 4-bit (light, avatar-friendly; first run downloads ~150 MB)…")
            }
            tts = KokoroTTSPlayer(graph: graph)
        } else {
            if !silentBoot {
                print("🗣️  TTS: Qwen3-TTS 0.6B 4-bit (first run downloads ~1 GB)…")
            }
            tts = Qwen3TTSPlayer(graph: graph, voice: config.voice)
        }
        #endif
        self.tts = tts
        await tts.prewarm()

        // Avatar pipeline (optional). Slotted in BEFORE the
        // orchestrator starts so the audio fan-out is wired before
        // the first TTS chunk could fire.
        if let avatarConfig = config.avatar {
            // Resolve the API key — config field wins, then
            // BITHUMAN_API_KEY env var, then refuse. Avatar mode is
            // metered at 2 credits/min; audio-only voice + text modes
            // run unmetered (no expression engine).
            let resolvedKey = config.apiKey
                ?? ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"]
            guard let apiKey = resolvedKey?.trimmingCharacters(in: .whitespaces),
                  !apiKey.isEmpty
            else {
                throw VoiceChatError.missingAPIKey
            }

            // Authenticate BEFORE the multi-second engine load, so a
            // bad key fails fast (~1 s) instead of after the user
            // waited through a 1.6 GB download + warm-up.
            if silentBoot {
                boot?.update(.authenticating)
            } else {
                print("🔐 authenticating with bitHuman billing service…")
            }
            let heartbeat = BithumanHeartbeat(
                config: BithumanAuthConfig(apiSecret: apiKey)
            )
            do {
                try await heartbeat.authenticate()
            } catch let err as BithumanAuthError {
                throw VoiceChatError.authenticationFailed(underlying: err)
            }
            self.heartbeat = heartbeat

            if silentBoot {
                boot?.update(.loadingExpressionEngine)
            } else {
                print("🎭 loading expression engine (~3.7 GB on disk; resident ~4 GB on Apple Silicon)…")
            }
            // Push the synchronous engine load off the main actor so
            // the UI keeps redrawing during the ~5 s mmap + quantize
            // pass. Without this hop, `VoiceChat` being @MainActor
            // means `Bithuman.create` blocks the main thread; SwiftUI
            // can't update @Published properties (boot splash freezes
            // mid-progress) until the engine load returns.
            let result = try await Task.detached(priority: .userInitiated) {
                try Bithuman.create(
                    modelPath: avatarConfig.modelPath,
                    identity: avatarConfig.portraitPath.map { .image($0) } ?? .default,
                    quality: avatarConfig.quality
                )
            }.value
            self.bithuman = result.bithuman
            self.initialIdleFrame = result.staticIdleImage

            // Start the periodic heartbeat now that auth + engine are
            // both up. Cancelled in `stop()`.
            await heartbeat.resume()

            // Profiling kill switch: BITHUMAN_AVATAR_AUDIO_OFF=1
            // suppresses the audio fan-out into the engine. Avatar
            // produces idle frames only; TTS audio is unaffected.
            // Useful for A/B baselines: with this set, audio quality
            // matches voice mode exactly. If chops disappear, the
            // root cause is Metal contention from avatar dispatch.
            if ProcessInfo.processInfo.environment["BITHUMAN_AVATAR_AUDIO_OFF"] == nil {
                let bridge = AvatarAudioBridge(bithuman: result.bithuman)
                self.avatarBridge = bridge
                await tts.setPCMObserver { pcm in
                    bridge.handle(pcm)
                }
                // No generation gate in video mode — Kokoro (~80 M)
                // coexists with the avatar engine on Metal without
                // throttling its per-token cadence, so we want both
                // running concurrently for live lip-sync.
            } else {
                FileHandle.standardError.write(Data(
                    "⚠️  BITHUMAN_AVATAR_AUDIO_OFF=1: lip-sync disabled, idle motion only.\n".utf8
                ))
            }
        }

        let orchestrator = VoiceChatOrchestrator(
            graph: graph, speech: speech, llm: llm, tts: tts,
            llmActivity: llmActivity, swapActivity: swapActivity,
            botSpeaking: botSpeaking
        )
        if config.avatar != nil {
            orchestrator.avatarOwnsPlayback = true
            let bh = self.bithuman
            // Barge-in cleanup. After tts.cancelAll() drops the TTS
            // streaming task + speaker queue, the avatar engine
            // still has pending audio + decoded chunks, and the
            // FramePump has buffered speech frames downstream. Drop
            // both so the avatar transitions to idle within ~40 ms.
            orchestrator.onBargeIn = { [weak self] in
                if let bh { await bh.interrupt() }
                await MainActor.run {
                    self?.onBargeIn?()
                }
            }
            // End-of-turn drain. Voice-mode `tts.awaitDrain()` only
            // covers the player queue. In video mode, several
            // upstream buffers must drain before state can flip
            // back to `.listening` (else the user's next utterance
            // hits .listening with no barge-in and the bot's audio
            // keeps playing). Poll every 50 ms; quiet means: TTS
            // drain done AND engine has no pending audio AND no
            // queued chunks AND the FramePump has no speech frames.
            orchestrator.onAwaitAvatarDrain = { [weak self, weak orchestrator] in
                await tts.awaitDrain()
                guard let bh else { return }
                while !Task.isCancelled {
                    let snap = bh.snapshot
                    let bufferEmpty = await MainActor.run { self?.onCheckSpeechBuffer?() ?? true }
                    if !snap.inFlight
                        && snap.pendingAudio16Count == 0
                        && bh.chunkQueueCount == 0
                        && bufferEmpty {
                        return
                    }
                    _ = orchestrator  // retained for the closure's lifetime
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        // Forward caption hooks from VoiceChat → orchestrator. Set
        // before start() so the host UI receives the very first
        // partial/final without missing events. The orchestrator's
        // hooks are non-isolated `@Sendable` closures; the
        // VoiceChat-side `onUserPartial` etc. are MainActor-isolated
        // properties, so each forwarder hops to MainActor before
        // dispatching the host's callback.
        orchestrator.onUserPartial = { [weak self] text in
            Task { @MainActor in self?.onUserPartial?(text) }
        }
        orchestrator.onUserFinal = { [weak self] text in
            Task { @MainActor in self?.onUserFinal?(text) }
        }
        orchestrator.onBotChunk = { [weak self] text in
            Task { @MainActor in self?.onBotChunk?(text) }
        }
        orchestrator.onBotTurnEnd = { [weak self] in
            Task { @MainActor in self?.onBotTurnEnd?() }
        }
        self.orchestrator = orchestrator
        try await orchestrator.start()
    }

    /// Tear down the audio engine, cancel the LLM, and close the
    /// transcript / cleanup paths. Idempotent.
    public func stop() async {
        await orchestrator?.stop()
        await heartbeat?.stop()
    }
}

/// Request the OS permissions VoiceChat needs (microphone + speech
/// recognition). Called automatically by `VoiceChat.start()`; library
/// users who want to handle the TCC prompts themselves can call this
/// directly before constructing `VoiceChat`.
public func requestPermissions() async throws {
    let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
    guard micGranted else { throw VoiceChatError.microphoneDenied }
    _ = await withCheckedContinuation { cont in
        SFSpeechRecognizer.requestAuthorization { status in
            cont.resume(returning: status)
        }
    }
}

public enum VoiceChatError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case microphoneDenied

    /// `config.avatar` was set but no API key was supplied via
    /// either `VoiceChatConfig.apiKey` or the `BITHUMAN_API_KEY`
    /// environment variable. The avatar pipeline is metered (2
    /// credits/minute against your bitHuman developer account)
    /// so a key is required. Audio-only mode (no avatar) doesn't
    /// require one.
    case missingAPIKey

    /// The supplied API key was rejected by the bitHuman billing
    /// service at session start. Common causes: revoked key,
    /// suspended account, insufficient balance to start a
    /// session. Inspect the underlying `BithumanAuthError`.
    case authenticationFailed(underlying: BithumanAuthError)

    public var description: String {
        switch self {
        case .microphoneDenied:
            return "Microphone access was denied. Open Settings → bitHuman → Microphone and enable it, then reopen the app."
        case .missingAPIKey:
            return """
            bitHumanKit: avatar mode requires an API key. Either set \
            VoiceChatConfig.apiKey or export BITHUMAN_API_KEY before \
            calling chat.start(). Get a key at \
            https://www.bithuman.ai → Developer → API Keys.
            """
        case .authenticationFailed(let underlying):
            return "bitHumanKit: authentication failed — \(underlying.description)"
        }
    }
    /// Read by `Error.localizedDescription` — without this, SwiftUI shows
    /// the generic "operation couldn't be completed" autobridge text.
    public var errorDescription: String? { description }
}
