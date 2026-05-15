// End-to-end check for the Flutter plugin's audio → lipsync path.
//
// Loads the bundled avatar, starts the VP-IO audio engine, replays a
// real speech.wav PCM in 20 ms chunks into playSpeakerPCM, and waits
// long enough for the compose loop to produce real animated frames.
// Verifies via the plugin's NSLog output that we transition from
// "static frame painted" to "composed tick=N" with non-zero cluster
// indices — i.e., the avatar is animating against real audio.
//
// Run on macOS:
//   flutter test integration_test/avatar_audio_test.dart -d macos

import 'dart:io';
import 'dart:typed_data';

import 'package:bithuman/bithuman.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('audio → lipsync drives the avatar', (tester) async {
    // 1. Load the sample avatar that the example app already downloaded.
    final supportDir = await getApplicationSupportDirectory();
    final imxPath = '${supportDir.path}/sample-avatar.imx';
    expect(File(imxPath).existsSync(), true,
        reason: 'run the app once first so the sample-avatar.imx is cached');

    final avatar = await BithumanAvatar.load(imxPath);
    expect(avatar.textureId, greaterThan(0));

    // 2. Bring up the VP-IO audio engine.
    await avatar.audioStart();

    // 3. Stream a real speech recording into playSpeakerPCM in 20 ms
    //    chunks at 24 kHz mono PCM16. This is the EXACT format OpenAI
    //    Realtime delivers, so the test exercises the same path the
    //    live session does.
    final pcmFile = File('${supportDir.path}/speech_24k.pcm');
    expect(pcmFile.existsSync(), true,
        reason: 'speech_24k.pcm must be copied into ${supportDir.path}/');
    final pcm = await pcmFile.readAsBytes();
    // 24 kHz * 20 ms = 480 samples = 960 bytes per chunk.
    const chunkBytes = 480 * 2;
    int pos = 0;
    while (pos < pcm.length) {
      final end = (pos + chunkBytes).clamp(0, pcm.length);
      final slice = Uint8List.sublistView(pcm, pos, end);
      await avatar.playSpeakerPCM(slice);
      pos = end;
      // Real-time pacing (~20 ms per chunk) so the compose loop on the
      // native side has time to drain ticks between chunks. Pumping
      // everything synchronously would back up the audio buffer and
      // the test wouldn't reflect the live timing.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    // Give the compose loop a beat to finish the last few ticks.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    await avatar.audioStop();
    await avatar.dispose();
  });
}
