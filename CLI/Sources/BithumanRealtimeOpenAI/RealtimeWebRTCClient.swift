// WebRTC transport for OpenAI's realtime API.
//
// **Why WebRTC instead of WebSocket.** The WebSocket transport
// (`RealtimeClient.swift`) sends raw PCM16 bytes up and down — no
// AEC, no built-in audio device. With laptop speakers + a mic the
// bot's voice loops back into the input stream, server VAD treats it
// as user speech, and you get a self-talk cycle.
//
// libwebrtc — what Chrome's `getUserMedia` and Safari's WebRTC stack
// use — bundles the AEC + NS + AGC pipeline inside its
// `audioDeviceModule`. Connecting to OpenAI via WebRTC instead of
// WebSocket means the same library Chrome uses for transparent AEC
// is now on our client. No custom audio processing, just a different
// transport.
//
// **Wire format.**
//
//   1. POST our SDP offer to
//      `https://api.openai.com/v1/realtime?model=…` with
//      `Content-Type: application/sdp` and the API key as bearer.
//   2. Server replies with an SDP answer (also `application/sdp`).
//   3. ICE negotiation completes; audio flows bidirectionally over
//      the negotiated peer connection.
//   4. Server-sent events (session.created, response.audio_transcript
//      .delta, etc.) arrive on the `oai-events` data channel as
//      JSON strings — identical schema to the WebSocket transport,
//      just delivered over SCTP/DTLS instead of TCP.

@preconcurrency import Foundation
@preconcurrency import LiveKitWebRTC

// LiveKitWebRTC prefixes every Obj-C type with `LK` (via the framework's
// `RTC_OBJC_TYPE_PREFIX = LK`), so `RTCPeerConnection` ships as
// `LKRTCPeerConnection`. We typealias them back to their unprefixed
// names so the rest of the file (originally written against
// stasel/WebRTC's plain `RTC*` names) keeps reading the same.
typealias RTCPeerConnectionFactory = LKRTCPeerConnectionFactory
typealias RTCPeerConnection = LKRTCPeerConnection
typealias RTCConfiguration = LKRTCConfiguration
typealias RTCIceServer = LKRTCIceServer
typealias RTCMediaConstraints = LKRTCMediaConstraints
typealias RTCAudioSource = LKRTCAudioSource
typealias RTCAudioTrack = LKRTCAudioTrack
typealias RTCDataChannel = LKRTCDataChannel
typealias RTCDataChannelConfiguration = LKRTCDataChannelConfiguration
typealias RTCDataBuffer = LKRTCDataBuffer
typealias RTCSessionDescription = LKRTCSessionDescription
typealias RTCIceCandidate = LKRTCIceCandidate
typealias RTCMediaStream = LKRTCMediaStream
typealias RTCRtpTransceiverInit = LKRTCRtpTransceiverInit
typealias RTCRtpSource = LKRTCRtpSource
typealias RTCDefaultVideoDecoderFactory = LKRTCDefaultVideoDecoderFactory
typealias RTCDefaultVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory
typealias RTCPeerConnectionDelegate = LKRTCPeerConnectionDelegate
typealias RTCDataChannelDelegate = LKRTCDataChannelDelegate
typealias RTCAudioRenderer = LKRTCAudioRenderer
typealias RTCSignalingState = LKRTCSignalingState
typealias RTCIceConnectionState = LKRTCIceConnectionState
typealias RTCIceGatheringState = LKRTCIceGatheringState
let RTCInitializeSSL = LKRTCInitializeSSL

/// Bridge type that conforms to `RTCAudioRenderer` (which lives in
/// LiveKitWebRTC's Obj-C namespace) and forwards each PCM buffer to a
/// pure-Swift closure. Lets callers tap the bot's audio without
/// importing LiveKitWebRTC themselves — they just hand the actor an
/// `(AVAudioPCMBuffer) -> Void`. The forwarder retains itself
/// (registered on the audio track) for the lifetime of the call.
final class WebRTCAudioRendererForwarder: NSObject, RTCAudioRenderer, @unchecked Sendable {
    let onPCM: @Sendable (AVAudioPCMBuffer) -> Void
    init(onPCM: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onPCM = onPCM
    }
    func render(pcmBuffer: AVAudioPCMBuffer) {
        onPCM(pcmBuffer)
    }
}

