import Foundation
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// An agent's two tools for its department's shared notes: propose one, and search the accepted ones.
// Only the person accepts, edits and deletes; see `DepartmentMemory`.

extension ToolExecutionEngine {
    static let teamToolHandlers: [ToolRegistration] = [
        ToolRegistration(["propose_team_memory"]) { await $0.proposeTeamMemoryTool($1) },
        ToolRegistration(["search_team_memory"]) { await $0.searchTeamMemoryTool($1) },
    ]

    /// The line a chat card reads to find the note it shows. Kept out of the sentence the model reads.
    static func teamNoteMarker(department: String, id: String) -> String {
        "[team-note dept=\(department.replacingOccurrences(of: "]", with: "")) id=\(id)]"
    }

    func proposeTeamMemoryTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let agent = call.currentAgent
        let startTime = call.startTime
        func done(_ ok: Bool, _ text: String) -> ToolExecutionResult {
            ToolExecutionResult(success: ok, output: ok ? text : "", error: ok ? nil : text,
                                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
        guard let kind = DepartmentFactKind(rawValue: ((dict["kind"] as? String) ?? "").lowercased()) else {
            return done(false, "propose_team_memory needs kind: one of person, place, decision, term.")
        }
        let aliases = (dict["aliases"] as? [String]) ?? []
        let input = DepartmentFactInput(
            kind: kind, name: dict["name"] as? String ?? "", detail: dict["detail"] as? String ?? "",
            aliases: aliases, key: dict["key"] as? String
        )
        do {
            let (fact, state) = try TeamMapStore.shared.update { state -> DepartmentFact in
                let dept = state.department(of: agent.id)
                var list = state.facts[dept] ?? []
                let made = try DepartmentMemory.propose(&list, input, sourceAgentId: agent.id, sourceName: agent.name)
                state.facts[dept] = list
                return made
            }
            let dept = state.department(of: agent.id)
            let label = dept.isEmpty ? "General" : dept
            return done(true, """
            Proposed "\(fact.name)" for the "\(label)" department's team memory. The person reviews it; until they accept it, it is not in anyone's prompt. Do not wait for it or propose it again.
            \(Self.teamNoteMarker(department: dept, id: fact.id))
            """)
        } catch {
            return done(false, error.localizedDescription)
        }
    }

    func searchTeamMemoryTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let agent = call.currentAgent
        let startTime = call.startTime
        let query = (dict["query"] as? String) ?? ""
        let limit = (dict["limit"] as? Int) ?? Int(dict["limit"] as? String ?? "") ?? 12
        let state = TeamMapStore.shared.loadState()
        let dept = state.department(of: agent.id)
        let found = DepartmentMemory.search(state.facts[dept] ?? [], query: query, limit: limit)
        let text: String
        if found.isEmpty {
            text = "No accepted team notes match '\(query)'."
        } else {
            text = "Team notes (\(found.count)):\n" + found.map { f in
                let also = f.aliases.isEmpty ? "" : " (also: \(f.aliases.joined(separator: ", ")))"
                return "- [\(f.kind.rawValue)] \(f.name)\(also): \(f.detail)"
            }.joined(separator: "\n")
        }
        return ToolExecutionResult(success: true, output: text, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
    }
}
