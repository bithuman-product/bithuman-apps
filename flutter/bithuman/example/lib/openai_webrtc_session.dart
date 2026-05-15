// OpenAI Realtime over WebRTC — Dart client. Verbatim port of the
// proven openai_realtime_android_probe wiring. libwebrtc owns mic +
// speaker + AEC; this file is just the peer-connection lifecycle +
// SDP exchange + data-channel event handling.
//
// Phase 1 of the Android avatar port: NO lipsync feed yet. Phase 2
// will attach a native AudioTrackSink in the bithuman plugin
// that taps this peer connection's remote audio for the avatar's
// pushAudio path.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpClientResponse;

import 'package:flutter_webrtc/flutter_webrtc.dart';

enum WebRTCStatus {
  idle,
  connecting,
  open,
  userSpeaking,
  userStopped,
  responseDone,
  closed,
  error,
}

class OpenAIWebRTCSession {
  OpenAIWebRTCSession({
    required this.apiKey,
    required this.model,
    required this.voice,
    required this.systemPrompt,
  });

  final String apiKey;
  final String model;
  final String voice;
  final String systemPrompt;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCDataChannel? _dc;
  MediaStreamTrack? _remoteAudioTrack;

  final _status = StreamController<WebRTCStatus>.broadcast();
  Stream<WebRTCStatus> get statusStream => _status.stream;

  final _transcript = StreamController<String>.broadcast();
  Stream<String> get botTranscriptStream => _transcript.stream;

  /// Fires whenever OpenAI cancels its in-flight audio (user
  /// barge-in, response.cancelled, etc.). Subscribe and call
  /// `avatar.interrupt()` so the lipsync queue is wiped — otherwise
  /// the mouth keeps articulating audio the user never hears.
  final _interrupt = StreamController<void>.broadcast();
  Stream<void> get interruptStream => _interrupt.stream;

  /// Fires when libwebrtc has attached the remote audio track and
  /// the data channel has reached the `session.updated` state, i.e.
  /// when it's safe to call `attachWebrtcRemoteAudio` on the avatar.
  final _remoteReady = StreamController<MediaStreamTrack>.broadcast();
  Stream<MediaStreamTrack> get remoteAudioReadyStream =>
      _remoteReady.stream;

  /// The remote audio track libwebrtc just attached. Phase 2 reads
  /// this from the Dart side and forwards its id to the bithuman
  /// plugin so the plugin's Kotlin code can attach an AudioTrackSink.
  MediaStreamTrack? get remoteAudioTrack => _remoteAudioTrack;

  bool _open = false;
  // True between `output_audio_buffer.started` and
  // `output_audio_buffer.stopped`. Kept ONLY as a diagnostic flag
  // for the `[AEC-PROBE]` line so we can correlate user-mic
  // transcripts with whether the bot was audibly playing at the
  // moment OpenAI transcribed our uplink. The mic is never muted —
  // full duplex always. AEC has to do its job.
  bool _agentAudioOut = false;

  Future<void> start() async {
    if (_open) return;
    _open = true;
    _status.add(WebRTCStatus.connecting);
    try {
      await _setUpPeerConnection();
      await _negotiateWithOpenAI();
      _status.add(WebRTCStatus.open);
    } catch (e) {
      // ignore: avoid_print
      print('[webrtc] start failed: $e');
      _status.add(WebRTCStatus.error);
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_open && _pc == null) return;
    _open = false;
    try { await _dc?.close(); } catch (_) {}
    _dc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try { await _pc?.close(); } catch (_) {}
    _pc = null;
    _remoteAudioTrack = null;
    _status.add(WebRTCStatus.closed);
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
    await _transcript.close();
    await _interrupt.close();
    await _remoteReady.close();
  }