public actor RealtimeWebRTCClient {
    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String?
    private let ui: TerminalUI
    private let verbose: Bool
    /// Optional sink for the bot's inbound PCM audio. When set, the
    /// client attaches an `RTCAudioRenderer` to the first inbound
    /// audio track and pipes every `AVAudioPCMBuffer` libwebrtc
    /// renders into the closure. Used by video mode to drive
    /// `EssenceRuntime.pushAudio` for lipsync. Not set in voice mode
    /// — the system speaker output is enough.
    private let onBotPCM: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// When non-nil, the client uses LiveKit's AudioEngine ADM and
    /// installs this speaker as the ADM's delegate so it can attach
    /// an `AVAudioPlayerNode` to libwebrtc's internal `AVAudioEngine`,
    /// rewire the engine output via a gain mixer (libwebrtc
    /// auto-route silenced; our player audible), and run Apple
    /// VP-IO for AEC against our player's audio. Used by avatar
    /// cloud mode for chunk-paired playback in sync with Bithuman
    /// frames. Voice mode and Essence cloud pass nil and use
    /// PlatformDefault ADM with native auto-playback.
    private let admSpeaker: AudioEngineADMSpeaker?
    /// Fires the moment the server's VAD reports the user has
    /// started speaking — BEFORE we transition the UI state or
    /// send `response.cancel`. Avatar mode wires this up to flush
    /// the in-flight chunk audio + frame buffer + engine pending
    /// state so the bot stops mid-syllable instead of finishing
    /// its buffered reply over the user's first word.
    private let onUserSpeechStarted: (@Sendable () async -> Void)?
    /// Fires `true` on `response.created` and `false` on
    /// `response.done` / `response.cancelled`. Avatar mode reads
    /// this in `onBotPCM` to skip feeding silence-padding audio
    /// into Bithuman's DiT pipeline during listening/hearing,
    /// which otherwise burns GPU generating "lipsync for silence"
    /// chunks the user never sees.
    private let onBotResponseActiveChange: (@Sendable (Bool) -> Void)?
    private var audioRendererForwarder: WebRTCAudioRendererForwarder?
    private var inboundAudioTrack: RTCAudioTrack?

    /// libwebrtc plumbing. The factory is the entry point that
    /// produces every other RTC object — must outlive the
    /// connection. Audio source + track are the mic; data channel
    /// is how the server pushes JSON events (same schema as WS).
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    private var dataChannel: RTCDataChannel?

    /// Bridges libwebrtc's @objc-protocol callbacks back into the
    /// actor. Held here so it isn't deallocated mid-session.
    private var delegateBridge: WebRTCDelegateBridge?

    /// Polls `RTCRtpSource.audioLevel` on the bot's receive track at
    /// 10 Hz, pushes the value into the UI's bot meter. libwebrtc
    /// publishes this as a 0.0…1.0 normalised level per RTP packet
    /// (the `urn:ietf:params:rtp-hdrext:ssrc-audio-level` extension)
    /// — accurate, cheap, no decoding needed.
    private var botLevelPollTask: Task<Void, Never>?

    /// AsyncStream of decoded events from the data channel. The
    /// receive loop iterates this and dispatches to `ui` events
    /// (mirrors `RealtimeClient.runReceiveLoop`).
    private nonisolated let events: AsyncStream<[String: Any]>
    private nonisolated let eventsCont: AsyncStream<[String: Any]>.Continuation

    public init(
        apiKey: String,
        model: String,
        voice: String,
        instructions: String?,
        ui: TerminalUI,
        verbose: Bool,
        onBotPCM: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
        admSpeaker: AudioEngineADMSpeaker? = nil,
        onUserSpeechStarted: (@Sendable () async -> Void)? = nil,
        onBotResponseActiveChange: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.ui = ui
        self.verbose = verbose
        self.onBotPCM = onBotPCM
        self.admSpeaker = admSpeaker
        self.onUserSpeechStarted = onUserSpeechStarted
        self.onBotResponseActiveChange = onBotResponseActiveChange

        var c: AsyncStream<[String: Any]>.Continuation!
        self.events = AsyncStream { c = $0 }
        self.eventsCont = c
    }

    /// Hop back into actor isolation, retain the inbound track, and
    /// attach the renderer. Called from the delegate bridge once the
    /// remote stream lands.
    private func attachBotRenderer(track: RTCAudioTrack, forwarder: WebRTCAudioRendererForwarder) {
        self.inboundAudioTrack = track
        track.add(forwarder)
        if verbose {
            FileHandle.standardError.write(Data("✓ attached audio renderer to inbound bot track\n".utf8))
        }
    }

    public func connect() async throws {
        // 1. Initialise SSL + create the factory. `initialize` only
        //    needs to be called once per process; calling it again
        //    is a no-op so it's safe to make it part of `connect()`.
        RTCInitializeSSL()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        // Avatar cloud mode (`admSpeaker != nil`) uses LiveKit's
        // AudioEngine ADM so it gets a real `AVAudioEngine` that
        // Apple VP-IO can run on. The speaker delegate attaches a
        // player + gainMixer to that engine and rewires the
        // output: libwebrtc's mainMixer is silenced via
        // outputVolume=0 but stays connected (decoder pipeline
        // intact so renderer tap keeps firing); player is the sole
        // audible source feeding outputNode. Same engine captures
        // mic with VP-IO doing AEC. Voice mode and Essence cloud
        // pass nil and use PlatformDefault ADM with native auto-
        // playback.
        let factory: RTCPeerConnectionFactory
        if let admSpeaker {
            factory = RTCPeerConnectionFactory(
                audioDeviceModuleType: .audioEngine,
                bypassVoiceProcessing: false,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory,
                audioProcessingModule: nil
            )
            factory.audioDeviceModule.observer = admSpeaker
            let vp = factory.audioDeviceModule.setVoiceProcessingEnabled(true)
            factory.audioDeviceModule.isVoiceProcessingBypassed = false
            if verbose {
                FileHandle.standardError.write(Data(
                    "↦ AudioEngine ADM ready — VP(rc=\(vp), enabled=\(factory.audioDeviceModule.isVoiceProcessingEnabled), bypassed=\(factory.audioDeviceModule.isVoiceProcessingBypassed))\n".utf8
                ))
            }
        } else {
            factory = RTCPeerConnectionFactory(
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory
            )
        }
        self.factory = factory

        // 2. RTCConfiguration — minimal. OpenAI's WebRTC endpoint
        //    publishes ICE candidates of its own; we only need a
        //    public STUN server so the local NAT can be traversed.
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        // Continual gathering keeps re-evaluating ICE candidates
        // throughout the call rather than capturing once at start.
        config.continualGatheringPolicy = .gatherContinually

        let mandatoryConstraints: [String: String] = [:]
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: mandatoryConstraints,
            optionalConstraints: nil
        )

        let bridge = WebRTCDelegateBridge(eventsCont: eventsCont)
        self.delegateBridge = bridge

        // Wire the inbound-track callback so we can hang an
        // `RTCAudioRenderer` off the bot's audio track for lipsync.
        // Only set when the caller wants a PCM tap (video mode);
        // voice mode leaves it nil and libwebrtc's auto-routed
        // speaker output carries the audio without us touching it.
        if let onPCM = onBotPCM {
            let forwarder = WebRTCAudioRendererForwarder(onPCM: onPCM)
            self.audioRendererForwarder = forwarder
            bridge.onBotAudioTrack = { [weak self] track in
                Task { await self?.attachBotRenderer(track: track, forwarder: forwarder) }
            }
        }

        guard let peerConnection = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: bridge
        ) else {
            throw NSError(
                domain: "RealtimeWebRTCClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create RTCPeerConnection"]
            )
        }
        self.peerConnection = peerConnection

        // 3. Microphone audio track. `audioSource(with:)` with empty
        //    constraints uses the platform's default capture device
        //    + libwebrtc's standard processing chain (AEC, NS, AGC).
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let audioSource = factory.audioSource(with: audioConstraints)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "mic-0")
        self.audioSource = audioSource
        self.audioTrack = audioTrack

        // Add the track as a local sender. WebRTC will negotiate
        // bidirectional audio — server's TTS comes back on the same
        // peer connection and is auto-routed to the system default
        // output device by libwebrtc's audio device module.
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .sendRecv
        transceiverInit.streamIds = ["stream-0"]
        peerConnection.addTransceiver(of: .audio, init: transceiverInit)
        peerConnection.add(audioTrack, streamIds: ["stream-0"])

        // 4. Data channel `oai-events` — server sends realtime API
        //    events (session.*, response.*, conversation.*) as JSON
        //    strings on this channel. Same schema as the WebSocket
        //    transport.
        let dcConfig = RTCDataChannelConfiguration()
        dcConfig.isOrdered = true
        guard let dc = peerConnection.dataChannel(
            forLabel: "oai-events",
            configuration: dcConfig
        ) else {
            throw NSError(
                domain: "RealtimeWebRTCClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create data channel"]
            )
        }
        dc.delegate = bridge
        self.dataChannel = dc

        // 5. Create + set local SDP offer.
        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: offerConstraints) { sdp, err in
                if let err { cont.resume(throwing: err); return }
                guard let sdp else {
                    cont.resume(throwing: NSError(
                        domain: "RealtimeWebRTCClient",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "createOffer returned no SDP"]
                    ))
                    return
                }
                cont.resume(returning: sdp)
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(offer) { err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: ())
            }
        }

        // 6. POST SDP offer to OpenAI; receive SDP answer.
        let answerSDP = try await postSDPOffer(offer.sdp)

        // 7. setRemoteDescription. ICE then completes asynchronously
        //    via the delegate; once the connection state hits
        //    `.connected` we'll see audio flow + the data channel
        //    open + state.created on it.
        let answer = RTCSessionDescription(type: .answer, sdp: answerSDP)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(answer) { err in
                if let err { cont.resume(throwing: err); return }
                cont.resume(returning: ())
            }
        }

        // 8. Send the session.update right away — the server applies
        //    voice + transcription + VAD config from this. We send
        //    it as a JSON string on the data channel.
        sendSessionUpdate()

        // 9. Mic + bot level meters. Poll the WebRTC stats API at
        //    10 Hz and pull `audioLevel` for both directions:
        //
        //    - `media-source` (kind=audio) → mic level (what we're
        //      sending up to the server).
        //    - `inbound-rtp` (kind=audio) → bot level (what we're
        //      receiving + playing).
        //
        //    `RTCRtpSource.audioLevel` (which we tried first) only
        //    populates when the SSRC audio-level RTP header
        //    extension is negotiated; OpenAI's SDP doesn't include
        //    it. The W3C stats path works regardless because it
        //    samples post-decode audio inside libwebrtc itself.
        botLevelPollTask?.cancel()
        let pc = peerConnection
        let uiRef = ui
        botLevelPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                let (micLevel, botLevel) = await Self.pollAudioLevels(pc)
                await uiRef.setMicLevel(micLevel)
                await uiRef.setBotLevel(botLevel)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// One round-trip to `getStats()` → audio levels for both
    /// directions. Wraps the @objc completion-handler API in
    /// `withCheckedContinuation` so the polling task can `await`.
    private nonisolated static func pollAudioLevels(_ pc: RTCPeerConnection) async -> (mic: Float, bot: Float) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Float, Float), Never>) in
            pc.statistics { report in
                var mic: Float = 0
                var bot: Float = 0
                for (_, stat) in report.statistics {
                    let values = stat.values
                    let kind = (values["kind"] as? String)
                        ?? (values["mediaType"] as? String)
                        ?? ""
                    guard kind == "audio" else { continue }
                    let level = (values["audioLevel"] as? NSNumber)?.floatValue
                    switch stat.type {
                    case "media-source":
                        if let level { mic = max(mic, level) }
                    case "inbound-rtp":
                        if let level { bot = max(bot, level) }
                    default:
                        continue
                    }
                }
                cont.resume(returning: (mic, bot))
            }
        }
    }

    /// POST our SDP offer to OpenAI and return their SDP answer.
    /// The HTTP body is plain SDP text, both directions.
    private func postSDPOffer(_ offerSDP: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/realtime?model=\(model)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        req.httpBody = offerSDP.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "RealtimeWebRTCClient",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response from realtime endpoint"]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            // Model-not-found / model-deprecated errors come back
            // as 400 with "model_not_found" or 404 in the body.
            // Surface a helpful "try one of these" hint instead of
            // making the user grep the raw OpenAI error blob.
            let isModelError = (http.statusCode == 400 || http.statusCode == 404)
                && (body.contains("model_not_found")
                    || body.contains("does not exist")
                    || body.contains("not found"))
            let baseMsg = "OpenAI WebRTC handshake failed: HTTP \(http.statusCode)"
            let detail: String
            if isModelError {
                detail = """
                \(baseMsg) — model `\(model)` is not available to this API key.
                Pick another with `--openai-model <id>`. Known realtime models:
                  • gpt-realtime-mini             (default)
                  • gpt-realtime
                  • gpt-4o-realtime-preview
                  • gpt-4o-mini-realtime-preview
                Server response: \(body)
                """
            } else {
                detail = "\(baseMsg) — \(body)"
            }
            throw NSError(
                domain: "RealtimeWebRTCClient",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
        guard let sdp = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "RealtimeWebRTCClient",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Empty SDP answer"]
            )
        }
        return sdp
    }

    /// Send `session.update` once the data channel is open. Same JSON
    /// schema as the WebSocket transport's session.update — voice,
    /// audio formats, transcription, server VAD turn detection.
    private func sendSessionUpdate() {
        // Defer the actual send until the data channel is open;
        // `RTCDataChannel.send` silently drops messages while the
        // channel is in the connecting state. The bridge calls back
        // into `dataChannelDidOpen` once it's safe.
        delegateBridge?.onDataChannelOpen = { [weak self] in
            Task { await self?.actuallySendSessionUpdate() }
        }
    }

    private func actuallySendSessionUpdate() {
        let prompt = instructions
            ?? "You are a helpful, friendly voice assistant. Keep replies short and conversational."
        let session: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": prompt,
            "voice": voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "input_audio_transcription": ["model": "whisper-1"],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
            ],
        ]
        let event: [String: Any] = [
            "type": "session.update",
            "session": session,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let dc = dataChannel
        else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dc.sendData(buffer)
    }

    private func sendCancel() {
        guard let dc = dataChannel, dc.readyState == .open else { return }
        let event: [String: Any] = ["type": "response.cancel"]
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        dc.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    public func runReceiveLoop() async throws {
        // True between `response.created` and `response.done`.
        var responseInFlight = false

        for await obj in events {
            guard let type = obj["type"] as? String else { continue }
            // Drop the high-frequency streaming deltas — they fire
            // dozens of times per turn and bury the events that
            // actually tell you what the conversation is doing.
            // Audio + transcript text already surface in the live
            // UI via dedicated handlers below; we only want
            // lifecycle / state-transition events in verbose mode.
            let chatty: Set<String> = [
                "response.audio.delta",
                "response.audio_transcript.delta",
                "conversation.item.input_audio_transcription.delta",
                "response.text.delta",
                "response.output_audio.delta",
                "response.output_audio_transcript.delta",
                "rate_limits.updated",
            ]
            if verbose, !chatty.contains(type) {
                await ui.line("← \(type)")
            }

            switch type {
            case "session.created":
                if verbose { await ui.line("✓ session.created") }
                await ui.setState(.listening)

            case "session.updated":
                if verbose { await ui.line("✓ session.updated") }

            case "input_audio_buffer.speech_started":
                // Barge-in: local pipelines flush + tell server
                // to stop streaming. (We don't toggle
                // `track.isEnabled` here — empirically that path
                // interferes with the renderer tap that feeds
                // Bithuman; without that feed there's no animation.
                // Server-side `response.cancel` round-trip is the
                // residual we accept.)
                await onUserSpeechStarted?()
                if responseInFlight { sendCancel() }
                await ui.setState(.hearing)
                await ui.userSpeechStarted()

            case "input_audio_buffer.speech_stopped":
                await ui.setState(.thinking)

            case "conversation.item.input_audio_transcription.completed":
                if let transcript = obj["transcript"] as? String {
                    await ui.commitUserTranscript(transcript)
                }

            case "response.created":
                responseInFlight = true
                onBotResponseActiveChange?(true)
                await ui.setState(.responding)
                await ui.botResponseStarted()

            case "response.audio_transcript.delta":
                if let delta = obj["delta"] as? String {
                    await ui.appendBotChunk(delta)
                }

            // (No `response.audio.delta` handler — under WebRTC
            // transport audio arrives via the RTP track, not the
            // data channel. The renderer attached in
            // `attachBotRenderer` taps the track-level PCM.)

            case "response.done":
                responseInFlight = false
                onBotResponseActiveChange?(false)
                await ui.endBotResponse()
                await ui.setState(.listening)

            case "response.cancelled":
                responseInFlight = false
                onBotResponseActiveChange?(false)
                await ui.cancelledBotResponse()
                await ui.setState(.listening)

            case "error":
                let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? "<unknown>"
                if msg.contains("Cancellation failed") {
                    if verbose { await ui.line("\u{1B}[2m(benign cancel race: \(msg))\u{1B}[0m") }
                } else {
                    await ui.errorLine("error: \(msg)")
                }

            default:
                continue
            }
        }
    }
}

