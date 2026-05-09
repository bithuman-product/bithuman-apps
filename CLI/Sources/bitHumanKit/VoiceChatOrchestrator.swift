import Combine
import Foundation
import MLX
import os

/// Sendable wrapper around a Bool, set on the MainActor and read
/// from any thread. Shared between `VoiceChat`, `VoiceChatOrchestrator`,
/// and the CLI's `FramePump` so different code paths can coordinate
/// access to the (single, global) MLX runtime — concurrent
/// dispatches from chat LLM, idle DiT, VAE face encode, etc. all
/// race the same shared compiler cache and segfault under load.
///
/// Two instances live on `VoiceChat`: `llmActivity` (set during a
/// turn) and `swapActivity` (set during a face swap). The avatar
/// producer skips idle DiT while either is active.
public final class ActivityFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<Bool>(initialState: false)
    public init() {}
    public func set(_ active: Bool) {
        state.withLock { $0 = active }
    }
    public var isActive: Bool {
        state.withLock { $0 }
    }
}

/// Central state machine for the turn-taking pipeline.
///
/// States transition on these events:
///   - user speech partial    → possible barge-in
///   - user speech final      → commit turn, trigger LLM
///   - LLM delta / completion → stream into TTS
///   - TTS completion         → back to listening
///
/// Barge-in: any non-empty partial OR a mic energy spike during
/// thinking/speaking cancels the in-flight LLM task and stops the
/// TTS queue before handing the new utterance to the ASR final path.
@MainActor
public final class VoiceChatOrchestrator: ObservableObject {
    public enum State: Sendable {
        case idle
        case listening
        case thinking
        case speaking
    }

    private let graph: AudioGraph
    private let speech: SpeechPipeline
    private let llm: LLMClient
    private let tts: any TTSPlayer

    @Published public private(set) var state: State = .idle {
        didSet { onStateTransition(from: oldValue, to: state) }
    }
    /// Shared with `VoiceChat.llmActivity` so the avatar `FramePump`
    /// producer (off-main) can skip idle DiT dispatches while we own
    /// MLX. See `ActivityFlag` doc for the cache-race rationale.
    private let llmActivity: ActivityFlag
    /// Shared with `VoiceChat.swapActivity`. We read this in
    /// `onFinal` to drop user-spoken turns while a VAE face encode
    /// is in flight — running LLM + TTS concurrently with VAE
    /// stresses MLX's shared cache and risks a crash.
    private let swapActivity: ActivityFlag
    /// Set true while the bot's audio is playing (and for a short
    /// grace period after, to cover speaker-echo tail). The mic
    /// pump reads this and skips pushing buffers to the speech
    /// analyzer while it's set — without that gate, AEC residual
    /// of the bot's own voice gets transcribed as "user input" and
    /// triggers a self-talk loop. Energy-based barge-in (8× ambient
    /// in video mode) prevents the same residual from triggering
    /// the energy-spike path.
    private let botSpeaking: ActivityFlag
    private var botSpeakingClearTask: Task<Void, Never>?
    /// Speaker-echo tail grace after the bot stops speaking. Long
    /// enough to cover the audio buffer playing out of the speakers
    /// after we believe the turn is done; short enough that the
    /// user can speak again without feeling muted.
    private static let botSpeakingGraceNanos: UInt64 = 250_000_000  // 0.25 s
    private var turnTask: Task<Void, Never>?
    private var micPumpTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var energyTask: Task<Void, Never>?
    private var ambientRMS: Float = 0.0008
    private var aboveCount: Int = 0
    /// Single-buffer trigger gives the lowest perceived "agent
    /// stopped talking" latency. False trips from a single noise
    /// glitch are mitigated by the energy threshold being a multiple
    /// of ambient RMS in onEnergy. Same setting in voice and video
    /// modes — the chunk-paired audio path keeps AEC's reference
    /// signal in step with the actual playback so the bot's own
    /// audio cancels cleanly out of the mic channel.
    private static let voiceRunLength = 1

