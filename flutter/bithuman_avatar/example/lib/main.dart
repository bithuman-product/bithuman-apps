// bithuman_avatar example — full-screen avatar with OpenAI Realtime chat.
//
// Tap anywhere to swap avatars from the public bithuman.ai catalog.
// Hold the mic button to talk; release to let the assistant respond.
// Audio flows: mic → 24 kHz PCM16 → WebSocket → OpenAI Realtime →
// response.audio.delta → speaker + 16 kHz lip-sync to the avatar.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:bithuman_avatar/bithuman_realtime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

// Provide the OpenAI key via:  flutter run --dart-define OPENAI_API_KEY=sk-...
const _openaiApiKey = String.fromEnvironment('OPENAI_API_KEY');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BithumanAvatarApp());
}

class BithumanAvatarApp extends StatelessWidget {
  const BithumanAvatarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bithuman',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF111111),
        useMaterial3: true,
      ),
      home: const AvatarScreen(),
    );
  }
}

class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});
  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  BithumanAvatar? _avatar;
  BithumanAgent? _currentAgent;
  BithumanRealtimeSession? _session;
  StreamSubscription<RealtimeStatus>? _sessionSub;
  StreamSubscription<Uint8List>? _speakerSub;
  final _player = AudioPlayer();
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;

  String? _engineVersion;
  String _status = 'tap to pick an avatar';
  RealtimeStatus _rtStatus = RealtimeStatus.closed;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    nativeEngineVersion()
        .then((v) => mounted ? setState(() => _engineVersion = v ?? '(stub)') : null);
  }

  Future<void> _pickAvatar() async {
    if (_busy) return;
    final picked = await showModalBottomSheet<BithumanAgent>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (_) => const _AgentPicker(),
    );
    if (picked == null) return;
    setState(() {
      _busy = true;
      _status = 'downloading ${picked.name}…';
      _currentAgent = picked;
    });
    try {
      final cacheDir = (await getTemporaryDirectory()).path;
      final imxPath = await downloadAgentImx(picked, cacheDir);
      if (!mounted) return;
      setState(() => _status = 'loading ${picked.name}…');
      // Stop the previous session/avatar.
      await _stopSession();
      await _avatar?.dispose();
      final loaded = await BithumanAvatar.load(imxPath);
      if (!mounted) return;
      setState(() {
        _avatar = loaded;
        _status = picked.name;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'failed: $e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _toggleSession() async {
    if (_avatar == null || _currentAgent == null) return;
    if (_session != null) {
      await _stopSession();
      return;
    }
    if (_openaiApiKey.isEmpty) {
      _showSnack(
          'Set OPENAI_API_KEY via --dart-define to enable Realtime chat.');
      return;
    }
    if (!await _recorder.hasPermission()) {
      _showSnack('Microphone permission denied');
      return;
    }
    final s = BithumanRealtimeSession(
      apiKey: _openaiApiKey,
      avatar: _avatar!,
      systemPrompt: _currentAgent!.systemPrompt,
    );
    _sessionSub = s.statusStream.listen((rtStatus) {
      if (mounted) setState(() => _rtStatus = rtStatus);
    });
    // Forward synthesized speaker audio to the AudioPlayer. The OpenAI
    // stream is raw 24 kHz PCM16 — we accumulate one assistant turn into
    // a WAV-wrapped buffer and play it. Per-chunk playback would require
    // a continuous PCM player (flutter_sound / flutter_pcm_sound); the
    // accumulate-and-play path is simpler and the visual lip-sync via
    // pushAudio() is already real-time.
    final speakerBuf = BytesBuilder(copy: false);
    _speakerSub = s.speakerAudioStream.listen((chunk) {
      speakerBuf.add(chunk);
    });
    s.statusStream.listen((rt) async {
      if (rt == RealtimeStatus.responseDone && speakerBuf.length > 0) {
        final pcm = speakerBuf.takeBytes();
        final wav = _wrapPcm16ToWav(pcm, sampleRate: 24000);
        await _player.play(BytesSource(wav));
      }
    });
    try {
      await s.start();
    } catch (e) {
      _showSnack('Realtime connect failed: $e');
      await _stopSession();
      return;
    }
    setState(() => _session = s);

    // Start mic capture at 24 kHz PCM16 mono and forward chunks.
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 24000,
      numChannels: 1,
    ));
    _micSub = stream.listen((chunk) => s.sendMicChunk(chunk));
  }

  Future<void> _stopSession() async {
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _sessionSub?.cancel();
    _sessionSub = null;
    await _speakerSub?.cancel();
    _speakerSub = null;
    await _session?.stop();
    if (mounted) {
      setState(() {
        _session = null;
        _rtStatus = RealtimeStatus.closed;
      });
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _stopSession();
    _avatar?.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onTap: _pickAvatar,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Full-screen avatar render. Falls back to the agent's poster
            // image (or a generic prompt) while the texture is empty.
            if (_avatar != null)
              Center(child: Texture(textureId: _avatar!.textureId))
            else if (_currentAgent != null && _currentAgent!.imageUrl.isNotEmpty)
              Image.network(_currentAgent!.imageUrl, fit: BoxFit.cover)
            else
              const _PickPrompt(),
            // Top: status pill + engine version
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Pill(_status),
                    if (_engineVersion != null) _Pill('engine $_engineVersion'),
                  ],
                ),
              ),
            ),
            // Bottom-right: mic button (visible only after an avatar is loaded)
            if (_avatar != null)
              Positioned(
                right: 24,
                bottom: 32,
                child: SafeArea(
                  child: _MicButton(
                    onTap: _toggleSession,
                    active: _session != null,
                    rtStatus: _rtStatus,
                  ),
                ),
              ),
            // Bottom-left: tap-to-pick hint
            const Positioned(
              left: 24,
              bottom: 32,
              child: SafeArea(child: _Pill('tap to swap ↻')),
            ),
          ],
        ),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.onTap, required this.active, required this.rtStatus});
  final VoidCallback onTap;
  final bool active;
  final RealtimeStatus rtStatus;
  @override
  Widget build(BuildContext context) {
    final color = !active
        ? Colors.white24
        : (rtStatus == RealtimeStatus.userSpeaking
            ? Colors.greenAccent
            : Colors.white70);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 2),
        ),
        child: Icon(
          active ? Icons.mic : Icons.mic_none,
          size: 28,
          color: color,
        ),
      ),
    );
  }
}

