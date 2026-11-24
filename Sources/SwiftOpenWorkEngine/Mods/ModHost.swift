import Foundation
import AppKit
import AVFoundation
import SwiftOpenWorkCore

/// What the mod host needs from the running app. `AppState` fills these in; the engine does not
/// reach into the app's state directly.
@MainActor
public final class ModEnvironment {
    public var sessionId: () -> String = { "" }
    public var workspacePath: () -> String = { NSHomeDirectory() }
    public var currentModel: () -> String = { "" }
    /// The chat so far, one row per message: `role`, `text`, `toolUses`, `toolResults`.
    public var messages: () -> [[String: Any]] = { [] }
    public var transcript: () -> String = { "" }
    public var usage: () -> [String: Any] = { [:] }
    /// A one-shot completion with the app's default model. Nil when there is no answer.
    public var complete: (_ prompt: String, _ system: String, _ maxTokens: Int, _ timeout: TimeInterval) async -> String? = { _, _, _, _ in nil }
    public var sendMessage: (String) -> Void = { _ in }
    public var fillPrompt: (String) -> Void = { _ in }
    public var readPrompt: () -> String = { "" }
    public var abortTurn: () -> Void = {}
    public var agents: () -> [[String: Any]] = { [] }
    public var toast: (String) -> Void = { _ in }
    public var notify: (_ title: String, _ text: String) -> Bool = { _, _ in false }
    public var runTool: (_ name: String, _ argumentsJson: String) async -> (success: Bool, text: String) = { _, _ in (false, "No tools are available here.") }
    public var mcpCall: (_ server: String, _ tool: String, _ argumentsJson: String) async -> String = { _, _, _ in "MCP is not available here." }
    public var builtinToolNames: () -> [String] = { [] }
    public var builtinCommands: () -> [String] = { [] }
    public var appVersion: String = ""
    public var userName: String = NSFullUserName()
    public init() {}
}

/// Runs mods: finds them, starts the enabled ones, passes events through their hook chains and
/// answers the `$` calls they make.
///
/// A mod is a function that hooks into events (`prompt.submit`, `tool.call`, `turn.complete`,
/// `ui.render`, …). For each event the mods' hooks run one after another, each able to look at it,
/// change it, answer it or let it through with `next`, and the app's own behaviour is at the end of
/// the chain. This is the same engine Claude Code's mods target, so a mod written for it runs here.
@MainActor
public final class ModHost: ObservableObject {
    public static let shared = ModHost()

    // MARK: - What the UI shows

    @Published public private(set) var mods: [ModInfo] = []
    @Published public private(set) var panes: [ModPane] = []
    @Published public private(set) var statusLines: [ModStatusLine] = []
    @Published public private(set) var commands: [ModCommand] = []
    @Published public private(set) var hasBand = false
    @Published public private(set) var hasMessageHooks = false
    /// Bumped whenever a mod asks to be drawn again, so views redraw what mods render.
    @Published public private(set) var revision = 0
    @Published public private(set) var logs: [String: [String]] = [:]
    @Published public var activePaneId: String?
    @Published public var question: ModQuestion?

    public let env = ModEnvironment()
    /// Called when a mod opens a pane, so the app can show where panes live.
    public var onOpenPane: (String) -> Void = { _ in }

    // MARK: - State

    @MainActor final class Chain {
        let next: @Sendable (String) async -> String
        let input: String
        let timeout: TimeInterval
        var deadline: Date
        var continuation: CheckedContinuation<String, Never>?
        var watchdog: Task<Void, Never>?
        init(next: @escaping @Sendable (String) async -> String, input: String, timeout: TimeInterval) {
            self.next = next; self.input = input; self.timeout = timeout; self.deadline = Date().addingTimeInterval(timeout)
        }
        func touch() { deadline = Date().addingTimeInterval(timeout) }
    }

    struct Hook { var event: String; var matcher: [String: ModJSON]? }

    @MainActor final class Record {
        let manifest: ModManifest
        var runtime: ModRuntime?
        var status: ModInfo.Status = .starting
        var error: String?
        var hooks: [Hook] = []
        var chains: [Int: Chain] = [:]
        var pressWaits: [Int: CheckedContinuation<String?, Never>] = [:]
        var startWaiter: CheckedContinuation<Void, Never>?
        var tools: [String: (description: String, schema: String)] = [:]
        var inflight = 0
        var rpcCount = 0
        var seq = 0
        var loadedAt = Date()
        init(manifest: ModManifest) { self.manifest = manifest }
        func resolveStart() { if let w = startWaiter { startWaiter = nil; w.resume() } }
    }

    private var records: [String: Record] = [:]
    private var state: [String: (value: Any, version: Int)] = [:]
    private var paneRecords: [String: (plugin: String, title: String)] = [:]
    /// Subagents of this chat, for `$.agent.list()` and the events they raise.
    struct SubAgentRecord { var id: String; var description: String; var type: String; var model: String; var status: String; var startedAt: Date }
    private var subAgents: [String: SubAgentRecord] = [:]
    /// Calls a mod made that SwiftOpenWork has no answer for, by mod, so its card can say so.
    private var unsupportedCalls: [String: Set<String>] = [:]
    private var statusByPlugin: [String: String] = [:]
    private var commandRecords: [String: ModCommand] = [:]
    private var chainSeq = 0
    private var askWaiters: [String: CheckedContinuation<[String]?, Never>] = [:]
    private var dirtyTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var sessionConv = ""
    private var tick = 0
    public private(set) var isWorking = false

    static let eventTimeout: TimeInterval = 15
    static let maxLogLines = 300

    private init() {}

    // MARK: - Discovery and switches

    var enabledMap: [String: Bool] {
        (ModDiscovery.readJSON(ModPaths.switchesFile) ?? [:]).compactMapValues { $0 as? Bool }
    }

    // MARK: - Panes that stay open

    /// Panes a mod opened and the person has not closed, by mod, so they are there again in the next
    /// chat and the next launch, whether or not the event that first opened them happens.
    private static var panesFile: String { (ModPaths.nativeDir as NSString).appendingPathComponent("panes.json") }

    private var rememberedPanes: [String: [String: String]] {
        ((ModDiscovery.readJSON(Self.panesFile) ?? [:]) as [String: Any]).compactMapValues { $0 as? [String: String] }
    }

