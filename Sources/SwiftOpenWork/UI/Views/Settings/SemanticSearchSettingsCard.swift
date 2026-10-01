import SwiftUI
import SwiftOpenWorkCore
import SwiftOpenWorkLocalInference

/// Turns on embedding-based search for `search_workspace` and fetches the small model it needs.
///
/// The download is a button, not a side effect of the toggle: nothing here pulls weights unasked.
struct SemanticSearchSettingsCard: View {
    @ObservedObject var appState: AppState
    @Binding var enabled: Bool
    @Binding var modelId: String
    @State private var isDownloaded = MLXEmbeddingService.shared.isDownloaded()
    @State private var progress: Double?
    @State private var status: String?

    var body: some View {
        SettingsCard(
            title: "Semantic Search",
            description: "Adds a small on-device embedding model to search_workspace, fused with keyword ranking, so “authentication” also finds code that only says “login”. Falls back to keyword search whenever the model is missing or still indexing.",
            icon: "magnifyingglass.circle"
        ) {
            SettingsRow(title: "Semantic Search", subtitle: isDownloaded ? "Model is on this Mac" : "Download the model below first", icon: "sparkle.magnifyingglass") {
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
            }

            SettingsRow(title: "Embedding Model", subtitle: "Hugging Face id. Small encoders such as bge-small (~65 MB) or nomic-embed-text keep memory free for the chat model", icon: "cube") {
                TextField("BAAI/bge-small-en-v1.5", text: $modelId)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { isDownloaded = MLXEmbeddingService.shared.isDownloaded() }
            }

            SettingsRow(title: "Download Model", subtitle: status, icon: "arrow.down.circle") {
                if let progress {
                    ProgressView(value: progress).frame(width: 140)
                } else {
                    Button(isDownloaded ? "Re-download" : "Download") { download() }
                }
            }
        }
    }

    private func download() {
        progress = 0
        status = nil
        Task {
            do {
                try await MLXEmbeddingService.shared.download { fraction, message in
                    Task { @MainActor in
                        progress = fraction
                        status = message
                    }
                }
                status = "Downloaded"
            } catch {
                status = "Download failed: \(error.localizedDescription)"
            }
            progress = nil
            isDownloaded = MLXEmbeddingService.shared.isDownloaded()
        }
    }
}
