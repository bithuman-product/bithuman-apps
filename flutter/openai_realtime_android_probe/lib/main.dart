// openai_realtime_android_probe — minimal proof that an OpenAI
// Realtime voice loop works flawlessly on Android over a direct
// WebRTC peer connection. Single Dart file, no plugins beyond
// flutter_webrtc. No avatar, no bithuman, no platform glue.
//
// Architecture:
//   1. createPeerConnection({iceServers: stun-only}) — direct peer to
//      OpenAI; no LiveKit server, no SFU.
//   2. getUserMedia({audio: true, echoCancellation: true,
//                    noiseSuppression: true, autoGainControl: true})
//      — libwebrtc captures mic + applies the platform's hardware AEC
//      via the Android WebRtcAudio module's built-in NS/AGC/AEC
//      effects (same as Chrome/Meet on Android).
//   3. addTrack(micTrack) — publish mic to peer.
//   4. createDataChannel("oai-events") — for session.update + response
//      events (transcripts, function calls, server VAD events).
//   5. createOffer + setLocalDescription → POST offer.sdp to
//      https://api.openai.com/v1/realtime/calls?model=… with the API
//      key in the Authorization header → setRemoteDescription(answer).
//   6. onTrack fires for the remote audio track — libwebrtc renders it
//      directly to the Android speaker via the same WebRtcAudio module
//      that's capturing the mic, so AEC has a synchronised reference.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, HttpClientResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// API key is baked at build time via `--dart-define=OPENAI_API_KEY=…`.
// Avoid runtime string literals so accidental screen-shares don't leak
// the key.
const _kOpenAIKey = String.fromEnvironment('OPENAI_API_KEY');
const _kModel = String.fromEnvironment(
    'REALTIME_MODEL', defaultValue: 'gpt-realtime');
const _kVoice =
    String.fromEnvironment('VOICE', defaultValue: 'ash');
