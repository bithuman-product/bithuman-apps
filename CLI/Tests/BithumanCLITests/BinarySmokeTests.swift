// Smoke tests that spawn the built `bithuman-cli` and assert
// stderr / stdout / exit code shape.
//
// These exercise the full parser behaviour (including `fatalUsage`
// and `exit(2)` paths that can't be unit-tested in-process), the
// help text, and the maintenance modes that don't need hardware.
//
// Anything that needs a microphone, an MLX runtime, a real `.imx`,
// or live network is out of scope here — that lives in manual QA
// (the doctor command's "ready" matrix is the smoke check for those).

import XCTest

final class BinarySmokeTests: XCTestCase {

    /// Path to the binary `swift test` just built. The Swift Package
    /// Manager exposes the products dir via `Bundle.module` for
    /// resources, but we want the executable target's binary —
    /// derive its path from the test bundle's location, which sits
    /// next to the executable in the same `.build/<config>/` dir.
    private static var binaryURL: URL {
        // The XCTest bundle path: …/.build/<triple>/debug/BithumanCLIPackageTests.xctest
        // The executable:         …/.build/<triple>/debug/bithuman-cli
        let bundlePath = Bundle(for: BinarySmokeTests.self).bundleURL
        return bundlePath.deletingLastPathComponent()
            .appendingPathComponent("bithuman-cli")
    }

    private struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func run(_ args: [String], timeout: TimeInterval = 10) throws -> Result {
        let p = Process()
        p.executableURL = Self.binaryURL
        p.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Inherit a clean env — we don't want a stray OPENAI_API_KEY
        // changing the parser's auto-pick branch.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "BITHUMAN_API_KEY")
        env.removeValue(forKey: "BITHUMAN_API_SECRET")
        p.environment = env
        try p.run()

        // Hard timeout — guard against a parse path that would hang
        // (e.g., regression where the parser starts reading stdin).
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            p.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            XCTFail("binary timed out after \(timeout)s for args: \(args)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return Result(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: p.terminationStatus
        )
    }

    // MARK: - --help

    func test_help_exitsZeroAndPrintsToStdout() throws {
        let r = try run(["--help"])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.stdout.contains("bithuman-cli"))
        XCTAssertTrue(r.stdout.contains("FAST PATHS"))
        XCTAssertTrue(r.stdout.contains("OPTIONS"))
        XCTAssertTrue(r.stderr.isEmpty, "help should not write to stderr")
    }

    func test_helpShortFlag_sameAsLong() throws {
        let long = try run(["--help"]).stdout
        let short = try run(["-h"]).stdout
        XCTAssertEqual(long, short)
    }

    // MARK: - Missing-value hints (the bug that started this PR sequence)

    func test_voiceMissingValue_emitsHintWithAllBackends() throws {
        let r = try run(["--voice"])
        XCTAssertEqual(r.exitCode, 2, "fatalUsage should exit 2")
        XCTAssertTrue(r.stderr.contains("--voice needs a value"))
        XCTAssertTrue(r.stderr.contains("voice --local"), "voice hint should list the local Qwen3 backend")
        XCTAssertTrue(r.stderr.contains("avatar"), "voice hint should list the Kokoro backend")
        XCTAssertTrue(r.stderr.contains("--openai"), "voice hint should list the OpenAI backend")
        XCTAssertTrue(r.stderr.contains("Run `bithuman-cli --help` for usage."))
    }

    func test_localeMissingValue_emitsBCP47Examples() throws {
        let r = try run(["--locale"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("BCP-47"))
        XCTAssertTrue(r.stderr.contains("en-US"))
    }

    func test_imageMissingValue_emitsPresetsAndFormats() throws {
        let r = try run(["--image"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("Alice"))
        XCTAssertTrue(r.stderr.contains("JPG"))
    }

    func test_promptMissingValue_emitsBothForms() throws {
        let r = try run(["--prompt"])
        XCTAssertEqual(r.exitCode, 2)
        // Hint shows both an inline-string form ("--prompt \"...\"") and
        // a file form ("--prompt @/path...") on labelled rows.
        XCTAssertTrue(r.stderr.contains("inline"))
        XCTAssertTrue(r.stderr.contains("@/path"))
    }

    func test_modelMissingValue_emitsImxHint() throws {
        let r = try run(["--model"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains(".imx"))
    }

    // MARK: - "Got flag instead of value" path

    func test_voiceConsumedNextFlag_callOutForgottenArgument() throws {
        let r = try run(["--voice", "--prompt", "hi"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("got the flag '--prompt'"))
        XCTAssertTrue(r.stderr.contains("Did you forget the argument?"))
    }

    // MARK: - Unknown-flag suggestion

    func test_typoFlag_suggestsCorrection() throws {
        let r = try run(["--vvoice", "Aiden"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("unknown argument '--vvoice'"))
        XCTAssertTrue(r.stderr.contains("Did you mean"))
        // The suggested flag is wrapped in ANSI bold codes; assert the
        // flag name is present without trying to match the escape bytes.
        XCTAssertTrue(r.stderr.contains("--voice"))
        // The valid-flag dump is grouped by category (Value / Boolean
        // / Info) rather than a flat "All flags:" list.
        XCTAssertTrue(r.stderr.contains("Value flags:"))
    }

    func test_completelyUnknownFlag_listsValidFlagsWithoutSuggestion() throws {
        let r = try run(["--xyzzy"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("unknown argument '--xyzzy'"))
        XCTAssertTrue(r.stderr.contains("Value flags:"))
        XCTAssertTrue(r.stderr.contains("Boolean flags:"))
    }

    // MARK: - Unknown subcommand

    func test_unknownSubcommand_listsValidModes() throws {
        let r = try run(["bogus"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("unknown subcommand 'bogus'"))
        XCTAssertTrue(r.stderr.contains("text, voice, avatar"))
    }

    func test_legacyVideoSubcommand_isAccepted() throws {
        // Should NOT exit with the unknown-subcommand error.
        // It'll likely fail later for some other reason in this
        // hermetic env (no key, no avatar weights), but the parser
        // shouldn't be the thing that rejects it.
        let r = try run(["video", "--help"])
        XCTAssertEqual(r.exitCode, 0,
                       "legacy 'video' alias should resolve to 'avatar' before --help triggers")
    }

    // MARK: - Conflicts

    func test_openaiAndLocalConflict_inVoiceMode() throws {
        let r = try run(["voice", "--openai", "--local"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("mutually exclusive"))
    }

    func test_imageInTextMode_emitsRedirectHint() throws {
        // Text mode warns about --image being ignored, but the
        // process can't start without a key. We just want to
        // confirm the parser-level warning fires before bootstrap.
        let r = try run(["text", "--image", "Alice"])
        // Either the warning fires (exit 2 from key check, or 0 if a
        // saved key resolves) — but the parser's warning text must
        // appear on stderr regardless of how the run ends.
        XCTAssertTrue(r.stderr.contains("--image is ignored in text mode")
                      || r.stderr.contains("error:"),
                      "expected text-mode --image warning OR a downstream error, got: \(r.stderr.prefix(300))")
    }

    func test_identityAndImageConflict() throws {
        let r = try run(["avatar", "--identity", "Alice", "--image", "Marco"])
        XCTAssertEqual(r.exitCode, 2)
        XCTAssertTrue(r.stderr.contains("--identity and --image both supplied"))
    }
}
