import SwiftUI
import SwiftOpenWorkEngine

/// Review what the agent changed this turn, file by file, and take any of it back.
///
/// The agent reports its own work in prose, which is exactly the claim a reviewer should not have
/// to trust. This reads the checkpoint store instead — the same record `revert_changes` uses — so
/// the list is what actually happened on disk.
public struct TurnChangeReviewView: View {
    @ObservedObject var appState: AppState
    /// Workspace root, so paths display relative.
    let root: String
    /// Called after a revert so the host can refresh anything showing file contents.
    var onRevert: (() -> Void)?

    @State private var changes: [FileCheckpointStore.Change] = []
    @State private var selected: FileCheckpointStore.Change?
    @State private var isLoading = true
    @State private var confirmingRevertAll = false
    @AppStorage("review.sideBySide") private var sideBySide = true

    public init(appState: AppState, root: String, onRevert: (() -> Void)? = nil) {
        self.appState = appState
        self.root = root
        self.onRevert = onRevert
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                ProgressView().padding(24)
            } else if changes.isEmpty {
                empty
            } else {
                HSplitView {
                    fileList.frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                    detail.frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .background(ThemeColors.bg(for: appState.settings.theme))
        .task { await reload() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
            Text(changes.isEmpty ? "Changes this turn" : "\(changes.count) file\(changes.count == 1 ? "" : "s") changed this turn")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            if !changes.isEmpty {
                Picker("", selection: $sideBySide) {
                    Text("Side by Side").tag(true)
                    Text("Unified").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Button(confirmingRevertAll ? "Really revert all?" : "Revert all") {
                    if confirmingRevertAll {
                        Task { await revertAll() }
                    } else {
                        confirmingRevertAll = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(confirmingRevertAll ? .red : nil)
            }
        }
        .padding(12)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundColor(.secondary)
            Text("No files were changed this turn.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(changes) { change in
                    Button {
                        selected = change
                    } label: {
                        HStack(spacing: 8) {
                            Text(badge(for: change.kind))
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(color(for: change.kind))
                                .cornerRadius(3)
                            Text(relative(change.path))
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            selected?.path == change.path
                                ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.15)
                                : Color.clear
                        )
                        .cornerRadius(5)
                    }
                    .buttonStyle(.hitTestable)
                    .contextMenu {
                        Button("Revert this file", role: .destructive) {
                            Task { await revert(change) }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let change = selected ?? changes.first {
            if sideBySide {
                SideBySideDiffReviewView(
                    appState: appState,
                    path: change.path,
                    displayPath: relative(change.path),
                    before: change.before,
                    after: change.after,
                    onChanged: { Task { await reload(); onRevert?() } },
                    onPreviousFile: { stepFile(-1) },
                    onNextFile: { stepFile(1) }
                )
            } else {
                VisualDiffInspectorView(
                    appState: appState,
                    filePath: relative(change.path),
                    // A created file diffs against nothing; a deleted one against nothing after.
                    originalText: change.before ?? "",
                    modifiedText: change.after ?? "",
                    // The agent already wrote this file. There is nothing left to apply, so the only
                    // real action is putting it back — "Apply & Save Changes" here did nothing at all.
                    onAccept: nil,
                    onReject: { Task { await revert(change) } },
                    rejectTitle: "Revert This File"
                )

            }
        } else {
            Color.clear
        }
    }

    // MARK: - Helpers

    private func stepFile(_ delta: Int) {
        guard !changes.isEmpty else { return }
        let index = changes.firstIndex { $0.path == (selected ?? changes.first)?.path } ?? 0
        selected = changes[min(changes.count - 1, max(0, index + delta))]
    }

    private func relative(_ path: String) -> String {
        guard !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func badge(for kind: FileCheckpointStore.Change.Kind) -> String {
        switch kind {
        case .created: return "NEW"
        case .modified: return "MOD"
        case .deleted: return "DEL"
        }
    }

    private func color(for kind: FileCheckpointStore.Change.Kind) -> Color {
        switch kind {
        case .created: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }

    private func reload() async {
        let latest = await FileCheckpointStore.shared.changes()
        await MainActor.run {
            changes = latest
            // Re-point at the fresh change, not the snapshot: a hunk revert rewrites the file, and a
            // stale selection would keep drawing (and reverting against) the text from before it.
            if let current = selected {
                selected = latest.first { $0.path == current.path }
            }
            isLoading = false
            confirmingRevertAll = false
        }
    }

    private func revert(_ change: FileCheckpointStore.Change) async {
        _ = await FileCheckpointStore.shared.revert(path: change.path)
        await reload()
        await MainActor.run {
            appState.showToast("Reverted \(relative(change.path))")
            onRevert?()
        }
    }

    private func revertAll() async {
        let outcome = await FileCheckpointStore.shared.revertTurn()
        await reload()
        await MainActor.run {
            let count = outcome.restored.count + outcome.removed.count
            if outcome.failed.isEmpty {
                appState.showToast("Reverted \(count) file\(count == 1 ? "" : "s")")
            } else {
                appState.showToast("Reverted \(count); \(outcome.failed.count) failed")
            }
            onRevert?()
        }
    }
}
