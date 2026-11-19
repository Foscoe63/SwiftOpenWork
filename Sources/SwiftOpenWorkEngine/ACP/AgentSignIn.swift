import Foundation
import SwiftOpenWorkCore

/// The coding agents the app expects to find on every Mac, each with its own sign-in: Claude Code
/// under the CLI login, Claude Code under the Desktop login, and OpenCode.
///
/// The agents themselves are seeded into the agent list the first time the app runs on a Mac, so a
/// new computer has them without setup. The sign-ins are not copied: tokens live in that Mac's
/// Keychain (Claude) or `~/.local/share/opencode` (OpenCode), and moving them around would mean
/// handling secrets. On a new Mac you sign in once from Settings → Agent Sign-ins.
public struct AgentSignInProfile: Identifiable, Hashable, Sendable {
    public enum Kind: Sendable { case claude, opencode }

    public var id: String
    public var name: String
    public var detail: String
    public var kind: Kind
    /// Claude only: the folder that holds this login (`CLAUDE_CONFIG_DIR`).
    public var configDir: String?
    public var config: ExternalAgentConfig

    /// The adapter that lets this app drive Claude Code over ACP.
    private static let claudeAdapter = ["-y", "@agentclientprotocol/claude-agent-acp"]

    public static let all: [AgentSignInProfile] = [
        AgentSignInProfile(
            id: "builtin-claude-cli", name: "Claude Code (CLI)",
            detail: "The Claude login used for command-line work, kept in ~/.claude-cli",
            kind: .claude, configDir: NSHomeDirectory() + "/.claude-cli",
            config: ExternalAgentConfig(command: "npx", args: claudeAdapter,
                                        env: ["CLAUDE_CONFIG_DIR": NSHomeDirectory() + "/.claude-cli"])),
        AgentSignInProfile(
            id: "builtin-claude-desktop", name: "Claude Code (Desktop)",
            detail: "The Claude login used for desktop work, kept in ~/.claude-desktop",
            kind: .claude, configDir: NSHomeDirectory() + "/.claude-desktop",
            config: ExternalAgentConfig(command: "npx", args: claudeAdapter,
                                        env: ["CLAUDE_CONFIG_DIR": NSHomeDirectory() + "/.claude-desktop"])),
        AgentSignInProfile(
            id: "builtin-opencode", name: "OpenCode",
            detail: "The open-source agent. Its provider sign-ins are kept by OpenCode itself",
            kind: .opencode, configDir: nil,
            config: ExternalAgentConfig(command: "opencode", args: ["acp"])),
    ]

    /// The command that signs in or out of this profile.
    public enum Action: String, Sendable { case login, logout }

    /// The program to run for this profile's sign-in commands.
    var program: String { kind == .claude ? "claude" : "opencode" }

    public func makeAgent() -> Agent {
        var agent = Agent(
            id: id, name: name, description: detail, avatar: "terminal", color: "#0EA5E9",
            role: "External coding agent", systemPrompt: "", tags: ["External"], externalAgent: config
        )
        agent.canSpawnSubAgents = false
        return agent
    }

    /// Whether `agents` already has an agent that runs this profile: the same id, or the same
    /// program and login folder (for example one added by hand from the External Agents list).
    public func isPresent(in agents: [Agent]) -> Bool {
        agents.contains { agent in
            if agent.id == id { return true }
            guard let other = agent.externalAgent else { return false }
            if kind == .claude {
                return ClaudeCodeUsage.configDir(for: other) == configDir
            }
            return other.command == config.command && other.args == config.args
        }
    }

    // MARK: - Seeding

    private static let seededKey = "agentSignIns.seeded"

    /// Adds each profile's agent once per Mac. A profile that was seeded before is never added
    /// again, so an agent the person removed stays removed; Settings has an Add button for it.
    /// Returns whether `agents` changed.
    @discardableResult
    public static func seedMissing(into agents: inout [Agent], defaults: UserDefaults = .standard) -> Bool {
        var seeded = Set(defaults.stringArray(forKey: seededKey) ?? [])
        var changed = false
        for profile in all where !seeded.contains(profile.id) {
            seeded.insert(profile.id)
            if !profile.isPresent(in: agents) {
                agents.append(profile.makeAgent())
                changed = true
            }
        }
        defaults.set(Array(seeded), forKey: seededKey)
        return changed
    }
}

/// Whether a profile is signed in on this Mac.
public enum AgentSignInStatus: Equatable, Sendable {
    case notInstalled
    case signedOut
    case signedIn(String?)
    case unknown(String)
}

public enum AgentSignIn {

    /// Reads the sign-in state by asking the program itself. Never prompts.
    public static func status(for profile: AgentSignInProfile) async -> AgentSignInStatus {
        await Task.detached(priority: .utility) {
            guard let executable = ExecutableLocator().executable(named: profile.program) else { return .notInstalled }
            var env = ProcessInfo.processInfo.environment
            if let dir = profile.configDir { env["CLAUDE_CONFIG_DIR"] = dir }
            switch profile.kind {
            case .claude:
                guard let out = run(executable, ["auth", "status"], env: env) else { return .unknown("`claude auth status` did not answer") }
                return parseClaudeStatus(out)
            case .opencode:
                guard let out = run(executable, ["auth", "list"], env: env) else { return .unknown("`opencode auth list` did not answer") }
                return parseOpenCodeList(out)
            }
        }.value
    }

    /// `claude auth status` prints JSON with `loggedIn` and `email`.
    static func parseClaudeStatus(_ output: String) -> AgentSignInStatus {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = object["loggedIn"] as? Bool else {
            return .unknown("Unexpected output from `claude auth status`")
        }
        return loggedIn ? .signedIn(object["email"] as? String) : .signedOut
    }

    /// `opencode auth list` prints one `●` line per saved credential.
    static func parseOpenCodeList(_ output: String) -> AgentSignInStatus {
        let credentials = output.split(separator: "\n").filter { $0.contains("●") }
        if credentials.isEmpty { return .signedOut }
        let count = credentials.count
        return .signedIn("\(count) provider\(count == 1 ? "" : "s")")
    }

    /// Writes a `.command` script that runs the sign-in (or sign-out) in Terminal, where the
    /// browser hand-off and any code to paste work as they do from a shell, and returns its URL for
    /// the caller to open. The script uses a login shell so Node and Homebrew are on the PATH.
    public static func terminalScript(for profile: AgentSignInProfile, action: AgentSignInProfile.Action) throws -> URL {
        guard let executable = ExecutableLocator().executable(named: profile.program) else {
            throw SignInError.notInstalled(profile.program)
        }
        var lines = ["#!/bin/zsh -l", "clear"]
        if let dir = profile.configDir { lines.append("export CLAUDE_CONFIG_DIR=\(quote(dir))") }
        lines.append("echo \(quote("\(profile.name): \(action.rawValue)"))")
        lines.append("\(quote(executable)) auth \(action.rawValue)")
        lines.append("echo")
        lines.append("echo 'Finished. Return to the app and press Refresh. You can close this window.'")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(action.rawValue)-\(profile.id).command")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    public enum SignInError: LocalizedError {
        case notInstalled(String)
        public var errorDescription: String? {
            switch self {
            case let .notInstalled(program): return "`\(program)` was not found on this Mac. Install it first."
            }
        }
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a program to completion (10 seconds at most) and returns its output, or nil if it
    /// could not run or did not finish.
    private static func run(_ executable: String, _ args: [String], env: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
