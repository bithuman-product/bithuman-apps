// AudioEngineADMSpeaker — chunk-paired audio playback through
// libwebrtc's internal AVAudioEngine, with Apple VP-IO doing the
// AEC at the engine level.
//
// **Architecture.** LiveKit's `RTCAudioDeviceModule` (AudioEngine
// variant) creates an internal `AVAudioEngine`. We register as its
// delegate; in `didCreateEngine` we attach our own
// `AVAudioPlayerNode` + a `gainMixer` to the same engine, then in
// `willStartEngine` we rewire the output as:
//
//     mainMixerNode (libwebrtc auto-route, outputVolume = 0)
//                                                 │
//                                                 ▼
//                            ┌─── gainMixer ──── outputNode ─── speaker
//                            ▲
//   our player ──────────────┘  (full gain, plays chunk-paired audio)
//
// libwebrtc's decoder pipeline keeps mainMixerNode connected
// downstream (gainMixer is its sink), so the renderer attached to
// the inbound track keeps firing — Bithuman gets the realtime PCM
// it needs to generate frames. mainMixer's output goes out at gain
// 0 (silenced); the audio reaching the speaker is purely our
// chunk-paired player. Apple VP-IO operates on the engine's input
// and output nodes, so AEC subtracts the actual speaker output (=
// our player) from the mic capture — same engine, single AEC unit.
//
// `setVoiceProcessingEnabled(true)` is called on input/output
// nodes in `didCreateEngine` (BEFORE any connections form, per
// Apple's requirement) so VP-IO is engaged from the start.

@preconcurrency import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC

