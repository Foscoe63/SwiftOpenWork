import Foundation
import SwiftOpenWorkCore

/// The pull request for the branch a workspace is on, and its CI, through the `gh` CLI.
///
/// "Is it green?" and "what did CI say?" are the questions that follow every push, and the answer
/// is a web page away. `gh` is used rather than a GitHub API client so the user's existing login is
/// the only credential involved: this app never sees or stores a token.
public enum PullRequestTools {

    public struct Check: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable { case passing, failing, pending, skipped }
        public var name: String
        public var state: State
        public var url: String?
        public var id: String { name }
    }

    public struct Status: Sendable, Equatable {
        public var number: Int
        public var title: String
        public var url: String
        public var branch: String
        public var isDraft: Bool
        /// OPEN, MERGED or CLOSED.
        public var state: String
        public var reviewDecision: String?
        public var checks: [Check]

        public var failing: [Check] { checks.filter { $0.state == .failing } }
        public var pending: [Check] { checks.filter { $0.state == .pending } }

        /// One line for the chip above the composer.
        public var summary: String {
            var parts = ["#\(number)"]
            if state != "OPEN" { parts.append(state.lowercased()) } else if isDraft { parts.append("draft") }
            if checks.isEmpty {
                parts.append("no checks")
            } else if !failing.isEmpty {
                parts.append("\(failing.count) failing")
            } else if !pending.isEmpty {
                parts.append("\(pending.count) running")
            } else {
                parts.append("checks passing")
            }
            if let decision = reviewDecision, !decision.isEmpty {
                parts.append(decision.replacingOccurrences(of: "_", with: " ").lowercased())
            }
            return parts.joined(separator: " · ")
        }
    }

    public enum Lookup: Sendable, Equatable {
        case status(Status)
        /// On a branch with no pull request.
        case none(branch: String)
        /// Nothing to show and nothing to say: no `gh`, not a repository, not signed in, offline.
        case unavailable(reason: String)
    }

    public static let fields = "number,title,url,state,isDraft,reviewDecision,headRefName,statusCheckRollup"

    // MARK: - Parsing

    /// `gh pr view --json` output → a status. `statusCheckRollup` mixes two shapes: check runs
    /// (`conclusion`, `status`, `name`) and commit statuses (`state`, `context`).
    public static func parseStatus(_ json: String) -> Status? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["number"] as? Int else { return nil }
        var checks: [Check] = []
        for case let entry as [String: Any] in (object["statusCheckRollup"] as? [Any]) ?? [] {
            let name = (entry["name"] as? String) ?? (entry["context"] as? String) ?? "check"
            let url = (entry["detailsUrl"] as? String) ?? (entry["targetUrl"] as? String)
            checks.append(Check(name: name, state: checkState(entry), url: url))
        }
        return Status(
            number: number,
            title: object["title"] as? String ?? "",
            url: object["url"] as? String ?? "",
            branch: object["headRefName"] as? String ?? "",
            isDraft: object["isDraft"] as? Bool ?? false,
            state: object["state"] as? String ?? "OPEN",
            reviewDecision: object["reviewDecision"] as? String,
            checks: checks
        )
    }

    static func checkState(_ entry: [String: Any]) -> Check.State {
        if let state = entry["state"] as? String { // commit status
            switch state.uppercased() {
            case "SUCCESS": return .passing
            case "FAILURE", "ERROR": return .failing
            default: return .pending
            }
        }
        let status = (entry["status"] as? String)?.uppercased() ?? ""
        if !status.isEmpty, status != "COMPLETED" { return .pending }
        switch (entry["conclusion"] as? String)?.uppercased() ?? "" {
        case "SUCCESS": return .passing
        case "NEUTRAL", "SKIPPED": return .skipped
        case "": return .pending
        default: return .failing // FAILURE, TIMED_OUT, CANCELLED, ACTION_REQUIRED, STARTUP_FAILURE
        }
    }

    // MARK: - Running gh

    /// Where `gh` is, if it is installed.
    public static func ghPath() -> String? {
        ExecutableLocator().executable(named: "gh")
    }

    public struct Ran: Sendable { public var status: Int32; public var stdout: String; public var stderr: String; public var timedOut: Bool }

    public static func gh(_ arguments: [String], in folder: String, timeout: TimeInterval = 20) async -> Ran? {
        guard let path = ghPath(), FileManager.default.fileExists(atPath: folder) else { return nil }
        var environment = ToolExecutionEngine.defaultEnvironment()
        // Never prompt: a prompt on a pipe is a hang.
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"
        let ran = await SubprocessRunner.run(executable: path, arguments: arguments, cwd: folder, environment: environment, timeout: timeout)
        return Ran(status: ran.exitCode, stdout: ran.stdout, stderr: ran.stderr, timedOut: ran.timedOut)
    }

    // MARK: - Lookups

    public static func lookup(in folder: String) async -> Lookup {
        guard ghPath() != nil else { return .unavailable(reason: "The GitHub CLI (gh) is not installed. `brew install gh`, then `gh auth login`.") }
        guard GitTools.isRepository(folder) else { return .unavailable(reason: "Not a git repository.") }
        guard let ran = await gh(["pr", "view", "--json", fields], in: folder) else { return .unavailable(reason: "gh could not run.") }
        if ran.timedOut { return .unavailable(reason: "gh timed out.") }
        if ran.status == 0, let status = parseStatus(ran.stdout) { return .status(status) }
        let message = ran.stderr.lowercased()
        if message.contains("no pull requests found") || message.contains("no open pull requests") {
            let branch = GitTools.run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .none(branch: branch)
        }
        if message.contains("auth") || message.contains("login") {
            return .unavailable(reason: "gh is not signed in. Run `gh auth login`.")
        }
        return .unavailable(reason: ran.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? "gh failed.")
    }

    /// The tail of the failing jobs' logs for the branch's latest run: what an agent needs to fix CI.
    public static func failedLogs(in folder: String, maxCharacters: Int = 12_000) async -> String? {
        guard let list = await gh(["run", "list", "--branch", currentBranch(in: folder) ?? "", "--limit", "5", "--json", "databaseId,conclusion,status,name"], in: folder),
              list.status == 0,
              let data = list.stdout.data(using: .utf8),
              let runs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let failed = runs.first(where: { ($0["conclusion"] as? String)?.lowercased() == "failure" }),
              let id = failed["databaseId"] as? Int,
              let logs = await gh(["run", "view", String(id), "--log-failed"], in: folder, timeout: 60),
              logs.status == 0, !logs.stdout.isEmpty else { return nil }
        let text = logs.stdout
        return text.count > maxCharacters ? "[…earlier output clipped]\n" + String(text.suffix(maxCharacters)) : text
    }

    static func currentBranch(in folder: String) -> String? {
        GitTools.run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tool output

    public static func describe(_ lookup: Lookup, failedLogs: String? = nil) -> (text: String, success: Bool) {
        switch lookup {
        case let .unavailable(reason):
            return (reason, false)
        case let .none(branch):
            return ("Branch \(branch) has no pull request. `pr_create` opens one.", true)
        case let .status(status):
            var lines = ["#\(status.number) \(status.title)", status.url, "\(status.state)\(status.isDraft ? " (draft)" : "") · branch \(status.branch)"]
            if let decision = status.reviewDecision, !decision.isEmpty { lines.append("Review: \(decision)") }
            if status.checks.isEmpty {
                lines.append("No checks have reported.")
            } else {
                lines.append("Checks:")
                for check in status.checks { lines.append("  \(check.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(check.name)") }
            }
            if let failedLogs { lines.append("\nFailed job log (tail):\n" + failedLogs) }
            return (lines.joined(separator: "\n"), true)
        }
    }

    /// Open a pull request for the current branch. Pushes the branch first, since a PR needs it on
    /// the remote; the caller has already had the person approve both.
    public static func create(
        in folder: String, title: String, body: String, base: String?, draft: Bool
    ) async -> (text: String, success: Bool) {
        guard ghPath() != nil else { return ("The GitHub CLI (gh) is not installed. `brew install gh`, then `gh auth login`.", false) }
        guard let branch = currentBranch(in: folder), branch != "HEAD" else {
            return ("Not on a branch (detached HEAD). Create or switch to a branch first.", false)
        }
        if let base, base == branch { return ("The branch \(branch) is the base branch; there is nothing to open a PR from.", false) }
        let dirty = (GitTools.run(["status", "--porcelain"], in: folder) ?? "").split(separator: "\n").count
        guard let push = await runGit(["push", "-u", "origin", "HEAD"], in: folder) else { return ("git could not run.", false) }
        if push.status != 0 {
            return ("git push failed:\n" + push.stderr.trimmingCharacters(in: .whitespacesAndNewlines), false)
        }
        var arguments = ["pr", "create", "--title", title, "--body", body]
        if let base, !base.isEmpty { arguments += ["--base", base] }
        if draft { arguments.append("--draft") }
        guard let ran = await gh(arguments, in: folder, timeout: 60) else { return ("gh could not run.", false) }
        guard ran.status == 0 else { return ("gh pr create failed:\n" + ran.stderr.trimmingCharacters(in: .whitespacesAndNewlines), false) }
        var text = ran.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if dirty > 0 { text += "\nNote: \(dirty) uncommitted change(s) are not in this pull request." }
        return (text, true)
    }

    private static func runGit(_ arguments: [String], in folder: String) async -> Ran? {
        var environment = ToolExecutionEngine.defaultEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let ran = await SubprocessRunner.run(
            executable: "/usr/bin/env", arguments: ["git"] + arguments, cwd: folder, environment: environment, timeout: 90
        )
        return Ran(status: ran.exitCode, stdout: ran.stdout, stderr: ran.stderr, timedOut: ran.timedOut)
    }
}
