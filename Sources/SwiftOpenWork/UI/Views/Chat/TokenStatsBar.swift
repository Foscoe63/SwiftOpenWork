import SwiftUI
import SwiftOpenWorkCore

/// Prompt / Sent / Recv above the composer. Prompt is the box's estimate while typing, then the
/// last billed prompt; Sent and Recv are billed totals for the session. All three follow the
/// transcript and the draft, so they move while a reply streams.
public struct TokenStatsBar: View {
    @ObservedObject var appState: AppState

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        let billed = TokenAccounting.stats(for: appState.currentSession?.messages ?? [])
        let prompt = TokenAccounting.displayedPrompt(
            draft: appState.composerText,
            lastBilledPrompt: billed.lastPromptTokens
        )
        VStack(alignment: .leading, spacing: 6) {
            if billed.lastPromptTokens >= Self.contextWarningTokens {
                contextWarning(billed.lastPromptTokens)
            }
            HStack(spacing: 14) {
                stat("Prompt", prompt)
                stat("Sent", billed.sentTokens)
                stat("Recv", billed.receivedTokens)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .help("Prompt is this box (~4 characters per token) while you type, then the last billed prompt. Sent and Recv are billed tokens for this session.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Prompt \(TokenAccounting.grouped(prompt)) tokens, \(TokenAccounting.grouped(billed.sentTokens)) sent, \(TokenAccounting.grouped(billed.receivedTokens)) received"
        )
    }

    /// Past this, each step of a tool-using agent re-sends a very large context.
    static let contextWarningTokens = 100_000

    private func contextWarning(_ tokens: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text("This chat's context is \(TokenAccounting.grouped(tokens)) tokens, and every step re-sends it. A new chat will use your allowance much more slowly.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("New chat") {
                let agentId = appState.currentSession?.messages.last(where: { $0.role == .assistant })?.agentId
                appState.createNewSession(agentId: agentId)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        let secondary = ThemeColors.textSecondary(for: appState.settings.theme)
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(secondary.opacity(0.7))
            Text(TokenAccounting.grouped(value))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(secondary)
                .lineLimit(1)
        }
    }
}
