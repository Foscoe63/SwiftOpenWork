import Foundation
import SwiftOpenWorkCore

/// Rebuilds tool calls from the `delta.tool_calls` fragments of an OpenAI-style stream.
///
/// A call arrives as a run of pieces sharing an `index`: the first carries the id and name and
/// usually an empty `arguments`, later ones carry more of the argument text. Servers differ in
/// what they leave out — no id after the first piece, no `index`, arguments as an object rather
/// than a string — and the assembly has to be stable across all of them, because the agent loop
/// keys calls by id.
public struct ToolCallStreamAssembler {

    private struct Pending {
        var id: String
        var name: String
        var arguments: String
    }

    private var pending: [Int: Pending] = [:]

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// Feed one `delta.tool_calls` array. Returns the snapshot of each call it touched that has a
    /// name by now — the same id every time for the same call, the arguments so far.
    public mutating func ingest(_ fragments: [[String: Any]]) -> [ToolCallInfo] {
        var touched: [ToolCallInfo] = []
        for (position, fragment) in fragments.enumerated() {
            let index = fragment["index"] as? Int ?? position
            let suppliedId = fragment["id"] as? String ?? ""

            var name = ""
            var argumentsDelta = ""
            var argumentsWhole: String?
            if let function = fragment["function"] as? [String: Any] {
                name = function["name"] as? String ?? ""
                if let piece = function["arguments"] as? String {
                    argumentsDelta = piece
                } else if let object = function["arguments"] as? [String: Any],
                          JSONSerialization.isValidJSONObject(object),
                          let data = try? JSONSerialization.data(withJSONObject: object),
                          let text = String(data: data, encoding: .utf8) {
                    argumentsWhole = text
                }
            }

            // The id is fixed the first time the call is seen. Minting a fresh one per piece when
            // the server never sends an id made every fragment look like its own call.
            let previous = pending[index] ?? Pending(
                id: suppliedId.isEmpty ? UUID().uuidString : suppliedId, name: "", arguments: ""
            )
            let updated = Pending(
                id: suppliedId.isEmpty ? previous.id : suppliedId,
                name: name.isEmpty ? previous.name : name,
                arguments: argumentsWhole ?? (previous.arguments + argumentsDelta)
            )
            pending[index] = updated

            // A piece that arrives before the name is not a call yet.
            if !updated.name.isEmpty { touched.append(info(updated)) }
        }
        return touched
    }

    /// Every call assembled, in the order the model made them.
    public func assembled() -> [ToolCallInfo] {
        pending.keys.sorted().compactMap { pending[$0] }.filter { !$0.name.isEmpty }.map(info)
    }

    private func info(_ call: Pending) -> ToolCallInfo {
        ToolCallInfo(
            id: call.id,
            toolName: call.name,
            argumentsJson: call.arguments.isEmpty ? "{}" : call.arguments,
            status: .running
        )
    }
}
