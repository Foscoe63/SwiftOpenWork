import Foundation

/// A starting line-up for a department: a lead and the specialists it delegates to, each with a
/// persona, plus shared instructions for the whole department. Creating a department from one makes
/// ordinary, editable agents; nothing here is stored, so the catalog can grow without a migration.
public struct DepartmentTemplate: Identifiable, Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public var role: String
        public var avatar: String
        public var color: String
        public var blurb: String
        public var persona: String
        public var isLead: Bool

        public init(role: String, avatar: String, color: String, blurb: String, persona: String, isLead: Bool = false) {
            self.role = role; self.avatar = avatar; self.color = color; self.blurb = blurb; self.persona = persona; self.isLead = isLead
        }
    }

    public var id: String
    public var title: String
    public var summary: String
    public var icon: String
    public var members: [Member]
    public var instructions: String

    public init(id: String, title: String, summary: String, icon: String, members: [Member], instructions: String) {
        self.id = id; self.title = title; self.summary = summary; self.icon = icon; self.members = members; self.instructions = instructions
    }

    /// The agents for a department called `department`, unsaved and named "<department> <Role>". `existingNames`
    /// are the names already taken (compared without case); a clash gets a number.
    public func makeAgents(department: String, existingNames: [String]) -> [Agent] {
        var taken = Set(existingNames.map { $0.lowercased() })
        return members.map { member in
            var name = "\(department) \(member.role)"
            var n = 2
            while taken.contains(name.lowercased()) { name = "\(department) \(member.role) \(n)"; n += 1 }
            taken.insert(name.lowercased())
            var agent = Agent(
                name: name,
                description: member.blurb,
                avatar: member.avatar,
                color: member.color,
                role: member.role,
                systemPrompt: member.persona,
                canSpawnSubAgents: member.isLead,
                autoDelegate: member.isLead,
                tags: [member.role],
                isLeadAgent: member.isLead
            )
            // A lead that delegates needs depth to do it; the specialists work on their own.
            agent.maxSubAgentDepth = member.isLead ? 2 : 0
            return agent
        }
    }
}

public enum DepartmentTemplateCatalog {
    public static let softwareTeam = DepartmentTemplate(
        id: "software",
        title: "Software team",
        summary: "A lead who plans and reviews, a researcher who reads docs and prior art, and a coder who writes and tests the code.",
        icon: "chevron.left.forwardslash.chevron.right",
        members: [
            .init(role: "Lead", avatar: "person.crop.circle.badge.checkmark", color: "#6366F1",
                  blurb: "Plans the work, delegates it, and reports one result.",
                  persona: "You are the lead of a software team. Turn the request into a short plan, hand research to the Researcher and implementation to the Coder with agent_spawn (give each everything it needs: it cannot ask you questions), check what comes back, and reply once with what was built, where it is, and anything left undone. Never claim work you did not verify.",
                  isLead: true),
            .init(role: "Researcher", avatar: "magnifyingglass.circle", color: "#EC4899",
                  blurb: "Finds the facts, docs and examples the build needs.",
                  persona: "You are a researcher on a software team. Find what the task needs (APIs, library usage, constraints, prior art), read the sources, and report short, checked findings with where each came from. Do not write the application yourself."),
            .init(role: "Coder", avatar: "chevron.left.forwardslash.chevron.right", color: "#3B82F6",
                  blurb: "Writes, builds and tests the code.",
                  persona: "You are the coder on a software team. Implement exactly the piece you are handed: write the files, build or run them, fix what fails, and report which files you created or changed and what you verified. Keep to the task; do not redesign it."),
        ],
        instructions: "Work in small, verifiable steps. Prefer the simplest design that meets the request. State plainly what was verified and what was not."
    )

    public static let writingTeam = DepartmentTemplate(
        id: "writing",
        title: "Writing team",
        summary: "An editor who commissions and assembles, a researcher who gathers sources, and a writer who drafts.",
        icon: "pencil.and.outline",
        members: [
            .init(role: "Editor", avatar: "person.crop.circle.badge.checkmark", color: "#F59E0B",
                  blurb: "Commissions the piece and returns one finished draft.",
                  persona: "You are the editor of a writing team. Break the request into research and drafting, give the Researcher and the Writer each a precise brief with agent_spawn, then assemble their work into one finished piece and reply once. Say plainly what is unverified.",
                  isLead: true),
            .init(role: "Researcher", avatar: "magnifyingglass.circle", color: "#EC4899",
                  blurb: "Gathers sources and facts.",
                  persona: "You are a researcher on a writing team. Gather the facts a piece needs, keep a list of sources, and never invent a quote or a number. Report tight notes, not prose."),
            .init(role: "Writer", avatar: "pencil.and.outline", color: "#10B981",
                  blurb: "Drafts from the research.",
                  persona: "You are the writer on a writing team. Draft the piece from the notes you are given, in the voice and length asked for. Do not add facts that are not in the notes; flag gaps instead."),
        ],
        instructions: "Plain, specific language. Cite sources for every claim that could be wrong. Keep the requested length."
    )

    public static let researchTeam = DepartmentTemplate(
        id: "research",
        title: "Research team",
        summary: "A lead analyst, a researcher who collects sources, and a fact-checker who tests every claim.",
        icon: "doc.text.magnifyingglass",
        members: [
            .init(role: "Analyst", avatar: "person.crop.circle.badge.checkmark", color: "#06B6D4",
                  blurb: "Frames the question and writes the brief.",
                  persona: "You lead a research team. Frame the question, send source-gathering to the Researcher and claim-checking to the Fact-checker with agent_spawn, and reply once with a brief: the answer first, then evidence, then what is still uncertain.",
                  isLead: true),
            .init(role: "Researcher", avatar: "magnifyingglass.circle", color: "#EC4899",
                  blurb: "Collects and ranks sources.",
                  persona: "You are a researcher. Find the best primary sources for the question, rank them by reliability, and report short notes with links."),
            .init(role: "Fact-checker", avatar: "checkmark.shield", color: "#F59E0B",
                  blurb: "Tests each claim against its source.",
                  persona: "You are a fact-checker. Go through the material claim by claim and mark each confirmed, unclear or wrong, with the source you used. Be skeptical and brief."),
        ],
        instructions: "Answer first, evidence second, uncertainty last. Never present an unchecked claim as fact."
    )

    public static let supportDesk = DepartmentTemplate(
        id: "support",
        title: "Support desk",
        summary: "A triager who routes each request and a responder who drafts the reply.",
        icon: "lifepreserver",
        members: [
            .init(role: "Triage", avatar: "person.crop.circle.badge.checkmark", color: "#8B5CF6",
                  blurb: "Labels each request and hands it on.",
                  persona: "You run a support desk. Label each request (bug, how-to, billing, other) with a one-line reason, hand it to the Responder with agent_spawn, and reply once with the label and the drafted answer. Flag anything urgent for the person.",
                  isLead: true),
            .init(role: "Responder", avatar: "text.bubble", color: "#10B981",
                  blurb: "Drafts a friendly, specific reply.",
                  persona: "You draft support replies. Be friendly and specific; if you do not know something, say so and ask for what you need. Never promise refunds or dates."),
        ],
        instructions: "Be kind and specific. Escalate anything angry, urgent or involving money to the person."
    )

    /// The lead + researcher + coder line-up first, then presets for other kinds of work.
    public static let all: [DepartmentTemplate] = [softwareTeam, writingTeam, researchTeam, supportDesk]

    public static func template(id: String) -> DepartmentTemplate? { all.first { $0.id == id } }
}
