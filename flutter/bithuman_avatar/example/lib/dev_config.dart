// Developer-demo configuration. The example app reads three things —
// an OpenAI API key, a bitHuman API secret, and a path to a .imx
// avatar file — and that's it. No sign-in, no gallery, no cloud
// fetch. Drop your credentials + model on the build command line:
//
//   flutter run -d macos \
//     --dart-define=OPENAI_API_KEY=sk-... \
//     --dart-define=BITHUMAN_API_SECRET=bh-... \
//     --dart-define=IMX_PATH=/absolute/path/to/avatar.imx
//
// You can also leave `IMX_PATH` empty and instead drop your .imx at
// the path printed in the first-run screen (under each platform's
// application support directory). That lets you swap models without
// rebuilding.
//
// Apache-2.0; (c) bitHuman.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class DevConfig {
  /// OpenAI Realtime API key. Provide via `--dart-define=OPENAI_API_KEY=…`.
  /// Required to start a voice session — empty value means the app will
  /// load the avatar but the mic button stays disabled with a hint.
  static const openaiApiKey = String.fromEnvironment('OPENAI_API_KEY');

  /// bitHuman API secret. Provide via `--dart-define=BITHUMAN_API_SECRET=…`.
  /// Currently unused by the example UI itself — the native plugin
  /// reads it via `BITHUMAN_API_SECRET` env var when libessence
  /// authenticates. Surfaced here for symmetry + future use (e.g.
  /// hitting `api.bithuman.ai` for usage metrics).
  static const bithumanApiSecret = String.fromEnvironment('BITHUMAN_API_SECRET');

  /// Explicit absolute path to a .imx avatar file. If set via
  /// `--dart-define=IMX_PATH=/abs/path`, takes precedence over the
  /// drop-in location below.
  static const imxPathOverride = String.fromEnvironment('IMX_PATH');

  /// Default voice used when starting an OpenAI Realtime session.
  /// Override per build with `--dart-define=VOICE=alloy` (or any of:
  /// alloy / ash / ballad / coral / echo / sage / shimmer / verse /
  /// marin / cedar). Runtime settings sheet can swap this per session.
  static const defaultVoice =
      String.fromEnvironment('VOICE', defaultValue: 'ash');

  /// Default system prompt the agent runs with. Override per build
  /// with `--dart-define=SYSTEM_PROMPT="…"`. Runtime settings sheet
  /// lets users edit it freely before starting a session.
  static const defaultSystemPrompt = String.fromEnvironment(
    'SYSTEM_PROMPT',
    defaultValue:
        'You are a friendly assistant. Keep replies short and warm.',
  );

  /// OpenAI Realtime model. Pin a snapshot for reproducible behaviour
  /// during demos. Override with `--dart-define=REALTIME_MODEL=…` or
  /// the `model` key in `config.json`.
  static const defaultModel = String.fromEnvironment(
    'REALTIME_MODEL',
    defaultValue: 'gpt-4o-realtime-preview-2024-12-17',
  );

  /// The 10 voices OpenAI Realtime currently exposes — surfaced as
  /// the chip set in the settings sheet.
  static const availableVoices = <String>[
    'alloy', 'ash', 'ballad', 'coral', 'echo',
    'sage', 'shimmer', 'verse', 'marin', 'cedar',
  ];

  /// Local VAD peak threshold (Int16 PCM amplitude, 0..32767). Above
  /// this the local barge-in fires. Tune per-device — laptop mics
  /// run quieter than phone mics. Override with
  /// `--dart-define=VAD_THRESHOLD=1500` or the `vad_threshold` key
  /// in config.json.
  static const defaultVadThreshold =
      int.fromEnvironment('VAD_THRESHOLD', defaultValue: 1500);

  /// Single source of truth for all tunable defaults — one JSON file
  /// in the application support dir alongside `avatar.imx`. Lets
  /// devs pin voice/prompt/model/keys/threshold without rebuilding.
  /// Settings-sheet edits ALSO write back to this file so changes
  /// survive relaunches.
  ///
  /// Schema (all keys optional):
  ///
  ///   {
  ///     "openai_api_key":     "sk-…",
  ///     "bithuman_api_secret": "bh-…",
  ///     "imx_path":           "/abs/path/to/avatar.imx",
  ///     "voice":              "ash",
  ///     "system_prompt":      "You are a friendly assistant…",
  ///     "model":              "gpt-4o-realtime-preview-2024-12-17",
  ///     "vad_threshold":      1500
  ///   }
  ///
  /// Resolution order (lowest priority → highest):
  ///   1. Hardcoded defaults in this file
  ///   2. `--dart-define` build flags
  ///   3. `config.json` (this method)
  ///   4. Runtime settings sheet (writes back here too)
  ///
  /// IMPORTANT: this file holds your dev secrets. Add it to your
  /// repo's `.gitignore` if you're going to commit the example.
  ///
  /// Returns an empty map if the file doesn't exist or is invalid.
  /// Never throws — bad config never breaks the demo.
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

  /// Persist a (partial) config patch to disk. Reads existing JSON,
  /// merges the patch (replacing only the keys you pass), and writes
  /// back atomically (`.partial` rename). Drops nulls so callers can
  /// clear a field with `{key: null}`. Never throws.
  static Future<void> writeConfigFile(Map<String, dynamic> patch) async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/config.json');
      Map<String, dynamic> merged = {};
      if (await f.exists()) {
        try {
          final body = jsonDecode(await f.readAsString());
          if (body is Map) merged = body.cast<String, dynamic>();
        } catch (_) {/* fall through with empty */}
      }
      for (final entry in patch.entries) {
        if (entry.value == null) {
          merged.remove(entry.key);
        } else {
          merged[entry.key] = entry.value;
        }
      }
      final tmp = File('${dir.path}/config.json.partial');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(merged));
      await tmp.rename(f.path);
    } catch (_) {/* swallowed — non-fatal */}
  }

  /// Path the developer should drop `config.json` at. Used by the
  /// first-run sheet and the settings sheet's footer hint.
  static Future<String> defaultConfigPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}/config.json';
  }

  /// Conventional drop-in location, resolved at runtime.
  ///   macOS sandbox: ~/Library/Containers/<bundle>/Data/Library/
  ///                  Application Support/<bundle>/avatar.imx
  ///   iOS:           <app sandbox>/Library/Application Support/avatar.imx
  ///   Android:       /data/data/<pkg>/files/avatar.imx
  /// The first-run screen prints the exact platform-specific path so
  /// developers know where to drop the file.
  static Future<String> defaultImxPath() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return '${dir.path}/avatar.imx';
  }

  /// Resolve the .imx the app should load.
  ///
  /// Returns null if no source resolves — the caller renders a
  /// first-run "drop your model here" screen with the conventional
  /// path. Resolution order matches the rest of the config layering:
  ///   1. `--dart-define=IMX_PATH=…`
  ///   2. `imx_path` key in config.json
  ///   3. `<application-support>/avatar.imx` drop-in
  static Future<String?> resolveImxPath() async {
    if (imxPathOverride.isNotEmpty && await File(imxPathOverride).exists()) {
      return imxPathOverride;
    }
    final cfg = await readConfigFile();
    final cfgPath = cfg['imx_path'];
    if (cfgPath is String && cfgPath.isNotEmpty && await File(cfgPath).exists()) {
      return cfgPath;
    }
    final fallback = await defaultImxPath();
    if (await File(fallback).exists()) return fallback;
    return null;
  }

  static bool get hasOpenAIKey => openaiApiKey.isNotEmpty;
}
