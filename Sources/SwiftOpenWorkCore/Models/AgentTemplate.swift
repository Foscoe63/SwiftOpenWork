import Foundation

/// A ready-made agent persona from Radiant's template library. Adding one creates an ordinary,
/// editable agent; the template itself is never stored, so it can grow without a migration.
public struct AgentTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let category: String
    public let name: String
    public let avatar: String
    public let color: String
    public let blurb: String
    public let persona: String

    public init(id: String, category: String, name: String, avatar: String, color: String, blurb: String, persona: String) {
        self.id = id
        self.category = category
        self.name = name
        self.avatar = avatar
        self.color = color
        self.blurb = blurb
        self.persona = persona
    }

    /// A new, unsaved agent with a fresh id. Provider and model stay empty so it follows the
    /// session's; the caller supplies the user's defaults for the generation settings.
    public func makeAgent(
        temperature: Double = 0.7,
        maxTokens: Int = 4096,
        reasoningEffort: ReasoningEffort = .medium
    ) -> Agent {
        Agent(
            name: name,
            description: blurb,
            avatar: avatar,
            color: color,
            role: category,
            systemPrompt: persona,
            temperature: temperature,
            maxTokens: maxTokens,
            reasoningEffort: reasoningEffort,
            canSpawnSubAgents: false,
            autoDelegate: false,
            tags: [category]
        )
    }
}

public enum AgentTemplateCatalog {
    public static var templates: [AgentTemplate] { all }

    /// Categories in library order.
    public static var categories: [String] {
        var seen = Set<String>()
        return all.map(\.category).filter { seen.insert($0).inserted }
    }

    public static func matching(query: String, category: String?) -> [AgentTemplate] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.filter { t in
            (category == nil || t.category == category)
                && (q.isEmpty || t.name.lowercased().contains(q) || t.blurb.lowercased().contains(q)
                    || t.category.lowercased().contains(q))
        }
    }
}
