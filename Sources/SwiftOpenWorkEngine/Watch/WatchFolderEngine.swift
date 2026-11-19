import Foundation
import Combine
import SwiftOpenWorkCore

@MainActor
public final class WatchFolderEngine: ObservableObject {
    public static let shared = WatchFolderEngine()

    private var fileMonitors: [String: DispatchSourceFileSystemObject] = [:]
    private var fileDescriptors: [String: Int32] = [:]
    private var debounceTimers: [String: Timer] = [:]

    private init() {}

    /// Built outside the main actor on purpose: a closure made inside this class inherits `@MainActor`,
    /// and the dispatch source runs it on a utility queue, which traps the isolation check.
    nonisolated private static func closer(for descriptor: Int32) -> @Sendable () -> Void {
        { close(descriptor) }
    }

    public func startWatching(items: [WatchItem], onEventTriggered: @escaping @MainActor (WatchItem, String) -> Void) {
        stopAll()

        for item in items where item.isEnabled && !item.path.isEmpty {
            let path = item.path
            let fm = FileManager.default

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                continue
            }

            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else {
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .link, .rename],
                queue: DispatchQueue.global(qos: .utility)
            )

            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.handleDirectoryEvent(for: item, onEventTriggered: onEventTriggered)
                }
            }

            source.setCancelHandler(handler: Self.closer(for: descriptor))

            source.resume()
            fileMonitors[item.id] = source
            fileDescriptors[item.id] = descriptor
        }
    }

    private func handleDirectoryEvent(for item: WatchItem, onEventTriggered: @escaping @MainActor (WatchItem, String) -> Void) {
        debounceTimers[item.id]?.invalidate()

        debounceTimers[item.id] = Timer.scheduledTimer(withTimeInterval: max(1.0, item.debounceIntervalSeconds), repeats: false) { _ in
            Task { @MainActor in
                let summary = "Detected filesystem changes in \( (item.path as NSString).lastPathComponent )"
                onEventTriggered(item, summary)
            }
        }
    }

    public func triggerManualScan(
        item: WatchItem,
        workspace: Workspace,
        agent: Agent,
        provider: ModelProvider,
        model: ModelInfo,
        onArtifactCreated: @escaping (AutomationArtifact) -> Void
    ) async {
        let fm = FileManager.default
        let path = item.path.isEmpty ? workspace.folderPath : item.path

        // Collect list of changed / current files in the watched target
        var filesFound: [String] = []
        if let enumerator = fm.enumerator(atPath: path) {
            var count = 0
            while let file = enumerator.nextObject() as? String, count < 25 {
                if file.hasPrefix(".") || file.contains("/.") { continue }
                let ext = (file as NSString).pathExtension.lowercased()
                if item.fileExtensionsFilter.contains("*") || item.fileExtensionsFilter.contains(ext) {
                    filesFound.append(file)
                    count += 1
                }
            }
        }

        let fileListSnippet = filesFound.isEmpty ? "(No files matching filter in \(path))" : filesFound.joined(separator: "\n- ")
        let promptToExecute = """
        \(item.customPrompt)

        === WATCH ITEM CONTEXT ===
        Target Name: \(item.name)
        Monitored Path: \(path)
        Template Mode: \(item.artifactTemplate.displayName)
        Current Detected Files:
        - \(fileListSnippet)

        Please generate a complete, rich \(item.artifactTemplate.displayName) artifact. Format as clear, elegant Markdown with emojis, sections, deliverables, and actionable takeaways.
        """

        let subAccumulator = SubAgentAccumulator()
        var failureReason: String?

        do {
            try await ProviderRouter.shared.stream(
                provider: provider,
                model: model,
                systemPrompt: agent.systemPrompt,
                messages: [
                    ChatMessage(sessionId: "watch-automation", role: .user, content: promptToExecute)
                ],
                temperature: agent.temperature,
                maxTokens: 2048,
                reasoningEffort: .off,
                tools: []
            ) { chunk in
                Task { @MainActor in
                    if !chunk.deltaText.isEmpty {
                        subAccumulator.append(chunk.deltaText)
                    }
                }
            }
        } catch {
            // Say the run failed. This used to write "All monitored items verified. No syntax
            // regressions or permission errors detected." into the artifact whenever the provider
            // threw — a finding nothing had checked, filed under the agent's name, in the place
            // the user goes to read what the agent found. A fabricated clean bill of health is
            // worse than an empty one.
            failureReason = error.localizedDescription
        }

        let generated = subAccumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let synthesizedContent: String
        if let failureReason {
            synthesizedContent = """
            # ⚠️ \(item.name) — run failed
            *\(Date().formatted())*

            The agent could not produce this artifact.

            **Reason:** \(failureReason)

            ### Monitored target
            `\(path)`

            ### Files that would have been examined
            - \(fileListSnippet)
            """
        } else if generated.isEmpty {
            synthesizedContent = """
            # ⚠️ \(item.name) — no content produced
            *\(Date().formatted())*

            The model returned nothing for this run. Nothing was analysed.

            ### Monitored target
            `\(path)`

            ### Files that would have been examined
            - \(fileListSnippet)
            """
        } else {
            synthesizedContent = generated
        }

        let title = "\(item.name) - \(Date().formatted(date: .abbreviated, time: .shortened))"
        let subtitle = failureReason == nil
            ? "\(item.artifactTemplate.displayName) via \(agent.name)"
            : "Failed — \(agent.name) could not complete this run"

        // Determine category
        let category: ArtifactCategory
        switch item.artifactTemplate {
        case .morningBrief: category = .brief
        case .dailyUpdate: category = .digest
        case .codeReviewDigest: category = .code
        case .documentSummary: category = .document
        case .fileProcessingPipeline: category = .report
        case .customPrompt: category = .report
        }

        // Save to workspace output folder if pipeline staging or output is configured
        var savedFilePath: String? = nil
        let outputDir = (workspace.folderPath as NSString).appendingPathComponent(item.outputDestination.isEmpty ? "output" : item.outputDestination)
        if !fm.fileExists(atPath: outputDir) {
            try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        }

        let safeFilename = "\(item.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(Int(Date().timeIntervalSince1970)).md"
        let fullOutputPath = (outputDir as NSString).appendingPathComponent(safeFilename)
        if (try? synthesizedContent.write(toFile: fullOutputPath, atomically: true, encoding: .utf8)) != nil {
            savedFilePath = fullOutputPath
        }

        let artifact = AutomationArtifact(
            workspaceId: workspace.id,
            watchItemId: item.id,
            agentId: agent.id,
            agentName: agent.name,
            title: title,
            subtitle: subtitle,
            category: category,
            content: synthesizedContent,
            format: "markdown",
            filePath: savedFilePath,
            sourceTrigger: "Watch Folder: \(item.name)"
        )

        onArtifactCreated(artifact)
    }

    public func stopAll() {
        for (_, source) in fileMonitors {
            source.cancel()
        }
        fileMonitors.removeAll()
        fileDescriptors.removeAll()
        for (_, timer) in debounceTimers {
            timer.invalidate()
        }
        debounceTimers.removeAll()
    }
}
