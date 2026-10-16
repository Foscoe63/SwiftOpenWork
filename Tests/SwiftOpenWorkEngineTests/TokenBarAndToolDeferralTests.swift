import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

final class TokenBarAndToolDeferralTests: XCTestCase {

    private func tool(_ name: String) -> Tool {
        Tool(id: name, name: name, displayName: name, description: "Does \(name). More.", category: .system, parametersJsonSchema: "{}")
    }

    func testSentAndRecvSumEveryCallInATurn() {
        var turn = ChatMessage(sessionId: "s", role: .assistant, content: "a", promptTokens: 400, completionTokens: 20)
        turn.billedPromptTokens = 1_000
        turn.billedCompletionTokens = 90
        let old = ChatMessage(sessionId: "s", role: .assistant, content: "b", promptTokens: 50, completionTokens: 5)
        let stats = TokenAccounting.stats(for: [old, turn])
        XCTAssertEqual(stats.sentTokens, 1_050)
        XCTAssertEqual(stats.receivedTokens, 95)
        XCTAssertEqual(stats.lastPromptTokens, 400)
    }

    func testPromptShowsTheDraftWhileTypingThenTheLastBilledPrompt() {
        XCTAssertEqual(TokenAccounting.displayedPrompt(draft: "12345678", lastBilledPrompt: 900), 2)
        XCTAssertEqual(TokenAccounting.displayedPrompt(draft: "  ", lastBilledPrompt: 900), 900)
    }

    func testRarelyUsedBuiltInsAreDeferredButEverydayOnesStay() {
        let tools = ["file_read", "grep", "worktree_create", "worktree_list", "preview_start", "generate_image"].map(tool)
        let split = BuiltInToolSearch.partition(tools, prompt: "fix the failing test")
        XCTAssertEqual(Set(split.loaded.map(\.name)), ["file_read", "grep"])
        XCTAssertEqual(split.deferred.count, 4)
    }

    func testAPromptThatNamesATopicKeepsItsToolLoaded() {
        let tools = ["file_read", "worktree_create", "worktree_list", "preview_start", "generate_image", "quit_app"].map(tool)
        let split = BuiltInToolSearch.partition(tools, prompt: "start a preview of the app")
        XCTAssertTrue(split.loaded.contains { $0.name == "preview_start" })
        XCTAssertFalse(split.deferred.contains { $0.name == "preview_start" })
    }

    func testFewDeferrableToolsAreNotWorthListing() {
        let tools = ["file_read", "worktree_create", "run_app"].map(tool)
        XCTAssertTrue(BuiltInToolSearch.partition(tools, prompt: "hi").deferred.isEmpty)
    }
}