    /// Reserved for future divergence between voice and video
    /// barge-in tuning. Currently a no-op.
    var avatarOwnsPlayback: Bool = false

    /// Hook fired after barge-in's `tts.cancelAll()` so VoiceChat
    /// can clear avatar-engine state (drop pending audio + queued
    /// chunks via `Bithuman.interrupt()`) and notify the FramePump
    /// to flush already-buffered speech frames. Without this, the
    /// avatar keeps animating the previous reply for several
    /// seconds after the user has cut in.
    var onBargeIn: (@Sendable () async -> Void)?

    /// Wait for the avatar pipeline to fully drain at end-of-turn.
    /// Voice-mode `tts.awaitDrain()` only waits for the player
    /// queue, but in video mode the TTS→engine→avatar-audio chain
    /// has additional buffers upstream:
    ///   - engine `pendingAudio16Count` (samples queued for DiT)
    ///   - engine `chunkQueueCount` (decoded TimedChunks ready)
    ///   - FramePump's frame buffer (speech frames not yet rendered)
    /// Without waiting for ALL of these, state flips to .listening
    /// while the bot is still speaking — the user's voice during
    /// the reply then hits the .listening branch (no barge-in)
    /// instead of triggering the cancel path.
    var onAwaitAvatarDrain: (@Sendable () async -> Void)?

    /// Streaming user-speech caption. Called every time the speech
    /// transcriber emits a partial (incremental rolling text) — the
    /// host UI can render this live so the user sees what the
    /// transcriber is hearing, even before the final.
    var onUserPartial: (@Sendable (String) -> Void)?

    /// Final user transcript for the current utterance. Called
    /// once per utterance after `.final` is emitted. The host UI
    /// typically replaces the rolling partial display with this.
    var onUserFinal: (@Sendable (String) -> Void)?

    /// Streaming bot text — called for each LLM token chunk in the
    /// current turn. The host UI can append these to a rolling
    /// caption. `onBotTurnEnd` signals when the turn is complete.
    var onBotChunk: (@Sendable (String) -> Void)?

    /// Bot turn boundary. Fired once per turn after the LLM stream
    /// ends (or is cancelled by barge-in). The host UI typically
    /// uses this to know when to clear the rolling bot caption.
    var onBotTurnEnd: (@Sendable () -> Void)?

    init(
        graph: AudioGraph,
        speech: SpeechPipeline,
        llm: LLMClient,
        tts: any TTSPlayer,
        llmActivity: ActivityFlag,
        swapActivity: ActivityFlag,
        botSpeaking: ActivityFlag
    ) {
        self.graph = graph
        self.speech = speech
        self.llm = llm
        self.tts = tts
        self.llmActivity = llmActivity
        self.swapActivity = swapActivity
        self.botSpeaking = botSpeaking
    }

    /// Property-observer hook for `state`. Owns the `botSpeaking`
    /// flag so the mic pump can mute ASR while the bot is talking
    /// (closing the self-talk loop). A 250 ms grace period after
    /// the bot stops speaking covers the speaker-echo tail.
    private func onStateTransition(from oldValue: State, to newValue: State) {
        if newValue == .speaking {
            // Cancel any pending clear from a previous .speaking
            // → other-state transition; we're back to speaking.
            botSpeakingClearTask?.cancel()
            botSpeakingClearTask = nil
            botSpeaking.set(true)
        } else if oldValue == .speaking {
            botSpeakingClearTask?.cancel()
            botSpeakingClearTask = Task { [botSpeaking] in
                try? await Task.sleep(nanoseconds: Self.botSpeakingGraceNanos)
                if !Task.isCancelled {
                    botSpeaking.set(false)
                    // Reclaim the MLX buffer pool that grew during this
                    // turn (LLM activations, TTS Mel buffers, DiT
                    // transients). Live MLXArrays are unaffected; only
                    // the unused slabs MLX hangs on to for re-use are
                    // released back to the OS. Idle frame generation
                    // pays a one-time alloc latency on the next
                    // dispatch, then the cache repopulates as needed.
                    MLX.Memory.clearCache()
                }
            }
        }
    }

