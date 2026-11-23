import Foundation

/// Two questions asked before an agent may call its work finished: did it check the result, and did it
/// stay in scope. Answered from what the turn actually did, not from what the agent says it did.
///
/// A heuristic, so it only nudges (at most `maxNudges` times a turn) and never blocks for good.
public enum CompletionCheck {

    public static let maxNudges = 2

    /// The calls of one turn, in order.
    public struct Log: Sendable {
        struct Call: Sendable { let tool: String; let path: String?; let success: Bool }
        var calls: [Call] = []
        public init() {}

        public mutating func record(toolName: String, argumentsJson: String, success: Bool) {
            guard success || CompletionCheck.isCheck(toolName) else { return }
            var path: String?
            if let data = argumentsJson.data(using: .utf8),
               let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                path = (raw["path"] as? String) ?? (raw["file_path"] as? String)
            }
            calls.append(Call(tool: ToolCallRepair.builtInCanonical(toolName) ?? toolName, path: path, success: success))
        }
    }

    static let creators: Set<String> = ["file_write", "write_file", "create_file", "save_file", "document_create"]
    static let editors: Set<String> = ["file_write", "write_file", "create_file", "save_file", "edit_file", "file_edit", "multi_edit", "edit_file_multi", "rename_symbol"]
    static let readers: Set<String> = ["file_read", "read_file"]
    static let checks: Set<String> = ["build_project", "run_tests", "terminal_command", "run_command", "code_diagnostics"]

    static func isCheck(_ tool: String) -> Bool { checks.contains(ToolCallRepair.builtInCanonical(tool) ?? tool) }

    static func isTestPath(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("/tests/") || p.contains("/test/") || p.contains("__tests__") || p.contains("/spec/")
            || p.hasPrefix("tests/") || p.contains(".test.") || p.contains(".spec.")
            || (p as NSString).lastPathComponent.hasSuffix("tests.swift")
    }

    static func isDocPath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["md", "rst", "txt"].contains(ext) && !isTestPath(path)
    }

    static func mentions(_ text: String, _ words: [String]) -> Bool {
        let lowered = text.lowercased()
        return words.contains { lowered.contains($0) }
    }

    /// The message to send the agent back with, or nil when the turn can end.
    public static func problem(log: Log, request: String, finalText: String) -> String? {
        let calls = log.calls
        let editIndexes = calls.indices.filter { editors.contains(calls[$0].tool) && calls[$0].success }
        guard let lastEdit = editIndexes.last else { return nil } // nothing changed, nothing to check

        // Scope first: it is the cheaper thing to undo.
        let created = calls.filter { creators.contains($0.tool) && $0.success }.compactMap(\.path)
        let tests = Array(Set(created.filter(isTestPath))).sorted()
        let docs = Array(Set(created.filter(isDocPath))).sorted()
        var extras: [String] = []
        if !tests.isEmpty, !mentions(request, ["test", "spec", "coverage"]) { extras.append("test files: " + tests.prefix(5).joined(separator: ", ")) }
        if !docs.isEmpty, !mentions(request, ["doc", "readme", "notes", "write-up", "writeup", "changelog", "markdown"]) { extras.append("documents: " + docs.prefix(5).joined(separator: ", ")) }
        if !extras.isEmpty {
            return "You created things the request did not ask for (\(extras.joined(separator: "; "))). Delete them, or tell the user plainly that you added them and why, so they can decide. Do not add unrequested files, tests or refactors."
        }

        // A build or test, or reading an edited file back: the only direct check a plain-text edit has.
        let edited = Set(calls[...lastEdit].filter { editors.contains($0.tool) && $0.success }.compactMap(\.path))
        let runs = calls[(lastEdit + 1)...].filter {
            isCheck($0.tool) || (readers.contains($0.tool) && $0.success && $0.path.map(edited.contains) == true)
        }
        guard let last = runs.last else {
            return "You changed files but have not verified the result since. Run build_project or run_tests (or another direct check), fix what fails, then report what ran and what it returned. If nothing can be run, say exactly why."
        }
        if !last.success, !mentions(finalText, ["fail", "still", "could not", "couldn't", "unable", "error"]) {
            return "Your last check failed. Fix the problem and run it again, or say plainly in your report that it still fails and why."
        }
        return nil
    }
}
