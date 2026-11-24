import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Settings → Mods: find, turn on, make, share and remove mods.
struct ModsSettingsPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var host = ModHost.shared
    @State private var message: String?
    @State private var messageIsError = false
    @State private var creating = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var expandedLogs: Set<String> = []

    private var theme: AppTheme { appState.settings.theme }

    var body: some View {
        VStack(spacing: 16) {
            SettingsCard(
                title: "Mods",
                description: "Small programs that add panels, status text, slash commands, tools and hooks around your chats. They use Claude Code’s mod format, so a mod made for Claude Code or GrizzyCode works here too.",
                icon: "puzzlepiece.extension"
            ) {
                HStack(spacing: 8) {
                    Button { creating.toggle() } label: { Label("New mod…", systemImage: "plus") }
                    Button { install() } label: { Label("Install from folder or .zip…", systemImage: "square.and.arrow.down") }
                    Button { host.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button { openModsFolder() } label: { Label("Open mods folder", systemImage: "folder") }
                }
                .controlSize(.small)
                if creating { newModForm }
                if let message {
                    Text(message).font(.system(size: 11.5)).foregroundColor(messageIsError ? .red : ThemeColors.textSecondary(for: theme))
                        .textSelection(.enabled)
                }
                Text("Mods are programs with file and process access. Turn on only mods you trust: this app asks before it starts each one, and holds a mod that came from somewhere else if it changes.")
                    .font(.system(size: 10.5)).foregroundColor(ThemeColors.textSecondary(for: theme))
            }

            SettingsCard(title: "Your Mods (\(host.mods.count))", description: "This app’s folder is ~/.swiftopenwork/mods. Claude Code’s installed plugins and ~/.GrizzyCode/mods are listed too, read only.", icon: "square.stack.3d.up") {
                if host.mods.isEmpty {
                    Text("No mods found. Make one with “New mod…”, install one from a folder or .zip, or install a mod in Claude Code.")
                        .font(.system(size: 11.5)).foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                ForEach(host.mods) { mod in card(mod) }
            }
        }
        .onAppear { host.refresh() }
    }

    // MARK: - Pieces

    private var newModForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("my-mod", text: $newName).textFieldStyle(.roundedBorder)
            TextField("What it does (optional)", text: $newDescription).textFieldStyle(.roundedBorder)
            Text("Lowercase letters, digits and single dashes. A working mod is written to ~/.swiftopenwork/mods/<name>; nothing is written to Claude Code’s folders.")
                .font(.system(size: 10.5)).foregroundColor(ThemeColors.textSecondary(for: theme))
            HStack {
                Button("Create") { create() }.disabled(newName.isEmpty)
                Button("Cancel") { creating = false }
            }.controlSize(.small)
        }
    }

    private func card(_ mod: ModInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color(mod.status)).frame(width: 8, height: 8)
                Text(mod.name).font(.system(size: 12.5, weight: .semibold))
                if !mod.version.isEmpty { badge("v" + mod.version) }
                badge(mod.source)
                Spacer()
                Toggle("", isOn: Binding(get: { mod.enabled && mod.status != .needsReview }, set: { toggle(mod, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if !mod.description.isEmpty {
                Text(mod.description).font(.system(size: 11.5)).foregroundColor(ThemeColors.textSecondary(for: theme)).fixedSize(horizontal: false, vertical: true)
            }
            if let error = mod.error {
                Text(error.split(separator: "\n").first.map(String.init) ?? error).font(.system(size: 11)).foregroundColor(.red).textSelection(.enabled)
            }
            Text(statusLine(mod)).font(.system(size: 10.5)).foregroundColor(ThemeColors.textSecondary(for: theme))
            HStack(spacing: 6) {
                if mod.enabled { Button("Reload") { reload(mod) } }
                Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mod.root)]) }
                Button("Export .zip") { export(mod) }
                Button("Publish…") { publish(mod) }
                Button(expandedLogs.contains(mod.name) ? "Hide log" : "Log") {
                    if expandedLogs.contains(mod.name) { expandedLogs.remove(mod.name) } else { expandedLogs.insert(mod.name) }
                }
                if mod.isRemovable { Button("Delete", role: .destructive) { remove(mod) } }
            }.controlSize(.small)
            if expandedLogs.contains(mod.name) { logView(mod) }
        }
        .padding(10)
        .background(ThemeColors.border(for: theme).opacity(0.25))
        .cornerRadius(8)
    }

    private func logView(_ mod: ModInfo) -> some View {
        let lines = host.logs[mod.name] ?? []
        return VStack(alignment: .leading, spacing: 4) {
            ScrollView {
                Text(lines.isEmpty ? "Nothing logged yet." : lines.joined(separator: "\n"))
                    .font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140).padding(6)
            .background(Color.black.opacity(0.18)).cornerRadius(6)
            if !lines.isEmpty { Button("Clear") { host.clearLog(mod.name) }.controlSize(.small) }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15)).cornerRadius(4)
    }

    private func color(_ status: ModInfo.Status) -> Color {
        switch status {
        case .running: return .green
        case .failed: return .red
        case .needsReview, .starting: return .orange
        default: return .gray
        }
    }

    private func statusLine(_ mod: ModInfo) -> String {
        switch mod.status {
        case .running:
            var parts = ["running", "\(mod.hookCount) hook\(mod.hookCount == 1 ? "" : "s")"]
            if mod.toolCount > 0 { parts.append("\(mod.toolCount) tool\(mod.toolCount == 1 ? "" : "s")") }
            if mod.commandCount > 0 { parts.append("\(mod.commandCount) command\(mod.commandCount == 1 ? "" : "s")") }
            return parts.joined(separator: " · ")
        case .needsReview: return "changed since you turned it on · turn it on again to review it"
        case .failed: return "failed to load"
        case .starting: return "starting…"
        case .stopped: return "stopped"
        case .off: return "off"
        }
    }

    // MARK: - Actions

    private func say(_ text: String, error: Bool = false) { message = text; messageIsError = error }

    private func create() {
        let result = ModAuthoring.create(name: newName, description: newDescription, taken: host.knownNames)
        guard result.ok else { say(result.error ?? "Could not create the mod.", error: true); return }
        creating = false; newName = ""; newDescription = ""
        host.refresh()
        say("Created \(result.name) in \(result.path). Edit hooks/register.tsx, then turn it on below; the app reloads it when you save.")
    }

    private func install() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose a mod folder, or a .zip or .plugin file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = ModAuthoring.install(from: url.path)
        host.refresh()
        if let error = result.error { say(error, error: true); return }
        if ModHost.shared.mods.first(where: { $0.name == result.name })?.enabled == true { Task { await host.reload(result.name) } }
        say(result.unchanged ? "\(result.name) is already installed." : "\(result.name) \(result.replaced ? "updated" : "installed"). Turn it on below.")
    }

    private func toggle(_ mod: ModInfo, _ on: Bool) {
        if on {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Turn on “\(mod.name)”?"
            alert.informativeText = "\(mod.description.isEmpty ? "" : mod.description + "\n\n")Mods are programs. This one can read and write files, run commands and see your conversations, with your permissions. Only turn on mods you trust.\n\nSource: \(mod.source)\n\(mod.root)"
            alert.addButton(withTitle: "Turn on"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { host.refresh(); return }
        }
        Task {
            if let error = await host.setEnabled(mod.name, on) { say(error, error: true) }
            host.refresh()
            if on, let failed = host.mods.first(where: { $0.name == mod.name }), let error = failed.error { say("\(mod.name): \(error.split(separator: "\n").first ?? "")", error: true) }
        }
    }

    private func reload(_ mod: ModInfo) {
        Task {
            if let error = await host.reload(mod.name) { say(error, error: true) } else { say("\(mod.name) reloaded.") }
        }
    }

    private func export(_ mod: ModInfo) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(mod.name)\(mod.version.isEmpty ? "" : "-" + mod.version).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = ModAuthoring.exportZip(root: mod.root, to: url.path)
        say(result.error ?? "Saved \(url.path)", error: result.error != nil)
    }

    private func publish(_ mod: ModInfo) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.title = "Publish “\(mod.name)” to a marketplace folder"
        panel.message = "Choose a marketplace folder (one with .claude-plugin/marketplace.json), or an empty folder to start a new one."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let plan = ModAuthoring.planPublish(name: mod.name, marketDir: url.path)
        if let error = plan.error { say(error, error: true); return }
        let alert = NSAlert()
        alert.messageText = "Publish “\(mod.name)” to “\(plan.marketName)”?"
        alert.informativeText = "\(plan.isNew ? "This starts a new marketplace" : "This adds the mod to the existing marketplace") in:\n\(url.path)\n\n\(plan.replaces ? "A mod called “\(mod.name)” is already there and will be replaced.\n\n" : "")Nothing else in the folder changes."
        alert.addButton(withTitle: plan.replaces ? "Replace and publish" : "Publish"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = ModAuthoring.publish(name: mod.name, version: mod.version, description: mod.description, root: mod.root, marketDir: url.path)
        if let error = result.error { say(error, error: true); return }
        say("Published \(mod.name) to \(result.marketName)\(result.replaced ? " (replaced)" : ""). In Claude Code: \(result.installLines.joined(separator: "  then  "))")
    }

    private func remove(_ mod: ModInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(mod.name)”?"
        alert.informativeText = "This deletes the folder:\n\(mod.root)"
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await host.setEnabled(mod.name, false)
            let result = ModAuthoring.remove(root: mod.root)
            host.refresh()
            say(result.error ?? "\(mod.name) deleted.", error: result.error != nil)
        }
    }

    private func openModsFolder() {
        let dir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".swiftopenwork/mods")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}
