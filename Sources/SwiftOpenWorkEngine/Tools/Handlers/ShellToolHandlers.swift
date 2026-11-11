import Foundation
import AppKit
import SwiftOpenWorkCore
import SwiftOpenWorkStorage

// Shell commands, interactive input, launching apps and preview servers.
//
// Each handler is the body of what used to be one `case` in `performExecute`'s switch.
// `ToolHandlerRegistry` maps every tool name and alias to its handler.

extension ToolExecutionEngine {
    static let shellToolHandlers: [ToolRegistration] = [
        ToolRegistration(["terminal_command", "run_command"]) { await $0.terminalCommandTool($1) },
        ToolRegistration(["send_input"]) { await $0.sendInputTool($1) },
        ToolRegistration(["quit_app"]) { await $0.quitAppTool($1) },
        ToolRegistration(["run_app", "launch_app"]) { await $0.runAppTool($1) },
        ToolRegistration(["preview_start"]) { await $0.previewStartTool($1) },
        ToolRegistration(["preview_check"]) { await $0.previewCheckTool($1) },
        ToolRegistration(["preview_logs"]) { await $0.previewLogsTool($1) },
        ToolRegistration(["preview_stop"]) { await $0.previewStopTool($1) },
    ]

    func terminalCommandTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let toolName = call.toolName
        let dict = call.dict
        let argumentsJson = call.argumentsJson
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let callId = call.callId
        let command = dict["command"] as? String ?? ""
        let cwd = dict["cwd"] as? String ?? workspace.folderPath
        // The shell was gated by command allowlist only, never by path: under
        // `.allowAll` a redirect could write anywhere, and `cwd` was never checked at all.
        // File tools have always been contained; this closes the way around them.
        if let denial = sandboxDenial(for: cwd, workspace: workspace, settings: settings, startTime: startTime) {
            return denial
        }
        if settings.sandboxAgentFileSystem,
           let escape = Self.shellWriteTargetOutsideSandbox(
               command: command, workspace: workspace, settings: settings
           ) {
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Blocked by Sandbox Agent File System: this command writes to '\(escape)', "
                    + "which is outside the workspace and authorized folders. Add it under "
                    + "Settings → Advanced → Authorized Workspace Directories, or disable sandboxing.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        switch settings.terminalSafetyLevel {
        case .allowAll, .allowEverything:
            break
        case .safeOnly:
            if !ToolExecutionEngine.isSafeReadOnlyCommand(command) {
                return ToolExecutionResult(
                    success: false,
                    output: "",
                    error: "Blocked by Terminal Safety Level (\"Allow Safe Read-Only Commands\"): '\(command)' is not on the read-only allowlist. Switch to \"Always Ask\" or \"Unrestricted\" under Settings → Advanced to run it.",
                    durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                )
            }
        case .alwaysAsk:
            // The agent loop must obtain interactive user approval before a call reaches
            // execute() under this policy; treat one that arrives here anyway as unapproved.
            // A standing "allow" rule is a decision already taken, so it counts.
            if ApprovedCalls.consume(callId)
                || PermissionRules.verdict(toolName: toolName, argumentsJson: argumentsJson, workspaceRoot: workspace.folderPath)?.action == .allow {
                break
            }
            return ToolExecutionResult(
                success: false,
                output: "",
                error: "Blocked: Terminal Safety Level is \"Always Ask Confirmation\" but no user approval was recorded for this command.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let background = Self.boolArgument(dict["run_in_background"]) == true
        if Self.boolArgument(dict["interactive"]) == true || background {
            guard let runner = InteractiveCommandRegistry.runner else {
                if background {
                    return ToolExecutionResult(
                        success: false, output: "",
                        error: "run_in_background needs the app's terminal, which is not available here. Run the command without it.",
                        durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    )
                }
                return await executeShell(command: command, cwd: cwd, startTime: startTime, callId: callId)
            }
            // A background command is one that keeps running after this call returns: the
            // terminal holds it, and `send_input` reads more of its output or stops it.
            let result = await executeInteractive(
                command: command, cwd: cwd, runner: runner, startTime: startTime,
                idleSeconds: Self.idleSeconds(from: dict["idle_seconds"])
            )
            if background, result.success {
                var noted = result
                noted.output += "\n\n[Running in the background. send_input with an empty text and press_enter false reads its newer output; send_input with terminate true stops it.]"
                return noted
            }
            return result
        }
        let timeout = (dict["timeout_seconds"] as? Int) ?? Int(dict["timeout_seconds"] as? String ?? "")
        return await executeShell(
            command: command, cwd: cwd, startTime: startTime, callId: callId,
            timeoutSeconds: timeout.map { TimeInterval(min(max($0, 1), 1800)) } ?? 120
        )
    }

    func sendInputTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let callId = call.callId
        return await executeSendInput(dict: dict, workspace: workspace, settings: settings, startTime: startTime, callId: callId)
    }

