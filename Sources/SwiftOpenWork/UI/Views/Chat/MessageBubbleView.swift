import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

public struct MessageBubbleView: View {
    let message: ChatMessage
    @ObservedObject var appState: AppState

    public init(message: ChatMessage, appState: AppState) {
        self.message = message
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.role == .user {
                userMessageLayout
            } else {
                assistantMessageLayout
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Right-click actions, attached to the message's *chrome* rather than to the whole bubble.
    ///
    /// A `.contextMenu` on the container wrapping the message text installs a hit-testing region
    /// over the entire subtree, and on macOS that swallows the mouse drag `.textSelection`
    /// depends on. The text was marked selectable and could not be selected, and clicks aimed at
    /// the buttons inside the bubble were intercepted on the way — so the reply could be neither
    /// highlighted nor copied. Anchoring the menu to the avatar and header keeps right-click
    /// where people reach for it while leaving the text alone.
    @ViewBuilder
    private var messageActions: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copyableText, forType: .string)
        } label: {
            Label("Copy Message", systemImage: "doc.on.doc")
        }

        if canForkHere {
            Divider()
            Button {
                guard let session = appState.currentSession else { return }
                appState.forkSession(session, at: message.id)
            } label: {
                Label("Fork Conversation From Here", systemImage: "arrow.triangle.branch")
            }
        }

