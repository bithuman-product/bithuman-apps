// bithuman_avatar example — developer demo.
//
// Open-source reference app showing the full bithuman_avatar +
// OpenAI Realtime pipeline. Configuration is dead simple: pass
// keys + an .imx path on the build command line, run, done.
//
//   flutter run -d macos \
//     --dart-define=OPENAI_API_KEY=sk-... \
//     --dart-define=BITHUMAN_API_SECRET=bh-... \
//     --dart-define=IMX_PATH=/abs/path/to/avatar.imx
//
// If you skip `IMX_PATH`, the app falls back to a conventional
// location under your platform's application support directory and
// shows the exact path so you can drop a file there. See
// `dev_config.dart` for full details.
//
// What this demo shows:
//   - libessence avatar rendered into a Flutter texture (native)
//   - OpenAI Realtime WebSocket with mic → cloud → bot audio
//   - Apple VP-IO echo-cancelled mic + speaker (no self-talk)
//   - A/V synced lipsync (avatar mouth tracks the agent's words)
//   - Client-side VAD for instant barge-in
//   - Looping idle animation when nothing's happening
//   - Live transcript captions
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:bithuman_avatar/bithuman_realtime.dart';

import 'dev_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BithumanAvatarApp());
}

class BithumanAvatarApp extends StatelessWidget {
  const BithumanAvatarApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'bithuman',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF050505),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6FE2C5),
            brightness: Brightness.dark,
          ),
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
  StreamSubscription<String>? _transcriptSub;
  StreamSubscription<double>? _micLevelSub;
  StreamSubscription<double>? _botLevelSub;

  String _status = 'loading…';
  String? _missingImxPath; // non-null → render first-run screen with this path
  RealtimeStatus _rtStatus = RealtimeStatus.closed;
  String _caption = '';
  bool _expectingNewReply = false;
  double _micLevel = 0;
  double _botLevel = 0;
  final _captionScroll = ScrollController();

  bool _muted = false;
  bool _captionsEnabled = false;
  Timer? _chromeFadeTimer;
  bool _chromeVisible = true;

  // Session-config overrides. Layered defaults at boot time:
  //   hardcoded → --dart-define → config.json → settings-sheet edits
  // Sheet edits also write BACK to config.json so changes survive
  // app restarts. config.json is the single source of truth.
  String _voice = DevConfig.defaultVoice;
  String _systemPrompt = DevConfig.defaultSystemPrompt;
  String _model = DevConfig.defaultModel;
  String _openaiKey = DevConfig.openaiApiKey;
  String _bithumanSecret = DevConfig.bithumanApiSecret;
  int _vadThreshold = DevConfig.defaultVadThreshold;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Pull config.json overrides if present — single source for
      // all tunable knobs. Per-key fallback to the --dart-define
      // value we already have in state.
      final cfg = await DevConfig.readConfigFile();
      if (mounted) {
        setState(() {
          _voice = (cfg['voice'] as String?) ?? _voice;
          _systemPrompt = (cfg['system_prompt'] as String?) ?? _systemPrompt;
          _model = (cfg['model'] as String?) ?? _model;
          _openaiKey = (cfg['openai_api_key'] as String?) ?? _openaiKey;
          _bithumanSecret =
              (cfg['bithuman_api_secret'] as String?) ?? _bithumanSecret;
          final vt = cfg['vad_threshold'];
          if (vt is int) _vadThreshold = vt;
        });
      }
      await _loadAvatar();
    });
  }

  Future<void> _loadAvatar() async {
    try {
      final imxPath = await DevConfig.resolveImxPath();
      if (imxPath == null) {
        final dropPath = await DevConfig.defaultImxPath();
        if (mounted) {
          setState(() => _missingImxPath = dropPath);
        }
        return;
      }
      if (mounted) setState(() => _status = 'Loading avatar…');
      final loaded = await BithumanAvatar.load(imxPath);
      if (!mounted) return;
      setState(() {
        _avatar = loaded;
        _status = '';
        _missingImxPath = null;
      });
      _scheduleChromeFadeOut();
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
    }
  }

  Future<void> _toggleSession() async {
    if (_avatar == null) return;
    if (_session != null) {
      await _stopSession();
      return;
    }
    if (_openaiKey.isEmpty) {
      _showSnack('Set openai_api_key in config.json or pass '
          '--dart-define=OPENAI_API_KEY to start talking.');
      return;
    }
    final s = BithumanRealtimeSession(
      apiKey: _openaiKey,
      avatar: _avatar!,
      model: _model,
      voice: _voice,
      systemPrompt: _systemPrompt,
    );
    s.muted = _muted;
    _sessionSub = s.statusStream.listen((rt) {
      if (!mounted) return;
      setState(() {
        _rtStatus = rt;
        if (rt == RealtimeStatus.userSpeaking) _expectingNewReply = true;
      });
    });
    _transcriptSub = s.botTranscriptStream.listen(_onTranscriptDelta);
    _micLevelSub = s.micLevelStream.listen((lv) {
      if (mounted) setState(() => _micLevel = lv);
    });
    _botLevelSub = s.botLevelStream.listen((lv) {
      if (mounted) setState(() => _botLevel = lv);
    });
    try {
      await s.start();
    } catch (e) {
      _showSnack('Connect failed: $e');
      await _stopSession();
      return;
    }
    if (mounted) setState(() => _session = s);
  }

  Future<void> _stopSession() async {
    await _sessionSub?.cancel();
    _sessionSub = null;
    await _transcriptSub?.cancel();
    _transcriptSub = null;
    await _micLevelSub?.cancel();
    _micLevelSub = null;
    await _botLevelSub?.cancel();
    _botLevelSub = null;
    await _session?.stop();
    if (mounted) {
      setState(() {
        _session = null;
        _rtStatus = RealtimeStatus.closed;
        _caption = '';
        _micLevel = 0;
        _botLevel = 0;
      });
    }
  }

  void _onTranscriptDelta(String delta) {
    if (!mounted) return;
    setState(() {
      if (_expectingNewReply) {
        _caption = '';
        _expectingNewReply = false;
      }
      _caption = (_caption + delta).trimLeft();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_captionScroll.hasClients) {
        _captionScroll.animateTo(
          _captionScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleMute() {
    HapticFeedback.lightImpact();
    setState(() => _muted = !_muted);
    _session?.muted = _muted;
    _scheduleChromeFadeOut();
  }

  void _toggleCaptions() {
    HapticFeedback.lightImpact();
    setState(() => _captionsEnabled = !_captionsEnabled);
    _scheduleChromeFadeOut();
  }

  void _onCanvasTap() {
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) _scheduleChromeFadeOut();
  }

  void _scheduleChromeFadeOut() {
    _chromeFadeTimer?.cancel();
    _chromeFadeTimer = Timer(const Duration(seconds: 6), () {
      if (mounted && _session != null) {
        setState(() => _chromeVisible = false);
      }
    });
  }

  /// Tear down the current session and immediately start a new one
  /// with the current `_voice` + `_systemPrompt` + `_model`. Used
  /// when the user picks a different voice mid-call — OpenAI's
  /// Realtime API doesn't allow `voice` to change via session.update
  /// once audio has been generated, so a full WS reconnect is the
  /// only path.
  Future<void> _restartSessionForVoice() async {
    if (_avatar == null) return;
    final wasMuted = _muted;
    await _stopSession();
    // Tiny gap before reconnecting so the native audio engine has a
    // tick to fully tear down (player.stop/reset is synchronous but
    // the OS audio unit takes ~50 ms to actually go quiet).
    await Future<void>.delayed(const Duration(milliseconds: 120));
    _muted = wasMuted;
    await _toggleSession();
  }

  Future<void> _openSettings() async {
    HapticFeedback.lightImpact();
    final configPath = await DevConfig.defaultConfigPath();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SettingsSheet(
        initialVoice: _voice,
        initialPrompt: _systemPrompt,
        initialModel: _model,
        configPath: configPath,
        sessionLive: _session != null,
        onVoice: (v) async {
          setState(() => _voice = v);
          // Persist for next launch.
          await DevConfig.writeConfigFile({'voice': v});
          // OpenAI locks `voice` once the model has produced audio,
          // so hot session.update is silently dropped. Restart the
          // session — ~150-300 ms blip, then the agent comes back
          // in the new voice.
          if (_session != null) {
            await _restartSessionForVoice();
          }
        },
        onPrompt: (p) {
          setState(() => _systemPrompt = p);
          // session.update { instructions } is honoured live; takes
          // effect on the next agent response.
          _session?.applySettings(systemPrompt: p);
          // Persist (debounced inside the sheet already).
          DevConfig.writeConfigFile({'system_prompt': p});
        },
        onModel: (m) {
          setState(() => _model = m);
          DevConfig.writeConfigFile({'model': m});
        },
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.black87,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 80),
    ));
  }

  @override
  void dispose() {
    _stopSession();
    _chromeFadeTimer?.cancel();
    _captionScroll.dispose();
    _avatar?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_missingImxPath != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF050505),
        body: _FirstRunScreen(dropPath: _missingImxPath!, onRetry: _loadAvatar),
      );
    }

    final size = MediaQuery.of(context).size;
    final isCompact = size.shortestSide < 600;

    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onCanvasTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _AvatarCanvas(avatar: _avatar, status: _status),
            IgnorePointer(child: _StateGlow(state: _rtStatus)),

            // Top-right: settings (voice + system prompt). Same fade
            // behavior as the bottom controls — auto-hides 6 s into
            // an active session, tap canvas to bring back.
            if (_avatar != null)
              SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: _chromeVisible ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !_chromeVisible,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            0, isCompact ? 6 : 10, isCompact ? 10 : 18, 0),
                        child: _CircleIconButton(
                          icon: Icons.tune_rounded,
                          size: 40,
                          onTap: _openSettings,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Bottom band — caption focus mode OR control bar.
            if (_avatar != null)
              SafeArea(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: _chromeVisible ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !_chromeVisible,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            isCompact ? 16 : 32, 0,
                            isCompact ? 16 : 32, isCompact ? 14 : 24),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 240),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.bottomCenter,
                            children: [
                              ...previous,
                              if (current != null) current,
                            ],
                          ),
                          child: SizedBox(
                            key: ValueKey(
                                _captionsEnabled ? 'caption' : 'controls'),
                            height: 168,
                            child: _captionsEnabled
                                ? _ExpandedCaption(
                                    text: _caption,
                                    scrollController: _captionScroll,
                                    onClose: _toggleCaptions,
                                  )
                                : Align(
                                    alignment: Alignment.bottomCenter,
                                    child: _BottomControls(
                                      active: _session != null,
                                      rtStatus: _rtStatus,
                                      muted: _muted,
                                      captionsOn: _captionsEnabled,
                                      micLevel: _muted ? 0 : _micLevel,
                                      botLevel: _botLevel,
                                      onPrimary: () {
                                        _toggleSession();
                                        _scheduleChromeFadeOut();
                                      },
                                      onMute: _toggleMute,
                                      onCaptions: _toggleCaptions,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── First-run screen (no .imx found) ───────────────────────────────

class _FirstRunScreen extends StatelessWidget {
  const _FirstRunScreen({required this.dropPath, required this.onRetry});
  final String dropPath;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.movie_filter_outlined,
                    color: Color(0xFF6FE2C5), size: 36),
                const SizedBox(height: 14),
                const Text(
                  'Bring your own avatar',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Drop a .imx file at the path below, then tap Retry. '
                  'Or rebuild with --dart-define=IMX_PATH=/abs/path.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13.5, height: 1.4),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12), width: 1),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          dropPath,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontFamily: 'Menlo',
                              height: 1.4),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy path',
                        icon: const Icon(Icons.copy_rounded,
                            color: Colors.white60, size: 18),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: dropPath));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Path copied'),
                                behavior: SnackBarBehavior.floating,
                                duration: Duration(seconds: 1),
                              ),
                            );
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF6FE2C5),
                    foregroundColor: Colors.black,
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 22),
                  ),
                ),
                const SizedBox(height: 24),
                const _EnvKeyHint(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EnvKeyHint extends StatelessWidget {
  const _EnvKeyHint();
  @override
  Widget build(BuildContext context) {
    final missingOpenAI = !DevConfig.hasOpenAIKey;
    if (!missingOpenAI) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFD580).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: const Color(0xFFFFD580).withValues(alpha: 0.4), width: 1),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline,
              color: Color(0xFFFFD580), size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'OPENAI_API_KEY is not set. The avatar will load but '
              'the mic button is disabled until you rebuild with '
              '--dart-define=OPENAI_API_KEY=sk-…',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Avatar canvas (background layer) ────────────────────────────────

class _AvatarCanvas extends StatelessWidget {
  const _AvatarCanvas({required this.avatar, required this.status});
  final BithumanAvatar? avatar;
  final String status;

  @override
  Widget build(BuildContext context) {
    if (avatar == null) {
      return Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            radius: 0.9,
            colors: [Color(0xFF1A1A1F), Color(0xFF050505)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
              const SizedBox(height: 16),
              Text(status,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  )),
            ],
          ),
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: 1248,
        height: 704,
        child: Texture(textureId: avatar!.textureId),
      ),
    );
  }
}