class _PickPrompt extends StatelessWidget {
  const _PickPrompt();
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.face_outlined, size: 64, color: Colors.white24),
            ),
            const SizedBox(height: 24),
            const Text('tap to pick an avatar',
                style: TextStyle(fontSize: 18, color: Colors.white60)),
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Colors.white70)),
      );
}

class _AgentPicker extends StatefulWidget {
  const _AgentPicker();
  @override
  State<_AgentPicker> createState() => _AgentPickerState();
}

class _AgentPickerState extends State<_AgentPicker> {
  late final Future<List<BithumanAgent>> _agents;
  @override
  void initState() {
    super.initState();
    _agents = fetchPublicAgents(limit: 60);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => FutureBuilder<List<BithumanAgent>>(
        future: _agents,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('catalog failed: ${snap.error}',
                    style: const TextStyle(color: Colors.white60)),
              ),
            );
          }
          final agents = snap.data!;
          return CustomScrollView(
            controller: controller,
            slivers: [
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Text('Pick an avatar',
                      style: TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w600)),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 0.75,
                  ),
                  itemCount: agents.length,
                  itemBuilder: (_, i) => _AgentTile(
                    agent: agents[i],
                    onTap: () => Navigator.pop(context, agents[i]),
                  ),
                ),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
            ],
          );
        },
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({required this.agent, required this.onTap});
  final BithumanAgent agent;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (agent.imageUrl.isNotEmpty)
              Image.network(agent.imageUrl, fit: BoxFit.cover)
            else
              Container(color: Colors.white12),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Text(
                  agent.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, height: 1.2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Wrap a raw PCM16 mono buffer in a WAV header so `audioplayers`'
/// `BytesSource` can decode it. The header is 44 bytes for the standard
/// RIFF/WAVE/PCM format.
Uint8List _wrapPcm16ToWav(Uint8List pcm, {required int sampleRate}) {
  final dataLen = pcm.length;
  final bytesPerSample = 2;
  final byteRate = sampleRate * 1 * bytesPerSample;
  final blockAlign = 1 * bytesPerSample;

  final out = BytesBuilder();
  void w32le(int v) {
    out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  }

  void w16le(int v) {
    out.add([v & 0xFF, (v >> 8) & 0xFF]);
  }

  out.add('RIFF'.codeUnits);
  w32le(36 + dataLen);
  out.add('WAVE'.codeUnits);
  out.add('fmt '.codeUnits);
  w32le(16); // fmt chunk size
  w16le(1); // PCM
  w16le(1); // mono
  w32le(sampleRate);
  w32le(byteRate);
  w16le(blockAlign);
  w16le(16); // bits/sample
  out.add('data'.codeUnits);
  w32le(dataLen);
  out.add(pcm);
  return out.toBytes();
}
