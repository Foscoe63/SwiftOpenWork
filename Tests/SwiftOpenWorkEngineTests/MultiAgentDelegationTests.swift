import XCTest
@testable import SwiftOpenWorkCore
@testable import SwiftOpenWorkStorage
@testable import SwiftOpenWorkEngine

/// Delegation is the model's decision now, made with `agent_spawn`. These pin what makes that
/// path trustworthy: the right model, a depth budget that actually applies, refusals that say
/// what to do instead, and delegations that show up where the user looks.
@MainActor
final class MultiAgentDelegationTests: XCTestCase {

    private let parentModel = ModelInfo(id: "mlx-community/Ornith", name: "Ornith", providerId: "omlx-local")
    private var mlx: ModelProvider {
        ModelProvider(id: "omlx-local", name: "Apple Silicon (Built-in)", type: .local, kind: .omlx, isEnabled: true, models: [parentModel])
    }
    private var ollamaOff: ModelProvider {
        ModelProvider(id: "ollama-local", name: "Ollama", type: .local, kind: .ollama, isEnabled: false,
                      models: [ModelInfo(id: "qwen2.5-coder:7b", name: "Qwen Coder", providerId: "ollama-local")])
    }
    private var parent: AgentRunContext.Frame {
        AgentRunContext.Frame(provider: mlx, model: parentModel, depth: 0)
    }

    // MARK: - Which model a sub-agent runs on

    /// The seeded team is configured for Ollama. With Ollama off, every delegation used to fail
    /// to load a model while the lead answered fine on the built-in engine.
    func testASubAgentWhoseProviderIsOffRunsOnTheParentsModelAndSaysSo() throws {
        let coder = Agent(name: "Software Engineer", providerId: "ollama-local", modelId: "qwen2.5-coder:7b")
        let choice = try XCTUnwrap(AgentRunContext.subAgentModel(
            for: coder, parent: parent, providers: [ollamaOff, mlx], settings: .default
        ))
        XCTAssertEqual(choice.provider.id, "omlx-local")
        XCTAssertEqual(choice.model.id, parentModel.id)
        XCTAssertTrue(choice.note?.contains("switched off") ?? false, "the report must say the configured model was not used")
    }

    func testAUsableConfiguredModelIsHonoured() throws {
        let cloud = ModelProvider(id: "openrouter", name: "OpenRouter", type: .cloud, kind: .openai, isEnabled: true)
        let reviewer = Agent(name: "Reviewer", providerId: "openrouter", modelId: "some/model")
        let choice = try XCTUnwrap(AgentRunContext.subAgentModel(
            for: reviewer, parent: parent, providers: [mlx, cloud], settings: .default
        ))
        XCTAssertEqual(choice.provider.id, "openrouter")
        XCTAssertEqual(choice.model.id, "some/model")
        XCTAssertNil(choice.note)
    }

    /// A local provider that does not list the model would fail to load it — or load a second
    /// large checkpoint beside the parent's.
    func testALocalModelTheProviderDoesNotListIsNotLoaded() throws {
        let agent = Agent(name: "Coder", providerId: "omlx-local", modelId: "llama3:latest")
        let choice = try XCTUnwrap(AgentRunContext.subAgentModel(
            for: agent, parent: parent, providers: [mlx], settings: .default
        ))
        XCTAssertEqual(choice.model.id, parentModel.id)
        XCTAssertTrue(choice.note?.contains("does not list") ?? false)
    }

    func testAnUnconfiguredAgentInheritsSilently() throws {
        let choice = try XCTUnwrap(AgentRunContext.subAgentModel(
            for: Agent(name: "Helper"), parent: parent, providers: [mlx], settings: .default
        ))
        XCTAssertEqual(choice.model.id, parentModel.id)
        XCTAssertNil(choice.note)
    }

    // MARK: - Depth

