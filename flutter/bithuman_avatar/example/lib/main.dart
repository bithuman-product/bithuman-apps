// bithuman_avatar example — full-screen avatar with tap-to-pick from the
// public bithuman.ai catalog. Same Dart file runs on iOS, Android, macOS.
//
// v0 milestone: catalog browser + tap-to-load flow all work, but the
// native avatar render is a stub (shows a colored placeholder behind the
// chrome) on platforms where the plugin's native side hasn't bound to
// libessence yet. Filling in the real render is tracked per-platform in
// the parent package's ARCHITECTURE.md.
//
// Apache-2.0; (c) bitHuman.

import 'package:flutter/material.dart';
import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:path_provider/path_provider.dart';

void main() {
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
  String? _engineVersion;
  String _status = 'tap to pick an avatar';

  @override
  void initState() {
    super.initState();
    nativeEngineVersion().then((v) {
      if (mounted) setState(() => _engineVersion = v ?? '(stub)');
    });
  }

  Future<void> _pickAvatar() async {
    final picked = await showModalBottomSheet<BithumanAgent>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      builder: (_) => const _AgentPicker(),
    );
    if (picked == null) return;
    setState(() {
      _status = 'downloading ${picked.name}…';
      _currentAgent = picked;
    });
    try {
      final cacheDir = (await getTemporaryDirectory()).path;
      final imxPath = await downloadAgentImx(picked, cacheDir);
      setState(() => _status = 'loading ${picked.name}…');
      final loaded = await BithumanAvatar.load(imxPath);
      await _avatar?.dispose();
      if (!mounted) return;
      setState(() {
        _avatar = loaded;
        _status = picked.name;
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'failed: $e');
    }
  }

  @override
  void dispose() {
    _avatar?.dispose();
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
            // Full-screen avatar render. Stub when no avatar loaded or when
            // the platform plugin hasn't bound to libessence yet.
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
            // Bottom-right: tap-to-pick hint
            Positioned(
              right: 24,
              bottom: 32,
              child: SafeArea(
                child: _Pill('tap anywhere ↻'),
              ),
            ),
          ],
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
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 6),
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