// ─── State-aware edge glow ──────────────────────────────────────────

class _StateGlow extends StatelessWidget {
  const _StateGlow({required this.state});
  final RealtimeStatus state;

  @override
  Widget build(BuildContext context) {
    Color color;
    double opacity;
    switch (state) {
      case RealtimeStatus.userSpeaking:
        color = const Color(0xFF6FE2C5);
        opacity = 0.55;
        break;
      case RealtimeStatus.responseDone:
      case RealtimeStatus.open:
        color = const Color(0xFF8AB6FF);
        opacity = 0.35;
        break;
      case RealtimeStatus.connecting:
        color = const Color(0xFFFFD580);
        opacity = 0.35;
        break;
      case RealtimeStatus.error:
        color = const Color(0xFFFF7B7B);
        opacity = 0.45;
        break;
      default:
        color = Colors.transparent;
        opacity = 0;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          radius: 1.1,
          colors: [
            Colors.transparent,
            color.withValues(alpha: opacity * 0.4),
            color.withValues(alpha: opacity),
          ],
          stops: const [0.55, 0.85, 1.0],
        ),
      ),
    );
  }
}

// ─── Pulsing state dot (used inside the primary button only) ────────

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final v = 0.55 + 0.45 * _c.value;
          return Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: v),
              shape: BoxShape.circle,
            ),
          );
        },
      );
}

