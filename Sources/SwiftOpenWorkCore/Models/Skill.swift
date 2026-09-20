import Foundation

public enum SkillSource: String, Codable, CaseIterable, Sendable {
    case builtIn = "builtIn"
    case fileImport = "fileImport"
    case urlImport = "urlImport"
    case manual = "manual"
    /// Read from `.swiftopenwork/skills/` in the workspace, not from `skills.json`.
    case project = "project"

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .fileImport: return "File Import"
        case .urlImport: return "URL Import"
        case .manual: return "Custom"
        case .project: return "Project"
        }
    }

    public var icon: String {
        switch self {
        case .builtIn: return "sparkles"
        case .fileImport: return "doc.badge.plus"
        case .urlImport: return "globe"
        case .manual: return "pencil.and.outline"
        case .project: return "folder.badge.gearshape"
        }
    }
}

public struct Skill: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var category: String
    public var content: String // Instructions / Markdown
    public var source: SkillSource
    public var filePath: String?
    public var url: String?
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        description: String = "",
        category: String = "General",
        content: String = "",
        source: SkillSource = .manual,
        filePath: String? = nil,
        url: String? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.content = content
        self.source = source
        self.filePath = filePath
        self.url = url
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
