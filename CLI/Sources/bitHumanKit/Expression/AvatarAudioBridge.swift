import AVFoundation
import Foundation

/// Routes Qwen3 TTS output into the avatar engine.
///
/// The bitHuman expression engine wants two parallel streams of the
/// same audio: 24 kHz mono Float32 (display-sync reference) and
/// 16 kHz mono Float32 (wav2vec2 speech-encoder input). Qwen3 emits
/// at whatever sample rate the model returns (24 kHz in practice),
/// so this bridge resamples each `AVAudioPCMBuffer` once into both
/// targets and pushes the pair through `Bithuman.pushAudio`.
///
/// One bridge per avatar session — converters are stateful and
/// configured to the source format on first chunk.
final class AvatarAudioBridge: @unchecked Sendable {
    private let bithuman: Bithuman
    private let target24k: AVAudioFormat
    private let target16k: AVAudioFormat
    private var converter24k: AVAudioConverter?
    private var converter16k: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(bithuman: Bithuman) {
        self.bithuman = bithuman
        // Both targets are mono Float32 at the engine's contract rates.
        self.target24k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
            channels: 1, interleaved: false
        )!
        self.target16k = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false
        )!
    }

    /// Convert `pcm` to 24 kHz + 16 kHz Float32 mono and push the pair
    /// through to the engine. Sync from the caller's perspective —
    /// the engine actor's `pushAudio` is awaited on a detached Task
    /// so the TTS chunk-scheduling path doesn't block on it.
    private static let traceEnabled =
        ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_PUMP"] != nil
        || ProcessInfo.processInfo.environment["BITHUMAN_AUDIO_TRACE"] != nil
    private static var lastTtsChunkAt: Date?
    private static let traceLock = NSLock()

    func handle(_ pcm: AVAudioPCMBuffer) {
        if Self.traceEnabled {
            // Profiling: log inter-arrival time of TTS chunks. If
            // Qwen3 is GPU-starved by avatar Metal contention, this
            // will be highly irregular (~50–800 ms variance).
            // Healthy is ≤300 ms (close to one streamingInterval=0.24).
            Self.traceLock.lock()
            let dt: Int = Self.lastTtsChunkAt.map {
                Int(Date().timeIntervalSince($0) * 1000)
            } ?? 0
            Self.lastTtsChunkAt = Date()
            Self.traceLock.unlock()
            FileHandle.standardError.write(Data(
                "[bridge] tts chunk x\(pcm.frameLength)f Δ=\(dt)ms\n".utf8
            ))
        }
        guard let inFmt = pcm.format as AVAudioFormat? else { return }

        // Lazy-build the converters on first chunk. Source format is
        // stable across an entire utterance / session, so once-and-
        // done is fine.
        if converter24k == nil || converter16k == nil || sourceFormat != inFmt {
            sourceFormat = inFmt
            converter24k = AVAudioConverter(from: inFmt, to: target24k)
            converter16k = AVAudioConverter(from: inFmt, to: target16k)
        }
        guard let c24 = converter24k, let c16 = converter16k else { return }

        guard
            let samples24 = resample(pcm, with: c24, to: target24k),
            let samples16 = resample(pcm, with: c16, to: target16k)
        else { return }

        // Hand the paired arrays off to the engine's actor on a
        // detached Task — pushAudio is `async throws` and we don't
        // want this synchronous fan-out to block the TTS player's
        // chunk scheduling loop.
        Task.detached(priority: .userInitiated) { [bithuman] in
            try? await bithuman.pushAudio(audio24k: samples24, audio16k: samples16)
        }
    }

    /// Resample `inBuf` through `converter` into `targetFormat`,
    /// returning the result as a Float32 array.
    ///
    /// Uses `AVAudioConverter.convert(to:error:withInputFrom:)` (the
    /// pull-style API) and signals `.noDataNow` rather than
    /// `.endOfStream` after feeding the buffer — `endOfStream` puts
    /// the converter into a drained / inert state and any subsequent
    /// chunk silently fails to convert. `noDataNow` keeps the
    /// converter alive for the next call, which is what we want for
    /// streaming conversion across many TTS chunks.
    private func resample(
        _ inBuf: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / inBuf.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outCapacity
        ) else { return nil }

        var fed = false
        var lastError: NSError?
        let status = converter.convert(to: outBuf, error: &lastError) { _, statusOut in
            if fed {
                statusOut.pointee = .noDataNow
                return nil
            }
            fed = true
            statusOut.pointee = .haveData
            return inBuf
        }
        guard status != .error, lastError == nil else { return nil }

        let n = Int(outBuf.frameLength)
        guard let chPtr = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: chPtr, count: n))
    }
}
