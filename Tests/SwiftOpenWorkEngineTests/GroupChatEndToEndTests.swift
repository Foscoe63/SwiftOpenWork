import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkEngine

/// Drives the real `AgentRunner` through group turns against a local OpenAI-style server that
/// records what every speaker was sent. Skipped unless `GROUP_FAKE_URL` and `GROUP_FAKE_LOG` are
/// set. Start the server with `python3 Scripts/fake_group_llm.py 18765 /tmp/group.log`, then run with
/// `TEST_RUNNER_GROUP_FAKE_URL=http://127.0.0.1:18765/v1 TEST_RUNNER_GROUP_FAKE_LOG=/tmp/group.log` — there is no in-process fake provider.
///
/// This replays `AppState.sendMessage`'s speaker loop: one run per speaker, each reading the
/// session as the previous speaker left it.
final class GroupChatEndToEndTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var session: Session
        init(_ s: Session) { session = s }
    }

    private struct Seen: Decodable {
        var speaker: String
        var has_tools: Bool
        var system: String
        var seen: [[String]]
    }

    private func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key] else {
            throw XCTSkip("\(key) not set; see Scripts/fake_group_llm.py")
        }
        return value
    }

    private func turn(_ text: String, in box: Box, agents: [Agent], provider: ModelProvider, workspace: Workspace) async {
        box.session.messages.append(ChatMessage(sessionId: box.session.id, role: .user, content: text))
        let room = box.session.participantIds.compactMap { id in agents.first { $0.id == id } }
        let people = room.map { GroupChat.Participant(id: $0.id, name: $0.name) }
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let plan = GroupChat.plan(text: text, participants: people, followUp: box.session.groupFollowUp)
        var relay = GroupChat.Relay(speakers: plan.speakers, excluded: plan.excluded, participants: people)
        var first = true
        while let next = relay.next() {
            let agent = room.first { $0.id == next.speaker.id }!
            let requester = next.requestedBy.flatMap { names[$0] }
            let group = GroupChat.Turn(
                names: names, roster: room.map(\.name), role: next.speaker.role,
                notice: first ? plan.notice : nil, startsTurn: first, requestedBy: requester
            )
            first = false
            await AgentRunner.shared.run(
                session: box.session,
                agent: agent,
                provider: provider,
                model: provider.models[0],
                workspace: workspace,
                allAgents: agents,
                reasoningOverride: .off,
                onMessageUpdated: { msg in
                    if let i = box.session.messages.firstIndex(where: { $0.id == msg.id }) {
                        box.session.messages[i] = msg
                    } else {
                        box.session.messages.append(msg)
                    }
                },
                onSubAgentTaskCreated: { _ in },
                onSubAgentTaskUpdated: { _ in },
                onInterAgentMessage: { _ in },
                group: group
            )
            if let reply = box.session.messages.last(where: { $0.role == .assistant && $0.agentId == agent.id }), !reply.isError {
                relay.didSpeak(next.speaker, reply: reply.content)
            }
        }
    }

    func testAgentsSeeEachOthersRepliesAndOnlyTheNamedOneGetsTools() async throws {
        let url = try env("GROUP_FAKE_URL")
        let logPath = try env("GROUP_FAKE_LOG")
        try? FileManager.default.removeItem(atPath: logPath)

        let agents = ["Coder", "Reviewer", "Tester"].map {
            Agent(id: $0.lowercased(), name: $0, systemPrompt: "You are \($0).")
        }
        let provider = ModelProvider(
            id: "fake", name: "Fake", type: .cloud, kind: .custom, baseUrl: url,
            models: [ModelInfo(id: "fake", name: "fake", providerId: "fake")]
        )
        let dir = NSTemporaryDirectory() + "group-e2e-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let workspace = Workspace(name: "T", folderPath: dir)
        var session = Session(agentId: "coder")
        session.participantIds = agents.map(\.id)
        let box = Box(session)

        // Round table: nobody named.
        await turn("How should we build the login page?", in: box, agents: agents, provider: provider, workspace: workspace)
        // Then address one agent.
        await turn("@reviewer sign off on it", in: box, agents: agents, provider: provider, workspace: workspace)

        let lines = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n")
        let calls = try lines.map { try JSONDecoder().decode(Seen.self, from: Data($0.utf8)) }
        for c in calls { print("GROUPLOG", c.speaker, "tools:", c.has_tools, c.seen.map { "\($0[0]): \($0[1])" }) }

        XCTAssertEqual(calls.map(\.speaker), ["Coder", "Reviewer", "Tester", "Reviewer"])
        // Round table: everyone can use tools, and none of them is told otherwise.
        XCTAssertEqual(calls.prefix(3).map(\.has_tools), [true, true, true])
        XCTAssertTrue(calls.prefix(3).allSatisfy { !$0.system.lowercased().contains("no tools") })
        // Reviewer saw Coder's reply, tagged, in the same turn (folded into the user's turn).
        XCTAssertTrue(calls[1].seen.contains { $0[0] == "user" && $0[1].contains("[Coder]: Plan drafted") })
        // Tester saw both.
        XCTAssertTrue(calls[2].seen.contains { $0[1].contains("[Coder]:") })
        XCTAssertTrue(calls[2].seen.contains { $0[1].contains("[Reviewer]:") })
        // Nobody sees their own reply tagged.
        XCTAssertFalse(calls[1].seen.contains { $0[1].contains("[Reviewer]:") })
        // Second turn: only Reviewer, with tools, and it remembers its own earlier reply as its own.
        XCTAssertTrue(calls[3].has_tools)
        XCTAssertTrue(calls[3].seen.contains { $0[0] == "assistant" && $0[1].hasPrefix("Reviewer here") })
        XCTAssertTrue(calls[3].seen.contains { $0[1].contains("[Tester]:") })
        // Some chat templates reject two user turns in a row: what every speaker gets must alternate.
        for call in calls {
            let roles = call.seen.map { $0[0] }
            XCTAssertFalse(zip(roles, roles.dropFirst()).contains { $0 == "user" && $1 == "user" }, "\(call.speaker): \(roles)")
        }
        // Every reply is stamped with its own agent.
        let authors = box.session.messages.filter { $0.role == .assistant }.compactMap(\.agentName)
        XCTAssertEqual(authors, ["Coder", "Reviewer", "Tester", "Reviewer"])

        // Handoff: naming only Coder is enough, because Coder's reply asks Reviewer to check it.
        await turn("@coder ship the login page", in: box, agents: agents, provider: provider, workspace: workspace)
        let after = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Seen.self, from: Data($0.utf8)) }
        XCTAssertEqual(after.dropFirst(4).map(\.speaker), ["Coder", "Reviewer"])
        XCTAssertEqual(after.dropFirst(4).map(\.has_tools), [true, true])
        XCTAssertTrue(after[5].system.contains("Coder mentioned you"))

        // @others: a swept-in agent re-plans without tools, and is told not to mention them.
        // Coder's reply also asks Reviewer, who is promoted from re-planning to acting.
        await turn("@coder tweak the button, @others adjust your plans", in: box, agents: agents, provider: provider, workspace: workspace)
        let last = try String(contentsOfFile: logPath, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Seen.self, from: Data($0.utf8)) }
        XCTAssertEqual(last.dropFirst(6).map(\.speaker), ["Coder", "Reviewer", "Tester"])
        XCTAssertEqual(last.dropFirst(6).map(\.has_tools), [true, true, false])
        XCTAssertTrue(last[8].system.contains("do not comment on tools"))
    }
}
