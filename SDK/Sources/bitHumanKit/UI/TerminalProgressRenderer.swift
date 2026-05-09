import Combine
import Foundation

/// Multi-line stderr renderer for ``BootProgress``. Used by every
/// terminal entry point (`bithuman-cli text|voice|video`) to show
/// boot progress as a growing build-log style block instead of a
/// single self-overwriting line.
///
/// Output shape:
///
/// ```text
/// 🔧 bithuman-cli — booting…
///
///   ✓ download speech model              0.4s
///   ✓ load on-device LLM                 5.2s
///   ◐ load TTS voice                     2.1s · ████░░░░ 47%
///   ─────────────────────────────────────────────
///   3 active · elapsed 7.7s
/// ```
///
/// Each phase the engine emits becomes a line. Transitions from
/// active to done are drawn in place: the active line gets ✓ and
/// its final elapsed; the new phase appears below as ◐. Once
/// ``BootProgress/Phase/ready`` fires the block is dismissed with a
/// summary line and a trailing newline so the next print lands on
/// fresh ground.
///
/// Renders at 10 Hz on a Combine timer so the active line's elapsed
/// counter ticks visibly even during long synchronous phases like
/// the ANE shader compile (~100 s on first run).
@MainActor
public final class TerminalProgressRenderer {

    private let progress: BootProgress
    private var phaseSubscription: AnyCancellable?
    private var tickSubscription: AnyCancellable?

    private struct Step {
        let key: String              // stable identity ("loadingLLM" etc.)
        var caption: String          // user-facing label
        var fraction: Double?        // 0…1 for known-progress steps
        var detail: String?          // bytes/sec, ETA, etc.
        let started: Date
        var finished: Date?
    }

    private var steps: [Step] = []
    private var startedAt: Date?
    private var lastRenderedLineCount: Int = 0
    private var dismissed = false

    public init(progress: BootProgress) {
        self.progress = progress
    }

