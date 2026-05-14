// Dev config — same shape as the sibling example/ app. Resolves
// OpenAI / bitHuman keys + an .imx path the user has dropped at the
// Android application support dir.
//
// Apache-2.0; (c) bitHuman.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class DevConfig {
  static const openaiApiKey = String.fromEnvironment('OPENAI_API_KEY');
  static const bithumanApiSecret =
      String.fromEnvironment('BITHUMAN_API_SECRET');
  static const imxPathOverride = String.fromEnvironment('IMX_PATH');
  static const defaultModel =
      String.fromEnvironment('REALTIME_MODEL', defaultValue: 'gpt-realtime');
  static const defaultVoice =
      String.fromEnvironment('VOICE', defaultValue: 'ash');
  static const defaultSystemPrompt = String.fromEnvironment(
    'SYSTEM_PROMPT',
    defaultValue:
        'You are a friendly assistant. Keep replies short and warm.',
  );

  static Future<Map<String, dynamic>> readConfigFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/config.json');
      if (!await f.exists()) return const {};
      final body = jsonDecode(await f.readAsString());
      if (body is Map) return body.cast<String, dynamic>();
      return const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<String> defaultImxPath() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return '${dir.path}/avatar.imx';
  }

  static Future<String?> resolveImxPath() async {
    if (imxPathOverride.isNotEmpty &&
        await File(imxPathOverride).exists()) {
      return imxPathOverride;
    }
    final cfg = await readConfigFile();
    final cfgPath = cfg['imx_path'];
    if (cfgPath is String &&
        cfgPath.isNotEmpty &&
        await File(cfgPath).exists()) {
      return cfgPath;
    }
    final fallback = await defaultImxPath();
    if (await File(fallback).exists()) return fallback;
    return null;
  }
}
