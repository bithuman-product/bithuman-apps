// Value resolvers — turn a parsed `CLIArgs` into the concrete
// objects that downstream session code consumes.
//
// `resolveVoice` maps the `--voice` argument (preset name OR
// audio file path) into a `VoiceSelection`. Path arguments trigger
// `resolveTranscript`, which transcribes via Apple Speech and
// caches the result alongside the audio file as a `.txt` sibling.
//
// `readInlineOrFile` handles the inline-or-`@path` shape used by
// `--prompt`.
//
// `makeConfig` builds the `VoiceChatConfig` that voice / text /
// avatar modes share. `resolvePortrait` converts the `--image`
// argument (preset name OR image path) into a URL the avatar mode
// can hand to the bundled portrait gallery.

import AppKit
import Foundation
import Speech
import bitHumanKit

@MainActor
func resolveVoice(_ args: CLIArgs) async -> VoiceSelection {
    guard let raw = args.voiceArg else {
        // No --voice → default persona (Einstein)'s calm-masculine Qwen3
        // preset, matching the default systemPrompt so all defaults
        // line up. Falls back to .default if the preset isn't in
        // the recognised list (defensive — the constant is in the
        // presetNames in practice).
        if let canonical = VoiceSelection.canonicalPreset(matching: DefaultEssenceAgent.qwen3Voice) {
            return .preset(canonical)
        }
        return .default
    }
    if let canonical = VoiceSelection.canonicalPreset(matching: raw) {
        return .preset(canonical)
    }
    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            fatalUsage("--voice file not readable: \(url.path)")
        }
        let transcript = await resolveTranscript(
            audioURL: url,
            locale: Locale(identifier: args.localeIdentifier)
        )
        return .clone(referenceAudio: url, transcript: transcript)
    }
    fatalUsage("""
        --voice '\(raw)' isn't a recognised preset and no file exists at that path.
          Valid presets: \(VoiceSelection.presetNames.joined(separator: ", "))
          Or supply a path to a 10–20 s mono audio file (WAV / AIFF / M4A).
        """)
}

@MainActor
func resolveTranscript(audioURL: URL, locale: Locale) async -> String {
    let sibling = audioURL.deletingPathExtension().appendingPathExtension("txt")
    if let cached = (try? String(contentsOf: sibling, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines), !cached.isEmpty {
        return cached
    }
    print("🎧 transcribing reference audio with Apple Speech…")
    do {
        let transcript = try await transcribeAudioFile(at: audioURL, locale: locale)
        try? transcript.write(to: sibling, atomically: true, encoding: .utf8)
        print("🎧 cached transcript → \(sibling.lastPathComponent)")
        return transcript
    } catch {
        fatalUsage("Couldn't auto-transcribe \(audioURL.lastPathComponent): \(error)")
    }
}

func readInlineOrFile(_ arg: String) -> String? {
    guard arg.hasPrefix("@") else {
        let s = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
    let path = (String(arg.dropFirst()) as NSString).expandingTildeInPath
    guard let contents = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        return nil
    }
    let s = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? nil : s
}

/// Actionable error string for the "user passed `--openai` but no
/// key is reachable" case. Replaces the bare "set OPENAI_API_KEY"
/// hint with a copy-paste-able set of fixes covering the three
/// places we look for the key (env var, saved file, paste in).
/// Construct a `BithumanHeartbeat` if a developer key is reachable
/// (env or saved file). Returns nil with a one-time hint when
/// neither is set so the user knows where to get one. Shared
/// between Expression and Essence cloud runners — only the
/// `billingType` and `tags` differ between the two.

@MainActor
func makeConfig(_ args: CLIArgs) -> VoiceChatConfig {
    var config = VoiceChatConfig()
    config.localeIdentifier = args.localeIdentifier
    if let raw = args.promptArg {
        guard let resolved = readInlineOrFile(raw) else {
            fatalUsage("--prompt: couldn't read '\(raw)'. Pass inline text or @path/to/file.txt.")
        }
        config.systemPrompt = resolved
    } else {
        // No --prompt → fall back to the default persona (Einstein) used by
        // the default Essence avatar, so text + voice + avatar modes
        // share one coherent character on first run. The avatar
        // Essence runner overrides this at .imx load time when the
        // .imx already encodes its own prompt; that path doesn't see
        // this fallback, so the override is fine.
        config.systemPrompt = DefaultEssenceAgent.systemPrompt
    }
    // Resolve the avatar API key in priority order — same as
    // BithumanKey.load():
    //   1. BITHUMAN_API_KEY env var
    //   2. ~/Library/Application Support/com.bithuman.cli/bithuman-api-key
    //   3. nil → dev-mode unmetered (auth service permits this for
    //      development; live cost / balance feedback won't surface)
    // Audio-only and text modes don't need this; only video mode
    // hits VoiceChat.start()'s API-key check. Setting it here for
    // all configs keeps the CLI consistent.
    if let key = BithumanKey.load() {
        config.apiKey = key
    }
    return config
}

@MainActor

func resolvePortrait(_ raw: String?) -> URL? {
    guard let raw else { return nil }
    // Bundled gallery first — preset names take precedence over a
    // (probably accidental) file at the same path.
    if let preset = PortraitGallery.presetURL(matching: raw) {
        return preset
    }
    let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    if FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            fatalUsage("--image: file at '\(url.path)' isn't readable.")
        }
        return url
    }
    fatalUsage("""
        --image '\(raw)' is neither a bundled preset nor a path on disk.
          Bundled presets: \(PortraitGallery.presetNames.joined(separator: ", "))
          Or pass a path to a portrait image (JPG / PNG / HEIC).
        """)
}

/// All async setup for `bithuman-cli video`. Called from the AppDelegate's
/// `applicationDidFinishLaunching` so it runs *after* NSApp.run() has
/// taken over the main thread — that's the only way the main-actor
/// dispatches inside `FramePump`'s render loop actually reach the
/// runloop. (Doing this from a top-level `try await` chain leaves the
/// main dispatch queue starved; every render hangs forever.)
///
/// **Dispatch.** When `--model <path>` is supplied we peek the file's
/// manifest via ``Bithuman/createRuntime(modelPath:)`` and route to
/// ``runEssenceVideoSession(args:modelPath:)`` for Essence `.imx`
/// files; Expression files (and the no-`--model` default, which uses
/// the bundled weights) fall through to the original code path
/// unchanged. Doing the peek-and-dispatch up here keeps the
/// Expression body byte-for-byte identical to commit 12 — important
/// for the "no regression" contract on this commit.
