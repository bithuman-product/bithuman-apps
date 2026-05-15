// Realtime-transport adapter: thin shim over the two concrete OpenAI
// Realtime client implementations the example app uses, so the UI
// (lib/main.dart's AvatarScreen) can speak ONE interface regardless of
// platform.
//
// Two underlying transports today:
//   - WebSocketTransport  → wraps `BithumanRealtimeSession` (the
//     plugin's WebSocket Realtime client + native VP-IO RealtimeAudioIO
//     for mic/speaker). The right path on macOS + iOS where Apple's
//     hardware AEC is available; clean, simple.
//   - WebRTCTransport     → wraps `OpenAIWebRTCSession` (flutter_webrtc
//     + libwebrtc native pipeline). The validated Android path —
//     sidesteps Android AAudio routing + Java audio sink limitations
//     that make the WebSocket transport unreliable there.
//
// Both adapters expose the same `RealtimeTransport` surface; the UI
// doesn't know or care which one it's holding. `pickTransport()` is the
// platform-conditional factory at the bottom of this file.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:bithuman_avatar/bithuman_realtime.dart';

import 'openai_webrtc_session.dart';

/// Lifecycle states that any underlying transport can be in. Maps the
/// concrete `RealtimeStatus` (WebSocket) and `WebRTCStatus` (WebRTC)
/// onto a single enum the UI can switch on.
enum TransportStatus {
  /// Initial state, no connection in flight.
  closed,

  /// Dialing / negotiating / authenticating.
  connecting,

  /// Connected; the bot is silent and waiting for the user to talk.
  listening,

  /// Server VAD detected user speech; the bot's playback (if any) was
  /// cancelled by the barge-in path.
  userSpeaking,

  /// User stopped talking; server is generating a response.
  thinking,

  /// Bot is actively replying (audio + transcript streaming back).
  responding,

  /// Last response completed cleanly. UI typically returns to
  /// `listening` immediately after.
  responseDone,

  /// Transport-level error. Specifics surface as a separate event /
  /// log; the UI can show a snack and offer to reconnect.
  error,
}

/// Common surface for any OpenAI Realtime transport the example app
/// can drive. New transports (e.g. LiveKit) implement this and slot
/// into `pickTransport()` below — the UI doesn't change.
///
/// Stream contracts:
///   - `statusStream` always emits at least once before any other
///     stream; UI uses it to swap chrome (status pill, mic-button
///     state, captions visibility).
///   - `botTranscriptStream` emits each bot-transcript delta as it
///     arrives. Empty deltas are valid (just don't append). Resets to
///     empty caption on a new `responding` transition.
///   - `micLevelStream` / `botLevelStream` emit a 0..1 float at ~10 Hz
///     when the underlying transport surfaces audio levels. WebRTC
///     transport currently emits nothing — UI should treat absent
///     emissions as "level not available" (not "level is zero").
///   - `interruptStream` pulses (no payload) when the bot's in-flight
///     reply was cancelled mid-stream. UI uses this to flush
///     captions / re-arm the avatar's idle frame.
abstract class RealtimeTransport {
  Stream<TransportStatus> get statusStream;
  Stream<String> get botTranscriptStream;
  Stream<double> get micLevelStream;
  Stream<double> get botLevelStream;
  Stream<void> get interruptStream;

  /// Mute the local mic. Implementations may delay the underlying
  /// effect until `start()` has produced a live capture node.
  bool get muted;
  set muted(bool value);

  /// Open the connection + start the audio loop. Returns once the
  /// transport is at `listening` (or has surfaced an error via
  /// `statusStream`).
  Future<void> start();

  /// Tear the connection down cleanly. Idempotent.
  Future<void> stop();

  /// Drop all owned resources. Call after `stop()`. Any further calls
  /// on the object are undefined.
  Future<void> dispose();

  /// Update session-level config (system prompt today; voice/model
  /// follow as the underlying transports gain server-side update
  /// support). Best-effort — implementations may ignore unknown keys.
  /// Returns true if at least one key was applied.
  bool applySettings({String? systemPrompt, String? voice, String? model});
}