const _kSystemPrompt = String.fromEnvironment(
    'SYSTEM_PROMPT',
    defaultValue: 'You are a friendly assistant. Keep replies short and warm.');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WebRTC.initialize();
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'OpenAI Realtime · WebRTC probe',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF22C8FF),
              brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCDataChannel? _dc;
  String _status = 'idle';
  final List<String> _events = [];
  final ScrollController _scroll = ScrollController();
  String _liveTranscript = '';

  bool get _connected => _pc != null;

  void _log(String msg) {
    // ignore: avoid_print
    print('[probe] $msg');
    if (mounted) {
      setState(() {
        _events.add(msg);
        if (_events.length > 200) _events.removeAt(0);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _start() async {
    if (_kOpenAIKey.isEmpty) {
      _log('ERROR: build with --dart-define=OPENAI_API_KEY=...');
      return;
    }
    if (_connected) return;
    setState(() => _status = 'connecting');
    try {
      _log('createPeerConnection');
      final pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
        'sdpSemantics': 'unified-plan',
      });
      _pc = pc;
      pc.onConnectionState = (s) => _log('pc=$s');
      pc.onIceConnectionState = (s) => _log('ice=$s');
      pc.onTrack = (event) {
        if (event.track.kind == 'audio') {
          _log('remote audio attached: ${event.track.id}');
          // On Android flutter_webrtc auto-renders the remote audio
          // track through libwebrtc's WebRtcAudio module — no
          // explicit audio renderer widget needed. The same module
          // that's capturing the mic also drives playback, which is
          // what lets AEC use the rendered signal as the far-end
          // reference.
        }
      };

      _log('getUserMedia (audio)');
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

      _log('createDataChannel(oai-events)');
      final dc = await pc.createDataChannel(
          'oai-events', RTCDataChannelInit()..ordered = true);
      _dc = dc;
      dc.onDataChannelState = (s) {
        _log('dc=$s');
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          _sendSessionUpdate();
        }
      };
      dc.onMessage = _onDataMessage;

      _log('createOffer + setLocalDescription');
      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);

      _log('POST sdp → api.openai.com/v1/realtime/calls?model=$_kModel');
      final uri = Uri.parse(
          'https://api.openai.com/v1/realtime/calls?model=$_kModel');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Authorization', 'Bearer $_kOpenAIKey');
        req.headers.set('Content-Type', 'application/sdp');
        req.add(utf8.encode(offer.sdp!));
        final HttpClientResponse res = await req.close();
        if (res.statusCode != 200 && res.statusCode != 201) {
          final body = await res.transform(utf8.decoder).join();
          throw StateError(
              'OpenAI HTTP ${res.statusCode}: $body');
        }
        final answerSdp = await res.transform(utf8.decoder).join();
        await pc.setRemoteDescription(
            RTCSessionDescription(answerSdp, 'answer'));
        _log('answer applied — peer connection live');
      } finally {
        client.close();
      }
      setState(() => _status = 'open');
    } catch (e) {
      _log('start failed: $e');
      setState(() => _status = 'error');
      await _stop();
    }
  }

  Future<void> _stop() async {
    setState(() => _status = 'closing');
    try { await _dc?.close(); } catch (_) {}
    _dc = null;
    try {
      _localStream?.getTracks().forEach((t) => t.stop());
      await _localStream?.dispose();
    } catch (_) {}
    _localStream = null;
    try { await _pc?.close(); } catch (_) {}
    _pc = null;
    if (mounted) setState(() => _status = 'idle');
  }

  void _sendSessionUpdate() {
    _send({
      'type': 'session.update',
      'session': {
        'modalities': ['audio', 'text'],
        'instructions': _kSystemPrompt,
        'voice': _kVoice,
        'turn_detection': {
          // Higher threshold means louder speech is required before
          // server VAD fires speech_started, so brief room noise /
          // throat clears don't trigger an interruption. Default
          // is 0.5; 0.8 needs noticeably more sustained energy.
          'type': 'server_vad',
          'threshold': 0.8,
          // Padding included BEFORE detected speech so we don't clip
          // the user's first syllable.
          'prefix_padding_ms': 500,
          // Quiet duration that closes a user turn. 800 ms feels
          // natural — pauses inside a sentence won't end the turn
          // prematurely.
          'silence_duration_ms': 800,
        },
      },
    });
    _log('→ session.update (threshold=0.8, silence=800ms)');
  }

  void _send(Map<String, dynamic> evt) {
    final dc = _dc;
    if (dc == null) return;
    dc.send(RTCDataChannelMessage(jsonEncode(evt)));
  }

  void _onDataMessage(RTCDataChannelMessage msg) {
    if (msg.isBinary) return;
    try {
      final evt = jsonDecode(msg.text) as Map<String, dynamic>;
      final type = evt['type'] as String?;
      switch (type) {
        case 'response.audio_transcript.delta':
          final delta = evt['delta'] as String? ?? '';
          if (delta.isNotEmpty) {
            setState(() {
              _liveTranscript += delta;
            });
          }
          break;
        case 'response.done':
          _log('← response.done');
          setState(() => _liveTranscript = '');
          break;
        case 'input_audio_buffer.speech_started':
          _log('← speech_started (user)');
          break;
        case 'input_audio_buffer.speech_stopped':
          _log('← speech_stopped (user)');
          break;
        case 'session.created':
        case 'session.updated':
        case 'response.created':
          _log('← $type');
          break;
        case 'error':
          _log('← error: ${evt['error']}');
          break;
        // Quieter events (audio.delta is over RTP not data channel,
        // conversation.item.* fire often, etc.) — skip the log to
        // keep the panel readable.
        default:
          break;
      }
    } catch (e) {
      _log('dc parse: $e');
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                      color: switch (_status) {
                        'open' => Colors.greenAccent,
                        'connecting' || 'closing' => Colors.amber,
                        'error' => Colors.redAccent,
                        _ => Colors.white38,
                      },
                      shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text('OpenAI Realtime · WebRTC · $_status',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14)),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(minHeight: 80),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  _liveTranscript.isEmpty
                      ? '(agent transcript will stream here)'
                      : _liveTranscript,
                  style: TextStyle(
                      color: _liveTranscript.isEmpty
                          ? Colors.white38
                          : Colors.white,
                      fontSize: 16,
                      height: 1.4),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _events.length,
                    itemBuilder: (_, i) => Text(
                      _events[i],
                      style: const TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _connected ? _stop : _start,
                icon: Icon(_connected
                    ? Icons.call_end
                    : Icons.mic),
                label: Text(_connected ? 'Hang up' : 'Talk'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: _connected
                      ? Colors.redAccent
                      : Colors.lightBlueAccent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