// ─── Expanded caption (focus-read mode) ─────────────────────────────

class _ExpandedCaption extends StatelessWidget {
  const _ExpandedCaption({
    required this.text,
    required this.scrollController,
    required this.onClose,
  });
  final String text;
  final ScrollController scrollController;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final hasText = text.isNotEmpty;
    return _Frosted(
      borderRadius: BorderRadius.circular(22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 168, maxHeight: 168),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: hasText
                    ? Scrollbar(
                        controller: scrollController,
                        thickness: 3,
                        radius: const Radius.circular(2),
                        child: SingleChildScrollView(
                          controller: scrollController,
                          physics: const BouncingScrollPhysics(),
                          child: Text(text,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                height: 1.45,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 0.15,
                              )),
                        ),
                      )
                    : const Align(
                        alignment: Alignment.topLeft,
                        child: Text(
                          'Captions on — waiting for reply…',
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                              fontStyle: FontStyle.italic),
                        ),
                      ),
              ),
              const SizedBox(width: 6),
              _CircleIconButton(
                icon: Icons.close_rounded,
                size: 32,
                onTap: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Bottom control bar ─────────────────────────────────────────────

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.active,
    required this.rtStatus,
    required this.muted,
    required this.captionsOn,
    required this.micLevel,
    required this.botLevel,
    required this.onPrimary,
    required this.onMute,
    required this.onCaptions,
  });
  final bool active;
  final RealtimeStatus rtStatus;
  final bool muted;
  final bool captionsOn;
  final double micLevel;
  final double botLevel;
  final VoidCallback onPrimary;
  final VoidCallback onMute;
  final VoidCallback onCaptions;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: _Frosted(
        borderRadius: BorderRadius.circular(40),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (active) ...[
                _CircleIconButton(
                  icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  size: 48,
                  highlighted: muted,
                  onTap: onMute,
                ),
                const SizedBox(width: 12),
              ],
              _PrimaryButton(
                active: active,
                rtStatus: rtStatus,
                micLevel: micLevel,
                botLevel: botLevel,
                onTap: onPrimary,
              ),
              const SizedBox(width: 12),
              _CircleIconButton(
                icon: captionsOn
                    ? Icons.closed_caption_rounded
                    : Icons.closed_caption_off_outlined,
                size: 48,
                highlighted: captionsOn && active,
                onTap: onCaptions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.active,
    required this.rtStatus,
    required this.micLevel,
    required this.botLevel,
    required this.onTap,
  });
  final bool active;
  final RealtimeStatus rtStatus;
  final double micLevel;
  final double botLevel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (ringColor, fillColor, icon, level) = _style();
    final v = (level * 5.0).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      child: SizedBox(
        width: 88,
        height: 88,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              width: 64 + 22 * v,
              height: 64 + 22 * v,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ringColor.withValues(alpha: 0.12 + 0.22 * v),
              ),
            ),
            if (active)
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: ringColor.withValues(alpha: 0.45),
                    width: 1.2,
                  ),
                ),
              ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: fillColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: fillColor.withValues(alpha: 0.35),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Icon(icon,
                    key: ValueKey(icon),
                    color: Colors.black,
                    size: 26),
              ),
            ),
            if (rtStatus == RealtimeStatus.connecting)
              SizedBox(
                width: 80,
                height: 80,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(
                      ringColor.withValues(alpha: 0.85)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  (Color, Color, IconData, double) _style() {
    if (!active) {
      return (Colors.white, const Color(0xFF6FE2C5), Icons.mic_rounded, 0);
    }
    switch (rtStatus) {
      case RealtimeStatus.connecting:
        return (const Color(0xFFFFD580), const Color(0xFFFFD580),
            Icons.call_end_rounded, 0);
      case RealtimeStatus.userSpeaking:
      case RealtimeStatus.open:
      case RealtimeStatus.userStopped:
        return (const Color(0xFF6FE2C5), const Color(0xFFFF6B6B),
            Icons.call_end_rounded, micLevel);
      case RealtimeStatus.responseDone:
        return (const Color(0xFF8AB6FF), const Color(0xFFFF6B6B),
            Icons.call_end_rounded, botLevel);
      case RealtimeStatus.error:
        return (const Color(0xFFFF7B7B), const Color(0xFFFF7B7B),
            Icons.call_end_rounded, 0);
      case RealtimeStatus.closed:
        return (Colors.white, const Color(0xFF6FE2C5), Icons.mic_rounded, 0);
    }
  }
}

// ─── Reusable bits ──────────────────────────────────────────────────

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.highlighted = false,
  });
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final bool highlighted;
  @override
  Widget build(BuildContext context) {
    final fg = highlighted ? const Color(0xFF6FE2C5) : Colors.white;
    final bg = highlighted
        ? const Color(0xFF6FE2C5).withValues(alpha: 0.18)
        : Colors.white.withValues(alpha: 0.12);
    final border = highlighted
        ? const Color(0xFF6FE2C5).withValues(alpha: 0.5)
        : Colors.white.withValues(alpha: 0.15);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 1),
        ),
        child: Icon(icon, color: fg, size: size * 0.46),
      ),
    );
  }
}

