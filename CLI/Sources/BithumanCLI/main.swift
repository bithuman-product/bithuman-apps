// bithuman-cli — entry point.
//
// Everything substantive lives in sibling files in this target:
//
//   CLIArgs.swift      Mode + CLIArgs (parsed argv shape)
//   ArgParser.swift    parseArgs + per-flag hints + typo suggester
//   HelpText.swift     `--help` output
//   Resolvers.swift    voice / portrait / config builders
//   Auth.swift         fatalUsage + key-failure helpers
//   Modes/TextMode.swift     bootstrapText{,OpenAI}
//   Modes/VoiceMode.swift    bootstrapVoice{,OpenAI}
//   Modes/AvatarMode.swift   bootstrapVideo + Expression/Essence runners
//   Modes/Maintenance.swift  runCleanup + runDoctor
//   BithumanKey.swift  developer-key resolution
//   Keychain.swift     OpenAI key storage
//   SpendTracker.swift session billing meter
//
// The entry below just unbuffers stdio (so prompts and progress
// render in real time) and dispatches `parseArgs()`'s result to
// the right bootstrap. text/voice are async and hand off to
// `dispatchMain`; cleanup/doctor exit synchronously; avatar's
// `bootstrapVideo` calls `NSApplication.run()` and never returns.

import Foundation

setbuf(stdout, nil)
setbuf(stderr, nil)

let cliArgs = parseArgs()

// Top-level is non-async, so calling @MainActor functions requires
// asserting we're on the main thread (we are — this *is* main).
MainActor.assumeIsolated {
    switch cliArgs.mode {
    case .avatar:
        bootstrapVideo(cliArgs)  // never returns

    case .cleanup:
        runCleanup()  // synchronous, exits when done
        exit(0)

    case .doctor:
        runDoctor()
        exit(0)

    case .text, .voice:
        let args = cliArgs
        Task { @MainActor in
            do {
                switch args.mode {
                case .text:  try await bootstrapText(args)
                case .voice: try await bootstrapVoice(args)
                case .avatar, .cleanup, .doctor: break  // unreachable
                }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}
// dispatchMain services the Task above for text/voice modes; for
// video the bootstrapVideo call doesn't return so this is unreachable.
dispatchMain()
