import Foundation
import SwiftOpenWorkCore

/// `$.process.run` and `$.http.fetch`: the two ways a mod reaches outside the app.
extension ModHost {
    func runProcess(argvAny: Any?, options: [String: Any]) async -> [String: Any] {
        guard let argv = argvAny as? [String], !argv.isEmpty else {
            return ModProcess.result(127, "", "process.run needs an argv array of strings", false, false)
        }
        let mapped = argv.map { mapPath($0) }
        let cwd = (options["cwd"] as? String).map { mapPath($0) } ?? env.workspacePath()
        let extra = (options["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let stdin = (options["stdin"] as? String) ?? ""
        let timeout = TimeInterval((options["timeoutMs"] as? Int) ?? 120_000) / 1000
        return await ModProcess.run(argv: mapped, cwd: cwd, extraEnv: extra, stdin: stdin, timeout: timeout)
    }

    func fetch(urlText: String, options: [String: Any]) async -> [String: Any] {
        func failure(_ message: String) -> [String: Any] { ["status": 0, "ok": false, "error": message, "text": "", "headers": [String: String]()] }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = WebFetchPolicy.normalizedHost(url) else { return failure("http.fetch needs an http or https URL") }
        // The same line the model's own web tool keeps: a mod cannot reach into the local network.
        if WebFetchPolicy.isLocal(host: host) { return failure("Local and private addresses are blocked.") }
        var request = URLRequest(url: url)
        request.httpMethod = ((options["method"] as? String) ?? "GET").uppercased()
        request.timeoutInterval = min(120, TimeInterval((options["timeoutMs"] as? Int) ?? 30_000) / 1000)
        for (k, v) in (options["headers"] as? [String: Any]) ?? [:] { if let v = v as? String { request.setValue(v, forHTTPHeaderField: k) } }
        if let body = options["body"] as? String { request.httpBody = Data(body.utf8) }
        let session = URLSession(configuration: .ephemeral, delegate: ModRedirectGuard(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return failure("No response") }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { headers["\(k)".lowercased()] = "\(v)" }
            let capped = data.prefix(2_000_000)
            return ["status": http.statusCode, "ok": (200..<300).contains(http.statusCode), "headers": headers,
                    "text": String(decoding: capped, as: UTF8.self), "isTruncated": data.count > capped.count]
        } catch { return failure(error.localizedDescription) }
    }
}

/// Refuses a redirect from a public page to a local address.
final class ModRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let to = request.url, WebFetchPolicy.allowsRedirect(from: task.originalRequest?.url, to: to) else { completionHandler(nil); return }
        completionHandler(request)
    }
}

enum ModProcess {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var out = Data(), err = Data()
        private(set) var outCut = false, errCut = false
        let cap = 8 * 1024 * 1024
        func addOut(_ d: Data) { lock.lock(); if out.count < cap { out.append(d) } else { outCut = true }; lock.unlock() }
        func addErr(_ d: Data) { lock.lock(); if err.count < cap { err.append(d) } else { errCut = true }; lock.unlock() }
        func snapshot() -> (Data, Data, Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (out, err, outCut, errCut) }
    }

    static func result(_ code: Int32, _ out: String, _ err: String, _ outCut: Bool, _ errCut: Bool) -> [String: Any] {
        ["exitCode": Int(code), "stdout": out, "stderr": err, "isStdoutTruncated": outCut, "isStderrTruncated": errCut]
    }

    static func run(argv: [String], cwd: String, extraEnv: [String: String], stdin: String, timeout: TimeInterval) async -> [String: Any] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            let process = Process()
            if argv[0].hasPrefix("/") { process.executableURL = URL(fileURLWithPath: argv[0]); process.arguments = Array(argv.dropFirst()) }
            else { process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = argv }
            var env = ProcessInfo.processInfo.environment.merging(extraEnv) { $1 }
            let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            env["PATH"] = ((env["PATH"] ?? "").split(separator: ":").map(String.init) + extra).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
            process.environment = env
            if FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            process.standardOutput = outPipe; process.standardError = errPipe; process.standardInput = inPipe
            let collector = Collector()
            outPipe.fileHandleForReading.readabilityHandler = { collector.addOut($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { collector.addErr($0.availableData) }
            let done = NSLock()
            nonisolated(unsafe) var finished = false
            let finish: @Sendable (Int32, String) -> Void = { code, note in
                done.lock(); defer { done.unlock() }
                guard !finished else { return }
                finished = true
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Whatever the process left in the pipes after it exited.
                collector.addOut(outPipe.fileHandleForReading.availableData)
                collector.addErr(errPipe.fileHandleForReading.availableData)
                let (o, e, oc, ec) = collector.snapshot()
                continuation.resume(returning: result(code, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self) + note, oc, ec))
            }
            process.terminationHandler = { p in finish(p.terminationStatus, "") }
            do { try process.run() } catch { finish(127, error.localizedDescription); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate(); usleep(200_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                finish(124, "\n[timed out]")
            }
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
    }
}
