import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

public struct ToolCallCardView: View {
    let toolCall: ToolCallInfo
    let preferExpanded: Bool
    var appState: AppState?
    var onReviewTurn: (() -> Void)?
    @State private var isExpanded: Bool
    @ObservedObject private var liveOutput = LiveToolOutput.shared

    public init(
        toolCall: ToolCallInfo,
        preferExpanded: Bool = false,
        appState: AppState? = nil,
        onReviewTurn: (() -> Void)? = nil
    ) {
        self.toolCall = toolCall
        self.preferExpanded = preferExpanded
        self.appState = appState
        self.onReviewTurn = onReviewTurn
        let needsApproval = toolCall.status == .waitingApproval || toolCall.status == .pendingApproval
        _isExpanded = State(initialValue: preferExpanded || needsApproval)
    }

    private var needsApproval: Bool {
        toolCall.status == .waitingApproval || toolCall.status == .pendingApproval
    }

    private var isFileMutatingTool: Bool {
        let n = ToolCallRepair.canonicalName(toolCall.toolName)
        return ["file_write", "write_file", "edit_file", "file_edit", "multi_edit", "edit_file_multi",
                "file_delete", "file_move", "file_copy", "rename_symbol", "revert_changes",
                "setup_xcode_language_server"].contains(n)
    }

    private var diagnosticLinks: [DiagnosticLinkParser.Link] {
        guard let output = toolCall.resultOutput else { return [] }
        return DiagnosticLinkParser.links(in: output)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolCall.status.icon)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)

                    Text(toolCall.toolName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)

                    Text("(\(toolCall.argumentsJson))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(needsApproval ? 3 : 1)

                    Spacer()

                    if toolCall.durationMs > 0 {
                        Text("\(Int(toolCall.durationMs))ms")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    if !needsApproval {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .buttonStyle(.hitTestable)

            if needsApproval {
                approvalPrompt
            }

            if let diff = toolCall.fileDiff {
                inlineDiff(diff)
            } else if let diffs = toolCall.fileDiffs, !diffs.isEmpty {
                multiFileDiff(diffs)
            }

            if isFileMutatingTool,
               toolCall.status == .success || toolCall.status == .completed,
               let onReviewTurn {
                Button {
                    onReviewTurn()
                } label: {
                    Label("Review file changes", systemImage: "doc.badge.ellipsis")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !diagnosticLinks.isEmpty, let appState {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(diagnosticLinks.prefix(6)) { link in
                        Button {
                            appState.revealDiagnostic(file: link.file, line: link.line)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.right.circle")
                                    .font(.system(size: 10))
                                Text(link.line.map { "\(link.file):\($0)" } ?? link.file)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.hitTestable)
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    }
                }
                .padding(.horizontal, 4)
            }

            if let tail = liveOutput.tail(for: toolCall.id) {
                liveTailView(tail)
            } else if isExpanded, let output = toolCall.resultOutput {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
            }
        }
    }

    /// What the call changed, shown where the claim that it changed something is made.
    ///
    /// Collapsed cards get the +/− counts only. A reviewer scanning a turn wants to know which
    /// edits were large before deciding which to open; expanding every card to find that out is how
    /// people end up not reading any of them.
    private func inlineDiff(_ diff: InlineFileDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    appState?.openInEditor(path: diff.path, line: diff.firstChangedLine)
                } label: {
                    Text(diffFileName(diff.path))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                        .underline(appState != nil && diff.kind != .deleted, color: .secondary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.hitTestable)
                .disabled(appState == nil || diff.kind == .deleted)
                .help("Open in the editor at the change")
                if diff.added > 0 {
                    Text("+\(diff.added)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }
                if diff.removed > 0 {
                    Text("−\(diff.removed)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                }
                Spacer()
            }

            if isExpanded, !diff.lines.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        diffLine(line)
                    }
                    if diff.truncated {
                        Text("…rest of the change not shown")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.18))
                .cornerRadius(5)
            } else if isExpanded, diff.truncated {
                Text("Too large to diff here — open the file to review it.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    /// A call that changed several files: the totals collapsed, every file listed when expanded.
    ///
    /// Listing all of them is the point — a reviewer of a rename needs to see that it reached a
    /// file it should not have, which a card showing one file would hide.
    private func multiFileDiff(_ diffs: [InlineFileDiff]) -> some View {
        let added = diffs.reduce(0) { $0 + $1.added }
        let removed = diffs.reduce(0) { $0 + $1.removed }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(diffs.count) file\(diffs.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                if added > 0 {
                    Text("+\(added)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }
                if removed > 0 {
                    Text("−\(removed)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                }
                Spacer()
            }
            .padding(.horizontal, 4)

            if isExpanded {
                ForEach(diffs, id: \.path) { diff in
                    inlineDiff(diff)
                }
            }
        }
    }

    private func diffLine(_ line: InlineFileDiff.Line) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(diffGutter(line))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
            Text(diffMarker(line) + line.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(diffTint(line))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 0.5)
        .background(diffBackground(line))
    }

    private func diffGutter(_ line: InlineFileDiff.Line) -> String {
        switch line.kind {
        case .added: return line.newNumber.map(String.init) ?? ""
        case .removed: return line.oldNumber.map(String.init) ?? ""
        case .context: return line.newNumber.map(String.init) ?? ""
        case .gap: return ""
        }
    }

    private func diffMarker(_ line: InlineFileDiff.Line) -> String {
        switch line.kind {
        case .added: return "+ "
        case .removed: return "− "
        case .context: return "  "
        case .gap: return ""
        }
    }

    private func diffTint(_ line: InlineFileDiff.Line) -> Color {
        switch line.kind {
        case .added: return .green
        case .removed: return .red
        case .context, .gap: return .secondary
        }
    }

    private func diffBackground(_ line: InlineFileDiff.Line) -> Color {
        switch line.kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context, .gap: return .clear
        }
    }

    private func diffFileName(_ path: String) -> String {
        guard let root = appState?.currentWorkspace.folderPath, !root.isEmpty else {
            return (path as NSString).lastPathComponent
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// The last few lines of a command that is still running.
    ///
    /// Shown whether or not the card is expanded: the whole point is that a four-minute build
    /// should not look identical to a hung one, and nobody expands a card to find that out.
    private func liveTailView(_ tail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                Text("running")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(tail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.2))
        .cornerRadius(6)
    }

    private var approvalPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = toolCall.approvalReason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    ToolApprovalManager.shared.resolve(callId: toolCall.id, approved: true)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    ToolApprovalManager.shared.resolve(callId: toolCall.id, approved: false)
                } label: {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    private var statusColor: Color {
        switch toolCall.status {
        case .running, .waitingApproval, .pendingApproval: return .orange
        case .success, .completed: return .green
        case .error, .failed: return .red
        }
    }
}
