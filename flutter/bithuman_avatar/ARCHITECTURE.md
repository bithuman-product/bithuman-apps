# bithuman_avatar — Flutter plugin architecture

One Flutter package + example app that runs the bitHuman avatar engine
on iOS, Android, macOS, Linux, and Windows from a single Dart codebase.
Web is a deliberate phase-2 target (needs WASM build of libessence or
a remote `bithuman avatar` server backend).

## Layers

```
┌─────────────────────────────────────────────────────────────────┐
│ example/lib/main.dart                                           │
│  - Full-screen avatar Texture                                   │
│  - Bottom-sheet picker over bithuman.ai/api/agents              │
│  - OpenAI Realtime (PTT or always-listen)                       │
│  - All UI in pure Dart; runs unchanged on every platform        │
└─────────────────────────────────────────────────────────────────┘
                              │ Dart
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│ lib/bithuman_avatar.dart      (plugin entrypoint)               │
│  BithumanAvatar.load(imxPath) -> BithumanAvatar                 │
│   .textureId             // for Texture(textureId: …)           │
│   .pushAudio(Float32List) // 16 kHz mono                        │
│   .dispose()                                                    │
│                                                                 │
│  Future<List<Agent>> fetchPublicAgents()                        │
│   // GET https://www.bithuman.ai/api/agents?type=community      │
└─────────────────────────────────────────────────────────────────┘
                              │ MethodChannel + Pigeon
                              ▼
┌────────────────────┬────────────────────┬───────────────────────┐
│ ios/Classes/        │ android/.../kotlin/ │ macos/Classes/        │
│ Swift plugin        │ Kotlin plugin       │ Swift plugin          │
│ libessence.xcfwk    │ ai.bithuman:sdk     │ libessence.xcfwk      │
│                     │ (Maven Central)     │ (macos-arm64 slice)   │
│ + FlutterTexture    │ + SurfaceTexture    │ + FlutterTexture      │
│ + CVPixelBuffer     │ + GL or Skia        │                       │
└────────────────────┴────────────────────┴───────────────────────┘
                              │
                              ▼
                  libessence engine (already shipping)
```

## Native delivery per platform

| Platform | libessence delivered as | Glue in this plugin |
|----------|--------------------------|---------------------|
| iOS device | `libessence.xcframework` (ios-arm64 slice) | vendored under `ios/Frameworks/` |
| iOS simulator | same xcframework (ios-arm64_x86_64-simulator slice) | same |
| macOS | same xcframework (macos-arm64 slice) | same |
| Android | `ai.bithuman:sdk:1.13.0` AAR (Maven Central) | Gradle dep |
| Linux | `libbithuman.so` (vendored tarball, same pattern as Linux CLI install.sh) | `linux/` CMake |
| Windows | not yet — CMake port gated in CI | future |
| Web | not yet — WASM build of libessence OR remote `bithuman avatar` server backend | future |

## Per-platform frame delivery

The avatar engine produces a BGR `uint8_t[w*h*3]` per tick at 25 fps.
Each platform's native side wraps that into the platform's GPU texture
format and notifies Flutter the texture has new content.

- **iOS / macOS**: `FlutterTexture` protocol — return a CVPixelBuffer
  (BGRA on `kCVPixelFormatType_32BGRA`). Native side pre-converts
  BGR→BGRA in place (skip the A channel). Flutter pulls via the
  `copyPixelBuffer()` callback.
- **Android**: `TextureRegistry.SurfaceTextureEntry` — upload BGR
  to GL_TEXTURE_2D in a background thread; call
  `surfaceTexture.updateTexImage()` from the Flutter render thread.
- **Linux**: Texture protocol via `FlPixelBufferTexture` — same as
  iOS but with GdkPixbuf as the in-flight wrapper.

## Method channel surface (Pigeon-generated)

```dart
@HostApi()
abstract class BithumanAvatarHost {
  int load(String imxPath);          // returns textureId
  void pushAudio(int textureId, Uint8List pcm16);
  void dispose(int textureId);
}
```

`pushAudio` takes int16-encoded PCM (matches what `flutter_sound` /
`record` capture from mic). Native side converts to f32 before
calling `be_runtime_tick_compose`.

Frames are produced internally on a 25-fps timer driven by the
amount of audio queued. When the audio queue empties the engine
pauses (no spurious compose calls).

## OpenAI Realtime integration

Two transport options:

1. **WebSocket direct** — Dart talks to `wss://api.openai.com/v1/realtime`
   with the user's API key. Audio in/out is PCM16 @ 24 kHz. We need a
   resampler 24→16 kHz to feed avatar's lip-sync input. Pure Dart, no
   native deps. **First implementation target.**
