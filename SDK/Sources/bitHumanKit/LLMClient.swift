import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
// `#hubDownloader()` and `#huggingFaceTokenizerLoader()` expand to
// code that references Tokenizers.AutoTokenizer and HuggingFace.HubClient
// at the call site — the macros don't bring them along.
import Tokenizers
import HuggingFace

/// On-device LLM via mlx-swift-lm. Two model choices, gated by
/// platform:
///
/// - **macOS**: Gemma 3n E2B 4-bit (~2 GB). Used where memory is
///   plentiful; produces tighter, more grounded replies.
/// - **iOS / iPadOS**: Gemma 3 1B QAT 4-bit (~800 MB). Half the
///   weight cost so the app fits under the default app-memory
///   limit on 8 GB phones. QAT (quantization-aware training)
///   preserves instruction-following better than the post-training-
///   quantized 1B variants.
///
/// Both picked over Qwen3-1.7B-Instruct because the latter defaults
/// to a thinking mode whose `<think>…</think>` monologues broke the
/// voice pipeline even with `/no_think` in the system prompt and a
/// stream-level filter — the model would get stuck emitting nothing
/// in some turns. Gemma is newer, better-behaved, and the tok/s
/// gap is a fair trade for reliability.
actor LLMClient {
    private var instructions: String
    private var container: ModelContainer?
    private var session: ChatSession?
    private var currentTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    /// Optional sink for cold-start progress. When set, the LLM
    /// download/load fraction is forwarded as ``BootProgress/Phase/loadingLLM``
    /// updates and the legacy stderr `📥 downloading model [bar]`
    /// emitter is suppressed so the host's renderer (terminal or
    /// SwiftUI splash) owns the boot UI.
    private let bootProgress: BootProgress?

    init(instructions: String, bootProgress: BootProgress? = nil) {
        self.instructions = instructions
        self.bootProgress = bootProgress
    }

    /// Hot-swap the system prompt. The next `deltas(for:)` call
    /// uses the new instructions; in-flight generation isn't
    /// rewritten retroactively. The model itself stays loaded —
    /// we just rebuild the `ChatSession` wrapper.
    func updateInstructions(_ newInstructions: String) {
        self.instructions = newInstructions
        guard let container else { return }
        // Cancel any in-flight generation so the next `deltas(...)`
        // call starts cleanly with the new prompt.
        currentTask?.cancel()
        currentTask = nil
        // Rebuild ChatSession against the still-loaded container.
        self.session = ChatSession(
            container,
            instructions: newInstructions,
            generateParameters: GenerateParameters(
                maxTokens: 80,
                temperature: 0.7,
                topP: 0.95,
                repetitionPenalty: 1.1
            )
        )
    }

    /// Start the model download / load in the background. Safe to
    /// call multiple times; only the first call does work. Caller
    /// should `await prewarm()` once before the first `deltas()` so
    /// the user isn't served a "nothing happens" window during the
    /// 2 GB first-run download or the ~3–5 s cold-load on subsequent
    /// runs.
    func prewarm() async {
        if container != nil { return }
        if loadTask == nil {
            let boot = bootProgress
            loadTask = Task.detached(priority: .userInitiated) { [instructions] in
                let container = try await Self.loadWithRetry(bootProgress: boot)
                return (container, instructions)
            }.flatMap { pair in
                await self.install(container: pair.0, instructions: pair.1)
            }
        }
        do {
            _ = try await loadTask?.value
        } catch {
            // Failed loads must clear `loadTask` so a retry actually
            // re-runs the download / install. Without this, every
            // future prewarm short-circuits on the existing-but-
            // failed task and the actor stays stuck with model == nil.
            loadTask = nil
            FileHandle.standardError.write(Data("""

                ❌ LLM weights didn't finish downloading: \(error.localizedDescription)
                   Rerun `bithuman-cli` — partial weights are kept under
                   ~/.cache/huggingface/hub and the next launch resumes from there.
                   (Will also retry automatically if you start talking.)


                """.utf8))
        }
    }

    /// Wrap the HF download in a small retry loop. Multi-gigabyte
    /// first-run downloads are prone to URLSession's default 60-second
    /// request timeout firing on slow / shared links — and a fresh
    /// URLSession instance on the next attempt usually lands fine.
    /// Three tries with 2s / 4s backoff covers transient flakes
    /// without making a genuinely-broken network drag the boot to a
    /// 30-second halt.
    ///
    /// Important: we call `LLMModelFactory.shared.loadContainer` directly
    /// rather than the `#huggingFaceLoadModelContainer` macro. The macro
    /// expands to a dispatcher that iterates ALL registered model
    /// factories in registry order — once `MLXVLM` is also imported
    /// (Phase 2d voice-match), the VLM factory may win the dispatch
    /// for the same `gemma4` model id and load the chat weights with a
    /// vision-aware processor. Text-only inference then crashes with
    /// `[broadcast_shapes] Shapes (20) and (98) cannot be broadcast`
    /// at the first turn. Calling the LLM factory directly pins the
    /// chat path to the text-only loader.
    private static func loadWithRetry(bootProgress: BootProgress? = nil) async throws -> ModelContainer {
        #if os(iOS)
        // iPhone: Qwen3 1.7B 4-bit (~1 GB resident). Gemma 4 E2B (~2 GB)
        // pushes peak past the iPhone per-app jetsam cap on multi-
        // sentence replies. Smaller models compromise quality:
        //   - Qwen3 0.6B leaks placeholder text ("[Your Name]")
        //   - Gemma 3 1B QAT gives canned phrases + factual errors
        // 1.7B + serialized sentence playback (in VoiceChatOrchestrator)
        // + maxTokens=80 keeps idle ~1.9 GB and per-turn peaks under
        // ~4.5 GB — well within the per-app cap.
        let config = LLMRegistry.qwen3_1_7b_4bit
        #else
        let config = LLMRegistry.gemma4_e2b_it_4bit
        #endif
        // Gate the diagnostic dump on BITHUMAN_VERBOSE so the boot
        // UI stays clean by default — the model id is already in
        // the BootProgress phase ("loading on-device LLM…") and
        // doesn't need to repeat here.
        if ProcessInfo.processInfo.environment["BITHUMAN_VERBOSE"] == "1" {
            NSLog("[LLMClient] selected LLM config: \(String(describing: config))")
        }
        let maxAttempts = 3
        var lastError: Error = LLMError.notReady
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                let backoffSeconds = UInt64(1) << (attempt - 1)  // 2, 4
                FileHandle.standardError.write(Data(
                    "↻ LLM download attempt \(attempt)/\(maxAttempts) (last error: \(lastError.localizedDescription))\n".utf8
                ))
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
            }
            do {
                return try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: config,
                    progressHandler: { progress in
                        if let bootProgress {
                            bootProgress.update(.loadingLLM(progress: progress.fractionCompleted))
                        } else {
                            let pct = Int(progress.fractionCompleted * 100)
                            Self.maybeLogProgress(pct)
                        }
                    }
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func install(container: ModelContainer, instructions: String) {
        self.container = container
        self.session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: 80,
                temperature: 0.7,
                topP: 0.95,
                repetitionPenalty: 1.1
            )
        )
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Stream incremental deltas for a user message. Each yielded
    /// String is the incremental chunk (not cumulative) — ChatSession
    /// emits token-group deltas directly. Cancellation of the
    /// iterating Task propagates through the stream's onTermination
    /// into the underlying generation. The raw stream is run through
    /// a `<think>…</think>` filter so any thinking-mode leakage from
    /// a future model swap doesn't reach TTS.
    func deltas(for userText: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Hop into the actor synchronously to (a) prewarm,
            // (b) grab the session, AND (c) record `currentTask`
            // BEFORE the streaming Task starts. A fire-and-forget
            // `Task { setCurrentTask(...) }` would race with the
            // stream body and let an early `cancel()` no-op for ~µs.
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.startStreaming(userText: userText, continuation: continuation)
            }
        }
    }

    private func startStreaming(
        userText: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        await prewarm()
        guard let session else {
            continuation.finish(throwing: LLMError.notReady)
            return
        }
        let task = Task { [weak self] in
            guard let self else { continuation.finish(); return }
            var filter = ThinkBlockFilter()
            do {
                for try await chunk in session.streamResponse(to: userText) {
                    try Task.checkCancellation()
                    let visible = filter.process(chunk)
                    if !visible.isEmpty {
                        continuation.yield(visible)
                    }
                }
                let tail = filter.flush()
                if !tail.isEmpty { continuation.yield(tail) }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                Log.llm.error("generate: \(error.localizedDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
            _ = self  // retain through the task body
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
    }

    // MARK: progress printing

    nonisolated(unsafe) private static var lastLoggedPct: Int = -1
    private static func maybeLogProgress(_ pct: Int) {
        if pct != lastLoggedPct {
            lastLoggedPct = pct
            let width = 24
            let filled = max(0, min(width, (pct * width) / 100))
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: width - filled)
            // \r overwrites the previous bar in place. Clear-EOL
            // (`\u{1B}[K`) prevents stale tail characters when the
            // bar shortens (it doesn't here, but defensive).
            let line = "\r\u{1B}[K📥 downloading model  [\(bar)] \(pct)%"
            FileHandle.standardError.write(Data(line.utf8))
            if pct >= 100 {
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }
    }
}

enum LLMError: Error {
    case notReady
}

/// Streaming filter that strips `<think>…</think>` blocks (case-
/// sensitive) from a chunked string stream. Defensive — current
/// model (Gemma 4) doesn't emit them, but a future swap might.
struct ThinkBlockFilter {
    private var inside = false
    private var buffer = ""
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    mutating func process(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while !buffer.isEmpty {
            if inside {
                if let r = buffer.range(of: Self.closeTag) {
                    buffer = String(buffer[r.upperBound...])
                    inside = false
                } else if buffer.count > Self.closeTag.count * 2 {
                    buffer = String(buffer.suffix(Self.closeTag.count))
                    return out
                } else {
                    return out
                }
            } else {
                if let r = buffer.range(of: Self.openTag) {
                    out += buffer[..<r.lowerBound]
                    buffer = String(buffer[r.upperBound...])
                    inside = true
                } else if let partial = Self.partialOpenSuffix(of: buffer) {
                    let safeEnd = buffer.index(buffer.endIndex, offsetBy: -partial.count)
                    out += buffer[..<safeEnd]
                    buffer = String(buffer[safeEnd...])
                    return out
                } else {
                    out += buffer
                    buffer.removeAll()
                    return out
                }
            }
        }
        return out
    }

    mutating func flush() -> String {
        defer { buffer.removeAll(); inside = false }
        return inside ? "" : buffer
    }

    private static func partialOpenSuffix(of s: String) -> String? {
        let tag = openTag
        let maxLen = min(s.count, tag.count - 1)
        if maxLen <= 0 { return nil }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let tail = String(s.suffix(len))
            if tag.hasPrefix(tail) { return tail }
        }
        return nil
    }
}

extension Task where Success: Sendable, Failure == Error {
    /// Chain a follow-up after the Task succeeds. Used in prewarm()
    /// to hand the loaded ModelContainer back to the actor without
    /// awaiting on the calling thread.
    fileprivate func flatMap<U>(_ transform: @escaping @Sendable (Success) async -> U) -> Task<U, Error> where U: Sendable {
        Task<U, Error> {
            let result = try await self.value
            return await transform(result)
        }
    }
}