public final class AudioEngineADMSpeaker:
    NSObject,
    LKRTCAudioDeviceModuleDelegate,
    @unchecked Sendable
{
    private let player = AVAudioPlayerNode()
    private let gainMixer = AVAudioMixerNode()
    private weak var engine: AVAudioEngine?
    private var attached: Bool = false
    private var outputFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterTargetRate: Double = 0

    private let verbose: Bool
    private let onPlay: (@Sendable (Float) -> Void)?

    public init(verbose: Bool = false, onPlay: (@Sendable (Float) -> Void)? = nil) {
        let extra = ProcessInfo.processInfo.environment["BITHUMAN_DEBUG_AUDIO"] == "1"
        self.verbose = verbose || extra
        self.onPlay = onPlay
        super.init()
    }

    /// Stop in-flight playback (barge-in). `player.stop()` flushes
    /// every queued buffer; we re-`play()` so subsequent
    /// `scheduleBuffer` calls resume on the next chunk.
    public func stopPlayback() {
        player.stop()
        if let engine, engine.isRunning {
            player.play()
        }
        if verbose {
            FileHandle.standardError.write(Data(
                "↦ ADMSpeaker.stopPlayback (queue flushed)\n".utf8
            ))
        }
    }

    /// Schedule a chunk of 24 kHz Float mono audio for playback.
    /// No-ops until libwebrtc's engine has been created and we've
    /// rewired the output (`willStartEngine`). FramePump may call
    /// during the prewarm window; those drop on the floor.
    public func play(samples24k: [Float]) {
        guard attached,
              let engine,
              engine.isRunning,
              let target = outputFormat
        else {
            if verbose {
                FileHandle.standardError.write(Data(
                    "→ ADMSpeaker.play DROPPED — attached=\(attached) running=\(engine?.isRunning ?? false) target=\(outputFormat != nil)\n".utf8
                ))
            }
            return
        }
        guard !samples24k.isEmpty,
              let inBuf = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples24k.count)
              )
        else { return }
        inBuf.frameLength = AVAudioFrameCount(samples24k.count)
        if let dst = inBuf.floatChannelData?[0] {
            samples24k.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: samples24k.count)
                }
            }
        }

        // Compute chunk RMS for the host's bot-level meter.
        if let onPlay {
            var sum: Double = 0, n = 0, i = 0
            while i < samples24k.count {
                let v = Double(samples24k[i]); sum += v * v; n += 1; i += 8
            }
            onPlay(n > 0 ? Float((sum / Double(n)).squareRoot()) : 0)
        }

        // Same-format pass-through — rare on macOS (output is
        // typically 48 kHz) but possible.
        if sourceFormat.sampleRate == target.sampleRate,
           sourceFormat.channelCount == target.channelCount {
            player.scheduleBuffer(inBuf, completionHandler: nil)
            return
        }

        if converter == nil || converterTargetRate != target.sampleRate {
            converter = AVAudioConverter(from: sourceFormat, to: target)
            converterTargetRate = target.sampleRate
        }
        guard let conv = converter else { return }

        let ratio = target.sampleRate / sourceFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(samples24k.count) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)
        else { return }
        var delivered = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, statusOut in
            if delivered { statusOut.pointee = .noDataNow; return nil }
            delivered = true
            statusOut.pointee = .haveData
            return inBuf
        }
        guard status != .error, out.frameLength > 0 else { return }
        player.scheduleBuffer(out, completionHandler: nil)
    }

    // MARK: - LKRTCAudioDeviceModuleDelegate

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent
    ) {}

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        didCreateEngine engine: AVAudioEngine
    ) -> Int {
        self.engine = engine
        if !attached {
            // Apple VP-IO must be enabled on input + output nodes
            // BEFORE any connections form. AEC only subtracts audio
            // rendered by THE SAME engine — so VP-IO sees what our
            // player renders to outputNode.
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                try engine.outputNode.setVoiceProcessingEnabled(true)
                if verbose {
                    FileHandle.standardError.write(Data(
                        "↦ VP-IO enabled on engine input + output nodes\n".utf8
                    ))
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "‼ VP-IO setVoiceProcessingEnabled failed: \(error.localizedDescription)\n".utf8
                ))
            }
            engine.attach(player)
            engine.attach(gainMixer)
            attached = true
            if verbose {
                FileHandle.standardError.write(Data(
                    "↦ ADMSpeaker attached player + gainMixer to libwebrtc engine\n".utf8
                ))
            }
        }
        return 0
    }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        willEnableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        if verbose {
            FileHandle.standardError.write(Data(
                "↦ ADMSpeaker willEnableEngine playout=\(isPlayoutEnabled) recording=\(isRecordingEnabled)\n".utf8
            ))
        }
        return 0
    }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        willStartEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int {
        // Re-route engine output:
        //   mainMixer (libwebrtc auto-route, outputVolume=0) ─┐
        //                                                    ▼
        //                                   ┌── gainMixer ── outputNode
        //                                   ▲
        //   our player ─────────────────────┘
        //
        // Decoder pipeline upstream of mainMixer keeps running
        // (its sink is gainMixer). The renderer tap on the inbound
        // track fires upstream of all this, so Bithuman still gets
        // realtime PCM. Audibly only our player reaches the speaker.
        if !attached {
            self.engine = engine
            engine.attach(player)
            engine.attach(gainMixer)
            attached = true
        }
        let mainMixer = engine.mainMixerNode
        let outFmt = mainMixer.outputFormat(forBus: 0)
        mainMixer.outputVolume = 0
        engine.disconnectNodeOutput(mainMixer)
        engine.connect(mainMixer, to: gainMixer, format: outFmt)
        engine.connect(player, to: gainMixer, format: outFmt)
        engine.connect(gainMixer, to: engine.outputNode, format: outFmt)
        outputFormat = outFmt
        if verbose {
            FileHandle.standardError.write(Data(
                "↦ ADMSpeaker rewired via gainMixer (\(outFmt.sampleRate)Hz/\(outFmt.channelCount)ch); libwebrtc bus muted, player audible\n".utf8
            ))
        }
        if !player.isPlaying { player.play() }
        return 0
    }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        didStopEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int { 0 }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        didDisableEngine engine: AVAudioEngine,
        isPlayoutEnabled: Bool,
        isRecordingEnabled: Bool
    ) -> Int { 0 }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        willReleaseEngine engine: AVAudioEngine
    ) -> Int {
        attached = false
        self.engine = nil
        outputFormat = nil
        return 0
    }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureInputFromSource source: AVAudioNode?,
        toDestination destination: AVAudioNode,
        format: AVAudioFormat,
        context: [AnyHashable: Any]
    ) -> Int { 0 }

    public func audioDeviceModule(
        _ adm: LKRTCAudioDeviceModule,
        engine: AVAudioEngine,
        configureOutputFromSource source: AVAudioNode,
        toDestination destination: AVAudioNode?,
        format: AVAudioFormat,
        context: [AnyHashable: Any]
    ) -> Int { 0 }

    public func audioDeviceModuleDidUpdateDevices(_ adm: LKRTCAudioDeviceModule) {}
}
