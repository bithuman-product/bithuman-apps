// `bithuman-cli cleanup` and `bithuman-cli doctor` — utility modes.
//
// `cleanup` removes regenerable caches (HF model weights, ANE
// compiled-graph cache, idle-frame cache, expression-extracted
// weights) after a `[y/N]` confirmation. API keys are deliberately
// preserved.
//
// `doctor` is read-only: prints CPU / RAM / disk / macOS version
// gates, the cached download inventory, and the resolved key
// state, so users can sanity-check the host before a long run.

import Foundation
import bitHumanKit

func runCleanup() {
    let home = NSString(string: "~").expandingTildeInPath
    let candidates = [
        "\(home)/.cache/huggingface",
        "\(home)/.cache/bithuman",
        // Stable per-`.imx` extracted weights (see ExpressionModel.makeWorkDirectory).
        // Surviving this cache is what keeps ANED's shader-compile
        // result reusable across launches; wiping it here is fine
        // because the user is asking for a cold-start anyway.
        "\(home)/Library/Caches/com.bithuman.expression-extracted",
        // ANE compiled-graph cache (com.apple.e5rt.e5bundlecache) +
        // URLCache that NSURLSession populates here — both regenerate
        // on next inference / next request, both can grow to ~1 GB.
        // Hosted under "bithuman/" because that's the process's
        // declared cache namespace; the OS doesn't move it for us.
        "\(home)/Library/Caches/bithuman",
        // Per-identity idle-frame palindrome cache (see
        // IdleFrameDiskCache). 12 MB per identity, regenerable
        // from the engine on next launch.
        "\(home)/Library/Application Support/com.bithuman.cli/idle-frames",
    ]

    print("\n  bithuman-cli cleanup\n")
    var present: [(path: String, size: Int64)] = []
    for path in candidates {
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let size = directorySize(path)
        present.append((path, size))
        print("    \(path)  \(formatBytes(size))")
    }
    if present.isEmpty {
        print("    (no caches found — nothing to clean)\n")
        return
    }
    let total = present.reduce(Int64(0)) { $0 + $1.size }
    print("\n    total: \(formatBytes(total))\n")
    print("    Delete these directories? [y/N] ", terminator: "")
    let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    if answer != "y" && answer != "yes" {
        // Leading \n covers the non-TTY case (piped stdin) where the
        // user's response doesn't echo + advance the cursor; without
        // it, "aborted." renders on the same line as the prompt.
        // In TTY mode a blank line before "aborted." is fine.
        print("\n    aborted.\n")
        return
    }
    for (path, _) in present {
        do {
            try FileManager.default.removeItem(atPath: path)
            print("    ✓ removed \(path)")
        } catch {
            print("    ✗ couldn't remove \(path): \(error.localizedDescription)")
        }
    }
    print("\n    done. Next `bithuman-cli` invocation will rebuild caches from scratch.\n")
}

