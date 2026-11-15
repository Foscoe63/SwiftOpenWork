import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// The Team map: departments, who sits in each, what they share, and who a tagged message goes to.
///
/// Every change goes through `TeamMapStore.update`, which reads the file, changes it and writes it under
/// one lock. An agent's `propose_team_memory` call changes the same file from another thread; going
/// through the store is what keeps either side from saving over the other with a stale copy.
extension AppState {
    // MARK: Reading

    public var teamSections: [TeamMapSection] { TeamMapLogic.sections(agents: agents, state: teamMap) }

    public func department(of agentId: String) -> String { teamMap.department(of: agentId) }

    public func departmentLabel(_ key: String) -> String { key.isEmpty ? "General" : key }

    /// Every department there is, General ("") first when it has anyone in it.
    public var allDepartmentKeys: [String] { teamSections.map(\.key) }

    /// Reloads the map from disk (an agent's tool call may have changed it).
    public func reloadTeamMap() {
        let loaded = PersistenceManager.shared.loadTeamMap()
        if loaded != teamMap { teamMap = loaded }
    }

    @discardableResult
    func mutateTeamMap<T>(_ change: (inout TeamMapState) -> T) -> T {
        let (result, state) = TeamMapStore.shared.update(change)
        teamMap = state
        return result
    }

    // MARK: Departments

    private func departmentNameTaken(_ name: String) -> Bool {
        let all = teamMap.departments + teamMap.assignments.values
        return all.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            || name.caseInsensitiveCompare("General") == .orderedSame
            // `@name` has to mean one thing.
            || agents.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func cleanDepartmentName(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(TeamMapLogic.maxNameLength))
    }

    /// Makes a department, optionally moving agents into it. False when the name is empty or taken.
    @discardableResult
    public func createDepartment(_ rawName: String, agentIds: [String] = []) -> Bool {
        let name = Self.cleanDepartmentName(rawName)
        guard !name.isEmpty, !departmentNameTaken(name) else { return false }
        let roster = agents
        let ids = Set(agents.map(\.id))
        mutateTeamMap { state in
            TeamMapLogic.grantNewDepartment(name, agents: roster, state: &state)
            state.departments.append(name)
            for id in agentIds where ids.contains(id) { Self.place(id, in: name, state: &state) }
        }
        return true
    }

    /// Makes a department from a starting line-up: its agents are created (named "<department> <Role>"),
    /// put in the department, and given the template's shared instructions. Returns the new agents, or an
    /// empty list when the name is empty or taken.
    @discardableResult
    public func createDepartment(from template: DepartmentTemplate, named rawName: String) -> [Agent] {
        let name = Self.cleanDepartmentName(rawName)
        guard !name.isEmpty, !departmentNameTaken(name) else { return [] }
        let made = template.makeAgents(department: name, existingNames: agents.map(\.name)).map { agent -> Agent in
            var agent = agent
            // The lead delegates on the session's own model unless the person picks one.
            agent.temperature = settings.defaultTemperature
            return agent
        }
        agents.append(contentsOf: made)
        PersistenceManager.shared.saveAgents(agents)
        let roster = agents
        mutateTeamMap { state in
            TeamMapLogic.grantNewDepartment(name, agents: roster, state: &state)
            state.departments.append(name)
            for agent in made { Self.place(agent.id, in: name, state: &state) }
            state.agentOrders[name] = made.map(\.id)
            if DepartmentInstructions.isValid(template.instructions) {
                state.instructions[name] = DepartmentInstructions(text: template.instructions)
            }
        }
        return made
    }

    @discardableResult
    public func renameDepartment(_ old: String, to rawName: String) -> Bool {
        let name = Self.cleanDepartmentName(rawName)
        guard !old.isEmpty, !name.isEmpty, name != old, !departmentNameTaken(name) else { return false }
        mutateTeamMap { state in
            state.departments = state.departments.map { $0 == old ? name : $0 }
            if !state.departments.contains(name) { state.departments.append(name) }
            for (id, dept) in state.assignments where dept == old { state.assignments[id] = name }
            if let p = state.positions.removeValue(forKey: old) { state.positions[name] = p }
            if let o = state.agentOrders.removeValue(forKey: old) { state.agentOrders[name] = o }
            if let brief = state.instructions.removeValue(forKey: old) { state.instructions[name] = brief }
            if let notes = state.facts.removeValue(forKey: old) { state.facts[name] = notes }
            TeamMapLogic.renameManaged(old, to: name, state: &state)
        }
        return true
    }

    /// Removes the department. Its agents are kept and go back to General.
    public func deleteDepartment(_ name: String) {
        guard !name.isEmpty else { return }
        mutateTeamMap { state in
            state.departments.removeAll { $0 == name }
            state.assignments = state.assignments.filter { $0.value != name }
            state.positions[name] = nil
            state.agentOrders[name] = nil
            state.instructions[name] = nil
            state.facts[name] = nil
            TeamMapLogic.dropManaged(name, state: &state)
        }
    }

