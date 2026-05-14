// example_webrtc_android — Android-first demo of the WebRTC-driven
// bithuman avatar. The plugin runs in render-only mode (load +
// Texture); flutter_webrtc owns mic + speaker + AEC via libwebrtc's
// native pipeline. Phase 1 ships the avatar at idle motion while
// the WebRTC voice loop runs; Phase 2 will hook the lipsync feed by
// tapping the remote audio track from the plugin's Kotlin side.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';

import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dev_config.dart';
import 'openai_webrtc_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await WebRTC.initialize();
  runApp(const _App());
}

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'bithuman_avatar · WebRTC',
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
  BithumanAvatar? _avatar;
  String? _missingImxPath;
  String _status = '';

  OpenAIWebRTCSession? _session;
  StreamSubscription<WebRTCStatus>? _sessionSub;
  StreamSubscription<String>? _transcriptSub;
  StreamSubscription<void>? _interruptSub;
  StreamSubscription<MediaStreamTrack>? _remoteAudioSub;
  WebRTCStatus _rtStatus = WebRTCStatus.idle;
  String _liveTranscript = '';
  String _openaiKey = DevConfig.openaiApiKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final cfg = await DevConfig.readConfigFile();
      if (mounted) {
        setState(() {
          _openaiKey = (cfg['openai_api_key'] as String?) ?? _openaiKey;
        });
      }
      await _loadAvatar();
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    _transcriptSub?.cancel();
    _interruptSub?.cancel();
    _remoteAudioSub?.cancel();
    _session?.dispose();
    _avatar?.dispose();
    super.dispose();
  }

  Future<void> _loadAvatar() async {
    try {
      final imxPath = await DevConfig.resolveImxPath();
      if (imxPath == null) {
        final dropPath = await DevConfig.defaultImxPath();
        if (mounted) setState(() => _missingImxPath = dropPath);
        return;
      }
      setState(() => _status = 'Loading avatar…');
      final loaded = await BithumanAvatar.load(imxPath);
      if (!mounted) return;
      setState(() {
        _avatar = loaded;
        _status = '';
      });
      // NOTE: we do NOT call _avatar.audioStart() here. The plugin's
      // native RealtimeAudioIO is intentionally bypassed on Android
      // — flutter_webrtc owns audio. The avatar's compose loop keeps
      // ticking at 25 fps with silence input → idle motion.
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    }
  }

  Future<void> _toggleSession() async {
    final avatar = _avatar;
    if (avatar == null) return;
    final existing = _session;
    if (existing != null) {
      // Tear down: detach lipsync first so any in-flight PCM stops
      // landing in the avatar's queue, then close peer connection.
      await avatar.detachWebrtcRemoteAudio();
      await existing.stop();
      await _sessionSub?.cancel();
      _sessionSub = null;
      await _transcriptSub?.cancel();
      _transcriptSub = null;
      await _interruptSub?.cancel();
      _interruptSub = null;
      await _remoteAudioSub?.cancel();
      _remoteAudioSub = null;
      await existing.dispose();
      if (mounted) {
        setState(() {
          _session = null;
          _rtStatus = WebRTCStatus.idle;
          _liveTranscript = '';
        });
      }
      return;
    }
    if (_openaiKey.isEmpty) {
      _showSnack('Set openai_api_key in config.json or pass '
          '--dart-define=OPENAI_API_KEY to start talking.');
      return;
    }
    final s = OpenAIWebRTCSession(
      apiKey: _openaiKey,
      model: DevConfig.defaultModel,
      voice: DevConfig.defaultVoice,
      systemPrompt: DevConfig.defaultSystemPrompt,
    );
    _sessionSub = s.statusStream.listen((rt) {
      if (mounted) {
        setState(() {
          _rtStatus = rt;
          if (rt == WebRTCStatus.responseDone) _liveTranscript = '';
        });
      }
    });
    _transcriptSub = s.botTranscriptStream.listen((delta) {
      if (mounted) setState(() => _liveTranscript += delta);
    });
    // Phase 2 wiring: as soon as libwebrtc attaches the REMOTE audio
    // track (OpenAI's bot voice), hand the track id to the bithuman
    // plugin so its lipsync queue is fed from the exact PCM the
    // speaker is playing. NOT the mic.
    _remoteAudioSub = s.remoteAudioReadyStream.listen((track) async {
      try {
        await avatar.attachWebrtcRemoteAudio(track.id ?? '');
      } catch (e) {
        // ignore: avoid_print
        print('[main] attachWebrtcRemoteAudio failed: $e');
      }
    });
    // On a barge-in / cancelled response, OpenAI clears its outbound
    // audio mid-stream. The avatar must also flush its lipsync queue
    // — otherwise the mouth keeps moving for audio the user never
    // hears (phantom talk).
    _interruptSub = s.interruptStream.listen((_) async {
      try {
        await avatar.interrupt();
      } catch (e) {
        // ignore: avoid_print
        print('[main] avatar.interrupt failed: $e');
      }
    });
    try {
      await s.start();
      if (!mounted) {
        await s.dispose();
        return;
      }
      setState(() => _session = s);
    } catch (e) {
      _showSnack('Connect failed: $e');
      await s.dispose();
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext c) {
    final missingPath = _missingImxPath;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_avatar != null)
            // Native texture renders the avatar at its source aspect
            // (1280×722 ≈ 1.77:1, landscape). On a portrait phone we
            // want it filling the height and cropping the sides, not
            // stretching to the screen rect → BoxFit.cover on a
            // fixed-aspect SizedBox.
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 1280,
                height: 722,
                child: Texture(textureId: _avatar!.textureId),
              ),
            )
          else if (missingPath != null)
            _FirstRunSheet(dropPath: missingPath, onRetry: _loadAvatar)
          else
            Center(
              child: Text(
                _status.isEmpty ? 'Initialising…' : _status,
                style: const TextStyle(color: Colors.white70),
              ),
            ),

          // Top-left status pill so the architectural state is
          // visible at a glance.
          Positioned(
            left: 16,
            top: 40,
            child:
                _StatusPill(status: _rtStatus, hasSession: _session != null),
          ),

          // Bottom transcript band (when active) + mic toggle.
          if (_avatar != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Column(
                children: [
                  if (_liveTranscript.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _liveTranscript,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            height: 1.35),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _MicButton(
                    isOn: _session != null,
                    onPressed: _toggleSession,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status, required this.hasSession});

  final WebRTCStatus status;
  final bool hasSession;

  @override
  Widget build(BuildContext c) {
    final (label, color) = switch (status) {
      WebRTCStatus.idle =>
        (hasSession ? 'starting…' : 'idle (tap mic)', Colors.white54),
      WebRTCStatus.connecting => ('connecting', Colors.amber),
      WebRTCStatus.open => ('open', Colors.greenAccent),
      WebRTCStatus.userSpeaking => ('you are talking', Colors.lightBlueAccent),
      WebRTCStatus.userStopped => ('agent thinking', Colors.greenAccent),
      WebRTCStatus.responseDone => ('replied', Colors.greenAccent),
      WebRTCStatus.closed => ('closed', Colors.white38),
      WebRTCStatus.error => ('error', Colors.redAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        'WebRTC · $label',
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.isOn, required this.onPressed});

  final bool isOn;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext c) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: isOn ? Colors.redAccent : Colors.white,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
                color: Colors.black54, blurRadius: 18, offset: Offset(0, 4)),
          ],
        ),
        child: Icon(
          isOn ? Icons.call_end_rounded : Icons.mic_rounded,
          size: 32,
          color: isOn ? Colors.white : Colors.black,
        ),
      ),
    );
  }
}

class _FirstRunSheet extends StatelessWidget {
  const _FirstRunSheet({required this.dropPath, required this.onRetry});

  final String dropPath;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext c) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Drop an .imx avatar file here:',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SelectableText(
              dropPath,
              style: const TextStyle(
                  color: Colors.white70, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