/// `bithuman-cli doctor` — sanity-check the host before a long
/// download/load run. Surfaces issues that would otherwise show up
/// 5 minutes into a boot cycle: low disk, low RAM, x86_64
/// (Rosetta), wrong macOS version. Read-only — never modifies
/// state.
@MainActor
func runDoctor() {
    print("\n  bithuman-cli doctor — host capability check\n")

    // Pad the label to a fixed width so values column-align across
    // every host-info row. Width 19 fits the longest label
    // ("CPU architecture" and "bitHuman API key" — both 16 chars +
    // ":" + 2 spaces of breathing room).
    func label(_ text: String) -> String {
        "\(text):".padding(toLength: 19, withPad: " ", startingAt: 0)
    }

    let arch = currentArch()
    let archOK = (arch == "arm64")
    print("    \(archOK ? "✓" : "✗") \(label("CPU architecture"))\(arch)\(archOK ? "" : "  (Apple Silicon required)")")

    let osVer = ProcessInfo.processInfo.operatingSystemVersionString
    print("    ✓ \(label("macOS"))\(osVer)")

    let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    let ramOK = ramGB >= 16
    print("    \(ramOK ? "✓" : "!") \(label("RAM"))\(String(format: "%.1f GB", ramGB))\(ramOK ? "" : "  (16 GB recommended for video mode)")")

    let home = NSString(string: "~").expandingTildeInPath
    let freeBytes = freeDiskSpace(home)
    let freeGB = Double(freeBytes) / 1_073_741_824
    let diskOK = freeGB >= 10
    print("    \(diskOK ? "✓" : "!") \(label("Free disk"))\(String(format: "%.1f GB", freeGB))\(diskOK ? "" : "  (need ~10 GB for cold start)")")

    // OpenAI key — used by `--openai` cloud paths for text/voice/avatar.
    let openaiSource: String?
    if !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty {
        openaiSource = "env"
    } else if BithumanKeychain.loadOpenAIKey()?.isEmpty == false {
        openaiSource = "key file"
    } else {
        openaiSource = nil
    }
    print("    \(openaiSource != nil ? "✓" : "·") \(label("OpenAI API key"))\(openaiSource.map { "available (\($0))" } ?? "not set — voice/avatar/text will use --local")")

    // bitHuman key — used by avatar (Expression + Essence) for the
    // per-minute billing heartbeat to api.bithuman.ai. Sources, in
    // priority order:
    //   1. BITHUMAN_API_KEY env var
    //   2. ~/Library/Application Support/com.bithuman.cli/bithuman-api-key
    // Without either, avatar mode runs unmetered (the auth service
    // permits this for development) but live cost / balance feedback
    // won't surface.
    let bhSource: String?
    if !(ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"] ?? "").isEmpty {
        bhSource = "env"
    } else if let saved = try? String(contentsOf: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("com.bithuman.cli/bithuman-api-key"),
        encoding: .utf8),
        !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        bhSource = "key file"
    } else {
        bhSource = nil
    }
    print("    \(bhSource != nil ? "✓" : "✗") \(label("bitHuman API key"))\(bhSource.map { "available (\($0))" } ?? "not set — REQUIRED for avatar mode. Get one at https://www.bithuman.ai/#developer")")

    // Capability matrix — quickly resolve which modes / models the
    // host can actually run, so the user doesn't discover a hardware
    // gap five minutes into a download. Each row is independent;
    // cloud paths require the OpenAI key, on-device paths require
    // arm64 + macOS 26.
    let chip = appleSiliconBrand()    // e.g. "M5", "M3 Pro", or nil on x86
    let chipGen = appleSiliconGeneration() ?? 0
    print("\n    Capabilities:")
    if let chip = chip {
        let chipBadge = chipGen >= 3 ? "✓" : "!"
        let chipNote = chipGen >= 3 ? "" : "  (M3+ recommended for Expression avatar)"
        print("    \(chipBadge) Chip:              Apple \(chip)\(chipNote)")
    } else {
        print("    ✗ Chip:              non-Apple-Silicon — avatar + on-device LLM/TTS unavailable")
    }
    let onDeviceOK = archOK   // arm64 covers macOS 26 + Apple Silicon
    let cloudOpenAIOK = openaiSource != nil
    func row(_ icon: String, _ label: String, _ note: String) {
        print("    \(icon) \(label)\(note.isEmpty ? "" : "  — \(note)")")
    }

    // Asset cache probes — cheap fileExists checks against the
    // canonical locations each downloader writes to. Lets the
    // capability rows distinguish "✓ ready (cached)" from
    // "⬇ available, X MB on first run". No network round-trips.
    //
    // Essence has no auto-download default (see
    // DefaultEssenceAgent.swift for the history) — the user has to
    // bring their own `.imx`. Cache probe falls back to
    // `~/.cache/bithuman/models/sample-avatar.imx`, the well-known
    // local sample, so the row reflects whether at least *something*
    // is loadable today.
    let sampleEssenceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/bithuman/models/sample-avatar.imx")
    let essenceCached = FileManager.default.fileExists(atPath: sampleEssenceURL.path)
    let expressionCached = FileManager.default.fileExists(atPath: ExpressionWeights.localURL.path)
    // HF cache layout: ~/.cache/huggingface/hub/models--<org>--<name>/.
    // Existence of the org-name directory is a sufficient signal
    // for "first download completed" — HF hub never deletes
    // partial fetches, so a present dir means usable bytes.
    let hfHub = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    func hfCached(_ slashedRepo: String) -> Bool {
        let dirName = "models--" + slashedRepo.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.fileExists(
            atPath: hfHub.appendingPathComponent(dirName).path)
    }
    let kokoroCached = hfCached("mlx-community/Kokoro-82M-4bit")
    let qwen3TTSCached = hfCached("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit")
    let gemma3nCached = hfCached("mlx-community/gemma-3n-E2B-it-4bit")
    let voiceLocalCached = onDeviceOK && qwen3TTSCached && gemma3nCached
    let textLocalCached = onDeviceOK && gemma3nCached

    // Avatar Essence
    if !onDeviceOK {
        row("✗", "Avatar Essence (local):     ", "needs Apple Silicon")
    } else if essenceCached {
        row("✓", "Avatar Essence (local):     ", "ready — try: bithuman-cli avatar --identity ~/.cache/bithuman/models/sample-avatar.imx")
    } else {
        row("·", "Avatar Essence (local):     ", "needs --identity <agent.imx>; download one from your bitHuman dashboard")
    }

    // Avatar Expression
    if !onDeviceOK {
        row("✗", "Avatar Expression (local):  ", "needs Apple Silicon")
    } else if chipGen < 3 {
        row("!", "Avatar Expression (local):  ", "M3+ required for sustainable lipsync")
    } else if expressionCached {
        row("✓", "Avatar Expression (local):  ", "ready (engine cached)")
    } else {
        row("⬇", "Avatar Expression (local):  ", "available, ~1.56 GB engine on first run")
    }

    // Avatar cloud
    row(cloudOpenAIOK ? "✓" : "·", "Avatar (cloud lipsync):     ",
        cloudOpenAIOK ? "OpenAI Realtime + local lipsync tap" : "set OPENAI_API_KEY to enable")

    // Voice (local) — Gemma 3n + Qwen3-TTS + Kokoro
    if !onDeviceOK {
        row("✗", "Voice (local):              ", "needs Apple Silicon")
    } else if voiceLocalCached && kokoroCached {
        row("✓", "Voice (local):              ", "ready (LLM + TTS cached)")
    } else if voiceLocalCached || qwen3TTSCached || kokoroCached || gemma3nCached {
        row("⬇", "Voice (local):              ", "partially cached, remainder fetched on first run")
    } else {
        row("⬇", "Voice (local):              ", "available, ~5 GB on first run")
    }

    // Voice (cloud)
    row(cloudOpenAIOK ? "✓" : "·", "Voice (cloud):              ",
        cloudOpenAIOK ? "OpenAI Realtime over WebRTC" : "set OPENAI_API_KEY to enable")

    // Text (local) — Gemma 3n only
    if !onDeviceOK {
        row("✗", "Text (local):               ", "needs Apple Silicon")
    } else if textLocalCached {
        row("✓", "Text (local):               ", "ready (Gemma cached)")
    } else {
        row("⬇", "Text (local):               ", "available, ~2 GB on first run")
    }

    // Text (cloud)
    row(cloudOpenAIOK ? "✓" : "·", "Text (cloud):               ",
        cloudOpenAIOK ? "OpenAI Chat Completions" : "set OPENAI_API_KEY to enable")

    print("")
    if archOK && ramOK && diskOK {
        print("    All checks passed. Try one of:")
        print("")
        print("      bithuman-cli text           # type to chat")
        print("      bithuman-cli voice          # speak to chat (mic + speakers)")
        print("      bithuman-cli avatar --identity <agent.imx>")
        print("                                  # voice + animated face — needs an .imx")
        print("")
        print("    Common flags:")
        print("      --identity <agent.imx>      # any agent .imx (Expression or Essence)")
        print("      --image <path-or-preset>    # Expression with custom portrait")
        print("      --prompt 'be a pirate'      # override system prompt")
        print("      --voice <name|path>         # preset name, or audio path to clone (voice mode)")
        print("      --openai / --local          # force cloud or on-device backend")
        print("")
        if bhSource == nil {
            print("    ⚠️  Avatar mode requires a bitHuman API key. Without one,")
            print("       `bithuman-cli avatar` will refuse to start. Voice + text modes")
            print("       are unaffected. Grab a key at https://www.bithuman.ai/#developer")
            print("       and either:")
            print("          export BITHUMAN_API_KEY=...")
            print("          # or save it to the 0600 key file:")
            print("          echo \"<key>\" > ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key")
            print("          chmod 600 ~/Library/Application\\ Support/com.bithuman.cli/bithuman-api-key")
            print("")
        }
    } else {
        print("    Some checks didn't pass — see notes above.\n")
    }
}