    func quitAppTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        let appQuery = (dict["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !appQuery.isEmpty else {
            return Self.failure("quit_app needs an 'app' — a bundle id or app name.", startTime)
        }
        guard let running = ScreenPerception.runningApplication(matching: appQuery) else {
            return ToolExecutionResult(
                success: true,
                output: "'\(appQuery)' is not running — nothing to quit.",
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        }
        let name = running.localizedName ?? appQuery
        // Ask first. Force-killing a GUI app discards whatever it had not written yet, and
        // the app under test is often the one holding the work.
        let asked = running.terminate()
        return ToolExecutionResult(
            success: true,
            output: asked
                ? "Asked '\(name)' to quit."
                : "'\(name)' refused to quit — it may have an unsaved-changes dialog open.",
            durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        )
    }

    func runAppTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        let rawPath = (dict["app_path"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let seconds = min(max(dict["observe_seconds"] as? Double ?? 8, 1), 60)
        // Left running by default. `run_app` used to always terminate, which made the two
        // tools it exists to feed — screenshot_window and accessibility_tree — structurally
        // unable to see what it had just launched. A real model hit that within one turn of
        // the feature shipping: it launched the app, read "then terminated", and reasoned
        // that it would have to relaunch to inspect anything.
        let keepRunning = dict["keep_running"] as? Bool ?? true
        guard !rawPath.isEmpty else {
            return Self.failure("run_app needs an 'app_path' — the built .app bundle or executable.", startTime)
        }
        let full = rawPath.hasPrefix("/") ? rawPath : (workspace.folderPath as NSString).appendingPathComponent(rawPath)
        guard FileManager.default.fileExists(atPath: full) else {
            return Self.failure("Nothing at \(full). Build first, then pass the built .app path.", startTime)
        }
        do {
            let outcome = try await AppRunner.run(
                appBundle: URL(fileURLWithPath: full),
                arguments: (dict["arguments"] as? [String]) ?? [],
                observeSeconds: seconds,
                terminateAfter: !keepRunning
            )
            var report: String
            if outcome.stillRunningAtDeadline {
                report = keepRunning
                    ? "Launched and still running after \(Int(seconds))s (pid \(outcome.pid ?? 0)). It is STILL RUNNING — inspect it now with accessibility_tree or screenshot_window, then call quit_app when done.\n"
                    : "Launched and still running after \(Int(seconds))s (pid \(outcome.pid ?? 0)), then terminated.\n"
            } else {
                report = "Exited after less than \(Int(seconds))s with code \(outcome.exitCode.map(String.init) ?? "unknown").\n"
            }
            if let crash = outcome.crashReport {
                report += "\n**A crash report was written:**\n```\n\(crash)\n```\n"
            }
            let out = ToolBounds.boundResult(outcome.stdout).text
            let err = ToolBounds.boundResult(outcome.stderr).text
            if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report += "\nstdout:\n```\n\(out)\n```\n" }
            if !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report += "\nstderr:\n```\n\(err)\n```\n" }
            if outcome.stillRunningAtDeadline && outcome.crashReport == nil && out.isEmpty && err.isEmpty {
                report += "\nNo output, which for a GUI app is usually a clean launch. "
                report += keepRunning
                    ? "Look at it: accessibility_tree or screenshot_window, app: \"\((full as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""))\"."
                    : "Pass keep_running: true to leave it up long enough to inspect."
            }
            // Exiting immediately is a failure of the thing being asked, so report it as one
            // — but never as a bare failure. A `nil` error here reached a model as
            // "Error: unknown error" with the exit code, stdout and stderr discarded.
            let succeeded = outcome.stillRunningAtDeadline || outcome.exitCode == 0
            let reason: String?
            if succeeded {
                reason = nil
            } else if outcome.crashReport != nil {
                reason = "the app crashed on launch"
            } else {
                reason = "the app exited immediately with code \(outcome.exitCode.map(String.init) ?? "unknown")"
            }
            return ToolExecutionResult(
                success: succeeded,
                output: report,
                error: reason,
                durationMs: (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            )
        } catch {
            return Self.failure(error.localizedDescription, startTime)
        }
    }

    func previewStartTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let settings = call.settings
        let startTime = call.startTime
        let hasCommand = !((dict["command"] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if hasCommand || (dict["url"] as? String ?? "").isEmpty {
            // It runs a shell command in the workspace, so it answers to the same rules as
            // terminal_command: the folder must be allowed, and a read-only safety level
            // cannot start a server.
            if let denial = sandboxDenial(for: workspace.folderPath, workspace: workspace, settings: settings, startTime: startTime) {
                return denial
            }
            if settings.terminalSafetyLevel == .safeOnly, hasCommand {
                return Self.failure("Blocked by Terminal Safety Level (\"Allow Safe Read-Only Commands\"): starting a dev server runs a command that is not read-only. Switch to \"Always Ask\" or \"Unrestricted\" under Settings → Advanced.", startTime)
            }
        }
        return await PreviewTools.start(arguments: dict, workspace: workspace, settings: settings, startTime: startTime)
    }

    func previewCheckTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let workspace = call.workspace
        let startTime = call.startTime
        return await PreviewTools.check(arguments: dict, workspace: workspace, startTime: startTime)
    }

    func previewLogsTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let dict = call.dict
        let startTime = call.startTime
        return await PreviewTools.logs(arguments: dict, startTime: startTime)
    }

    func previewStopTool(_ call: sending ToolCall) async -> ToolExecutionResult {
        let startTime = call.startTime
        return await PreviewTools.stop(startTime: startTime)
    }
}
