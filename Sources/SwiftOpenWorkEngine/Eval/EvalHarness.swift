import Foundation
import SwiftOpenWorkCore

/// Measured, not claimed: run a fixed set of small coding tasks through the real agent loop and
/// check each result with a command, so a change to the prompt, the tool-repair layer or the
/// sampling can be judged by a pass rate instead of by feel.
///
/// A task is a folder under `Evals/tasks`:
/// ```
/// <id>/task.json   { id, title, prompt, verify, timeout_seconds, tags }
/// <id>/files/...   the starting state of the workspace
/// ```
/// `verify` is a shell command run in the workspace afterwards; exit 0 means the task was done. It
/// is a program's opinion, not another model's, so the same run scores the same way twice.
public enum EvalHarness {

    public struct Task: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var prompt: String
        public var verify: String
        public var timeoutSeconds: Int
        public var tags: [String]

        enum CodingKeys: String, CodingKey { case id, title, prompt, verify, timeoutSeconds = "timeout_seconds", tags }

        public init(id: String, title: String, prompt: String, verify: String, timeoutSeconds: Int = 300, tags: [String] = []) {
            self.id = id; self.title = title; self.prompt = prompt; self.verify = verify
            self.timeoutSeconds = timeoutSeconds; self.tags = tags
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
            prompt = try c.decode(String.self, forKey: .prompt)
            verify = try c.decode(String.self, forKey: .verify)
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 300
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }
    }

    public struct Outcome: Codable, Equatable, Sendable {
        public var taskId: String
        public var passed: Bool
        public var seconds: Double
        public var toolCalls: Int
        public var promptTokens: Int
        public var completionTokens: Int
        /// Why the agent run itself failed (provider error, timeout), when it did.
        public var error: String?
        /// The tail of the verifier's output; what it said about a failure.
        public var verifierOutput: String
    }

    public struct Report: Codable, Equatable, Sendable {
        public var model: String
        public var provider: String
        public var startedAt: Date
        public var outcomes: [Outcome]

        public var passed: Int { outcomes.filter(\.passed).count }
        public var passRate: Double { outcomes.isEmpty ? 0 : Double(passed) / Double(outcomes.count) }
        public var totalSeconds: Double { outcomes.reduce(0) { $0 + $1.seconds } }

        /// A table for a terminal or a pull request.
        public func summary() -> String {
            var lines = ["Eval: \(model) via \(provider) — \(passed)/\(outcomes.count) passed (\(Int((passRate * 100).rounded()))%), \(Int(totalSeconds))s", ""]
            lines.append("| task | result | seconds | tool calls | tokens (in/out) |")
            lines.append("|---|---|---|---|---|")
            for o in outcomes {
                lines.append("| \(o.taskId) | \(o.passed ? "pass" : "**FAIL**") | \(Int(o.seconds)) | \(o.toolCalls) | \(o.promptTokens)/\(o.completionTokens) |")
            }
            let failed = outcomes.filter { !$0.passed }
            if !failed.isEmpty {
                lines.append("")
                for o in failed {
                    lines.append("- \(o.taskId): " + (o.error ?? String(o.verifierOutput.suffix(300))).replacingOccurrences(of: "\n", with: " ⏎ "))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// What changed between two runs of the same tasks.
    public struct Comparison: Equatable, Sendable {
        public var regressions: [String]
        public var fixes: [String]
        public var unchanged: Int

        public var summary: String {
            if regressions.isEmpty && fixes.isEmpty { return "No change across \(unchanged) tasks." }
            var parts: [String] = []
            if !regressions.isEmpty { parts.append("Regressed: " + regressions.joined(separator: ", ")) }
            if !fixes.isEmpty { parts.append("Fixed: " + fixes.joined(separator: ", ")) }
            return parts.joined(separator: ". ")
        }
    }

    public static func compare(baseline: Report, current: Report) -> Comparison {
        let before = Dictionary(baseline.outcomes.map { ($0.taskId, $0.passed) }, uniquingKeysWith: { $1 })
        var regressions: [String] = [], fixes: [String] = [], unchanged = 0
        for outcome in current.outcomes {
            guard let was = before[outcome.taskId] else { continue }
            if was && !outcome.passed { regressions.append(outcome.taskId) }
            else if !was && outcome.passed { fixes.append(outcome.taskId) }
            else { unchanged += 1 }
        }
        return Comparison(regressions: regressions.sorted(), fixes: fixes.sorted(), unchanged: unchanged)
    }

    // MARK: - Tasks

    /// Every task under `directory`, in id order. A folder without a readable `task.json` is skipped.
    public static func loadTasks(from directory: URL) -> [(task: Task, folder: URL)] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { folder -> (Task, URL)? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("task.json")),
                  let task = try? JSONDecoder().decode(Task.self, from: data) else { return nil }
            return (task, folder)
        }.sorted { $0.0.id < $1.0.id }
    }

    /// A fresh workspace holding the task's starting files, committed to git so a verifier can ask
    /// "what did the agent change".
    public static func prepare(task: Task, folder: URL, into workspace: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: workspace)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let files = folder.appendingPathComponent("files")
        if fm.fileExists(atPath: files.path) {
            for entry in try fm.contentsOfDirectory(at: files, includingPropertiesForKeys: nil) {
                try fm.copyItem(at: entry, to: workspace.appendingPathComponent(entry.lastPathComponent))
            }
        }
        for args in [["init", "-q"], ["add", "-A"],
                     ["-c", "user.name=eval", "-c", "user.email=eval@example.com", "commit", "-q", "-m", "start", "--allow-empty"]] {
            _ = GitTools.run(args, in: workspace.path)
        }
    }

    public static func verify(task: Task, in workspace: URL) async -> (passed: Bool, output: String) {
        let ran = await SubprocessRunner.run(
            executable: "/bin/zsh", arguments: ["-c", task.verify], cwd: workspace.path,
            environment: ToolExecutionEngine.defaultEnvironment(), timeout: 120
        )
        let output = (ran.stdout + ran.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return (ran.exitCode == 0 && !ran.timedOut, ran.timedOut ? "verifier timed out" : String(output.suffix(2_000)))
    }
}
