import Foundation
import SwiftOpenWorkCore

/// OS-level confinement for the shell the agent drives, built on macOS Seatbelt (`sandbox-exec`).
///
/// `shellWriteTargetOutsideSandbox` reads the command text for redirects and the like, which a
/// script, a `python -c`, or a `git` hook walks straight past. Seatbelt enforces the same rule in
/// the kernel, on whatever the command actually does.
public enum ShellSandbox {
    public static let executablePath = "/usr/bin/sandbox-exec"

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    /// Where a build or package manager legitimately writes outside the workspace. Without these
    /// `xcodebuild`, `npm`, `cargo` and friends fail on their first cache write.
    static func toolingWritableDirectories(home: String) -> [String] {
        [
            "\(home)/Library/Caches",
            "\(home)/Library/Developer",
            "\(home)/Library/Logs",
            "\(home)/.cache",
            "\(home)/.npm",
            "\(home)/.cargo",
            "\(home)/.rustup",
            "\(home)/.swiftpm",
            "\(home)/.gradle",
            "\(home)/.m2",
            "\(home)/.bun",
            "\(home)/.pnpm-store",
            "/private/tmp",
            "/private/var/folders",
            "/private/var/tmp",
        ]
    }

    /// The system temp locations a process reaches as `/tmp` or `/var/...`; Seatbelt matches on the
    /// resolved path, so a root has to be listed as `/private/...`.
    static func seatbeltPath(_ path: String) -> String {
        for top in ["var", "tmp", "etc"] where path == "/\(top)" || path.hasPrefix("/\(top)/") {
            return "/private" + path
        }
        return path
    }

    static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Later rules win in SBPL, so the broad deny comes first and the allowances after it.
    public static func profile(
        writableRoots: [String],
        allowNetwork: Bool,
        home: String = NSHomeDirectory()
    ) -> String {
        var lines = [
            "(version 1)",
            "(allow default)",
            "(deny file-write*)",
        ]
        var seen = Set<String>()
        for root in writableRoots + toolingWritableDirectories(home: home) {
            let path = seatbeltPath((root as NSString).standardizingPath)
            guard !path.isEmpty, path != "/", seen.insert(path).inserted else { continue }
            lines.append("(allow file-write* (subpath \(quote(path))))")
        }
        // Devices every shell and compiler writes to.
        lines.append("(allow file-write* (literal \"/dev/null\") (literal \"/dev/zero\") (literal \"/dev/tty\") (literal \"/dev/dtracehelper\"))")
        lines.append("(allow file-write* (regex #\"^/dev/(fd/[0-9]+|ttys[0-9]+|pty[a-z0-9]+)$\"))")
        if !allowNetwork {
            // Loopback stays open: dev servers, and the app's own local services.
            lines.append("(deny network-outbound (remote ip))")
            lines.append("(allow network-outbound (remote ip \"localhost:*\"))")
            lines.append("(deny network-inbound (remote ip))")
            lines.append("(allow network-inbound (local ip \"localhost:*\"))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The executable and arguments that run `shellPath -c command` under `mode`, or nil when the
    /// mode confines nothing.
    public static func wrap(
        shellPath: String,
        command: String,
        mode: ShellSandboxMode,
        writableRoots: [String]
    ) -> (executable: String, arguments: [String])? {
        guard mode != .off else { return nil }
        let profile = profile(writableRoots: writableRoots, allowNetwork: mode != .workspaceNoNetwork)
        return (executablePath, ["-p", profile, shellPath, "-c", command])
    }

    /// Why a command should not be launched at all under `mode`, or nil when it can be.
    /// Fails closed: a sandbox the user asked for that cannot be applied must not quietly run
    /// the command unconfined.
    public static func unavailableReason(for mode: ShellSandboxMode) -> String? {
        guard mode != .off, !isAvailable else { return nil }
        return "Shell sandboxing is on, but \(executablePath) is not available on this Mac. "
            + "Turn it off under Settings → Advanced → Shell Sandbox to run commands."
    }
}
