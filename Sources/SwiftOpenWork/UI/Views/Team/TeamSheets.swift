import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

/// The colours every Team view uses, from the app's own theme.
@MainActor
struct TeamPalette {
    let theme: AppTheme
    let accentChoice: AccentColorChoice
    init(_ state: AppState) { theme = state.settings.theme; accentChoice = state.settings.accentColor }
    var bg: Color { ThemeColors.bg(for: theme) }
    var card: Color { ThemeColors.cardBg(for: theme) }
    var border: Color { ThemeColors.border(for: theme) }
    var text: Color { ThemeColors.textPrimary(for: theme) }
    var muted: Color { ThemeColors.textSecondary(for: theme) }
    var accent: Color { ThemeColors.accent(for: accentChoice) }
}

/// Edits one department's shared instructions: the text every agent in it sees at the start of each turn.
/// A byte counter that turns red past the limit, a last-saved time, Save only when something changed and
/// it fits, and a discard prompt if you close with unsaved edits.
struct DepartmentInstructionsSheet: View {
    @ObservedObject var appState: AppState
    let department: String
    let onClose: () -> Void

    @State private var text = ""
    @State private var savedText = ""
    @State private var updatedAt: Date?
    @State private var error = ""
    @State private var confirmDiscard = false
    @State private var loaded = false

    private var p: TeamPalette { TeamPalette(appState) }
    private var label: String { appState.departmentLabel(department) }
    private var bytes: Int { DepartmentInstructions.byteCount(text) }
    private var overLimit: Bool { bytes > DepartmentInstructions.maxBytes }
    private var dirty: Bool { text != savedText }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "book").foregroundColor(p.accent)
                Text("\(label) shared instructions").font(.system(size: 18, weight: .semibold)).foregroundColor(p.text)
            }
            Text("Shown to every agent in this department at the start of each turn, including the ones the lead hands work to. Only you can edit them; agents cannot.")
                .font(.system(size: 12.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12.5)).frame(minHeight: 200, maxHeight: 260)
                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(p.border))
                .accessibilityLabel("\(label) shared instructions")
            HStack(alignment: .top) {
                Text(footnote).font(.system(size: 11.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text("\(bytes.formatted()) / \(DepartmentInstructions.maxBytes.formatted()) bytes")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundColor(overLimit ? .red : p.muted)
            }
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel") { if dirty { confirmDiscard = true } else { onClose() } }
                    .keyboardShortcut(.cancelAction)
                Button("Save shared instructions") { save() }
                    .buttonStyle(.borderedProminent).disabled(!dirty || overLimit)
            }
        }
        .padding(24).frame(width: 600).background(p.bg)
        .onAppear(perform: load)
        .interactiveDismissDisabled(dirty)
        .confirmationDialog("Discard unsaved changes to these shared instructions?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { onClose() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var footnote: String {
        var parts = ["Keep durable department facts here. Private notes stay in each agent's own memory."]
        if let updatedAt { parts.append("Last saved \(updatedAt.formatted(date: .abbreviated, time: .shortened)).") }
        return parts.joined(separator: " ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let brief = appState.departmentInstructions(department)
        text = brief?.text ?? ""
        savedText = text
        updatedAt = brief?.updatedAt
    }

    private func save() {
        switch appState.setDepartmentInstructions(department, text: text) {
        case .saved, .cleared:
            savedText = text
            error = ""
            onClose()
        case .tooLong(let size, let limit):
            error = "That is \(size.formatted()) bytes; the limit is \(limit.formatted())."
        case .unknownDepartment:
            error = "This department no longer exists."
        }
    }
}

/// A department's shared notes. Agents propose facts; here the person accepts, edits, pins or deletes them.
/// Only accepted notes reach an agent's prompt, and the dialog says how many fit.
struct DepartmentMemorySheet: View {
    @ObservedObject var appState: AppState
    let department: String
    let onClose: () -> Void

    @State private var editing: DepartmentFact?
    @State private var formOpen = false
    @State private var kind: DepartmentFactKind = .term
    @State private var name = ""
    @State private var detail = ""
    @State private var aliases = ""
    @State private var error = ""
    @State private var query = ""

