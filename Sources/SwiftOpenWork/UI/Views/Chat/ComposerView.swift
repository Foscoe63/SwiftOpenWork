import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// MARK: - Custom Native Chat Text View for macOS (Return to send, Shift/Option/Slash+Return for newline)
public struct ChatInputRepresentable: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSend: () -> Void
    var onTextChange: ((String) -> Void)?
    var onImportAttachments: (([MessageAttachment]) -> Void)?

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = CustomChatNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.textContainer?.widthTracksTextView = true
        textView.onSend = onSend
        textView.onImportAttachments = onImportAttachments
        textView.placeholderString = placeholder
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let textView = nsView.documentView as? CustomChatNSTextView {
            if textView.string != text {
                textView.string = text
                textView.needsDisplay = true
            }
            textView.placeholderString = placeholder
            textView.onSend = onSend
            textView.onImportAttachments = onImportAttachments
        }
    }

    public class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputRepresentable
        weak var textView: CustomChatNSTextView?

        init(_ parent: ChatInputRepresentable) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.onTextChange?(tv.string)
        }
    }
}

final class CustomChatNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var onImportAttachments: (([MessageAttachment]) -> Void)?
    var placeholderString: String = ""

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        types.append(contentsOf: [.fileURL, .png, .tiff])
        return types
    }

    override func paste(_ sender: Any?) {
        let imported = ComposerAttachmentIntake.attachments(fromPasteboard: .general)
        if !imported.isEmpty {
            onImportAttachments?(imported)
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+V with image/files should hit our paste path even when AppKit would paste a filename string.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            let imported = ComposerAttachmentIntake.attachments(fromPasteboard: .general)
            if !imported.isEmpty {
                onImportAttachments?(imported)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canImport(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canImport(from: sender.draggingPasteboard) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canImport(from: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let imported = ComposerAttachmentIntake.attachments(fromPasteboard: sender.draggingPasteboard)
        guard !imported.isEmpty else { return false }
        onImportAttachments?(imported)
        return true
    }

    private func canImport(from pasteboard: NSPasteboard) -> Bool {
        !ComposerAttachmentIntake.attachments(fromPasteboard: pasteboard).isEmpty
    }

    override func keyDown(with event: NSEvent) {
        // Return key is 36, Numpad Enter is 76
        if event.keyCode == 36 || event.keyCode == 76 {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Shift+Return or Option+Return or Control+Return -> Insert a new line
            if flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) {
                super.insertNewline(nil)
                return
            }

            // Command+Return -> Send message
            if flags.contains(.command) {
                onSend?()
                return
            }

            // Check if user typed slash+return (text right before cursor is '/' or '\')
            let currentString = self.string as NSString
            let selectedRange = self.selectedRange()
            if selectedRange.location > 0 {
                let charBefore = currentString.substring(with: NSRange(location: selectedRange.location - 1, length: 1))
                if charBefore == "/" || charBefore == "\\" {
                    // Replace the trailing slash with a newline
                    self.insertText("\n", replacementRange: NSRange(location: selectedRange.location - 1, length: 1))
                    return
                }
            }

            // Plain Return without modifiers -> Send message
            if flags.isEmpty {
                onSend?()
                return
            }
        }

        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholderString.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let rect = NSRect(x: 4, y: 2, width: bounds.width - 8, height: bounds.height - 4)
            (placeholderString as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}

public struct ComposerView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var voiceEngine = VoiceSpeechEngine.shared
    @ObservedObject private var userChoiceManager = UserChoiceManager.shared
    @State private var attachments: [MessageAttachment] = []
    @State private var showingSlashCommands = false
    @State private var askUserFreeText: String = ""

    private var matchingPromptTemplates: [PromptTemplate] {
        let trimmed = appState.composerText.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return [] }
        let query = String(trimmed.dropFirst()).lowercased()
        if query.isEmpty {
            return PromptCatalog.sharedTemplates
        }
        return PromptCatalog.sharedTemplates.filter {
            $0.command.lowercased().contains(query) ||
            $0.title.lowercased().contains(query) ||
            $0.description.lowercased().contains(query)
        }
    }

    private var mentionQuery: String? {
        ComposerContextMentions.activeQuery(in: appState.composerText)
    }

    /// In a group chat, `@` also picks who acts: "@coder, plan the stack" makes Coder the only
    /// agent that answers, with tools. The room is offered first, files after.
    private var agentMentionSuggestions: [Agent] {
        guard let session = appState.currentSession, session.isGroup,
              let query = mentionQuery?.lowercased() else { return [] }
        return appState.participants(of: session).filter { agent in
            let slug = GroupChat.slugName(agent.name)
            return query.isEmpty || slug.hasPrefix(query) || slug.replacingOccurrences(of: "-", with: "").hasPrefix(query)
        }
    }

    private var mentionSuggestions: [ComposerContextMentions.Suggestion] {
        guard let query = mentionQuery else { return [] }
        return ComposerContextMentions.suggestions(
            query: query,
            workspacePath: appState.currentWorkspace.folderPath
        )
    }

    /// Attachments alone are a valid prompt — a dropped screenshot needs no sentence.
    private var canSend: Bool {
        !appState.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 8) {
            UnsavedEditorFilesBanner(appState: appState)

            if let queued = appState.queuedFollowUp {
                HStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                    Text("Queued: \(queued.text)")
                        .font(.system(size: 11.5))
                        .lineLimit(2)
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    Spacer()
                    if !appState.isGenerating {
                        Button("Send now") {
                            appState.sendQueuedFollowUpNow()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Button("Clear") {
                        appState.clearQueuedFollowUp()
                    }
                    .buttonStyle(.hitTestable)
                    .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .cornerRadius(8)
                .padding(.horizontal, 16)
            }

            if let pending = userChoiceManager.pending {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text("Agent is asking you")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    Text(pending.question)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                        .fixedSize(horizontal: false, vertical: true)

                    if pending.options.isEmpty {
                        HStack(spacing: 8) {
                            TextField("Type your answer…", text: $askUserFreeText)
                                .textFieldStyle(.roundedBorder)
                            Button("Submit") {
                                let answer = askUserFreeText
                                askUserFreeText = ""
                                userChoiceManager.resolve(answer: answer)
                            }
                            .disabled(askUserFreeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pending.options, id: \.self) { option in
                                Button {
                                    userChoiceManager.resolve(answer: option)
                                } label: {
                                    Text(option)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                                        )
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                            HStack(spacing: 8) {
                                TextField("Or type a custom answer…", text: $askUserFreeText)
                                    .textFieldStyle(.roundedBorder)
                                Button("Send") {
                                    let answer = askUserFreeText
                                    askUserFreeText = ""
                                    userChoiceManager.resolve(answer: answer)
                                }
                                .disabled(askUserFreeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                .padding(12)
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.45), lineWidth: 1)
                )
                .cornerRadius(10)
                .padding(.horizontal, 16)
            }

            if !agentMentionSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "person.2")
                            .font(.system(size: 10))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text("IN THIS ROOM \u{2014} ONLY THEY WILL ACT")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    ForEach(agentMentionSuggestions) { agent in
                        Button {
                            insertMention(GroupChat.slugName(agent.name))
                        } label: {
                            HStack(spacing: 8) {
                                AgentAvatar(agent: agent, size: 18)
                                Text("@\(GroupChat.slugName(agent.name))")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                Text(agent.name)
                                    .font(.system(size: 11))
                                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.hitTestable)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ThemeColors.accent(for: appState.settings.accentColor).opacity(0.45), lineWidth: 1)
                )
                .cornerRadius(10)
                .padding(.horizontal, 16)
            }

            if !mentionSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "at")
                            .font(.system(size: 10))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text("ATTACH CONTEXT")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(mentionSuggestions) { suggestion in
                                Button {
                                    insertMention(suggestion.path)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: suggestion.isDirectory ? "folder.fill" : "doc.text")
                                            .font(.system(size: 11))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                            .frame(width: 18)
                                        Text(suggestion.path)
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.06))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 160)
                }
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                )
                .padding(.horizontal, 16)
            }

            // Slash Command Autocomplete Popover / Overlay
            if !matchingPromptTemplates.isEmpty && appState.composerText.hasPrefix("/") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: "bolt.horizontal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                        Text("PROMPT TEMPLATES & SLASH COMMANDS")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matchingPromptTemplates) { template in
                                Button {
                                    appState.composerText = template.prompt
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: template.category.icon)
                                            .font(.system(size: 11))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))
                                            .frame(width: 18)

                                        Text(template.command)
                                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(ThemeColors.accent(for: appState.settings.accentColor))

                                        Text(template.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                                        Spacer()

                                        Text(template.category.rawValue)
                                            .font(.system(size: 9.5))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.06))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.hitTestable)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 180)
                }
                .background(ThemeColors.cardBg(for: appState.settings.theme))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.15), radius: 6, y: -2)
                .padding(.horizontal, 16)
            }

            // Attachments Preview Row
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { att in
                            HStack(spacing: 4) {
                                Image(systemName: ImageTransport.isImage(att) ? "photo.fill" : "doc.fill")
                                    .font(.system(size: 10))
                                Text(att.name)
                                    .font(.system(size: 11))
                                Button {
                                    attachments.removeAll(where: { $0.id == att.id })
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.hitTestable)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            // Input Box
            HStack(alignment: .bottom, spacing: 8) {
                // Attach File Button
                Button {
                    chooseFileAttachment()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        .frame(width: 28, height: 28)
                        .background(ThemeColors.cardBg(for: appState.settings.theme))
                        .cornerRadius(6)
                }
                .buttonStyle(.hitTestable)
                .help("Attach file from workspace")

                // Voice Dictation Button. Hidden when dictation is switched off in Settings —
                // that toggle was stored and never read, so this was drawn whatever it said.
                if appState.settings.voiceInputEnabled {
                    Button {
                        voiceEngine.toggleDictation { spokenText in
                            appState.composerText = spokenText
                        }
                    } label: {
                        Image(systemName: voiceEngine.isRecording ? "waveform.circle.fill" : "mic.fill")
                            .font(.system(size: 14))
                            .foregroundColor(voiceEngine.isRecording ? .red : ThemeColors.textSecondary(for: appState.settings.theme))
                            .frame(width: 28, height: 28)
                            .background(voiceEngine.isRecording ? Color.red.opacity(0.15) : ThemeColors.cardBg(for: appState.settings.theme))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.hitTestable)
                    .help(voiceEngine.isRecording ? "Stop Dictation" : "Dictate with Voice (macOS STT)")
                    .onReceive(voiceEngine.$lastError.compactMap { $0 }) { message in
                        appState.showToast(message)
                        voiceEngine.lastError = nil
                    }
                }

                // Text Input Field (Return sends, Shift/Option/Slash+Return inserts newline)
                ChatInputRepresentable(
                    text: $appState.composerText,
                    placeholder: "Type a prompt, @ for files, / for commands. Drop or paste files and images.",
                    onSend: {
                        if canSend { sendMessage() }
                    },
                    onImportAttachments: { imported in
                        addAttachments(imported)
                    }
                )
                .frame(minHeight: 36, maxHeight: 120)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)

                // Send or Stop Button
                if appState.isGenerating {
                    Button {
                        appState.cancelCurrentGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.hitTestable)
                    .help("Stop Generation")
                } else {
                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(canSend ? ThemeColors.accent(for: appState.settings.accentColor) : ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.4))
                    }
                    .buttonStyle(.hitTestable)
                    .disabled(!canSend)
                    .help("Send Message (Return)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .onReceive(appState.$composerAttachmentInbox) { inbox in
                guard !inbox.isEmpty else { return }
                addAttachments(inbox)
                appState.composerAttachmentInbox.removeAll()
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                importDroppedProviders(providers)
            }
            .background(ThemeColors.cardBg(for: appState.settings.theme))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
            )
            .cornerRadius(10)

            // Bottom Sub-Bar: Quick Controls (Agent pill, Model selector, reasoning toggle)
            HStack(spacing: 8) {
                if let session = appState.currentSession, session.isGroup {
                    // Which agent answers is decided per message by @mentions, not by a picker.
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                        Text("Group \u{00B7} \(session.participantIds.count) agents")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .cornerRadius(6)
                    .help("Address one agent with @name to have just that agent act; without a name everyone takes a turn.")
                } else {
                // Agent Picker Pill
                Menu {
                    ForEach(appState.agents) { ag in
                        Button {
                            appState.selectedAgentId = ag.id
                        } label: {
                            HStack {
                                Image(systemName: ag.avatar)
                                Text(ag.name)
                                if ag.id == appState.selectedAgentId {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: appState.currentAgent.avatar)
                            .font(.system(size: 10))
                        Text(appState.currentAgent.name)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(ThemeColors.cardBg(for: appState.settings.theme))
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                }

                // Model Picker Pill (searchable)
                ModelPickerButton(appState: appState, style: .composer)

                // Reasoning Effort Switch
                Button {
                    appState.isReasoningEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain")
                            .font(.system(size: 10))
                        Text(appState.isReasoningEnabled ? "Reasoning: On" : "Reasoning: Off")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(appState.isReasoningEnabled ? Color.purple.opacity(0.2) : Color.clear)
                    .foregroundColor(appState.isReasoningEnabled ? Color.purple : ThemeColors.textSecondary(for: appState.settings.theme))
                    .cornerRadius(4)
                }
                .buttonStyle(.hitTestable)
                .help(appState.isReasoningEnabled
                    ? "Reasoning is on for this chat — models that support it will think before answering. Click to disable."
                    : "Reasoning is off for this chat — models will answer directly without a thinking step. Click to enable.")

                Button {
                    appState.settings.planModeEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "list.clipboard")
                            .font(.system(size: 10))
                        Text(appState.settings.planModeEnabled ? "Plan: On" : "Plan: Off")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(appState.settings.planModeEnabled ? Color.orange.opacity(0.2) : Color.clear)
                    .foregroundColor(appState.settings.planModeEnabled ? .orange : ThemeColors.textSecondary(for: appState.settings.theme))
                    .cornerRadius(4)
                }
                .buttonStyle(.hitTestable)
                .help("Plan mode blocks writes until exit_plan_mode. Also toggled with /plan.")

                approvalSwitch

                turnBudgetMenu

                Spacer()

                if let meter = contextMeter, meter.isWorthShowing {
                    contextMeterPill(meter)
                }

                Text("SwiftOpenWork Standalone")
                    .font(.system(size: 10))
                    .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.5))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Ask / Safe / Allow for agent shell commands. It edits the one setting every agent and
    /// sub-agent reads, so it applies to whichever agent is selected.
    private var approvalSwitch: some View {
        HStack(spacing: 0) {
            ForEach(TerminalSafetyLevel.allCases) { level in
                let selected = appState.settings.terminalSafetyLevel == level
                Button {
                    appState.settings.terminalSafetyLevel = level
                } label: {
                    Text(level.shortName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(selected ? approvalTint(level).opacity(0.25) : Color.clear)
                        .foregroundColor(selected ? approvalTint(level) : ThemeColors.textSecondary(for: appState.settings.theme))
                }
                .buttonStyle(.hitTestable)
                .help(level.helpText)
            }
        }
        .background(ThemeColors.cardBg(for: appState.settings.theme))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
        )
    }

    private func approvalTint(_ level: TerminalSafetyLevel) -> Color {
        switch level {
        case .alwaysAsk: return .blue
        case .safeOnly: return .green
        case .allowAll: return .orange
        case .allowEverything: return .red
        }
    }

    /// The per-turn token budget, adjustable (or off) without opening Settings.
    private var turnBudgetMenu: some View {
        let budget = appState.settings.maxTurnTokens
        let presets = [1_000_000, 2_000_000, 5_000_000, 10_000_000]
        return Menu {
            ForEach(presets, id: \.self) { value in
                Button {
                    appState.settings.maxTurnTokens = value
                } label: {
                    Text("\(value / 1_000_000)M tokens per turn" + (budget == value ? "  ✓" : ""))
                }
            }
            Divider()
            Button {
                appState.settings.maxTurnTokens = 0
            } label: {
                Text("No limit" + (budget <= 0 ? "  ✓" : ""))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 10))
                Text(budget <= 0 ? "Budget: Off" : "Budget: \(budget / 1_000_000)M")
                    .font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundColor(budget <= 0 ? .orange : ThemeColors.textSecondary(for: appState.settings.theme))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Token budget for one turn. A turn halts with a Continue prompt when it goes over. Choose No limit to turn it off.")
    }

    private var contextMeter: ContextMeter? {
        guard let session = appState.currentSession else { return nil }
        return ContextMeter.forSession(session, contextWindow: appState.currentModel.contextWindow)
    }

    /// Context exhaustion looks like the model getting stupid, not like an error, so the only
    /// place this helps is next to the box where you decide whether to keep typing into it.
    private func contextMeterPill(_ meter: ContextMeter) -> some View {
        HStack(spacing: 4) {
            Image(systemName: meter.pressure == .tight ? "gauge.high" : "gauge.medium")
                .font(.system(size: 10))
            Text(meter.label)
                .font(.system(size: 10, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(contextMeterTint(meter).opacity(0.18))
        .foregroundColor(contextMeterTint(meter))
        .cornerRadius(4)
        .help(meter.help)
    }

    private func contextMeterTint(_ meter: ContextMeter) -> Color {
        switch meter.pressure {
        case .comfortable: return ThemeColors.textSecondary(for: appState.settings.theme)
        case .filling: return .orange
        case .tight: return .red
        }
    }

    private func insertMention(_ path: String) {
        var text = appState.composerText
        if let at = text.lastIndex(of: "@") {
            text = String(text[..<at]) + "@\(path) "
        } else {
            text += "@\(path) "
        }
        appState.composerText = text
    }

    private func sendMessage() {
        let typed = appState.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments
        guard !typed.isEmpty || !atts.isEmpty else { return }
        // A dropped screenshot with no sentence still has to reach the model as a real turn.
        let text = typed.isEmpty
            ? (atts.count == 1 ? "Look at the attached \(atts[0].name)." : "Look at the \(atts.count) attached files.")
            : typed
        attachments.removeAll()
        appState.sendMessage(text: text, attachments: atts)
    }

    private func addAttachments(_ imported: [MessageAttachment]) {
        guard !imported.isEmpty else { return }
        for att in imported where !attachments.contains(where: { $0.path == att.path }) {
            attachments.append(att)
        }
    }

    /// SwiftUI drop on the composer chrome, for drags that miss the text view itself.
    private func importDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let att = ComposerAttachmentIntake.attachment(fromFileURL: url) else { return }
                DispatchQueue.main.async {
                    addAttachments([att])
                }
            }
        }
        return handled
    }

    private func chooseFileAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            addAttachments(panel.urls.compactMap(ComposerAttachmentIntake.attachment(fromFileURL:)))
        }
    }
}


/// Unsaved editor changes are invisible to the agent: its tools read the file on disk. Asking it
/// to "fix the function I just edited" while the edit is unsaved gets a fix to the old code, which
/// then collides with the edit. Saying so beside the send button is cheaper than that argument.
struct UnsavedEditorFilesBanner: View {
    @ObservedObject var appState: AppState
    @ObservedObject var editors = EditorWorkspace.shared

    var body: some View {
        let unsaved = editors.unsavedDocuments
        if !unsaved.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .foregroundColor(.orange)
                Text(Self.message(for: unsaved.map(\.fileName)))
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))
                Spacer()
                Button("Save All") {
                    let failures = editors.saveAll()
                    if let first = failures.first {
                        appState.showToast("\(first.fileName): \(first.reason)")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Show") {
                    if let first = unsaved.first {
                        appState.openInEditor(path: first.path)
                    }
                }
                .buttonStyle(.hitTestable)
                .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal, 16)
        }
    }

    static func message(for names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) has unsaved edits — the agent reads the saved version."
        case 2: return "\(names[0]) and \(names[1]) have unsaved edits — the agent reads the saved versions."
        default: return "\(names.count) files have unsaved edits — the agent reads the saved versions."
        }
    }
}
