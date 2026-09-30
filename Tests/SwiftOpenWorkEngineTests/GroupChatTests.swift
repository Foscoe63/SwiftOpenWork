import XCTest
@testable import SwiftOpenWorkCore

/// A group chat where every agent answered every message, none of them able to use tools, was the
/// failure Radiant's addressing rules exist to prevent. These pin the rules ported from it.
final class GroupChatTests: XCTestCase {

    private let coder = GroupChat.Participant(id: "coder", name: "Coder")
    private let reviewer = GroupChat.Participant(id: "reviewer", name: "Reviewer")
    private let devops = GroupChat.Participant(id: "devops", name: "Dev Ops")
    private let marketing = GroupChat.Participant(id: "marketing", name: "Marketing")
    private var room: [GroupChat.Participant] { [coder, reviewer, devops, marketing] }

    // MARK: - Names

    func testSlugNameCollapsesSeparators() {
        XCTAssertEqual(GroupChat.slugName("Prompt Engineer"), "prompt-engineer")
        XCTAssertEqual(GroupChat.slugName("  Dev  Ops! "), "dev-ops")
        XCTAssertEqual(GroupChat.slugName("Coder"), "coder")
        XCTAssertEqual(GroupChat.slugName(""), "")
    }

    // MARK: - Addressing

    func testNoMentionAddressesNobody() {
        let a = GroupChat.addressing(in: "let's do the frontend in React", participants: room)
        XCTAssertTrue(a.ids.isEmpty)
    }

    func testMentionNamesOneAgent() {
        let a = GroupChat.addressing(in: "@Coder, plan the stack", participants: room)
        XCTAssertEqual(a.named, ["coder"])
        XCTAssertTrue(a.swept.isEmpty)
    }

    func testTrailingPunctuationIsNotPartOfTheName() {
        XCTAssertEqual(GroupChat.addressing(in: "thanks @coder.", participants: room).named, ["coder"])
        XCTAssertEqual(GroupChat.addressing(in: "(@reviewer) look", participants: room).named, ["reviewer"])
    }

    func testMultiWordNameMatchesHyphenatedAndJoined() {
        XCTAssertEqual(GroupChat.addressing(in: "@dev-ops ship it", participants: room).named, ["devops"])
        XCTAssertEqual(GroupChat.addressing(in: "@devops ship it", participants: room).named, ["devops"])
    }

    func testUnknownMentionIsIgnored() {
        // "@Sources/Foo.swift" is a file mention, not an agent.
        XCTAssertTrue(GroupChat.addressing(in: "look at @Sources/Foo.swift", participants: room).ids.isEmpty)
    }

    func testEmailAddressIsNotAMention() {
        XCTAssertTrue(GroupChat.addressing(in: "mail me at bob@coder.io", participants: room).ids.isEmpty)
    }

    func testNamedAgentsSpeakInOrderOfMention() {
        let a = GroupChat.addressing(in: "@reviewer then @coder", participants: room)
        XCTAssertEqual(a.named, ["reviewer", "coder"])
    }

    func testOthersSweepsTheRestInAfterTheNamedOnes() {
        let a = GroupChat.addressing(in: "@coder move the backend to Go; @others update your plan", participants: room)
        XCTAssertEqual(a.named, ["coder"])
        XCTAssertEqual(a.swept, ["reviewer", "devops", "marketing"])
        XCTAssertEqual(a.ids, ["coder", "reviewer", "devops", "marketing"])
    }

    func testExclusionWinsWhereverItAppears() {
        let after = GroupChat.addressing(in: "@coder go; @others !@marketing", participants: room)
        let before = GroupChat.addressing(in: "!@marketing @others @coder go", participants: room)
        XCTAssertEqual(after.swept, ["reviewer", "devops"])
        XCTAssertEqual(before.swept, ["reviewer", "devops"])
        XCTAssertEqual(after.excluded, ["marketing"])
    }

    func testExclusionBeatsAnEarlierExplicitMention() {
        let a = GroupChat.addressing(in: "@marketing @coder go, !@marketing", participants: room)
        XCTAssertEqual(a.named, ["coder"])
    }