/// Recursive directory-size walk. Used by `runCleanup`.
func directorySize(_ path: String) -> Int64 {
    var total: Int64 = 0
    let enumerator = FileManager.default.enumerator(atPath: path)
    while let entry = enumerator?.nextObject() as? String {
        let full = "\(path)/\(entry)"
        if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
           let size = attrs[.size] as? NSNumber {
            total += size.int64Value
        }
    }
    return total
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: "%.1f %@", value, units[unit])
}

func freeDiskSpace(_ path: String) -> Int64 {
    do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: path)
        if let bytes = attrs[.systemFreeSize] as? NSNumber {
            return bytes.int64Value
        }
    } catch {}
    return 0
}

func currentArch() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let machine = withUnsafePointer(to: &sysinfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) {
            String(cString: $0)
        }
    }
    return machine
}

/// Read `machdep.cpu.brand_string` and try to extract the Apple
/// Silicon generation as an integer (M1 → 1, M3 Pro → 3, M5 Max
/// → 5). Returns nil on Intel / unknown chips. Used to recommend
/// Expression vs Essence: M4+ silicon handles the Expression DiT
/// pipeline at ~25 fps comfortably, M3 and earlier may be choppy
/// and benefit from the lighter Essence runtime.
func appleSiliconGeneration() -> Int? {
    var size: size_t = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    let brand = String(cString: buf)
    // Patterns: "Apple M1", "Apple M2 Pro", "Apple M3 Max",
    // "Apple M4", "Apple M5 Pro", etc. Find the digit right after
    // " M" and return it as an Int.
    guard let mIdx = brand.range(of: " M")?.upperBound else { return nil }
    let tail = brand[mIdx...]
    let digits = tail.prefix(while: { $0.isNumber })
    return Int(digits)
}

/// Brand-string fragment for display ("M5", "M3 Pro", "M4 Max").
/// Strips the "Apple " prefix and any trailing whitespace, returns
/// nil on Intel hosts where the sysctl returns an x86 brand instead.
func appleSiliconBrand() -> String? {
    var size: size_t = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    let brand = String(cString: buf).trimmingCharacters(in: .whitespaces)
    // Apple chip strings start "Apple M…". Anything else is Intel
    // (or future/unknown silicon) — return nil so callers fall
    // through to the generic ✗ row.
    guard brand.hasPrefix("Apple M") else { return nil }
    let stripped = brand.replacingOccurrences(of: "Apple ", with: "")
    return stripped.isEmpty ? nil : stripped
}

/// One-line hint about whether the user's hardware is well-suited
/// to the default video pipeline. Printed at the top of video mode
/// boot when relevant. Returns nil if there's nothing useful to
/// say (M4+ on Expression is the happy path; no hint needed).
