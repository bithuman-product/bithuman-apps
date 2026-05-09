// TerminalUI — single-actor sink for everything the user sees.
//
// **What's on screen.**
//
//   ╭ scrolling history ──────────────────────────────╮
//   │ [14:23:00 ▆▆▆▅▃░] me:       Hello, can you hear me?    │
//   │ [14:23:01 ▇▇▇▆▆▅] bithuman: Yes, I can hear you …      │
//   │ [14:23:05 ▇▆▅▄▂░] me:       What can you do?            │
//   ╰─────────────────────────────────────────────────╯
//   ╭ live status (1 line, redrawn 10×/sec) ──────────╮
//   │ [14:23:10] 🟢 listening   🎙️ ████░░░░░ -32 dB   │
//   ╰─────────────────────────────────────────────────╯
//
// Each historical line carries a 6-bin loudness fingerprint between
// the timestamp and the speaker label — short bursts of louder
// audio spike higher cells, quiet patches read as ░. The fingerprint
// is built from level samples taken throughout the utterance so you
// can read the past at a glance.
//
// The live status row shows ONLY the side relevant to the current
// state (mic for listening/hearing, speaker for thinking/responding).
// Two side-by-side bars were mostly noise — only one is moving at any
// given moment.
//
// **Causal ordering.** OpenAI's realtime API emits the bot's
// `response.audio_transcript.delta` events as soon as it starts
// replying — *before* `input_audio_transcription.completed` arrives
// for the user's own utterance. Without buffering, the bot's reply
// shows up above the line that triggered it. We hold bot text until
// the user transcript commits, then flush in canonical order. Audio
// playback is unaffected; only the visible transcript is reordered.

import Foundation

