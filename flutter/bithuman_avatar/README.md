# bithuman_avatar — Flutter plugin

One Flutter plugin to render the bitHuman avatar engine across **iOS,
Android, and macOS** from a single Dart codebase. The example app is a
full-screen avatar that you can chat with over OpenAI Realtime; tap the
screen to swap the avatar from the public [bithuman.ai](https://www.bithuman.ai/#explore)
catalog.

## Status (v1.0)

| Platform | Engine bound | Tested on |
|----------|-------------:|-----------|
| iOS device     | ✅  1.13.0 | (build verified; on-device run pending devicectl tap) |
| iOS Simulator  | ✅  1.13.0 | iPhone 17 Pro sim, iOS 26.4 |
| macOS arm64    | ✅  1.13.0 | macOS 26.4 host |
| Android device | ✅  1.12.4 | (build verified) |
| Android emulator | ✅  1.12.4 | arm64-v8a AVD on android-29 |
| Linux          | 🟡 plugin-stub only |
| Windows        | 🟡 plugin-stub only |
| Web            | 🟡 plugin-stub only (needs WASM port or remote server backend) |

The engine pill in the example app reads the real `be_library_version()`
+ `be_abi_version()` on every platform with ✅.

## Try it (60 seconds)

```sh
git clone https://github.com/bithuman-product/bithuman-apps.git
cd bithuman-apps/flutter/bithuman_avatar/example
# Set your OpenAI key for the Realtime chat (optional for v0.4 visual test).
export OPENAI_API_KEY=sk-...

# iOS Simulator:
flutter run -d 'iPhone 17 Pro'  --dart-define OPENAI_API_KEY=$OPENAI_API_KEY

# Android (emulator or device):
flutter run -d emulator-5554    --dart-define OPENAI_API_KEY=$OPENAI_API_KEY

# macOS:
brew install onnxruntime hdf5 jpeg-turbo webp ffmpeg
flutter run -d macos            --dart-define OPENAI_API_KEY=$OPENAI_API_KEY
```

Tap anywhere → bottom-sheet picker fetches the public bithuman.ai
catalog → tap an agent → .imx downloads + loads → avatar fills the
screen. Tap the mic to start a Realtime conversation (uses the agent's
`system_prompt` for character voice).

## Workspace layout

The plugin's native sides link directly against the libessence engine
in a sibling repo. Clone the SDK next to the apps repo:

```
~/bithuman/
├── bithuman-apps/                 ← this repo
│   └── flutter/bithuman_avatar/   ← the plugin + example
└── bithuman-sdk/                  ← SDK (libessence sources + prebuilt static libs)
```

The plugin's `ios/Vendor/`, `macos/Vendor/`, and `ios/Frameworks/` are
symlinks into the sibling `bithuman-sdk/cpp/` — zero file copy. The
Android side pulls `ai.bithuman:sdk:1.12.4` from Maven Central (no
sibling repo needed for Android-only consumers).

## API surface (Dart)

```dart
import 'package:bithuman_avatar/bithuman_avatar.dart';
import 'package:bithuman_avatar/bithuman_realtime.dart';

// 1. Browse the public catalog (anonymous, public).
final agents = await fetchPublicAgents(limit: 60);
final pick = agents.first;

// 2. Download + load the .imx model.
final imxPath = await downloadAgentImx(pick, '/tmp/bithuman-cache');
final avatar = await BithumanAvatar.load(imxPath);

// 3. Render: just drop the texture into your widget tree.
Widget build(BuildContext _) => Texture(textureId: avatar.textureId);

// 4. Talk to it over OpenAI Realtime.
final session = BithumanRealtimeSession(
  apiKey: '<your-openai-key>',
  avatar: avatar,
  systemPrompt: pick.systemPrompt,
);
await session.start();
// session.sendMicChunk(pcm24kPcm16le) drives the conversation;
// the example app wires this from the `record` package.

// 5. Tear down.
await session.stop();
await avatar.dispose();
```

See `example/lib/main.dart` for the complete UI wiring.

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the per-platform delivery
story, frame-pipeline details, and OpenAI Realtime audio routing.

## License

Apache-2.0. © bitHuman.
