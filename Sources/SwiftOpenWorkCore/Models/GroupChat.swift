import Foundation

/// Who speaks in a group chat, and what each speaker is told.
///
/// A group chat is one session with several agents in it. Ported from Radiant's `group.js`, which
/// learned the shape the hard way: with every agent answering every message, "let's do the
/// frontend in React" sent four models off to do the same job at once in one folder, and none of
/// them could use tools because nobody was sure which one should.
///
/// So addressing decides everything:
///
/// - `@Coder, plan the stack` makes Coder the only agent that **acts** this turn. One agent
///   acting rather than four talking means it can run with the chat's tools.
/// - `@others` (or `@all`) sweeps the rest of the room in to **re-plan**: revise their own plans
///   in light of what was said, not start doing the named agent's job. `!@marketing` sits one
///   agent out.
/// - No mention is the round table: everyone answers briefly, **without tools**.
///
/// The agents that stay quiet are still aware. Their messages are in the transcript every agent
/// reads on its next turn (`flatten`).
public enum GroupChat {

    /// What a speaker is being asked to do this turn.
    public enum Role: String, Codable, Sendable {
        /// Round table, nobody named: answer briefly in prose.
        case discuss
        /// Named directly: do the work, with tools.
        case act
        /// Swept in by `@others`: revise your own plan, do not do someone else's task.
        case replan

        /// Only the agent doing the work gets tools. Four agents editing one folder at once is
        /// the thing addressing exists to prevent.
        public var usesTools: Bool { self == .act }
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
        /// False for the second and later speakers of one user message. The checkpoint window is
        /// per turn, and reopening it between speakers would drop the first one's file changes
        /// from "Review turn".
        public var startsTurn: Bool

        public init(names: [String: String], roster: [String], role: Role, notice: String? = nil, startsTurn: Bool = true) {
            self.names = names
            self.roster = roster
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
    ) -> (speakers: [Speaker], notice: String?) {
        let addr = addressing(in: text, participants: participants)
        let auto = followUp && !addr.named.isEmpty
        let swept = !addr.swept.isEmpty
            ? addr.swept
            : (auto ? participants.map(\.id).filter { !addr.named.contains($0) && !addr.excluded.contains($0) } : [])

        guard !addr.named.isEmpty || !swept.isEmpty else {
            // Round table. An exclusion with nobody named still applies to it.
            let room = participants.map(\.id).filter { !addr.excluded.contains($0) }
            let speakers = (room.isEmpty ? participants.map(\.id) : room).map { Speaker(id: $0, role: .discuss) }
            return (speakers, nil)
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
        return (speakers, parts.joined(separator: "; ") + ".")
    }

    // MARK: - What each speaker sees

    /// The system-prompt addendum for a group turn, for the speaker and the situation.
    public static func persona(base: String, names: [String], self selfName: String, role: Role) -> String {
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
            return shared + "\n\nThis is a discussion turn: answer in prose. You have no tools this turn; if the work needs doing, say who should be asked to do it with @Name."
        case .replan:
            // @others sweeps agents in so they can REVISE THEIR OWN PLANS, not so they can all
            // start doing the named agent's job — which is exactly what "you were addressed, do
            // the work" would tell Marketing to do.
            return shared + "\n\nYou were not asked to do this work — someone else in the room was. You are included so you can update YOUR OWN plan in light of it. Say briefly what changes for your part and what no longer applies, or say plainly that nothing changes. Do not do the other person's task. You have no tools this turn."
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
    /// The speaker's own messages are untouched, tool calls and all. Another agent's tool calls
    /// are dropped: their result is in what they said, and replaying a tool call the speaker
    /// never made would confuse both the model and the provider's tool-call pairing.
    public static func flatten(_ messages: [ChatMessage], speakerId: String, names: [String: String]) -> [ChatMessage] {
        messages.compactMap { message in
            guard message.role == .assistant,
                  let author = message.agentId,
                  author != speakerId else { return message }
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !message.isError else { return nil }
            var tagged = ChatMessage(
                id: message.id,
                sessionId: message.sessionId,
                role: .user,
                content: "[\(names[author] ?? message.agentName ?? "Agent")]: \(text)",
                timestamp: message.timestamp
            )
            tagged.agentId = nil
            return tagged
        }
    }
}
