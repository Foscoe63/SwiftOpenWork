import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The Skills & MCP page: project skills, installed skills and MCP servers.

extension SettingsView {
    /// Skills that live in the repository rather than in the app.
    ///
    /// Global skills apply to every workspace, which is the wrong scope for anything specific to
    /// one codebase. These are read from `.swiftopenwork/skills/` in the active workspace on every
    /// turn, so they can be edited with the rest of the project and reviewed in a pull request.
    var projectSkillsCard: some View {
        let workspace = appState.currentWorkspace
        let folder = ProjectSkills.folder(in: workspace.folderPath)
        let folderExists = !ProjectSkills.existingFolders(in: workspace.folderPath).isEmpty

        return SettingsCard(
            title: "Project Skills (\(projectSkills.count))",
            description: "Skills stored inside '\(workspace.name)' and loaded only while it is the active workspace. Edited on disk, versioned with the project.",
            icon: "folder.badge.gearshape",
            collapseKey: "projectSkills"
        ) {
            HStack(spacing: 8) {
                Text(folder)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)

                Spacer()

                if folderExists {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Create Skills Folder") {
                        createProjectSkillsFolder(in: workspace.folderPath)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(workspace.folderPath.isEmpty)
                }

                Button("Reload") { refreshProjectSkills() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if projectSkills.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                    Text(folderExists
                         ? "No skills in this project yet."
                         : "This project has no skills folder yet.")
                        .font(.system(size: 12, weight: .medium))
                    Text("Add a folder per skill containing a SKILL.md file. They load on the next message — no import step.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(projectSkills) { skill in
                        HStack(spacing: 10) {
                            Image(systemName: skill.source.icon)
                                .font(.system(size: 13))
                                .foregroundColor(skill.isEnabled ? .accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.system(size: 12, weight: .semibold))
                                if !skill.description.isEmpty {
                                    Text(skill.description)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                if let path = skill.filePath {
                                    Text(displayPath(path, relativeTo: workspace.folderPath))
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.8))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }

                            Spacer()

                            // Enabling happens in the file's front matter, not here: a toggle in
                            // settings would be app state that silently disagrees with the
                            // repository everyone else checks out.
                            Text(skill.isEnabled ? "Enabled" : "Disabled (enabled: false)")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(skill.isEnabled ? .green : .secondary)

                            if let path = skill.filePath {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                } label: {
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                        .padding(10)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .onAppear { refreshProjectSkills() }
        .onChange(of: appState.activeWorkspaceId) { _, _ in refreshProjectSkills() }
    }

    func refreshProjectSkills() {
        projectSkills = ProjectSkills.load(workspacePath: appState.currentWorkspace.folderPath)
    }

    func createProjectSkillsFolder(in workspacePath: String) {
        do {
            let created = try ProjectSkills.ensureFolder(in: workspacePath)
            refreshProjectSkills()
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: created)])
            appState.showToast("Created \(ProjectSkills.relativePath)")
        } catch {
            appState.showToast("Could not create the skills folder: \(error.localizedDescription)")
        }
    }

    /// `.swiftopenwork/skills/foo/SKILL.md` reads better than the absolute path in a narrow row.
    func displayPath(_ path: String, relativeTo root: String) -> String {
        guard !root.isEmpty, path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // 14. Skills & MCP
    var skillsPage: some View {
        VStack(spacing: 20) {
            // MARK: - AGENT SKILLS SECTION
            SettingsCard(
                title: "Agent Skills (\(appState.skills.count))",
                description: "Modular instructions and domain knowledge that enhance agent autonomy",
                icon: "sparkles",
                collapseKey: "agentSkills"
            ) {
                // Actions & Filter Bar
                HStack(spacing: 10) {
                    // Search Bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        TextField("Search skills...", text: $skillSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !skillSearchText.isEmpty {
                            Button {
                                skillSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.hitTestable)
                        }
                    }
                    .padding(6)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .cornerRadius(6)

                    Spacer()

                    // Add Skill Menu with Multiple Ways
                    Menu {
                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Create Custom Skill...", systemImage: "pencil.and.outline")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select SKILL.md or Markdown File"
                            if let mdType = UTType(filenameExtension: "md") {
                                panel.allowedContentTypes = [.plainText, mdType]
                            } else {
                                panel.allowedContentTypes = [.plainText]
                            }
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importSkillFromFile(url: url)
                            }
                        } label: {
                            Label("Import SKILL.md File...", systemImage: "doc.badge.plus")
                        }

                        Button {
                            let panel = NSOpenPanel()
                            panel.title = "Select Folder Containing Skills"
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.importSkillsFromFolder(url: url)
                            }
                        } label: {
                            Label("Import from Directory / Folder...", systemImage: "folder.badge.plus")
                        }

                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Import from URL / GitHub...", systemImage: "globe")
                        }

                        Divider()

                        Button {
                            showingAddSkill = true
                        } label: {
                            Label("Browse Skill Templates...", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("Add Skill")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 4)

                // List of Skills
                let filteredSkills = appState.skills.filter {
                    skillSearchText.isEmpty ||
                    $0.name.localizedCaseInsensitiveContains(skillSearchText) ||
                    $0.description.localizedCaseInsensitiveContains(skillSearchText) ||
                    $0.category.localizedCaseInsensitiveContains(skillSearchText)
                }

                if filteredSkills.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text(skillSearchText.isEmpty ? "No agent skills installed yet." : "No skills match '\(skillSearchText)'")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Add skills to equip your autonomous agents with specialized instructions, best practices, and domain workflows.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredSkills) { skill in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: skill.source.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(skill.name)
                                            .font(.system(size: 12, weight: .bold))

                                        Text(skill.category)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        Text(skill.source.displayName)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(Color.secondary.opacity(0.12))
                                            .cornerRadius(4)
                                    }

                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }

                                    if let path = skill.filePath {
                                        Text(path)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button("Inspect / Edit") {
                                        selectedSkillForDetail = skill
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { skill.isEnabled },
                                        set: { val in
                                            var updated = skill
                                            updated.isEnabled = val
                                            appState.saveSkill(updated)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deleteSkill(skill)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.hitTestable)
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            // MARK: - PROJECT SKILLS SECTION
            projectSkillsCard

            // MARK: - MODEL CONTEXT PROTOCOL (MCP) SERVERS SECTION
            SettingsCard(
                title: "Model Context Protocol (MCP) Servers (\(appState.settings.mcpServers.count))",
                description: "Extend autonomous agents with stdio processes, remote HTTP/SSE gateways, and WebSocket tools. Enable only servers you trust — cold starts no longer block chat.",
                icon: "network",
                collapseKey: "mcp"
            ) {
                HStack {
                    Text("Configured MCP Servers")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()

                    Button(mcpStatusBusy ? "Probing…" : "Refresh Status") {
                        refreshMcpStatus(probe: true)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(mcpStatusBusy)

                    Button("Restore Defaults") {
                        appState.settings.mcpServers = AppSettings.defaultMCPServers
                        appState.updateSettings(appState.settings)
                        appState.showToast("Restored standard MCP servers (disabled by default)")
                        refreshMcpStatus(probe: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        selectedMcpForEdit = nil
                        showingAddMcp = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                            Text("Add MCP Server...")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }

                if appState.settings.mcpServers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "cable.connector.slash")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                        Text("No Model Context Protocol servers configured.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Connect servers like @modelcontextprotocol/server-filesystem, memory, sqlite, or remote HTTP/SSE endpoints.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 8) {
                        ForEach(appState.settings.mcpServers) { mcp in
                            let report = mcpStatusReports.first(where: { $0.id == mcp.id })
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: mcp.transportType.icon)
                                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                    .font(.system(size: 14))
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(mcp.name)
                                            .font(.system(size: 12, weight: .bold))

                                        Text(mcp.transportType.displayName)
                                            .font(.system(size: 9.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(ThemeColors.border(for: appState.settings.theme))
                                            .cornerRadius(4)

                                        mcpStatusBadge(for: mcp, report: report)

                                        if !mcp.env.isEmpty {
                                            Text("\(mcp.env.count) ENV")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Color.secondary.opacity(0.12))
                                                .cornerRadius(4)
                                        }
                                    }

                                    if mcp.transportType == .stdio {
                                        Text("\(mcp.command) \(mcp.args.joined(separator: " "))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text(mcp.url)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    if !mcp.workingDirectory.isEmpty {
                                        Text("cwd: \(mcp.workingDirectory)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                            .lineLimit(1)
                                    }

                                    if let err = report?.error, !err.isEmpty {
                                        Text(err)
                                            .font(.system(size: 10.5))
                                            .foregroundColor(.red.opacity(0.85))
                                            .lineLimit(3)
                                    } else if let tools = report?.tools, !tools.isEmpty {
                                        mcpToolGateSection(server: mcp, advertised: tools)
                                    }
                                }

                                Spacer()

                                HStack(spacing: 8) {
                                    Button(mcpStatusBusy ? "…" : "Test") {
                                        testMcpServer(mcp)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(mcpStatusBusy || !mcp.isEnabled)

                                    Button("Configure") {
                                        selectedMcpForEdit = mcp
                                        showingAddMcp = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Toggle("", isOn: Binding(
                                        get: { mcp.isEnabled },
                                        set: { val in
                                            var updated = mcp
                                            updated.isEnabled = val
                                            appState.saveMcpServer(updated)
                                            refreshMcpStatus(probe: false)
                                        }
                                    ))
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)

                                    Button {
                                        appState.deleteMcpServer(mcp)
                                        refreshMcpStatus(probe: false)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red.opacity(0.8))
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.hitTestable)
                                }
                            }
                            .padding(10)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(ThemeColors.border(for: appState.settings.theme).opacity(0.6), lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .task {
                refreshMcpStatus(probe: false)
            }
        }
        .sheet(isPresented: $showingAddSkill) {
            AddSkillModalView(appState: appState, isPresented: $showingAddSkill)
        }
        .sheet(item: $selectedSkillForDetail) { skill in
            SkillDetailModalView(appState: appState, isPresented: Binding(
                get: { selectedSkillForDetail != nil },
                set: { if !$0 { selectedSkillForDetail = nil } }
            ), skill: skill)
        }
        .sheet(isPresented: $showingAddMcp) {
            McpServerEditModalView(
                appState: appState,
                isPresented: $showingAddMcp,
                editingConfig: selectedMcpForEdit
            )
        }
    }

    // MARK: - Helpers
    /// Per-tool switches for one connected server. Collapsed to a summary line until opened, so a
    /// server advertising 40 tools does not bury the rest of the list.
    @ViewBuilder
    func mcpToolGateSection(server: MCPServerConfig, advertised: [String]) -> some View {
        let expanded = expandedMcpToolLists.contains(server.id)
        let offCount = advertised.filter { server.disabledTools.contains($0) }.count

        VStack(alignment: .leading, spacing: 5) {
            Button {
                if expanded {
                    expandedMcpToolLists.remove(server.id)
                } else {
                    expandedMcpToolLists.insert(server.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("Tools: \(advertised.count)")
                        .font(.system(size: 10.5))
                    if offCount > 0 {
                        Text("\(offCount) off")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.18))
                            .cornerRadius(4)
                    }
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.hitTestable)

            if !expanded {
                Text(advertised.prefix(8).joined(separator: ", ") + (advertised.count > 8 ? "…" : ""))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(2)
            } else {
                HStack(spacing: 8) {
                    Button("Enable all") {
                        var updated = server
                        MCPToolGate.setAllTools(true, advertised: advertised, in: &updated)
                        appState.saveMcpServer(updated)
                    }
                    Button("Disable all") {
                        var updated = server
                        MCPToolGate.setAllTools(false, advertised: advertised, in: &updated)
                        appState.saveMcpServer(updated)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 10))

                ForEach(advertised.sorted(), id: \.self) { toolName in
                    Toggle(isOn: Binding(
                        get: { MCPToolGate.isToolEnabled(server: server, toolName: toolName) },
                        set: { isOn in
                            var updated = server
                            MCPToolGate.setTool(isOn, named: toolName, in: &updated)
                            appState.saveMcpServer(updated)
                        }
                    )) {
                        Text(toolName)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .disabled(!server.isEnabled)
                }
            }
        }
    }

    func mcpStatusBadge(for mcp: MCPServerConfig, report: MCPServerReport?) -> some View {
        let label: String
        let color: Color
        if !mcp.isEnabled {
            label = "off"
            color = .secondary
        } else if let report, report.connected {
            label = "✓ \(report.toolCount) tools"
            color = .green
        } else if let report, report.error != nil {
            label = "error"
            color = .red
        } else if report?.status == .connecting {
            label = "connecting"
            color = .orange
        } else {
            label = "idle"
            color = .secondary
        }
        return Text(label)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }

    func refreshMcpStatus(probe: Bool) {
        mcpStatusBusy = true
        Task { @MainActor in
            let reports = await MCPClientManager.shared.mcpStatusReports(probe: probe)
            mcpStatusReports = reports
            mcpStatusBusy = false
            if probe {
                let connected = reports.filter(\.connected).count
                let errors = reports.filter { $0.error != nil }.count
                appState.showToast("MCP status: \(connected) connected, \(errors) errors")
            }
        }
    }

    func testMcpServer(_ mcp: MCPServerConfig) {
        guard mcp.isEnabled else {
            appState.showToast("Enable '\(mcp.name)' before testing")
            return
        }
        mcpStatusBusy = true
        Task { @MainActor in
            do {
                let tools = try await MCPClientManager.shared.startServer(config: mcp)
                let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
                mcpStatusReports = reports
                appState.showToast("MCP '\(mcp.name)' OK — \(tools.count) tools")
            } catch {
                let reports = await MCPClientManager.shared.mcpStatusReports(probe: false)
                mcpStatusReports = reports
                appState.showToast("MCP '\(mcp.name)' failed: \(error.localizedDescription)")
            }
            mcpStatusBusy = false
        }
    }

    /// The version this build actually is, from its own bundle.
    ///
    /// The About row hardcoded "1.0.0" while the shipped release was 1.1.0. `project.yml` now sets
    /// MARKETING_VERSION, so the string here and the bundle agree by construction.
    static var appVersionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        default: return "unknown"
        }
    }
}
