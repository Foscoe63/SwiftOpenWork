import Foundation

/// Stopping a shell command means stopping everything it started.
///
/// `Process.terminate()` signals only the `zsh -c` the runner launched. The `npm`, `node`,
/// `xcodebuild` or dev server underneath it keeps running as an orphan — and keeps the output pipe
/// open, so a runner that then reads to end-of-file blocks until that grandchild exits, which for
/// a dev server is never. The tool call hangs and so does the agent behind it.
///
/// `ProcessTree` (in `PreviewSupport.swift`) already knows how to find descendants from `ps`
/// output; this adds running `ps` and stopping what it finds.
extension ProcessTree {

    /// Every live descendant of `pid`, from a fresh `ps` snapshot. Empty if `ps` cannot run.
    public static func liveDescendants(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return descendants(of: pid, in: parse(psOutput: String(decoding: data, as: UTF8.self)))
    }

    /// SIGTERM the process and everything under it, then SIGKILL whatever ignored that.
    /// Returns immediately; the follow-up runs in the background.
    public static func terminate(_ pid: Int32, grace: TimeInterval = 2) {
        let victims = liveDescendants(of: pid) + [pid]
        for victim in victims { kill(victim, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            for victim in victims where kill(victim, 0) == 0 { kill(victim, SIGKILL) }
        }
    }
}
