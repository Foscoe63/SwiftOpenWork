import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Reading, writing, searching and editing files.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let fileToolHandlers: [ToolRegistration] = [
        ToolRegistration(["file_read", "read_file"]) { await $0.fileReadTool($1) },
        ToolRegistration(["file_write", "write_file", "create_file", "save_file"]) { await $0.fileWriteTool($1) },
        ToolRegistration(["grep", "search_code", "code_search"]) { await $0.grepTool($1) },
        ToolRegistration(["glob", "find_files"]) { await $0.globTool($1) },
        ToolRegistration(["file_list", "list_files", "list_directory", "ls", "dir"]) { await $0.fileListTool($1) },
        ToolRegistration(["file_copy", "copy_file", "cp"]) { await $0.fileCopyTool($1) },
        ToolRegistration(["file_move", "move_file", "mv"]) { await $0.fileMoveTool($1) },
        ToolRegistration(["file_delete", "delete_file", "rm"]) { await $0.fileDeleteTool($1) },
        ToolRegistration(["edit_file", "file_edit"]) { await $0.editFileTool($1) },
        ToolRegistration(["multi_edit", "edit_file_multi"]) { await $0.multiEditTool($1) },
        ToolRegistration(["document_extract", "extract_document", "read_pdf_or_image"]) { await $0.documentExtractTool($1) },
        ToolRegistration(["document_create"]) { await $0.documentCreateTool($1) },
    ]

    func fileReadTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? (dict["filepath"] as? String) ?? (dict["file"] as? String) ?? ""
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let offset = Self.intArgument(dict["offset"]) ?? Self.intArgument(dict["start_line"])
        let limit = Self.intArgument(dict["limit"]) ?? Self.intArgument(dict["max_lines"])
        // A missing path with exactly one likely target inside the workspace is a slip, not a
        // question: a "Did you mean" hint was ignored and the same wrong path sent again,
        // burning a sub-agent's step budget. Read the one candidate and say so.
        if !FileManager.default.fileExists(atPath: (fullPath as NSString).expandingTildeInPath) {
            let nearby = Self.similarPaths(toMissing: fullPath, in: workspace.folderPath)
            if nearby.count == 1 {
                let rootPath = (workspace.folderPath as NSString).expandingTildeInPath
                let corrected = (rootPath as NSString).appendingPathComponent(nearby[0])
                var result = readFile(path: corrected, offset: offset, limit: limit, workspaceRoot: workspace.folderPath, startTime: startTime)
                if result.success {
                    result.output = "Note: '\(path)' does not exist; read '\(corrected)' instead. Use this full path from now on.\n" + result.output
                    return result
                }
            }
        }
        return readFile(path: fullPath, offset: offset, limit: limit, workspaceRoot: workspace.folderPath, startTime: startTime)
    }

    func fileWriteTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? (dict["filepath"] as? String) ?? (dict["file"] as? String) ?? (dict["title"] as? String) ?? ""
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "file_write requires a `path`. Nothing was written. Each call is independent — "
                    + "it does not remember the path or content from an earlier call this turn, so "
                    + "resend both. For a small correction to a file already written, use edit_file "
                    + "instead: it only needs the path and the exact text to replace.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        // A call with no `content` used to write an empty file — and a model whose output was
        // cut off mid-call sends exactly that — so it silently wiped whatever was there.
        // Missing is an error; an explicit empty string is a deliberate empty file.
        let rawContent = dict["content"] ?? dict["text"] ?? dict["body"] ?? dict["data"]
        let content: String
        switch rawContent {
        case let string as String:
            content = string
        case let object as [String: Any]:
            content = Self.prettyJSON(object) ?? ""
        case let array as [Any]:
            content = Self.prettyJSON(array) ?? ""
        case .some(let other) where !(other is NSNull):
            content = "\(other)"
        default:
            return ToolExecutionResult(
                success: false, output: "",
                error: "file_write requires `content` (the full file text); none was given, so nothing was written and '\(path)' is unchanged. This call does not remember content from an earlier call — resend the complete text. If the file is large, write it in smaller pieces, or use edit_file for a targeted change instead of a full rewrite.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        var writeIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: fullPath, isDirectory: &writeIsDirectory), writeIsDirectory.boolValue {
            return ToolExecutionResult(
                success: false, output: "",
                error: "file_write: '\(path)' is a directory. Give the path of the file to create inside it.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        await FileCheckpointStore.shared.record(path: fullPath)
        return writeFile(path: fullPath, content: content, startTime: startTime)
    }

    func grepTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let pattern = (dict["pattern"] as? String) ?? (dict["query"] as? String) ?? (dict["regex"] as? String) ?? ""
        guard !pattern.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "grep requires a `pattern` (a regular expression).",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let rawRoot = (dict["path"] as? String) ?? (dict["directory"] as? String) ?? workspace.folderPath
        let root = rawRoot.hasPrefix("/") ? rawRoot : (workspace.folderPath as NSString).appendingPathComponent(rawRoot)
        if let denial = sandboxDenial(for: root, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let include = (dict["include"] as? String) ?? (dict["glob"] as? String)
        let caseInsensitive = (dict["case_insensitive"] as? Bool) ?? (dict["ignore_case"] as? Bool) ?? false
        let grepLimit = Self.intArgument(dict["limit"]) ?? Self.intArgument(dict["max_results"]) ?? 100
        do {
            let result = try CodeSearch.grep(
                pattern: pattern,
                root: root,
                include: include,
                caseInsensitive: caseInsensitive,
                limit: grepLimit
            )
            return ToolExecutionResult(
                success: true,
                output: CodeSearch.format(result, pattern: pattern),
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false, output: "",
                error: "grep: invalid regular expression /\(pattern)/ — \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func globTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let pattern = (dict["pattern"] as? String) ?? (dict["glob"] as? String) ?? (dict["query"] as? String) ?? ""
        guard !pattern.isEmpty else {
            return ToolExecutionResult(
                success: false, output: "",
                error: "glob requires a `pattern`, for example `**/*.swift` or `Package.swift`.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let rawRoot = (dict["path"] as? String) ?? (dict["directory"] as? String) ?? workspace.folderPath
        let root = rawRoot.hasPrefix("/") ? rawRoot : (workspace.folderPath as NSString).appendingPathComponent(rawRoot)
        if let denial = sandboxDenial(for: root, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let globLimit = Self.intArgument(dict["limit"]) ?? 200
        let hits = CodeSearch.glob(pattern: pattern, root: root, limit: globLimit)
        if hits.paths.isEmpty {
            return ToolExecutionResult(
                success: true,
                output: "No files match `\(pattern)` under \(root) (\(hits.scanned) files scanned).",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        var body = hits.paths.joined(separator: "\n")
        if hits.truncated {
            body += "\n… more matches omitted; narrow the pattern or raise `limit`."
        }
        return ToolExecutionResult(
            success: true,
            output: body,
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func fileListTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["directory"] as? String) ?? (dict["folder"] as? String) ?? workspace.folderPath
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        // Every other read tool checks the sandbox; this one did not, so listing worked
        // anywhere on disk with the sandbox on.
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        return listDirectory(path: fullPath, startTime: startTime)
    }

    func fileCopyTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let from = (dict["source"] as? String) ?? (dict["from"] as? String) ?? (dict["path"] as? String) ?? ""
        let to = (dict["destination"] as? String) ?? (dict["to"] as? String) ?? (dict["target"] as? String) ?? ""
        let fullFrom = from.hasPrefix("/") ? from : (workspace.folderPath as NSString).appendingPathComponent(from)
        let fullTo = to.hasPrefix("/") ? to : (workspace.folderPath as NSString).appendingPathComponent(to)
        if let denial = sandboxDenial(for: fullFrom, workspace: workspace, settings: settings, startTime: startTime)
            ?? sandboxDenial(for: fullTo, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        if let problem = Self.transferProblem(tool: "file_copy", from: from, to: to, fullFrom: fullFrom, fullTo: fullTo) {
            return ToolExecutionResult(success: false, output: "", error: problem, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
        await FileCheckpointStore.shared.record(path: fullTo)
        do {
            let toDir = (fullTo as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: toDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fullTo) {
                try fileManager.removeItem(atPath: fullTo)
            }
            try fileManager.copyItem(atPath: fullFrom, toPath: fullTo)
            return ToolExecutionResult(
                success: true,
                output: "Successfully copied '\(from)' to '\(to)'",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to copy: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func fileMoveTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let from = (dict["source"] as? String) ?? (dict["from"] as? String) ?? (dict["path"] as? String) ?? ""
        let to = (dict["destination"] as? String) ?? (dict["to"] as? String) ?? (dict["target"] as? String) ?? ""
        let fullFrom = from.hasPrefix("/") ? from : (workspace.folderPath as NSString).appendingPathComponent(from)
        let fullTo = to.hasPrefix("/") ? to : (workspace.folderPath as NSString).appendingPathComponent(to)
        if let denial = sandboxDenial(for: fullFrom, workspace: workspace, settings: settings, startTime: startTime)
            ?? sandboxDenial(for: fullTo, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        // Checked before anything is touched: the destination used to be deleted first, so a
        // mistyped source destroyed the destination, and moving a file onto itself deleted it.
        if let problem = Self.transferProblem(tool: "file_move", from: from, to: to, fullFrom: fullFrom, fullTo: fullTo) {
            return ToolExecutionResult(success: false, output: "", error: problem, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        }
        await FileCheckpointStore.shared.record(path: fullFrom)
        await FileCheckpointStore.shared.record(path: fullTo)
        do {
            let toDir = (fullTo as NSString).deletingLastPathComponent
            try fileManager.createDirectory(atPath: toDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fullTo) {
                try fileManager.removeItem(atPath: fullTo)
            }
            try fileManager.moveItem(atPath: fullFrom, toPath: fullTo)
            return ToolExecutionResult(
                success: true,
                output: "Successfully moved '\(from)' to '\(to)'",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to move: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func fileDeleteTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? ""
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        // An empty or missing `path` resolves to the workspace folder itself, and `removeItem`
        // is recursive. Refuse anything that is the workspace root, a parent of it, or home.
        if let reason = Self.refusedDeleteTarget(fullPath, workspaceRoot: workspace.folderPath) {
            return ToolExecutionResult(
                success: false, output: "",
                error: "file_delete refused: \(reason) Name the specific file or folder to delete.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        await FileCheckpointStore.shared.record(path: fullPath)
        do {
            if fileManager.fileExists(atPath: fullPath) {
                try fileManager.removeItem(atPath: fullPath)
                return ToolExecutionResult(
                    success: true,
                    output: "Successfully deleted '\(path)'",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            } else {
                return ToolExecutionResult(
                    success: true,
                    output: "File '\(path)' does not exist.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Failed to delete: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func editFileTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? (dict["file"] as? String) ?? ""
        let oldString = (dict["old_string"] as? String) ?? (dict["oldString"] as? String) ?? ""
        let newString = (dict["new_string"] as? String) ?? (dict["newString"] as? String) ?? ""
        let replaceAll = (dict["replace_all"] as? Bool) ?? (dict["replaceAll"] as? Bool) ?? false
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        guard !oldString.isEmpty else {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "edit_file requires non-empty old_string",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        guard oldString != newString else {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "edit_file: old_string and new_string are identical, so nothing would change. Nothing was written.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        if let problem = editTargetProblem(tool: "edit_file", path: path, fullPath: fullPath, workspace: workspace, startTime: startTime) {
            return problem
        }
        do {
            let existing = try String(contentsOfFile: fullPath, encoding: .utf8)
            let count = existing.components(separatedBy: oldString).count - 1
            if count == 0 {
                // Exact text missing: retry ignoring whitespace/indent/line-ending drift.
                if let m = EditMatcher.fuzzyMatch(old: oldString, new: newString, in: existing) {
                    await FileCheckpointStore.shared.record(path: fullPath)
                    let updated = existing.replacingCharacters(in: m.range, with: m.replacement)
                    try updated.write(toFile: fullPath, atomically: true, encoding: .utf8)
                    return ToolExecutionResult(
                        success: true,
                        output: "Updated \(path) (1 replacement; old_string matched after ignoring whitespace differences).",
                        durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    )
                }
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "edit_file: old_string not found in \(path)." + EditMatcher.missHint(old: oldString, in: existing),
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            if !replaceAll && count > 1 {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "edit_file: old_string matched \(count) times; set replace_all=true or provide a more unique old_string",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
            await FileCheckpointStore.shared.record(path: fullPath)
            let updated: String
            if replaceAll {
                updated = existing.replacingOccurrences(of: oldString, with: newString)
            } else if let range = existing.range(of: oldString) {
                updated = existing.replacingCharacters(in: range, with: newString)
            } else {
                updated = existing
            }
            try updated.write(toFile: fullPath, atomically: true, encoding: .utf8)
            return ToolExecutionResult(
                success: true,
                output: replaceAll
                    ? "Updated \(path) (\(count) replacements)."
                    : "Updated \(path) (1 replacement).",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "edit_file failed: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func multiEditTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? (dict["file"] as? String) ?? ""
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        guard let edits = MultiEdit.parseEdits(from: dict) else {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "multi_edit requires `edits`: a list of {old_string, new_string, replace_all?} objects.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        if let problem = editTargetProblem(tool: "multi_edit", path: path, fullPath: fullPath, workspace: workspace, startTime: startTime) {
            return problem
        }
        do {
            let existing = try String(contentsOfFile: fullPath, encoding: .utf8)
            switch MultiEdit.apply(edits, to: existing) {
            case .failure(let failure):
                // Nothing has been written at this point, and the message says so — a model
                // told only "edit 3 failed" would have to guess whether 1 and 2 landed.
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: failure.message,
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            case .success(let applied):
                await FileCheckpointStore.shared.record(path: fullPath)
                try applied.contents.write(toFile: fullPath, atomically: true, encoding: .utf8)
                return ToolExecutionResult(
                    success: true,
                    output: "Updated \(path): \(edits.count) edit(s), \(applied.total) replacement(s).",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
        } catch {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "multi_edit failed: \(error.localizedDescription)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func documentExtractTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let rawPath = dict["path"] as? String ?? ""
        let fullPath = rawPath.hasPrefix("/") ? rawPath : (workspace.folderPath as NSString).appendingPathComponent(rawPath)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        let ext = (fullPath as NSString).pathExtension.lowercased()

        if ext == "pdf" {
            let (text, pages, err) = DocumentExtractionEngine.shared.extractTextFromPDF(at: fullPath)
            if let err = err {
                return ToolExecutionResult(success: false, output: "", error: err, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            }
            return ToolExecutionResult(
                success: true,
                output: "### Extracted \(pages) PDF pages from \(rawPath):\n\n\(text)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } else {
            let (text, err) = await DocumentExtractionEngine.shared.extractTextFromImage(at: fullPath)
            if let err = err {
                return ToolExecutionResult(success: false, output: "", error: err, durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            }
            return ToolExecutionResult(
                success: true,
                output: "### Vision OCR Recognized Text from \(rawPath):\n\n\(text)",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
    }

    func documentCreateTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let path = (dict["path"] as? String) ?? (dict["filename"] as? String) ?? ""
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty, let content = dict["content"] as? String else {
            return Self.failure("document_create needs `path` and `content`.", startTime)
        }
        guard let format = DocumentWriter.Format(path: path) else {
            return Self.failure("document_create writes \(DocumentWriter.Format.allCases.map { ".\($0.rawValue)" }.joined(separator: ", ")) files; '\(path)' has a different extension. Use file_write for plain text.", startTime)
        }
        let fullPath = path.hasPrefix("/") ? path : (workspace.folderPath as NSString).appendingPathComponent(path)
        if let denial = sandboxDenial(for: fullPath, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        await FileCheckpointStore.shared.record(path: fullPath)
        do {
            try await MainActor.run { try DocumentWriter.write(content: content, to: URL(fileURLWithPath: fullPath), format: format) }
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fullPath)[.size] as? Int) ?? 0
        return ToolExecutionResult(
            success: true, output: "Wrote \(path) (\(format.rawValue), \(size) bytes).",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }
}
