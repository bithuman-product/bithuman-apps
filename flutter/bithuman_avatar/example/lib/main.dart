// bithuman_avatar example — minimal demo.
//
// One bundled sample-avatar.imx renders full-screen on every platform.
// Optionally connects to OpenAI Realtime (--dart-define OPENAI_API_KEY=…)
// with a single mic button. No picker, no catalog.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:io' show File, HttpClient;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:bithuman_avatar/bithuman_realtime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

const _openaiApiKey = String.fromEnvironment('OPENAI_API_KEY');

// Canonical sample avatar — hosted on the public homebrew-bithuman tap
// repo so it's anonymously downloadable on first launch.
const _sampleAvatarUrl =
    'https://github.com/bithuman-product/homebrew-bithuman/releases/download/v1.13.0/sample-avatar.imx';

// System prompt for the bundled avatar's Realtime persona. Override per
// agent in a real app — here we keep it generic.
const _systemPrompt =
    'You are a friendly assistant. Keep replies short and warm.';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // audioplayers on macOS writes BytesSource WAV payload into
  // ~/Library/Caches/<bundle-id>/<hash>. Under the macOS sandbox that
  // container subdirectory doesn't exist by default → first response
  // playback throws PathNotFoundException. Pre-create it so the very
  // first OpenAI Realtime reply has somewhere to land.
  () async {
    try {
      final cache = await getTemporaryDirectory();
      await cache.create(recursive: true);
    } catch (_) {
      /* best-effort */
    }
  }();
  runApp(const BithumanAvatarApp());
}

class BithumanAvatarApp extends StatelessWidget {
  const BithumanAvatarApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'bithuman',
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF111111),
          useMaterial3: true,
        ),
        home: const AvatarScreen(),
      );
}

class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});
  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  BithumanAvatar? _avatar;
  BithumanRealtimeSession? _session;
  StreamSubscription<RealtimeStatus>? _sessionSub;
  StreamSubscription<Uint8List>? _speakerSub;
  StreamSubscription<Uint8List>? _micSub;
  final _player = AudioPlayer();
  final _recorder = AudioRecorder();

  String _status = 'loading…';
  RealtimeStatus _rtStatus = RealtimeStatus.closed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBundled());
  }

  Future<void> _loadBundled() async {
    try {
      final cacheDir = (await getApplicationSupportDirectory());
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
      final dst = File('${cacheDir.path}/sample-avatar.imx');
      // First run: download the 120 MB canonical sample from the public
      // tap repo. Subsequent runs: skip if cached.
      if (!await dst.exists() || (await dst.length()) < 100 * 1024 * 1024) {
        setState(() => _status = 'downloading sample avatar (120 MB)…');
        await _downloadFile(_sampleAvatarUrl, dst);
      }
      setState(() => _status = 'loading…');
      final loaded = await BithumanAvatar.load(dst.path);
      if (!mounted) return;
      setState(() {
        _avatar = loaded;
        _status = '';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'failed: $e');
    }
  }

  /// Download a file with progress updates.
  Future<void> _downloadFile(String url, File dst) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      if (res.statusCode != 200 && res.statusCode != 302) {
        throw 'download HTTP ${res.statusCode}';
      }
      final tmp = File('${dst.path}.partial');
      final sink = tmp.openWrite();
      final total = res.contentLength;
      int got = 0;
      int lastPct = -1;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          final pct = (got * 100 / total).floor();
          if (pct != lastPct && mounted) {
            lastPct = pct;
            setState(() => _status = 'downloading $pct%');
          }
        }
      }
      await sink.close();
      await tmp.rename(dst.path);
    } finally {
      client.close();
    }
  }

  Future<void> _toggleSession() async {
    if (_avatar == null) return;
    if (_session != null) {
      await _stopSession();
      return;
    }
    if (_openaiApiKey.isEmpty) {
      _showSnack('Set OPENAI_API_KEY via --dart-define to chat.');
      return;
    }
    if (!await _recorder.hasPermission()) {
      _showSnack('Microphone permission denied');
      return;
    }
    final s = BithumanRealtimeSession(
      apiKey: _openaiApiKey,
      avatar: _avatar!,
      systemPrompt: _systemPrompt,
    );
    _sessionSub = s.statusStream.listen((rtStatus) {
      if (mounted) setState(() => _rtStatus = rtStatus);
    });
    final speakerBuf = BytesBuilder(copy: false);
    _speakerSub = s.speakerAudioStream.listen(speakerBuf.add);
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
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 24000,
      numChannels: 1,
    ));
    _micSub = stream.listen(s.sendMicChunk);
  }

  Future<void> _stopSession() async {
    await _micSub?.cancel();
    _micSub = null;
    try { await _recorder.stop(); } catch (_) {}
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
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Full-screen avatar (or placeholder until loaded).
          if (_avatar != null)
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 1248,
                height: 704,
                child: Texture(textureId: _avatar!.textureId),
              ),
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(strokeWidth: 2),
                  const SizedBox(height: 16),
                  Text(_status,
                      style: const TextStyle(color: Colors.white60)),
                ],
              ),
            ),
          // Bottom-center: mic toggle (only when avatar loaded).
          if (_avatar != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: SafeArea(
                child: Center(
                  child: _MicButton(
                    onTap: _toggleSession,
                    active: _session != null,
                    rtStatus: _rtStatus,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.onTap,
    required this.active,
    required this.rtStatus,
  });
  final VoidCallback onTap;
  final bool active;
  final RealtimeStatus rtStatus;
  @override
  Widget build(BuildContext context) {
    final tint = !active
        ? Colors.white60
        : (rtStatus == RealtimeStatus.userSpeaking
            ? Colors.greenAccent
            : Colors.white);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(color: tint, width: 2),
        ),
        child: Icon(active ? Icons.mic : Icons.mic_none, size: 32, color: tint),
      ),
    );
  }
}

/// Wrap a raw PCM16 mono buffer in a WAV header for audioplayers.
Uint8List _wrapPcm16ToWav(Uint8List pcm, {required int sampleRate}) {
  final out = BytesBuilder();
  void w32(int v) =>
      out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void w16(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF]);
  out.add('RIFF'.codeUnits);
  w32(36 + pcm.length);
  out.add('WAVE'.codeUnits);
  out.add('fmt '.codeUnits);
  w32(16);
  w16(1);
  w16(1);
  w32(sampleRate);
  w32(sampleRate * 2);
  w16(2);
  w16(16);
  out.add('data'.codeUnits);
  w32(pcm.length);
  out.add(pcm);
  return out.toBytes();
}