    private var p: TeamPalette { TeamPalette(appState) }
    private var label: String { appState.departmentLabel(department) }
    private var facts: [DepartmentFact] { appState.departmentFacts(department) }
    private var proposed: [DepartmentFact] { facts.filter { $0.status == .proposed } }
    private var accepted: [DepartmentFact] {
        let all = facts.filter { $0.status == .accepted }
        return query.trimmingCharacters(in: .whitespaces).isEmpty
            ? all : DepartmentMemory.search(all, query: query, limit: 25)
    }
    private var selection: DepartmentMemory.Selection { appState.departmentMemorySelection(department) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain").foregroundColor(p.accent)
                Text("\(label) shared memory").font(.system(size: 18, weight: .semibold)).foregroundColor(p.text)
                Spacer()
                Button { openForm(nil) } label: { Label("Add a note", systemImage: "plus").font(.system(size: 12, weight: .medium)) }
                    .buttonStyle(.plain).foregroundColor(p.text)
            }
            Text("People, places, decisions and terms every agent in this department shares. Agents suggest notes; nothing is shared until you accept it.")
                .font(.system(size: 12.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Search notes", text: $query).textFieldStyle(.roundedBorder)
            if !formOpen, !error.isEmpty { Text(error).font(.system(size: 12)).foregroundColor(.red) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if formOpen { form }
                    if !proposed.isEmpty {
                        sectionTitle("To review (\(proposed.count))")
                        ForEach(proposed) { card($0) }
                    }
                    sectionTitle("Shared notes (\(accepted.count))")
                    if accepted.isEmpty {
                        Text(query.isEmpty ? "No shared notes yet. Add one, or accept a suggestion from an agent." : "No notes match.")
                            .font(.system(size: 12)).foregroundColor(p.muted)
                    }
                    ForEach(accepted) { card($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 420)
            HStack {
                Text(selection.total == 0 ? "" : "\(selection.loadedIds.count) of \(selection.total) notes fit in each agent's prompt (6,000 bytes); the rest stay searchable by the agents.")
                    .font(.system(size: 11.5)).foregroundColor(p.muted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done", action: onClose).buttonStyle(.borderedProminent).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 640).background(p.bg)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(p.muted)
    }

    private func card(_ fact: DepartmentFact) -> some View {
        let isProposal = fact.status == .proposed
        let loaded = selection.loadedIds.contains(fact.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fact.kind.label).font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(p.border)).foregroundColor(p.muted)
                Text(fact.name).font(.system(size: 13.5, weight: .semibold)).foregroundColor(p.text)
                if fact.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundColor(p.accent) }
                Spacer()
                if !isProposal && !loaded { Text("not in prompt").font(.system(size: 10.5)).foregroundColor(p.muted) }
            }
            if !fact.detail.isEmpty {
                Text(fact.detail).font(.system(size: 12.5)).foregroundColor(p.text).fixedSize(horizontal: false, vertical: true)
            }
            if !fact.aliases.isEmpty {
                Text("Also: " + fact.aliases.joined(separator: ", ")).font(.system(size: 11.5)).foregroundColor(p.muted)
            }
            if isProposal {
                let who = fact.sourceName.isEmpty ? "an agent" : fact.sourceName
                Text("Suggested by \(who), \(fact.proposedAt.formatted(date: .abbreviated, time: .shortened))" + (fact.replaces.isEmpty ? "" : ". Would replace the note with the same key."))
                    .font(.system(size: 11.5)).foregroundColor(p.muted)
            }
            HStack(spacing: 14) {
                if isProposal {
                    Button("Accept") { run { try appState.resolveDepartmentFact(department, id: fact.id, accept: true, expectedRevision: fact.revision) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Edit") { openForm(fact) }
                    Button("Reject") { run { try appState.resolveDepartmentFact(department, id: fact.id, accept: false, expectedRevision: fact.revision) } }
                } else {
                    Button("Edit") { openForm(fact) }
                    Button(fact.pinned ? "Unpin" : "Pin") { run { try appState.updateDepartmentFact(department, id: fact.id, patch: .init(pinned: !fact.pinned), expectedRevision: fact.revision) } }
                    if DepartmentMemory.canUndo(fact) {
                        Button("Undo accept") { run { try appState.undoDepartmentFactAccept(department, id: fact.id) } }
                    }
                    Button("Delete", role: .destructive) { run { try appState.removeDepartmentFact(department, id: fact.id, expectedRevision: fact.revision) } }
                }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(p.muted)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(isProposal ? p.accent.opacity(0.10) : p.card))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(editing == nil ? "New note" : (editing?.status == .proposed ? "Edit and accept" : "Edit note"))
            Picker("Kind", selection: $kind) { ForEach(DepartmentFactKind.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            TextField("Name (\(DepartmentMemory.nameMax) characters at most)", text: $name).textFieldStyle(.roundedBorder)
            TextField("Detail: the fact, its context, why it matters", text: $detail, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
            TextField("Also known as (comma separated)", text: $aliases).textFieldStyle(.roundedBorder)
            HStack {
                Text("\(detail.count) / \(DepartmentMemory.detailMax)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(detail.count > DepartmentMemory.detailMax ? .red : p.muted)
                if !error.isEmpty { Text(error).font(.system(size: 11.5)).foregroundColor(.red) }
                Spacer()
                Button("Cancel") { closeForm() }
                Button(editing?.status == .proposed ? "Save and accept" : "Save", action: saveForm)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || detail.count > DepartmentMemory.detailMax)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(p.border))
    }

    private func openForm(_ fact: DepartmentFact?) {
        editing = fact
        kind = fact?.kind ?? .term
        name = fact?.name ?? ""
        detail = fact?.detail ?? ""
        aliases = fact?.aliases.joined(separator: ", ") ?? ""
        error = ""
        formOpen = true
    }

    private func closeForm() { formOpen = false; editing = nil; error = "" }

    private func saveForm() {
        let list = aliases.split(separator: ",").map { String($0) }
        let current = editing
        run {
            if let current {
                try appState.updateDepartmentFact(department, id: current.id,
                    patch: .init(kind: kind, name: name, detail: detail, aliases: list), expectedRevision: current.revision)
            } else {
                try appState.addDepartmentFact(department, DepartmentFactInput(kind: kind, name: name, detail: detail, aliases: list))
            }
            closeForm()
        }
    }

    /// Runs a change and shows why it was refused (stale, duplicate, too long) instead of failing silently.
    private func run(_ change: () throws -> Void) {
        do { try change(); if !formOpen { error = "" } } catch { self.error = error.localizedDescription }
    }
}

/// A team note an agent proposed, in the chat where it proposed it. The person can accept or reject it right
/// here, and take an accept back while the note is untouched. The state is read live, so the same note
/// accepted in the department's memory dialog shows up here too.
struct TeamNoteCard: View {
    @ObservedObject var appState: AppState
    let department: String
    let factId: String

    @State private var error = ""

    private var p: TeamPalette { TeamPalette(appState) }
    private var label: String { appState.departmentLabel(department) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fact = appState.departmentFact(department, id: factId) {
                header(fact)
                if !fact.detail.isEmpty {
                    Text(fact.detail).font(.system(size: 13)).foregroundColor(p.text).fixedSize(horizontal: false, vertical: true)
                }
                if !fact.aliases.isEmpty {
                    Text("Also: " + fact.aliases.joined(separator: ", ")).font(.system(size: 11.5)).foregroundColor(p.muted)
                }
                actions(fact)
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundColor(.red) }
            } else {
                Text("This team note is no longer available.").font(.system(size: 12.5)).foregroundColor(p.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.accent.opacity(0.3)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Team note")
    }

    private func header(_ fact: DepartmentFact) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "brain").foregroundColor(p.accent)
            Text(fact.kind.label).font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(p.border)).foregroundColor(p.muted)
            Text(fact.name).font(.system(size: 14, weight: .semibold)).foregroundColor(p.text)
            Spacer()
            Text(status(fact)).font(.system(size: 11.5)).foregroundColor(p.muted)
        }
    }

    private func status(_ fact: DepartmentFact) -> String {
        switch fact.status {
        case .proposed: return "Suggested for \(label) shared memory"
        case .accepted: return "In \(label) shared memory"
        case .superseded: return "Replaced by a newer note"
        case .deleted: return fact.acceptedRevision == nil ? "Rejected" : "Removed"
        }
    }

    @ViewBuilder
    private func actions(_ fact: DepartmentFact) -> some View {
        switch fact.status {
        case .proposed:
            HStack(spacing: 12) {
                Button("Accept") {
                    run { try appState.resolveDepartmentFact(department, id: fact.id, accept: true, expectedRevision: fact.revision) }
                }.buttonStyle(.borderedProminent).controlSize(.small)
                Button("Reject") {
                    run { try appState.resolveDepartmentFact(department, id: fact.id, accept: false, expectedRevision: fact.revision) }
                }.buttonStyle(.plain).font(.system(size: 12.5)).foregroundColor(p.muted)
                if !fact.replaces.isEmpty {
                    Text("Replaces the note with the same key.").font(.system(size: 11.5)).foregroundColor(p.muted)
                }
            }
        case .accepted where DepartmentMemory.canUndo(fact):
            Button("Undo") { run { try appState.undoDepartmentFactAccept(department, id: fact.id) } }
                .buttonStyle(.plain).font(.system(size: 12.5)).foregroundColor(p.muted)
        default:
            EmptyView()
        }
    }

    /// Runs a change and shows why it was refused (stale, conflicting) instead of failing silently.
    private func run(_ change: () throws -> Void) {
        do { try change(); error = "" } catch { self.error = error.localizedDescription }
    }
}