// ─── Settings sheet ────────────────────────────────────────────────

/// Live-edit sheet. Every change fires its `on*` callback immediately
/// — the parent both updates state AND calls `session.applySettings`
/// so voice + prompt take effect on the next agent response without
/// the user having to "Save" or restart the call.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.initialVoice,
    required this.initialPrompt,
    required this.initialModel,
    required this.configPath,
    required this.sessionLive,
    required this.onVoice,
    required this.onPrompt,
    required this.onModel,
  });
  final String initialVoice;
  final String initialPrompt;
  final String initialModel;
  final String configPath;
  final bool sessionLive;
  final ValueChanged<String> onVoice;
  final ValueChanged<String> onPrompt;
  final ValueChanged<String> onModel;
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late String _voice = widget.initialVoice;
  late final _promptCtl = TextEditingController(text: widget.initialPrompt);
  late final _modelCtl = TextEditingController(text: widget.initialModel);
  Timer? _promptDebounce;
  bool _showAdvanced = false;

  @override
  void dispose() {
    _promptDebounce?.cancel();
    _promptCtl.dispose();
    _modelCtl.dispose();
    super.dispose();
  }

  void _pickVoice(String v) {
    HapticFeedback.selectionClick();
    setState(() => _voice = v);
    widget.onVoice(v);
  }

  void _onPromptChanged(String value) {
    // 250 ms debounce — applying on every keystroke would flood the
    // WebSocket with `session.update` events. A quarter of a second
    // after the user stops typing is the right cadence; quick enough
    // to feel live, long enough that "alloy" → "alloyalloy" doesn't
    // fire two updates.
    _promptDebounce?.cancel();
    _promptDebounce = Timer(const Duration(milliseconds: 250), () {
      widget.onPrompt(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: _Frosted(
        borderRadius: BorderRadius.circular(28),
        child: SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.82),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Header
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Settings',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.1)),
                            const SizedBox(height: 4),
                            Text(
                              widget.sessionLive
                                  ? 'Changes apply live to this call'
                                  : 'Changes apply on next call',
                              style: const TextStyle(
                                  color: Colors.white60, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      _CircleIconButton(
                        icon: Icons.close_rounded,
                        size: 34,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),

                  // Voice section
                  _Section(
                    title: 'Voice',
                    child: _VoicePicker(
                      selected: _voice,
                      onSelect: _pickVoice,
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Prompt section — live debounced
                  _Section(
                    title: 'System prompt',
                    child: _PromptField(
                      controller: _promptCtl,
                      hint: 'Tell the assistant who it is and how to behave…',
                      maxLines: 6,
                      onChanged: _onPromptChanged,
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Advanced section — model + config-file hint
                  _DisclosureSection(
                    title: 'Advanced',
                    expanded: _showAdvanced,
                    onToggle: () =>
                        setState(() => _showAdvanced = !_showAdvanced),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 6),
                        _FieldLabel(
                          'Realtime model',
                          subtitle: widget.sessionLive
                              ? 'Locked while a call is active'
                              : null,
                        ),
                        const SizedBox(height: 6),
                        _PromptField(
                          controller: _modelCtl,
                          maxLines: 1,
                          enabled: !widget.sessionLive,
                          onChanged: widget.onModel,
                        ),
                        const SizedBox(height: 14),
                        _ConfigCard(path: widget.configPath),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.1)),
        const SizedBox(height: 10),
        child,
      ],
    );
  }
}

class _DisclosureSection extends StatelessWidget {
  const _DisclosureSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });
  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.1)),
                const Spacer(),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more_rounded,
                      color: Colors.white60, size: 22),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 220),
          crossFadeState:
              expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: child,
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.subtitle});
  final String text;
  final String? subtitle;
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(text,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                fontWeight: FontWeight.w500)),
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Text(subtitle!,
              style: const TextStyle(color: Colors.white38, fontSize: 11.5)),
        ],
      ],
    );
  }
}

