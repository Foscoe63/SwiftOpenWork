import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Builds, tests, language-server queries and code search.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let codeToolHandlers: [ToolRegistration] = [
        ToolRegistration(["build_project", "run_tests"]) { await $0.buildProjectTool($1) },
        ToolRegistration(["rename_symbol"]) { await $0.renameSymbolTool($1) },
        ToolRegistration(["go_to_definition", "find_references", "symbol_info", "call_hierarchy"]) { await $0.goToDefinitionTool($1) },
        ToolRegistration(["setup_xcode_language_server"]) { await $0.setupXcodeLanguageServerTool($1) },
        ToolRegistration(["code_diagnostics", "document_symbols"]) { await $0.codeDiagnosticsTool($1) },
        ToolRegistration(["find_symbol", "symbol_search"]) { await $0.findSymbolTool($1) },
        ToolRegistration(["workspace_semantic_search", "search_workspace"]) { await $0.workspaceSemanticSearchTool($1) },
    ]

    func buildProjectTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let toolName = call.toolName
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let callId = call.callId
        let action: BuildDiagnostics.Action = toolName == "run_tests" ? .test : .build
        let root = workspace.folderPath
        let explicit = (dict["command"] as? String)?.trimmingCharacters(in: .whitespaces)
        let kinds = WorkspaceContext.detectProjectKinds(at: root)
        guard let command = (explicit?.isEmpty == false ? explicit : nil)
            ?? BuildDiagnostics.command(forProjectKinds: kinds, action: action, at: root) else {
            let detected = kinds.isEmpty ? "none detected" : kinds.joined(separator: ", ")
            return ToolExecutionResult(
                success: false, output: "",
                error: "Cannot infer a \(action.rawValue) command for this project (\(detected)). "
                    + "Pass `command` explicitly, or use terminal_command.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        // Narrowing to last run's failures is the tight loop when fixing a test. It has to
        // announce when it could not narrow: a run that quietly widened back to the whole
        // suite, or quietly matched nothing, both read as the requested run having happened.
        var effectiveCommand = command
        var narrowingNote: String?
        let wantsOnlyFailing = (dict["only_failing"] as? Bool)
            ?? (dict["onlyFailing"] as? Bool)
            ?? (dict["failed_only"] as? Bool)
            ?? false
        if action == .test && wantsOnlyFailing {
            let remembered = await LastTestFailures.shared.failures(for: root)
            if remembered.isEmpty {
                narrowingNote = "No failures were recorded from a previous run, so the whole suite ran."
            } else if let narrowed = BuildDiagnostics.rerunCommand(baseCommand: command, failures: remembered) {
                effectiveCommand = narrowed
                narrowingNote = "Ran only the \(remembered.count) test(s) that failed last time."
            } else {
                narrowingNote = "This runner cannot be narrowed safely, so the whole suite ran."
            }
        }

        let run = await runProcess(command: effectiveCommand, cwd: root, timeoutSeconds: 600, callId: callId)
        var summary = BuildDiagnostics.summarize(
            command: effectiveCommand,
            exitCode: run.exitCode,
            output: run.output,
            root: root
        )
        if let narrowingNote {
            summary = "\(narrowingNote)\n\(summary)"
        }
        if action == .test {
            let failures = BuildDiagnostics.failedTests(in: run.output)
            // Only a full run can clear the list; a narrowed green run says nothing about the
            // tests it did not execute.
            if !failures.isEmpty || effectiveCommand == command {
                await LastTestFailures.shared.record(failures, for: root)
            }
        }
        return ToolExecutionResult(
            success: run.exitCode == 0,
            output: summary,
            error: run.exitCode == 0 ? nil : summary,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func renameSymbolTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let callId = call.callId
        let oldName = (dict["old_name"] as? String) ?? (dict["from"] as? String) ?? ""
        let newName = (dict["new_name"] as? String) ?? (dict["to"] as? String) ?? ""
        let pathHint = (dict["path"] as? String) ?? (dict["file"] as? String)
        let dryRun = (dict["dry_run"] as? Bool) ?? false
        let mode = (dict["mode"] as? String).flatMap(SymbolRename.Mode.init(rawValue:)) ?? .auto
        let declarationLine = Self.intArgument(dict["line"])
        defer { if let callId { LiveToolOutput.conclude(noteFor: callId) } }
        do {
            let outcome = try await SymbolRename.rename(
                oldName: oldName,
                newName: newName,
                root: workspace.folderPath,
                pathHint: pathHint,
                dryRun: dryRun,
                mode: mode,
                declarationLine: declarationLine,
                onProgress: Self.languageServerProgress(callId: callId)
            )
            return ToolExecutionResult(
                success: true,
                output: outcome.summary,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000,
                fileDiffs: outcome.diffs.isEmpty ? nil : InlineFileDiff.boundedSet(outcome.diffs)
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: error.localizedDescription,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func goToDefinitionTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let toolName = call.toolName
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let callId = call.callId
        let target: CodeIntelligence.Target
        switch Self.codeTarget(from: dict, toolName: toolName) {
        case .success(let value): target = value
        case .failure(let message):
            return ToolExecutionResult(success: false, output: "", error: message.text,
                                       durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
        let absolute = CodeIntelligence.absolutePath(target.path, workspaceRoot: workspace.folderPath)
        if let denial = sandboxDenial(for: absolute, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let limit = Self.intArgument(dict["limit"])
        let progress = Self.languageServerProgress(callId: callId)
        defer { if let callId { LiveToolOutput.conclude(noteFor: callId) } }
        do {
            let output: String
            switch toolName {
            case "go_to_definition":
                let kind = (dict["kind"] as? String).flatMap(CodeIntelligence.DefinitionKind.init(rawValue:)) ?? .definition
                output = try await CodeIntelligence.definition(target, kind: kind, workspaceRoot: workspace.folderPath, onProgress: progress)
            case "find_references":
                output = try await CodeIntelligence.references(
                    target, includeDeclaration: (dict["include_declaration"] as? Bool) ?? true,
                    limit: min(limit ?? 200, 1000), workspaceRoot: workspace.folderPath, onProgress: progress
                )
            case "symbol_info":
                output = try await CodeIntelligence.symbolInfo(target, workspaceRoot: workspace.folderPath, onProgress: progress)
            default:
                let direction = (dict["direction"] as? String).flatMap(CodeIntelligence.CallDirection.init(rawValue:)) ?? .incoming
                output = try await CodeIntelligence.callHierarchy(
                    target, direction: direction, limit: min(limit ?? 100, 1000), workspaceRoot: workspace.folderPath, onProgress: progress
                )
            }
            return ToolExecutionResult(success: true, output: output,
                                       durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        } catch {
            return ToolExecutionResult(success: false, output: "", error: error.localizedDescription,
                                       durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
    }

    func setupXcodeLanguageServerTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let callId = call.callId
        return await setUpXcodeLanguageServer(dict: dict, workspace: workspace, settings: settings, startTime: startTime, callId: callId)
    }

    func codeDiagnosticsTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let toolName = call.toolName
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let callId = call.callId
        guard let path = ((dict["path"] as? String) ?? (dict["file"] as? String)), !path.isEmpty else {
            return ToolExecutionResult(success: false, output: "", error: "\(toolName) requires `path` — the file to examine.",
                                       durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
        let absolute = CodeIntelligence.absolutePath(path, workspaceRoot: workspace.folderPath)
        if let denial = sandboxDenial(for: absolute, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let progress = Self.languageServerProgress(callId: callId)
        defer { if let callId { LiveToolOutput.conclude(noteFor: callId) } }
        do {
            let output = toolName == "code_diagnostics"
                ? try await CodeIntelligence.diagnostics(path: absolute, workspaceRoot: workspace.folderPath, onProgress: progress)
                : try await CodeIntelligence.documentSymbols(path: absolute, workspaceRoot: workspace.folderPath)
            return ToolExecutionResult(success: true, output: output,
                                       durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        } catch {
            return ToolExecutionResult(success: false, output: "", error: error.localizedDescription,
                                       durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
    }

    func findSymbolTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let name = (dict["name"] as? String) ?? (dict["symbol"] as? String) ?? (dict["query"] as? String) ?? ""
        guard !name.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "find_symbol requires a `name` — the symbol to locate.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let symbolRootRaw = (dict["path"] as? String) ?? (dict["directory"] as? String) ?? workspace.folderPath
        let symbolRoot = symbolRootRaw.hasPrefix("/")
            ? symbolRootRaw
            : (workspace.folderPath as NSString).appendingPathComponent(symbolRootRaw)
        if let denial = sandboxDenial(for: symbolRoot, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let symbolLimit = Self.intArgument(dict["limit"]) ?? Self.intArgument(dict["max_results"]) ?? 20
        let symbols = await SymbolIndex.shared.lookup(name: name, root: symbolRoot, limit: symbolLimit)
        return ToolExecutionResult(
            success: true,
            output: SymbolIndex.format(symbols, name: name),
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func workspaceSemanticSearchTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let query = dict["query"] as? String ?? ""
        guard !query.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "search_workspace requires a `query`.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let topK = Self.intArgument(dict["top_k"]) ?? Self.intArgument(dict["limit"]) ?? 6
        let (hits, note) = await CodeIndex.shared.searchWithStatus(query: query, root: workspace.folderPath, topK: topK)
        return ToolExecutionResult(
            success: true,
            output: CodeIndex.format(hits, query: query) + (note.map { "\n\n(\($0))" } ?? ""),
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }
}
