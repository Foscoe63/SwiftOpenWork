import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The Slash Commands page.

extension SettingsView {
    // MARK: - Slash commands
    var slashCommandsPage: some View {
        let theme = appState.settings.theme
        return VStack(spacing: 16) {
            SettingsCard(
                title: "Built-in Commands",
                description: "Handled by the app. Type / in the message box to pick one.",
                icon: "terminal"
            ) {
                ForEach(SlashCommands.builtIn, id: \.command) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.command)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                            .frame(width: 90, alignment: .leading)
                        Text(item.description)
                            .font(.system(size: 11.5))
                            .foregroundColor(ThemeColors.textSecondary(for: theme))
                        Spacer()
                    }
                }
            }

            SettingsCard(
                title: "Your Commands (\(appState.customSlashCommands.count))",
                description: "A command sends its saved prompt. Anything typed after it is added to the prompt, or placed where $ARGUMENTS appears.",
                icon: "slash.circle"
            ) {
                if appState.customSlashCommands.isEmpty {
                    Text("None yet. Add one below.")
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                ForEach(appState.customSlashCommands) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.command)
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                            if !item.description.isEmpty {
                                Text(item.description)
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            Text(item.prompt)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            slashEditingId = item.id
                            slashCommandName = item.command
                            slashDescription = item.description
                            slashPrompt = item.prompt
                            slashProblem = nil
                        } label: {
                            Image(systemName: "pencil").font(.system(size: 11))
                        }
                        .buttonStyle(.hitTestable)
                        .help("Edit")
                        Button {
                            appState.customSlashCommands.removeAll { $0.id == item.id }
                            appState.saveCustomSlashCommands()
                            if slashEditingId == item.id { resetSlashDraft() }
                        } label: {
                            Image(systemName: "trash").foregroundColor(.red).font(.system(size: 11))
                        }
                        .buttonStyle(.hitTestable)
                        .help("Delete")
                    }
                    .padding(8)
                    .background(ThemeColors.border(for: theme).opacity(0.3))
                    .cornerRadius(6)
                }
            }

            SettingsCard(
                title: slashEditingId == nil ? "Add a Command" : "Edit Command",
                icon: "plus.circle"
            ) {
                TextField("/standup", text: $slashCommandName)
                    .textFieldStyle(.roundedBorder)
                TextField("Description (optional)", text: $slashDescription)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $slashPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColors.border(for: theme), lineWidth: 1))
                Text("Prompt sent when you run the command. Use $ARGUMENTS to place what you type after it.")
                    .font(.system(size: 10.5))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                if let problem = slashProblem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                HStack {
                    Button(slashEditingId == nil ? "Add Command" : "Save Changes") { saveSlashDraft() }
                        .buttonStyle(.borderedProminent)
                    if slashEditingId != nil {
                        Button("Cancel") { resetSlashDraft() }
                    }
                }
            }
        }
    }

    func resetSlashDraft() {
        slashEditingId = nil
        slashCommandName = ""
        slashDescription = ""
        slashPrompt = ""
        slashProblem = nil
    }

    func saveSlashDraft() {
        if let problem = SlashCommands.problem(
            command: slashCommandName, prompt: slashPrompt,
            existing: appState.customSlashCommands, editing: slashEditingId
        ) {
            slashProblem = problem
            return
        }
        let name = SlashCommands.normalized(slashCommandName)
        let description = slashDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = slashEditingId, let index = appState.customSlashCommands.firstIndex(where: { $0.id == id }) {
            appState.customSlashCommands[index].command = name
            appState.customSlashCommands[index].description = description
            appState.customSlashCommands[index].prompt = slashPrompt
        } else {
            appState.customSlashCommands.append(CustomSlashCommand(command: name, description: description, prompt: slashPrompt))
        }
        appState.saveCustomSlashCommands()
        appState.showToast("Saved \(name)")
        resetSlashDraft()
    }
}
