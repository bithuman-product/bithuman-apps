// bithuman_realtime — OpenAI Realtime session wired to the bitHuman avatar.
//
// One-way audio capture (mic → OpenAI), two-way audio playback (OpenAI →
// speaker AND OpenAI → avatar.pushAudio for lip-sync), all over a single
// WebSocket to api.openai.com.
//
// Wire format (per https://platform.openai.com/docs/guides/realtime):
//   - Transport: wss://api.openai.com/v1/realtime?model=…
//   - Auth: `Authorization: Bearer <api_key>` + `OpenAI-Beta: realtime=v1`
//   - Audio: PCM16 mono @ 24 kHz, base64-encoded inside JSON events
//
// The avatar engine wants 16 kHz mono f32 PCM. We resample 24→16 kHz with
// a 3:2 polyphase decimator (simple linear interp — good enough for
// lip-sync; the visual pipeline doesn't need DSP-grade audio).
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
    this.model = 'gpt-4o-realtime-preview-2024-12-17',
    this.systemPrompt = '',
    this.voice = 'alloy',
  });

  final String apiKey;
  final BithumanAvatar avatar;
  final String model;
  final String systemPrompt;
  final String voice;

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  bool _open = false;

  final _status = StreamController<RealtimeStatus>.broadcast();
  Stream<RealtimeStatus> get statusStream => _status.stream;

  /// User-supplied mic capture handler. The example app sets this to a
  /// closure that base64-encodes 24 kHz PCM16 frames into a queue, which
  /// `sendMicChunk` then drains. Keeping the recorder out of this class
  /// lets us depend on `record` only in the example app, not the plugin
  /// (so non-mic consumers don't pay the platform-channel weight).
  void Function(Uint8List pcm24kPcm16le)? onMicCapture;

  /// Open the WebSocket and send the initial session.update.
  Future<void> start() async {
    if (_open) return;
    _open = true;
    _status.add(RealtimeStatus.connecting);
    try {
      _ws = IOWebSocketChannel.connect(
        Uri.parse('wss://api.openai.com/v1/realtime?model=$model'),
        headers: {
          'Authorization': 'Bearer $apiKey',
          'OpenAI-Beta': 'realtime=v1',
        },
      );
      _wsSub = _ws!.stream.listen(_handleMessage,
          onError: _handleError, onDone: () => _status.add(RealtimeStatus.closed));
      // Configure the session.
      _send({
        'type': 'session.update',
        'session': {
          'modalities': ['audio', 'text'],
          'instructions': systemPrompt,
          'voice': voice,
          'input_audio_format': 'pcm16',
          'output_audio_format': 'pcm16',
          'turn_detection': {
            'type': 'server_vad',
            'threshold': 0.5,
            'prefix_padding_ms': 300,
            'silence_duration_ms': 500,
          },
        },
      });
      _status.add(RealtimeStatus.open);
    } catch (e) {
      _status.add(RealtimeStatus.error);
      rethrow;
    }
  }

  /// Send a chunk of mic audio. Caller already has 24 kHz PCM16 LE bytes.
  void sendMicChunk(Uint8List pcm24kPcm16le) {
    if (!_open || _ws == null) return;
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
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
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
    switch (type) {
      case 'response.audio.delta':
        final b64 = evt['delta'] as String?;
        if (b64 == null) return;
        final pcm24kBytes = base64Decode(b64);
        // Speaker is responsibility of the caller (host app routes this
        // through audioplayers/just_audio). We also need to feed the
        // avatar engine — which wants 16 kHz mono int16. Resample 24→16.
        final pcm24kInt16 = Int16List.view(
          pcm24kBytes.buffer,
          pcm24kBytes.offsetInBytes,
          pcm24kBytes.lengthInBytes ~/ 2,
        );
        final pcm16kInt16 = _resample24to16(pcm24kInt16);
        await avatar.pushAudio(pcm16kInt16);
        // Also forward raw 24k bytes to the speaker queue for playback.
        _audioOut.add(pcm24kBytes);
        break;
      case 'response.done':
        _status.add(RealtimeStatus.responseDone);
        break;
      case 'input_audio_buffer.speech_started':
        _status.add(RealtimeStatus.userSpeaking);
        break;
      case 'input_audio_buffer.speech_stopped':
        _status.add(RealtimeStatus.userStopped);
        break;
      case 'error':
        final err = evt['error'] as Map<String, dynamic>?;
        // ignore: avoid_print
        print('[realtime] error: ${err?["message"] ?? evt}');
        _status.add(RealtimeStatus.error);
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
    _status.add(RealtimeStatus.error);
  }

  /// 24 kHz int16 PCM → 16 kHz int16 PCM via simple decimation with
  /// linear interpolation. Ratio is exactly 3:2 → for every 3 input
  /// samples, emit 2 output samples. Good enough for lip-sync visual.
  /// For higher-fidelity audio output use a proper polyphase resampler.
  final _resampleAccum = <int>[];
  Int16List _resample24to16(Int16List in24) {
    // Accumulate so we can handle chunk boundaries cleanly.
    _resampleAccum.addAll(in24);
    final out = <int>[];
    int i = 0;
    while (i + 2 < _resampleAccum.length) {
      // s_out[0] = s_in[0]
      // s_out[1] = (s_in[1] + s_in[2]) / 2
      out.add(_resampleAccum[i]);
      out.add(((_resampleAccum[i + 1] + _resampleAccum[i + 2]) / 2).round());
      i += 3;
    }
    _resampleAccum.removeRange(0, i);
    return Int16List.fromList(out);
  }

  // Speaker audio queue. Caller listens on [speakerAudioStream] and routes
  // through their player (audioplayers / just_audio).
  final _audioOut = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get speakerAudioStream => _audioOut.stream;
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
