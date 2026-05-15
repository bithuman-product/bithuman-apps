# bithuman — Flutter developer demo

Full-bleed avatar plus OpenAI Realtime voice chat from a single Dart entry
point. The native plugin owns an Apple VP-IO graph so the mic is
echo-cancelled and the speaker can never feed back into itself; bot PCM
chunks drive the speaker and the libessence lipsync queue in the same
instant so A/V cannot drift. Client-side VAD fires barge-in in ~50 ms,
the avatar loops a breathing-idle animation when nothing is happening,
captions stream from `response.audio_transcript.delta`, and the settings
sheet hot-applies voice / prompt / model edits.

## Quickstart

### All four surfaces at once

If you have a Mac, an iPhone, an iPad, and an Android device hooked up and
just want to deploy the same app to each in parallel:

```
scripts/run-all.sh
```

The script discovers everything reachable (this Mac always, then any
paired iPhone/iPad via `devicectl`, then any non-emulator Android via
`adb`), prints a status table, builds three artifacts in parallel
(macOS app / universal iOS bundle / Android APK), and installs +
launches on every detected target concurrently. Keys are picked up
from `~/.env` (`OPENAI_API_KEY=…`, `BITHUMAN_API_SECRET=…`). Logs land
in `/tmp/bithuman-run-all/`.

Useful flags:

| Flag                          | What it does                                    |
|-------------------------------|-------------------------------------------------|
| `--surfaces=macos,iphone`     | Subset (default: every reachable target)        |
| `--imx=/path/to/avatar.imx`   | Pre-positions this .imx into each mobile sandbox |
| `--skip-build`                | Reuse last build artifacts (fast re-launch)     |
| `--no-launch`                 | Build + install only (no foreground launch)     |

iPad and iPhone share a single universal iOS bundle — the same
`flutter build ios --release` artifact installs on both because the
Xcode project targets `TARGETED_DEVICE_FAMILY = 1,2`. The Flutter UI
auto-tunes for tablet via `MediaQuery.shortestSide >= 600` in
`lib/main.dart`.

### macOS

```
git clone https://github.com/bithuman/bithuman-apps
cd bithuman-apps/flutter/bithuman/example
flutter run -d macos \
  --dart-define=OPENAI_API_KEY=sk-... \
  --dart-define=BITHUMAN_API_SECRET=bh-... \
  --dart-define=IMX_PATH=/abs/path/to/avatar.imx
```

If you skip `IMX_PATH`, the first-run sheet prints the exact platform
path to drop a `.imx` at, then tap **Retry**.

### iPhone (iOS device)

