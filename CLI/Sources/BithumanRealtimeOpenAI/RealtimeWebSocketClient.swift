// WebSocket transport for OpenAI's Realtime API.
//
// **Why this exists alongside RealtimeWebRTCClient.** WebRTC gives
// us libwebrtc-managed audio I/O with built-in AEC — perfect for
// voice mode. But the libwebrtc Swift package we use
// (stasel/WebRTC) only exposes `RTCVideoRenderer`; there's no
// `RTCAudioRenderer` protocol on the macOS slice, so we can't tap
// the receive track to get raw PCM samples for the avatar's
// lipsync. WebSocket transport sidesteps that entirely: server
// returns base64 PCM16 in `response.audio.delta` events, we have
// the bytes in-process, and feeding them to
// `EssenceRuntime.pushAudio` / `Bithuman.pushAudio` is one line.
//
// AEC: handled by the host's `AudioGraph` on the mic-capture side
// (Apple VP-IO). The bot's audio gets played through `AudioGraph`'s
// player node, which is also the VP-IO reference signal — so the
// loop closes correctly and the mic stream sent to the server is
// already echo-free. Same approach as on-device voice mode; just
// with OpenAI as the LLM/TTS oracle instead of local MLX.
//
// Wire format is the same JSON event schema as the WebRTC data
// channel. Caller receives:
//   - `RealtimeWSEvent.userTranscript(String)`     final text
//   - `RealtimeWSEvent.botTranscriptDelta(String)` streaming text
//   - `RealtimeWSEvent.botAudio(Data)`             16-bit PCM
//   - `RealtimeWSEvent.botResponseStarted`
//   - `RealtimeWSEvent.botResponseEnded`
//   - `RealtimeWSEvent.userSpeechStarted`
//   - `RealtimeWSEvent.userSpeechStopped`

import Foundation

public enum RealtimeWSEvent: Sendable {
    case sessionReady
    case userSpeechStarted
    case userSpeechStopped
    case userTranscript(String)
    case botResponseStarted
    case botTranscriptDelta(String)
    /// 24 kHz PCM16 mono samples, raw bytes (little-endian Int16).
    /// Caller is responsible for dispatching to the speaker AND the
    /// avatar runtime in lockstep.
    case botAudio(Data)
    case botResponseEnded
    case botResponseCancelled
    case error(String)
}