public actor TerminalUI {
    // MARK: - Conversation state

    /// Where the conversation is right now. Drives the live status
    /// pill plus which audio side is metered (mic when listening or
    /// hearing the user; speaker when waiting on / playing a reply).
    public enum State {
        case listening    // idle, waiting for user
        case hearing      // user mid-utterance
        case thinking     // user done, waiting on server transcription/response
        case responding   // bot mid-reply (audio + text streaming)
    }

    private var state: State = .listening

    public init() {}

    public func setState(_ next: State) { state = next }

    // MARK: - Live audio levels (drive the status bar)

    private var micLevel: Float = 0
    private var botLevel: Float = 0

    public func setMicLevel(_ rms: Float) {
        micLevel = rms > micLevel ? rms : (micLevel * 0.7 + rms * 0.3)
        // Track per-utterance histogram while the user is talking.
        if state == .hearing { recordSample(.mic, rms: rms) }
    }

    public func setBotLevel(_ rms: Float) {
        botLevel = rms > botLevel ? rms : (botLevel * 0.7 + rms * 0.3)
        // Speaker tap fires whenever player has audio in flight, so
        // gating on `.responding` would miss the actual playback
        // window (response.done can arrive while audio still drains).
        // Just record any non-trivial level seen during the bot turn.
        if !activeBotText.isEmpty || !pendingBotText.isEmpty || state == .responding {
            recordSample(.bot, rms: rms)
        }
    }

    // MARK: - Per-utterance level histogram

    /// One sample slot per utterance, keyed by the side (mic for the
    /// user's turn, bot for the model's turn). Samples accumulate
    /// while the side is active and get rendered into a 6-cell mini
    /// bar embedded in the transcript line on commit.
    private enum Side { case mic, bot }
    private var micSamples: [Float] = []
    private var botSamples: [Float] = []

    private func recordSample(_ side: Side, rms: Float) {
        // Cap at a few seconds worth of samples so a long-winded
        // utterance doesn't grow unbounded. 1000 samples is ~50 s at
        // the speaker tap's ~20 Hz rate — overkill on purpose.
        switch side {
        case .mic:
            if micSamples.count < 1000 { micSamples.append(rms) }
        case .bot:
            if botSamples.count < 1000 { botSamples.append(rms) }
        }
    }

    /// Bin `samples` into `cells` equal-time chunks and render each
    /// chunk's max RMS as a graduated block character. Empty bins
    /// (utterance too short, or bot turn that produced no audio)
    /// render as `░` so the prefix is always the same width.
    private func histogramBar(_ samples: [Float], cells: Int = 6) -> String {
        guard !samples.isEmpty else {
            return String(repeating: "░", count: cells)
        }
        let blocks: [Character] = ["░", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        var out = ""
        for i in 0 ..< cells {
            let lo = i * samples.count / cells
            let hi = max(lo + 1, (i + 1) * samples.count / cells)
            let slice = samples[lo ..< min(hi, samples.count)]
            let peak = slice.max() ?? 0
            let dB = peak > 1e-7 ? max(-60, 20 * log10f(peak)) : -60
            let pct = (dB + 60) / 60  // 0…1
            let idx = max(0, min(blocks.count - 1, Int(pct * Float(blocks.count))))
            out.append(blocks[idx])
        }
        return out
    }

    // MARK: - Transcript ordering / state

    /// True between `speech_started`/`speech_stopped` and
    /// `input_audio_transcription.completed`. While set, bot chunks
    /// are buffered, not printed, so the user's transcript can be
    /// shown first when it arrives.
    private var awaitingUserTranscript = false

    /// Bot text accumulated while we wait on the user transcript.
    /// Flushed on `commitUserTranscript`.
    private var pendingBotText = ""

    /// Wall-clock when the user started speaking (set in
    /// ``userSpeechStarted``). The transcript line prefix uses this
    /// rather than `Date()` at commit time so the timestamp
    /// reflects when the user actually started speaking — not the
    /// later moment when the server's transcription pass finished.
    private var userTurnStartedAt: Date?

    /// `response.done` can fire before the user's
    /// `input_audio_transcription.completed`. Without buffering, the
    /// bot's reply prints into history above the line that triggered
    /// it. We hold the bot's final print until the user transcript
    /// arrives so visual order matches chronological order. A
    /// safety task flushes the deferred bot line after 3 s in case
    /// transcription gets dropped — better to show out-of-order than
    /// hide the bot's reply forever.
    private var deferredBotFinal = false
    private var deferredBotBar: String?
    private var deferredBotStamp: Date?
    private var deferredFlushTask: Task<Void, Never>?

    /// Whatever bot text is currently streaming. Re-rendered on the
    /// "active row" every tick so the user sees the reply grow as
    /// it arrives instead of having it wiped by the status redraw.
    /// Cleared on `endBotResponse` once the line is committed to
    /// scrolling history.
    private var activeBotText = ""

    /// Time captured when we first started buffering the current
    /// pending bot reply, so its timestamp prefix reflects when the
    /// bot started speaking rather than when we got around to
    /// printing the line.
    private var botTurnStartedAt: Date?

    // MARK: - Lifecycle

    private var renderTask: Task<Void, Never>?

    /// True once we've drawn the 2-row sticky area at least once, so
    /// `redraw()` knows it can move the cursor up 2 rows to reach the
    /// top of the area. Reset by `clearStickyArea()` after we move
    /// past the area to print a permanent transcript.
    private var stickyDrawn = false

    public func start() {
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 100_000_000)  // 10 Hz
            }
        }
    }

    public func stop() {
        renderTask?.cancel()
        renderTask = nil
        clearStickyArea()
    }

    // MARK: - Transcript events

    public func userSpeechStarted() {
        awaitingUserTranscript = true
        pendingBotText = ""
        micSamples.removeAll(keepingCapacity: true)
        userTurnStartedAt = Date()
    }

    public func commitUserTranscript(_ text: String) {
        // 1. Print user line first (chronologically the user spoke
        //    before the bot replied; visual history matches that).
        let userBar = histogramBar(micSamples)
        let userStamp = userTurnStartedAt ?? Date()
        let userLine = "\(timestampPrefixWithBar(at: userStamp, bar: userBar, color: "\u{1B}[36m")) \u{1B}[36m[me]\u{1B}[0m \(text)"
        printAboveStickyArea(userLine)
        micSamples.removeAll(keepingCapacity: true)
        userTurnStartedAt = nil
        awaitingUserTranscript = false

        // 2. If bot already finished while we were waiting, flush it
        //    now (after the user line). Cancels the safety timeout.
        if deferredBotFinal, !pendingBotText.isEmpty {
            flushDeferredBot()
        } else if !pendingBotText.isEmpty {
            // Bot still streaming — hand its buffered text off to
            // the active row so it continues to grow live.
            activeBotText = pendingBotText
            pendingBotText = ""
        }
    }

    private func flushDeferredBot() {
        let stamp = deferredBotStamp ?? Date()
        let bar = deferredBotBar ?? String(repeating: "░", count: 6)
        let botLine = "\(timestampPrefixWithBar(at: stamp, bar: bar, color: "\u{1B}[35m")) \u{1B}[35m[bitHuman]\u{1B}[0m \(pendingBotText)"
        printAboveStickyArea(botLine)
        pendingBotText = ""
        deferredBotFinal = false
        deferredBotBar = nil
        deferredBotStamp = nil
        botTurnStartedAt = nil
        deferredFlushTask?.cancel()
        deferredFlushTask = nil
    }

    public func botResponseStarted() {
        botSamples.removeAll(keepingCapacity: true)
        botTurnStartedAt = Date()
        activeBotText = ""
    }

    public func appendBotChunk(_ text: String) {
        if awaitingUserTranscript {
            pendingBotText += text
            return
        }
        // Append to the active row. The render tick picks it up.
        // We DON'T print directly — the previous design did, but the
        // status redraw 100 ms later wiped the bot text by clearing
        // the line it was streaming on.
        activeBotText += text
    }

    public func endBotResponse() {
        let bar = histogramBar(botSamples)
        let stamp = botTurnStartedAt ?? Date()
        if awaitingUserTranscript, !pendingBotText.isEmpty {
            // Bot finished before the user transcript came back.
            // Hold the print so commitUserTranscript can flush both
            // lines in chronological order. Set a 3 s safety task so
            // the bot line still appears even if transcription
            // never arrives (network glitch, model error, etc.).
            deferredBotFinal = true
            deferredBotBar = bar
            deferredBotStamp = stamp
            deferredFlushTask?.cancel()
            deferredFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                await self.flushDeferredBotIfStillPending()
            }
        } else if !activeBotText.isEmpty {
            let line = "\(timestampPrefixWithBar(at: stamp, bar: bar, color: "\u{1B}[35m")) \u{1B}[35m[bitHuman]\u{1B}[0m \(activeBotText)"
            printAboveStickyArea(line)
            activeBotText = ""
            botTurnStartedAt = nil
        } else if !pendingBotText.isEmpty {
            // No user transcript pending and we still have buffered
            // text — print it (this can happen on the very first
            // turn before any user speech, though rare).
            let line = "\(timestampPrefixWithBar(at: stamp, bar: bar, color: "\u{1B}[35m")) \u{1B}[35m[bitHuman]\u{1B}[0m \(pendingBotText)"
            printAboveStickyArea(line)
            pendingBotText = ""
            botTurnStartedAt = nil
        }
        botSamples.removeAll(keepingCapacity: true)
    }

    /// Safety net: if `commitUserTranscript` never arrives (rare —
    /// dropped event, server error), the deferred bot line would
    /// stay invisible forever. After 3 s, flush it anyway with
    /// chronologically-correct timestamps so the user can see the
    /// reply even if the visual order ends up reversed for that
    /// turn.
    private func flushDeferredBotIfStillPending() {
        guard deferredBotFinal, !pendingBotText.isEmpty else { return }
        flushDeferredBot()
    }

    public func cancelledBotResponse() {
        if !activeBotText.isEmpty {
            let bar = histogramBar(botSamples)
            let stamp = botTurnStartedAt ?? Date()
            let line = "\(timestampPrefixWithBar(at: stamp, bar: bar, color: "\u{1B}[35m")) \u{1B}[35m[bitHuman]\u{1B}[0m \(activeBotText) \u{1B}[2m⏹ (interrupted)\u{1B}[0m"
            printAboveStickyArea(line)
        }
        activeBotText = ""
        pendingBotText = ""
        botSamples.removeAll(keepingCapacity: true)
        botTurnStartedAt = nil
    }

    // MARK: - Generic prints

    /// Plain log line — no timestamp. Used for the boot banner.
    public func banner(_ text: String) {
        printAboveStickyArea(text)
    }

    /// Clear the screen + paint an opening banner so the swift-build
    /// noise (Planning build / Emitting module / etc.) is wiped from
    /// view and the user starts on a clean canvas. Design uses
    /// nothing but top + bottom horizontal rules — emoji width
    /// rendering differs across terminals so anything that requires
    /// columnar alignment (right borders, left accents on every row)
    /// will drift. Two rules + free-flowing content can't misalign.
    public func printOpeningBanner(
        model: String,
        voice: String,
        verbose: Bool,
        keyValidated: Bool,
        voiceKnown: Bool
    ) {
        write("\u{1B}[3J\u{1B}[2J\u{1B}[H")

        let bold = "\u{1B}[1m"
        let dim = "\u{1B}[2m"
        let cyan = "\u{1B}[36m"
        let magenta = "\u{1B}[35m"
        let green = "\u{1B}[32m"
        let yellow = "\u{1B}[33m"
        let red = "\u{1B}[31m"
        let reset = "\u{1B}[0m"

        let rule = "\(dim)\(String(repeating: "━", count: 60))\(reset)"

        write("\(rule)\n")
        write("\n")
        write("  \(bold)bithuman-cli\(reset)  \(dim)·  voice chat over OpenAI Realtime\(reset)\n")
        write("  \(dim)by\(reset) \(bold)bitHuman Inc.\(reset)  \(dim)·  https://www.bithuman.ai\(reset)\n")
        write("\n")
        write("  \(dim)model:\(reset)     \(cyan)\(model)\(reset)\n")
        write("  \(dim)voice:\(reset)     \(magenta)\(voice)\(reset)\n")
        write("  \(dim)transport:\(reset) WebRTC \(dim)(libwebrtc · AEC + NS + AGC built in)\(reset)\n")
        if verbose {
            write("  \(dim)verbose:\(reset)   on\n")
        }
        write("\n")
        if keyValidated {
            write("  \(green)✓\(reset) \(dim)OpenAI API key validated\(reset)\n")
        } else {
            write("  \(red)✗ OpenAI API key invalid\(reset) — generate a new one at\n")
            write("    \(dim)https://platform.openai.com/api-keys\(reset)\n")
        }
        if voiceKnown {
            write("  \(green)✓\(reset) \(dim)voice '\(voice)' is a known OpenAI Realtime voice\(reset)\n")
        } else {
            write("  \(yellow)!\(reset) \(dim)voice '\(voice)' isn't on the documented list — server may reject\(reset)\n")
            write("    \(dim)known: alloy, ash, ballad, coral, echo, sage, shimmer, verse, marin, cedar\(reset)\n")
        }
        write("\n")
        if keyValidated {
            write("  \(dim)speak any time · ctrl-c to exit\(reset)\n")
            write("\n")
        }
        write("\(rule)\n")
        write("\n")
    }

    /// Best-effort visible-width count: ignores ANSI SGR escapes
    /// and treats common emoji modifiers (variation selectors, ZWJ,
    /// skin tones) as zero columns so combined sequences like `🎙️`
    /// (microphone + U+FE0F variation selector) report 2 columns
    /// rather than 3, which used to drift the banner's right border
    /// one cell per emoji glyph.
    private nonisolated func visualWidth(of s: String) -> Int {
        var n = 0
        var inEscape = false
        for ch in s {
            if inEscape {
                // SGR / cursor sequences end on a final byte 0x40-0x7E.
                if ch == "m" || ch == "K" || ch == "H" || ch == "J"
                    || ch == "A" || ch == "B" || ch == "C" || ch == "D" {
                    inEscape = false
                }
                continue
            }
            if ch == "\u{1B}" {
                inEscape = true
                continue
            }
            // Zero-width modifiers must be subtracted so an emoji
            // grapheme cluster doesn't overcount. Iterate scalars
            // because `Character` packs the cluster into one but each
            // scalar may have a distinct visual contribution.
            for scalar in ch.unicodeScalars {
                let v = scalar.value
                if v == 0x200D                     // zero-width joiner
                    || v == 0xFE0E || v == 0xFE0F  // variation selectors
                    || (v >= 0x1F3FB && v <= 0x1F3FF)  // skin-tone modifiers
                    || (v >= 0x0300 && v <= 0x036F)    // combining marks
                {
                    continue
                }
                if v >= 0x1F000 || (v >= 0x2600 && v <= 0x27FF) {
                    // Pictographs / dingbats — usually 2 cells in
                    // monospace terminals.
                    n += 2
                } else {
                    n += 1
                }
            }
        }
        return n
    }

    /// Time-stamped log line. System events (✓ session created,
    /// ⚠️ warnings, etc.) align visually with transcripts.
    public func line(_ text: String) {
        printAboveStickyArea("\(timestampPrefixWithBar(bar: nil, color: "\u{1B}[2m")) \(text)")
    }

    public func errorLine(_ text: String) {
        // Errors go through the same sticky-area-aware path so the
        // status doesn't get duplicated. Tinted red.
        printAboveStickyArea("\(timestampPrefixWithBar(bar: nil, color: "\u{1B}[31m")) \(text)")
    }

    // MARK: - Internals

    private func tick() {
        // Decay so silence reads as silence rather than freezing on
        // the last value. Mic decay is also useful — quiet rooms
        // shouldn't show a steady ▃ from the noise floor.
        micLevel *= 0.85
        botLevel *= 0.85
        redrawStickyArea()
    }

    /// Redraw the sticky 2-row area at the bottom of the cursor:
    ///
    ///   row 1: active row — bot text streaming live (with leading
    ///          live histogram + colored bot prefix), or blank when
    ///          no response is in flight.
    ///   row 2: status row — timestamp + state pill + live audio bar
    ///          for whichever side is meaningful (mic for listening
    ///          / hearing, speaker for responding).
    ///
    /// The two rows are co-located so the per-tick redraw never
    /// overlaps with the streaming bot text — the previous single-
    /// line design wrote the status on the same row the bot text
    /// was streaming on, and 10 Hz `\r\033[2K` redraws wiped the
    /// bot text before it could be read.
    /// The sticky area is exactly four rows tall. Order from top to
    /// bottom:
    ///
    ///   row 0: ACTIVE — bot text streaming live (or blank when
    ///          no response is in flight).
    ///   row 1: STATE  — `[HH:MM:SS] <pill>`. Tells the user where
    ///          the conversation is right now (listening, hearing,
    ///          thinking, responding).
    ///   row 2: MIC    — `🎙️  ████░░░░ -32 dB`. Always live;
    ///          driven by WebRTC's `media-source` audioLevel stat.
    ///   row 3: BOT    — `🔊  ░░░░░░░░ -60 dB`. Always live; driven
    ///          by WebRTC's `inbound-rtp` audioLevel stat.
    ///
    /// Both bars are always rendered (even when "off") so the user
    /// can read the duplex stream at a glance — bot bar moves
    /// while bot is talking, mic bar moves while user is talking,
    /// neither while the system is idle. State pill provides the
    /// authoritative label for what's happening; the bars give a
    /// continuous "I'm alive" pulse.
    private static let stickyRowCount = 4

    private func redrawStickyArea() {
        // Cursor invariant: at the end of the previous tick the
        // cursor sits at column N of the LAST sticky row (the bot
        // bar). To redraw all rows we move up `stickyRowCount - 1`
        // lines, landing on the top row's column 0.
        //
        // Auto-wrap is disabled around the writes (`?7l`/`?7h`) so
        // a wider-than-terminal row truncates at the right edge
        // instead of wrapping into another visual row — wrapping
        // would invalidate the cursor-up arithmetic and cause the
        // sticky area to climb the screen each tick.
        if stickyDrawn {
            write("\u{1B}[\(Self.stickyRowCount - 1)A")
        }
        write("\u{1B}[?7l")
        write("\r\u{1B}[2K\(activeRowRender())\n")
        write("\r\u{1B}[2K\(stateRowRender())\n")
        write("\r\u{1B}[2K\(micRowRender())\n")
        write("\r\u{1B}[2K\(botRowRender())")
        write("\u{1B}[?7h")
        stickyDrawn = true
    }

    /// Move past the sticky area and clear it so the caller can
    /// emit a permanent line without overwriting the sticky rows.
    /// The next tick redraws the sticky area on the rows below
    /// where the caller's line landed.
    private func clearStickyArea() {
        if stickyDrawn {
            // Up to the top row of the sticky area, then clear from
            // cursor to end of screen — wipes all four rows.
            write("\u{1B}[\(Self.stickyRowCount - 1)A\r\u{1B}[J")
            stickyDrawn = false
        } else {
            write("\r\u{1B}[2K")
        }
    }

    /// Print one permanent line above the sticky area. Caller passes
    /// the fully-formatted line (including any timestamp / colour
    /// codes); we add the trailing newline. After the print, the
    /// sticky area redraws on the next tick at the new cursor row.
    private func printAboveStickyArea(_ line: String) {
        clearStickyArea()
        // Use stdout directly so we don't accidentally double-newline
        // through Swift's print buffering with the sticky redraw.
        write("\(line)\n")
    }

    /// Active row: empty when no response is streaming, otherwise
    /// the bot's reply with a leading live histogram (the bar grows
    /// as the bot keeps speaking) and the magenta `bot:` prefix.
    private func activeRowRender() -> String {
        guard !activeBotText.isEmpty else { return "" }
        let bar = histogramBar(botSamples)
        let stamp = botTurnStartedAt ?? Date()
        return "\(timestampPrefixWithBar(at: stamp, bar: bar, color: "\u{1B}[35m")) \u{1B}[35m[bitHuman]\u{1B}[0m \(activeBotText)"
    }

    /// State row — timestamp + animated pill. No bar; the bars are
    /// on dedicated rows below so the user can read both sides of
    /// the duplex stream simultaneously.
    private func stateRowRender() -> String {
        let pill: String
        switch state {
        case .listening:  pill = "\u{1B}[2m🟢 listening\u{1B}[0m"
        case .hearing:    pill = "\u{1B}[36m🎤 hearing\u{1B}[0m"
        case .thinking:   pill = "\u{1B}[33m💭 thinking\u{1B}[0m"
        case .responding: pill = "\u{1B}[35m🗣️ responding\u{1B}[0m"
        }
        return "\(timestampPrefixWithBar(bar: nil, color: "\u{1B}[2m")) \(pill)"
    }

    /// Mic row — always rendered, brightens while the user is
    /// hearing'd by the model. Cyan when active; dim green at idle
    /// so the bar is obviously "your side" of the conversation.
    private func micRowRender() -> String {
        let active = (state == .hearing)
        let color = active ? "\u{1B}[36m" : "\u{1B}[32m"
        let label = active ? "🎙️  \u{1B}[1myou\u{1B}[0m " : "\u{1B}[2m🎙️  you \u{1B}[0m"
        return "  \(label)\(liveBarBody(micLevel, color: color))"
    }

    /// Bot row — always rendered, brightens during `.responding`.
    /// Magenta when the bot is speaking; dim otherwise so the eye
    /// can see at a glance which side is "speaking" right now.
    private func botRowRender() -> String {
        let active = (state == .responding)
        let color = active ? "\u{1B}[35m" : "\u{1B}[34m"
        let label = active ? "🔊  \u{1B}[1mbot\u{1B}[0m " : "\u{1B}[2m🔊  bot \u{1B}[0m"
        return "  \(label)\(liveBarBody(botLevel, color: color))"
    }

    /// 30-cell graduated live bar (without speaker-label prefix —
    /// callers add their own colour-coded label). Clipping (>0.9)
    /// flips the colour to red regardless of state so a too-hot
    /// signal is unmistakable.
    private func liveBarBody(_ level: Float, color: String) -> String {
        let cells = 30
        let dB = level > 1e-7 ? max(-60, 20 * log10f(level)) : -60
        let pct = (dB + 60) / 60
        let filled = max(0, min(cells, Int(pct * Float(cells))))
        let dyn = pct > 0.9 ? "\u{1B}[31m" : color
        let bars = String(repeating: "█", count: filled)
            + String(repeating: "░", count: cells - filled)
        let dBStr = String(format: "%4d dB", Int(dB))
        return "\(dyn)\(bars)\u{1B}[0m \u{1B}[2m\(dBStr)\u{1B}[0m"
    }

    /// `[HH:MM:SS]` (or `[HH:MM:SS ▆▇▆▆▅▄]` if a histogram bar is
    /// supplied). The colour parameter tints the brackets + bar to
    /// match the speaker (cyan for user, magenta for bot, dim for
    /// system messages).
    private nonisolated func timestampPrefixWithBar(
        at date: Date = Date(),
        bar: String?,
        color: String
    ) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var local = tm()
        localtime_r(&t, &local)
        let stamp = String(
            format: "%02d:%02d:%02d",
            local.tm_hour, local.tm_min, local.tm_sec
        )
        if let bar {
            return "\(color)[\(stamp) \(bar)]\u{1B}[0m"
        } else {
            return "\(color)[\(stamp)]\u{1B}[0m"
        }
    }

    private nonisolated func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
}
