import Foundation

/// Stopping a shell command means stopping everything it started.
///
/// `Process.terminate()` signals only the `zsh -c` the runner launched. The `npm`, `node`,
/// `xcodebuild` or dev server underneath it keeps running as an orphan — and keeps the output pipe
/// open, so a runner that then reads to end-of-file blocks until that grandchild exits, which for
/// a dev server is never. The tool call hangs and so does the agent behind it.
public enum ProcessTree {

    /// Every descendant of `pid`, children before their parents.
    public static func descendants(of pid: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return descendants(of: pid, inPsOutput: String(decoding: data, as: UTF8.self))
    }

    /// Pure half of `descendants(of:)`, over `ps -axo pid=,ppid=` output.
    static func descendants(of root: Int32, inPsOutput output: String) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var ordered: [Int32] = []
        func visit(_ pid: Int32) {
            for child in children[pid] ?? [] {
                visit(child)
                ordered.append(child)
            }
        }
        visit(root)
        return ordered
    }

    /// SIGTERM the process and everything under it, then SIGKILL whatever ignored that.
    /// Returns immediately; the follow-up runs in the background.
    public static func terminate(_ pid: Int32, grace: TimeInterval = 2) {
        let victims = descendants(of: pid) + [pid]
        for victim in victims { kill(victim, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            for victim in victims where kill(victim, 0) == 0 { kill(victim, SIGKILL) }
        }
    }
}