    private func rememberPane(plugin: String, id: String, title: String?) {
        var map = rememberedPanes
        var panes = map[plugin] ?? [:]
        if let title { panes[id] = title } else { panes.removeValue(forKey: id) }
        map[plugin] = panes.isEmpty ? nil : panes
        try? FileManager.default.createDirectory(atPath: ModPaths.nativeDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Self.panesFile))
        }
    }

    private func restorePanes(for name: String) {
        for (id, title) in rememberedPanes[name] ?? [:] where paneRecords[id] == nil {
            paneRecords[id] = (name, title)
            if activePaneId == nil { activePaneId = id }
        }
        markDirty()
    }

    private func saveEnabled(_ map: [String: Bool]) {
        try? FileManager.default.createDirectory(atPath: ModPaths.nativeDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ModPaths.switchesFile))
        }
    }

    private var trusted: [String: String] {
        (ModDiscovery.readJSON(ModPaths.trustFile) ?? [:]).compactMapValues { $0 as? String }
    }

    private func saveTrusted(_ map: [String: String]) {
        try? FileManager.default.createDirectory(atPath: ModPaths.nativeDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: ModPaths.trustFile))
        }
    }

    func discover() -> [ModManifest] { ModDiscovery.discover() }
    func manifest(named name: String) -> ModManifest? { discover().first { $0.name == name } }
    public var knownNames: [String] { discover().map(\.name) }

    /// Re-read the list of mods, with how each one stands.
    public func refresh() {
        let enabled = enabledMap
        let trust = trusted
        mods = discover().map { m in
            let record = records[m.name]
            var status = record?.status ?? .off
            if record == nil, enabled[m.name] == true, Self.needsReview(m, trusted: trust) { status = .needsReview }
            return ModInfo(
                name: m.name, version: m.version, description: m.description, source: m.source, root: m.root,
                enabled: enabled[m.name] == true, status: status, error: record?.error,
                hookCount: record?.hooks.count ?? 0, toolCount: record?.tools.count ?? 0,
                commandCount: commandRecords.values.filter { $0.plugin == m.name }.count,
                isRemovable: m.source == ModPaths.nativeSource,
                permissions: m.permissions,
                compatibility: ModCompatibility.notes(for: m, unsupportedCalls: unsupportedCalls[m.name] ?? [])
            )
        }
    }

    /// A mod that came from somewhere else (Claude Code's installs, GrizzyCode) and has changed since
    /// the person turned it on is held until they look at it again. Mods in this app's own folder
    /// are the person's to edit.
    private static func needsReview(_ m: ModManifest, trusted: [String: String]) -> Bool {
        guard m.source != ModPaths.nativeSource else { return false }
        guard let known = trusted[m.name] else { return false }
        return known != ModDiscovery.digest(of: m)
    }

    // MARK: - Lifecycle

    public func startEnabled() async {
        let enabled = enabledMap, trust = trusted
        for m in discover() where enabled[m.name] == true {
            if Self.needsReview(m, trusted: trust) {
                appendLog(m.name, "Held: this mod changed since you turned it on. Turn it on again to review it.")
                continue
            }
            await start(m)
        }
        refresh()
        beginWatching()
    }

    /// Turn a mod on or off. The caller has already asked the person when turning on.
    @discardableResult
    public func setEnabled(_ name: String, _ on: Bool) async -> String? {
        var map = enabledMap
        if on {
            guard let m = manifest(named: name) else { return "Mod not found." }
            map[name] = true
            saveEnabled(map)
            var trust = trusted
            trust[name] = ModDiscovery.digest(of: m)
            saveTrusted(trust)
            await start(m)
        } else {
            map[name] = false
            saveEnabled(map)
            await stop(name)
        }
        markDirty()
        return nil
    }

    /// Re-read a mod from disk and restart it if it is on (after its files were edited or replaced).
    @discardableResult
    public func reload(_ name: String) async -> String? {
        guard let m = manifest(named: name) else { await stop(name); markDirty(); return "Mod not found." }
        if enabledMap[name] == true {
            if m.source != ModPaths.nativeSource {
                // An update someone else made is not something to run unseen.
                var trust = trusted
                if trust[name] == nil || trust[name] == ModDiscovery.digest(of: m) { trust[name] = ModDiscovery.digest(of: m); saveTrusted(trust) }
            }
            await start(m)
        } else { await stop(name) }
        markDirty()
        return nil
    }

    func start(_ m: ModManifest) async {
        await stop(m.name, quiet: true)
        let record = Record(manifest: m)
        records[m.name] = record
        let runtime = ModRuntime(config: .init(
            name: m.name, root: m.root, pluginRoot: ModDiscovery.pluginRoot(for: m),
            entries: m.entries, optionsJSON: m.optionsJSON
        ))
        record.runtime = runtime
        runtime.onMessage = { [weak record] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let record else { return }
                    ModHost.shared.handle(record, text)
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            record.startWaiter = continuation
            runtime.start()
            Task { @MainActor [weak record] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if let record, record.status == .starting { self.fail(record, "timed out while loading") }
            }
        }
        if record.status == .running { restorePanes(for: m.name) }
        refresh()
    }

    func stop(_ name: String, quiet: Bool = false) async {
        guard let record = records.removeValue(forKey: name) else { return }
        record.status = .stopped
        record.runtime?.stop()
        for chain in record.chains.values { chain.watchdog?.cancel(); finish(chain, with: nil) }
        record.chains.removeAll()
        for (_, wait) in record.pressWaits { wait.resume(returning: nil) }
        record.pressWaits.removeAll()
        record.resolveStart()
        statusByPlugin.removeValue(forKey: name)
        for (id, pane) in paneRecords where pane.plugin == name { paneRecords.removeValue(forKey: id) }
        for key in commandRecords.keys where commandRecords[key]?.plugin == name { commandRecords.removeValue(forKey: key) }
        if !quiet { markDirty() }
    }

    public func stopAll() async {
        watchTask?.cancel()
        for name in Array(records.keys) { await stop(name, quiet: true) }
        subAgents.removeAll(); unsupportedCalls.removeAll()
        markDirty()
    }

    private func fail(_ record: Record, _ message: String) {
        guard record.status != .failed else { return }
        record.status = .failed
        record.error = String(message.prefix(600))
        appendLog(record.manifest.name, "failed: \(record.error ?? "")")
        record.runtime?.stop()
        for chain in record.chains.values { chain.watchdog?.cancel(); finish(chain, with: nil) }
        record.chains.removeAll()
        record.resolveStart()
        markDirty()
    }

    var running: [Record] {
        records.values.filter { $0.status == .running }.sorted { $0.manifest.name < $1.manifest.name }
    }

    func hasHook(_ event: String, where filter: ((Hook) -> Bool)? = nil) -> Bool {
        running.contains { $0.hooks.contains { $0.event == event && (filter?($0) ?? true) } }
    }

    /// Whether any mod listens for this event. Cheap enough to ask on every tool call.
    public func hasListener(for event: String) -> Bool { hasHook(event) }

    // Watch the mods the person is editing: save a file and the mod restarts.
    private func beginWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                await self.checkForEdits()
            }
        }
    }

    private func checkForEdits() async {
        let candidates = records.values.filter { $0.manifest.source == ModPaths.nativeSource && $0.status != .starting }
        for record in candidates {
            let manifest = record.manifest, since = record.loadedAt
            let newest = await Task.detached { ModDiscovery.newestModification(of: manifest) }.value
            if newest > since, records[manifest.name] === record {
                appendLog(manifest.name, "files changed; reloading")
                if let fresh = self.manifest(named: manifest.name) { await start(fresh) }
                markDirty()
            }
        }
    }

    // MARK: - Messages from a mod

    func handle(_ record: Record, _ text: String) {
        guard record.status != .stopped,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["t"] as? String else { return }
        switch type {
        case "ready":
            record.status = .running
            record.loadedAt = Date()
            record.hooks = ((object["hooks"] as? [[String: Any]]) ?? []).map {
                Hook(event: ($0["event"] as? String) ?? "", matcher: ($0["matcher"] as? [String: Any])?.mapValues { ModJSON(any: $0) })
            }
            record.resolveStart()
            markDirty()
            Task { await self.raiseOne(record, "session.start", self.sessionStartInput()) }
        case "failed": fail(record, (object["error"] as? String) ?? "failed")
        case "log": appendLog(record.manifest.name, (object["msg"] as? String) ?? "")
        case "rpc": onRPC(record, object)
        case "next": onNext(record, object)
        case "eventRet":
            guard let id = (object["chain"] as? NSNumber)?.intValue, let chain = record.chains.removeValue(forKey: id) else { return }
            chain.watchdog?.cancel()
            if let error = object["error"] as? String {
                appendLog(record.manifest.name, "event skipped (\(error))")
                finish(chain, with: nil)
            } else { finish(chain, with: ModRuntime.json(["v": object["value"] ?? NSNull()])) }
        case "pressRet":
            if let id = (object["id"] as? NSNumber)?.intValue, let wait = record.pressWaits.removeValue(forKey: id) {
                wait.resume(returning: object["error"] as? String ?? "")
            }
        default: break
        }
    }

    func appendLog(_ plugin: String, _ line: String) {
        var list = logs[plugin] ?? []
        list.append(line)
        if list.count > Self.maxLogLines { list.removeFirst(list.count - Self.maxLogLines) }
        logs[plugin] = list
        AppLog.verbose(.tools, "mod \(plugin): \(line)")
    }

    public func clearLog(_ plugin: String) { logs[plugin] = [] }

    // MARK: - Event chains

    private func sessionStartInput() -> String {
        ModRuntime.json(["cwd": env.workspacePath(), "surface": "desktop", "isInteractive": true] as [String: Any])
    }

    /// Resolve a chain with its final value (a JSON object holding `v`), or with nothing when it
    /// failed and the rest of the chain should run without that mod.
    private func finish(_ chain: Chain, with wrapped: String?) {
        guard let continuation = chain.continuation else { return }
        chain.continuation = nil
        chain.watchdog?.cancel()
        if let wrapped,
           let object = (try? JSONSerialization.jsonObject(with: Data(wrapped.utf8))) as? [String: Any] {
            continuation.resume(returning: ModRuntime.json(["v": object["v"] ?? NSNull()]))
        } else {
            let next = chain.next, input = chain.input
            Task { continuation.resume(returning: ModRuntime.json(["v": Self.unwrap(await next(input))])) }
        }
    }

    nonisolated static func unwrap(_ jsonText: String) -> Any {
        guard let data = jsonText.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return any
    }

    /// Run one mod's hooks for an event. `next` runs the rest of the chain.
    private func callMod(_ record: Record, event: String, input: String,
                         next: @escaping @Sendable (String) async -> String,
                         timeout: TimeInterval = ModHost.eventTimeout) async -> String {
        guard record.status == .running, let runtime = record.runtime else { return await next(input) }
        chainSeq += 1
        let id = chainSeq
        let chain = Chain(next: next, input: input, timeout: timeout)
        let wrapped: String = await withCheckedContinuation { continuation in
            chain.continuation = continuation
            record.chains[id] = chain
            chain.watchdog = Task { @MainActor [weak record] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let record else { return }
                    if record.inflight == 0, record.rpcCount == 0, Date() > chain.deadline {
                        record.chains.removeValue(forKey: id)
                        self.appendLog(record.manifest.name, "\(event) skipped (timed out)")
                        self.finish(chain, with: nil)
                        return
                    }
                }
            }
            let inputObject = (try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])) ?? NSNull()
            runtime.send(ModRuntime.json(["t": "event", "chain": id, "event": event, "input": inputObject] as [String: Any]))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(wrapped.utf8))) as? [String: Any] else { return "null" }
        return Self.encodeFragment(object["v"])
    }

    nonisolated static func encodeFragment(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) {
            return String(decoding: data, as: UTF8.self)
        }
        if let data = try? JSONSerialization.data(withJSONObject: [value]) {
            let text = String(decoding: data, as: UTF8.self)
            return String(text.dropFirst().dropLast())
        }
        return "null"
    }

    private func onNext(_ record: Record, _ object: [String: Any]) {
        guard let chainId = (object["chain"] as? NSNumber)?.intValue, let id = (object["id"] as? NSNumber)?.intValue,
              let chain = record.chains[chainId] else { return }
        let input = Self.encodeFragment(object["input"])
        record.inflight += 1
        let next = chain.next
        Task { @MainActor in
            let value = await next(input)
            record.inflight -= 1
            chain.touch()
            record.runtime?.send(ModRuntime.json(["t": "nextRet", "id": id, "value": Self.unwrap(value)] as [String: Any]))
        }
    }

    /// Raise an event through every running mod that listens, then the app's own behaviour (`bottom`).
    func raise(_ event: String, _ input: String, timeout: TimeInterval = ModHost.eventTimeout,
               bottom: @escaping @Sendable (String) async -> String) async -> String {
        let listeners = running.filter { $0.hooks.contains { $0.event == event } }
        @Sendable func run(_ index: Int, _ value: String) async -> String {
            if index >= listeners.count { return await bottom(value) }
            return await self.callMod(listeners[index], event: event, input: value, next: { e in await run(index + 1, e) }, timeout: timeout)
        }
        return await run(0, input)
    }

    private func raiseOne(_ record: Record, _ event: String, _ input: String) async {
        _ = await callMod(record, event: event, input: input, next: { _ in "{}" })
    }

    private func raiseAll(_ event: String, _ input: String) async {
        let listeners = running.filter { $0.hooks.contains { $0.event == event } }
        for record in listeners { await raiseOne(record, event, input) }
    }

    @MainActor private final class DoneFlag { var done = false }

    nonisolated private static func object(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    // MARK: - Behaviours the app calls

    /// The chat or folder the mods should treat as current.
    public func setSession(id: String, cwd: String) {
        guard id != sessionConv else { return }
        sessionConv = id
        subAgents = subAgents.filter { $0.value.status == "running" }
        Task { await raiseAll("session.start", sessionStartInput()) }
        markDirty()
    }

    /// Let mods look at a message before it is sent: they may change it, or take it (`drop`).
    public func promptSubmit(_ text: String) async -> PromptSubmitOutcome {
        guard hasHook("prompt.submit") else { return .text(text) }
        let input = ModRuntime.json(["text": text, "wait": false, "origin": ["kind": "composer"]] as [String: Any])
        let result = await raise("prompt.submit", input) { e in
            ModRuntime.json(["text": (Self.object(e)?["text"] as? String) ?? ""])
        }
        guard let object = Self.object(result) else { return .text(text) }
        if let drop = object["drop"], !(drop is NSNull) {
            if let message = drop as? String { return .drop(message) }
            return .drop("")
        }
        if let changed = object["text"] as? String { return .text(changed) }
        return .text(text)
    }

    /// Extra sections mods want in the system prompt.
    public func promptCompose(model: String) async -> [String] {
        guard hasHook("prompt.compose") else { return [] }
        let input = ModRuntime.json(["model": model, "promptModel": model, "surfaces": ["desktop"], "tools": [Any](), "outputStyle": NSNull(), "traits": [Any]()] as [String: Any])
        let result = await raise("prompt.compose", input) { _ in ModRuntime.json(["sections": [Any]()]) }
        let sections = (Self.object(result)?["sections"] as? [[String: Any]]) ?? []
        return sections.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
    }

    /// Run a slash command a mod registered. The reply is text for the chat.
    public func runCommand(plugin: String, name: String, args: String) async -> String {
        let input = ModRuntime.json(["command": name, "args": args, "origin": ["kind": "composer"], "presentation": ["isFullscreen": false, "columns": 100]] as [String: Any])
        let result = await raise("command.run", input, timeout: 60) { _ in ModRuntime.json(["text": "No mod handled /\(name)."]) }
        markDirty()
        if let text = Self.object(result)?["text"] as? String { return text }
        return ""
    }

    public func turnStart(text: String, turnId: String) async {
        isWorking = true
        if hasHook("turn.start") {
            let input = ModRuntime.json(["text": text, "turnId": turnId])
            // A slow mod must not hold the turn up for more than a moment.
            let flag = DoneFlag()
            Task { @MainActor in await self.raiseAll("turn.start", input); flag.done = true }
            var waited = 0
            while !flag.done, waited < 40 { try? await Task.sleep(nanoseconds: 50_000_000); waited += 1 }
        }
        markDirty()
    }

    public func turnStep(turnId: String, index: Int, model: String, messageCount: Int) async {
        guard hasHook("turn.step") else { return }
        await raiseAll("turn.step", ModRuntime.json(["turnId": turnId, "index": index, "model": model, "messageCount": messageCount] as [String: Any]))
    }

    public func turnComplete(answer: String, durationMs: Int, aborted: Bool, turnId: String, inputTokens: Int = 0, outputTokens: Int = 0) async {
        isWorking = false
        if hasHook("turn.complete") {
            let input = ModRuntime.json(["answer": answer, "durationMs": durationMs, "isAborted": aborted, "turnId": turnId, "reason": aborted ? "aborted" : "answer",
                                          "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0]] as [String: Any])
            _ = await raise("turn.complete", input) { _ in "{}" }
        }
        markDirty()
    }

    // MARK: - Subagents

    /// A subagent is starting. Mods hear `agent.spawn` (they may watch it) and see it in `$.agent.list()`.
    /// Returns the id its later events carry.
    public func subAgentStarted(description: String, type: String, model: String) async -> String {
        let id = "sub-" + String(UUID().uuidString.prefix(8)).lowercased()
        subAgents[id] = SubAgentRecord(id: id, description: description, type: type, model: model, status: "running", startedAt: Date())
        markDirty()
        if hasHook("agent.spawn") {
            let input = ModRuntime.json(["description": description, "subagentType": type, "model": model, "prompt": ""] as [String: Any])
            _ = await raise("agent.spawn", input, timeout: 5) { _ in ModRuntime.json(["agentId": id, "model": model] as [String: Any]) }
        }
        return id
    }

    /// One model request of the subagent running in this task.
    public func subAgentStep(index: Int, model: String, effort: String) async {
        guard let id = ModAgentContext.id, hasHook("turn.step") else { return }
        await raiseAll("turn.step", ModRuntime.json(["agentId": id, "index": index, "model": model, "effort": effort] as [String: Any]))
    }

    public func subAgentFinished(id: String, succeeded: Bool, durationMs: Int) async {
        subAgents[id]?.status = succeeded ? "completed" : "failed"
        markDirty()
        guard hasHook("turn.complete") else { return }
        let input = ModRuntime.json(["agentId": id, "reason": succeeded ? "answer" : "error", "isAborted": false, "durationMs": durationMs] as [String: Any])
        _ = await raise("turn.complete", input, timeout: 5) { _ in "{}" }
    }

    // MARK: - Tools

    /// The names Claude Code's mods know built-in tools by, and the field names they use.
    static func claudeCall(tool: String, argumentsJson: String) -> (name: String, input: [String: Any]) {
        let canonical = ToolCallRepair.builtInCanonical(tool) ?? tool
        let map: [String: String] = [
            "file_read": "Read", "read_file": "Read", "file_write": "Write", "write_file": "Write", "create_file": "Write",
            "edit_file": "Edit", "file_edit": "Edit", "multi_edit": "MultiEdit", "terminal_command": "Bash", "run_command": "Bash",
            "grep": "Grep", "glob": "Glob", "list_directory": "LS", "list_dir": "LS", "fetch_url": "WebFetch", "web_search": "WebSearch",
            "exit_plan_mode": "ExitPlanMode", "use_skill": "Skill", "agent_spawn": "Agent", "todo_write": "TodoWrite",
        ]
        let name = map[canonical] ?? tool
        var input = (try? JSONSerialization.jsonObject(with: Data(argumentsJson.utf8))) as? [String: Any] ?? [:]
        if ["Read", "Write", "Edit", "MultiEdit"].contains(name), let path = input["path"] { input["file_path"] = path; input.removeValue(forKey: "path") }
        // Delegating to another agent is Claude Code's Agent (Task) tool; the plan is TodoWrite.
        if name == "Agent" {
            if let title = input["task_title"] { input["description"] = title }
            if let target = input["target_agent_id"] { input["subagent_type"] = target }
            if let detail = input["task_description"] { input["prompt"] = detail }
        }
        if name == "TodoWrite", input["todos"] == nil, let items = input["items"] { input["todos"] = items }
        return (name, input)
    }

    /// A built-in tool's name and arguments as Claude Code's mods know them.
    public static func claudeNames(tool: String, argumentsJson: String) -> (name: String, input: [String: Any]) {
        claudeCall(tool: tool, argumentsJson: argumentsJson)
    }

    private final class ResultBox: @unchecked Sendable { var value: ToolExecutionResult? }

    /// Wrap a built-in tool call so mods see it, and may rewrite its result or refuse it. `perform`
    /// does the real work. Returns nil when no mod listens, so the caller can skip all of this.
    public func wrapToolCall(toolName: String, argumentsJson: String, callId: String?,
                             perform: @escaping @Sendable () async -> ToolExecutionResult) async -> ToolExecutionResult {
        guard hasHook("tool.call") else { return await perform() }
        let call = Self.claudeCall(tool: toolName, argumentsJson: argumentsJson)
        var event = call.input
        event["tool"] = call.name
        event["tool_use_id"] = callId ?? ""
        // A call a subagent makes names it, so mods can tell it from the main chat's.
        if let agent = ModAgentContext.id { event["agentId"] = agent }
        let box = ResultBox()
        let result = await raise("tool.call", ModRuntime.json(event), timeout: 20) { _ in
            let done = await perform()
            box.value = done
            let text = done.success ? done.output : (done.error ?? done.output)
            return ModRuntime.json(["result": ["text": text], "text": text, "isError": !done.success] as [String: Any])
        }
        let object = Self.object(result) ?? [:]
        if let deny = object["deny"], !(deny is NSNull) {
            let reason = (deny as? String) ?? "denied"
            return ToolExecutionResult(success: false, output: "", error: "Blocked by a mod: \(reason)", durationMs: 0)
        }
        let text = (object["text"] as? String) ?? ((object["result"] as? [String: Any])?["text"] as? String)
        if var ran = box.value {
            // A mod may rewrite what the model sees of a result (redact, trim, annotate).
            if let text {
                let original = ran.success ? ran.output : (ran.error ?? ran.output)
                if text != original { if ran.success { ran.output = text } else { ran.error = text } }
            }
            return ran
        }
        // No built-in ran: a mod answered the call itself.
        let isError = (object["isError"] as? Bool) ?? false
        return ToolExecutionResult(success: !isError, output: isError ? "" : (text ?? ""), error: isError ? (text ?? "error") : nil, durationMs: 0)
    }

    private static let toolPrefix = "mod__"

    /// The tools mods registered, as the model sees them: `mod__<mod>__<tool>`.
    public func toolDefinitions() -> [Tool] {
        var out: [Tool] = []
        for record in running {
            for (name, spec) in record.tools.sorted(by: { $0.key < $1.key }) {
                out.append(Tool(
                    id: "mod:\(record.manifest.name):\(name)",
                    name: "\(Self.toolPrefix)\(record.manifest.name)__\(name)",
                    displayName: "\(record.manifest.name): \(name)",
                    description: String(spec.description.prefix(1000)),
                    category: .custom,
                    parametersJsonSchema: spec.schema,
                    isEnabled: true,
                    requiresApproval: false
                ))
            }
        }
        return out
    }

    public func isModTool(_ name: String) -> Bool {
        guard name.hasPrefix(Self.toolPrefix) else { return false }
        return resolveTool(name) != nil
    }

    private func resolveTool(_ full: String) -> (Record, String)? {
        let rest = full.dropFirst(Self.toolPrefix.count)
        guard let split = rest.range(of: "__") else { return nil }
        let plugin = String(rest[rest.startIndex..<split.lowerBound]), tool = String(rest[split.upperBound...])
        guard let record = records[plugin], record.status == .running, record.tools[tool] != nil else { return nil }
        return (record, tool)
    }

    /// Run a mod's tool: the call goes through the mods' `tool.call` hooks, and whichever mod owns
    /// the tool answers it.
    public func callModTool(_ full: String, argumentsJson: String, callId: String?) async -> ToolExecutionResult {
        guard let (record, tool) = resolveTool(full) else {
            return ToolExecutionResult(success: false, output: "", error: "That mod tool is not running.", durationMs: 0)
        }
        let started = CFAbsoluteTimeGetCurrent()
        var event = (try? JSONSerialization.jsonObject(with: Data(argumentsJson.utf8))) as? [String: Any] ?? [:]
        event["tool"] = "mcp__\(record.manifest.name)__\(tool)"
        event["tool_use_id"] = callId ?? ""
        let result = await raise("tool.call", ModRuntime.json(event), timeout: 30) { _ in
            ModRuntime.json(["isError": true, "result": "This tool has no handler.", "text": "This tool has no handler."] as [String: Any])
        }
        let object = Self.object(result) ?? [:]
        let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
        if let deny = object["deny"], !(deny is NSNull) {
            return ToolExecutionResult(success: false, output: "", error: "Blocked by a mod: \((deny as? String) ?? "denied")", durationMs: ms)
        }
        var text = ""
        if let t = object["text"] as? String { text = t }
        else if let r = object["result"] as? String { text = r }
        else if let r = object["result"], let data = try? JSONSerialization.data(withJSONObject: r) { text = String(decoding: data, as: UTF8.self) }
        let isError = (object["isError"] as? Bool) ?? false
        return ToolExecutionResult(success: !isError, output: isError ? "" : text, error: isError ? text : nil, durationMs: ms)
    }

    // MARK: - UI

    /// Coalesce: many `ui.status` calls in a burst should redraw once.
    func markDirty() {
        dirtyTask?.cancel()
        dirtyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            self.publish()
        }
    }

    private func publish() {
        refresh()
        revision &+= 1
        hasBand = hasHook("ui.render") { $0.matcher?["component"]?.string == "AbovePrompt" }
        hasMessageHooks = hasHook("ui.render") {
            ["UserMessage", "AssistantMessage", "ToolUse", "ToolResult", "ToolGroup", "CommandOutput"].contains($0.matcher?["component"]?.string ?? "")
        }
        panes = paneRecords.map { ModPane(id: $0.key, plugin: $0.value.plugin, title: $0.value.title) }.sorted { $0.id < $1.id }
        if let active = activePaneId, !panes.contains(where: { $0.id == active }) { activePaneId = panes.last?.id }
        if activePaneId == nil { activePaneId = panes.last?.id }
        statusLines = statusByPlugin.sorted { $0.key < $1.key }.compactMap { $0.value.isEmpty ? nil : ModStatusLine(plugin: $0.key, text: $0.value) }
        commands = commandRecords.values.sorted { $0.name < $1.name }
    }

    /// Ask the mods to draw a component (`AbovePrompt`, `Pane`, a message …).
    public func render(component: String, requestId: String, props: [String: ModJSON] = [:]) async -> ModRenderResult {
        let anyProps = props.mapValues(\.any)
        let input = ModRuntime.json(["surface": "desktop", "component": component, "requestId": requestId, "viewport": ["columns": 120, "rows": 40], "props": anyProps] as [String: Any])
        let result = await raise("ui.render", input, timeout: 8) { e in
            ModRuntime.json(["type": "engine", "props": Self.object(e)?["props"] ?? [String: Any]()] as [String: Any])
        }
        guard let any = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed]) else { return .none }
        return ModRenderResult.parse(any)
    }

    public func closePane(_ id: String) {
        if let gone = paneRecords.removeValue(forKey: id) {
            rememberPane(plugin: gone.plugin, id: id, title: nil)
            Task { await raiseAll("ui.close", ModRuntime.json(["id": id, "origin": "person"])) }
        }
        markDirty()
    }

    /// A press, a typed value or a choice made on something a mod drew.
    public func press(plugin: String, handle: Int, element: String?, component: String, requestId: String, text: String? = nil, value: String? = nil) async {
        guard let record = records[plugin], record.status == .running, let runtime = record.runtime else { return }
        var arg: [String: Any] = ["plugin": plugin, "component": component, "requestId": requestId, "surface": "desktop"]
        if let element { arg["element"] = element }
        if let text { arg["text"] = text }
        if let value { arg["value"] = value }
        var event: [String: Any] = ["plugin": plugin, "component": component, "requestId": requestId, "surface": "desktop"]
        if let element { event["element"] = element }
        let argJSON = ModRuntime.json(arg)
        _ = await raise("ui.press", ModRuntime.json(event), timeout: 120) { _ in
            let _: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                Task { @MainActor in
                    record.seq += 1
                    let id = record.seq
                    record.pressWaits[id] = continuation
                    runtime.send("{\"t\":\"press\",\"id\":\(id),\"handle\":\(handle),\"arg\":\(argJSON)}")
                }
            }
            return "{}"
        }
        markDirty()
    }

    /// Answer a mod's question.
    public func answer(_ id: String, selection: [String]?) {
        if question?.id == id { question = nil }
        askWaiters.removeValue(forKey: id)?.resume(returning: selection)
    }

    // MARK: - The `$` calls

    private func onRPC(_ record: Record, _ object: [String: Any]) {
        let id = (object["id"] as? NSNumber)?.intValue ?? 0
        let noun = (object["noun"] as? String) ?? "", method = (object["method"] as? String) ?? ""
        let args = (object["args"] as? [Any]) ?? []
        record.rpcCount += 1
        Task { @MainActor in
            defer { record.rpcCount -= 1 }
            var reply: [String: Any] = ["t": "ret", "id": id]
            do { reply["value"] = try await self.service(record, noun, method, args) ?? NSNull() }
            catch { reply["error"] = error.localizedDescription }
            if id != 0 { record.runtime?.send(ModRuntime.json(reply)) }
        }
    }

    struct ServiceError: LocalizedError { var message: String; var errorDescription: String? { message } }

    private func stateKey(_ record: Record, _ ref: [String: Any]) -> String {
        "\(sessionConv.isEmpty ? "_" : sessionConv)|\((ref["plugin"] as? String) ?? record.manifest.name)|\((ref["key"] as? String) ?? "")|\((ref["id"] as? String) ?? "")"
    }

    private func convRows() -> [[String: Any]] { env.messages() }

    private func service(_ record: Record, _ noun: String, _ method: String, _ a: [Any]) async throws -> Any? {
        func str(_ i: Int) -> String { i < a.count ? ((a[i] as? String) ?? "\(a[i])") : "" }
        func dict(_ i: Int) -> [String: Any] { i < a.count ? ((a[i] as? [String: Any]) ?? [:]) : [:] }
        let name = record.manifest.name
        if let declared = record.manifest.permissions, let needed = ModPermission.required(for: "\(noun).\(method)"), !declared.contains(needed.rawValue) {
            appendLog(name, "Refused \(noun).\(method): the mod did not declare “\(needed.rawValue)” under permissions in plugin.json.")
            throw ServiceError(message: "This mod did not declare the “\(needed.rawValue)” permission (\(needed.title.lowercased())) in plugin.json, so it can’t do that.")
        }
        switch "\(noun).\(method)" {
        // display
        case "ui.status":
            let text = (a.first as? String) ?? ""
            if text.isEmpty { statusByPlugin.removeValue(forKey: name) } else { statusByPlugin[name] = String(text.prefix(2000)) }
            markDirty(); return nil
        case "ui.toast": env.toast("\(name): \(String(str(0).prefix(2000)))"); return nil
        case "ui.log": appendLog(name, str(0)); return nil
        case "ui.invalidate": markDirty(); return nil
        case "ui.ask": return try await ask(record, question: str(0), options: a.count > 1 ? a[1] : nil)
        case "ui.notify":
            let title = (dict(1)["title"] as? String) ?? name
            return env.notify(title, str(0)) ? ["isSent": true, "channel": "system"] : ["isSent": false, "reason": "no-channel"]
        case "ui.open":
            let p = dict(0)
            guard let id = p["id"] as? String, !id.isEmpty else { throw ServiceError(message: "ui.open needs an id") }
            paneRecords[id] = (name, (p["title"] as? String) ?? id)
            rememberPane(plugin: name, id: id, title: (p["title"] as? String) ?? id)
            activePaneId = id
            onOpenPane(id)
            markDirty(); return ["isPlaced": true]
        case "ui.close":
            let id = (dict(0)["id"] as? String) ?? ""
            if paneRecords.removeValue(forKey: id) != nil { rememberPane(plugin: name, id: id, title: nil); Task { await raiseAll("ui.close", ModRuntime.json(["id": id, "origin": "plugin"])) } }
            markDirty(); return nil
        case "ui.panes": return paneRecords.map { ["id": $0.key, "title": $0.value.title, "isShown": true, "isFocused": false, "isPlaced": true] as [String: Any] }
        case "ui.copy":
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(str(0), forType: .string); return ["isCopied": true]
        case "ui.scroll", "ui.focus", "ui.view", "ui.blit": return [String: Any]()
        case "ui.selection": return nil
        // session
        case "session.id": return sessionConv.isEmpty ? "swiftopenwork" : sessionConv
        case "session.cwd", "session.root": return env.workspacePath()
        case "session.model": return env.currentModel()
        case "session.turns": return convRows().filter { ($0["role"] as? String) == "user" && !(($0["text"] as? String) ?? "").isEmpty }.count
        case "session.messages": return convRows()
        case "session.repo": return nil
        case "session.surfaces": return ["desktop"]
        case "session.surface": return "desktop"
        case "session.version": return ["version": env.appVersion, "build": "SwiftOpenWork"]
        case "session.usage": return env.usage()
        case "session.identity": return ["name": env.userName, "email": ""]
        case "session.authorize": return ["isAuthorized": true]
        case "session.send", "prompt.submit": env.sendMessage(str(0)); return ["isSent": true]
        case "prompt.fill": env.fillPrompt(str(0)); return nil
        case "prompt.read": return env.readPrompt()
        case "turn.abort": env.abortTurn(); return nil
        // model
        case "model.complete":
            let req = dict(0)
            let prompt = Self.plainText(req["prompt"]), system = Self.plainText(req["system"])
            let tokens = max(16, min(8000, (req["maxTokens"] as? Int) ?? 1500))
            let timeout = TimeInterval((req["timeoutMs"] as? Int) ?? 90_000) / 1000
            if let text = await env.complete(prompt, system.isEmpty ? "You are a helpful assistant." : system, tokens, timeout), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ["isAnswered": true, "text": text, "usage": [String: Any]()]
            }
            return ["isAnswered": false, "reason": "no-answer", "usage": [String: Any]()]
        case "model.fork":
            var transcript = env.transcript()
            guard !transcript.isEmpty else { return ["isAnswered": false, "reason": "nothing-to-fork"] }
            if transcript.count > 300_000 { transcript = "…\n" + transcript.suffix(300_000) }
            let prompt = "Here is the conversation so far:\n\n<conversation>\n\(transcript)\n</conversation>\n\n\(str(0).isEmpty ? Self.plainText(dict(0)["prompt"]) : str(0))"
            if let text = await env.complete(prompt, "You are a helpful assistant.", 4000, 180), !text.isEmpty { return ["isAnswered": true, "text": text, "usage": [String: Any]()] }
            return ["isAnswered": false, "reason": "no-answer"]
        case "model.classify":
            let labels = (a.count > 1 ? a[1] as? [String] : nil) ?? []
            guard !labels.isEmpty else { return nil }
            let prompt = "Classify the text with exactly one of these labels: \(labels.joined(separator: ", ")).\nAnswer with the label only.\n\nText:\n\(str(0))"
            guard let reply = await env.complete(prompt, "You are a helpful assistant.", 20, 30) else { return nil }
            let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return labels.first { answer.contains($0.lowercased()) }
        // tools and commands
        case "tool.register":
            let spec = dict(0)
            guard let toolName = spec["name"] as? String, Self.isPlainName(toolName) else { throw ServiceError(message: "tool names are letters, digits, _ and -") }
            let schemaObject = (spec["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            record.tools[toolName] = ((spec["description"] as? String) ?? "", ModRuntime.json(schemaObject))
            markDirty()
            return ["name": "\(Self.toolPrefix)\(name)__\(toolName)"]
        case "tool.list":
            let builtin = env.builtinToolNames().map { ["name": Self.claudeCall(tool: $0, argumentsJson: "{}").name, "description": "", "mcp": false] as [String: Any] }
            let modTools = toolDefinitions().map { ["name": $0.name, "description": $0.description, "mcp": true] as [String: Any] }
            return builtin + modTools
        case "tool.call":
            let toolName = str(0)
            let argsJson = ModRuntime.json(dict(1))
            let out = await env.runTool(toolName, argsJson)
            return ["text": out.text, "isError": !out.success]
        case "tool.check": return ["isAllowed": true]
        case "command.register":
            let spec = dict(0)
            guard let commandName = spec["name"] as? String, Self.isPlainName(commandName) else { throw ServiceError(message: "command names are letters, digits, _ and -") }
            commandRecords["\(name):\(commandName)"] = ModCommand(plugin: name, name: commandName, description: (spec["description"] as? String) ?? "", argumentHint: (spec["argumentHint"] as? String) ?? "")
            markDirty(); return [String: Any]()
        case "command.list":
            let builtin = env.builtinCommands().map { ["name": $0, "description": "", "source": "builtin"] as [String: Any] }
            let custom = commandRecords.values.map { ["name": $0.name, "description": $0.description, "source": "plugin", "plugin": $0.plugin] as [String: Any] }
            return builtin + custom
        case "agent.list":
            return subAgents.values.sorted { $0.startedAt < $1.startedAt }.map {
                ["id": $0.id, "name": $0.description, "description": $0.description, "type": $0.type, "model": $0.model, "status": $0.status] as [String: Any]
            }
        // files
        case "fs.read":
            guard let text = try? String(contentsOfFile: mapPath(str(0)), encoding: .utf8) else { throw ServiceError(message: "Cannot read \(str(0))") }
            return text
        case "fs.write":
            let path = mapPath(str(0))
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try str(1).write(toFile: path, atomically: true, encoding: .utf8); return nil
        case "fs.exists": return FileManager.default.fileExists(atPath: mapPath(str(0)))
        case "fs.mkdir": try FileManager.default.createDirectory(atPath: mapPath(str(0)), withIntermediateDirectories: true); return nil
        case "fs.remove": try FileManager.default.removeItem(atPath: mapPath(str(0))); return nil
        case "fs.list": return try listDir(a.isEmpty ? env.workspacePath() : str(0))
        case "fs.stat":
            let path = mapPath(str(0))
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let type = attrs[.type] as? FileAttributeType
            let resolved = (try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)) ?? attrs
            let kind = (resolved[.type] as? FileAttributeType) == .typeDirectory ? "dir" : (resolved[.type] as? FileAttributeType) == .typeRegular ? "file" : "other"
            return ["kind": kind, "size": (attrs[.size] as? Int) ?? 0, "mtimeMs": ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000, "isLink": type == .typeSymbolicLink]
        // storage
        case "store.get": return storeRead()[name]?[str(0)]
        case "store.set": var s = storeRead(); var mine = s[name] ?? [:]; mine[str(0)] = a.count > 1 ? a[1] : NSNull(); s[name] = mine; storeWrite(s); return nil
        case "store.delete": var s = storeRead(); s[name]?.removeValue(forKey: str(0)); storeWrite(s); return nil
        case "store.keys": return Array((storeRead()[name] ?? [:]).keys).sorted()
        case "state.get":
            let v = state[stateKey(record, dict(0))]
            // A key never set has no `value` at all, so a mod's default (`read` falls back on undefined) applies.
            guard let v else { return ["version": 0] as [String: Any] }
            return ["value": v.value, "version": v.version] as [String: Any]
        case "state.set":
            let key = stateKey(record, dict(0)); let current = state[key]
            if let want = dict(2)["ifVersion"] as? Int, (current?.version ?? 0) != want { return ["isApplied": false, "version": current?.version ?? 0] }
            let next = (value: a.count > 1 ? a[1] : NSNull(), version: (current?.version ?? 0) + 1)
            state[key] = next
            markDirty(); return ["isApplied": true, "version": next.version]
        // environment
        case "env.get": return ProcessInfo.processInfo.environment[str(0)]
        case "env.set": return ["isApplied": false]
        case "settings.read": return [String: Any]()
        case "process.run": return await runProcess(argvAny: a.first, options: dict(1))
        case "mcp.call": return ["text": await env.mcpCall(str(0), str(1), ModRuntime.json(dict(2)))]
        case "http.fetch": return await fetch(urlText: str(0), options: dict(1))
        case "audio.speak": Self.speak(str(0)); return [String: Any]()
        case "audio.play": if let sound = NSSound(contentsOfFile: mapPath(str(0)), byReference: true) { sound.play() }; return [String: Any]()
        default:
            unsupportedCalls[name, default: []].insert("\(noun).\(method)")
            markDirty()
            throw ServiceError(message: "$.\(noun).\(method) is not available in SwiftOpenWork")
        }
    }

    nonisolated static func isPlainName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0 == "_" || $0 == "-" }
    }

    nonisolated static func plainText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let list = value as? [[String: Any]] { return list.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }

    @MainActor private static let speaker = AVSpeechSynthesizer()
    private static func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speaker.speak(AVSpeechUtterance(string: text))
    }

    // MARK: - Ask

    private func ask(_ record: Record, question text: String, options raw: Any?) async throws -> Any? {
        var options: [String] = []
        var header: String?
        var multi = false
        if let list = raw as? [Any] { options = list.map { ($0 as? [String: Any])?["label"] as? String ?? "\($0)" } }
        else if let spec = raw as? [String: Any] {
            options = ((spec["options"] as? [Any]) ?? []).map { ($0 as? [String: Any])?["label"] as? String ?? "\($0)" }
            header = spec["header"] as? String
            multi = (spec["multiSelect"] as? Bool) ?? false
        }
        let id = UUID().uuidString
        let asked = ModQuestion(id: id, plugin: record.manifest.name, question: text, header: header, options: options, multiSelect: multi)
        let selection: [String]? = await withCheckedContinuation { continuation in
            askWaiters[id] = continuation
            if question == nil { question = asked } else { pendingQuestions.append(asked) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
                self.answer(id, selection: nil)
            }
        }
        if let next = pendingQuestions.first, question == nil { pendingQuestions.removeFirst(); question = next }
        guard let selection else { throw ServiceError(message: "dismissed") }
        return multi ? selection : (selection.first ?? "")
    }

    private var pendingQuestions: [ModQuestion] = []

    // MARK: - Shared home paths

    /// Mods find their shared home (settings, open requests) by cutting their own root at "/.claude/".
    /// A mod in this app's folder sees itself at ~/.claude/mods/<folder>; these paths map that view
    /// back to the real folder, and `~/.claude/mods-data` to this app's own data folder, so nothing is
    /// written under ~/.claude.
    func mapPath(_ raw: String) -> String {
        let p = raw
        let data = ModPaths.claudeModsData, mods = ModPaths.claudeMods
        if p == data || p.hasPrefix(data + "/") { return ModPaths.nativeData + p.dropFirst(data.count) }
        guard p.hasPrefix(mods + "/") else { return p }
        let rest = String(p.dropFirst(mods.count + 1))
        let first = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        if first == "switches.json" || first.hasPrefix(".open-") { return (ModPaths.nativeDir as NSString).appendingPathComponent(rest) }
        if first.isEmpty || FileManager.default.fileExists(atPath: (mods as NSString).appendingPathComponent(first)) { return p }
        for dir in [ModPaths.nativeDir, ModPaths.grizzyDir] where FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(first)) {
            return (dir as NSString).appendingPathComponent(rest)
        }
        return p
    }

    private func listDir(_ raw: String) throws -> [[String: Any]] {
        let real = mapPath(raw)
        var names: [String] = []
        do { names = try FileManager.default.contentsOfDirectory(atPath: real) }
        catch { if URL(fileURLWithPath: real).standardizedFileURL.path != ModPaths.claudeMods { throw error } }
        var rows: [[String: Any]] = names.map { item in
            let path = (real as NSString).appendingPathComponent(item)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return ["name": item, "kind": isDir.boolValue ? "dir" : ((attrs?[.type] as? FileAttributeType) == .typeRegular || isLink ? "file" : "other"),
                    "size": (attrs?[.size] as? Int) ?? 0, "mtimeMs": ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000, "isLink": isLink]
        }
        if URL(fileURLWithPath: real).standardizedFileURL.path == ModPaths.claudeMods {
            for dir in [ModPaths.nativeDir, ModPaths.grizzyDir] {
                for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(item + "/.claude-plugin/plugin.json")) {
                    if !rows.contains(where: { ($0["name"] as? String) == item }) { rows.append(["name": item, "kind": "dir", "size": 0, "mtimeMs": 0, "isLink": true]) }
                }
            }
        }
        return rows
    }

    // MARK: - Mod storage

    private func storeRead() -> [String: [String: Any]] {
        ((ModDiscovery.readJSON(ModPaths.storeFile)) as? [String: [String: Any]]) ?? [:]
    }

    private func storeWrite(_ store: [String: [String: Any]]) {
        try? FileManager.default.createDirectory(atPath: (ModPaths.storeFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if JSONSerialization.isValidJSONObject(store), let data = try? JSONSerialization.data(withJSONObject: store) {
            try? data.write(to: URL(fileURLWithPath: ModPaths.storeFile))
        }
    }
}

extension ModJSON {
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }
}


/// The subagent a piece of work belongs to, so the tool calls and requests it makes are attributed to it.
public enum ModAgentContext {
    @TaskLocal public static var id: String?
}
