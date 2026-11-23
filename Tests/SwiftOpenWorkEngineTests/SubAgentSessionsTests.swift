import XCTest
import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

@MainActor
final class SubAgentSessionsTests: XCTestCase {
    func testResumeIsScopedToTheChatThatStartedIt() {
        let store = SubAgentSessions.shared
        let id = store.save(parentSessionId: "chat-A", agentId: "coder", objective: "x", messages: [], worktree: nil)
        XCTAssertNotNil(store.session(id: id, parentSessionId: "chat-A"))
        XCTAssertNil(store.session(id: id, parentSessionId: "chat-B"))
    }

    func testSavingAgainWithTheSameIdReplacesIt() {
        let store = SubAgentSessions.shared
        let id = store.save(parentSessionId: "chat-R", agentId: "coder", objective: "x", messages: [], worktree: nil)
        _ = store.save(id: id, parentSessionId: "chat-R", agentId: "coder", objective: "x", messages: [ChatMessage(role: .user, content: "hi")], worktree: nil)
        XCTAssertEqual(store.session(id: id, parentSessionId: "chat-R")?.messages.count, 1)
        XCTAssertEqual(store.ids(in: "chat-R").filter { $0 == id }.count, 1)
    }

    func testOldestSessionsAreDroppedPastTheLimit() {
        let store = SubAgentSessions.shared
        let first = store.save(parentSessionId: "chat-L", agentId: "a", objective: "", messages: [], worktree: nil)
        for _ in 0..<SubAgentSessions.limit { _ = store.save(parentSessionId: "chat-L", agentId: "a", objective: "", messages: [], worktree: nil) }
        XCTAssertNil(store.session(id: first, parentSessionId: "chat-L"))
    }
}
