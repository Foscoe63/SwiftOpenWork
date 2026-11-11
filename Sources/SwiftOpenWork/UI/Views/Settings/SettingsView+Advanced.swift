import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftOpenWorkCore
import SwiftOpenWorkStorage
import SwiftOpenWorkLocalInference
import SwiftOpenWorkEngine

// The Advanced page, with the Google integrations card.

extension SettingsView {
    // 5. Advanced
    var googleIntegrationsCard: some View {
        SettingsCard(
            title: "Google Integrations",
            description: "Sign in with Google to connect Gmail and Calendar. Client ID / secrets stay in the macOS Keychain.",
            icon: "envelope.badge.shield.half.filled"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if googleIsSignedIn {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(googleSignedInDisplay.isEmpty ? "Signed in to Google" : googleSignedInDisplay)
                                .font(.system(size: 12, weight: .semibold))
                            Text("Access tokens refresh automatically when they expire.")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(8)
                }

                SecureField("Google OAuth Client ID", text: $googleClientId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!googleCredentialsLoaded)
                    .font(.system(size: 12))
                    .onChange(of: googleClientId) { _, newValue in
                        GoogleIntegrationsService.shared.clientId = newValue
                    }

                SecureField("Google OAuth Client Secret", text: $googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!googleCredentialsLoaded)
                    .font(.system(size: 12))
                    .onChange(of: googleClientSecret) { _, newValue in
                        GoogleIntegrationsService.shared.clientSecret = newValue
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Authorized redirect URI (required)")
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        Text(GoogleIntegrationsService.authorizedRedirectURI)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(ThemeColors.sidebarBg(for: appState.settings.theme))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(ThemeColors.border(for: appState.settings.theme), lineWidth: 1)
                            )
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                GoogleIntegrationsService.authorizedRedirectURI,
                                forType: .string
                            )
                            googleConnectionStatus = "Copied redirect URI. Paste it into Google Cloud Console → Credentials → your OAuth client → Authorized redirect URIs."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("In Google Cloud Console, open your OAuth client and add that URI exactly (including the trailing slash). Prefer client type “Desktop app”; if you use “Web application”, this URI is required to avoid redirect_uri_mismatch.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isSigningInGoogle = true
                            googleConnectionStatus = ""
                            do {
                                googleConnectionStatus = try await GoogleIntegrationsService.shared.signInWithGoogle()
                                googleAccessToken = GoogleIntegrationsService.shared.accessToken
                                googleRefreshToken = GoogleIntegrationsService.shared.refreshToken
                                if !GoogleIntegrationsService.shared.signedInEmail.isEmpty {
                                    appState.settings.googleAccountEmail = GoogleIntegrationsService.shared.signedInEmail
                                    appState.updateSettings(appState.settings)
                                }
                                refreshGoogleSignedInState()
                            } catch is CancellationError {
                                googleConnectionStatus = "Sign-in cancelled."
                            } catch {
                                googleConnectionStatus = "Sign-in failed: \(error.localizedDescription)"
                            }
                            isSigningInGoogle = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSigningInGoogle {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                            }
                            Text(isSigningInGoogle ? "Waiting for browser…" : "Sign in with Google")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSigningInGoogle || !googleCredentialsLoaded || googleClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if googleIsSignedIn {
                        Button("Sign Out") {
                            GoogleIntegrationsService.shared.signOut()
                            googleAccessToken = ""
                            googleRefreshToken = ""
                            googleConnectionStatus = "Signed out of Google."
                            refreshGoogleSignedInState()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isSigningInGoogle)
                    }

                    Button {
                        Task {
                            isTestingGoogleConnection = true
                            googleConnectionStatus = await GoogleIntegrationsService.shared.testConnection()
                            isTestingGoogleConnection = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isTestingGoogleConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isTestingGoogleConnection ? "Testing…" : "Test Connection")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTestingGoogleConnection || isSigningInGoogle)
                }

                if !googleConnectionStatus.isEmpty {
                    Text(googleConnectionStatus)
                        .font(.system(size: 11))
                        .foregroundColor(googleConnectionStatus.hasPrefix("✅") ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Advanced credentials", isExpanded: $showGoogleAdvancedCredentials) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Google account email (optional)", text: Binding(
                            get: { appState.settings.googleAccountEmail },
                            set: { val in
                                appState.settings.googleAccountEmail = val
                                appState.updateSettings(appState.settings)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                        SecureField("Google API Key (optional)", text: $googleApiKey)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!googleCredentialsLoaded)
                            .font(.system(size: 12))
                            .onChange(of: googleApiKey) { _, newValue in
                                GoogleIntegrationsService.shared.apiKey = newValue
                            }

                        SecureField("Manual OAuth Access Token", text: $googleAccessToken)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!googleCredentialsLoaded)
                            .font(.system(size: 12))
                            .onChange(of: googleAccessToken) { _, newValue in
                                GoogleIntegrationsService.shared.accessToken = newValue
                            }

                        SecureField("Manual OAuth Refresh Token", text: $googleRefreshToken)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!googleCredentialsLoaded)
                            .font(.system(size: 12))
                            .onChange(of: googleRefreshToken) { _, newValue in
                                GoogleIntegrationsService.shared.refreshToken = newValue
                            }

                        Text("Prefer Sign in with Google. Manual tokens are only for debugging.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 11.5))

                Divider()

                SettingsRow(title: "Enable Gmail", subtitle: "Allow agents to list and search Gmail", icon: "envelope.fill") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.gmailExtensionEnabled },
                        set: { val in
                            appState.settings.gmailExtensionEnabled = val
                            appState.updateSettings(appState.settings)
                            syncGooglePlugin(id: "plugin-gmail", enabled: val)
                            syncGoogleTools(names: ["gmail_list", "gmail_search"], enabled: val)
                        }
                    ))
                    .toggleStyle(.switch)
                }

                SettingsRow(title: "Enable Google Calendar", subtitle: "Allow agents to list upcoming Google Calendar events", icon: "calendar") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.googleCalendarExtensionEnabled },
                        set: { val in
                            appState.settings.googleCalendarExtensionEnabled = val
                            appState.updateSettings(appState.settings)
                            syncGooglePlugin(id: "plugin-google-calendar", enabled: val)
                            syncGoogleTools(names: ["google_calendar_list", "google_calendar_upcoming"], enabled: val)
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }
            .task {
                // Off the main thread: a Keychain read can wait on an authorisation prompt.
                let loaded = await GoogleIntegrationsService.shared.loadCredentials()
                googleClientId = loaded.clientId
                googleClientSecret = loaded.clientSecret
                googleApiKey = loaded.apiKey
                googleAccessToken = loaded.accessToken
                googleRefreshToken = loaded.refreshToken
                googleCredentialsLoaded = true
                refreshGoogleSignedInState()
            }
        }
    }

    func refreshGoogleSignedInState() {
        let google = GoogleIntegrationsService.shared
        googleIsSignedIn = google.isSignedIn
        if !google.signedInName.isEmpty, !google.signedInEmail.isEmpty {
            googleSignedInDisplay = "Signed in as \(google.signedInName) <\(google.signedInEmail)>"
        } else if !google.signedInEmail.isEmpty {
            googleSignedInDisplay = "Signed in as \(google.signedInEmail)"
        } else if !appState.settings.googleAccountEmail.isEmpty, google.isSignedIn {
            googleSignedInDisplay = "Signed in as \(appState.settings.googleAccountEmail)"
        } else if google.isSignedIn {
            googleSignedInDisplay = "Signed in to Google"
        } else {
            googleSignedInDisplay = ""
        }
    }

    func syncGooglePlugin(id: String, enabled: Bool) {
        if let plugin = appState.plugins.first(where: { $0.id == id }) {
            var updated = plugin
            updated.isEnabled = enabled
            appState.savePlugin(updated)
        } else {
            let name = id == "plugin-gmail" ? "Gmail" : "Google Calendar"
            let description = id == "plugin-gmail"
                ? "Read and search Gmail via Google APIs."
                : "List upcoming Google Calendar events."
            let permissions = id == "plugin-gmail"
                ? ["network:outbound", "google:gmail.readonly"]
                : ["network:outbound", "google:calendar.readonly"]
            appState.savePlugin(AppExtensionPlugin(
                id: id,
                name: name,
                description: description,
                pluginType: .workspaceTool,
                source: .builtIn,
                isEnabled: enabled,
                permissions: permissions
            ))
        }
    }

    func syncGoogleTools(names: [String], enabled: Bool) {
        var tools = appState.tools
        var changed = false
        for name in names {
            if let idx = tools.firstIndex(where: { $0.name == name || $0.id == name }) {
                if tools[idx].isEnabled != enabled {
                    tools[idx].isEnabled = enabled
                    changed = true
                }
            }
        }
        if changed {
            appState.tools = tools
            PersistenceManager.shared.saveTools(tools)
        }
    }

    var advancedPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Autonomous ReAct Loop & Hierarchy", description: "Multi-agent hierarchy limits and deep ReAct execution cycles", icon: "point.3.connected.trianglepath.dotted") {
                SettingsRow(title: "Max Autonomous Iteration Loop (\(appState.settings.maxAutonomousIterations) turns)", subtitle: "Maximum iterative ReAct tool calls per agent turn (1 - 50)", icon: "arrow.triangle.2.circlepath") {
                    Stepper("", value: $appState.settings.maxAutonomousIterations, in: 1...50)
                }

                SettingsRow(title: "Sub-agent Step Budget (\(appState.settings.subAgentStepBudget) steps)", subtitle: "Rounds a delegated sub-agent gets before it must report back (1 - 50)", icon: "person.2.badge.gearshape") {
                    Stepper("", value: $appState.settings.subAgentStepBudget, in: 1...50)
                }

                SettingsRow(title: "Sub-agent Time Limit (\(appState.settings.subAgentTimeoutMinutes) min)", subtitle: "Working time a delegated sub-agent gets before it reports what it has; time queued for the local model is not counted (1 - 60 minutes)", icon: "timer") {
                    Stepper("", value: $appState.settings.subAgentTimeoutMinutes, in: 1...60)
                }

                SettingsRow(title: "Plan Mode", subtitle: "Block writes/shell/mutating MCP until exit_plan_mode (Radiant parity)", icon: "list.clipboard") {
                    Toggle("", isOn: $appState.settings.planModeEnabled)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Auto-Continue Until Done", subtitle: "When a turn stops with the todo list still open and no question asked, send Continue automatically instead of waiting for you to (stops after 4 in a row, 2 for external agents)", icon: "arrow.clockwise") {
                    Toggle("", isOn: $appState.settings.autoContinueUntilDone)
                        .toggleStyle(.switch)
                }
            }

            WorkspaceRulesCard(appState: appState)
            PermissionsAndHooksCard(appState: appState)
            ExternalAgentsCard(appState: appState)
            ClaudeUsageCard(appState: appState)
            LocalAPICard(
                appState: appState,
                enabled: $appState.settings.localAPIEnabled,
                port: $appState.settings.localAPIPort,
                exposeCloud: $appState.settings.localAPIExposeCloudModels
            )

            SettingsCard(title: "Autonomous ReAct Loop & Hierarchy (continued)", description: "Token budgets and multi-agent limits", icon: "gauge.with.dots.needle.67percent") {
                SettingsRow(title: "Limit Turn Tokens", subtitle: "Halt a single turn when its token use exceeds the budget. Turn off to let turns run without a cap", icon: "gauge.with.dots.needle.67percent") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.maxTurnTokens > 0 },
                        set: { appState.settings.maxTurnTokens = $0 ? 2_000_000 : 0 }
                    ))
                    .toggleStyle(.switch)
                }

                if appState.settings.maxTurnTokens > 0 {
                    SettingsRow(title: "Max Turn Tokens (\(appState.settings.maxTurnTokens / 1000)k)", subtitle: "Budget for a single turn. Lower it to stop a runaway turn sooner; for Claude Code it is counted cost-weighted (cache reads at a tenth)", icon: "gauge.with.dots.needle.67percent") {
                        Stepper("", value: $appState.settings.maxTurnTokens, in: 100_000...20_000_000, step: 100_000)
                    }
                }

                SettingsRow(title: "Limit Turn Spend", subtitle: "Halt a turn once its estimated cost passes this many US dollars, priced from the model's own rates. Local models are free, so this never stops them", icon: "dollarsign.circle") {
                    Toggle("", isOn: Binding(
                        get: { appState.settings.maxTurnCostUSD > 0 },
                        set: { appState.settings.maxTurnCostUSD = $0 ? 5 : 0 }
                    ))
                    .toggleStyle(.switch)
                }

                if appState.settings.maxTurnCostUSD > 0 {
                    SettingsRow(title: "Max Turn Spend ($\(String(format: "%.2f", appState.settings.maxTurnCostUSD)))", subtitle: "Budget for a single turn", icon: "dollarsign.circle") {
                        Stepper("", value: $appState.settings.maxTurnCostUSD, in: 0.25...200, step: 0.25)
                    }
                }

                SettingsRow(title: "Allow Sub-Agent Spawning", subtitle: "Enable lead agents to launch child agents", icon: "person.2.fill") {
                    Toggle("", isOn: $appState.settings.allowSubAgentCreation)
                        .toggleStyle(.switch)
                }

                SettingsRow(title: "Max Global Nesting Depth (\(appState.settings.maxGlobalSubAgentDepth))", subtitle: "Maximum chain of child agents", icon: "arrow.down.right.and.arrow.up.left") {
                    Stepper("", value: $appState.settings.maxGlobalSubAgentDepth, in: 1...5)
                }

                SettingsRow(title: "Multi-Agent Collaboration Room", subtitle: "Show the collaboration tab in AI Agents", icon: "bubble.left.and.exclamationmark.bubble.right.fill") {
                    Toggle("", isOn: $appState.settings.enableAgentCollaborationRoom)
                        .toggleStyle(.switch)
                }

                // The Agent Messages tab was always shown whatever this said.
                SettingsRow(title: "Agent Messages Inspector Tab", subtitle: "Show the inter-agent communication log", icon: "list.bullet.rectangle") {
                    Toggle("", isOn: $appState.settings.showInterAgentCommunicationLogs)
                        .toggleStyle(.switch)
                }
            }
        }
    }
}