// MARK: - Delegate bridge

/// libwebrtc's delegate protocols are @objc, callbacks fire on
/// arbitrary threads. This bridge object accepts the @objc
/// callbacks, decodes data-channel JSON, and forwards events into
/// the actor's `AsyncStream`. Held strongly by the client; the
/// client's lifetime keeps the bridge alive for the connection.
private final class WebRTCDelegateBridge: NSObject,
    RTCPeerConnectionDelegate,
    RTCDataChannelDelegate,
    @unchecked Sendable
{
    let eventsCont: AsyncStream<[String: Any]>.Continuation
    /// Called once when the data channel transitions to `.open`,
    /// so the client can flush its initial `session.update`.
    var onDataChannelOpen: (@Sendable () -> Void)?
    /// Called the first time an inbound audio track shows up on a
    /// remote stream — that's the bot's voice. Lets the client
    /// attach an `RTCAudioRenderer` to it for lipsync taps.
    var onBotAudioTrack: (@Sendable (RTCAudioTrack) -> Void)?

    init(eventsCont: AsyncStream<[String: Any]>.Continuation) {
        self.eventsCont = eventsCont
    }

    // RTCPeerConnectionDelegate (only the events we care about
    // implemented; the rest are no-ops).
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        // OpenAI's realtime endpoint sends the bot voice as an audio
        // track on a remote stream. Forward the first one we see so
        // the actor can hook a renderer for lipsync. Subsequent
        // streams (rare; typically just one) are ignored.
        if let track = stream.audioTracks.first {
            let cb = onBotAudioTrack
            onBotAudioTrack = nil
            cb?(track)
        }
    }
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    /// Server-initiated data channel — for OpenAI realtime, this is
    /// `oai-events`. We accept it the same way as the one we
    /// created locally.
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
    }

    // RTCDataChannelDelegate
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            onDataChannelOpen?()
            onDataChannelOpen = nil  // fire once
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // OpenAI emits all events as JSON text on the data channel.
        // `isBinary` is false for them; binary frames would be
        // unexpected and we ignore them.
        guard !buffer.isBinary else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else { return }
        eventsCont.yield(obj)
    }
}
