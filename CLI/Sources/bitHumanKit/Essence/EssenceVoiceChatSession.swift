// SPDX-License-Identifier: Apache-2.0
//
// EssenceVoiceChatSession — public API for hosting an Essence avatar
// session inside a SwiftUI / AppKit app.
//
// Lifts the helper classes that lived inside `BithumanCLI` (where they
// were first proven out for v0.10.x) into the framework so the macOS,
// iPad, and iPhone apps can share the exact same dispatch instead of
// each duplicating the bridge + frame consumer.
//
// Why a dedicated session host (rather than threading Essence through
// `VoiceChat.start()`'s avatar branch): Expression and Essence have
// genuinely different audio shapes (paired 24 kHz + 16 kHz Float32
// for Expression's wav2vec/DiT pair vs single-stream 16 kHz Int16 for
// Essence) AND different frame loops (Expression's pull-style
// `tryDequeueChunk` vs Essence's push-style `AsyncStream<CGImage?>`).
// Wiring both through one `AvatarConfig` would force the audio bridge
// + window code to fork on the runtime case anyway; collecting that
// fork into one Essence-shaped helper keeps the Expression code path
// in `VoiceChat` untouched (zero regression risk) and makes the
// Essence path easy to read end-to-end.

import AVFoundation
import CoreGraphics
import Foundation

/// Public host for an Essence-mode avatar session.
///
/// Owns the lifetime of the ``EssenceRuntime`` actor, the PCM-observer
/// bridge that converts Kokoro / Qwen3 TTS chunks to the 16 kHz Int16
/// shape ``EssenceRuntime/pushAudio(_:)`` expects, and the consumer
/// task that drains ``EssenceRuntime/frames()`` into the caller's
/// frame sink (any ``AvatarFrameSink`` — `AvatarWindow` on macOS, a
/// `MetalRenderView` on iOS, a Picture-in-Picture controller, etc).
///
/// Typical app integration:
///
/// ```swift
/// let runtime = try EssenceRuntime.create(modelPath: imxURL)
/// let session = EssenceVoiceChatSession(runtime: runtime, sink: window)
/// session.startConsuming()
///
/// var config = VoiceChatConfig()
/// config.voice = .default
/// // Note: NO `config.avatar` — Essence does not use the Expression
/// // avatar pipeline. The audio bridge below replaces it.
/// let chat = VoiceChat(config: config)
/// try await chat.start()
///
/// await chat.setPCMObserver { [bridge = session.pcmBridge] pcm in
///     bridge.handle(pcm)
/// }
/// ```
@MainActor
public final class EssenceVoiceChatSession {

    /// The Essence runtime actor owning the per-frame inference.
    public let runtime: EssenceRuntime

    /// The frame sink (e.g., ``AvatarWindow`` on macOS, a
    /// `MetalRenderView` on iOS) the consumer task drives.
    public let sink: AvatarFrameSink

    /// Stateful PCM bridge — feed every TTS chunk through this and it
    /// resamples to 16 kHz Int16 and pushes into the runtime.
    public let pcmBridge: EssencePCMBridge

    private var consumerTask: Task<Void, Never>?

    public init(runtime: EssenceRuntime, sink: AvatarFrameSink) {
        self.runtime = runtime
        self.sink = sink
        self.pcmBridge = EssencePCMBridge(runtime: runtime)
    }

    /// Spin up the frame consumer. The runtime's stream emits
    /// `CGImage?` at 25 FPS; `nil` is the idle marker (no audio for
    /// >100 ms).
    ///
    /// We seed the sink with the runtime's static idle frame
    /// **immediately** so a freshly-opened window isn't black between
    /// launch and the first TTS chunk arriving (which can take ~1 s
    /// on cold start). On every `nil` idle marker we re-render the
    /// idle frame too — that snaps the avatar back to a neutral
    /// closed-mouth pose at end of speech, which is a less jarring UX
    /// than freezing on whatever lipsynced phoneme played last.
    public func startConsuming() {
        guard consumerTask == nil else { return }
        let verbose = ProcessInfo.processInfo.environment["BITHUMAN_VERBOSE"] == "1"
        // Seed first so the window has something to display the
        // instant it appears on screen.
        sink.render(runtime.idleFrame)
        if verbose {
            FileHandle.standardError.write(Data(
                "🎬 EssenceVoiceChatSession: seeded idle frame (\(runtime.resolution.width)×\(runtime.resolution.height)).\n".utf8
            ))
        }

        let runtime = self.runtime
        let sink = self.sink
        consumerTask = Task { @MainActor in
            var frameCount = 0
            var idleCount = 0
            var lastLog = Date()
            for await maybeFrame in await runtime.frames() {
                if Task.isCancelled { break }
                if let frame = maybeFrame {
                    sink.render(frame)
                    frameCount &+= 1
                } else {
                    // Idle gap (>100 ms of silence) — return to the
                    // neutral pose.
                    sink.render(runtime.idleFrame)
                    idleCount &+= 1
                }
                if verbose, Date().timeIntervalSince(lastLog) >= 1.0 {
                    FileHandle.standardError.write(Data(
                        "🎬 EssenceVoiceChatSession: \(frameCount) live, \(idleCount) idle frames in last sec.\n".utf8
                    ))
                    frameCount = 0; idleCount = 0; lastLog = Date()
                }
            }
        }
    }

    /// Tear down the consumer task and the runtime. Idempotent.
    public func stop() async {
        consumerTask?.cancel()
        consumerTask = nil
        await runtime.stop()
    }
}

