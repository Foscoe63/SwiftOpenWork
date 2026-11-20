import Foundation
import JavaScriptCore

/// Runs the JavaScript program a `code_mode` call carries.
///
/// The script sees one bridge, `tools.<name>(args)`, which returns a Promise. The runtime knows
/// nothing about which tools exist or whether they may run: every call is handed to `Invoker`, and
/// the handler behind it applies the same rules the agent loop applies to a call made directly.
/// The context has no `fetch`, `require`, file or process access of its own, so a script reaches
/// the machine only through that bridge.
///
/// Three limits keep a script from holding the agent: a wall-clock limit for the whole run, a limit
/// on the JavaScript a single stretch may execute (so `while (true) {}` ends), and a cap on tool
/// calls. All three end the run with an error the model can read.
final class CodeModeRuntime: @unchecked Sendable {

    struct Limits: Sendable {
        var wallSeconds: Double = 120
        /// Most JavaScript execution time in one stretch between awaits. Time spent waiting for
        /// tools is not counted.
        var scriptSeconds: Double = 10
        var maxCalls: Int = 100
        var maxLogCharacters: Int = 20_000
        var maxResultCharacters: Int = 200_000
    }

    struct Outcome: Sendable {
        var value: String?
        var error: String?
        var logs: [String]
        var callCount: Int
        var succeeded: Bool { error == nil }
    }

    /// `(tool name, arguments as JSON, 1-based call number)` → the tool's output, or why it failed.
    typealias Invoker = @Sendable (String, String, Int) async -> Result<String, CodeModeCallFailure>

    static let maxSleepSeconds = 10.0

    private let queue = DispatchQueue(label: "swiftopenwork.codemode")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var finished = false
    private var cancelled = false
    private var logs: [String] = []
    private var logCharacters = 0
    private var callCount = 0
    private var inner: [Task<Void, Never>] = []
    private var context: JSContext?

    /// Runs `code` as the body of an async function and returns what it returned.
    static func run(code: String, limits: Limits = Limits(), invoke: @escaping Invoker) async -> Outcome {
        let runtime = CodeModeRuntime()
        return await runtime.execute(code: code, limits: limits, invoke: invoke)
    }

