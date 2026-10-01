import Foundation

/// Fire-and-forget bridge from SwiftOpenWork's agent lifecycle to a locally
/// running ai-memory server (github.com/akitaonrails/ai-memory), so sessions,
/// prompts and tool activity are captured as long-term memory automatically.
/// This is the equivalent of ai-memory's lifecycle hooks for a host that has
/// no native hook surface.
///
/// Wire protocol — ai-memory's documented custom-bridge contract:
///   POST {base}/hook?event=<canonical>&agent=other    body: event JSON
/// Canonical events emitted: session-start, user-prompt, post-tool-use,
/// session-end.
///
/// Never blocks or throws into the agent loop; if the server is down the POST
/// is dropped silently. Disable with AI_MEMORY_HOOKS_DISABLED=1; override the
/// server with AI_MEMORY_HOOK_URL (default http://127.0.0.1:49374).
public final class AIMemoryHooks: @unchecked Sendable {
    public static let shared = AIMemoryHooks()

    private let enabled: Bool
    private let base: URL?
    private let session: URLSession
    private let lock = NSLock()
    private var openSessions: [String: String] = [:]   // sessionId -> cwd
    /// Sessions whose handoff has been requested. The server hands one out once, so the answer
    /// is kept here and re-served on later turns rather than fetched again.
    private var handoffs: [String: String?] = [:]

    public init() {
        let env = ProcessInfo.processInfo.environment
        if let off = env["AI_MEMORY_HOOKS_DISABLED"], off == "1" || off.lowercased() == "true" {
            self.enabled = false
        } else {
            self.enabled = true
        }
        self.base = URL(string: env["AI_MEMORY_HOOK_URL"] ?? "http://127.0.0.1:49374")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle emit points

    /// Opens a session once (first turn). Subsequent calls for the same id are
    /// no-ops, so it is safe to call on every turn.
    public func noteSessionStart(sessionId: String, cwd: String) {
        guard enabled else { return }
        lock.lock()
        let isNew = openSessions[sessionId] == nil
        openSessions[sessionId] = cwd
        lock.unlock()
        guard isNew else { return }
        fire(event: "session-start", body: ["session_id": sessionId, "cwd": cwd, "source": "startup"])
    }

    public func noteUserPrompt(sessionId: String, cwd: String, prompt: String) {
        guard enabled, !prompt.isEmpty else { return }
        noteSessionStart(sessionId: sessionId, cwd: cwd)
        fire(event: "user-prompt", body: ["session_id": sessionId, "cwd": cwd, "prompt": prompt])
    }

    public func noteToolUse(cwd: String, toolName: String, input: String, output: String, success: Bool) {
        guard enabled else { return }
        fire(event: "post-tool-use", body: [
            "cwd": cwd,
            "tool_name": toolName,
            "tool_input": String(input.prefix(20_000)),
            "tool_response": String(output.prefix(20_000)),
            "status": success ? "success" : "error",
        ])
    }

    public func noteSessionEnd(sessionId: String, reason: String = "closed") {
        guard enabled else { return }
        lock.lock(); let cwd = openSessions.removeValue(forKey: sessionId); lock.unlock()
        guard let cwd else { return }
        fire(event: "session-end", body: ["session_id": sessionId, "cwd": cwd, "reason": reason])
    }

    /// Best-effort synchronous flush of session-end for every open session,
    /// for applicationWillTerminate where async work would not complete.
    public func flushOnTerminate(reason: String = "quit") {
        guard enabled else { return }
        lock.lock(); let open = openSessions; openSessions.removeAll(); lock.unlock()
        for (sessionId, cwd) in open {
            fireSync(event: "session-end",
                     body: ["session_id": sessionId, "cwd": cwd, "reason": reason],
                     timeout: 1.0)
        }
    }

    // MARK: - Handoff injection

    /// The pending handoff for this session, fetched on the first call and cached after. The
    /// server's text already carries its own untrusted-history boundary markers. Returns nil when
    /// there is none, the server is down, or hooks are disabled; never throws or blocks for more
    /// than the 1s fetch timeout.
    public func handoff(sessionId: String, cwd: String) async -> String? {
        guard enabled else { return nil }
        // Claim the fetch so concurrent turns don't make a second request.
        let cached: String?? = lock.withLock {
            if let hit = handoffs[sessionId] { return hit }
            handoffs[sessionId] = .some(nil)
            return nil
        }
        if let cached { return cached }

        guard let base,
              var comps = URLComponents(url: base.appendingPathComponent("handoff"),
                                        resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "agent", value: "other"),
            URLQueryItem(name: "cwd", value: cwd),
            URLQueryItem(name: "session_id", value: sessionId),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        lock.withLock { handoffs[sessionId] = .some(text) }
        return text
    }

    // MARK: - Transport

    private func request(event: String, body: [String: String]) -> URLRequest? {
        guard let base,
              var comps = URLComponents(url: base.appendingPathComponent("hook"),
                                        resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "event", value: event),
            URLQueryItem(name: "agent", value: "other"),
        ]
        guard let url = comps.url,
              let data = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = data
        return req
    }

    private func fire(event: String, body: [String: String]) {
        guard let req = request(event: event, body: body) else { return }
        let s = session
        Task.detached { _ = try? await s.data(for: req) }
    }

    private func fireSync(event: String, body: [String: String], timeout: TimeInterval) {
        guard let req = request(event: event, body: body) else { return }
        let sem = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: req) { _, _, _ in sem.signal() }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout)
    }
}