class _VoicePicker extends StatelessWidget {
  const _VoicePicker({required this.selected, required this.onSelect});
  final String selected;
  final ValueChanged<String> onSelect;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: DevConfig.availableVoices.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final v = DevConfig.availableVoices[i];
          return _VoiceChip(
            label: v,
            selected: v == selected,
            onTap: () => onSelect(v),
          );
        },
      ),
    );
  }
}

class _VoiceChip extends StatelessWidget {
  const _VoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? const Color(0xFF6FE2C5)
        : Colors.white.withValues(alpha: 0.06);
    final fg = selected ? Colors.black : Colors.white;
    final border = selected
        ? const Color(0xFF6FE2C5)
        : Colors.white.withValues(alpha: 0.12);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: border, width: 1),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: const Color(0xFF6FE2C5).withValues(alpha: 0.35),
                    blurRadius: 12,
                    spreadRadius: -2,
                  ),
                ]
              : null,
        ),
        child: Text(
          // Capitalise so chips read "Ash" rather than "ash"
          '${label[0].toUpperCase()}${label.substring(1)}',
          style: TextStyle(
            color: fg,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.25,
          ),
        ),
      ),
    );
  }
}

class _PromptField extends StatelessWidget {
  const _PromptField({
    required this.controller,
    this.hint,
    this.maxLines = 4,
    this.enabled = true,
    this.onChanged,
  });
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.10), width: 1),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: TextField(
          controller: controller,
          enabled: enabled,
          minLines: 1,
          maxLines: maxLines,
          onChanged: onChanged,
          style: const TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              height: 1.45,
              fontFamily: 'SF Pro Text'),
          decoration: InputDecoration(
            border: InputBorder.none,
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(
                color: Colors.white38, fontSize: 14, height: 1.45),
          ),
        ),
      ),
    );
  }
}

class _ConfigCard extends StatelessWidget {
  const _ConfigCard({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.08), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline_rounded,
                  color: Color(0xFF6FE2C5), size: 14),
              const SizedBox(width: 6),
              const Text(
                'Pin defaults across launches',
                style: TextStyle(
                  color: Color(0xFF6FE2C5),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Drop a config.json with any of these keys at:',
            style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 8),
          SelectableText(
            path,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11.5,
                fontFamily: 'Menlo',
                height: 1.4),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '{\n  "voice": "ash",\n  "system_prompt": "…",\n  "model": "…"\n}',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontFamily: 'Menlo',
                  height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Frosted extends StatelessWidget {
  const _Frosted({required this.child, required this.borderRadius});
  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.32),
            borderRadius: borderRadius,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