  Future<void> _setUpPeerConnection() async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onConnectionState = (state) {
      // ignore: avoid_print
      print('[webrtc] pc state: $state');
    };
    pc.onTrack = (event) {
      if (event.track.kind == 'audio') {
        _remoteAudioTrack = event.track;
        // ignore: avoid_print
        print('[webrtc] remote audio attached: ${event.track.id}');
        // libwebrtc auto-renders the remote audio through the Android
        // WebRtcAudio module. Surface the track so the avatar plugin
        // can `attachWebrtcRemoteAudio(track.id)` and feed lipsync
        // from the EXACT same PCM the speaker is playing.
        if (!_remoteReady.isClosed) _remoteReady.add(event.track);
      }
    };

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': false,
    });
    for (final track in _localStream!.getAudioTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    // NOTE: deliberately NOT calling Helper.setSpeakerphoneOn here.
    // Doing it AFTER getUserMedia desyncs libwebrtc's AEC reference
    // path on Android — the APM was initialized against one routing
    // and then the audio mode flipped under it. The validated probe
    // runs on whatever routing the system inherits (Z Fold 5 sticks
    // on speakerphone once another VOIP-mode app set it), and AEC
    // works there. We rely on that here too.

    final dc = await pc.createDataChannel(
        'oai-events', RTCDataChannelInit()..ordered = true);
    _dc = dc;
    dc.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _sendSessionUpdate();
      }
    };
    dc.onMessage = _handleDataMessage;
  }

  Future<void> _negotiateWithOpenAI() async {
    final pc = _pc!;
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    final uri =
        Uri.parse('https://api.openai.com/v1/realtime/calls?model=$model');
    final client = HttpClient();
    try {
      final req = await client.postUrl(uri);
      req.headers.set('Authorization', 'Bearer $apiKey');
      req.headers.set('Content-Type', 'application/sdp');
      req.add(utf8.encode(offer.sdp!));
      final HttpClientResponse res = await req.close();
      if (res.statusCode != 200 && res.statusCode != 201) {
        final body = await res.transform(utf8.decoder).join();
        throw StateError(
            'OpenAI Realtime SDP exchange HTTP ${res.statusCode}: $body');
      }
      final answerSdp = await res.transform(utf8.decoder).join();
      await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
    } finally {
      client.close();
    }
  }

  void _sendSessionUpdate() {
    // New (2026-Q2) OpenAI Realtime session schema. Everything
    // audio-related moved under `session.audio.{input,output}.*`,
    // and `modalities` was renamed to `output_modalities`. Sending
    // the old shape silently invalidates the entire session.update
    // — the server keeps a fully-default config and you only find
    // out because `session.created` echoes back the wrong values
    // and a stray `error` event mentions a single unknown
    // parameter. The default config has threshold=0.5/silence=200,
    // which is hair-trigger and turns any speaker→mic residual
    // into a self-talk loop.
    _sendEvent({
      'type': 'session.update',
      'session': {
        'type': 'realtime',
        'output_modalities': ['audio'],
        'instructions': systemPrompt,
        'audio': {
          'input': {
            'format': {'type': 'audio/pcm', 'rate': 24000},
            // Server-side noise reduction. `far_field` is the
            // hands-free / speakerphone profile — it strips the
            // exact kind of AEC residual + AGC pumping that was
            // tripping server_vad on empty audio.
            'noise_reduction': {'type': 'far_field'},
            'transcription': {
              'model': 'gpt-4o-mini-transcribe',
            },
            // semantic_vad uses a learned speech model rather than
            // RMS energy. Residual noise + low-volume artifacts no
            // longer fire false speech_started events. eagerness=low
            // = only confident, sustained speech commits a turn,
            // preserving barge-in for real user input.
            'turn_detection': {
              'type': 'semantic_vad',
              'eagerness': 'low',
              'create_response': true,
              'interrupt_response': true,
            },
          },
          'output': {
            'voice': voice,
          },
        },
      },
    });
  }

  void _sendEvent(Map<String, dynamic> evt) {
    final dc = _dc;
    if (dc == null) return;
    dc.send(RTCDataChannelMessage(jsonEncode(evt)));
  }

  void _handleDataMessage(RTCDataChannelMessage msg) {
    if (msg.isBinary) return;
    try {
      final evt = jsonDecode(msg.text) as Map<String, dynamic>;
      final type = evt['type'] as String?;
      // Log every event type so we can see the full server-side flow
      // (especially response.* events that confirm the bot is
      // actually producing audio).
      if (type != null &&
          type != 'response.audio.delta' &&
          type != 'response.audio_transcript.delta') {
        // ignore: avoid_print
        print('[webrtc] ← $type');
      }
      switch (type) {
        // Transcript deltas — note BOTH old + new schema names so
        // this code keeps working if OpenAI flips again.
        case 'response.output_audio_transcript.delta':
        case 'response.audio_transcript.delta':
          final delta = evt['delta'] as String?;
          if (delta != null && delta.isNotEmpty) _transcript.add(delta);
          break;
        case 'response.done':
        case 'response.cancelled':
          _status.add(WebRTCStatus.responseDone);
          break;
        // The TRUE "bot is producing sound on the speaker" window —
        // tracks the WebRTC outbound buffer, not OpenAI's generation
        // state. Used only as a diagnostic flag on the AEC probe;
        // no muting happens.
        case 'output_audio_buffer.started':
          _agentAudioOut = true;
          break;
        case 'output_audio_buffer.stopped':
          _agentAudioOut = false;
          break;
        case 'output_audio_buffer.cleared':
          // User barged in / response cancelled mid-stream. We MUST
          // wipe the avatar's lipsync queue or the mouth will keep
          // animating audio the user never hears — phantom talking.
          _agentAudioOut = false;
          if (!_interrupt.isClosed) _interrupt.add(null);
          break;
        case 'response.cancelled':
          if (!_interrupt.isClosed) _interrupt.add(null);
          break;
        case 'input_audio_buffer.speech_started':
          // ignore: avoid_print
          print('[webrtc] speech_started '
              '(agentAudioOut=$_agentAudioOut)');
          _status.add(WebRTCStatus.userSpeaking);
          break;
        case 'input_audio_buffer.speech_stopped':
          _status.add(WebRTCStatus.userStopped);
          break;
        case 'session.created':
        case 'session.updated':
          // Useful to confirm what config OpenAI actually accepted.
          // ignore: avoid_print
          print('[webrtc] $type — session: ${evt['session']}');
          break;
        case 'conversation.item.input_audio_transcription.completed':
          final txt = (evt['transcript'] as String?)?.trim() ?? '';
          // ignore: avoid_print
          print('[AEC-PROBE] user-mic transcript '
              '(agentAudioOut=$_agentAudioOut): "$txt"');
          break;
        case 'conversation.item.input_audio_transcription.delta':
          final delta = (evt['delta'] as String?)?.trim() ?? '';
          if (delta.isNotEmpty) {
            // ignore: avoid_print
            print('[AEC-PROBE] (delta, agentAudioOut=$_agentAudioOut): "$delta"');
          }
          break;
        case 'conversation.item.input_audio_transcription.failed':
          // ignore: avoid_print
          print('[AEC-PROBE] transcription failed: ${evt['error']}');
          break;
        case 'error':
          // ignore: avoid_print
          print('[webrtc] error event: ${evt['error']}');
          _status.add(WebRTCStatus.error);
          break;
      }
    } catch (e) {
      // ignore: avoid_print
      print('[webrtc] dc parse: $e');
    }
  }
}
