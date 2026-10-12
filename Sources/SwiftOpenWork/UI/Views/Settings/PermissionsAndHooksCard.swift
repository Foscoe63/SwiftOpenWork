import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Edit the workspace's standing permission rules and lifecycle hooks, and trust a project's hooks.
public struct PermissionsAndHooksCard: View {
    @ObservedObject var appState: AppState
    @State private var rules = ""
    @State private var hooks = ""
    @State private var status: String?
    @State private var trust: ToolHooks.ProjectStatus = .none
    @State private var didLoad = false

    public init(appState: AppState) {
        self.appState = appState
    }

    private var root: String? {
        appState.workspaces.first { $0.id == appState.activeWorkspaceId }?.folderPath
    }

    private static let rulesExample = """
    {
      "allow": ["terminal_command(git status*)", "terminal_command(swift build*)"],
      "ask":   ["terminal_command(git push*)"],
      "deny":  ["file_*(**/.env*)", "terminal_command(rm -rf *)"]
    }
    """

    private static let hooksExample = """
    {
      "hooks": {
        "PostToolUse": [
          { "matcher": "edit_file|file_write",
            "hooks": [ { "type": "command", "command": "./scripts/format.sh", "timeout": 20 } ] }
        ]
      }
    }
    """

    public var body: some View {
        SettingsCard(
            title: "Permission Rules & Hooks",
            description: "Per-project rules that allow, ask or deny individual tool calls, and commands the app runs at fixed points — before and after a tool, when you send a message, when a turn ends.",
            icon: "checkmark.shield"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if root == nil {
                    Text("Open a workspace to edit its rules.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    editor(
                        title: "Permission rules", file: PermissionRules.relativePath, text: $rules,
                        help: "Deny beats ask beats allow. An allow never covers a chained command (a; b, a && b, a | b, redirects), and never lifts the guards on secret files, plan mode and new sites."
                    )
                    HStack {
                        Spacer()
                        Button("Insert example") { if rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { rules = Self.rulesExample } }
                            .controlSize(.small)
                        Button("Save rules") { save(rules, to: PermissionRules.projectPath(workspaceRoot: root ?? "")) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }

                    Divider()

                    editor(
                        title: "Hooks", file: ToolHooks.relativePath, text: $hooks,
                        help: "Events: PreToolUse, PostToolUse, UserPromptSubmit, Stop. Exit code 2 blocks (stderr is the reason). The file format matches Claude Code's hooks."
                    )
                    trustRow
                    HStack {
                        Spacer()
                        Button("Insert example") { if hooks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hooks = Self.hooksExample } }
                            .controlSize(.small)
                        Button("Save hooks") { save(hooks, to: ToolHooks.projectPath(workspaceRoot: root ?? "")) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                if let status {
                    Text(status).font(.system(size: 11)).foregroundColor(.secondary)
                }
                HStack {
                    Button("Reveal audit log") {
                        let directory = AuditLog.shared.directory
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(directory)
                    }
                    .controlSize(.small)
                    Text("One file per chat: every tool call, who allowed it, how it ended. Secrets are scrubbed.")
                        .font(.system(size: 10.5)).foregroundColor(.secondary)
                }
                Text("Your own rules and hooks for every project: \(ToolHooks.globalPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")) and \(PermissionRules.globalPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
            }
            .onAppear { if !didLoad { didLoad = true; reload() } }
            .onChange(of: appState.activeWorkspaceId) { _, _ in reload() }
        }
    }

    @ViewBuilder
    private var trustRow: some View {
        switch trust {
        case .none:
            EmptyView()
        case .trusted:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Trusted: these hooks run.").font(.system(size: 11))
                Spacer()
                Button("Revoke") { if let root { ToolHooks.revokeProjectTrust(workspaceRoot: root); reload() } }
                    .controlSize(.small)
            }
        case let .untrusted(commands):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Not running. Hooks are commands that run as you — only trust a file you have read.")
                        .font(.system(size: 11))
                }
                ForEach(Array(commands.prefix(6).enumerated()), id: \.offset) { _, command in
                    Text(command).font(.system(size: 10.5, design: .monospaced)).foregroundColor(.secondary).lineLimit(2)
                }
                Button("Trust these hooks") { if let root { ToolHooks.trustProject(workspaceRoot: root); reload() } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Text("Saving the file again withdraws trust.").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    private func editor(title: String, file: String, text: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(file).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            }
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))
            Text(help).font(.system(size: 10.5)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reload() {
        guard let root else { return }
        rules = (try? String(contentsOfFile: PermissionRules.projectPath(workspaceRoot: root), encoding: .utf8)) ?? ""
        hooks = (try? String(contentsOfFile: ToolHooks.projectPath(workspaceRoot: root), encoding: .utf8)) ?? ""
        trust = ToolHooks.projectStatus(workspaceRoot: root)
        status = nil
    }

    private func save(_ text: String, to path: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) == nil {
            status = "Not saved: that is not valid JSON."
            return
        }
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            if trimmed.isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            } else {
                try (trimmed + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            trust = root.map { ToolHooks.projectStatus(workspaceRoot: $0) } ?? .none
            status = "Saved."
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}
