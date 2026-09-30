import Foundation

/// Who speaks in a group chat, and what each speaker is told.
///
/// A group chat is one session with several agents in it. Ported from Radiant's `group.js`, which
/// learned the shape the hard way: with every agent answering every message, "let's do the
/// frontend in React" sent four models off to do the same job at once in one folder, and none of
/// them could use tools because nobody was sure which one should.
///
/// Addressing decides who does what:
///
/// - `@Coder, plan the stack` makes Coder the only agent that **acts** this turn. One agent
///   acting rather than four talking means it can run with the chat's tools.
/// - `@others` (or `@all`) sweeps the rest of the room in to **re-plan**: revise their own plans
///   in light of what was said, not start doing the named agent's job. `!@marketing` sits one
///   agent out.
/// - No mention is the round table: everyone takes a turn, one at a time, **with tools**, each
///   told to build on what the others already did rather than repeat it.
///
/// The agents that stay quiet are still aware. Their messages are in the transcript every agent
/// reads on its next turn (`flatten`).
public enum GroupChat {

    /// What a speaker is being asked to do this turn.
    public enum Role: String, Codable, Sendable {
        /// Nobody named: the whole room takes a turn, one after another, and each can look at and
        /// change the project. Later speakers see what earlier ones did.
        case discuss
        /// Named directly: do the work, with tools.
        case act
        /// Swept in by `@others`: revise your own plan, do not do someone else's task.
        case replan

        /// Everyone gets tools except a re-planner, who is only meant to revise their own notes.
        /// Speakers never run at the same time, so two agents cannot edit one file at once; the
        /// prompt tells each to build on what teammates already did rather than repeat it.
        public var usesTools: Bool { self != .replan }
    }

    public struct Participant: Hashable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One agent's turn, in the order they speak.
    public struct Speaker: Hashable, Sendable {
        public var id: String
        public var role: Role

        public init(id: String, role: Role) {
            self.id = id
            self.role = role
        }
    }

    /// What the runner needs to know to run one speaker's turn inside a group.
    public struct Turn: Sendable {
        /// Every participant's display name by id, for tagging other agents' messages.
        public var names: [String: String]
        /// The same names in the order the agents were picked, for the roster line in the prompt.
        public var roster: [String]
        public var role: Role
        /// A line for the speaker's bubble saying who is doing what, on the first speaker only.
        public var notice: String?
        /// The display name of the teammate whose reply handed this turn over, when it was a handoff rather than
        /// something the user asked for. See `Relay`.
        public var requestedBy: String?
        /// False for the second and later speakers of one user message. The checkpoint window is
        /// per turn, and reopening it between speakers would drop the first one's file changes
        /// from "Review turn".
        public var startsTurn: Bool

        public init(names: [String: String], roster: [String], role: Role, notice: String? = nil, startsTurn: Bool = true, requestedBy: String? = nil) {
            self.names = names
            self.roster = roster
            self.requestedBy = requestedBy
            self.role = role
            self.notice = notice
            self.startsTurn = startsTurn
        }
    }

    public struct Addressing: Equatable, Sendable {
        /// Addressed by name, in order of mention — these act.
        public var named: [String]
        /// Pulled in by `@others` / `@all` — these re-plan, they do not act.
        public var swept: [String]
        /// Removed by `!@name`, whatever else the message said.
        public var excluded: [String]

        /// Named then swept, the order they speak in.
        public var ids: [String] { named + swept }
    }

    // MARK: - Names

