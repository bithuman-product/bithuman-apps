// bithuman_realtime — OpenAI Realtime session wired to the bitHuman avatar.
//
// Audio I/O is owned by the plugin's native VP-IO graph (see
// macos/Classes/RealtimeAudioIO.swift). This session is responsible for
// the WebSocket only: it forwards mic chunks to OpenAI and routes bot
// audio chunks back to the plugin. The plugin then plays them through
// the speaker AND pushes the same chunks into the avatar lipsync queue
// at the same instant — A/V cannot drift, and Apple's VP-IO subtracts
// the bot's voice from the mic so self-talk is impossible.
//
// Wire format (per https://platform.openai.com/docs/guides/realtime):
//   - Transport: wss://api.openai.com/v1/realtime?model=…
//   - Auth: `Authorization: Bearer <api_key>` (GA — no Beta header)
//   - Audio: PCM16 mono @ 24 kHz, base64-encoded inside JSON events
//   - session.update uses the GA shape: top-level `type: 'realtime'`,
//     `output_modalities`, nested `audio.input.*` / `audio.output.*`.
//     The old beta shape (top-level `modalities`/`voice`/`input_audio_format`)
//     is now rejected with `beta_api_shape_disabled`.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'bithuman_avatar.dart';

/// One Realtime session over a single WebSocket.
///
/// Lifecycle: `start()` → bidirectional audio for the session's lifetime →
/// `stop()`. The session is single-use; create a new one for the next
/// conversation. Use [statusStream] and [onError] to drive the UI.
class BithumanRealtimeSession {
  BithumanRealtimeSession({
    required this.apiKey,
    required this.avatar,
    this.model = 'gpt-realtime',
    this.systemPrompt = '',
    this.voice = 'alloy',
  }) {
    _liveSystemPrompt = systemPrompt;
    _liveVoice = voice;
  }

  final String apiKey;
  final BithumanAvatar avatar;
  final String model;
  final String systemPrompt;
  final String voice;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  StreamSubscription<Uint8List>? _micSub;
  bool _open = false;

  // Reconnect-with-backoff state. Active only while `_open == true` —
  // a user-initiated `stop()` clears these and prevents further retries.
  // Backoff schedule: 1, 2, 4, 8, 16, 30, 30, 30 seconds (cap 30 s);
  // after [_maxReconnectAttempts] consecutive failures we give up and
  // surface RealtimeStatus.error so the UI can offer a manual retry.
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  static const int _maxReconnectAttempts = 8;

  // True once the server has acknowledged the connection with any
  // inbound event (e.g. `session.created`). Used to gate the
  // `_reconnectAttempt = 0` reset — earlier code reset on TCP-level
  // success, which made server-side close-after-handshake (e.g. the
  // beta API deprecation) loop forever in `connecting` instead of
  // surfacing the error.
  bool _serverAcked = false;

  // True between `speech_started` (we sent response.cancel) and the
  // next `response.created` (OpenAI confirmed it's composing a fresh
  // reply). While true, drop any `response.audio.delta` events that
  // are still arriving — those are from the cancelled response, were
  // already in flight when we cancelled, and would otherwise keep the
  // lipsync animating after the speaker has gone silent.
  bool _droppingCancelledAudio = false;

  // True between `response.created` and `response.done` / cancellation
  // — i.e., when the agent has an in-flight reply. Used to gate
  // `response.cancel`: sending cancel when nothing is in flight makes
  // OpenAI return an "error" event ("Cancellation failed: no active
  // response found") which we'd otherwise misclassify as a connection
  // error.
  bool _haveActiveResponse = false;

  final _status = StreamController<RealtimeStatus>.broadcast();
  Stream<RealtimeStatus> get statusStream => _status.stream;

  /// Streaming text of what the bot is saying — emitted from
  /// `response.audio_transcript.delta` events. Each event carries one
  /// partial chunk; callers concatenate to build the full reply.
  final _botTranscript = StreamController<String>.broadcast();
  Stream<String> get botTranscriptStream => _botTranscript.stream;

  /// User's transcribed speech (when OpenAI returns it). Useful for
  /// captions of "what you just said". Emitted on
  /// `conversation.item.input_audio_transcription.completed`.
  final _userTranscript = StreamController<String>.broadcast();
  Stream<String> get userTranscriptStream => _userTranscript.stream;

  /// Live mic loudness in [0, 1] (peak per ~85 ms chunk). Drives the
  /// "mic is hot" pulse on the primary button so users see immediate
  /// visual feedback that their microphone is working.
  final _micLevel = StreamController<double>.broadcast();
  Stream<double> get micLevelStream => _micLevel.stream;