/// Wraps the WebSocket-based `BithumanRealtimeSession` (the plugin's
/// own Realtime client + native VP-IO mic/speaker). macOS + iOS path.
class WebSocketTransport implements RealtimeTransport {
  WebSocketTransport({
    required String apiKey,
    required BithumanAvatar avatar,
    required String model,
    required String voice,
    required String systemPrompt,
  }) : _session = BithumanRealtimeSession(
          apiKey: apiKey,
          avatar: avatar,
          model: model,
          voice: voice,
          systemPrompt: systemPrompt,
        );

  final BithumanRealtimeSession _session;

  // Eagerly-created broadcast controller for the interrupt pulses; the
  // session itself doesn't surface a dedicated interrupt stream, so we
  // synthesise one from the status transitions (any → userSpeaking
  // implies a barge-in cancelling the bot mid-reply).
  final _interrupt = StreamController<void>.broadcast();
  StreamSubscription<RealtimeStatus>? _statusSub;
  TransportStatus _last = TransportStatus.closed;

  @override
  Stream<TransportStatus> get statusStream => _session.statusStream
      .map(_mapStatus)
      .map((s) {
        if (s == TransportStatus.userSpeaking &&
            _last == TransportStatus.responding) {
          _interrupt.add(null);
        }
        _last = s;
        return s;
      });

  @override
  Stream<String> get botTranscriptStream => _session.botTranscriptStream;
  @override
  Stream<double> get micLevelStream => _session.micLevelStream;
  @override
  Stream<double> get botLevelStream => _session.botLevelStream;
  @override
  Stream<void> get interruptStream => _interrupt.stream;

  @override
  bool get muted => _session.muted;
  @override
  set muted(bool value) => _session.muted = value;

  @override
  Future<void> start() => _session.start();
  @override
  Future<void> stop() => _session.stop();

  @override
  Future<void> dispose() async {
    await _statusSub?.cancel();
    await _interrupt.close();
    // BithumanRealtimeSession doesn't have its own dispose; stop()
    // releases the WS + audio graph, and Dart GC takes the rest.
  }

  @override
  bool applySettings({String? systemPrompt, String? voice, String? model}) {
    return _session.applySettings(systemPrompt: systemPrompt);
  }

  static TransportStatus _mapStatus(RealtimeStatus s) {
    return switch (s) {
      RealtimeStatus.connecting   => TransportStatus.connecting,
      RealtimeStatus.open         => TransportStatus.listening,
      RealtimeStatus.userSpeaking => TransportStatus.userSpeaking,
      RealtimeStatus.userStopped  => TransportStatus.thinking,
      RealtimeStatus.responseDone => TransportStatus.responseDone,
      RealtimeStatus.closed       => TransportStatus.closed,
      RealtimeStatus.error        => TransportStatus.error,
    };
  }
}

/// Wraps the WebRTC-based `OpenAIWebRTCSession`. Android path. Also
/// wires the lipsync feed: when libwebrtc attaches the remote audio
/// track, the avatar's `attachWebrtcRemoteAudio` is called so the
/// plugin's lipsync queue is fed from the exact PCM the speaker plays.
/// On barge-in, `avatar.interrupt()` is called to flush the queue so
/// the mouth doesn't keep articulating cancelled audio.
class WebRTCTransport implements RealtimeTransport {
  WebRTCTransport({
    required String apiKey,
    required this.avatar,
    required String model,
    required String voice,
    required String systemPrompt,
  }) : _session = OpenAIWebRTCSession(
          apiKey: apiKey,
          model: model,
          voice: voice,
          systemPrompt: systemPrompt,
        );

