// Tests for Resolvers.swift — pure logic only.
//
// `resolveVoice` and `resolveTranscript` aren't covered here:
// `resolveVoice` calls into the SDK's `VoiceSelection.canonicalPreset`
// (well-tested upstream), and `resolveTranscript` invokes Apple
// SpeechAnalyzer on a real audio file. The interesting branching
// in `resolveVoice` (preset hit / file hit / fatalUsage on miss)
// is exercised end-to-end by the binary smoke tests.
//
// `readInlineOrFile` is genuine pure logic with both code paths
// reachable from tests, so it gets full coverage here.

import XCTest
@testable import BithumanCLI

final class ReadInlineOrFileTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BithumanCLITests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        tmpDir = nil
        super.tearDown()
    }

    // MARK: - Inline-string branch

    func test_inlineString_returnsTrimmed() {
        XCTAssertEqual(readInlineOrFile("hello"), "hello")
        XCTAssertEqual(readInlineOrFile("  hello  "), "hello")
        XCTAssertEqual(readInlineOrFile("hello\nworld"), "hello\nworld")
    }

    func test_inlineString_emptyOrWhitespace_returnsNil() {
        XCTAssertNil(readInlineOrFile(""))
        XCTAssertNil(readInlineOrFile("   "))
        XCTAssertNil(readInlineOrFile("\n\t  \n"))
    }

    func test_inlineString_withSentence_preserved() {
        let prompt = "You are a helpful assistant. Be concise."
        XCTAssertEqual(readInlineOrFile(prompt), prompt)
    }

    // MARK: - @path branch

    func test_atPath_existingFile_returnsContents() throws {
        let file = tmpDir.appendingPathComponent("prompt.txt")
        try "you are einstein".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(readInlineOrFile("@\(file.path)"), "you are einstein")
    }

    func test_atPath_existingFile_trimsWhitespace() throws {
        let file = tmpDir.appendingPathComponent("padded.txt")
        try "  \n  prompt content  \n\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(readInlineOrFile("@\(file.path)"), "prompt content")
    }

    func test_atPath_emptyFile_returnsNil() throws {
        let file = tmpDir.appendingPathComponent("empty.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(readInlineOrFile("@\(file.path)"))
    }

    func test_atPath_whitespaceOnlyFile_returnsNil() throws {
        let file = tmpDir.appendingPathComponent("ws.txt")
        try "   \n\t\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(readInlineOrFile("@\(file.path)"))
    }

    func test_atPath_missingFile_returnsNil() {
        XCTAssertNil(readInlineOrFile("@/no/such/file/anywhere.txt"))
    }

    func test_atPath_tildeExpansion() throws {
        // Drop a file under HOME and reference it via `~`. The
        // CI runner will have $HOME set; we never touch it.
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let file = homeURL.appendingPathComponent(".bithuman-cli-test-\(UUID().uuidString).txt")
        try "tilde-expanded content".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let relativePath = "~/" + file.lastPathComponent
        XCTAssertEqual(readInlineOrFile("@\(relativePath)"), "tilde-expanded content")
    }
}

// MARK: - Mode rawValue contract

final class ModeTests: XCTestCase {

    func test_modeRawValues_acceptCanonicalSubcommands() {
        XCTAssertEqual(Mode(rawValue: "text"), .text)
        XCTAssertEqual(Mode(rawValue: "voice"), .voice)
        XCTAssertEqual(Mode(rawValue: "avatar"), .avatar)
        XCTAssertEqual(Mode(rawValue: "cleanup"), .cleanup)
        XCTAssertEqual(Mode(rawValue: "doctor"), .doctor)
    }

    func test_modeRawValues_rejectUnknownSubcommands() {
        XCTAssertNil(Mode(rawValue: "video"),
                     "video is the legacy alias; parseArgs translates it before constructing Mode")
        XCTAssertNil(Mode(rawValue: "VIDEO"))
        XCTAssertNil(Mode(rawValue: "Voice"), "Mode rawValue is case-sensitive — parseArgs lowercases first")
        XCTAssertNil(Mode(rawValue: ""))
        XCTAssertNil(Mode(rawValue: "garbage"))
    }

    func test_cliArgsDefaults() {
        let args = CLIArgs()
        XCTAssertEqual(args.mode, .voice, "bare bithuman-cli should default to voice")
        XCTAssertEqual(args.localeIdentifier, "en-US")
        XCTAssertNil(args.voiceArg)
        XCTAssertNil(args.promptArg)
        XCTAssertNil(args.imageArg)
        XCTAssertNil(args.identityArg)
        XCTAssertNil(args.modelArg)
        XCTAssertFalse(args.openAI)
        XCTAssertFalse(args.local)
        XCTAssertEqual(args.openAIModel, "gpt-realtime-mini")
    }
}
