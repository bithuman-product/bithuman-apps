// Per-session usage / cost tracker for the avatar cloud runners.
//
// Runs a 60 s timer that prints a one-liner to the TerminalUI's
// scrolling region:
//
//   [10:42] 💸 5m elapsed  ·  bitHuman 10 cr (~$0.10)  ·  OpenAI ~$0.30
//
// Numbers are rough by design. bitHuman side is exact (we know
// the rate per minute and how many minutes elapsed since
// authenticate). OpenAI side is an estimate based on
// `gpt-realtime-mini` published rates because the WebRTC
// transport doesn't surface per-call usage tokens — we'd need the
// `response.usage` event to be precise. Listed as `~` so the user
// reads it as a ballpark.
//
// Stops on `stop()`. The host runner cancels on Ctrl-C.

import Foundation
import BithumanRealtimeOpenAI

/// One-line cost report cadence + format.
public actor SpendTracker {
    public enum AvatarRuntime: Sendable {
        case expression  // 2 credits / min
        case essence     // 1 credit / min
        var creditsPerMinute: Int {
            switch self {
            case .expression: return 2
            case .essence: return 1
            }
        }
        var label: String {
            switch self {
            case .expression: return "Expression"
            case .essence: return "Essence"
            }
        }
    }

    /// `gpt-realtime-mini` mid-2026 published price. Rough — the
    /// realtime API meters tokens, not minutes, and the actual cost
    /// depends on input/output ratio. Use OpenAI's billing dashboard
    /// for ground truth.
    public static let openAIRateUSDPerMinute: Double = 0.06

    /// Cents → dollars conversion for bitHuman credits. Public
    /// rate card: 100 credits = $1.00. Override here when LLC pricing
    /// changes; the shipped value matches the November 2026 sheet.
    public static let bitHumanUSDPerCredit: Double = 0.01

    private let runtime: AvatarRuntime
    private let ui: TerminalUI
    private let openAIModel: String
    private let startedAt: Date
    private var task: Task<Void, Never>?

    public init(runtime: AvatarRuntime, ui: TerminalUI, openAIModel: String) {
        self.runtime = runtime
        self.ui = ui
        self.openAIModel = openAIModel
        self.startedAt = Date()
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            // First report at 60 s — printing immediately would be
            // alarmist for a session that just started.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        let elapsed = Date().timeIntervalSince(startedAt)
        let minutes = elapsed / 60.0

        let creditsBH = Int((Double(runtime.creditsPerMinute) * minutes).rounded())
        let usdBH = Double(creditsBH) * Self.bitHumanUSDPerCredit
        let usdOA = minutes * Self.openAIRateUSDPerMinute

        let elapsedStr = formatElapsed(elapsed)
        let line = "💸 \(elapsedStr) elapsed  ·  bitHuman \(runtime.label) \(creditsBH) cr (~$\(formatUSD(usdBH)))  ·  OpenAI \(openAIModel) ~$\(formatUSD(usdOA))"
        await ui.line(line)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        let s = Int(seconds.truncatingRemainder(dividingBy: 60))
        if m == 0 { return "\(s)s" }
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }

    private func formatUSD(_ amount: Double) -> String {
        // Show 3 decimal places under $0.10 (so very short sessions
        // don't read as "$0.00"), 2 thereafter.
        amount < 0.10
            ? String(format: "%.3f", amount)
            : String(format: "%.2f", amount)
    }
}