2. **WebRTC via `flutter_webrtc`** — lower latency, but needs OpenAI's
   WebRTC endpoint plus an ICE/SDP exchange. Defer to phase 2.

The avatar's audio-out and the speaker's audio-out are the SAME stream.
Native side splits the speaker output: 24 kHz → speaker (unchanged) +
24 kHz → 16 kHz resample → `pushAudio()` for lip-sync.

## Catalog browser

`fetchPublicAgents()` calls
`https://www.bithuman.ai/api/agents?type=community` (anonymous, public).
Response shape:

```json
{
  "success": true,
  "agents": [
    {
      "id": "A95SXN5716",
      "name": "Thrift Coach & Bargain Buddy",
      "image_url":  "https://…/thumbnail_….jpg",
      "model_url":  "https://…/model.imx",
      "system_prompt": "You are Lena Thrift, …",
      "voice_id":   "8e1d6fb4-…",
      …
    }, …
  ]
}
```

The picker grid renders `image_url` thumbnails. On tap we:
1. Download `model_url` → app's documents dir (cached by `id`).
2. Call `BithumanAvatar.load(localImxPath)`.
3. Update the Realtime session config with the agent's `system_prompt`.

## Build prerequisites

```sh
# Once, on the dev host:
flutter pub get
cd example && flutter pub get

# Run on iOS Simulator (uses ios-arm64_x86_64-simulator slice):
flutter run -d ios

# Run on iPhone (uses ios-arm64 slice):
flutter run -d <device-id>

# Run on macOS:
flutter run -d macos

# Run on Android device or emulator:
flutter run -d android
```

## Phasing — status as of v1.0

- **v0**  ✅ Dart API + plugin scaffold + catalog browser + tap-to-load.
- **v0.1** ✅ iOS native render path. `engine 1.13.0 (ABI 4)` confirmed on
  iPhone 17 Pro Simulator. Real libessence.xcframework binding, per-SDK
  OTHER_LDFLAGS, static framework so symbols carry to the app's link.
- **v0.2** ✅ OpenAI Realtime via WebSocket + mic capture (`record`) +
  speaker playback (`audioplayers` with WAV-wrapped PCM) + 24→16 kHz
  resample to avatar.pushAudio.
- **v0.3** ✅ Android plugin against `ai.bithuman:sdk:1.12.4` AAR (Maven
  Central, public). `engine 1.12.4 (ABI 4)` confirmed on emulator-5554.
  Bitmap+Canvas render to SurfaceTexture at 25 fps.
- **v0.4** ✅ macOS native path. `engine 1.13.0 (ABI 4)` confirmed on
  macOS host. macOS arm64 slice of libessence + Homebrew dylibs.
- **v1.0** ✅ README + this status doc + final ergonomics polish.

## Future targets (deliberately deferred)

- **Linux**: bundle libbithuman.so the same way the Linux CLI install.sh
  does (`bin/` + `lib/` layout with $ORIGIN/../lib RPATH).
- **Windows**: gated behind libessence's WINDOWS_CMAKE_PORTED flag —
  CMakeLists currently hardcodes Homebrew + PkgConfig paths.
- **Web**: needs either a WASM build of libessence or a remote
  `bithuman avatar` HTTP server backend. `kIsWeb` would branch between
  the native bundle path and the server path.

## How the plugin's "one source, three native bindings" trick works

The Dart `BithumanAvatar.load(path)` → MethodChannel("ai.bithuman.avatar")
fans out into three deliberate per-platform paths:

| Step | iOS / macOS | Android |
|------|-------------|---------|
| Open fixture | `be_fixture_load` via `import CLibessence` | `Fixture(path)` via `ai.bithuman:sdk` |
| Create runtime | `be_runtime_create` | `Runtime(fixture)` |
| Allocate texture handle | `FlutterTexture` (CVPixelBuffer producer) | `TextureRegistry.SurfaceTextureEntry` |
| 25-fps loop | `DispatchSourceTimer` on a serial queue | `ScheduledExecutorService` |
| Per tick | `be_runtime_tick_compose` → BGR → vImage BGR→BGRA → CVPixelBuffer | `runtime.tickCompose` → BGR → manual BGR→ARGB → `Bitmap.setPixels` → `Surface.lockCanvas` |
| Notify Flutter | `registry.textureFrameAvailable(id)` | implicit on `surface.unlockCanvasAndPost` |

Dart sees the same `int textureId` either way and renders with the
plain `Texture(textureId: id)` widget — same line of UI code works on
every platform.
