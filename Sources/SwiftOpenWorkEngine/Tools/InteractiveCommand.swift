import Foundation
import os

/// What an interactive command left behind.
public struct InteractiveCommandResult: Sendable, Equatable {
    /// The terminal's text at the end, as the user saw it: carriage returns and cursor movement
    /// already applied, so a progress bar is one line, not four hundred.
    public var output: String
    /// nil when the command was killed rather than exiting.
    public var exitCode: Int32?
    public var timedOut: Bool
    public var cancelled: Bool

    public init(output: String, exitCode: Int32?, timedOut: Bool = false, cancelled: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

/// Runs a command in a pseudo-terminal the user can see and type into, then reports what it
/// printed. The engine does not link the terminal emulator; the app registers one at launch.
public protocol InteractiveCommandRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        displayCommand: String,
        timeoutSeconds: TimeInterval
    ) async -> InteractiveCommandResult
}

public enum InteractiveCommandRegistry {
    private static let current = OSAllocatedUnfairLock<(any InteractiveCommandRunner)?>(initialState: nil)

    public static func register(_ runner: (any InteractiveCommandRunner)?) {
        current.withLock { $0 = runner }
    }

    public static var runner: (any InteractiveCommandRunner)? {
        current.withLock { $0 }
    }
}

enum InteractiveCommandFormatting {
    /// Longest result handed back to the model, matching the ordinary shell tool.
    static let maxCharacters = 200_000

    /// Tool output for a finished interactive run. Says plainly when the user was the one who
    /// ended it, because the model otherwise reads a truncated transcript as a failed command.
    static func format(_ result: InteractiveCommandResult, timeoutSeconds: TimeInterval) -> (success: Bool, output: String, error: String?) {
        var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > maxCharacters { output = String(output.suffix(maxCharacters)) }
        if result.timedOut {
            return (false, output, "Interactive command was still running after \(Int(timeoutSeconds))s and was terminated. Output so far is above.")
        }
        if result.cancelled {
            return (false, output, "Interactive command was stopped before it finished. Output so far is above.")
        }
        guard let code = result.exitCode else {
            return (false, output, "Interactive command ended without an exit status.")
        }
        return (code == 0, output, code == 0 ? nil : "Process exited with code \(code)")
    }
}