/// Stateful resampler that converts incoming TTS chunks
/// (`AVAudioPCMBuffer`, whatever Float32 sample rate Kokoro / Qwen3
/// happen to emit at) into the 16 kHz Int16 mono format
/// ``EssenceRuntime/pushAudio(_:)`` requires.
///
/// One instance per session — `AVAudioConverter` is stateful (it
/// carries internal resampling history across `convert()` calls), so
/// re-using the same converter across an utterance avoids the seam
/// artefacts a fresh converter would introduce at every chunk
/// boundary. The source format is locked on the first chunk; if the
/// TTS player switches backends mid-session (it doesn't today, but
/// guarding is cheap), the converter rebuilds.
public final class EssencePCMBridge: @unchecked Sendable {
    /// One-shot log gate for `BITHUMAN_VERBOSE=1` — flips true after
    /// the first chunk is observed so the log doesn't spam every
    /// 20 ms TTS callback.
    nonisolated(unsafe) static var _loggedFirstChunk: Bool = false

    private let runtime: EssenceRuntime
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// FIFO pipe between the TTS-thread `handle(_:)` calls and the
    /// drain task that pushes into the actor. Each TTS chunk lands
    /// in this stream in the order the player produced it; the
    /// drain awaits values one-at-a-time and calls
    /// `runtime.pushAudio` in strict order. This replaces the v0.18.0
    /// "spawn one `Task.detached` per chunk" pattern, which raced —
    /// detached tasks reach the actor in scheduler-dependent order,
    /// so a stream of TTS chunks could arrive at the runtime
    /// out-of-order, scrambling lipsync.
    private let chunkStream: AsyncStream<[Int16]>
    private let chunkContinuation: AsyncStream<[Int16]>.Continuation
    private var drainTask: Task<Void, Never>?

    public init(runtime: EssenceRuntime) {
        self.runtime = runtime
        // Essence's contract per algo spec §1: 16 kHz mono Int16. We
        // run the converter to Float32 and quantise to Int16 ourselves
        // because `AVAudioConverter` won't bridge Float32 → Int16
        // through a sample-rate change in one pass on every macOS
        // build (the second conversion sometimes returns
        // `.inputRanOutOfData` with no error). Two-step is reliable.
        self.target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let (stream, cont) = AsyncStream.makeStream(of: [Int16].self,
                                                     bufferingPolicy: .unbounded)
        self.chunkStream = stream
        self.chunkContinuation = cont
        // Start the drainer immediately. Single consumer; serial.
        let runtimeRef = runtime
        self.drainTask = Task.detached(priority: .userInitiated) {
            for await samples in stream {
                if Task.isCancelled { break }
                await runtimeRef.pushAudio(samples)
            }
        }
    }

    deinit {
        chunkContinuation.finish()
        drainTask?.cancel()
    }

    /// Drop-in handler for the `setPCMObserver` callback shape used
    /// by `VoiceChat`'s TTS players. Synchronous from the caller's
    /// perspective; spawns a detached task to actually push into the
    /// runtime so the TTS player isn't blocked on the avatar.
    public func handle(_ pcm: AVAudioPCMBuffer) {
        // BITHUMAN_VERBOSE=1 surfaces the bridge's per-chunk activity
        // so the apps' "no motion in the window" debugging path
        // doesn't have to guess whether the PCM observer fired.
        // Cheap (one-time format log + one int per call); no overhead
        // when off.
        if !Self._loggedFirstChunk,
           ProcessInfo.processInfo.environment["BITHUMAN_VERBOSE"] == "1" {
            Self._loggedFirstChunk = true
            FileHandle.standardError.write(Data(
                "🔊 EssencePCMBridge: first chunk in. format=\(pcm.format.sampleRate) Hz, \(pcm.format.channelCount) ch, \(pcm.frameLength) frames.\n".utf8
            ))
        }
        let inFmt = pcm.format
        if converter == nil || sourceFormat != inFmt {
            sourceFormat = inFmt
            converter = AVAudioConverter(from: inFmt, to: target)
        }
        guard let conv = converter,
              let floatSamples = resample(pcm, with: conv)
        else { return }

        // Float32 → Int16 quantisation. Clamp at the rails so a TTS
        // chunk with an over-1.0 transient (rare but seen in Qwen3's
        // emphatic syllables) doesn't wrap around to a negative
        // sawtooth on conversion.
        var i16 = [Int16]()
        i16.reserveCapacity(floatSamples.count)
        for f in floatSamples {
            let scaled = f * 32767.0
            let clamped: Float = max(-32768.0, min(32767.0, scaled))
            i16.append(Int16(clamped))
        }
        if i16.isEmpty { return }
        // Yield to the FIFO chunk stream — the drain task pushes into
        // the runtime actor in strict arrival order. Buffer policy
        // is `.unbounded` so the producer never blocks, and the
        // runtime actor's audio buffer has its own bound check
        // (`audioBufferCapacity`) that drops the oldest samples on
        // overflow. Net: PCM observer remains a synchronous fire-
        // and-forget for the TTS thread, ordering is preserved, and
        // a slow runtime can't backpressure the TTS player.
        chunkContinuation.yield(i16)
    }

    private func resample(
        _ inBuf: AVAudioPCMBuffer,
        with converter: AVAudioConverter
    ) -> [Float]? {
        let ratio = target.sampleRate / inBuf.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(
            pcmFormat: target, frameCapacity: outCapacity
        ) else { return nil }

        // Pull-style API with `.noDataNow` after the single chunk we
        // hold — same pattern as `AvatarAudioBridge.resample`. Using
        // `.endOfStream` would put the converter in a drained state
        // and the next chunk would silently fail.
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
