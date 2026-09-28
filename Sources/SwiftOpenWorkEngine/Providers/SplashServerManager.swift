import Foundation
import SwiftOpenWorkCore

/// Runs and owns the `splash serve` process (github.com/incoai/splash) so the Splash provider
/// behaves like the built-in MLX engine from the user's point of view: no terminal, no server the
/// user has to start themselves. SwiftOpenWork detects the `splash` binary, installs it with
/// Homebrew on request, launches it for whichever model is selected, and restarts it when the
/// model changes — `splash serve` pins one model per process, so there is no in-place model swap.
@MainActor
public final class SplashServerManager: ObservableObject {

    public static let shared = SplashServerManager()

    public enum Status: Equatable {
        case notInstalled
        case installing
        case starting
        case running(modelId: String)
        case failed(String)
        case stopped

        public var isLive: Bool {
            switch self {
            case .starting, .running: return true
            default: return false
            }
        }

        public var label: String {
            switch self {
            case .notInstalled: return "Not Installed"
            case .installing: return "Installing…"
            case .starting: return "Starting…"
            case .running(let modelId): return "Running (\(modelId))"
            case .failed: return "Failed"
            case .stopped: return "Stopped"
            }
        }
    }

    @Published public private(set) var status: Status = .stopped
    @Published public private(set) var logLines: [String] = []

    private var process: Process?
    private var partialLine = ""
    private var loginShellPath: String?
    private var loginShellPathResolved = false

    private static let maxLogLines = 2_000
    // The first launch of a model Splash hasn't served before downloads its GGUF weights first —
    // tens of GB, which can take far longer than a normal server boot. A crash or bad launch still
    // surfaces immediately through `terminationHandler` below, independent of this timeout, so it
    // only needs to guard against a process that is alive but never becomes healthy.
    private static let startupTimeout: TimeInterval = 1_800
    private static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    private init() {
        status = detectInstalled() == nil ? .notInstalled : .stopped
    }

    public var pid: Int32? { process?.processIdentifier }

    public func logTail(_ count: Int) -> String {
        logLines.suffix(count).joined(separator: "\n")
    }

    // MARK: Detection

