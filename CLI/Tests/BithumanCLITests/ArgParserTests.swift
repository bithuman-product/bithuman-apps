// Tests for ArgParser.swift — typo suggester (Levenshtein-based)
// and the FlagHint / knownFlags surface.
//
// `parseArgs()` itself isn't unit-tested here because it reads
// `CommandLine.arguments` and calls `fatalUsage` (which `exit(2)`s).
// End-to-end behaviour for `parseArgs` lives in the smoke tests
// at `BinarySmokeTests.swift`, which spawn the built binary and
// check stderr.

import XCTest
@testable import BithumanCLI

final class ClosestMatchTests: XCTestCase {

    // MARK: - Levenshtein distance

    func test_levenshtein_identicalStrings_isZero() {
        XCTAssertEqual(levenshtein("voice", "voice"), 0)
        XCTAssertEqual(levenshtein("", ""), 0)
    }

    func test_levenshtein_emptyVsNonEmpty_isLength() {
        XCTAssertEqual(levenshtein("", "voice"), 5)
        XCTAssertEqual(levenshtein("voice", ""), 5)
    }

    func test_levenshtein_singleEdits() {
        XCTAssertEqual(levenshtein("voice", "voiced"), 1, "insertion")
        XCTAssertEqual(levenshtein("voice", "vice"), 1, "deletion")
        XCTAssertEqual(levenshtein("voice", "vooce"), 1, "substitution")
    }

    func test_levenshtein_multipleEdits() {
        // kitten → sitting: classic 3-edit example.
        XCTAssertEqual(levenshtein("kitten", "sitting"), 3)
    }

    func test_levenshtein_isCommutative() {
        let pairs: [(String, String)] = [
            ("voice", "vvoice"),
            ("--voice", "--vooice"),
            ("hello", "world"),
            ("a", "abc"),
        ]
        for (a, b) in pairs {
            XCTAssertEqual(levenshtein(a, b), levenshtein(b, a), "d(\(a),\(b)) != d(\(b),\(a))")
        }
    }

    // MARK: - closestMatch — the user-facing typo suggester

    func test_closestMatch_singleCharTypo_suggestsCanonical() {
        let candidates = ["--voice", "--locale", "--image"]
        XCTAssertEqual(closestMatch("--vvoice", in: candidates), "--voice", "duplicated char")
        XCTAssertEqual(closestMatch("--voicee", in: candidates), "--voice", "trailing extra")
        XCTAssertEqual(closestMatch("--voce", in: candidates), "--voice", "missing char")
    }

    func test_closestMatch_caseInsensitive() {
        let candidates = ["--voice", "--locale"]
        XCTAssertEqual(closestMatch("--VOICE", in: candidates), "--voice")
        XCTAssertEqual(closestMatch("--Locale", in: candidates), "--locale")
    }

    func test_closestMatch_returnsNilWhenTooFar() {
        let candidates = ["--voice"]
        // A 5-letter input vs 7-letter "--voice" with totally
        // different characters should exceed tolerance.
        XCTAssertNil(closestMatch("xyzzy", in: candidates))
    }

    func test_closestMatch_emptyInput_returnsNil() {
        XCTAssertNil(closestMatch("", in: ["--voice"]))
    }

    func test_closestMatch_emptyCandidates_returnsNil() {
        XCTAssertNil(closestMatch("--voice", in: []))
    }

    func test_closestMatch_picksBestAmongMultiple() {
        // Equal-distance ties resolve to whichever comes first in
        // the input order — by design, we want the canonical-list
        // ordering to win.
        let candidates = ["--voice", "--vooced", "--voicy"]
        let result = closestMatch("--voicee", in: candidates)
        XCTAssertNotNil(result)
        XCTAssertTrue(candidates.contains(result!))
    }

    // MARK: - knownFlags — parser/suggester contract

    func test_knownFlags_includesAllValueFlags() {
        for flag in ["--voice", "--locale", "--image", "--model",
                     "--identity", "--prompt", "--openai-model"] {
            XCTAssertTrue(knownFlags.contains(flag),
                          "knownFlags missing value flag \(flag) — parseArgs.switch and the typo suggester would drift")
        }
    }

    func test_knownFlags_includesBooleanFlags() {
        XCTAssertTrue(knownFlags.contains("--openai"))
        XCTAssertTrue(knownFlags.contains("--local"))
    }

    func test_knownFlags_includesHelp() {
        XCTAssertTrue(knownFlags.contains("--help"))
        XCTAssertTrue(knownFlags.contains("-h"))
    }
}

// MARK: - FlagHint surface

final class FlagHintTests: XCTestCase {

    /// The voice hint pulls live preset lists from the SDK; just
    /// smoke-test that all three backends appear in the assembled
    /// string so we don't ship a hint that's missing a row.
    func test_voiceHint_mentionsAllThreeBackends() {
        let hint = FlagHint.voice
        XCTAssertTrue(hint.contains("voice --local"), "missing local backend row")
        XCTAssertTrue(hint.contains("avatar"), "missing avatar backend row")
        XCTAssertTrue(hint.contains("--openai"), "missing OpenAI backend row")
    }

    func test_voiceHint_mentionsCloningPath() {
        XCTAssertTrue(FlagHint.voice.contains("path"),
                      "voice hint should mention path-based cloning")
    }

    func test_imageHint_mentionsBundledPresets() {
        let hint = FlagHint.image
        for preset in ["Alice", "Marco", "Captain", "Nia", "Riley"] {
            XCTAssertTrue(hint.contains(preset), "missing preset \(preset)")
        }
    }

    func test_imageHint_mentionsSupportedFormats() {
        XCTAssertTrue(FlagHint.image.contains("JPG"))
        XCTAssertTrue(FlagHint.image.contains("PNG"))
        XCTAssertTrue(FlagHint.image.contains("HEIC"))
    }

    func test_localeHint_listsCommonBCP47Codes() {
        let hint = FlagHint.locale
        for code in ["en-US", "ja-JP", "zh-CN"] {
            XCTAssertTrue(hint.contains(code), "missing common BCP-47 code \(code)")
        }
    }

    func test_promptHint_showsBothInlineAndFileForms() {
        let hint = FlagHint.prompt
        XCTAssertTrue(hint.contains("--prompt \""), "missing inline-string form")
        XCTAssertTrue(hint.contains("@/path"), "missing @path form")
    }

    func test_modelHint_pointsAtSignupURL() {
        XCTAssertTrue(FlagHint.model.contains(".imx"))
        XCTAssertTrue(FlagHint.model.contains("bithuman.ai"))
    }
}
