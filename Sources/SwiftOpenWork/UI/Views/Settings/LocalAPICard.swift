import SwiftUI
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkEngine

/// Turn the loaded model into an OpenAI/Anthropic-compatible endpoint other tools can use.
public struct LocalAPICard: View {
    @ObservedObject var appState: AppState
    @Binding var enabled: Bool
    @Binding var port: Int
    @Binding var exposeCloud: Bool
    @State private var token = ""
    @State private var revealed = false
    @State private var copied: String?

    public init(appState: AppState, enabled: Binding<Bool>, port: Binding<Int>, exposeCloud: Binding<Bool>) {
        self.appState = appState
        self._enabled = enabled
        self._port = port
        self._exposeCloud = exposeCloud
    }

    private var base: String { "http://127.0.0.1:\(port)" }

    public var body: some View {
        SettingsCard(
            title: "Local Model API",
            description: "Let Claude Code, Codex, OpenCode, Cline or a script use the model loaded here, through the OpenAI or Anthropic API. It shares the one resident model with your chats instead of loading another copy.",
            icon: "network"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(title: "Serve the local API", subtitle: "Listens on 127.0.0.1 only, and every request needs the key below. Browsers are refused.", icon: "power") {
                    Toggle("", isOn: $enabled).toggleStyle(.switch)
                }
                SettingsRow(title: "Port", subtitle: "1024 or higher", icon: "number") {
                    TextField("", value: $port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                SettingsRow(title: "Also offer cloud models", subtitle: "Off: only models that run on this Mac or a server you run. On: the key can spend your cloud API credits.", icon: "cloud") {
                    Toggle("", isOn: $exposeCloud).toggleStyle(.switch)
                }

                if enabled {
                    if let status = appState.localAPIStatus {
                        Text(status).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("API key").font(.system(size: 12, weight: .semibold))
                        Text(revealed ? token : String(repeating: "•", count: 20))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                        Spacer()
                        Button(revealed ? "Hide" : "Show") { revealed.toggle() }
                        Button("Copy") { copy(token, label: "Key") }
                        Button("New key") {
                            token = LocalAPIServer.regenerateToken()
                            appState.applyLocalAPISettings()
                        }
                    }
                    .controlSize(.small)

                    Text("Use it").font(.system(size: 12, weight: .semibold))
                    snippet("OpenAI-compatible (Codex, OpenCode, Cline, scripts)", "export OPENAI_BASE_URL=\(base)/v1\nexport OPENAI_API_KEY=<key>")
                    snippet("Anthropic-compatible (Claude Code)", "export ANTHROPIC_BASE_URL=\(base)\nexport ANTHROPIC_AUTH_TOKEN=<key>")
                    if let copied { Text("Copied \(copied).").font(.system(size: 10.5)).foregroundColor(.secondary) }
                }
            }
            .onAppear { if token.isEmpty { token = LocalAPIServer.currentToken() } }
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer()
                Button("Copy") { copy(text.replacingOccurrences(of: "<key>", with: token), label: title) }.controlSize(.small)
            }
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1)).cornerRadius(6)
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = label
    }
}