    /// Path to the `splash` binary, or nil if it is not installed anywhere SwiftOpenWork looks.
    public func detectInstalled() -> String? {
        let fm = FileManager.default
        for directory in Self.searchDirectories {
            let candidate = directory + "/splash"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":") {
            let candidate = String(directory) + "/splash"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func detectBrew() -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: Install

    /// Installs Splash with Homebrew. Only ever called from an explicit user action (an "Install
    /// Splash" button) — never automatically, the same restraint the rest of the app uses for every
    /// other missing local dependency.
    public func install() async -> Bool {
        guard let brew = detectBrew() else {
            status = .failed("Homebrew isn't installed. Install it from https://brew.sh, then try again.")
            return false
        }
        status = .installing
        logLines.removeAll()
        note("$ brew install incoai/tap/splash")

        var environment = ProcessInfo.processInfo.environment
        if let path = await resolvedLoginShellPath() {
            environment["PATH"] = DevServerManager.mergePaths(primary: path, secondary: environment["PATH"] ?? "")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "incoai/tap/splash"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.ingest(text) }
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil

        guard exitCode == 0, detectInstalled() != nil else {
            status = .failed("brew install exited with code \(exitCode). Check the log for details.")
            return false
        }
        status = .stopped
        note("Splash installed.")
        return true
    }

    // MARK: Run

    /// Makes sure Splash is up and serving `modelId` at `baseUrl`, starting or restarting it as
    /// needed. The single entry point `ProviderRouter` calls before sending a chat request.
    public func ensureRunning(modelId: String, baseUrl: String, settings: AppSettings) async -> (success: Bool, message: String) {
        guard let url = URL(string: baseUrl) else {
            return (false, "Splash's base URL (\(baseUrl)) isn't valid.")
        }

        if case .running(let runningModel) = status, runningModel == modelId,
           await Self.isHealthy(url, expectingModel: modelId) {
            return (true, "")
        }

        if status.isLive {
            stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        guard let binary = detectInstalled() else {
            status = .notInstalled
            return (false, "Splash isn't installed. Click **Install Splash** in Settings → Providers to install it with Homebrew.")
        }

        return await launch(binary: binary, modelId: modelId, baseUrl: url, settings: settings)
    }

    private func launch(binary: String, modelId: String, baseUrl: URL, settings: AppSettings) async -> (success: Bool, message: String) {
        status = .starting
        logLines.removeAll()

        var environment = ToolExecutionEngine.defaultEnvironment(custom: settings.customEnvironmentVariables)
        if let path = await resolvedLoginShellPath() {
            environment["PATH"] = DevServerManager.mergePaths(primary: path, secondary: environment["PATH"] ?? "")
        }

        // `splash serve` has no documented `--port` flag — it always listens on its own fixed
        // default (127.0.0.1:8000), which is why that is Splash's seeded base URL. Passing an
        // unrecognized flag made the process exit immediately on every launch. If the provider's
        // base URL is ever pointed at a different port, the health check below will simply time
        // out with a clear message rather than silently probing the wrong port.
        let command = "\(binary) serve --model \(modelId)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.ingest(text) }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor [weak self] in
                guard let self, self.status != .stopped else { return }
                self.status = .failed("Splash exited with code \(finished.terminationStatus).")
                self.note("Splash exited with code \(finished.terminationStatus).")
            }
        }

        note("$ \(command)")
        do {
            try process.run()
        } catch {
            let message = "Could not launch splash: \(error.localizedDescription)"
            status = .failed(message)
            return (false, message)
        }
        self.process = process

        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            if case .failed(let reason) = status { return (false, reason) }
            if await Self.isHealthy(baseUrl, expectingModel: modelId) {
                status = .running(modelId: modelId)
                note("Serving \(modelId) at \(baseUrl.absoluteString)")
                return (true, "")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let message = "Splash did not start serving \(modelId) within \(Int(Self.startupTimeout))s. Check the log for details."
        status = .failed(message)
        return (false, message)
    }

    private static func isHealthy(_ baseUrl: URL, expectingModel modelId: String) async -> Bool {
        let url = baseUrl.appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return false }
        return models.contains { ($0["id"] as? String) == modelId }
    }

    // MARK: Stop

    /// Stops the process. Safe to call whether or not one is running.
    public func stop() {
        status = .stopped
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        note("Stopping…")
        ProcessTree.terminate(process.processIdentifier)
        self.process = nil
    }

    /// Stops the process synchronously, for app termination, where no later task will run.
    public func terminateNow() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        for member in [pid] + ProcessTree.liveDescendants(of: pid) { kill(member, SIGKILL) }
    }

    // MARK: Log

    private func ingest(_ chunk: String) {
        let text = partialLine + ANSI.strip(chunk).replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        let settled = lines.map { $0.components(separatedBy: "\r").last ?? $0 }
        append(settled)
    }

    private func note(_ line: String) {
        append(["[Splash] \(line)"])
    }

    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        logLines.append(contentsOf: lines)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
    }

    // MARK: Login shell PATH

    /// Same reasoning and shape as `DevServerManager`'s own resolver: an app launched from the Dock
    /// inherits launchd's minimal PATH, so a bare `splash` lookup can miss where Homebrew put it.
    private func resolvedLoginShellPath() async -> String? {
        if loginShellPathResolved { return loginShellPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolved = await Task.detached(priority: .userInitiated) { () -> String? in
            let output = DevServerManager.runQuick(shell, ["-ilc", #"printf "__SOW_PATH__%s__SOW_END__" "$PATH""#], timeout: 6) ?? ""
            return DevServerManager.extractMarkedPath(output)
        }.value
        loginShellPath = resolved
        loginShellPathResolved = true
        return resolved
    }
}