    func testAllAndEveryoneAreSynonymsForTheRest() {
        for word in ["@all", "@everyone", "@room", "@rest"] {
            let a = GroupChat.addressing(in: "@coder go \(word)", participants: room)
            XCTAssertEqual(a.swept.count, 3, word)
        }
    }

    // MARK: - Plan

    func testRoundTableWhenNobodyIsNamed() {
        let plan = GroupChat.plan(text: "what do you all think?", participants: room, followUp: false)
        XCTAssertEqual(plan.speakers.map(\.id), ["coder", "reviewer", "devops", "marketing"])
        XCTAssertTrue(plan.speakers.allSatisfy { $0.role == .discuss })
        XCTAssertNil(plan.notice)
    }

    func testOnlyTheNamedAgentActsAndGetsTools() {
        let plan = GroupChat.plan(text: "@Coder, plan the stack", participants: room, followUp: false)
        XCTAssertEqual(plan.speakers, [GroupChat.Speaker(id: "coder", role: .act)])
        XCTAssertTrue(plan.speakers[0].role.usesTools)
        XCTAssertEqual(plan.notice, "Coder is acting on this.")
    }

    func testNoRoleExceptActUsesTools() {
        XCTAssertFalse(GroupChat.Role.discuss.usesTools)
        XCTAssertFalse(GroupChat.Role.replan.usesTools)
        XCTAssertTrue(GroupChat.Role.act.usesTools)
    }

    func testSweptAgentsReplanAndDoNotAct() {
        let plan = GroupChat.plan(text: "@coder move to Go, @others adjust", participants: room, followUp: false)
        XCTAssertEqual(plan.speakers.first, GroupChat.Speaker(id: "coder", role: .act))
        XCTAssertTrue(plan.speakers.dropFirst().allSatisfy { $0.role == .replan })
        XCTAssertEqual(plan.speakers.count, 4)
    }

    func testFollowUpOptionSweepsTheRestWithoutTypingOthers() {
        let off = GroupChat.plan(text: "@coder go", participants: room, followUp: false)
        let on = GroupChat.plan(text: "@coder go", participants: room, followUp: true)
        XCTAssertEqual(off.speakers.count, 1)
        XCTAssertEqual(on.speakers.map(\.id), ["coder", "reviewer", "devops", "marketing"])
        XCTAssertEqual(on.speakers.dropFirst().map(\.role), [.replan, .replan, .replan])
    }

    func testFollowUpHonoursExclusions() {
        let plan = GroupChat.plan(text: "@coder go !@marketing", participants: room, followUp: true)
        XCTAssertFalse(plan.speakers.map(\.id).contains("marketing"))
    }

    func testFollowUpDoesNothingWhenNobodyIsNamed() {
        let plan = GroupChat.plan(text: "thoughts?", participants: room, followUp: true)
        XCTAssertTrue(plan.speakers.allSatisfy { $0.role == .discuss })
    }

    func testExclusionAloneSitsAgentOutOfTheRoundTable() {
        let plan = GroupChat.plan(text: "thoughts? !@marketing", participants: room, followUp: false)
        XCTAssertEqual(plan.speakers.map(\.id), ["coder", "reviewer", "devops"])
    }

    func testExcludingEveryoneStillAnswersRatherThanSilence() {
        let two = [coder, reviewer]
        let plan = GroupChat.plan(text: "!@coder !@reviewer hello", participants: two, followUp: false)
        XCTAssertEqual(plan.speakers.count, 2)
    }

    // MARK: - Persona

    func testActingPersonaSaysDoTheWorkAndNamesTheListeners() {
        let text = GroupChat.persona(base: "You are Coder.", names: ["Coder", "Reviewer"], self: "Coder", role: .act)
        XCTAssertTrue(text.contains("You are Coder."))
        XCTAssertTrue(text.contains("Do the work yourself, with your tools"))
        XCTAssertTrue(text.contains("Reviewer is listening"))
    }