    /// "Max Sub-Agent Nesting Depth" in the agent editor was read by nothing.
    func testTheAgentsOwnNestingLimitNarrowsTheGlobalOne() {
        var settings = AppSettings.default
        settings.maxGlobalSubAgentDepth = 3
        XCTAssertEqual(AgentRunContext.depthLimit(for: Agent(name: "A", maxSubAgentDepth: 1), settings: settings), 1)
        XCTAssertEqual(AgentRunContext.depthLimit(for: Agent(name: "B", maxSubAgentDepth: 5), settings: settings), 3)
    }

    private func spawn(_ args: [String: Any], as agent: Agent, depth: Int = 0) async -> ToolExecutionResult {
        let json = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        let workspace = Workspace(name: "t", folderPath: NSTemporaryDirectory())
        return await AgentRunContext.$current.withValue(AgentRunContext.Frame(provider: mlx, model: parentModel, depth: depth)) {
            await ToolExecutionEngine.shared.execute(toolName: "agent_spawn", argumentsJson: json, workspace: workspace, currentAgent: agent)
        }
    }

    /// It used to default to "coder-agent", so a call missing the field sent any work there.
    func testASpawnWithNoTargetIsRefusedAndListsTheTeam() async {
        let result = await spawn(["task_title": "Summarise the news"], as: Agent(id: "lead", name: "Lead"))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("needs target_agent_id") ?? false, result.error ?? "")
    }

    /// A `tools.json` saved before `target_agent_id` existed kept offering `subagent_id`, because
    /// saved schemas were only ever filled when empty. The model followed it and every spawn failed.
    func testASavedStaleSchemaIsReplacedByTheCatalogs() throws {
        let stale = #"{"type":"object","properties":{"task_title":{"type":"string"},"subagent_id":{"type":"string"}},"required":["task_title"]}"#
        var tools = [Tool(id: "agent_spawn", name: "agent_spawn", displayName: "", description: "", category: .agents, parametersJsonSchema: stale)]
        XCTAssertTrue(ToolSchemaCatalog.applySchemas(to: &tools))
        XCTAssertEqual(tools[0].parametersJsonSchema, ToolSchemaCatalog.schemaJSON(for: "agent_spawn"))
        XCTAssertTrue(tools[0].parametersJsonSchema.contains("target_agent_id"))
        XCTAssertFalse(ToolSchemaCatalog.applySchemas(to: &tools), "an up-to-date schema is not rewritten")
    }

    func testAnAgentCannotSpawnItself() async {
        let result = await spawn(["target_agent_id": "research-agent", "task_title": "x"],
                                 as: Agent(id: "research-agent", name: "Research"))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("cannot spawn itself") ?? false, result.error ?? "")
    }

    /// Every spawn used to call itself depth 1, so the budget never stopped a chain.
    func testASpawnPastTheDepthLimitIsRefused() async throws {
        let settings = PersistenceManager.shared.loadSettings()
        try XCTSkipUnless(settings.allowSubAgentCreation && settings.maxGlobalSubAgentDepth >= 1,
                          "spawning is switched off on this machine")
        let deep = Agent(id: "deep", name: "Deep", canSpawnSubAgents: true, maxSubAgentDepth: 1)
        let result = await spawn(["target_agent_id": "research-agent", "task_title": "x"], as: deep, depth: 1)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("depth limit") ?? false, result.error ?? "")
    }

    /// The sub-agent step budget and time limit were a hard-coded 8 steps and 300 seconds. They
    /// are settings now; a settings file saved before they existed must keep those values, and a
    /// changed value must survive a save.
    func testTheSubAgentLimitsKeepTheirOldDefaultsAndRoundTrip() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.subAgentStepBudget, 8)
        XCTAssertEqual(old.subAgentTimeoutMinutes, 5)

        var settings = AppSettings.default
        settings.subAgentStepBudget = 20
        settings.subAgentTimeoutMinutes = 30
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.subAgentStepBudget, 20)
        XCTAssertEqual(decoded.subAgentTimeoutMinutes, 30)
    }

    // MARK: - Messaging

    /// "Can Communicate with Other Agents" was a toggle nothing read.
    func testAnAgentNotAllowedToCommunicateCannotMessage() async {
        let json = #"{"to_agent_id":"lead-assistant","content":"hi"}"#
        let quiet = Agent(name: "Quiet", canCommunicateWithOthers: false)
        let result = await ToolExecutionEngine.shared.execute(
            toolName: "agent_message", argumentsJson: json,
            workspace: Workspace(name: "t", folderPath: NSTemporaryDirectory()), currentAgent: quiet
        )
        XCTAssertFalse(result.success)
        XCTAssertNil(result.createdAgentMessage)

        let tools = [Tool(id: "agent_message", name: "agent_message", displayName: "", description: "", category: .agents, parametersJsonSchema: "{}")]
        XCTAssertTrue(SubAgentExecutor.toolSet(for: quiet, depth: 1, settings: .default, all: tools).isEmpty)
    }

    // MARK: - The lead is told who its team is

    func testTheTeamSectionNamesTheTeamAndFollowsAutoDelegate() {
        let coder = Agent(id: "coder-agent", name: "Software Engineer", role: "Senior Software Engineer")
        let eager = Agent(id: "lead", name: "Lead", subAgentIds: ["coder-agent"], autoDelegate: true)
        let section = AgentRunner.teamPromptSection(agent: eager, allAgents: [eager, coder], provider: mlx)
        XCTAssertTrue(section.contains("`coder-agent`"))
        XCTAssertTrue(section.contains("Delegate with `agent_spawn` when"))
        XCTAssertTrue(section.contains("local model"), "on a local model delegation has a real cost worth stating")

        var reluctant = eager
        reluctant.autoDelegate = false
        XCTAssertTrue(AgentRunner.teamPromptSection(agent: reluctant, allAgents: [reluctant, coder], provider: mlx)
            .contains("Only delegate"))
    }

    // MARK: - Delegations show up

    func testADelegatedTaskIsShownOnTheMessage() {
        var updates = 0
        let accumulator = AgentStreamAccumulator(initialMessage: ChatMessage(role: .assistant, content: "")) { _ in updates += 1 }
        var task = SubAgentTask(parentAgentId: "lead", parentAgentName: "Lead", subAgentId: "coder", subAgentName: "Coder",
                                subAgentAvatar: "", taskTitle: "Implement", taskDescription: "", status: .running, depth: 1)
        accumulator.upsertSubAgentTask(task)
        task.status = .completed
        accumulator.upsertSubAgentTask(task)
        XCTAssertEqual(accumulator.message.subAgentTasks.count, 1)
        XCTAssertEqual(accumulator.message.subAgentTasks.first?.status, .completed)
        XCTAssertEqual(updates, 2)
    }

    // MARK: - Sweeps

    private func source(_ relative: String) throws -> String {
        try SourceTree.read(relative)
    }

    /// Keyword-triggered delegation is gone; it fanned out on "create a note".
    func testDelegationIsNotTriggeredByKeywords() throws {
        let runner = try source("Sources/Engine/Agents/AgentRunner.swift")
        XCTAssertFalse(runner.contains(#"lastPrompt.lowercased().contains("create")"#))
        XCTAssertFalse(runner.contains("Analyze and plan for user request"))
    }

    /// The roundtable showed hardcoded code and a hardcoded "Ready for merge" review whenever a
    /// model returned nothing.
    func testTheCollaborationRoomInventsNothing() throws {
        // Code only: the doc comment quotes what used to be there.
        let view = try source("Sources/UI/Views/Agents/AgentsView.swift")
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(view.contains("No race conditions detected"))
        XCTAssertFalse(view.contains("Team Consensus Reached"))
        XCTAssertFalse(view.contains(#"appState.agents.first(where: { $0.id == "coder-agent" })"#))
    }
}