    /// A name as it can be typed after `@`: "Prompt Engineer" → "prompt-engineer"; also "promptengineer".
    public static func slugName(_ name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlnum {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    // MARK: - Addressing

    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(^|[\s(,;:])(!?)@([a-z0-9][\w.\-]*)"#,
        options: [.caseInsensitive]
    )
    private static let everyone: Set<String> = ["all", "everyone", "room"]
    private static let theRest: Set<String> = ["others", "rest", "everyone-else"]

    /// Who this message is for.
    ///
    /// Naming one agent was not enough on its own: "`@coder`, move the backend to Go; `@others`
    /// update your plan accordingly" is two different jobs in one message. The NAMED agents do the
    /// work; the SWEPT-IN ones revise their own plans. Collapsing them into one list would tell
    /// Marketing to go and rewrite the backend.
    public static func addressing(in text: String, participants: [Participant]) -> Addressing {
        var named: [String] = []
        var excluded: [String] = []
        var wantsRest = false

        func match(_ typed: String) -> Participant? {
            participants.first { p in
                let slug = slugName(p.name)
                return typed == slug || typed == slug.replacingOccurrences(of: "-", with: "") || typed == p.name.lowercased()
            }
        }

        let ns = text as NSString
        for m in mentionPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let negated = ns.substring(with: m.range(at: 2)) == "!"
            var typed = ns.substring(with: m.range(at: 3)).lowercased()
            // "@coder," / "@coder." — trailing punctuation is the sentence's, not the name's.
            while let last = typed.last, ".,;:!?)".contains(last) { typed.removeLast() }
            if everyone.contains(typed) || theRest.contains(typed) {
                if !negated { wantsRest = true }
                continue
            }
            guard let hit = match(typed) else { continue }
            // Exclusion wins wherever it appears: "!@marketing" must beat both an earlier
            // "@marketing" and a later "@others", or sitting a round out would depend on word
            // order, which nobody would guess.
            if negated {
                if !excluded.contains(hit.id) { excluded.append(hit.id) }
            } else if !named.contains(hit.id) {
                named.append(hit.id)
            }
        }

        let finalNamed = named.filter { !excluded.contains($0) }
        let swept = wantsRest
            ? participants.map(\.id).filter { !excluded.contains($0) && !finalNamed.contains($0) }
            : []
        return Addressing(named: finalNamed, swept: swept, excluded: excluded)
    }

    /// The speakers for one user message, in order, and the line that says who is doing what.
    ///
    /// `followUp` is the room option ("others re-plan"): with it on, naming one agent sweeps the
    /// rest in automatically — the same thing typing `@others` does by hand, so there is one
    /// behaviour to learn rather than two. Off by default because it costs a turn per agent.
    public static func plan(
        text: String,
        participants: [Participant],
        followUp: Bool
    ) -> (speakers: [Speaker], notice: String?, excluded: [String]) {
        let addr = addressing(in: text, participants: participants)
        let auto = followUp && !addr.named.isEmpty
        let swept = !addr.swept.isEmpty
            ? addr.swept
            : (auto ? participants.map(\.id).filter { !addr.named.contains($0) && !addr.excluded.contains($0) } : [])

        guard !addr.named.isEmpty || !swept.isEmpty else {
            // Round table. An exclusion with nobody named still applies to it.
            let room = participants.map(\.id).filter { !addr.excluded.contains($0) }
            let speakers = (room.isEmpty ? participants.map(\.id) : room).map { Speaker(id: $0, role: .discuss) }
            return (speakers, nil, addr.excluded)
        }

        let names = Dictionary(participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func list(_ ids: [String]) -> String {
            ids.map { names[$0] ?? "Agent" }.joined(separator: " and ")
        }
        var parts: [String] = []
        if !addr.named.isEmpty {
            parts.append("\(list(addr.named)) \(addr.named.count == 1 ? "is" : "are") acting on this")
        }
        if !swept.isEmpty {
            parts.append("\(list(swept)) \(swept.count == 1 ? "is" : "are") updating \(swept.count == 1 ? "its" : "their") own plan")
        }
        if !addr.excluded.isEmpty {
            parts.append("\(list(addr.excluded)) sits this one out")
        }
        let speakers = addr.named.map { Speaker(id: $0, role: .act) } + swept.map { Speaker(id: $0, role: .replan) }
        return (speakers, parts.joined(separator: "; ") + ".", addr.excluded)
    }

    // MARK: - Handoffs

    /// The queue of speakers for one user message, which can grow while it runs.
    ///
    /// An agent the user named can ask a teammate to take part of the work by `@mentioning` them
    /// in its reply: "@Reviewer please check the API shape." That teammate then acts, with tools,
    /// right after the requester. Without this, agents could read each other but never hand each
    /// other anything — the user had to type every `@` themselves.
    ///
    /// The limits are the point:
    /// - **Only acting agents hand off.** A discussion or re-plan turn has no tools, and a plain
    ///   question must not turn into tool use because one model mentioned another.
    /// - **Each agent speaks at most once per user message**, so two agents cannot ping-pong.
    /// - **At most `maxHandoffs` per message**, so a chain cannot run away.
    /// - **`!@name` in the user's message still holds**: an excluded agent is never handed anything.
    ///
    /// A teammate already queued to re-plan is promoted to acting instead of speaking twice.
    public struct Relay: Sendable {
        public static let maxHandoffs = 3

        private var queue: [Speaker]
        private var spoken: Set<String> = []
        private var requesters: [String: String] = [:]
        private let excluded: Set<String>
        private let participants: [Participant]
        public private(set) var handoffs = 0

        public init(speakers: [Speaker], excluded: [String], participants: [Participant]) {
            self.queue = speakers
            self.excluded = Set(excluded)
            self.participants = participants
        }

        /// The next agent to speak, and who handed it the turn (nil when the user asked for it).
        public mutating func next() -> (speaker: Speaker, requestedBy: String?)? {
            guard !queue.isEmpty else { return nil }
            let speaker = queue.removeFirst()
            spoken.insert(speaker.id)
            return (speaker, requesters[speaker.id])
        }

        /// Record `speaker`'s finished reply. Returns the ids it handed work to, in order.
        @discardableResult
        public mutating func didSpeak(_ speaker: Speaker, reply: String) -> [String] {
            guard speaker.role == .act else { return [] }
            let mentioned = GroupChat.addressing(in: reply, participants: participants).named
            var added: [String] = []
            for id in mentioned where id != speaker.id && !spoken.contains(id) && !excluded.contains(id) {
                guard handoffs < Self.maxHandoffs else { break }
                queue.removeAll { $0.id == id }
                queue.insert(Speaker(id: id, role: .act), at: added.count)
                requesters[id] = speaker.id
                handoffs += 1
                added.append(id)
            }
            return added
        }
    }

    // MARK: - What each speaker sees

    /// The system-prompt addendum for a group turn, for the speaker and the situation.
    public static func persona(base: String, names: [String], self selfName: String, role: Role, requestedBy: String? = nil) -> String {
        let others = names.filter { $0 != selfName }
        let shared = """
        \(base)

        This is a group discussion between \(names.joined(separator: ", ")). You are \(selfName). \
        The other participants' messages are shown to you tagged like "[Name]: …". Speak only as \
        yourself, in the first person, briefly. Add something new — build on or respectfully \
        challenge what the others said; do not repeat them or role-play the other participants.
        """
        switch role {
        case .discuss:
            return shared + "\n\nThe user's message was for the whole room, so each of you takes a turn, one at a time, and you can use your tools. What your teammates said and did is above. Do the part that fits your role and skip what a teammate already covered; do not redo their work. If nothing is yours, say so in a sentence. To ask a teammate for something specific, name them."
        case .replan:
            // @others sweeps agents in so they can REVISE THEIR OWN PLANS, not so they can all
            // start doing the named agent's job — which is exactly what "you were addressed, do
            // the work" would tell Marketing to do.
            return shared + "\n\nYou were not asked to do this work — someone else in the room was. You are included so you can update YOUR OWN plan in light of it. Say briefly what changes for your part and what no longer applies, or say plainly that nothing changes. Do not do the other person's task. Just give your revised plan; do not comment on tools or on what you can or cannot run."
        case .act where requestedBy != nil:
            // Handed over by a teammate: the user did not name this agent, so say who did.
            return shared + "\n\n\(requestedBy ?? "A teammate") mentioned you in their reply to the user's request above, so this part is yours now. Do it yourself, with your tools, and report what you did. Only pass it on if part of it clearly belongs to someone else, and say so by name."
        case .act:
            let listening = others.isEmpty
                ? ""
                : " — \(others.joined(separator: ", ")) \(others.count == 1 ? "is" : "are") listening and will see what you do and say, but will not act unless asked"
            return shared + "\n\nYou were addressed directly in this message, so you are the one acting on it\(listening). Do the work yourself, with your tools, and report what you did. If part of it clearly belongs to someone else in the room, say so by name rather than doing it."
        }
    }

    /// The transcript as `speakerId` should read it: other agents' replies become tagged user
    /// messages, so each model sees a conversation it is one voice in rather than a stack of
    /// assistant turns that are not its own.
    ///
    /// Runs of user-role messages (the user's, then teammates') are merged into one turn.
    ///
    /// The speaker's own messages are untouched, tool calls and all. Another agent's tool calls
    /// are dropped: their result is in what they said, and replaying a tool call the speaker
    /// never made would confuse both the model and the provider's tool-call pairing.
    public static func flatten(_ messages: [ChatMessage], speakerId: String, names: [String: String]) -> [ChatMessage] {
        let tagged: [ChatMessage] = messages.compactMap { message in
            guard message.role == .assistant,
                  let author = message.agentId,
                  author != speakerId else { return message }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !message.isError else { return nil }
            var turned = ChatMessage(
                id: message.id,
                sessionId: message.sessionId,
                role: .user,
                content: "[\(names[author] ?? message.agentName ?? "Agent")]: \(text)",
                timestamp: message.timestamp
            )
            turned.agentId = nil
            return turned
        }

        // Teammates' replies are user-role messages now, so they sit right after the user's own.
        // Several chat templates (Mistral and Llama among them) reject two user turns in a row,
        // and the rest read them as one anyway. Merge each run into a single turn.
        var merged: [ChatMessage] = []
        for message in tagged {
            if message.role == .user, var last = merged.last, last.role == .user {
                last.content += "\n\n" + message.content
                last.attachments += message.attachments
                merged[merged.count - 1] = last
            } else {
                merged.append(message)
            }
        }
        return merged
    }
}
