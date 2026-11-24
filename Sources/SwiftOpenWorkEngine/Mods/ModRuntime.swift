import Foundation
import JavaScriptCore

/// One mod, one JavaScriptCore context, one serial queue.
///
/// The context has no file system, no network, no process access and no DOM: what a mod can do
/// to the world is a message to the app (`ModHost.service`), which decides whether to do it. It
/// loads the mod's TypeScript through the bundled Sucrase, and it reads files only from inside the
/// mod's own folder.
final class ModRuntime: @unchecked Sendable {
    struct Config: Sendable {
        var name: String
        var root: String
        var pluginRoot: String
        var entries: [String]
        var optionsJSON: String
    }

    let config: Config
    private let queue: DispatchQueue
    private var context: JSContext?
    private var deliver: JSValue?
    private var fire: JSValue?
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var stopped = false
    /// Messages from the mod, as JSON. Called on the mod's queue.
    var onMessage: (@Sendable (String) -> Void)?

    init(config: Config) {
        self.config = config
        self.queue = DispatchQueue(label: "swiftopenwork.mod.\(config.name)", qos: .userInitiated)
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            let ctx = JSContext()!
            ctx.exceptionHandler = { [weak self] _, exception in
                self?.onMessage?(Self.json(["t": "log", "msg": "uncaught: " + (exception?.toString() ?? "unknown")]))
            }
            let native = JSValue(newObjectIn: ctx)!
            let post: @convention(block) (String) -> Void = { [weak self] text in self?.onMessage?(text) }
            let log: @convention(block) (String) -> Void = { [weak self] text in
                self?.onMessage?(Self.json(["t": "log", "msg": text]))
            }
            let readFile: @convention(block) (String) -> Any = { [weak self] path in
                guard let self, let allowed = self.contained(path),
                      let text = try? String(contentsOfFile: allowed, encoding: .utf8) else { return NSNull() }
                return text
            }
            let resolve: @convention(block) (String, String) -> Any = { [weak self] from, spec in
                guard let self else { return NSNull() }
                return self.resolveModule(from: from, spec: spec) ?? NSNull()
            }
            let setTimer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, repeats in
                self?.startTimer(id: id, ms: ms, repeats: repeats)
            }
            let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
                self?.timers.removeValue(forKey: id)?.cancel()
            }
            native.setValue(post, forProperty: "post")
            native.setValue(log, forProperty: "log")
            native.setValue(readFile, forProperty: "readFile")
            native.setValue(resolve, forProperty: "resolve")
            native.setValue(setTimer, forProperty: "setTimer")
            native.setValue(clearTimer, forProperty: "clearTimer")
            ctx.setObject(native, forKeyedSubscript: "__native" as NSString)
            ctx.setObject(Self.configJSON(config), forKeyedSubscript: "__cfg" as NSString)

            // Sucrase first (it leaves `__sucrase` behind), then the bootstrap, which takes both
            // handles and removes them from the global scope.
            ctx.evaluateScript(ModSucrase.script)
            if ctx.objectForKeyedSubscript("__sucrase")?.isUndefined ?? true {
                onMessage?(Self.json(["t": "failed", "error": "The TypeScript transform did not load."]))
                return
            }
            ctx.evaluateScript(ModBootstrap.script, withSourceURL: URL(string: "mod-bootstrap.js"))
            deliver = ctx.objectForKeyedSubscript("__deliver")
            fire = ctx.objectForKeyedSubscript("__fireTimer")
            // Only the app's bridge may call these; take them off the global object.
            context = ctx
        }
    }

    /// Hand a message to the mod.
    func send(_ json: String) {
        queue.async { [self] in
            guard !stopped, let deliver else { return }
            deliver.call(withArguments: [json])
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            for (_, t) in timers { t.cancel() }
            timers.removeAll()
            deliver = nil
            fire = nil
            context = nil
        }
    }

    // MARK: - Timers

    private func startTimer(id: Int, ms: Double, repeats: Bool) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(0.001, ms / 1000)
        if repeats { timer.schedule(deadline: .now() + interval, repeating: interval) } else { timer.schedule(deadline: .now() + interval) }
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            if !repeats { self.timers.removeValue(forKey: id)?.cancel() }
            self.fire?.call(withArguments: [id])
        }
        timers[id]?.cancel()
        timers[id] = timer
        timer.resume()
    }

    // MARK: - Files (only inside the mod's own folder)

    private var realRoot: String { URL(fileURLWithPath: config.root).resolvingSymlinksInPath().path }

    /// The path itself when it lies inside the mod's folder once symlinks are resolved.
    private func contained(_ path: String) -> String? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let root = realRoot
        guard real == root || real.hasPrefix(root + "/") else { return nil }
        return real
    }

    private static let extensions = ["", ".ts", ".tsx", ".js", ".mjs", ".jsx", ".mts", ".cts", ".cjs"]

    private func resolveModule(from: String, spec: String) -> String? {
        let base = ((from as NSString).deletingLastPathComponent as NSString).appendingPathComponent(spec)
        let standard = (base as NSString).standardizingPath
        var isDir: ObjCBool = false
        for ext in Self.extensions {
            let candidate = standard + ext
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                return contained(candidate)
            }
        }
        for ext in Self.extensions.dropFirst() {
            let candidate = (standard as NSString).appendingPathComponent("index" + ext)
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue {
                return contained(candidate)
            }
        }
        return nil
    }

    // MARK: - JSON helpers

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func configJSON(_ config: Config) -> String {
        let options = (try? JSONSerialization.jsonObject(with: Data(config.optionsJSON.utf8))) ?? [String: Any]()
        return json([
            "name": config.name, "root": config.root, "pluginRoot": config.pluginRoot,
            "entries": config.entries, "options": options,
        ] as [String: Any])
    }
}