  /// Live bot audio loudness in [0, 1] (peak per response.audio.delta
  /// chunk). Animates a "speaking" pulse so the button glows in time
  /// with the agent's voice while the avatar's lips move.
  final _botLevel = StreamController<double>.broadcast();
  Stream<double> get botLevelStream => _botLevel.stream;

  /// Open the WebSocket, start the VP-IO audio engine, and begin
  /// forwarding echo-cancelled mic chunks to OpenAI.
  Future<void> start() async {
    if (_open) return;
    _open = true;
    _status.add(RealtimeStatus.connecting);
    try {
      // Bring up the native audio engine FIRST so VP-IO is already
      // running by the time the WS opens — the very first mic packet
      // we send is already echo-cancelled.
      await avatar.audioStart();
      _micSub = avatar.micStream.listen(_sendMicBytes);

      await _connectAndConfigure();
      _status.add(RealtimeStatus.open);
    } catch (e) {
      _status.add(RealtimeStatus.error);
      rethrow;
    }
  }

  /// Open the WebSocket and push the session.update config. Used both
  /// by the initial `start()` path and by `_reconnect()` on drops — the
  /// mic subscription + native audio graph stay up across reconnects,
  /// only the WS underneath is rebuilt.
  Future<void> _connectAndConfigure() async {
    // ignore: avoid_print
    print('[realtime] connecting to wss://api.openai.com/v1/realtime?model=$model');
    _serverAcked = false;
    _ws = IOWebSocketChannel.connect(
      Uri.parse('wss://api.openai.com/v1/realtime?model=$model'),
      headers: {
        'Authorization': 'Bearer $apiKey',
      },
    );
    _wsSub = _ws!.stream.listen(_handleMessage,
        onError: _handleError,
        onDone: _handleDone);
    // Configure the session — GA shape. Audio I/O is nested under
    // `audio.input` / `audio.output`; turn_detection lives inside
    // `audio.input`. PCM16 mono @ 24 kHz both directions.
    _send({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'instructions': systemPrompt,
        'output_modalities': ['audio'],
        'audio': {
          'input': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            'turn_detection': {
              'type': 'server_vad',
              'threshold': 0.5,
              'prefix_padding_ms': 300,
              'silence_duration_ms': 500,
              'create_response': true,
              'interrupt_response': true,
            },
            // Surface user transcripts so captions of "what you just said"
            // work. Also doubles as an AEC probe — if transcripts come back
            // with the bot's words, mic is leaking into input.
            'transcription': {'model': 'whisper-1'},
          },
          'output': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            'voice': voice,
          },
        },
      },
    });
  }

  void _handleDone() {
    // ignore: avoid_print
    print('[realtime] ws closed');
    if (_open) {
      // Unsolicited drop — caller still wants the session up. Schedule
      // a reconnect; the status flip to `closed` is suppressed so the
      // UI doesn't blink "Disconnected" between attempts.
      _scheduleReconnect();
    } else {
      _status.add(RealtimeStatus.closed);
    }
  }

  void _scheduleReconnect() {
    if (!_open) return;
    if (_reconnectTimer != null) return; // already pending
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      // ignore: avoid_print
      print('[realtime] giving up after $_reconnectAttempt reconnect attempts');
      _status.add(RealtimeStatus.error);
      return;
    }
    // 1, 2, 4, 8, 16, 30, 30, 30 …
    final raw = 1 << _reconnectAttempt;
    final delaySec = raw > 30 ? 30 : raw;
    _reconnectAttempt++;
    // ignore: avoid_print
    print('[realtime] reconnect attempt $_reconnectAttempt in ${delaySec}s');
    // Tear down the dead WS before the next dial — leaving the old
    // _wsSub bound would route the next failure back through this same
    // path while we're already mid-retry.
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    _status.add(RealtimeStatus.connecting);
    _reconnectTimer = Timer(Duration(seconds: delaySec), _reconnect);
  }

  Future<void> _reconnect() async {
    _reconnectTimer = null;
    if (!_open) return;
    try {
      await _connectAndConfigure();
      // NOTE: do NOT reset `_reconnectAttempt` here. `_connectAndConfigure`
      // only awaits the TCP dial — the server can still close the WS
      // immediately afterwards with an event-level error (e.g. when the
      // beta API was deprecated, every dial succeeded then got 4000-closed
      // a beat later). Resetting on TCP-success masked that as an infinite
      // `connecting` loop. The reset now lives in `_handleMessage` on the
      // first inbound event, which proves the server actually accepted us.
      _status.add(RealtimeStatus.open);
    } catch (e) {
      // ignore: avoid_print
      print('[realtime] reconnect failed: $e');
      _ws = null;
      await _wsSub?.cancel();
      _wsSub = null;
      _scheduleReconnect();
    }
  }

  /// When true, mic capture keeps running natively (VP-IO needs it for
  /// echo cancellation reference) but the encoded bytes are NOT
  /// forwarded to OpenAI. The agent stays "deaf" until unmuted.
  bool muted = false;

  /// Live mirrors of voice + system prompt so `applySettings()` can
  /// short-circuit when the value hasn't actually changed (OpenAI
  /// charges a round-trip for every `session.update`).
  String _liveSystemPrompt = '';
  String _liveVoice = '';

  /// Hot-apply the system prompt to the in-flight session via
  /// `session.update { instructions: … }`. Takes effect on the NEXT
  /// agent turn. Returns true if an update was actually sent (the
  /// caller can use this to surface a toast). Safe to call when no
  /// session is open — it just no-ops and returns false.
  ///
  /// IMPORTANT: this method DOES NOT change voice. OpenAI Realtime
  /// locks the session's voice after the model has emitted any audio
  /// — `session.update { voice: … }` mid-call is silently ignored on
  /// the server. To switch voice live, end the WebSocket and start a
  /// new session (see `BithumanRealtimeSession`'s constructor in
  /// main.dart's `_toggleSession`).
  bool applySettings({String? systemPrompt}) {
    if (!_open || _ws == null) return false;
    if (systemPrompt == null || systemPrompt == _liveSystemPrompt) return false;
    _liveSystemPrompt = systemPrompt;
    _send({
      'type': 'session.update',
      'session': {'instructions': systemPrompt},
    });
    // ignore: avoid_print
    print('[realtime] session.update instructions (${systemPrompt.length} chars)');
    return true;
  }

  void _sendMicBytes(Uint8List pcm24kPcm16le) {
    if (!_open || _ws == null || pcm24kPcm16le.isEmpty) return;
    // Compute peak/32768 for the "mic is hot" UI pulse. Cannot use
    // Int16List.view here — Flutter's EventChannel may hand back a
    // Uint8List whose offsetInBytes is odd, which fails the
    // BYTES_PER_ELEMENT alignment check and throws RangeError. Decode
    // little-endian Int16 pairs manually instead; no alignment
    // requirement and the throw was previously taking down _sendMicBytes
    // BEFORE the WS send, so OpenAI was getting zero audio.
    int peak = 0;
    final n = pcm24kPcm16le.length & ~1; // round down to even
    for (int i = 0; i < n; i += 16) {
      final lo = pcm24kPcm16le[i];
      final hi = pcm24kPcm16le[i + 1];
      var s = (hi << 8) | lo;
      if ((s & 0x8000) != 0) s -= 0x10000;
      final v = s < 0 ? -s : s;
      if (v > peak) peak = v;
    }
    _micLevel.add(peak / 32768.0);
    if (muted) return;
    _send({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(pcm24kPcm16le),
    });
  }

  /// Mark the end of the user's turn explicitly (when server VAD is off).
  void commitInputAudio() {
    _send({'type': 'input_audio_buffer.commit'});
    _send({'type': 'response.create'});
  }

  Future<void> stop() async {
    if (!_open) return;
    _open = false;
    // Cancel any pending reconnect — must come BEFORE clearing _open's
    // effects so a timer firing mid-stop sees `!_open` and bails. The
    // guard inside `_reconnect()` already double-checks this.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    // Drop any post-disconnect audio.delta that's still in flight on
    // the WS read buffer — without this they'd push lipsync into the
    // avatar even after we've torn the session down.
    _droppingCancelledAudio = true;
    // Wipe the lipsync queue + stop the speaker player IMMEDIATELY.
    // Without this, the avatar keeps animating the agent's last
    // buffered audio for ~1-2 s after the user hangs up.
    try { await avatar.interrupt(); } catch (_) {}
    await _micSub?.cancel();
    _micSub = null;
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    try { await avatar.audioStop(); } catch (_) {}
    _status.add(RealtimeStatus.closed);
  }

  // -------- internals --------

  void _send(Map<String, dynamic> evt) {
    final ws = _ws;
    if (ws == null) return;
    ws.sink.add(jsonEncode(evt));
  }

  Future<void> _handleMessage(dynamic raw) async {
    if (raw is! String) return;
    final evt = jsonDecode(raw) as Map<String, dynamic>;
    final type = evt['type'] as String?;
    // Any inbound event proves the server accepted the handshake — it's
    // now safe to reset the reconnect backoff. Doing this here (not in
    // `_reconnect`) catches the case where the dial succeeds but the
    // server kills the WS right after with an event-level error.
    if (!_serverAcked) {
      _serverAcked = true;
      _reconnectAttempt = 0;
    }
    switch (type) {
      case 'response.output_audio.delta':
        if (_droppingCancelledAudio) {
          // Tail-end of a response we already cancelled — OpenAI had
          // these chunks in flight when speech_started fired. Drop
          // them or the lipsync keeps animating after the speaker
          // went silent.
          break;
        }
        final b64 = evt['delta'] as String?;
        if (b64 == null) return;
        final pcm24kBytes = base64Decode(b64);
        // Cheap peak for the "agent speaking" UI pulse. Same Int16List
        // alignment trap as the mic path — decode pairs of bytes
        // manually so an odd offsetInBytes never crashes us.
        int bpeak = 0;
        final bn = pcm24kBytes.length & ~1;
        for (int i = 0; i < bn; i += 32) {
          final lo = pcm24kBytes[i];
          final hi = pcm24kBytes[i + 1];
          var s = (hi << 8) | lo;
          if ((s & 0x8000) != 0) s -= 0x10000;
          final v = s < 0 ? -s : s;
          if (v > bpeak) bpeak = v;
        }
        _botLevel.add(bpeak / 32768.0);
        // Single call drives BOTH the speaker (VP-IO player node) AND
        // the avatar's lipsync queue from the same chunk in the same
        // instant. A/V cannot drift; VP-IO's AEC means the speaker
        // output never feeds back into the mic.
        await avatar.playSpeakerPCM(pcm24kBytes);
        break;
      case 'response.created':
        // OpenAI is starting a NEW response — any post-barge backlog
        // is behind us; resume forwarding audio.delta normally.
        _droppingCancelledAudio = false;
        _haveActiveResponse = true;
        break;
      case 'response.cancelled':
        _haveActiveResponse = false;
        break;
      case 'response.output_audio_transcript.delta':
        final delta = evt['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          _botTranscript.add(delta);
        }
        break;
      case 'conversation.item.input_audio_transcription.completed':
        final t = evt['transcript'] as String?;
        if (t != null && t.isNotEmpty) _userTranscript.add(t);
        break;
      case 'response.done':
        _haveActiveResponse = false;
        _status.add(RealtimeStatus.responseDone);
        break;
      case 'input_audio_buffer.speech_started':
        // Barge-in: fire the moment server-VAD detects the user has
        // started talking. Three parallel actions:
        //   1. response.cancel — tell OpenAI to stop generating the
        //      current response.
        //   2. avatar.interrupt() — stop the local speaker + lipsync
        //      so the agent doesn't keep talking from already-buffered
        //      response.audio.delta chunks.
        //   3. _droppingCancelledAudio — drop further deltas for the
        //      cancelled response.
        // On Android this depends on USAGE_VOICE_COMMUNICATION audio
        // being routed through the speakerphone (MODE_IN_COMMUNICATION
        // + setSpeakerphoneOn=true) so the platform AcousticEchoCanceler
        // can effectively suppress the agent's voice from leaking
        // back through the mic. Without speakerphone routing the
        // earpiece-mic path has weak AEC and the server fires false
        // speech_started events on agent-self-leak.
        if (_haveActiveResponse) {
          _send({'type': 'response.cancel'});
        }
        _droppingCancelledAudio = true;
        await avatar.interrupt();
        _status.add(RealtimeStatus.userSpeaking);
        break;
      case 'input_audio_buffer.speech_stopped':
        _status.add(RealtimeStatus.userStopped);
        break;
      case 'error':
        final err = evt['error'] as Map<String, dynamic>?;
        final code = (err?['code'] as String?) ?? '';
        final msg = (err?['message'] as String?) ?? '';
        // Soft / non-fatal server errors — log but DO NOT flip the UI
        // to "Connection error". Examples:
        //   - cancellation_failed: we tried to cancel when nothing
        //     was in flight (also gated upstream, but defense in depth)
        //   - input_audio_buffer_commit_empty: server VAD didn't hear
        //     any speech in the buffer
        //   - rate_limit / similar: visible elsewhere, not a "down" state
        final soft = code.contains('cancellation_failed') ||
            code.contains('input_audio_buffer_commit_empty') ||
            msg.contains('no active response');
        // ignore: avoid_print
        print('[realtime] server ${soft ? "warning" : "error"}: '
            '${code.isEmpty ? msg : "$code — $msg"}');
        if (!soft) {
          _status.add(RealtimeStatus.error);
        }
        break;
      // Other event types (session.created, session.updated, response.created,
      // response.audio_transcript.delta, …) are informational — ignore for v0.2.
      default:
        break;
    }
  }

  void _handleError(Object e) {
    // ignore: avoid_print
    print('[realtime] ws error: $e');
    if (_open) {
      // Treat as a drop and reconnect — don't flip to .error yet, the
      // backoff schedule will surface .error itself if all retries
      // exhaust. Spurious .error here would make the UI strobe.
      _scheduleReconnect();
    } else {
      _status.add(RealtimeStatus.error);
    }
  }

}

enum RealtimeStatus {
  connecting,
  open,
  userSpeaking,
  userStopped,
  responseDone,
  closed,
  error,
}
