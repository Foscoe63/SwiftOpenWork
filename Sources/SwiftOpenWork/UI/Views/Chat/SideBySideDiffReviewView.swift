import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// A file's change laid out as old and new side by side, walked hunk by hunk from the keyboard.
///
/// "Keep" only marks a hunk as read: the agent already wrote it, so there is nothing to apply.
/// "Revert hunk" is the real action, and writes the file with just that hunk put back.
struct SideBySideDiffReviewView: View {
    @ObservedObject var appState: AppState
    let path: String
    let displayPath: String
    let before: String?
    let after: String?
    /// Called after a hunk was reverted on disk, so the host reloads the change.
    var onChanged: () -> Void
    var onPreviousFile: (() -> Void)?
    var onNextFile: (() -> Void)?

    @State private var diff: SideBySideDiff?
    @State private var current = 0
    @State private var kept: Set<Int> = []
    @State private var failure: String?

    private var theme: AppTheme { appState.settings.theme }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let diff {
                if diff.isEmpty {
                    Text("No differences.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(diff)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(shortcuts)
        // Recomputed when either side changes (a revert, or a new turn), off the main thread:
        // the line alignment is quadratic in the part of the file that differs.
        .task(id: Identity(path: path, before: before, after: after)) {
            let before = before, after = after
            diff = nil
            let computed = await Task.detached { SideBySideDiff.make(old: before, new: after) }.value
            diff = computed
            current = min(current, max(0, computed.hunks.count - 1))
        }
    }

    private struct Identity: Equatable {
        let path: String
        let before: String?
        let after: String?
    }

    /// Stable across a revert, which renumbers hunks: a hunk is the same hunk if its text is.
    private func fingerprint(_ hunk: SideBySideDiff.Hunk) -> Int {
        [hunk.removedLines, hunk.addedLines].hashValue
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(displayPath)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let diff, !diff.isEmpty {
                let reviewed = diff.hunks.filter { kept.contains(fingerprint($0)) }.count
                Text("Hunk \(current + 1) of \(diff.hunks.count) · \(reviewed) kept")
                    .font(.system(size: 11))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Previous hunk  ⌥↑")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .help("Next hunk  ⌥↓")
                Button("Keep") { keepCurrent() }
                    .help("Mark this hunk as reviewed  ⌥↩")
                Button("Revert Hunk", role: .destructive) { revertCurrent() }
                    .help("Put this hunk back to how it was  ⌥⌫")
                Button("Keep All") { keepAll() }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Hidden buttons carry the shortcuts, so they work wherever focus is in the window.
    private var shortcuts: some View {
        ZStack {
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: .option)
            Button("") { keepCurrent() }.keyboardShortcut(.return, modifiers: .option)
            Button("") { revertCurrent() }.keyboardShortcut(.delete, modifiers: .option)
            Button("") { onPreviousFile?() }.keyboardShortcut(.upArrow, modifiers: [.option, .command])
            Button("") { onNextFile?() }.keyboardShortcut(.downArrow, modifiers: [.option, .command])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Content

    private func content(_ diff: SideBySideDiff) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(spacing: 0) {
                    ForEach(diff.rows) { row in
                        if let hunk = row.hunk, diff.hunks[hunk].firstRowId == row.id {
                            hunkHeader(diff.hunks[hunk], total: diff.hunks.count)
                                .id("hunk-\(hunk)")
                        }
                        rowView(row)
                    }
                }
                .padding(.bottom, 24)
            }
            .onChange(of: current) { _, new in
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo("hunk-\(new)", anchor: .top) }
            }
            .overlay(alignment: .bottom) {
                if let failure {
                    Text(failure)
                        .font(.system(size: 11))
                        .padding(8)
                        .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundColor(.white)
                        .padding(8)
                }
            }
        }
    }

    private func hunkHeader(_ hunk: SideBySideDiff.Hunk, total: Int) -> some View {
        let isKept = kept.contains(fingerprint(hunk))
        let isCurrent = hunk.id == current
        return HStack(spacing: 8) {
            Image(systemName: isKept ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundColor(isKept ? .green : .secondary)
            Text("Hunk \(hunk.id + 1) of \(total)  \(hunk.summary)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isKept ? ThemeColors.textSecondary(for: theme) : .primary)
            Spacer()
            Button(isKept ? "Unmark" : "Keep") { toggleKept(hunk) }
            Button("Revert", role: .destructive) { revert(hunk.id) }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isCurrent
            ? ThemeColors.accent(for: appState.settings.accentColor).opacity(0.18)
            : Color.secondary.opacity(0.08))
        .contentShape(Rectangle())
        .onTapGesture { current = hunk.id }
    }

    @ViewBuilder
    private func rowView(_ row: SideBySideDiff.Row) -> some View {
        if case .gap(let count) = row.kind {
            Text("⋯ \(count) unchanged line\(count == 1 ? "" : "s")")
                .font(.system(size: 10.5))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.05))
        } else {
            HStack(alignment: .top, spacing: 0) {
                half(number: row.leftNumber, text: row.leftText, tint: leftTint(row.kind))
                Divider()
                half(number: row.rightNumber, text: row.rightText, tint: rightTint(row.kind))
            }
            .fixedSize(horizontal: false, vertical: true)
            .opacity(row.hunk.map { kept.contains(fingerprint(currentHunks[$0])) } == true ? 0.55 : 1)
        }
    }

    private var currentHunks: [SideBySideDiff.Hunk] { diff?.hunks ?? [] }

    private func half(number: Int?, text: String?, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(text ?? "")
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint)
    }

    private func leftTint(_ kind: SideBySideDiff.Row.Kind) -> Color {
        switch kind {
        case .removed, .changed: return Color.red.opacity(0.16)
        case .added: return Color.secondary.opacity(0.08)
        default: return .clear
        }
    }

    private func rightTint(_ kind: SideBySideDiff.Row.Kind) -> Color {
        switch kind {
        case .added, .changed: return Color.green.opacity(0.16)
        case .removed: return Color.secondary.opacity(0.08)
        default: return .clear
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        guard let count = diff?.hunks.count, count > 0 else { return }
        current = min(count - 1, max(0, current + delta))
    }

    private func toggleKept(_ hunk: SideBySideDiff.Hunk) {
        let key = fingerprint(hunk)
        if kept.contains(key) { kept.remove(key) } else { kept.insert(key) }
    }

    private func keepCurrent() {
        guard let diff, diff.hunks.indices.contains(current) else { return }
        kept.insert(fingerprint(diff.hunks[current]))
        // Reviewing is a walk: kept one, show the next.
        if current < diff.hunks.count - 1 { current += 1 }
    }

    private func keepAll() {
        diff?.hunks.forEach { kept.insert(fingerprint($0)) }
    }

    private func revertCurrent() { revert(current) }

    private func revert(_ index: Int) {
        guard let diff, diff.hunks.indices.contains(index), let after else { return }
        let contents = diff.reverting([index])
        let path = path
        let session = appState.currentSession?.id
        Task {
            let ok = await FileCheckpointStore.shared.applyPartialRevert(
                path: path, expectedCurrent: after, contents: contents, session: session
            )
            if ok {
                failure = nil
                appState.showToast("Reverted hunk \(index + 1) in \(displayPath)")
            } else {
                failure = "\(displayPath) changed on disk since this diff was drawn. Reloaded; try again."
            }
            onChanged()
        }
    }
}
