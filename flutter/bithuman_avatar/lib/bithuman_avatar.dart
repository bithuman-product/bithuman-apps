// bithuman_avatar — Flutter plugin entrypoint.
//
// One-package access to the bitHuman avatar engine across iOS, Android,
// macOS, and (planned) Linux/Windows/Web. See ARCHITECTURE.md for the
// per-platform delivery story.
//
// Apache-2.0; (c) bitHuman.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpClient, HttpClientResponse;
import 'dart:typed_data' show Int16List;

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
/// re-tapping the same avatar doesn't re-download.
Future<String> downloadAgentImx(BithumanAgent agent, String cacheDir) async {
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
    final sink = local.openWrite();
    await res.pipe(sink);
    return local.path;
  } finally {
    client.close();
  }
}

/// Plugin version stamp the native side reports for diagnostics.
Future<String?> nativeEngineVersion() async {
  return _channel.invokeMethod<String>('engineVersion');
}
