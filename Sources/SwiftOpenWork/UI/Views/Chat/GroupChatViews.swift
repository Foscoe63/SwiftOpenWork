import SwiftUI
import SwiftOpenWorkCore

// MARK: - Layout

/// Lays children out left to right and wraps onto a new row when the width runs out, centring
/// each row. The group picker's agent chips have unpredictable widths ("Executive Assistant"
/// beside "Data"), so a fixed grid would either clip the long names or leave gaps.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let laidOut = rows(for: subviews, maxWidth: maxWidth)
        let width = laidOut.map(\.width).max() ?? 0
        let height = laidOut.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, laidOut.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }
}

// MARK: - Avatar

/// An agent's round badge — the same one its chat bubbles wear, so the roster, the picker and the
/// transcript all read as the same person.
struct AgentAvatar: View {
    let agent: Agent
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: agent.avatar.isEmpty ? "sparkles" : agent.avatar)
            .font(.system(size: size * 0.5))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Color(hex: agent.color.isEmpty ? "#8B5CF6" : agent.color))
            .clipShape(Circle())
    }
}

// MARK: - Group picker

/// "Pick 2 or more agents for a group chat."
///
/// Used inline on the welcome screen and in a sheet from the sidebar. A group chat belongs to the
/// active workspace like any other session, so the folder, project instructions and skills apply to
/// the whole room — the picker says which workspace it is starting in.
struct GroupPickerView: View {
    @ObservedObject var appState: AppState
    var onStart: ([String]) -> Void
    var onCancel: () -> Void

    /// In the order picked: that is the order the roster lists them in.
    @State private var selected: [String] = []

