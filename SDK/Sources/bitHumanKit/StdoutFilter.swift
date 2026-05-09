import Foundation

/// Process-wide stdout interceptor that scrubs the noisy `print()` chatter
/// from mlx-audio-swift — cache-verification messages, download progress
/// lines, per-call "Got audio ID:" traces, etc. — so the conversation UI
/// stays readable.
///
/// How it works: at `install()` we create a pipe, dup2 fd 1 to the
/// pipe's write end, and save the original stdout fd. A background
/// Task reads from the pipe line-by-line, drops / truncates any line
/// that matches a known noise pattern, and writes the rest to the
/// saved fd (the real terminal).
///
/// The library writes each of its messages with a trailing `\n` while
/// our orchestrator streams tokens without newlines, so the two often
/// share a line (`"🤖 Hello.Downloading model…\n"`). In that case we
/// emit the pre-marker prefix without a newline, and drop the library
/// portion along with its trailing newline — the user sees the
/// orchestrator's intended single-line streaming without interruption.
enum StdoutFilter {
    /// Line substrings that mark the start of library noise. When any
    /// of these appears in a line, everything from that position to
    /// the end of the line (including the trailing newline) is dropped.
    private static let markers: [String] = [
        // Download / cache lifecycle
        "Downloading model ",
        "Model downloaded to:",
        "Downloaded model ",
        "Using cached model at:",
        // Component load traces — generic "Loaded " prefix catches
        // every variant the SDK prints ("Loaded speech tokenizer
        // decoder", "Loaded speaker encoder", "Loaded Qwen3-TTS model
        // (base)", "Loaded Kokoro model", "Loaded PocketTTS model", …).
        "Loaded ",
        // Generation runtime chatter
        "Got audio ID:",
        "Returning cached context",
        "Generated tokenizer.json",
        "Generated ",  // "Generated tokenizer.json from vocab.json + merges.txt" etc.
    ]

    /// Install the filter. Idempotent — safe to call more than once.
    /// Must run BEFORE any library code touches stdout, so call it at
    /// the very top of `main`.
    static func install() {
        // Create pipe. fds[0] read, fds[1] write.
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        let readFD = fds[0]
        let writeFD = fds[1]

        // Save real stdout so we can still write to the terminal.
        let origStdout = dup(1)
        guard origStdout >= 0 else {
            close(readFD); close(writeFD)
            return
        }

        // Redirect process-wide stdout (fd 1) to the pipe's write end.
        guard dup2(writeFD, 1) >= 0 else {
            close(readFD); close(writeFD); close(origStdout)
            return
        }
        close(writeFD)  // kernel keeps ref via fd 1

        // Keep the new fd 1 unbuffered so Swift `print()` flushes each
        // line immediately — otherwise chat output sits in the stdio
        // buffer until block-fill.
        setbuf(stdout, nil)

        Task.detached(priority: .background) {
            let reader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
            let writer = FileHandle(fileDescriptor: origStdout, closeOnDealloc: false)
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }  // pipe closed
                buffer.append(chunk)

                while let nlOffset = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<nlOffset]
                    buffer.removeSubrange(buffer.startIndex...nlOffset)
                    let line = String(decoding: lineData, as: UTF8.self)

                    // Pure progress lines ("N/M files") — drop entirely
                    // including the newline, since the whole line and
                    // its terminator are noise.
                    if Self.isProgressLine(line) {
                        continue
                    }

                    // Truncate at the earliest marker, if any. Emit
                    // whatever came before (no trailing newline: the
                    // newline was part of the library's noise line,
                    // and the orchestrator's preceding content is
                    // mid-stream).
                    if let cut = Self.earliestMarker(in: line) {
                        let prefix = String(line[..<cut])
                        if !prefix.isEmpty {
                            writer.write(Data(prefix.utf8))
                        }
                    } else {
                        // Legit line — emit verbatim with newline.
                        writer.write(Data((line + "\n").utf8))
                    }
                }
            }
        }
    }

    private static func earliestMarker(in s: String) -> String.Index? {
        var best: String.Index? = nil
        for m in markers {
            if let r = s.range(of: m), best.map({ r.lowerBound < $0 }) ?? true {
                best = r.lowerBound
            }
        }
        return best
    }

    private static func isProgressLine(_ s: String) -> Bool {
        // "0/9119497 files" or "9119497/9119497 files"
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix(" files") else { return false }
        let head = t.dropLast(" files".count)
        let parts = head.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
    }
}
