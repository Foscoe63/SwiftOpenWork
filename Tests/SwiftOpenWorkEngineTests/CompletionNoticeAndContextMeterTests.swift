import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkStorage

/// Two things that only earn their place by staying quiet most of the time: a banner nobody asked
/// for is worse than no banner, and a meter that is always on screen stops being read.
final class CompletionNoticeAndContextMeterTests: XCTestCase {

    // MARK: - Completion notices

    private func notice(
        enabled: Bool = true,
        active: Bool = false,
        failed: Bool = false,
        duration: TimeInterval = 120,
        title: String = "Refactor the parser",
        summary: String? = "Done — updated three files."
    ) -> TurnCompletionNotifier.Notice? {
        TurnCompletionNotifier.notice(
            enabled: enabled,
            appIsActive: active,
            failed: failed,
            duration: duration,
            sessionTitle: title,
            summary: summary
        )
    }

    func testALongTurnFinishingInTheBackgroundIsAnnounced() throws {
        let result = try XCTUnwrap(notice())
        XCTAssertTrue(result.title.contains("Refactor the parser"), result.title)
        XCTAssertEqual(result.body, "Done — updated three files.")
    }

    /// Interrupting someone who is already watching the turn run is pure noise.
    func testNothingIsAnnouncedWhileTheAppIsInFront() {
        XCTAssertNil(notice(active: true))
    }

    func testTheSettingIsHonoured() {
        XCTAssertNil(notice(enabled: false))
    }

    /// A turn that finished before you could look away does not need a banner.
    func testAShortTurnIsNotAnnounced() {
        XCTAssertNil(notice(duration: 3))
    }

    /// …but a short turn that *broke* is exactly the one you want to hear about, because otherwise
    /// you come back in ten minutes to find nothing happened.
    func testAShortFailureIsStillAnnounced() throws {
        let result = try XCTUnwrap(notice(failed: true, duration: 3))
        XCTAssertTrue(result.title.hasPrefix("Turn failed"), result.title)
    }

    func testTheBodyFallsBackToTheDurationWhenThereIsNoSummary() throws {
        let result = try XCTUnwrap(notice(duration: 125, summary: nil))
        XCTAssertEqual(result.body, "Took 2m 5s.")
    }

    func testAMultiLineSummaryIsReducedToItsFirstRealLine() throws {
        let result = try XCTUnwrap(notice(summary: "\n\n   \nAll tests pass.\nDetails below."))
        XCTAssertEqual(result.body, "All tests pass.")
    }

    func testAnUntitledSessionStillGetsAReadableTitle() throws {
        let result = try XCTUnwrap(notice(title: "   "))
        XCTAssertTrue(result.title.contains("Chat"), result.title)
    }

    func testDurationsReadAsPeopleSayThem() {
        XCTAssertEqual(TurnCompletionNotifier.describe(45), "45s")
        XCTAssertEqual(TurnCompletionNotifier.describe(60), "1m")
        XCTAssertEqual(TurnCompletionNotifier.describe(605), "10m 5s")
    }

    // MARK: - Context meter

    private func message(promptTokens: Int) -> ChatMessage {
        ChatMessage(sessionId: "s", role: .assistant, content: "hi", promptTokens: promptTokens)
    }

    func testTheMeterUsesTheMostRecentTurnsPromptSize() throws {
        let meter = try XCTUnwrap(ContextMeter.forSession(
            [message(promptTokens: 1000), message(promptTokens: 9000)],
            contextWindow: 10_000
        ))
        XCTAssertEqual(meter.used, 9000)
        XCTAssertEqual(meter.fraction, 0.9, accuracy: 0.001)
    }

    /// A session with no reply yet has no honest number, and a character-count guess ignores the
    /// system prompt, the tool schemas, and every tool result the model actually saw.
    func testASessionWithNoRepliesShowsNothingRatherThanAGuess() {
        XCTAssertNil(ContextMeter.forSession([message(promptTokens: 0)], contextWindow: 10_000))
        XCTAssertNil(ContextMeter.forSession([], contextWindow: 10_000))
    }

    func testAModelWithNoDeclaredWindowShowsNothing() {
        XCTAssertNil(ContextMeter.forSession([message(promptTokens: 500)], contextWindow: 0))
    }

    /// Always-on furniture stops being read. It appears when it starts to matter.
    func testTheMeterStaysHiddenUntilTheWindowIsHalfFull() {
        XCTAssertTrue(ContextMeter(used: 10_000, limit: 128_000).isWorthShowing)
        XCTAssertFalse(ContextMeter(used: 0, limit: 128_000).isWorthShowing)
        XCTAssertTrue(ContextMeter(used: 70_000, limit: 128_000).isWorthShowing)
    }

    func testPressureRisesWithUse() {
        XCTAssertEqual(ContextMeter(used: 50, limit: 100).pressure, .comfortable)
        XCTAssertEqual(ContextMeter(used: 70, limit: 100).pressure, .filling)
        XCTAssertEqual(ContextMeter(used: 95, limit: 100).pressure, .tight)
    }

    /// Over-budget prompts happen; the bar must not claim more than full.
    func testFractionIsClampedAtFull() {
        XCTAssertEqual(ContextMeter(used: 200, limit: 100).fraction, 1.0, accuracy: 0.001)
    }

    func testTheTightWarningSaysWhatWillHappen() {
        let help = ContextMeter(used: 120_000, limit: 128_000).help
        XCTAssertTrue(help.contains("summarized away"), help)
        XCTAssertTrue(help.contains("new chat"), help)
    }

    func testTokenCountsAreAbbreviatedTheWayPeopleReadThem() {
        XCTAssertEqual(ContextMeter.abbreviate(840), "840")
        XCTAssertEqual(ContextMeter.abbreviate(9_500), "9.5k")
        XCTAssertEqual(ContextMeter.abbreviate(32_000), "32k")
        XCTAssertEqual(ContextMeter.abbreviate(128_000), "128k")
    }

    func testTheLabelNamesBothSides() {
        XCTAssertEqual(ContextMeter(used: 64_000, limit: 128_000).label, "64k / 128k")
    }
}