    private func execute(code: String, limits: Limits, invoke: @escaping Invoker) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, limits.wallSeconds) * 1_000_000_000))
                self?.finish(error: "The script ran longer than \(Int(limits.wallSeconds)) seconds and was stopped. Do less per call, or raise timeout_seconds (max 600).", value: nil, limits: limits)
            }
            lock.lock(); inner.append(watchdog); lock.unlock()

            queue.async { [self] in
                start(code: code, limits: limits, invoke: invoke)
            }
        }
    }

    // MARK: - Context

    private func start(code: String, limits: Limits, invoke: @escaping Invoker) {
        guard let context = JSContext() else {
            finish(error: "JavaScriptCore could not start.", value: nil, limits: limits)
            return
        }
        self.context = context
        Self.limitScriptTime(of: context, seconds: limits.scriptSeconds)

        context.exceptionHandler = { [weak self] _, exception in
            guard let self else { return }
            // An error inside the script's own promise chain is delivered through the rejection
            // handler; one that reaches here is a syntax error or a terminated script.
            self.finish(error: Self.describe(exception: exception), value: nil, limits: limits)
        }

        let console: @convention(block) (String, String) -> Void = { [weak self] level, text in
            self?.log(level == "log" ? text : "[\(level)] \(text)", limits: limits)
        }
        context.setObject(console, forKeyedSubscript: "__log" as NSString)

        let native: @convention(block) (String, String, JSValue, JSValue) -> Void = { [weak self] name, argsJson, resolve, reject in
            self?.dispatch(name: name, argsJson: argsJson, resolve: resolve, reject: reject, limits: limits, invoke: invoke)
        }
        context.setObject(native, forKeyedSubscript: "__native" as NSString)

        let sleeper: @convention(block) (Double, JSValue) -> Void = { [weak self] milliseconds, resolve in
            guard let self else { return }
            let box = JSBox(resolve)
            let seconds = min(max(0, milliseconds) / 1000, Self.maxSleepSeconds)
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.queue.async { [weak self] in
                    guard let self, !self.isDone else { return }
                    _ = box.value.call(withArguments: [])
                }
            }
            self.track(task)
        }
        context.setObject(sleeper, forKeyedSubscript: "__sleep" as NSString)

        context.evaluateScript(Self.prelude)
        if isDone { return }

        let wrapped = "(async () => {\n\(code)\n})()"
        guard let promise = context.evaluateScript(wrapped), !isDone else { return }

        let onValue: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self, let context = JSContext.current() else { return }
            let text = context.objectForKeyedSubscript("__format")?.call(withArguments: [value])?.toString() ?? ""
            self.finish(error: nil, value: text, limits: limits)
        }
        let onError: @convention(block) (JSValue) -> Void = { [weak self] error in
            guard let self, let context = JSContext.current() else { return }
            let text = context.objectForKeyedSubscript("__describeError")?.call(withArguments: [error])?.toString() ?? "The script threw."
            self.finish(error: text, value: nil, limits: limits)
        }
        promise.invokeMethod("then", withArguments: [unsafeBitCast(onValue, to: AnyObject.self), unsafeBitCast(onError, to: AnyObject.self)])
    }

    /// `tools.name(args)`: run the call outside the context and settle the promise when it is done.
    private func dispatch(
        name: String, argsJson: String, resolve: JSValue, reject: JSValue,
        limits: Limits, invoke: @escaping Invoker
    ) {
        let resolveBox = JSBox(resolve), rejectBox = JSBox(reject)
        func fail(_ message: String) { _ = rejectBox.value.call(withArguments: [message]) }

        lock.lock()
        let stopped = finished || cancelled
        let number = callCount + 1
        let overCap = number > limits.maxCalls
        if !stopped && !overCap { callCount = number }
        lock.unlock()

        if stopped { return fail("The script has been stopped.") }
        if overCap {
            return fail("This script made more than \(limits.maxCalls) tool calls. Batch the work: list or search once, then read only what you need.")
        }

        let task = Task { [weak self] in
            let result = await invoke(name, argsJson, number)
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.isDone else { return }
                switch result {
                case .success(let output): _ = resolveBox.value.call(withArguments: [output])
                case .failure(let failure): _ = rejectBox.value.call(withArguments: [failure.message])
                }
            }
        }
        track(task)
    }

    // MARK: - Finishing

    private var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func track(_ task: Task<Void, Never>) {
        lock.lock(); inner.append(task); lock.unlock()
    }

    private func log(_ text: String, limits: Limits) {
        lock.lock(); defer { lock.unlock() }
        guard logCharacters < limits.maxLogCharacters else { return }
        let room = limits.maxLogCharacters - logCharacters
        let kept = text.count > room ? String(text.prefix(room)) + " …[log truncated]" : text
        logs.append(kept)
        logCharacters += kept.count
    }

    private func finish(error: String?, value: String?, limits: Limits) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        cancelled = true
        self.continuation = nil
        let tasks = inner
        inner = []
        let outcome = Outcome(
            value: value.map { Self.bounded($0, to: limits.maxResultCharacters) },
            error: error, logs: logs, callCount: callCount
        )
        lock.unlock()
        // Calls still in flight belong to a script that has ended; do not let them keep running.
        for task in tasks { task.cancel() }
        queue.async { [weak self] in self?.context = nil }
        continuation.resume(returning: outcome)
    }

    static func bounded(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[result truncated at \(limit) characters; return less]"
    }

    /// `Name: message (line N)`, with the line counted from the model's first line of code.
    static func describe(exception: JSValue?) -> String {
        guard let exception else { return "The script failed." }
        let message = exception.toString() ?? "The script failed."
        if message.localizedCaseInsensitiveContains("terminated") {
            return "The script ran too long without waiting for a tool and was stopped (an endless loop?)."
        }
        // The wrapper adds one line before the model's code.
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber, line.toInt32() > 1 {
            return "\(message) (line \(line.toInt32() - 1))"
        }
        return message
    }

    // MARK: - JavaScriptCore details

    private typealias SetTimeLimit = @convention(c) (UnsafeRawPointer, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void

    /// Stops a script that spins without ever awaiting. `JSContextGroupSetExecutionTimeLimit` is
    /// exported by JavaScriptCore but not in its public headers, so it is looked up by name; if a
    /// future system lacks it the wall-clock limit still ends the run, just later.
    private static func limitScriptTime(of context: JSContext, seconds: Double) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit"),
              let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        let set = unsafeBitCast(symbol, to: SetTimeLimit.self)
        set(UnsafeRawPointer(group), max(0.5, seconds), nil, nil)
    }

    /// `JSValue` is not `Sendable`; it is only ever touched on `queue`.
    private struct JSBox: @unchecked Sendable {
        let value: JSValue
        init(_ value: JSValue) { self.value = value }
    }

    static let prelude = #"""
    "use strict";
    (function () {
      var native = globalThis.__native, sleepNative = globalThis.__sleep, logNative = globalThis.__log;
      delete globalThis.__native; delete globalThis.__sleep; delete globalThis.__log; // reachable only through `tools`
      var log = function (level) {
        return function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) parts.push(__format(arguments[i]));
          logNative(level, parts.join(" "));
        };
      };
      globalThis.__format = function (v) {
        if (typeof v === "string") return v;
        if (v === undefined) return "";
        if (v instanceof Error) return __describeError(v);
        try { var s = JSON.stringify(v, null, 2); return s === undefined ? String(v) : s; }
        catch (e) { return String(v); }
      };
      globalThis.__describeError = function (e) {
        if (e instanceof Error) return e.name + ": " + e.message;
        return typeof e === "string" ? e : __format(e);
      };
      globalThis.console = { log: log("log"), info: log("info"), warn: log("warn"), error: log("error"), debug: log("debug") };
      globalThis.tools = new Proxy(Object.create(null), {
        get: function (_, name) {
          if (typeof name !== "string" || name === "then") return undefined;
          return function (args) {
            return new Promise(function (resolve, reject) {
              var json = args === undefined ? "{}" : JSON.stringify(args);
              native(name, json === undefined ? "{}" : json, resolve, function (m) { reject(new Error(m)); });
            });
          };
        },
        has: function () { return true; }
      });
      globalThis.sleep = function (ms) { return new Promise(function (resolve) { sleepNative(Number(ms) || 0, resolve); }); };
    })();
    """#
}

/// Why a call a script made did not return output. The message is what the script's `catch` sees.
struct CodeModeCallFailure: Error, Sendable {
    var message: String
}
