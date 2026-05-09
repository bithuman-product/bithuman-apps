import Foundation
import os

enum Log {
    static let pipeline = Logger(subsystem: "ai.bithuman.kit", category: "pipeline")
    static let audio    = Logger(subsystem: "ai.bithuman.kit", category: "audio")
    static let asr      = Logger(subsystem: "ai.bithuman.kit", category: "asr")
    static let llm      = Logger(subsystem: "ai.bithuman.kit", category: "llm")
    static let tts      = Logger(subsystem: "ai.bithuman.kit", category: "tts")

    /// True when the user has set `BITHUMAN_VERBOSE=1`. The avatar
    /// expression-engine internals print model-loading details
    /// (tensor counts, dtype breakdowns, key-matching reports) to
    /// stdout — useful when chasing weight-loading bugs, but noise
    /// for normal users. Gated behind this flag, default off.
    static let verbose: Bool = ProcessInfo.processInfo.environment["BITHUMAN_VERBOSE"] != nil
}

/// Replacement for `print(...)` inside the avatar expression engine
/// that's silent by default and only emits when `Log.verbose` is on
/// (set via `BITHUMAN_VERBOSE=1`). The engine has ~35 print sites
/// dumping model-loading internals; routing them through here keeps
/// the user's terminal clean without losing the ability to debug
/// weight loading.
func engineLog(_ message: @autoclosure () -> String) {
    if Log.verbose {
        print(message())
    }
}
