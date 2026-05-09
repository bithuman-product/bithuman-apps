@preconcurrency import AVFoundation
import Speech

enum SpeechEvent: Sendable {
    /// Volatile partial transcription. Used as both an in-progress
    /// display string and — critically — the barge-in signal: any
    /// non-empty partial while the bot is speaking means the user
    /// just started talking.
    case partial(String)
    /// Finalized utterance, emitted after the transcriber endpoints
    /// a segment. This is the signal to commit a turn to the LLM.
    case final(String)

    var tag: String { if case .partial = self { return "partial" } else { return "FINAL" } }
    var text: String { switch self { case .partial(let t), .final(let t): return t } }
}

enum SpeechPipelineError: Error {
    case localeNotSupported(Locale)
    case noCompatibleAudioFormat
}

/// Thin wrapper around SpeechAnalyzer + SpeechTranscriber that exposes
/// one AsyncStream of SpeechEvents. We skip SpeechDetector for v1 —
/// the transcriber's volatile partials are a tighter barge-in signal
/// than raw VAD edges, and endpointing falls out of `.isFinal` for free.
actor SpeechPipeline {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat

    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let eventContinuation: AsyncStream<SpeechEvent>.Continuation

    nonisolated let events: AsyncStream<SpeechEvent>

    private var converter: AVAudioConverter?
    private var converterSrcFormat: AVAudioFormat?

    init(locale: Locale = .init(identifier: "en-US")) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // Ask AssetInventory whether a download is needed. If everything
        // is already installed, assetInstallationRequest returns nil and
        // we skip straight to analyzer wiring. The transcriber itself
        // will throw at `analyzer.start` if the locale is genuinely
        // unsupported — that error is more precise than any preflight.
        Log.asr.info("checking speech model for \(locale.identifier, privacy: .public)…")
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.asr.info("downloading speech model (first run)…")
            // Don't print here — the caller already announced
            // `.loadingSpeechModel` to BootProgress and the
            // TerminalProgressRenderer is showing it as an active
            // step with elapsed counter. Adding a stray `print()`
            // here breaks the renderer's cursor positioning and
            // duplicates the message. (Apple's
            // `downloadAndInstall()` is opaque — no progress hook
            // — so the elapsed timer is the best signal we have.)
            try await req.downloadAndInstall()
            Log.asr.info("speech model ready")
        }

        let modules: [any SpeechModule] = [transcriber]
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechPipelineError.noCompatibleAudioFormat
        }
        self.analyzerFormat = fmt
        Log.asr.info("analyzer format: \(fmt.sampleRate, privacy: .public) Hz / \(fmt.channelCount, privacy: .public) ch")

        let (inputSeq, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder
        let analyzer = SpeechAnalyzer(modules: modules)
        self.analyzer = analyzer

        let (events, eventCont) = AsyncStream<SpeechEvent>.makeStream()
        self.events = events
        self.eventContinuation = eventCont

        try await analyzer.start(inputSequence: inputSeq)

        // Drain transcriber results into our event stream. We keep this
        // task referenced via the structured pattern below; actor keeps
        // it alive until stop().
        Task { [transcriber, eventCont] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { continue }
                    if result.isFinal {
                        eventCont.yield(.final(text))
                    } else {
                        eventCont.yield(.partial(text))
                    }
                }
            } catch {
                Log.asr.error("transcriber loop ended: \(error.localizedDescription, privacy: .public)")
            }
            eventCont.finish()
        }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convertIfNeeded(buffer) else { return }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        inputBuilder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        eventContinuation.finish()
    }

    private func convertIfNeeded(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let src = buffer.format
        if src.sampleRate == analyzerFormat.sampleRate,
           src.channelCount == analyzerFormat.channelCount,
           src.commonFormat == analyzerFormat.commonFormat {
            return buffer
        }
        if converter == nil || converterSrcFormat != src {
            let c = AVAudioConverter(from: src, to: analyzerFormat)
            // VP-IO on macOS hands us a 9-channel deinterleaved buffer
            // where only channel 0 is the AEC'd mic; the rest are
            // reference/raw/diagnostic signals. AVAudioConverter's default
            // downmix sums them all into garbage. Force it to pick channel
            // 0 via an explicit channelMap.
            if src.channelCount > analyzerFormat.channelCount {
                c?.channelMap = (0..<Int(analyzerFormat.channelCount)).map { NSNumber(value: $0) }
            }
            converter = c
            converterSrcFormat = src
        }
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / src.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var provided = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            Log.audio.error("convert: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        return out
    }
}
