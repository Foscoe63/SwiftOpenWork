import Foundation

public enum AutomationTriggerType: String, Codable, CaseIterable, Sendable {
    case manual = "manual"
    case scheduled = "scheduled"
    case onStartup = "onStartup"
    case onSessionCreated = "onSessionCreated"
    case fileWatch = "fileWatch"

    public var displayName: String {
        switch self {
        case .manual: return "Manual Trigger"
        case .scheduled: return "Scheduled (Interval / Cron)"
        case .onStartup: return "Run on App Launch"
        case .onSessionCreated: return "On Session Create"
        case .fileWatch: return "Watch Directory Changes"
        }
    }

    public var icon: String {
        switch self {
        case .manual: return "play.circle.fill"
        case .scheduled: return "clock.arrow.2.circlepath"
        case .onStartup: return "bolt.fill"
        case .onSessionCreated: return "plus.message.fill"
        case .fileWatch: return "eye.circle.fill"
        }
    }
}

public struct Automation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var workspaceId: String
    public var name: String
    public var description: String
    public var triggerType: AutomationTriggerType
    /// Free text, read by `AutomationSchedule.parse`. "Daily at 9:00 AM", "Every 30 mins",
    /// "Weekly on Monday at 8am", or a five-field cron expression. A string the parser does not
    /// recognise never fires, and the card says so rather than inventing a next-run time.
    public var cronSchedule: String
    /// The directory watched by a `.fileWatch` automation. Optional so that automations saved
    /// before this field existed still decode.
    public var watchPath: String?
    public var targetAgentId: String
    public var promptTemplate: String
    public var isEnabled: Bool
    public var lastRunAt: Date?
    public var lastResultSummary: String?
    public var lastStatus: String?
    /// The session the latest run was recorded in, so an interrupted run can be found and labelled.
    public var lastSessionId: String?
    /// Continue the last run's chat instead of starting a fresh one, so a recurring job (a morning
    /// brief, a weekly review) remembers what it said last time. Optional so older automations decode.
    public var continueConversation: Bool?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        workspaceId: String = "default-workspace",
        name: String,
        description: String = "",
        triggerType: AutomationTriggerType = .manual,
        cronSchedule: String = "Hourly",
        watchPath: String? = nil,
        targetAgentId: String = "",
        promptTemplate: String = "",
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        lastResultSummary: String? = nil,
        lastStatus: String? = nil,
        continueConversation: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.continueConversation = continueConversation
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.description = description
        self.triggerType = triggerType
        self.cronSchedule = cronSchedule
        self.watchPath = watchPath
        self.targetAgentId = targetAgentId
        self.promptTemplate = promptTemplate
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.lastResultSummary = lastResultSummary
        self.lastStatus = lastStatus
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