    /// Tear everything down. Idempotent. Cancels in-flight tasks,
    /// stops the audio engine, finalises the speech analyzer, drops
    /// any queued TTS audio.
    func stop() async {
        turnTask?.cancel()
        micPumpTask?.cancel()
        eventTask?.cancel()
        energyTask?.cancel()
        await graph.stop()
        await speech.stop()
        await tts.cancelAll()
    }

    func start() async throws {
        try await graph.start()
        state = .listening
        // Bitman-branded ready banner — matches the shape used by
        // the cloud voice + text paths (`bithuman-cli · X chat ·
        // by bitHuman Inc.`). Only fires for the on-device voice
        // pipeline; the cloud-voice path renders its own banner via
        // `TerminalUI.printOpeningBanner`.
        let bold = "\u{1B}[1m"
        let dim = "\u{1B}[2m"
        let cyan = "\u{1B}[36m"
        let reset = "\u{1B}[0m"
        let rule = "\(dim)\(String(repeating: "━", count: 60))\(reset)"
        print("""

        \(rule)

          \(bold)bithuman-cli\(reset)  \(dim)·  voice chat (on-device)\(reset)
          \(dim)by\(reset) \(bold)bitHuman Inc.\(reset)  \(dim)·  https://www.bithuman.ai\(reset)

          \(dim)backend:\(reset) \(cyan)Gemma + Qwen3-TTS + Apple SpeechAnalyzer\(reset) \(dim)(local)\(reset)

          \(dim)🎙️  listening. talk any time · ctrl-c to exit\(reset)

        \(rule)

        """)

        micPumpTask = Task { [graph, speech, botSpeaking] in
            for await buffer in graph.micBuffers {
                // Mute ASR while the bot is speaking (and during
                // the 250 ms speaker-echo tail). AEC reduces the
                // bot's voice in the mic stream but doesn't always
                // null it completely — Apple SpeechAnalyzer
                // happily transcribes the residual and feeds it
                // into `onFinal`, looping the bot back at itself.
                // Skipping the push entirely closes the loop.
                if botSpeaking.isActive { continue }
                await speech.push(buffer)
            }
        }
        eventTask = Task { [weak self, speech] in
            for await event in speech.events {
                await self?.handle(event)
            }
        }
        energyTask = Task { [weak self, graph] in
            for await rms in graph.micEnergy {
                await self?.onEnergy(rms)
            }
        }

        // Warm the LLM in parallel with the first turn.
        Task { [llm] in await llm.prewarm() }
    }

    /// Inject a user message as if it had come from the speech
    /// transcriber. Lets a CLI host stitch a stdin reader into the
    /// orchestrator so users can type during a video session.
    public func inject(userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Echo the typed line through the same writeLine path the
        // ASR-final branch uses, so the formatting stays consistent.
        writeLine(prefix: Self.userPrefix, text: trimmed, sameLine: false)
        await onFinalText(trimmed, alreadyEchoed: true)
    }

