// bithuman — Flutter plugin entrypoint.
//
// One-package access to the bitHuman avatar engine across iOS, Android,
// macOS, and (planned) Linux/Windows/Web. See ARCHITECTURE.md for the
// per-platform delivery story.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, HttpClient, HttpClientResponse;
import 'dart:typed_data' show Int16List, Uint8List;

import 'package:flutter/services.dart';

const _channel = MethodChannel('ai.bithuman.avatar');

/// One loaded avatar. Owns a native texture; render with
/// `Texture(textureId: avatar.textureId)`.
class BithumanAvatar {
  BithumanAvatar._(this.textureId);

  /// Flutter texture id — pass to `Texture(textureId: ...)`.
  final int textureId;

  bool _disposed = false;

  /// Load an `.imx` model from a local file path.
  static Future<BithumanAvatar> load(String imxPath) async {
    final id = await _channel.invokeMethod<int>('load', {'path': imxPath});
    if (id == null) throw const BithumanAvatarException('load returned null');
    return BithumanAvatar._(id);
  }

  /// Push 16 kHz mono int16 PCM. Native side schedules `tick_compose` at
  /// 25 fps as the queue drains; new frames flow into the texture
  /// automatically.
  Future<void> pushAudio(Int16List pcm) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('pushAudio', {
      'textureId': textureId,
      'pcm': pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes),
    });
  }

  /// Start the unified VP-IO audio engine on the platform side. Owns
  /// mic capture (returned via [micStream]) AND speaker playback (fed
  /// via [playSpeakerPCM]) in a single AVAudioEngine with Apple's Voice
  /// Processing I/O enabled. This is what gives you:
  ///   - Acoustic echo cancellation: bot's voice is subtracted from
  ///     the mic input → no self-talk feedback loop
  ///   - Sample-accurate A/V sync: speaker and avatar lipsync drain
  ///     from the SAME source buffer at the SAME instant
  /// Must be called before [playSpeakerPCM] or [micStream] yield data.
  Future<void> audioStart() async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('audioStart', {'textureId': textureId});
  }

  /// Tear down the VP-IO audio engine. Mic tap stops; pending speaker
  /// buffers are discarded.
  Future<void> audioStop() async {
    if (_disposed) return;
    await _channel.invokeMethod('audioStop', {'textureId': textureId});
  }

  /// Cut the agent off mid-sentence. Flushes the VP-IO player's
  /// scheduled-buffer queue (so the speaker stops within ~10 ms) and
  /// wipes the avatar's lipsync audio buffer (so the mouth stops
  /// animating the cancelled response and returns to looping idle).
  /// Call from the Realtime session's `speech_started` handler so
  /// barge-in fires the instant the user opens their mouth, not at
  /// end-of-sentence.
  Future<void> interrupt() async {
    if (_disposed) return;
    await _channel.invokeMethod('interrupt', {'textureId': textureId});
  }

  /// Play 24 kHz mono PCM16 bot audio AND drive the avatar's lipsync
  /// from the same chunk. The native side schedules the buffer on the
  /// VP-IO player node and simultaneously pushes a 16 kHz copy into
  /// the avatar runtime — they share a clock so A/V cannot drift.
  Future<void> playSpeakerPCM(Uint8List pcm24kPcm16le) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('playSpeakerPCM', {
      'textureId': textureId,
      'pcm': pcm24kPcm16le,
    });
  }

  /// Echo-cancelled mic capture as 24 kHz mono PCM16 chunks. Yields
  /// only between [audioStart] and [audioStop]. Forward the chunks
  /// straight to OpenAI Realtime — VP-IO has already removed the
  /// bot's voice from the signal.
  Stream<Uint8List> get micStream {
    final ch = EventChannel('ai.bithuman.avatar.mic/$textureId');
    return ch.receiveBroadcastStream().map((event) {
      if (event is Uint8List) return event;
      if (event is List<int>) return Uint8List.fromList(event);
      return Uint8List(0);
    });
  }

  /// Attach the plugin's lipsync queue to OpenAI's bot-output audio
  /// flowing over a flutter_webrtc remote track. Android-only for
  /// now — the Kotlin side reflectively locates flutter_webrtc's
  /// `FlutterWebRTCPlugin.sharedSingleton`, fetches the underlying
  /// `org.webrtc.AudioTrack` for [trackId], and attaches an
  /// `AudioTrackSink` that downsamples to 16 kHz mono and pushes
  /// into the same audio queue [pushAudio] uses.
  ///
  /// **The source is the REMOTE WebRTC track only — the mic stream
  /// is never tapped.** That track on the bithuman WebRTC
  /// example is exclusively OpenAI's TTS output, so the avatar's
  /// mouth tracks what the user hears.
  ///
  /// Call AFTER [load] returns AND the WebRTC peer connection's
  /// `onTrack` callback has fired (so the track is registered with
  /// FlutterWebRTCPlugin). Pass `trackId = remoteAudioTrack.id`.
  /// Throws if the app doesn't actually ship flutter_webrtc.
  Future<void> attachWebrtcRemoteAudio(String trackId) async {
    if (_disposed) throw const BithumanAvatarException('avatar is disposed');
    await _channel.invokeMethod('attachWebrtcRemoteAudio', {
      'textureId': textureId,
      'trackId': trackId,
    });
  }

  /// Reverse of [attachWebrtcRemoteAudio] — also flushes any in-
  /// flight lipsync chunks so the mouth returns to idle when the
  /// session ends.
  Future<void> detachWebrtcRemoteAudio() async {
    if (_disposed) return;
    await _channel.invokeMethod('detachWebrtcRemoteAudio', {
      'textureId': textureId,
    });
  }

  /// Drop the underlying native runtime. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _channel.invokeMethod('dispose', {'textureId': textureId});
  }
}

