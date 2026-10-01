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
    /// The command is alive and has gone quiet, usually waiting for input. `send_input` continues it.
    public var stillRunning: Bool
    /// Why nothing was run or sent (a command is already active, or there is none to send to).
    public var refusal: String?

    public init(
        output: String, exitCode: Int32?, timedOut: Bool = false, cancelled: Bool = false,
        stillRunning: Bool = false, refusal: String? = nil
    ) {
        self.output = output
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.stillRunning = stillRunning
        self.refusal = refusal
    }
}

/// Runs a command in a pseudo-terminal the user can see and type into, then reports what it
/// printed. The engine does not link the terminal emulator; the app registers one at launch.
///
/// A run is a session. It returns when the command exits, when its output has been quiet for
/// `idleSeconds` (almost always: it is waiting for input), or at the time limit. A quiet command
/// stays alive, and `sendInput` continues the same session.
public protocol InteractiveCommandRunner: Sendable {
    func run(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        displayCommand: String,
        timeoutSeconds: TimeInterval,
        idleSeconds: TimeInterval
    ) async -> InteractiveCommandResult

    /// Type `input` (raw bytes as text, so `\r` is Enter) into the live session and return what it
    /// printed in response. `terminate` ends the session instead.
    func sendInput(_ input: String, idleSeconds: TimeInterval, terminate: Bool) async -> InteractiveCommandResult
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

/// Turns `send_input`'s arguments into the bytes a terminal would receive.
enum InteractiveInput {
    static let keys: [String: String] = [
        "enter": "\r", "tab": "\t", "escape": "\u{1B}", "backspace": "\u{7F}", "space": " ",
        "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
        "ctrl_c": "\u{03}", "ctrl_d": "\u{04}", "ctrl_z": "\u{1A}", "ctrl_l": "\u{0C}",
    ]

    /// `text` first, then `key` if given, then Enter when `pressEnter` (the default for a bare
    /// answer). nil when `key` is not one we know, so a typo is an error rather than a stray byte.
    static func bytes(text: String, pressEnter: Bool, key: String?) -> String? {
        var out = text
        if let key {
            guard let sequence = keys[key.lowercased().replacingOccurrences(of: "-", with: "_")] else { return nil }
            out += sequence
            return out
        }
        // Enter is "\r": the terminal's line discipline turns it into the newline a program reads.
        if pressEnter { out += "\r" }
        return out
    }

    static let knownKeys = keys.keys.sorted().joined(separator: ", ")
}

enum InteractiveCommandFormatting {
    /// Longest result handed back to the model, matching the ordinary shell tool.
    static let maxCharacters = 200_000

    /// Tool output for a finished interactive run. Says plainly when the user was the one who
    /// ended it, because the model otherwise reads a truncated transcript as a failed command.
    static func format(_ result: InteractiveCommandResult, timeoutSeconds: TimeInterval) -> (success: Bool, output: String, error: String?) {
        var output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.count > maxCharacters { output = String(output.suffix(maxCharacters)) }
        if let refusal = result.refusal { return (false, "", refusal) }
        if result.stillRunning {
            let note = "[The command is still running and has gone quiet, so it is probably waiting for input. "
                + "Call send_input to answer it (empty text with press_enter false just waits for more output), "
                + "or send_input with terminate true to end it.]"
            return (true, output.isEmpty ? note : output + "\n\n" + note, nil)
        }
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