    /// Fast-path barge-in: cut audio on mic energy (~21 ms) instead
    /// of waiting for a transcriber partial (hundreds of ms).
    private func onEnergy(_ rms: Float) async {
        if state != .speaking {
            ambientRMS = 0.95 * ambientRMS + 0.05 * rms
            aboveCount = 0
            return
        }
        // While the bot is actively producing audio
        // (`botSpeaking.isActive`), gate energy-based barge-in
        // entirely. iPhone's mic-and-speaker proximity makes AEC
        // residual hard to bound by RMS multiplier alone; even at
        // 12× ambient we observed self-interrupts every couple of
        // seconds. ASR-text barge-in (via partials, gated by the
        // mic-pump-skip below) remains the user's interrupt path —
        // they can still cut the bot off by speaking, the latency is
        // just transcriber-bound (~150-300 ms) instead of
        // energy-bound (~21 ms). Worth it to keep the conversation
        // flowing without false stops.
        if botSpeaking.isActive { return }

        // Video mode: keep raising the bar a touch (8× ambient
        // instead of 6×) since AEC residual occasionally pokes
        // above 6×. Bot's own audio reads cleanly above ambient
        // because of the chunk-paired playback path; we want only
        // the *user's* voice to break through.
        let threshold = max(0.01, ambientRMS * (avatarOwnsPlayback ? 8 : 6))
        if rms > threshold {
            aboveCount += 1
            if aboveCount >= Self.voiceRunLength {
                aboveCount = 0
                printInterrupt()
                turnTask?.cancel()
                await llm.cancel()
                await tts.cancelAll()
                await onBargeIn?()
                state = .listening
            }
        } else {
            aboveCount = 0
        }
    }

    private func handle(_ event: SpeechEvent) async {
        switch event {
        case .partial(let text): await onPartial(text)
        case .final(let text):   await onFinal(text)
        }
    }

    private func onPartial(_ text: String) async {
        switch state {
        case .idle, .listening:
            writeLine(prefix: Self.userPrefix, text: text, sameLine: true)
            onUserPartial?(text)
        case .thinking:
            // Don't barge-in while the LLM is mid-think. The mic pump
            // doesn't get gated until `state == .speaking` flips
            // `botSpeaking.isActive`, so during `.thinking` the user's
            // own continued voice OR speaker-echo from an earlier
            // utterance leaks into ASR and would cancel the in-flight
            // LLM before it produces a single token. Just refresh the
            // caption; the LLM is allowed to finish thinking.
            writeLine(prefix: Self.userPrefix, text: text, sameLine: true)
            onUserPartial?(text)
        case .speaking:
            // The mic pump already skips audio while `botSpeaking.isActive`,
            // so SpeechAnalyzer normally shouldn't emit partials here.
            // It still does occasionally — a lagging partial from audio
            // SpeechAnalyzer had already accepted before the gate
            // closed. Treat those as echo/residual and refresh the
            // caption instead of barging in. A genuine user interrupt
            // arrives via the .listening branch once botSpeaking
            // releases (250 ms after the bot's last buffer drains).
            if botSpeaking.isActive {
                writeLine(prefix: Self.userPrefix, text: text, sameLine: true)
                onUserPartial?(text)
                return
            }
            printInterrupt()
            turnTask?.cancel()
            await llm.cancel()
            await tts.cancelAll()
            await onBargeIn?()
            state = .listening
            writeLine(prefix: Self.userPrefix, text: text, sameLine: true)
            onUserPartial?(text)
        }
    }

    private func onFinal(_ text: String) async {
        await onFinalText(text, alreadyEchoed: false)
    }

    /// Shared path for ASR-final and stdin-injected user text.
    /// `alreadyEchoed` is true when the caller (e.g. `inject`) has
    /// already printed the user line — we just need the post-line
    /// blank and the bot prefix.
    private func onFinalText(_ text: String, alreadyEchoed: Bool) async {
        guard !text.isEmpty else { return }
        if !alreadyEchoed {
            writeLine(prefix: Self.userPrefix, text: text, sameLine: false)
        }
        onUserFinal?(text)
        print("")

        // If the user is mid-swap (VAE encoding their new face),
        // don't kick off a turn — running the LLM + TTS concurrently
        // with VAE encode stresses MLX's shared compiler cache and
        // risks a crash. The CraftingSpinner overlay tells the user
        // the system is busy; we'll pick up their next utterance
        // once the swap completes.
        if swapActivity.isActive {
            print("\(Self.dimStyle)⏳ still loading the new face — give me a moment.\(Self.resetStyle)\n")
            return
        }

        state = .thinking
        print("\(Self.botPrefix) ", terminator: "")
        fflush(stdout)

        turnTask?.cancel()
        let captured = text
        turnTask = Task { [weak self] in
            await self?.runTurn(userText: captured)
        }
    }

