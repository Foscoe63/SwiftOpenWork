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

    func testEveryoneCanUseToolsExceptAReplanner() {
        XCTAssertTrue(GroupChat.Role.discuss.usesTools)
        XCTAssertTrue(GroupChat.Role.act.usesTools)
        XCTAssertFalse(GroupChat.Role.replan.usesTools)
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

    // MARK: - Handoffs

    private func relay(_ text: String, followUp: Bool = false) -> GroupChat.Relay {
        let plan = GroupChat.plan(text: text, participants: room, followUp: followUp)
        return GroupChat.Relay(speakers: plan.speakers, excluded: plan.excluded, participants: room)
    }

    func testAnActingAgentCanHandWorkToATeammateWithTools() {
        var r = relay("@coder build the API")
        let first = r.next()
        XCTAssertEqual(first?.speaker, GroupChat.Speaker(id: "coder", role: .act))
        XCTAssertNil(first?.requestedBy)
        XCTAssertEqual(r.didSpeak(first!.speaker, reply: "Done. @Reviewer please check the API shape."), ["reviewer"])
        let second = r.next()
        XCTAssertEqual(second?.speaker, GroupChat.Speaker(id: "reviewer", role: .act))
        XCTAssertEqual(second?.requestedBy, "coder")
        XCTAssertNil(r.next())
    }

    func testOnlyActingAgentsHandOff() {
        var r = relay("what do you all think?")
        let first = r.next()!
        XCTAssertEqual(first.speaker.role, .discuss)
        XCTAssertTrue(r.didSpeak(first.speaker, reply: "@Marketing should weigh in").isEmpty)
        // Marketing still speaks once, as a discussion turn, not as an actor.
        var roles: [GroupChat.Role] = []
        while let n = r.next() { roles.append(n.speaker.role) }
        XCTAssertEqual(roles, [.discuss, .discuss, .discuss])
    }

    func testAgentsCannotHandBackToWhoAlreadySpokeOrToThemselves() {
        var r = relay("@coder go")
        let coderTurn = r.next()!
        XCTAssertEqual(r.didSpeak(coderTurn.speaker, reply: "@Coder and @Reviewer"), ["reviewer"])
        let reviewerTurn = r.next()!
        // Reviewer mentioning Coder (already spoke) or itself hands off nothing: no ping-pong.
        XCTAssertTrue(r.didSpeak(reviewerTurn.speaker, reply: "@Coder fix it, cc @Reviewer").isEmpty)
        XCTAssertNil(r.next())
    }

    func testHandoffsAreCappedPerMessage() {
        let many = (1...6).map { GroupChat.Participant(id: "a\($0)", name: "A\($0)") }
        var r = GroupChat.Relay(speakers: [GroupChat.Speaker(id: "a1", role: .act)], excluded: [], participants: many)
        let first = r.next()!
        let added = r.didSpeak(first.speaker, reply: "@a2 @a3 @a4 @a5 @a6")
        XCTAssertEqual(added.count, GroupChat.Relay.maxHandoffs)
        var spoke = 0
        while r.next() != nil { spoke += 1 }
        XCTAssertEqual(spoke, GroupChat.Relay.maxHandoffs)
    }

    func testAnExcludedAgentIsNeverHandedAnything() {
        var r = relay("@coder go !@reviewer")
        let first = r.next()!
        XCTAssertTrue(r.didSpeak(first.speaker, reply: "@Reviewer look").isEmpty)
        XCTAssertNil(r.next())
    }

    func testAQueuedReplannerIsPromotedRatherThanSpeakingTwice() {
        var r = relay("@coder go @others adjust")
        let first = r.next()!
        XCTAssertEqual(r.didSpeak(first.speaker, reply: "@Devops needs to act"), ["devops"])
        var order: [(String, GroupChat.Role)] = []
        while let n = r.next() { order.append((n.speaker.id, n.speaker.role)) }
        XCTAssertEqual(order.map(\.0), ["devops", "reviewer", "marketing"])
        XCTAssertEqual(order.map(\.1), [.act, .replan, .replan])
    }

    func testHandedOverPersonaNamesWhoAskedAndKeepsTools() {
        let text = GroupChat.persona(base: "", names: ["Coder", "Reviewer"], self: "Reviewer", role: .act, requestedBy: "Coder")
        XCTAssertTrue(text.contains("Coder mentioned you"))
        XCTAssertTrue(text.contains("with your tools"))
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

    func testRoundTablePersonaDoesNotClaimThereAreNoTools() {
        let text = GroupChat.persona(base: "", names: ["A", "B"], self: "A", role: .discuss)
        XCTAssertFalse(text.lowercased().contains("no tools"))
        XCTAssertTrue(text.contains("you can use your tools"))
        XCTAssertTrue(text.contains("do not redo their work"))
    }

    func testReplanPersonaTellsTheAgentNotToTalkAboutTools() {
        let text = GroupChat.persona(base: "", names: ["A", "B"], self: "B", role: .replan)
        XCTAssertFalse(text.lowercased().contains("no tools"))
        XCTAssertTrue(text.contains("do not comment on tools"))
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
        // The user's message and Coder's tagged reply are one user turn; Reviewer's own reply follows.
        XCTAssertEqual(seenByReviewer.map(\.role), [.user, .assistant])
        XCTAssertEqual(seenByReviewer[0].content, "plan it\n\n[Coder]: Use Go.")
        XCTAssertEqual(seenByReviewer[1].content, "Looks fine.")
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

    func testFlattenMergesRunsOfUserTurnsSoRolesAlternate() {
        let names = ["coder": "Coder", "reviewer": "Reviewer"]
        let messages = [
            ChatMessage(role: .user, content: "plan it"),
            ChatMessage(role: .assistant, content: "Use Go.", agentId: "coder"),
            ChatMessage(role: .assistant, content: "Fine.", agentId: "reviewer"),
            ChatMessage(role: .user, content: "ok, go on")
        ]
        let out = GroupChat.flatten(messages, speakerId: "coder", names: names)
        XCTAssertEqual(out.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(out[0].content, "plan it")
        XCTAssertEqual(out[2].content, "[Reviewer]: Fine.\n\nok, go on")

        let forReviewer = GroupChat.flatten(messages, speakerId: "reviewer", names: names)
        XCTAssertEqual(forReviewer.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(forReviewer[0].content, "plan it\n\n[Coder]: Use Go.")
    }

    func testContinueInAGroupIsAddressedToOneAgent() {
        XCTAssertEqual(AutoContinuePolicy.continuePrompt(addressedTo: nil), AutoContinuePolicy.continuePrompt)
        let addressed = AutoContinuePolicy.continuePrompt(addressedTo: "coder")
        XCTAssertTrue(addressed.hasPrefix("@coder "))
        XCTAssertTrue(AutoContinuePolicy.isContinuePrompt(addressed))
        XCTAssertTrue(AutoContinuePolicy.isContinuePrompt(AutoContinuePolicy.continuePrompt))
        XCTAssertFalse(AutoContinuePolicy.isContinuePrompt("@coder please continue the migration"))
        // ...and it really does pick only that agent.
        let room = [GroupChat.Participant(id: "coder", name: "Coder"), GroupChat.Participant(id: "reviewer", name: "Reviewer")]
        let plan = GroupChat.plan(text: addressed, participants: room, followUp: false)
        XCTAssertEqual(plan.speakers, [GroupChat.Speaker(id: "coder", role: .act)])
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