    private static func place(_ agentId: String, in dept: String, state: inout TeamMapState) {
        if dept.isEmpty { state.assignments[agentId] = nil } else { state.assignments[agentId] = dept }
        for key in Array(state.agentOrders.keys) { state.agentOrders[key]?.removeAll { $0 == agentId } }
    }

    /// Moves an agent to a department ("" is General); it lands at the end of its lane.
    public func moveAgent(_ agentId: String, toDepartment dept: String) {
        guard agents.contains(where: { $0.id == agentId }) else { return }
        guard dept.isEmpty || teamSections.contains(where: { $0.key == dept }) else { return }
        mutateTeamMap { Self.place(agentId, in: dept, state: &$0) }
    }

    /// Puts `agentId` at `index` among the agents of its own kind (leads or members) in its department.
    public func arrangeAgent(_ agentId: String, toIndex index: Int) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }
        let dept = department(of: agentId)
        guard let section = teamSections.first(where: { $0.key == dept }) else { return }
        let lane = (agent.isLeadAgent ? section.leads : section.members).map(\.id)
        let other = (agent.isLeadAgent ? section.members : section.leads).map(\.id)
        mutateTeamMap { $0.agentOrders[dept] = TeamMapLogic.reorder(lane, moving: agentId, to: index) + other }
    }

    public func setDepartmentPosition(_ dept: String, _ point: CanvasPoint) {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) < 100_000, abs(point.y) < 100_000 else { return }
        mutateTeamMap { $0.positions[dept] = point }
    }

    /// Makes `agentId` the department's lead (or takes the lead off), so a message tagged to the department
    /// reaches it. Only the lead flag changes; the agent keeps everything else.
    public func setLead(_ agentId: String, _ on: Bool) {
        guard let i = agents.firstIndex(where: { $0.id == agentId }), agents[i].isLeadAgent != on else { return }
        agents[i].isLeadAgent = on
        if on {
            // A lead that cannot delegate is a lead in name only.
            agents[i].canSpawnSubAgents = true
            agents[i].maxSubAgentDepth = max(agents[i].maxSubAgentDepth, 2)
        }
        PersistenceManager.shared.saveAgents(agents)
        if !on { mutateTeamMap { $0.managed[agentId] = nil } }
    }

    /// Drops what the map holds for an agent that was deleted.
    func forgetAgentInTeamMap(_ agentId: String) {
        mutateTeamMap { state in
            state.assignments[agentId] = nil
            state.managed[agentId] = nil
            for key in Array(state.agentOrders.keys) { state.agentOrders[key]?.removeAll { $0 == agentId } }
        }
    }

    // MARK: Authority

    public func isInCharge(_ lead: Agent, of department: String) -> Bool {
        TeamMapLogic.isInCharge(lead, of: department, state: teamMap)
    }

    public func hasAuthority(_ leadId: String, over targetId: String) -> Bool {
        TeamMapLogic.hasAuthority(leadId, over: targetId, agents: agents, state: teamMap)
    }

    /// Sets the departments (besides its own) a lead is in charge of. Only the person calls this.
    @discardableResult
    public func setManagedDepartments(_ leadId: String, _ names: [String]) -> Bool {
        let roster = agents
        return mutateTeamMap { TeamMapLogic.setManaged(leadId, names, agents: roster, state: &$0) }
    }

    // MARK: Shared instructions

    public enum DepartmentInstructionsResult: Equatable, Sendable {
        case saved, cleared
        case tooLong(bytes: Int, limit: Int)
        case unknownDepartment
    }

    public func departmentInstructions(_ department: String) -> DepartmentInstructions? {
        teamMap.instructions[department.trimmingCharacters(in: .whitespaces)]
    }

    /// Saves, replaces or (for blank text) clears a department's shared instructions. Refuses text over the
    /// byte limit without touching what is saved, and a department that does not exist.
    @discardableResult
    public func setDepartmentInstructions(_ department: String, text: String, now: Date = Date()) -> DepartmentInstructionsResult {
        let key = department.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, !teamSections.contains(where: { $0.key == key }) { return .unknownDepartment }
        let bytes = DepartmentInstructions.byteCount(text)
        guard bytes <= DepartmentInstructions.maxBytes else { return .tooLong(bytes: bytes, limit: DepartmentInstructions.maxBytes) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if teamMap.instructions[key] != nil { mutateTeamMap { $0.instructions[key] = nil } }
            return .cleared
        }
        mutateTeamMap { $0.instructions[key] = DepartmentInstructions(text: text, updatedAt: now) }
        return .saved
    }

    // MARK: Shared notes

    private func factsKey(_ department: String) -> String { department.trimmingCharacters(in: .whitespaces) }

    /// Notes still in play (accepted and proposed): proposals first, then pinned, then newest.
    public func departmentFacts(_ department: String) -> [DepartmentFact] {
        func rank(_ f: DepartmentFact) -> Int { f.status == .proposed ? 2 : (f.pinned ? 1 : 0) }
        return (teamMap.facts[factsKey(department)] ?? []).filter(\.isActive)
            .sorted { (rank($0), $0.updatedAt) > (rank($1), $1.updatedAt) }
    }

    public func pendingFactCount(_ department: String) -> Int {
        (teamMap.facts[factsKey(department)] ?? []).filter { $0.status == .proposed }.count
    }

    public var totalPendingFacts: Int { teamMap.facts.values.reduce(0) { $0 + $1.filter { $0.status == .proposed }.count } }

    /// One note in any state (a chat card shows accepted, rejected and replaced notes too).
    public func departmentFact(_ department: String, id: String) -> DepartmentFact? {
        (teamMap.facts[factsKey(department)] ?? []).first { $0.id == id }
    }

    public func departmentMemorySelection(_ department: String) -> DepartmentMemory.Selection {
        DepartmentMemory.promptSelection(teamMap.facts[factsKey(department)] ?? [], department: department)
    }

    private func mutateFacts<T>(_ department: String, _ change: (inout [DepartmentFact]) throws -> T) throws -> T {
        let key = factsKey(department)
        if !key.isEmpty, !teamSections.contains(where: { $0.key == key }) { throw DepartmentMemoryError.unknownDepartment }
        let (result, state) = try TeamMapStore.shared.update { state -> T in
            var list = state.facts[key] ?? []
            let result = try change(&list)
            state.facts[key] = list.isEmpty ? nil : list
            return result
        }
        teamMap = state
        return result
    }

    @discardableResult
    public func addDepartmentFact(_ department: String, _ input: DepartmentFactInput) throws -> DepartmentFact {
        try mutateFacts(department) { try DepartmentMemory.add(&$0, input) }
    }

    @discardableResult
    public func resolveDepartmentFact(_ department: String, id: String, accept: Bool, expectedRevision: Int? = nil) throws -> DepartmentMemory.Resolution {
        try mutateFacts(department) { try DepartmentMemory.resolve(&$0, id: id, accept: accept, expectedRevision: expectedRevision) }
    }

    @discardableResult
    public func updateDepartmentFact(_ department: String, id: String, patch: DepartmentFactPatch, expectedRevision: Int? = nil) throws -> DepartmentFact {
        try mutateFacts(department) { try DepartmentMemory.update(&$0, id: id, patch: patch, expectedRevision: expectedRevision) }
    }

    public func undoDepartmentFactAccept(_ department: String, id: String) throws {
        try mutateFacts(department) { try DepartmentMemory.undoAccept(&$0, id: id) }
    }

    public func removeDepartmentFact(_ department: String, id: String, expectedRevision: Int? = nil) throws {
        try mutateFacts(department) { try DepartmentMemory.remove(&$0, id: id, expectedRevision: expectedRevision) }
    }

    /// Accepted notes of a department found by words (what an agent's `search_team_memory` does).
    public func searchDepartmentFacts(_ department: String, query: String, limit: Int = 12) -> [DepartmentFact] {
        DepartmentMemory.search(teamMap.facts[factsKey(department)] ?? [], query: query, limit: limit)
    }

    // MARK: Usage

    /// Billed tokens per department over the last `days` days, from every chat's replies.
    public func departmentUsage(days: Int = 7, now: Date = Date()) -> [DepartmentUsage] {
        TeamMapLogic.usageByDepartment(
            sessions.flatMap(\.messages), since: now.addingTimeInterval(-Double(days) * 86_400), sections: teamSections
        )
    }

    // MARK: Tagging

    /// Who a message goes to when its text tags an agent, a department or everyone, one step each in
    /// the order tagged. A department goes to its lead, who delegates to the rest and answers once.
    func taggedSteps(for text: String, reasoning: (Agent) -> ReasoningEffort) -> (steps: [TurnStep], emptyTags: [String]) {
        let targets = TeamMapLogic.targets(text: text, agents: agents, state: teamMap)
        guard !targets.isEmpty else { return ([], []) }
        let recipients = TeamMapLogic.recipients(for: targets, agents: agents, state: teamMap)
        var steps: [TurnStep] = []
        for r in recipients {
            guard let agent = agents.first(where: { $0.id == r.agentId }) else { continue }
            let notice: String?
            switch r.reason {
            case .agent: notice = nil
            case .departmentLead(let dept): notice = "Sent to \(dept): \(agent.name) leads it and will hand the work to the team."
            case .departmentMember(let dept): notice = "\(dept) has no lead, so \(agent.name) got this directly."
            case .everyoneLead: notice = "Sent to everyone: \(agent.name) is the lead over the whole team and will pass it on."
            }
            steps.append(TurnStep(agent: agent, group: nil, reasoning: reasoning(agent), notice: notice))
        }
        let empty = targets.tags.compactMap { tag -> String? in
            guard case .department(let key) = tag, teamSections.first(where: { $0.key == key })?.count == 0 else { return nil }
            return key
        }
        return (steps, empty)
    }

    /// Sends what was typed on the Team map as a new chat: the tags in it pick who answers.
    public func sendFromTeamMap(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isGenerating else { return }
        if TeamMapLogic.targets(text: message, agents: agents, state: teamMap).isEmpty {
            showToast("Tag an agent, a department or @everyone to send a message.")
            return
        }
        createNewSession()
        sendMessage(text: message)
    }
}