    public func attach() {
        phaseSubscription = progress.$phase.sink { [weak self] phase in
            self?.handlePhase(phase)
        }
        // Re-render at 10 Hz so the active step's elapsed-time ticker
        // updates visibly. Cheap — only runs while the renderer is
        // attached, and short-circuits when nothing has changed.
        tickSubscription = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.renderTick() }
    }

    public func detach() {
        phaseSubscription?.cancel()
        phaseSubscription = nil
        tickSubscription?.cancel()
        tickSubscription = nil
    }

    // MARK: - Phase handling

    private func handlePhase(_ phase: BootProgress.Phase) {
        if dismissed { return }
        switch phase {
        case .idle:
            return
        case .ready:
            finalize()
            return
        default:
            break
        }

        let key = phaseKey(phase)
        let caption = BootProgress.caption(for: phase, engineFirstRun: progress.engineFirstRun)
        let fraction = BootProgress.progress(for: phase)
        let detail = BootProgress.detail(for: phase)

        if startedAt == nil {
            startedAt = Date()
            // Print the title row + a blank gap on first phase.
            // Subsequent renders never touch these — only the steps
            // block below.
            FileHandle.standardError.write(Data(
                "\n  \u{1B}[1m🔧 bithuman-cli\u{1B}[0m \u{1B}[2m— booting…\u{1B}[0m\n\n".utf8
            ))
        }

        if let last = steps.last, last.key == key {
            // Same phase, payload changed — update caption/fraction.
            steps[steps.count - 1].caption = caption
            steps[steps.count - 1].fraction = fraction
            steps[steps.count - 1].detail = detail
        } else {
            // Phase transition. Mark the previous step finished, append
            // a fresh ◐ for the new one.
            if let lastIdx = steps.indices.last, steps[lastIdx].finished == nil {
                steps[lastIdx].finished = Date()
            }
            steps.append(Step(
                key: key,
                caption: caption,
                fraction: fraction,
                detail: detail,
                started: Date(),
                finished: nil
            ))
        }
        repaint()
    }

    private func renderTick() {
        if dismissed { return }
        if steps.isEmpty { return }
        // Only the active step's elapsed counter changes between
        // phase events; cheap to repaint the whole block at 10 Hz.
        repaint()
    }

    private func finalize() {
        guard !dismissed, !steps.isEmpty else { return }
        // Mark the trailing step finished if it hadn't transitioned.
        if let lastIdx = steps.indices.last, steps[lastIdx].finished == nil {
            steps[lastIdx].finished = Date()
        }
        repaint(finalRender: true)
        // Drop one trailing newline so the next caller's print() lands
        // cleanly below the block.
        FileHandle.standardError.write(Data("\n".utf8))
        dismissed = true
        detach()
    }

    // MARK: - Render

    private func repaint(finalRender: Bool = false) {
        var lines: [String] = []
        for step in steps {
            lines.append(formatStep(step))
        }

        // Footer summary.
        let total = elapsedSeconds(from: startedAt ?? Date(), to: Date())
        let doneCount = steps.filter { $0.finished != nil }.count
        let activeCount = steps.count - doneCount
        let summaryIcon = finalRender ? "✓" : "·"
        let summary = finalRender
            ? "\u{1B}[32m\(summaryIcon)\u{1B}[0m \u{1B}[2mready in \(format(seconds: total))\u{1B}[0m"
            : "\u{1B}[2m\(summaryIcon) \(doneCount) done · \(activeCount) active · elapsed \(format(seconds: total))\u{1B}[0m"
        lines.append("  \u{1B}[2m─────────────────────────────────────────────\u{1B}[0m")
        lines.append("  \(summary)")

        // Rotating helpful tip for the active step. Surfaces on
        // long-running opaque phases (ANE compile, speech-model
        // download) so the user has something to read while they
        // wait. Rotates every 8 s so the message changes a few times
        // during a multi-minute compile.
        if !finalRender,
           let active = steps.last(where: { $0.finished == nil }),
           let tips = tipsForPhaseKey(active.key),
           !tips.isEmpty {
            let elapsed = elapsedSeconds(from: active.started, to: Date())
            let idx = Int(elapsed / 8) % tips.count
            lines.append("  \u{1B}[2m💡 \(tips[idx])\u{1B}[0m")
        }

        // Cursor up to the top of the previous block, clear, redraw.
        // Auto-wrap off so a wide line truncates instead of wrapping
        // into another visual row (which would invalidate the
        // up-by-N arithmetic below).
        var output = ""
        if lastRenderedLineCount > 0 {
            output += "\u{1B}[\(lastRenderedLineCount)A"
        }
        output += "\u{1B}[?7l"
        for line in lines {
            output += "\r\u{1B}[2K\(line)\n"
        }
        output += "\u{1B}[?7h"

        FileHandle.standardError.write(Data(output.utf8))
        lastRenderedLineCount = lines.count
    }

    private func formatStep(_ step: Step) -> String {
        let elapsed = elapsedSeconds(from: step.started, to: step.finished ?? Date())
        let icon: String
        let captionStyle: String
        if step.finished != nil {
            icon = "\u{1B}[32m✓\u{1B}[0m"  // green check
            captionStyle = "\u{1B}[2m"      // dim done lines
        } else {
            icon = "\u{1B}[33m◐\u{1B}[0m"  // yellow active dot
            captionStyle = "\u{1B}[1m"      // bold active line
        }

        // Strip the ETA suffix from the caption — we'll surface it
        // as a separate, dimmed note next to the elapsed-time so the
        // caption column stays compact AND the user still sees the
        // expectation (e.g. ANE shader compile can run 2–3 min on a
        // cold cache). Done steps get only the actual elapsed
        // (the estimate is no longer informative once the work is
        // complete).
        let baseCaption = stripParentheticalETA(step.caption)
        let etaHint = extractETAHint(step.caption)

        let timing: String
        if step.finished != nil {
            timing = format(seconds: elapsed)
        } else if let pct = step.fraction, pct > 0 {
            let pctStr = String(format: "%d%%", Int((pct * 100).rounded()))
            timing = "\(format(seconds: elapsed)) · \(progressBar(pct)) \(pctStr)"
        } else if let expected = expectedSecondsForPhaseKey(step.key) {
            // Active opaque step with a known typical duration —
            // synthesize a progress bar from elapsed/expected. We
            // cap at 99% until the step actually transitions to
            // .finished so an overrun doesn't claim "100% done"
            // while the work is still running.
            let frac = min(0.99, Double(elapsed) / Double(expected))
            let pctStr = String(format: "%d%%", Int((frac * 100).rounded()))
            timing = "\(format(seconds: elapsed)) · \(progressBar(frac)) \(pctStr)"
        } else if let hint = etaHint {
            timing = "\(format(seconds: elapsed)) · est \(hint)"
        } else {
            timing = format(seconds: elapsed)
        }

        // Pad caption to a fixed width so the timing column lines up
        // across rows. Use visible width (skip ANSI codes); the
        // padding is whitespace so colour escapes don't matter.
        let captionWidth = 38
        let padded = pad(baseCaption, to: captionWidth)
        return "  \(icon) \(captionStyle)\(padded)\u{1B}[0m  \u{1B}[2m\(timing)\u{1B}[0m"
    }

    // MARK: - Helpers

    private func phaseKey(_ phase: BootProgress.Phase) -> String {
        switch phase {
        case .idle:                    return "idle"
        case .downloadingEngine:       return "downloadingEngine"
        case .verifyingEngine:         return "verifyingEngine"
        case .loadingSpeechModel:      return "loadingSpeechModel"
        case .loadingLLM:              return "loadingLLM"
        case .openingAudioGraph:       return "openingAudioGraph"
        case .loadingTTS:              return "loadingTTS"
        case .authenticating:          return "authenticating"
        case .loadingExpressionEngine: return "loadingExpressionEngine"
        case .loadingEssenceRuntime:   return "loadingEssenceRuntime"
        case .connectingRealtime:      return "connectingRealtime"
        case .prewarmingIdle:          return "prewarmingIdle"
        case .ready:                   return "ready"
        }
    }

    private func progressBar(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        let width = 14
        let filled = Int((clamped * Double(width)).rounded())
        return String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
    }

    private func format(seconds: TimeInterval) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return String(format: "%.0fs", seconds)
    }

    private func elapsedSeconds(from start: Date, to end: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    /// Pad a possibly-narrow caption to `width` visible columns by
    /// appending spaces. Counts emoji as 2 cols (best-effort) and
    /// strips ANSI SGR escapes — the existing captions don't carry
    /// SGRs but it's defensive against future additions.
    private func pad(_ s: String, to width: Int) -> String {
        let visible = visibleWidth(of: s)
        if visible >= width { return s }
        return s + String(repeating: " ", count: width - visible)
    }

    private func visibleWidth(of s: String) -> Int {
        var n = 0
        var inEscape = false
        for ch in s {
            if inEscape {
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
            for scalar in ch.unicodeScalars {
                let v = scalar.value
                if v == 0x200D || v == 0xFE0E || v == 0xFE0F
                    || (v >= 0x1F3FB && v <= 0x1F3FF)
                    || (v >= 0x0300 && v <= 0x036F)
                {
                    continue
                }
                if v >= 0x1F000 || (v >= 0x2600 && v <= 0x27FF) {
                    n += 2
                } else {
                    n += 1
                }
            }
        }
        return n
    }

    /// Drop any trailing parenthetical ETA hint so the caption fits
    /// the fixed-width column. Matches " (~10s …)" style suffixes.
    private func stripParentheticalETA(_ caption: String) -> String {
        if let idx = caption.range(of: " (~", options: .backwards),
           caption.hasSuffix(")")
        {
            return String(caption[..<idx.lowerBound])
        }
        return caption
    }

    /// Typical wall-clock duration of an opaque phase, used to
    /// synthesize a progress bar from elapsed-time when the
    /// underlying engine doesn't expose a fraction. Bumps based on
    /// `engineFirstRun` for the loading-engine phase since a cold
    /// ANED cache costs minutes while a warm one is ~5 s — using
    /// the worst-case 180 s for both made the bar crawl at 3% on
    /// every warm launch.
    private func expectedSecondsForPhaseKey(_ key: String) -> Int? {
        let firstRun = progress.engineFirstRun
        switch key {
        case "loadingExpressionEngine":
            return firstRun ? 180 : 8
        case "loadingSpeechModel":
            return 45  // first-run download
        case "verifyingEngine":
            return 8
        default:
            return nil
        }
    }

    /// Rotating helpful-tip strings shown below the active step on
    /// long-running opaque phases. Each list cycles every ~8 s so a
    /// 2-minute ANE compile shows a handful of different tips. Keep
    /// each tip under ~80 chars so it fits a standard terminal.
    private func tipsForPhaseKey(_ key: String) -> [String]? {
        let firstRun = progress.engineFirstRun
        switch key {
        case "loadingExpressionEngine":
            if firstRun {
                return [
                    "Apple's Neural Engine is compiling shader graphs for the avatar — this happens ONCE per Mac.",
                    "The compiled artifacts land in /var/db/com.apple.aned/cache and survive reboots, OS upgrades, and brew reinstalls.",
                    "Plug in your laptop if you can — ANE compile is CPU-heavy and pulls 20-30 W on Apple Silicon.",
                    "Mac M-series typically finishes in 30-90 s; iPhone-class cores can take longer.",
                    "While you wait, try `bithuman-cli voice --openai` in another terminal for instant cloud chat (no ANE compile needed).",
                    "After this completes, every subsequent launch starts the avatar in ~5 seconds.",
                ]
            } else {
                // Warm path: ANE shaders already cached. We're just
                // mmap'ing weights + loading the cached graph.
                return [
                    "Loading from the ANED shader cache — first run already paid the compile cost.",
                    "If this takes longer than ~10 s, the cache may have been invalidated (OS upgrade, low disk). Next run will re-compile and re-cache.",
                ]
            }
        case "loadingSpeechModel":
            return [
                "Apple's SpeechAnalyzer model is downloading from Apple servers (one-time, ~30 MB).",
                "This model powers the on-device speech-to-text used by `voice --local`.",
            ]
        case "downloadingEngine":
            return [
                "Streaming the Expression engine weights from the bitHuman CDN (~1.5 GB, one-time).",
                "Subsequent launches reuse the cached file at ~/.cache/bithuman/expression/.",
                "The download is resumable — kill the process and re-run if your network drops.",
            ]
        case "loadingLLM":
            return [
                "Streaming the on-device LLM from HuggingFace Hub (~2 GB, one-time).",
                "Cache lives at ~/.cache/huggingface/hub/ — reusable by every bithuman tool.",
            ]
        default:
            return nil
        }
    }

    /// Pull the ETA hint OUT of a caption like
    /// `"loading expression engine — compiling ANE shaders… (~2–3 min first run, ~5 s cached)"`
    /// so we can surface it as a separate inline note while the step
    /// is active. Returns the bare hint without the wrapping
    /// parentheses (`"~2–3 min first run, ~5 s cached"`), or nil
    /// when the caption has no parenthetical.
    private func extractETAHint(_ caption: String) -> String? {
        guard let idx = caption.range(of: " (~", options: .backwards),
              caption.hasSuffix(")")
        else { return nil }
        let inside = caption[idx.upperBound..<caption.index(before: caption.endIndex)]
        return "~" + inside
    }
}