Build in **release** mode (iOS 14+ blocks debug-mode standalone launches
without Flutter tooling attached, so `devicectl device process launch`
on a Debug `.app` exits with "Cannot create a FlutterEngine instance in
debug mode"):

```
flutter build ios --release \
  --dart-define=OPENAI_API_KEY=sk-... \
  --dart-define=BITHUMAN_API_SECRET=bh-...

# Install + pre-position .imx into the app sandbox
xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
xcrun devicectl device copy to \
  --device <UDID> --domain-type appDataContainer \
  --domain-identifier ai.bithuman.bithumanAvatarExample \
  --source ./avatar.imx --destination "Library/Application Support/avatar.imx"
xcrun devicectl device process launch --device <UDID> ai.bithuman.bithumanAvatarExample
```

If you want to debug from Flutter tools instead of installing release
mode, run `flutter run -d <UDID>` — but the app then needs the Flutter
service protocol attached for the lifetime of the run.

### Android

```
flutter run -d <android-device-id> \
  --dart-define=OPENAI_API_KEY=sk-... \
  --dart-define=BITHUMAN_API_SECRET=bh-...
```

Audio and barge work as of v0.5 (speakerphone routing is forced via
`MODE_IN_COMMUNICATION` + `setSpeakerphoneOn(true)` so the agent plays
through the loudspeaker, not the earpiece). Lipsync A/V sync may
visibly drift on bursty OpenAI replies — a chunk-paired emission
refactor is in progress.

## Config resolution order

Lowest priority first; later sources override earlier ones:

1. Hardcoded defaults in `lib/dev_config.dart`
2. `--dart-define=…` build flags
3. `config.json` in the application support directory
4. Settings-sheet edits (also written back to `config.json`)

`config.json` schema (all keys optional):

```json
{
  "openai_api_key":      "sk-...",
  "bithuman_api_secret": "bh-...",
  "imx_path":            "/abs/path/to/avatar.imx",
  "voice":               "ash",
  "system_prompt":       "You are a friendly assistant. Keep replies short and warm.",
  "model":               "gpt-realtime",
  "vad_threshold":       1500
}
```

The settings sheet writes patches back to this file on every edit, so
runtime tweaks survive relaunches. The footer of the **Advanced**
section in the sheet prints the resolved path for your platform with a
copy button.

> **Gitignore it.** `config.json` lives in your application support
> directory by default (outside the repo), but if you point it at a path
> inside the repo make sure it's listed in `.gitignore` — it stores your
> live API keys.

## Where to put your .imx

If you don't pass `--dart-define=IMX_PATH`, the app resolves to the
application support directory and looks for `avatar.imx`:

| Platform | Path |
|----------|------|
| macOS    | `~/Library/Containers/<bundle>/Data/Library/Application Support/<bundle>/avatar.imx` |
| iOS      | `<app sandbox>/Library/Application Support/avatar.imx` |
| Android  | `/data/data/<pkg>/files/avatar.imx` |

The first-run sheet prints the exact resolved path with a copy button.

## First run

If the resolver finds no `.imx`, the app boots to a single sheet that
prints the drop path, offers a Copy button, and shows a **Retry** button
that re-runs the resolver. If `OPENAI_API_KEY` is also missing, a yellow
hint card explains the mic button will stay disabled until you rebuild
with the flag set. Drop a file, tap Retry, talk.

## UI walkthrough

- **Avatar canvas** — full-bleed `Texture(textureId: avatar.textureId)`
  scaled `BoxFit.cover`. Tap to toggle chrome visibility; chrome
  auto-fades 6 s into an active session.
- **Primary button (centre)** — state-aware:
  - Idle: green mic icon
  - Connecting: amber spinner around the button
  - Open / user speaking: red hang-up icon, mint outer ring expanding
    in time with `micLevel` (peak per ~85 ms chunk)
  - Agent replying: red hang-up icon, blue outer ring expanding in time
    with `botLevel`
  - Error: red ring
- **Mic toggle (left of primary, only when active)** — mutes the WS
  upload. The native VP-IO graph keeps capturing so echo cancellation
  still has its reference signal.
- **CC toggle (right of primary)** — swaps the bottom band for a 168 px
  focus-mode caption panel that auto-scrolls with the streaming
  transcript.
- **Settings (top-right)** — voice chips, debounced system-prompt field
  (250 ms), and an **Advanced** disclosure with the Realtime model
  (locked while a call is live; OpenAI doesn't let you change it
  mid-session) and the `config.json` path hint.
- **Barge-in** — start talking while the agent is replying: the speaker
  cuts within ~10 ms, the lipsync queue is wiped and zeroed, the
  in-flight `response` is cancelled server-side. Feels instant.

## Platform support

| Platform | Status |
|----------|--------|
| macOS    | Shipping |
| iPhone   | Shipping |
| iPad     | Shipping (universal iOS bundle) |
| Android  | Shipping (lipsync A/V refinement in progress) |
| Web / Linux / Windows | Not yet |

## Architecture

```
                            +------------------------+
                            |   OpenAI Realtime API  |
                            +-----------+------------+
                                        ^
                                        | wss:// (PCM16 mono 24 kHz, b64-in-JSON)
                                        v
+-------------+   streams  +---------------------------+
| Flutter UI  +----------->|  BithumanRealtimeSession  |
|  main.dart  |<-----------|  (Dart, WebSocket only)   |
+-----+-------+   status   +-------------+-------------+
      |                                  | mic up / bot down
      | Texture(id)                      v
      |                    +---------------------------+
      |                    |   BithumanAvatar plugin   |
      +------------------->|  - Texture id from native |
                           |  - audioStart/Stop        |
                           |  - playSpeakerPCM         |
                           |  - micStream / interrupt  |
                           +-------+----------+--------+
                                   |          |
                            VP-IO  |          |  libessence
                                   v          v
                       +-----------+--+   +---+-----------+
                       | RealtimeAudio|   | native lipsync|
                       |   IO.swift   |   |  + texture FB |
                       +--------------+   +---------------+
```

A single `playSpeakerPCM` call drives both the speaker output node and
the avatar's lipsync queue, so audio and mouth motion can never drift.

## Common gotchas (already debugged, documented inline)

**9-channel mic downmix returns silence.** On Apple silicon with VP-IO
enabled, the input bus surfaces as 9 channels and `AVAudioConverter`'s
automatic N→1 downmix produces all zeros. Manually copy channel 0 to a
mono `Float32` buffer first, then resample. See
`macos/Classes/RealtimeAudioIO.swift` (`handleMicBuffer`).

**`Int16List.view` throws on odd `offsetInBytes`.** Flutter's
EventChannel can hand you a `Uint8List` whose backing buffer is unaligned
for 2-byte reads. Decoding little-endian Int16 pairs by hand avoids the
`RangeError` that was silently killing `_sendMicBytes` upstream of the
WS write. See `lib/bithuman_realtime.dart` (`_sendMicBytes`).

**Tap callbacks are NOT thread-safe.** `installTap` runs on the
realtime audio thread; calling `AVAudioPlayerNode.stop()` / `reset()` /
`scheduleBuffer()` from there does `dispatch_sync` onto the same queue
and traps. Hop to `DispatchQueue.main.async { … }` before touching
engine state. See `RealtimeAudioIO.swift` barge-in trigger.

**`AVAudioMixerNode` rejects Int16.** Connect the player at Float32 and
pre-convert by dividing each sample by 32768; connecting at Int16
produces a robotic "zzz" buzz. See `RealtimeAudioIO.swift`
(`playSpeakerPCM24k`).

## Hacking notes

- `lib/main.dart` — UI, state machine, settings-sheet plumbing
- `lib/dev_config.dart` — config resolution and `config.json` I/O
- `lib/bithuman_realtime.dart` — WebSocket + Realtime event loop +
  reconnect-with-backoff
- `lib/bithuman.dart` — plugin Dart API (texture, audioStart,
  playSpeakerPCM, micStream, interrupt)
- `macos/Classes/RealtimeAudioIO.swift` — AVAudioEngine + VP-IO graph,
  mic tap, speaker player, client-side barge-in
- `macos/Classes/BithumanPlugin.swift` — Flutter texture
  registration, libessence `tick_compose` pump

## License

Apache-2.0. (c) bitHuman.