    func testReplanPersonaForbidsDoingSomeoneElsesTask() {
        let text = GroupChat.persona(base: "", names: ["Coder", "Marketing"], self: "Marketing", role: .replan)
        XCTAssertTrue(text.contains("Do not do the other person's task"))
        XCTAssertFalse(text.contains("Do the work yourself"))
    }

    func testDiscussPersonaTellsTheAgentItHasNoTools() {
        let text = GroupChat.persona(base: "", names: ["A", "B"], self: "A", role: .discuss)
        XCTAssertTrue(text.contains("no tools this turn"))
    }

    // MARK: - History

    func testFlattenTagsOtherAgentsAsUserMessagesAndKeepsOwnMessages() {
        let names = ["coder": "Coder", "reviewer": "Reviewer"]
        let messages = [
            ChatMessage(role: .user, content: "plan it"),
            ChatMessage(role: .assistant, content: "Use Go.", agentId: "coder", agentName: "Coder"),
            ChatMessage(role: .assistant, content: "Looks fine.", agentId: "reviewer", agentName: "Reviewer")
        ]
        let seenByReviewer = GroupChat.flatten(messages, speakerId: "reviewer", names: names)
        XCTAssertEqual(seenByReviewer.map(\.role), [.user, .user, .assistant])
        XCTAssertEqual(seenByReviewer[1].content, "[Coder]: Use Go.")
        XCTAssertEqual(seenByReviewer[2].content, "Looks fine.")
    }

    func testFlattenDropsOtherAgentsToolCallsAndEmptyOrFailedReplies() {
        let names = ["coder": "Coder", "reviewer": "Reviewer"]
        var toolOnly = ChatMessage(role: .assistant, content: "", agentId: "coder")
        toolOnly.toolCalls = []
        let failed = ChatMessage(role: .assistant, content: "boom", agentId: "coder", isError: true)
        let ok = ChatMessage(role: .assistant, content: "done", agentId: "coder")
        let out = GroupChat.flatten([toolOnly, failed, ok], speakerId: "reviewer", names: names)
        XCTAssertEqual(out.map(\.content), ["[Coder]: done"])
        XCTAssertTrue(out[0].toolCalls.isEmpty)
    }

    func testFlattenLeavesUnattributedAssistantMessagesAlone() {
        let legacy = ChatMessage(role: .assistant, content: "old reply")
        let out = GroupChat.flatten([legacy], speakerId: "coder", names: [:])
        XCTAssertEqual(out.first?.role, .assistant)
    }

    // MARK: - Session

    func testSessionIsAGroupFromTwoParticipants() {
        var s = Session()
        XCTAssertFalse(s.isGroup)
        s.participantIds = ["coder"]
        XCTAssertFalse(s.isGroup)
        s.participantIds = ["coder", "reviewer"]
        XCTAssertTrue(s.isGroup)
    }

    func testSessionsSavedBeforeGroupChatsStillDecode() throws {
        let old = Session(title: "Old chat")
        let data = try JSONEncoder().encode(old)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "participantIds")
        json.removeValue(forKey: "groupFollowUp")
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Session.self, from: stripped)
        XCTAssertEqual(decoded.participantIds, [])
        XCTAssertFalse(decoded.groupFollowUp)
    }

    func testGroupFieldsSurviveARoundTrip() throws {
        var s = Session(title: "Room")
        s.participantIds = ["coder", "reviewer"]
        s.groupFollowUp = true
        let back = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.participantIds, ["coder", "reviewer"])
        XCTAssertTrue(back.groupFollowUp)
    }

    func testGroupSessionIgnoresSavedModelContext() {
        var s = Session()
        s.messages = [ChatMessage(id: "u1", role: .user, content: "hi")]
        s.modelContext = ModelContextSnapshot(
            coveredMessageIds: ["u1"],
            messages: [ChatMessage(id: "u1", role: .user, content: "hi"), ChatMessage(role: .assistant, content: "snapshot-only step")]
        )
        XCTAssertEqual(s.modelHistory().count, 2)
        s.participantIds = ["a", "b"]
        XCTAssertEqual(s.modelHistory().count, 1)
    }
}
