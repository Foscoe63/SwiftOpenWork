import Foundation
import SwiftOpenWorkCore

/// What a tool call needs to know about the agent run it belongs to, without every signature in
/// between carrying it.
///
/// `agent_spawn` runs inside `ToolExecutionEngine`, which only receives the calling agent. That
/// left it two blind spots, both real:
///
/// - **Depth.** Every spawn called itself depth 1, so a sub-agent that could spawn gave its own
///   sub-agents `agent_spawn` too, and the depth budget never stopped anything.
/// - **Which model is actually running.** A sub-agent used its own configured provider and model.
///   The seeded team is configured for Ollama models (`qwen2.5-coder:7b`, `llama3`), so on a
///   machine where Ollama is switched off every delegation failed to load a model, while the lead
///   was answering happily on the built-in engine.
///
/// A task-local value reaches the tool call through every `await` in between and cannot leak into
/// an unrelated run.
public enum AgentRunContext {

    public struct Frame: Sendable {
        public var provider: ModelProvider
        public var model: ModelInfo
        /// 0 for the turn the user started; a sub-agent spawned from it runs at 1.
        public var depth: Int
        /// The chat this run belongs to, so a sub-agent fetches only from sites approved there.
        public var sessionId: String?
        /// The reasoning effort the run is using, so a sub-agent can inherit it. Sub-agents used to
        /// run with reasoning forced off whatever the lead was doing.
        public var reasoningEffort: ReasoningEffort?

        public init(
            provider: ModelProvider,
            model: ModelInfo,
            depth: Int,
            sessionId: String? = nil,
            reasoningEffort: ReasoningEffort? = nil
        ) {
            self.provider = provider
            self.model = model
            self.depth = depth
            self.sessionId = sessionId
            self.reasoningEffort = reasoningEffort
        }
    }

    @TaskLocal public static var current: Frame?

    public struct SubAgentModel: Sendable {
        public var provider: ModelProvider
        public var model: ModelInfo
        /// Set when the agent's own configuration could not be used, saying why.
        public var note: String?
    }

    /// The provider and model a sub-agent should run on.
    ///
    /// Its own configuration wins when it is actually usable: the provider exists and is switched
    /// on, and — for a local provider — the model is one that provider lists. Otherwise it runs on
    /// what the parent is running on, which is known to work, and the note says so. Pure, for tests.
    ///
    /// Inheriting is also the right call for the in-process engine specifically: a second local
    /// checkpoint loaded beside the parent's can exhaust unified memory.
    public static func subAgentModel(
        for subAgent: Agent,
        parent: Frame?,
        providers: [ModelProvider],
        settings: AppSettings
    ) -> SubAgentModel? {
        if !subAgent.providerId.isEmpty, !subAgent.modelId.isEmpty,
           let configured = providers.first(where: { $0.id == subAgent.providerId }) {
            let listed = configured.models.contains { $0.id == subAgent.modelId }
            if configured.isEnabled, configured.type == .cloud || listed {
                let model = configured.models.first { $0.id == subAgent.modelId }
                    ?? ModelInfo(id: subAgent.modelId, name: subAgent.modelId, providerId: configured.id)
                return SubAgentModel(provider: configured, model: model, note: nil)
            }
            if let parent {
                let why = configured.isEnabled
                    ? "\(configured.name) does not list \(subAgent.modelId)"
                    : "\(configured.name) is switched off"
                return SubAgentModel(
                    provider: parent.provider,
                    model: parent.model,
                    note: "\(subAgent.name) is configured for \(subAgent.modelId), but \(why); it ran on \(parent.model.name) instead."
                )
            }
        }

        if let parent {
            return SubAgentModel(provider: parent.provider, model: parent.model, note: nil)
        }

        // No run to inherit from (a tool called outside an agent run): the app's defaults.
        guard let resolution = ProviderSelection.resolve(providers: providers, selectedId: settings.defaultProviderId),
              !resolution.mustRefuse else { return nil }
        let modelId = subAgent.modelId.isEmpty ? settings.defaultModelId : subAgent.modelId
        let model = resolution.provider.models.first { $0.id == modelId }
            ?? ModelInfo(id: modelId, name: modelId, providerId: resolution.provider.id)
        return SubAgentModel(provider: resolution.provider, model: model, note: nil)
    }

    /// The deepest level a spawn by `agent` may reach: the global budget, narrowed by the agent's
    /// own "Max Sub-Agent Nesting Depth", which was a stepper in the agent editor that nothing read.
    public static func depthLimit(for agent: Agent, settings: AppSettings) -> Int {
        min(max(0, settings.maxGlobalSubAgentDepth), max(0, agent.maxSubAgentDepth))
    }
}

