import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// The workspace's file/folder tree, with toolbar controls to create or delete entries directly
/// — the agent-facing `file_write`/`file_delete`/etc. tools cover the same ground for the model,
/// this is the same capability for a person working in the sidebar.
public struct FilesPanelView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var editors = EditorWorkspace.shared

    @State private var tree: [WorkspaceFileScanner.FileNode] = []
    @State private var selection: String?
    @State private var expanded: Set<String> = []

    @State private var showingNewFileSheet = false
    @State private var showingNewFolderSheet = false
    @State private var newEntryName = ""
    @State private var showingDeleteConfirm = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar

            Divider()

            if tree.isEmpty {
                VStack(spacing: 6) {
                    Text("No files in this workspace folder.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    OutlineGroup(tree, children: \.children) { node in
                        row(for: node)
                    }
                    .padding(8)
                }
            }
        }
        .background(ThemeColors.paneBg(for: appState.settings.theme, translucent: appState.settings.useTranslucentBackground))
        .onAppear { loadTree() }
        .onChange(of: appState.currentWorkspace.folderPath) { _, _ in
            selection = nil
            loadTree()
        }
        .sheet(isPresented: $showingNewFileSheet) {
            nameSheet(title: "New File", placeholder: "filename.txt / notes/todo.md", action: createFile)
        }
        .sheet(isPresented: $showingNewFolderSheet) {
            nameSheet(title: "New Folder", placeholder: "folder-name", action: createFolder)
        }
        .confirmationDialog(
            "Delete \(selectedName ?? "this item")?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("FILES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                Text(appState.currentWorkspace.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
            }

            Spacer()

            Button {
                newEntryName = ""
                showingNewFileSheet = true
            } label: {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
            }
            .buttonStyle(.hitTestable)
            .help("New File")

            Button {
                newEntryName = ""
                showingNewFolderSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
            }
            .buttonStyle(.hitTestable)
            .help("New Folder")

            Button {
                showingDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(selection == nil ? ThemeColors.textSecondary(for: appState.settings.theme) : .red)
            }
            .buttonStyle(.hitTestable)
            .disabled(selection == nil)
            .help("Delete Selected")

            Button {
                loadTree()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
            .buttonStyle(.hitTestable)
            .help("Refresh")
        }
        .padding(12)
        .background(ThemeColors.sidebarBg(for: appState.settings.theme))
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for node: WorkspaceFileScanner.FileNode) -> some View {
        let isSelected = selection == node.path
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(for: node.name))
                .font(.system(size: 11))
                .foregroundColor(
                    node.isDirectory ? ThemeColors.textSecondary(for: appState.settings.theme)
                        : (isSelected ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme))
                )
            Text(node.name)
                .font(.system(size: 11.5))
                .foregroundColor(isSelected ? ThemeColors.textPrimary(for: appState.settings.theme) : ThemeColors.textSecondary(for: appState.settings.theme))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = node.path
            if !node.isDirectory {
                openInEditor(node.path)
            }
        }
        .contextMenu {
            Button("Reveal in Finder") { reveal(node.path) }
            Button("Delete", role: .destructive) {
                selection = node.path
                showingDeleteConfirm = true
            }
        }
    }

    private var selectedName: String? {
        selection.map { ($0 as NSString).lastPathComponent }
    }

    // MARK: - Actions

    private func loadTree() {
        tree = WorkspaceFileScanner.listTree(at: appState.currentWorkspace.folderPath)
    }

    private func openInEditor(_ relativePath: String) {
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(relativePath)
        do {
            try editors.open(path: fullPath, workspaceRoot: appState.currentWorkspace.folderPath)
            appState.revealInspector(tab: .editor, minimumWidth: 480)
        } catch {
            appState.showToast("Could not open \(relativePath): \(error.localizedDescription)")
        }
    }

    private func reveal(_ relativePath: String) {
        let fullPath = (appState.currentWorkspace.folderPath as NSString).appendingPathComponent(relativePath)
        NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: appState.currentWorkspace.folderPath)
    }

    /// The one gate every create/delete goes through: nothing may resolve outside the current
    /// workspace, no matter what `..` or a symlink in the typed name tries to do.
    private func resolvedInWorkspace(_ relativePath: String) -> String? {
        let root = appState.currentWorkspace.folderPath
        let full = (root as NSString).appendingPathComponent(relativePath)
        let canonicalFull = ToolExecutionEngine.canonicalPath(full)
        let canonicalRoot = ToolExecutionEngine.canonicalPath(root)
        guard canonicalFull == canonicalRoot || canonicalFull.hasPrefix(canonicalRoot + "/") else {
            return nil
        }
        return full
    }

    private func createFile() {
        let name = newEntryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let fullPath = resolvedInWorkspace(name) else {
            appState.showToast("That name isn't valid.")
            return
        }
        do {
            let parent = (fullPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: fullPath) else {
                appState.showToast("\(name) already exists")
                return
            }
            try "".write(toFile: fullPath, atomically: true, encoding: .utf8)
            showingNewFileSheet = false
            newEntryName = ""
            loadTree()
            selection = name
            appState.showToast("Created \(name)")
        } catch {
            appState.showToast("Error creating file: \(error.localizedDescription)")
        }
    }

    private func createFolder() {
        let name = newEntryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let fullPath = resolvedInWorkspace(name) else {
            appState.showToast("That name isn't valid.")
            return
        }
        guard !FileManager.default.fileExists(atPath: fullPath) else {
            appState.showToast("\(name) already exists")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: fullPath, withIntermediateDirectories: true)
            showingNewFolderSheet = false
            newEntryName = ""
            loadTree()
            selection = name
            appState.showToast("Created \(name)/")
        } catch {
            appState.showToast("Error creating folder: \(error.localizedDescription)")
        }
    }

    private func deleteSelection() {
        guard let relative = selection, let fullPath = resolvedInWorkspace(relative) else { return }
        let root = appState.currentWorkspace.folderPath
        if let refusal = ToolExecutionEngine.refusedDeleteTarget(fullPath, workspaceRoot: root) {
            appState.showToast("Can't delete: \(refusal)")
            return
        }
        do {
            try FileManager.default.removeItem(atPath: fullPath)
            if let active = editors.activeDocument, active.path == fullPath {
                editors.close(active.id)
            }
            selection = nil
            loadTree()
            appState.showToast("Deleted \(relative)")
        } catch {
            appState.showToast("Error deleting \(relative): \(error.localizedDescription)")
        }
    }

    @ViewBuilder
    private func nameSheet(title: String, placeholder: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            TextField(placeholder, text: $newEntryName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(action)
            HStack {
                Button("Cancel") {
                    showingNewFileSheet = false
                    showingNewFolderSheet = false
                    newEntryName = ""
                }
                Spacer()
                Button("Create", action: action)
                    .buttonStyle(.borderedProminent)
                    .disabled(newEntryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func fileIcon(for name: String) -> String {
        if name.hasSuffix(".swift") { return "swift" }
        if name.hasSuffix(".json") { return "curlybraces" }
        if name.hasSuffix(".md") { return "doc.plaintext" }
        if name.hasSuffix(".yml") || name.hasSuffix(".yaml") { return "gearshape.2" }
        return "doc"
    }
}