        // Forking branches the transcript and leaves the disk alone; this is the other half.
        if canRestoreHere {
            if !canForkHere { Divider() }
            Button {
                appState.prepareRestore(toMessageId: message.id)
            } label: {
                Label("Restore Files to Before This Turn…", systemImage: "clock.arrow.circlepath")
            }
        }
    }

    /// What "Copy Message" should actually put on the pasteboard.
    ///
    /// Copying `content` alone silently yields an empty string for a turn that produced only
    /// reasoning — which reads exactly like a broken Copy button.
    private var copyableText: String {
        let visible = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.isEmpty { return message.content }
        if let reasoning = message.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return reasoning
        }
        return message.content
    }

    /// Only turns that actually wrote something have a snapshot to go back to.
    private var canRestoreHere: Bool {
        appState.restorableMessageIds.contains(message.id)
    }

    /// Forking at the last message would copy the session rather than branch it.
    private var canForkHere: Bool {
        guard let session = appState.currentSession,
              let index = session.messages.firstIndex(where: { $0.id == message.id }) else { return false }
        return index < session.messages.count - 1
    }

    // MARK: - User Message
    private var userMessageLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("You")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
                }

                ModMaskedMessage(component: "UserMessage", text: message.content, isStreaming: false) { shown in
                    Text(shown)
                        .font(.system(size: 13.5))
                        .foregroundColor(.white)
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(ThemeColors.accent(for: appState.settings.accentColor))
                    .cornerRadius(12)
                    .textSelection(.enabled)

                // Attachments if any
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { att in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 9))
                                Text(att.name)
                                    .font(.system(size: 10))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(6)
                        }
                    }
                }
            }

            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                .contextMenu { messageActions }
        }
    }

    // MARK: - Assistant Message
    private var assistantMessageLayout: some View {
        let pendingApprovals = message.toolCalls.filter {
            $0.status == .waitingApproval || $0.status == .pendingApproval
        }
        let otherToolCalls = message.toolCalls.filter {
            $0.status != .waitingApproval && $0.status != .pendingApproval
        }

        return HStack(alignment: .top, spacing: 12) {
            // Agent Avatar
            Image(systemName: message.agentAvatar ?? "sparkles")
                .font(.system(size: 16))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Color(hex: message.agentColor ?? "#8B5CF6"))
                .clipShape(Circle())
                .contextMenu { messageActions }

            VStack(alignment: .leading, spacing: 8) {
                // Header (Agent Name & Model Pill)
                HStack(spacing: 8) {
                    Text(message.agentName ?? "SwiftOpenWork Agent")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(ThemeColors.textPrimary(for: appState.settings.theme))

                    if let model = message.modelId {
                        Text(model)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ThemeColors.border(for: appState.settings.theme))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .cornerRadius(4)
                    }

                    Text(message.timestamp, style: .time)
                        .font(.system(size: 10))
                        .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))

                    if let speed = MessageBubbleView.speedLabel(message) {
                        Text(speed)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme).opacity(0.6))
                            .help("Decode speed measured by the model engine for this reply")
                    }

                    Spacer()

                    // Speak Text (TTS) Action. Gated on the Settings toggle, which was stored
                    // and never read — this button appeared whether it was on or off.
                    if appState.settings.voiceSynthesisEnabled {
                        Button {
                            VoiceSpeechEngine.shared.speak(text: message.content)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                                .font(.system(size: 11))
                                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        }
                        .buttonStyle(.hitTestable)
                        .help("Read Aloud (macOS Speech Synthesizer)")
                    }

                    // Copy Action
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyableText, forType: .string)
                        appState.showToast("Copied to clipboard")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                    }
                    .buttonStyle(.hitTestable)
                    .help("Copy Message")
                }

                // Reasoning Section (if present)
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosureView(reasoning: reasoning, thinkingTimeMs: message.thinkingTimeMs)
                }

                // Sub-Agent Tasks (if any were spawned)
                if !message.subAgentTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.subAgentTasks) { task in
                            SubAgentExecutionCardView(task: task)
                        }
                    }
                }

                // Completed / running tool calls stay above the answer (collapsed when many).
                if !otherToolCalls.isEmpty {
                    toolCallsSection(otherToolCalls, collapsedLabel: "\(otherToolCalls.count) tool calls")
                }

                if !message.notices.isEmpty && (message.isStreaming || message.content.isEmpty) {
                    FlowNoticeChipsView(notices: message.notices, theme: appState.settings.theme)
                }

                if let haltText = message.haltText, !haltText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text(haltText)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.orange)
                        Text("Press Continue to resume from where the agent stopped.")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                        Button {
                            appState.continueAfterHalt()
                        } label: {
                            Text("Continue")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isGenerating)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                    .cornerRadius(8)
                }

                // Main Markdown / Content Text — read this first.
                if !message.content.isEmpty {
                    ModMaskedMessage(component: "AssistantMessage", text: message.content, isStreaming: message.isStreaming) { shown in
                        MarkdownRichContentView(content: shown, appState: appState)
                    }
                } else if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(message.notices.last ?? "Generating response...")
                            .font(.system(size: 11))
                            .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
                            .lineLimit(2)
                    }
                }

                // Pending approvals AFTER the answer so scroll-to-bottom lands on Approve/Reject
                // instead of burying them under a long MCP tool list + reply.
                if !pendingApprovals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pendingApprovals.count == 1 ? "Approval needed" : "Approvals needed")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                        ForEach(pendingApprovals) { toolCall in
                            ToolCallCardView(
                                toolCall: toolCall,
                                preferExpanded: true,
                                appState: appState,
                                onReviewTurn: { appState.presentTurnChangeReview = true }
                            )
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                    )
                    .cornerRadius(8)
                    .id("approval-\(message.id)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func toolCallsSection(_ calls: [ToolCallInfo], collapsedLabel: String) -> some View {
        if calls.count > 3 {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(calls) { toolCall in
                        ToolCallCardView(
                            toolCall: toolCall,
                            appState: appState,
                            onReviewTurn: { appState.presentTurnChangeReview = true }
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                    Text(collapsedLabel)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(ThemeColors.textSecondary(for: appState.settings.theme))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(calls) { toolCall in
                    ToolCallCardView(
                        toolCall: toolCall,
                        appState: appState,
                        onReviewTurn: { appState.presentTurnChangeReview = true }
                    )
                }
            }
        }
    }
}

private struct FlowNoticeChipsView: View {
    let notices: [String]
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ThemeColors.border(for: theme).opacity(0.45))
                    .cornerRadius(10)
            }
        }
    }
}

extension MessageBubbleView {
    /// "38 tok/s" for a reply whose provider measured its speed; nothing while streaming or when
    /// no measurement exists, so an estimate never passes for one.
    static func speedLabel(_ message: ChatMessage) -> String? {
        guard !message.isStreaming,
              let speed = message.generationTokensPerSecond,
              speed.isFinite, speed > 0 else { return nil }
        return speed >= 10 ? "\(Int(speed.rounded())) tok/s" : String(format: "%.1f tok/s", speed)
    }
}