    private func runTurn(userText: String) async {
        var sentenceBuf = ""
        var spokeSomething = false

        // Block idle avatar DiT dispatches while the LLM owns MLX —
        // see `ActivityFlag` doc for the cache-race rationale.
        llmActivity.set(true)
        defer { llmActivity.set(false) }

        let stream = await llm.deltas(for: userText)
        defer { onBotTurnEnd?() }
        do {
            for try await delta in stream {
                try Task.checkCancellation()
                print(delta, terminator: "")
                fflush(stdout)
                onBotChunk?(delta)
                sentenceBuf += delta
                while let cut = sentenceBuf.firstIndex(where: { ".!?\n".contains($0) }) {
                    let end = sentenceBuf.index(after: cut)
                    let sentence = String(sentenceBuf[..<end])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    sentenceBuf.removeSubrange(sentenceBuf.startIndex..<end)
                    if !sentence.isEmpty {
                        if !spokeSomething {
                            state = .speaking
                            spokeSomething = true
                        }
                        _ = await tts.speak(sentence)
                        #if os(iOS)
                        // iPhone: serialize sentence playback. Without
                        // this, sentence N+1 starts synthesizing while
                        // sentence N is still playing — multiple Mel
                        // buffers + Essence chunk queues stack up and
                        // peak memory exceeds the per-app jetsam cap on
                        // verbose replies. Cost is one TTS-render-pass
                        // of latency between sentences (~150-300 ms),
                        // worth it for stability.
                        // NOTE: don't call `MLX.Memory.clearCache()`
                        // here — the LLM is still mid-token-generation
                        // on its own MLX context, and a clearCache
                        // dispatched from this actor races with the
                        // LLM's compiler-cache hash table (see project
                        // memory `MLX compiler cache race`). Reclaim
                        // happens in `onStateTransition` after the
                        // `.speaking → .listening` flip instead.
                        await tts.awaitDrain()
                        #endif
                    }
                    try Task.checkCancellation()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            Log.llm.error("turn: \(error.localizedDescription, privacy: .public)")
        }

        let tail = sentenceBuf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, !Task.isCancelled {
            if !spokeSomething {
                state = .speaking
                spokeSomething = true
            }
            _ = await tts.speak(tail)
        }

        print("")
        if spokeSomething {
            if avatarOwnsPlayback, let drain = onAwaitAvatarDrain {
                await drain()
            } else {
                await tts.awaitDrain()
            }
        }
        if !Task.isCancelled && state != .listening {
            state = .listening
        }
    }

    private func writeLine(prefix: String, text: String, sameLine: Bool) {
        let clear = "\r\u{1B}[2K"
        if sameLine {
            print("\(clear)\(prefix) \(text)", terminator: "")
            fflush(stdout)
        } else {
            print("\(clear)\(prefix) \(text)")
        }
    }

    /// Soft-styled "(interrupted)" marker that replaces the older
    /// "🛑 interrupted" shout. Indented so it visually attaches to
    /// the cut-off bot line, dim so it doesn't compete for attention.
    private func printInterrupt() {
        print("\n     \(Self.dimStyle)(interrupted)\(Self.resetStyle)\n")
    }

    // MARK: - Styling

    /// ANSI-styled labels. macOS Terminal + iTerm + Warp all
    /// interpret these. Falls back to plain text if the terminal
    /// strips them; the labels still read correctly.
    // Conversation labels — cyan `[me]` for the human side, magenta
    // `[bitHuman]` for the model. Same shape used by the cloud-voice
    // and text-chat renderers; consistency across modes makes
    // recordings + screenshots interchangeable.
    private static let userPrefix = "\u{1B}[36m[me]\u{1B}[0m"
    private static let botPrefix  = "\u{1B}[35m[bitHuman]\u{1B}[0m"
    private static let dimStyle   = "\u{1B}[2m"
    private static let resetStyle = "\u{1B}[0m"
}
