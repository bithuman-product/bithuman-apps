// Tests for SpendTracker.swift — rate-card constants and the
// AvatarRuntime → credits/min mapping.
//
// The 60-second tick loop, USD formatting, and TerminalUI plumbing
// aren't exercised here — those are time-driven and need the
// terminal-attached UI. The numbers below are the load-bearing
// part: a wrong rate maps directly to wrong invoices, so we
// pin them.

import XCTest
@testable import BithumanCLI

final class SpendTrackerTests: XCTestCase {

    func test_expressionRuntime_billsTwoCreditsPerMinute() {
        XCTAssertEqual(SpendTracker.AvatarRuntime.expression.creditsPerMinute, 2)
    }

    func test_essenceRuntime_billsOneCreditPerMinute() {
        XCTAssertEqual(SpendTracker.AvatarRuntime.essence.creditsPerMinute, 1)
    }

    func test_expressionRuntime_labelMatchesUserFacingName() {
        XCTAssertEqual(SpendTracker.AvatarRuntime.expression.label, "Expression")
    }

    func test_essenceRuntime_labelMatchesUserFacingName() {
        XCTAssertEqual(SpendTracker.AvatarRuntime.essence.label, "Essence")
    }

    func test_bitHumanCreditDollarRate() {
        // 100 credits = $1.00. Update only when the published rate
        // card changes, never as a routine refactor.
        XCTAssertEqual(SpendTracker.bitHumanUSDPerCredit, 0.01, accuracy: 1e-9)
    }

    func test_openAIRealtimePerMinuteRate_isPositiveAndPlausible() {
        // The exact rate is provider-quoted; we just ensure it's a
        // sane non-zero ballpark so a regression to 0 (or 60) gets
        // caught fast.
        XCTAssertGreaterThan(SpendTracker.openAIRateUSDPerMinute, 0.001)
        XCTAssertLessThan(SpendTracker.openAIRateUSDPerMinute, 1.0)
    }
}

// MARK: - BithumanKey constants

final class BithumanKeyTests: XCTestCase {

    func test_signupURL_pointsAtDeveloperSection() {
        XCTAssertEqual(BithumanKey.signupURL, "https://www.bithuman.ai/#developer")
    }

    /// `BithumanKey.load()` reads $BITHUMAN_API_KEY first. We can't
    /// safely round-trip the file path in a hermetic test (that would
    /// stomp the user's real key), but we can verify the env-var
    /// branch by setting it in-process and asserting load() returns
    /// what we set.
    func test_load_envVar_takesPrecedenceOverFile() {
        let sentinel = "test-key-\(UUID().uuidString)"
        let prior = ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"]

        setenv("BITHUMAN_API_KEY", sentinel, 1)
        defer {
            if let prior {
                setenv("BITHUMAN_API_KEY", prior, 1)
            } else {
                unsetenv("BITHUMAN_API_KEY")
            }
        }

        XCTAssertEqual(BithumanKey.load(), sentinel)
    }

    /// Empty env var falls through (the docstring promises this so
    /// callers running with `BITHUMAN_API_KEY=` don't pretend they
    /// have a key).
    func test_load_emptyEnvVar_fallsThrough() {
        let prior = ProcessInfo.processInfo.environment["BITHUMAN_API_KEY"]
        setenv("BITHUMAN_API_KEY", "", 1)
        defer {
            if let prior {
                setenv("BITHUMAN_API_KEY", prior, 1)
            } else {
                unsetenv("BITHUMAN_API_KEY")
            }
        }
        // Result is whatever the file fallback returns — could be a
        // real key on a developer machine. We only assert that the
        // empty env var didn't pretend to be a key.
        XCTAssertNotEqual(BithumanKey.load(), "")
    }
}