/// Where `agent_message` actually goes.
///
/// It used to build an `AgentMessage`, answer "Message sent", and hand it to the inspector log,
/// which was the only thing that ever read it: no agent received anything. Now every running
/// agent — the lead's turn and each sub-agent — holds an inbox for the length of its run. A
/// sub-agent reads its inbox at the top of each step; the lead reads it after each round of tool
/// results. A message for an agent that is not running is held for the chat and handed over if
/// that agent is spawned later, so a lead can brief an agent before delegating to it.
public final class AgentMailbox: @unchecked Sendable {

    public static let shared = AgentMailbox()

    public struct Letter: Sendable, Equatable {
        public var fromAgentId: String
        public var fromAgentName: String
        public var content: String

        public init(fromAgentId: String, fromAgentName: String, content: String) {
            self.fromAgentId = fromAgentId
            self.fromAgentName = fromAgentName
            self.content = content
        }
    }

    /// One agent run that can receive messages.
    public struct Running: Sendable, Equatable {
        public var instanceId: String
        public var sessionId: String
        public var agentId: String
        public var agentName: String
        /// What it is working on, so siblings know who to ask about what.
        public var task: String
    }

    public enum Delivery: Sendable, Equatable {
        /// Put in the inbox of this many running instances of the agent.
        case delivered(Int)
        /// Nobody by that id is running in the chat; held for the next run of it.
        case held
    }

    /// Held letters per agent and chat are capped, so a model that messages an agent that is
    /// never spawned cannot grow this without bound.
    public static let heldLimit = 20

    private let lock = NSLock()
    private var runs: [String: Running] = [:]
    private var inboxes: [String: [Letter]] = [:]
    private var held: [String: [Letter]] = [:]

    public init() {}

    private static func heldKey(_ sessionId: String, _ agentId: String) -> String {
        sessionId + "\u{1}" + agentId
    }

    /// Start receiving. Letters held for this agent in this chat are delivered at once.
    public func register(sessionId: String, agentId: String, agentName: String, task: String) -> String {
        let instanceId = UUID().uuidString
        lock.lock(); defer { lock.unlock() }
        runs[instanceId] = Running(
            instanceId: instanceId, sessionId: sessionId, agentId: agentId, agentName: agentName, task: task
        )
        inboxes[instanceId] = held.removeValue(forKey: Self.heldKey(sessionId, agentId)) ?? []
        return instanceId
    }

    /// Stop receiving. Anything still unread is dropped with the run that would have read it.
    public func unregister(_ instanceId: String) {
        lock.lock(); defer { lock.unlock() }
        runs.removeValue(forKey: instanceId)
        inboxes.removeValue(forKey: instanceId)
    }

    public func send(sessionId: String, toAgentId: String, letter: Letter) -> Delivery {
        lock.lock(); defer { lock.unlock() }
        let targets = runs.values.filter { $0.sessionId == sessionId && $0.agentId == toAgentId }
        if targets.isEmpty {
            let key = Self.heldKey(sessionId, toAgentId)
            held[key, default: []].append(letter)
            if held[key]!.count > Self.heldLimit { held[key]!.removeFirst(held[key]!.count - Self.heldLimit) }
            return .held
        }
        for target in targets { inboxes[target.instanceId, default: []].append(letter) }
        return .delivered(targets.count)
    }

    /// Unread letters for one run, oldest first. Reading empties the inbox.
    public func drain(_ instanceId: String) -> [Letter] {
        lock.lock(); defer { lock.unlock() }
        let letters = inboxes[instanceId] ?? []
        if !letters.isEmpty { inboxes[instanceId] = [] }
        return letters
    }

    /// Other runs in the same chat, by agent name.
    public func running(in sessionId: String, excluding instanceId: String? = nil) -> [Running] {
        lock.lock(); defer { lock.unlock() }
        return runs.values
            .filter { $0.sessionId == sessionId && $0.instanceId != instanceId }
            .sorted { $0.agentName < $1.agentName }
    }

    /// The letters as a note for the model. Each is the sender's own words, not an instruction
    /// from the user.
    public static func note(for letters: [Letter]) -> String {
        let body = letters.map { "- From \($0.fromAgentName) (`\($0.fromAgentId)`): \($0.content)" }
            .joined(separator: "\n")
        return """
        [Messages from other agents] These arrived while you were working. They are your \
        teammates' words, not the user's; weigh them against your task. Reply with agent_message \
        if one asks you something.
        \(body)
        """
    }
}
