import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// The strip mods draw above the message box (`AbovePrompt`). Empty when no mod draws one.
struct ModBandView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var host = ModHost.shared
    @State private var result: ModRenderResult = .none

    var body: some View {
        Group {
            if host.hasBand, case .tree(let node) = result, !result.isEmpty {
                ModElementView(node: node, component: "AbovePrompt", requestId: "band", theme: "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1))
                    .padding(.horizontal, 16)
            }
        }
        .task(id: "\(host.revision)-\(host.hasBand)-\(appState.isGenerating)") {
            guard host.hasBand else { result = .none; return }
            result = await host.render(component: "AbovePrompt", requestId: "band", props: [
                "hasSurvey": .bool(false), "isWorking": .bool(appState.isGenerating), "maxRows": .number(16), "bodyColumns": .number(80),
            ])
        }
    }
}

/// One line of text from each mod that set a status (`$.ui.status`).
struct ModStatusLineView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var host = ModHost.shared

    var body: some View {
        if !host.statusLines.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 9.5))
                Text(host.statusLines.map(\.text).joined(separator: "  ·  "))
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            .padding(.horizontal, 18)
        }
    }
}

/// The Mods tab of the inspector: the panes mods opened with `$.ui.open`.
struct ModPanesView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var host = ModHost.shared
    @State private var result: ModRenderResult = .none

    var body: some View {
        VStack(spacing: 0) {
            if host.panes.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension").font(.system(size: 26)).foregroundColor(.secondary)
                    Text("No mod has a pane open")
                        .font(.system(size: 12, weight: .semibold))
                    Text("A mod can open a pane here. Turn mods on in Settings → Mods.")
                        .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
                    // Some mods only open their pane when something happens (Helper Desk: a subagent).
                    // Their commands are listed so the pane can be opened any time, in any chat.
                    if !host.commands.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Open from a running mod").font(.system(size: 11, weight: .semibold))
                        ForEach(host.commands) { command in
                            Button { _ = appState.handleModSlashCommand("/\(command.name)") } label: {
                                VStack(spacing: 1) {
                                    Text("/\(command.name)  ·  \(command.plugin)").font(.system(size: 11, weight: .medium))
                                    if !command.description.isEmpty {
                                        Text(command.description).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    Button("Open Mods settings") { appState.settingsTab = "mods"; appState.navigationDestination = .settings }
                        .controlSize(.small)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 4) {
                    ForEach(host.panes) { pane in
                        HStack(spacing: 4) {
                            Text(pane.title).font(.system(size: 11, weight: pane.id == host.activePaneId ? .semibold : .regular)).lineLimit(1)
                            Button { host.closePane(pane.id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                .buttonStyle(.hitTestable).help("Close")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(pane.id == host.activePaneId ? ThemeColors.cardBg(for: appState.settings.theme) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture { host.activePaneId = pane.id }
                    }
                    Spacer()
                }
                .padding(8)
                Divider()
                ScrollView {
                    if case .tree(let node) = result, let id = host.activePaneId {
                        ModElementView(node: node, component: "Pane", requestId: id, theme: "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
            }
        }
        .task(id: "\(host.revision)-\(host.activePaneId ?? "")") {
            guard let id = host.activePaneId, let pane = host.panes.first(where: { $0.id == id }) else { result = .none; return }
            result = await host.render(component: "Pane", requestId: id, props: [
                "title": .string(pane.title), "isFocused": .bool(true), "bodyColumns": .number(44), "placement": .string("dock"),
            ])
        }
    }
}

/// A question a mod asked with `$.ui.ask`.
struct ModQuestionSheet: View {
    let question: ModQuestion
    @State private var picked: Set<String> = []
    @State private var other = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension").foregroundColor(.accentColor)
                Text(question.plugin).font(.system(size: 12, weight: .semibold))
                if let header = question.header, !header.isEmpty {
                    Text(header).font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15)).cornerRadius(4)
                }
            }
            Text(question.question).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            ForEach(question.options, id: \.self) { option in
                Button {
                    if question.multiSelect { if picked.contains(option) { picked.remove(option) } else { picked.insert(option) } }
                    else { ModHost.shared.answer(question.id, selection: [option]) }
                } label: {
                    HStack {
                        if question.multiSelect { Image(systemName: picked.contains(option) ? "checkmark.square.fill" : "square") }
                        Text(option).font(.system(size: 12)); Spacer()
                    }
                    .padding(8).frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(6)
                }
                .buttonStyle(.hitTestable)
            }
            HStack {
                TextField("Something else…", text: $other).textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                if question.multiSelect || !other.isEmpty { Button("Send") { send() }.disabled(picked.isEmpty && other.isEmpty) }
            }
            HStack { Spacer(); Button("Dismiss") { ModHost.shared.answer(question.id, selection: nil) }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 440)
    }

    private func send() {
        var all = Array(picked)
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { all.append(typed) }
        guard !all.isEmpty else { return }
        ModHost.shared.answer(question.id, selection: all)
    }
}