    private var theme: AppTheme { appState.settings.theme }
    private var accent: Color { ThemeColors.accent(for: appState.settings.accentColor) }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 3) {
                Text("Pick 2 or more agents for a group chat")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                Text("Starts in \(appState.currentWorkspace.name)")
                    .font(.system(size: 10.5))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
            }

            ScrollView {
                WrappingHStack(spacing: 8, lineSpacing: 8) {
                    ForEach(appState.agents) { agent in
                        chip(for: agent)
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 260)

            Text("Name an agent to have just that one act: \u{201C}@coder, plan the stack\u{201D}. Without a name, everyone answers in prose and nobody touches your files.")
                .font(.system(size: 10.5))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Start group chat") { onStart(selected) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(accent)
                    .disabled(selected.count < 2)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: 480)
        .background(ThemeColors.cardBg(for: theme))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(ThemeColors.border(for: theme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func chip(for agent: Agent) -> some View {
        let isOn = selected.contains(agent.id)
        return Button {
            if let at = selected.firstIndex(of: agent.id) {
                selected.remove(at: at)
            } else {
                selected.append(agent.id)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(isOn ? accent : ThemeColors.textSecondary(for: theme))
                AgentAvatar(agent: agent, size: 20)
                Text(agent.name)
                    .font(.system(size: 12.5))
                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(isOn ? accent.opacity(0.12) : Color.clear)
            .overlay(
                Capsule().stroke(isOn ? accent : ThemeColors.border(for: theme), lineWidth: 1)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.hitTestable)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The picker as a sheet, for the sidebar's "New group chat".
struct GroupPickerSheet: View {
    @ObservedObject var appState: AppState

    var body: some View {
        GroupPickerView(
            appState: appState,
            onStart: { ids in
                if appState.createGroupSession(participantIds: ids) != nil {
                    appState.isGroupPickerPresented = false
                }
            },
            onCancel: { appState.isGroupPickerPresented = false }
        )
        .padding(20)
        .frame(width: 520)
        .background(ThemeColors.bg(for: appState.settings.theme))
    }
}

// MARK: - Work with an agent

/// The welcome screen's "Choose an agent" grid, with "Start a group chat" beneath it.
///
/// Picking an agent puts that agent on the current (empty) chat; the composer's agent pill and the
/// header follow, and the user just types.
struct AgentChoiceGrid: View {
    @ObservedObject var appState: AppState
    var opensGroupPicker: Bool = false
    var onDone: () -> Void

    @State private var groupPickerOpen = false

    private var theme: AppTheme { appState.settings.theme }
    private var accent: Color { ThemeColors.accent(for: appState.settings.accentColor) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button(action: onDone) {
                    Label("Back", systemImage: "arrow.left")
                        .font(.system(size: 11.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                }
                .buttonStyle(.hitTestable)
                Text("Choose an agent")
                    .font(.system(size: 11.5))
                    .foregroundColor(ThemeColors.textSecondary(for: theme))
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(appState.agents) { agent in
                    card(for: agent)
                }
            }

            if appState.agents.count >= 2 {
                if groupPickerOpen {
                    GroupPickerView(
                        appState: appState,
                        onStart: { ids in
                            if appState.createGroupSession(participantIds: ids) != nil {
                                groupPickerOpen = false
                                onDone()
                            }
                        },
                        onCancel: { groupPickerOpen = false }
                    )
                } else {
                    Button {
                        groupPickerOpen = true
                    } label: {
                        Label("Start a group chat", systemImage: "person.2")
                            .font(.system(size: 12.5))
                            .foregroundColor(ThemeColors.textSecondary(for: theme))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .overlay(Capsule().stroke(ThemeColors.border(for: theme), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.hitTestable)
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: 640)
        .onAppear { groupPickerOpen = opensGroupPicker }
    }

    private func card(for agent: Agent) -> some View {
        let isCurrent = appState.currentSession?.isGroup != true && appState.selectedAgentId == agent.id
        return Button {
            appState.startChat(with: agent.id)
            appState.showToast("Chatting with \(agent.name)")
            onDone()
        } label: {
            HStack(spacing: 10) {
                AgentAvatar(agent: agent, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(ThemeColors.textPrimary(for: theme))
                        .lineLimit(1)
                    Text(agent.description.isEmpty ? agent.role : agent.description)
                        .font(.system(size: 10.5))
                        .foregroundColor(ThemeColors.textSecondary(for: theme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColors.cardBg(for: theme))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCurrent ? accent : ThemeColors.border(for: theme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.hitTestable)
        .help(agent.systemPrompt.isEmpty ? agent.name : String(agent.systemPrompt.prefix(240)))
    }
}

// MARK: - Roster

/// Who is in this group chat, under the chat header.
///
/// Tapping a name drops `@name` into the composer — the way to make one agent act. The
/// "others re-plan" switch is the room option: with it on, naming one agent has the rest revise
/// their own plans in light of it, instead of staying silent.
struct GroupRosterBar: View {
    @ObservedObject var appState: AppState
    let session: Session

    private var theme: AppTheme { appState.settings.theme }
    private var accent: Color { ThemeColors.accent(for: appState.settings.accentColor) }

    var body: some View {
        HStack(spacing: 6) {
            Label("Group", systemImage: "person.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(ThemeColors.textSecondary(for: theme))
                .padding(.trailing, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(appState.participants(of: session)) { agent in
                        Button {
                            let mention = "@\(GroupChat.slugName(agent.name)) "
                            let text = appState.composerText
                            appState.composerText = text.isEmpty || text.hasSuffix(" ") ? text + mention : text + " " + mention
                        } label: {
                            HStack(spacing: 5) {
                                AgentAvatar(agent: agent, size: 16)
                                Text(agent.name)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(ThemeColors.textPrimary(for: theme))
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 9)
                            .padding(.vertical, 2)
                            .background(ThemeColors.cardBg(for: theme))
                            .overlay(Capsule().stroke(ThemeColors.border(for: theme), lineWidth: 1))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.hitTestable)
                        .help("Type @\(GroupChat.slugName(agent.name)) to have \(agent.name) act on your next message")
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                appState.setGroupFollowUp(!session.groupFollowUp)
            } label: {
                Text(session.groupFollowUp ? "\u{2713} others re-plan" : "others re-plan")
                    .font(.system(size: 11))
                    .foregroundColor(session.groupFollowUp ? accent : ThemeColors.textSecondary(for: theme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(session.groupFollowUp ? accent : ThemeColors.border(for: theme), lineWidth: 1)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.hitTestable)
            .help("When you address one agent by name, the others update their own plans in light of it instead of staying silent. Same as typing @others yourself.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ThemeColors.sidebarBg(for: theme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ThemeColors.border(for: theme)).frame(height: 1)
        }
    }
}
