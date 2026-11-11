import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Image generation, vision, screenshots and accessibility trees.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let perceptionToolHandlers: [ToolRegistration] = [
        ToolRegistration(["generate_image"]) { await $0.generateImageTool($1) },
        ToolRegistration(["mlx_vision_describe", "image_analyze"]) { await $0.mlxVisionDescribeTool($1) },
        ToolRegistration(["screenshot_window", "screenshot_app"]) { await $0.screenshotWindowTool($1) },
        ToolRegistration(["accessibility_tree", "ui_tree", "inspect_window"]) { await $0.accessibilityTreeTool($1) },
    ]

    func generateImageTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let startTime = call.startTime
        // Removed, deliberately, rather than left working-looking.
        //
        // This used to write a fixed SVG — a gradient, a circle, a square, a triangle — with
        // the prompt truncated to 60 characters stamped underneath as a caption, then return
        // `success: true` and "Generative Media Created". Nothing about the output depended on
        // the prompt beyond that caption. A model asked to draw a chart got the same circle
        // every time, was told it had worked, and told the user it had worked.
        //
        // There is no local image generator in this app to route it to. The honest tool is the
        // one the agent already has: write the SVG itself with `file_write`, where the output
        // actually reflects what was asked for. The case is kept so that an agent carrying the
        // old tool in its saved list is told where to go rather than getting "unknown tool".
        return ToolExecutionResult(
            success: false,
            output: "",
            error: """
            generate_image was removed — it never generated anything from the prompt. \
            Write the image yourself instead: compose the SVG (or Markdown, or HTML) and save \
            it with file_write.
            """,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func mlxVisionDescribeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let toolName = call.toolName
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        // Two tools, two honest jobs.
        //
        // Both used to run the same Apple Vision OCR pass and return it under the heading
        // "MLX Vision & Apple Neural Analysis", behind a tool described as analysing images
        // "using local MLX vision models". No vision model was involved, the `prompt`
        // parameter in the schema was never read, and an image with no text came back as
        // "Image verified. No embedded text detected" — which a model reads as success.
        //
        // Now `mlx_vision_describe` actually describes, by sending the image to the loaded
        // model down the same path a chat attachment takes, so it works exactly where vision
        // works. `image_analyze` stays OCR, and says so in its name and description.
        let rawPath = dict["path"] as? String ?? ""
        guard !rawPath.isEmpty else {
            return Self.failure("\(toolName) needs a 'path' to an image file.", startTime)
        }
        let fullPath = rawPath.hasPrefix("/") ? rawPath : (workspace.folderPath as NSString).appendingPathComponent(rawPath)
        // Reads a file like `file_read` does, so it answers to the same sandbox.
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        guard fileManager.fileExists(atPath: fullPath) else {
            return Self.failure("No file at \(rawPath).", startTime)
        }

        let wantsDescription = toolName == "mlx_vision_describe"
        let prompt = (dict["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if wantsDescription {
            let current = await MainActor.run {
                EngineHosting.host.map { ($0.currentProvider, $0.currentModel) }
            }
            if let (provider, model) = current, model.supportsVision {
                let question = prompt.isEmpty
                    ? "Describe this image. Say what it shows, its layout, and any text in it."
                    : prompt
                let attachment = MessageAttachment(
                    name: (fullPath as NSString).lastPathComponent,
                    path: fullPath,
                    sizeBytes: ImageTransport.fileSize(atPath: fullPath),
                    mimeType: Self.imageMimeType(forPath: fullPath)
                )
                let accumulator = StreamTextAccumulator()
                do {
                    try await ProviderRouter.shared.stream(
                        provider: provider,
                        model: model,
                        systemPrompt: "You are looking at an image. Answer only about what you can see in it.",
                        messages: [ChatMessage(
                            sessionId: "vision-tool",
                            role: .user,
                            content: question,
                            attachments: [attachment]
                        )],
                        temperature: 0.2,
                        maxTokens: 1024,
                        reasoningEffort: .off,
                        tools: []
                    ) { chunk in
                        if !chunk.deltaText.isEmpty { accumulator.append(chunk.deltaText) }
                    }
                } catch {
                    // Do not quietly fall back to OCR and present it as a description. The
                    // caller asked what the image shows; answering with something else under
                    // the same heading is the fault this tool had in the first place.
                    return Self.failure(
                        "\(model.name) could not describe the image: \(error.localizedDescription). "
                            + "Use image_analyze to read any text in it instead.",
                        startTime
                    )
                }
                let described = accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !described.isEmpty else {
                    return Self.failure("\(model.name) returned nothing for this image.", startTime)
                }
                return ToolExecutionResult(
                    success: true,
                    output: "Description of `\(rawPath)` by \(model.name):\n\n\(described)",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
        }

        // OCR path: `image_analyze` always, and `mlx_vision_describe` when the loaded model
        // cannot see. Labelled as text extraction, never as a description, and an image with
        // no text is reported as "no text found" rather than as a successful analysis.
        let (ocrText, ocrErr) = await DocumentExtractionEngine.shared.extractTextFromImage(at: fullPath)
        if let ocrErr {
            return Self.failure("Could not read text from \(rawPath): \(ocrErr)", startTime)
        }
        let blindNote = wantsDescription
            ? "\n\nThis is OCR text, not a description — the loaded model cannot see images. "
                + "Load a vision model to have the image described."
            : ""
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolExecutionResult(
                success: true,
                output: "No text found in `\(rawPath)`. Nothing is known about what it depicts.\(blindNote)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        return ToolExecutionResult(
            success: true,
            output: "Text read from `\(rawPath)`:\n```\n\(ocrText)\n```\(blindNote)",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func screenshotWindowTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let appQuery = (dict["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !appQuery.isEmpty else {
            return Self.failure("screenshot_window needs an 'app' — a bundle id or app name.", startTime)
        }
        do {
            let dir = Self.perceptionDirectory(for: workspace)
            let url = try await ScreenPerception.captureWindow(appQuery: appQuery, to: dir)
            let size = ImageTransport.fileSize(atPath: url.path)
            return ToolExecutionResult(
                success: true,
                output: """
                Captured the frontmost window of '\(appQuery)'.
                File: \(url.path) (\(size / 1024) KB)
                The image is attached to this result — look at it rather than reasoning about the path.
                """,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                producedImages: [url.path]
            )
        } catch {
            let running = ScreenPerception.runningApplicationNames().prefix(25).joined(separator: ", ")
            return Self.failure(
                "\(error.localizedDescription)\n\nRunning apps: \(running)",
                startTime
            )
        }
    }

    func accessibilityTreeTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        let appQuery = (dict["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !appQuery.isEmpty else {
            return Self.failure("accessibility_tree needs an 'app' — a bundle id or app name.", startTime)
        }
        let maxDepth = dict["max_depth"] as? Int ?? 14
        do {
            let tree = try ScreenPerception.accessibilityTree(appQuery: appQuery, maxDepth: maxDepth)
            return ToolExecutionResult(
                success: true,
                output: tree,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            let running = ScreenPerception.runningApplicationNames().prefix(25).joined(separator: ", ")
            return Self.failure(
                "\(error.localizedDescription)\n\nRunning apps: \(running)",
                startTime
            )
        }
    }
}
