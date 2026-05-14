# bithuman_avatar

Render a bithuman avatar in your Flutter app, with optional OpenAI Realtime voice chat. macOS / iOS / Android.

---

`bithuman_avatar` wraps the native [libessence](https://github.com/bithuman-product/bithuman-sdk) runtime behind a Flutter `Texture` widget. One `.imx` model in, one full-bleed animated avatar out. The native side composites at ~1 ms / tick on Apple Silicon (Mac M3+, iPhone A17+), pre-decodes H.264 base frames once, caches them as JPEGs, and NEON-blends the lip-sync patch on every tick. Memory floor is ~120 MB on Mac, ~60 MB on iPhone.

A second class, `BithumanRealtimeSession`, is an optional helper that wires the avatar to OpenAI's Realtime API for full-duplex voice chat. The plugin owns a single VP-IO `AVAudioEngine` graph: Apple's Voice Processing I/O subtracts the bot's voice from the mic input (no self-talk feedback), the speaker and the avatar's lip-sync drain from the same chunk in the same instant (no A/V drift), and a client-side VAD on mic peak fires barge-in within ~50 ms when the user starts talking over the agent.

## Install

```yaml
dependencies:
  bithuman_avatar: ^0.0.1
```

For local development against a checkout:

```yaml
dependencies:
  bithuman_avatar:
    path: ../path/to/bithuman_avatar
```

## Minimum API — static avatar

```dart
import 'package:flutter/material.dart';
import 'package:bithuman_avatar/bithuman_avatar.dart';

class AvatarView extends StatefulWidget { const AvatarView({super.key}); @override State<AvatarView> createState() => _S(); }
class _S extends State<AvatarView> {
  BithumanAvatar? _a;
  @override void initState() {
    super.initState();
    BithumanAvatar.load('/path/to/your.imx').then((a) => setState(() => _a = a));
  }
  @override void dispose() { _a?.dispose(); super.dispose(); }
  @override Widget build(BuildContext c) =>
      _a == null ? const SizedBox() : Texture(textureId: _a!.textureId);
}
```

The avatar idles (breathing, blinks, slight head sway) with no audio pushed.

## Voice chat in 30 lines

```dart
import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:bithuman_avatar/bithuman_realtime.dart';

final avatar = await BithumanAvatar.load(imxPath);
final session = BithumanRealtimeSession(
  apiKey: const String.fromEnvironment('OPENAI_API_KEY'),
  avatar: avatar,
  systemPrompt: 'You are a friendly avatar host.',
  voice: 'alloy',
);

session.statusStream.listen((s) => debugPrint('status: $s'));
session.botTranscriptStream.listen((delta) => debugPrint('bot: $delta'));
session.userTranscriptStream.listen((t) => debugPrint('user: $t'));
session.micLevelStream.listen((lvl) {/* drive a mic pulse */});
session.botLevelStream.listen((lvl) {/* drive a speaking pulse */});

await session.start();   // opens WS + starts VP-IO mic+speaker
// ... conversation runs; barge-in is automatic ...
await session.stop();    // closes WS, tears down audio graph
await avatar.dispose();
```

`session.start()` brings the native audio engine up before the WebSocket so the first mic frame OpenAI sees is already echo-cancelled.

## Public Dart API

### `BithumanAvatar`

| Member | Purpose |
| --- | --- |
| `static load(imxPath)` | Load an `.imx` model from a local path. Returns a `BithumanAvatar` with a fresh `textureId`. |
| `textureId` | Pass to `Texture(textureId: ...)`. |
| `pushAudio(Int16List pcm)` | Push 16 kHz mono PCM16. Native side schedules `tick_compose` at 25 fps as the queue drains. |
| `audioStart()` | Start the unified VP-IO mic+speaker engine. AEC + sample-accurate A/V sync. |
| `audioStop()` | Tear down the audio engine. |
| `playSpeakerPCM(Uint8List pcm24kPcm16le)` | Play 24 kHz PCM16 through the speaker AND drive lip-sync from the same chunk. |
| `micStream` | Echo-cancelled mic capture as 24 kHz PCM16 chunks. Forward straight to OpenAI Realtime. |
| `interrupt()` | Cancel mid-sentence. Flushes the speaker queue + wipes the avatar's lip-sync buffer. |
| `dispose()` | Drop the native runtime. Idempotent. |

Plus catalog helpers (anonymous, no auth):

| Member | Purpose |
| --- | --- |
| `fetchPublicAgents({limit})` | Fetch the public agent catalog from bithuman.ai. |
| `downloadAgentImx(agent, cacheDir)` | Stream-download an agent's `.imx`, cached by id, magic-header-validated. |
| `nativeEngineVersion()` | Diagnostic version stamp from the native side. |

### `BithumanRealtimeSession`

| Member | Purpose |
| --- | --- |
| `BithumanRealtimeSession({apiKey, avatar, model, systemPrompt, voice})` | Construct. `model` defaults to `gpt-realtime` (OpenAI Realtime GA). |
| `start()` | Open WS, start VP-IO, begin forwarding mic. |
| `stop()` | Close WS, tear down audio. Single-use; build a new session for the next conversation. |
| `commitInputAudio()` | End-of-turn marker for non-VAD push-to-talk flows. |
| `applySettings({systemPrompt})` | Hot-update the system prompt mid-session (voice cannot be changed mid-call). |
| `muted` | When true, mic capture continues (needed for VP-IO reference) but bytes are not sent to OpenAI. |
| `statusStream` | `RealtimeStatus` events: connecting, open, userSpeaking, userStopped, responseDone, closed, error. |
| `botTranscriptStream` | Streaming partials of what the bot is saying. |
| `userTranscriptStream` | The user's transcribed speech (when OpenAI returns it). |
| `micLevelStream` | Mic peak in [0, 1] per ~85 ms chunk. |
| `botLevelStream` | Bot-audio peak in [0, 1] per chunk. |

The session auto-reconnects WS drops with 1/2/4/8/16/30 s backoff (cap 30 s, 8 attempts) before surfacing `RealtimeStatus.error`.

## Platform support

| Platform | Status |
| --- | --- |
| macOS (Apple Silicon, 13.0+) | shipped |
| iOS (device, 16.0+) | shipped (Release builds only — debug builds require `flutter run`) |
| Android | partial — audio + barge work with speakerphone routing; lipsync A/V sync still drifts on real-time bursts |

## What's bundled per platform

- **macOS**: links against a sibling-cloned `bithuman-sdk/cpp/build/libessence.a` plus a small set of Homebrew dylibs (`ffmpeg`, `hdf5`, `jpeg-turbo`, `webp`, `onnxruntime`). The example app's xcconfig wires `@rpath` so the dylibs resolve at launch. Run `brew install onnxruntime hdf5 jpeg-turbo webp ffmpeg` before first build.
- **iOS / Android**: target shape is fully-vendored binaries — a `bes.xcframework` for iOS and an AAR with prebuilt `.so` files for Android, pulling from the `bootstrap-deps-v1` tarballs published on the bithuman-sdk releases page. Not landed yet.

## Hardware floor

- **Mac**: Apple Silicon M3 or newer. Older Intel Macs and M1/M2 will run but are not benched.
- **iPhone**: A17 Pro or newer (iPhone 15 Pro and up). Validated on iPhone 17 Pro at 1.26 ms / tick paced, ~60 MB RSS.
- **Android**: Snapdragon 8 Gen 2 class or better. Validated on Galaxy Z Fold 5 at 3.10 ms / tick, ~140 MB RSS.

## License

Apache-2.0. Copyright bitHuman.