  final BithumanAvatar avatar;
  final OpenAIWebRTCSession _session;
  StreamSubscription<dynamic>? _remoteAudioSub;
  StreamSubscription<dynamic>? _interruptForwardSub;
  // WebRTC transport doesn't surface mic/bot levels yet — getStats()
  // audio levels are wireable but TBD. Empty broadcast controllers
  // satisfy the contract (no emissions ≠ "level is zero").
  final _micLevel = StreamController<double>.broadcast();
  final _botLevel = StreamController<double>.broadcast();

  @override
  Stream<TransportStatus> get statusStream =>
      _session.statusStream.map(_mapStatus);
  @override
  Stream<String> get botTranscriptStream => _session.botTranscriptStream;
  @override
  Stream<double> get micLevelStream => _micLevel.stream;
  @override
  Stream<double> get botLevelStream => _botLevel.stream;
  @override
  Stream<void> get interruptStream => _session.interruptStream;

  // The WebRTC client doesn't expose mic-mute today. Track locally + no-op
  // until the underlying client gains a `setMicEnabled` knob (or we
  // flip the local audio track's `enabled` flag directly).
  bool _muted = false;
  @override
  bool get muted => _muted;
  @override
  set muted(bool value) {
    _muted = value;
    // TODO(plugin): wire to localAudioTrack.enabled = !value once the
    // session exposes the track. Until then mute is UI-only state.
  }

  @override
  Future<void> start() async {
    // Lipsync attach: feed the bot's PCM into the avatar's queue as
    // soon as libwebrtc has the remote track. NOT the mic.
    _remoteAudioSub = _session.remoteAudioReadyStream.listen((track) async {
      try {
        await avatar.attachWebrtcRemoteAudio(track.id ?? '');
      } catch (_) {/* swallowed; lipsync simply won't be driven */}
    });
    // On barge-in / cancel, flush avatar's lipsync queue so the mouth
    // stops articulating audio the user never hears (phantom talk).
    _interruptForwardSub = _session.interruptStream.listen((_) async {
      try {
        await avatar.interrupt();
      } catch (_) {/* swallowed */}
    });
    await _session.start();
  }

  @override
  Future<void> stop() async {
    try {
      await avatar.detachWebrtcRemoteAudio();
    } catch (_) {/* swallowed */}
    await _session.stop();
  }

  @override
  Future<void> dispose() async {
    await _remoteAudioSub?.cancel();
    await _interruptForwardSub?.cancel();
    await _micLevel.close();
    await _botLevel.close();
    await _session.dispose();
  }

  @override
  bool applySettings({String? systemPrompt, String? voice, String? model}) {
    // OpenAIWebRTCSession ignores live settings updates today (the
    // session.update is sent once at connect). Returning false signals
    // "no-op" so the UI can decide whether to drop & reconnect.
    return false;
  }

  static TransportStatus _mapStatus(WebRTCStatus s) {
    return switch (s) {
      WebRTCStatus.idle         => TransportStatus.closed,
      WebRTCStatus.connecting   => TransportStatus.connecting,
      WebRTCStatus.open         => TransportStatus.listening,
      WebRTCStatus.userSpeaking => TransportStatus.userSpeaking,
      WebRTCStatus.userStopped  => TransportStatus.thinking,
      WebRTCStatus.responseDone => TransportStatus.responseDone,
      WebRTCStatus.closed       => TransportStatus.closed,
      WebRTCStatus.error        => TransportStatus.error,
    };
  }
}

/// Platform-conditional factory. Android → WebRTC; everywhere else →
/// WebSocket. Adding a new platform = one switch case here, no UI
/// change.
RealtimeTransport pickTransport({
  required String apiKey,
  required BithumanAvatar avatar,
  required String model,
  required String voice,
  required String systemPrompt,
}) {
  if (Platform.isAndroid) {
    return WebRTCTransport(
      apiKey: apiKey,
      avatar: avatar,
      model: model,
      voice: voice,
      systemPrompt: systemPrompt,
    );
  }
  return WebSocketTransport(
    apiKey: apiKey,
    avatar: avatar,
    model: model,
    voice: voice,
    systemPrompt: systemPrompt,
  );
}
