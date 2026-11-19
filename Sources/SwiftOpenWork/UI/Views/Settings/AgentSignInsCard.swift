import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Sign in to the coding agents the app uses — Claude Code under its CLI and Desktop logins, and
/// OpenCode — from one place. The agents are created on every Mac automatically; each Mac signs in
/// once, because sign-in tokens stay in that Mac's Keychain and are not synced.
public struct AgentSignInsCard: View {
    @ObservedObject var appState: AppState
    @State private var statuses: [String: AgentSignInStatus] = [:]
    @State private var checking = false
    @State private var message: String?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        SettingsCard(
            title: "Agent Sign-ins",
            description: "Claude Code (CLI), Claude Code (Desktop) and OpenCode each keep their own login. Sign in here; the browser step opens in Terminal. Sign-ins stay on this Mac, so on a new computer press Sign in once.",
            icon: "person.badge.key"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AgentSignInProfile.all) { profile in
                    row(profile)
                    if profile.id != AgentSignInProfile.all.last?.id { Divider() }
                }
                HStack {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(checking ? "Checking…" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small).disabled(checking)
                    Spacer()
                }
                if let message {
                    Text(message).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .task { await refresh() }
    }

    private func row(_ profile: AgentSignInProfile) -> some View {
        let status = statuses[profile.id]
        let present = profile.isPresent(in: appState.agents)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.system(size: 12.5, weight: .semibold))
                Text(profile.detail).font(.system(size: 10.5)).foregroundColor(.secondary)
                statusLabel(status)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    if case .signedIn = status {
                        Button("Sign out") { launch(profile, .logout) }
                    }
                    Button(isSignedIn(status) ? "Sign in again" : "Sign in") { launch(profile, .login) }
                        .buttonStyle(.borderedProminent)
                        .disabled(status == .notInstalled)
                }
                .controlSize(.small)
                if !present {
                    Button("Add agent") {
                        appState.saveAgent(profile.makeAgent())
                        message = "\(profile.name) added. Pick it from the agent menu in the composer."
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func isSignedIn(_ status: AgentSignInStatus?) -> Bool {
        if case .signedIn = status { return true }
        return false
    }

    @ViewBuilder
    private func statusLabel(_ status: AgentSignInStatus?) -> some View {
        switch status {
        case .none:
            Label("Checking…", systemImage: "hourglass").font(.system(size: 11)).foregroundColor(.secondary)
        case .notInstalled:
            Label("Not installed on this Mac", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundColor(.orange)
        case .signedOut:
            Label("Signed out", systemImage: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(.red)
        case let .signedIn(detail):
            Label(detail.map { "Signed in — \($0)" } ?? "Signed in", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundColor(.green)
        case let .unknown(reason):
            Label(reason, systemImage: "questionmark.circle.fill").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func launch(_ profile: AgentSignInProfile, _ action: AgentSignInProfile.Action) {
        do {
            let script = try AgentSignIn.terminalScript(for: profile, action: action)
            NSWorkspace.shared.open(script)
            message = "Terminal opened for \(profile.name). Finish there, then press Refresh."
        } catch {
            message = error.localizedDescription
        }
    }

    private func refresh() async {
        checking = true
        defer { checking = false }
        for profile in AgentSignInProfile.all {
            statuses[profile.id] = await AgentSignIn.status(for: profile)
        }
    }
}