class BithumanAvatarException implements Exception {
  const BithumanAvatarException(this.message);
  final String message;
  @override
  String toString() => 'BithumanAvatarException: $message';
}

/// One public agent from bithuman.ai/#explore.
class BithumanAgent {
  const BithumanAgent({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.imageUrl,
    required this.modelUrl,
    required this.systemPrompt,
    required this.voiceId,
  });

  final String id;
  final String name;
  final String description;
  final String category;
  final String imageUrl;
  final String modelUrl;
  final String systemPrompt;
  final String voiceId;

  factory BithumanAgent.fromJson(Map<String, dynamic> j) => BithumanAgent(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        description: j['description'] as String? ?? '',
        category: j['category'] as String? ?? '',
        imageUrl: (j['image_url'] ?? j['poster'] ?? '') as String,
        modelUrl: (j['model_url'] ?? '') as String,
        systemPrompt: (j['system_prompt'] ?? j['prompt'] ?? '') as String,
        voiceId: (j['voice_id'] ?? '') as String,
      );
}

/// Fetch the public agent catalog from bithuman.ai.
///
/// Anonymous, no auth needed — these are the `visibility = public` agents
/// users see on https://www.bithuman.ai/#explore.
Future<List<BithumanAgent>> fetchPublicAgents({int limit = 60}) async {
  final url = Uri.parse(
      'https://www.bithuman.ai/api/agents?type=community&limit=$limit');
  final client = HttpClient();
  try {
    final req = await client.getUrl(url);
    final HttpClientResponse res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException(
          'bithuman.ai catalog HTTP ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    final j = jsonDecode(body) as Map<String, dynamic>;
    final list = (j['agents'] as List).cast<Map<String, dynamic>>();
    return list
        .where((a) => (a['model_url'] as String?)?.isNotEmpty ?? false)
        .map(BithumanAgent.fromJson)
        .toList(growable: false);
  } finally {
    client.close();
  }
}

/// Download `agent.modelUrl` into `<cacheDir>/<id>.imx`. Cached by id so
/// re-tapping the same avatar doesn't re-download. Creates the cache
/// directory if it doesn't exist (some platforms — especially macOS
/// sandbox — return a tmp path that hasn't been mkdir'd yet).
Future<String> downloadAgentImx(BithumanAgent agent, String cacheDir) async {
  final dir = Directory(cacheDir);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final local = File('$cacheDir/${agent.id}.imx');
  if (await local.exists() && (await local.length()) > 1024 * 1024) {
    return local.path;
  }
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(agent.modelUrl));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw BithumanAvatarException(
          '.imx download HTTP ${res.statusCode} from ${agent.modelUrl}');
    }
    // Stream to a `.partial` file then rename, so a cancelled / failed
    // download doesn't leave a half-baked file that passes the "size > 1 MB"
    // cache check next time.
    final tmp = File('${local.path}.partial');
    final sink = tmp.openWrite();
    try {
      await res.pipe(sink);
    } catch (e) {
      try { await tmp.delete(); } catch (_) {}
      rethrow;
    }
    await tmp.rename(local.path);
    // Validate the downloaded file before returning. An .imx must
    // start with the literal bytes "IMX\0" and be at least a few MB.
    final size = await local.length();
    if (size < 1024 * 1024) {
      await local.delete();
      throw BithumanAvatarException(
          'downloaded .imx is suspiciously small: $size bytes');
    }
    final magic = await local.openRead(0, 4).first;
    if (magic.length < 4 ||
        magic[0] != 0x49 || magic[1] != 0x4D ||
        magic[2] != 0x58 || magic[3] != 0x00) {
      await local.delete();
      throw BithumanAvatarException(
          'downloaded .imx has wrong magic header (expected "IMX\\0")');
    }
    return local.path;
  } finally {
    client.close();
  }
}

/// Plugin version stamp the native side reports for diagnostics.
Future<String?> nativeEngineVersion() async {
  return _channel.invokeMethod<String>('engineVersion');
}