public actor RealtimeWebSocketClient {

    public let events: AsyncStream<RealtimeWSEvent>
    private let eventsCont: AsyncStream<RealtimeWSEvent>.Continuation

    private let apiKey: String
    private let model: String
    private let voice: String
    private let instructions: String?
    private let verbose: Bool
    private let useServerVAD: Bool

    private var socket: URLSessionWebSocketTask?
    private var responseInFlight = false
    private var appendCalls: Int = 0
    private var appendBytes: Int = 0
    private var lastSendError: String?
    private var heartbeatTask: Task<Void, Never>?

    public init(
        apiKey: String,
        model: String,
        voice: String,
        instructions: String? = nil,
        verbose: Bool = false,
        useServerVAD: Bool = false
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.verbose = verbose
        self.useServerVAD = useServerVAD
        let (stream, cont) = AsyncStream<RealtimeWSEvent>.makeStream()
        self.events = stream
        self.eventsCont = cont
    }

    /// Open the WebSocket, send the initial `session.update`, start
    /// listening. Returns once the connection is open and the loop
    /// is pumping events into `events`.
    public func connect() async throws {
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        let task = URLSession.shared.webSocketTask(with: req)
        self.socket = task
        task.resume()
        try await sendSessionUpdate()
        Task { await receiveLoop() }
        if verbose { startHeartbeat() }
    }

    /// Periodic stderr report so we can tell whether `appendAudio` is
    /// actually reaching `socket.send` and whether the server has
    /// gone silent (gated to verbose so it doesn't interfere with the
    /// TerminalUI sticky area otherwise).
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() {
        let kb = appendBytes / 1024
        var line = "← [hb] sent \(appendCalls) chunks, \(kb) KB"
        if let err = lastSendError {
            line += " · last send error: \(err)"
        }
        line += "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Close the connection. Idempotent.
    public func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        eventsCont.finish()
    }

    /// Append a raw PCM16 24 kHz mono chunk to the input audio
    /// buffer. Server-side VAD watches this stream for speech edges
    /// and triggers transcription + response.
    public func appendAudio(_ pcm16Bytes: Data) async {
        guard let socket else { return }
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": pcm16Bytes.base64EncodedString(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8)
        else { return }
        do {
            try await socket.send(.string(json))
            appendCalls += 1
            appendBytes += pcm16Bytes.count
        } catch {
            // Don't spam stderr per-chunk; the heartbeat below will
            // surface the most recent error in aggregate.
            lastSendError = error.localizedDescription
        }
    }

    /// Force the server to commit the current audio buffer and start
    /// generating a response. Useful when server-side VAD isn't
    /// firing for some reason (possible cause: GA `gpt-realtime*` no
    /// longer supports server VAD on the WS transport).
    public func commitAndRespond() async {
        guard let socket else { return }
        let commit: [String: Any] = ["type": "input_audio_buffer.commit"]
        let create: [String: Any] = ["type": "response.create"]
        for ev in [commit, create] {
            if let data = try? JSONSerialization.data(withJSONObject: ev),
               let json = String(data: data, encoding: .utf8) {
                try? await socket.send(.string(json))
            }
        }
    }

    private func sendSessionUpdate() async throws {
        let prompt = instructions
            ?? "You are a helpful, friendly voice assistant. Keep replies short and conversational."
        var session: [String: Any] = [
            "modalities": ["audio", "text"],
            "instructions": prompt,
            "voice": voice,
            "input_audio_format": "pcm16",
            "output_audio_format": "pcm16",
            "input_audio_transcription": ["model": "whisper-1"],
        ]
        if useServerVAD {
            session["turn_detection"] = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
            ]
        } else {
            // Explicitly null out turn_detection so the server runs in
            // manual-commit mode. Caller drives `commitAndRespond`
            // when client-side VAD says the user stopped talking.
            session["turn_detection"] = NSNull()
        }
        let event: [String: Any] = [
            "type": "session.update",
            "session": session,
        ]
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try await socket?.send(.string(json))
    }

    private func sendCancel() async {
        guard let socket else { return }
        let event: [String: Any] = ["type": "response.cancel"]
        if let data = try? JSONSerialization.data(withJSONObject: event),
           let json = String(data: data, encoding: .utf8) {
            try? await socket.send(.string(json))
        }
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                eventsCont.yield(.error("ws receive: \(error.localizedDescription)"))
                eventsCont.finish()
                return
            }
            let payload: String
            switch message {
            case .string(let s): payload = s
            case .data(let d): payload = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            if verbose, type != "response.audio.delta" {
                FileHandle.standardError.write(Data("← \(type)\n".utf8))
            }
            // Always surface raw error payloads — these are how the
            // server signals that a session.update was rejected, an
            // append was malformed, etc. Filtering them by `type`
            // would hide the very signal we need to debug.
            if type == "error" {
                FileHandle.standardError.write(Data("‼ raw error payload: \(payload)\n".utf8))
            }

            switch type {
            case "session.created", "session.updated":
                eventsCont.yield(.sessionReady)
            case "input_audio_buffer.speech_started":
                eventsCont.yield(.userSpeechStarted)
                if responseInFlight { await sendCancel() }
            case "input_audio_buffer.speech_stopped":
                eventsCont.yield(.userSpeechStopped)
            case "conversation.item.input_audio_transcription.completed":
                if let t = obj["transcript"] as? String {
                    eventsCont.yield(.userTranscript(t))
                }
            case "response.created":
                responseInFlight = true
                eventsCont.yield(.botResponseStarted)
            case "response.audio.delta":
                if let b64 = obj["delta"] as? String,
                   let audioData = Data(base64Encoded: b64) {
                    eventsCont.yield(.botAudio(audioData))
                }
            case "response.audio_transcript.delta":
                if let d = obj["delta"] as? String {
                    eventsCont.yield(.botTranscriptDelta(d))
                }
            case "response.done":
                responseInFlight = false
                eventsCont.yield(.botResponseEnded)
            case "response.cancelled":
                responseInFlight = false
                eventsCont.yield(.botResponseCancelled)
            case "error":
                let msg = ((obj["error"] as? [String: Any])?["message"] as? String) ?? payload
                if !msg.contains("Cancellation failed") {
                    eventsCont.yield(.error(msg))
                }
            default:
                continue
            }
        }
    }
}
