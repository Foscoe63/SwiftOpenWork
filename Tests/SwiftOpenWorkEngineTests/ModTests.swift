import XCTest
@testable import SwiftOpenWorkEngine
@testable import SwiftOpenWorkCore

/// Mods run real TypeScript in JavaScriptCore, so these tests write small mods to a scratch home
/// folder and drive them through the host the way the app does.
@MainActor
final class ModTests: XCTestCase {
    var home: String!

    override func setUp() async throws {
        home = NSTemporaryDirectory() + "mods-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        ModPaths.homeOverride = home
    }

    override func tearDown() async throws {
        await ModHost.shared.stopAll()
        ModPaths.homeOverride = nil
        try? FileManager.default.removeItem(atPath: home)
    }

    /// Write a mod whose register.tsx is `source`, and turn it on.
    @discardableResult
    func makeMod(_ name: String = "probe", _ source: String) async throws -> ModManifest {
        let created = ModAuthoring.create(name: name, description: "test mod")
        XCTAssertTrue(created.ok, created.error ?? "")
        try source.write(toFile: (created.path as NSString).appendingPathComponent("hooks/register.tsx"), atomically: true, encoding: .utf8)
        let manifest = try XCTUnwrap(ModHost.shared.manifest(named: name))
        await ModHost.shared.start(manifest)
        return manifest
    }

    func testScaffoldedModLoadsAndAnswersItsCommand() async throws {
        try await makeMod("hello", ModAuthoring.template(name: "hello", description: "says hello"))
        let info = try XCTUnwrap(ModHost.shared.mods.first { $0.name == "hello" } ?? { ModHost.shared.refresh(); return ModHost.shared.mods.first { $0.name == "hello" } }())
        XCTAssertEqual(info.status, .running, info.error ?? "")
        try await Task.sleep(nanoseconds: 300_000_000)
        let reply = await ModHost.shared.runCommand(plugin: "hello", name: "hello", args: "world")
        XCTAssertTrue(reply.contains("You typed: world"), reply)
    }

    func testPromptSubmitCanRewriteAndDrop() async throws {
        try await makeMod("rewrite", """
        export const register = (on) => {
          on('prompt.submit', async ($, e, next) => {
            if (e.text.startsWith('drop')) return { drop: 'dropped by mod' }
            return next({ ...e, text: e.text.toUpperCase() })
          })
        }
        """)
        let upper = await ModHost.shared.promptSubmit("hello")
        XCTAssertEqual(upper, .text("HELLO"))
        let dropped = await ModHost.shared.promptSubmit("drop it")
        XCTAssertEqual(dropped, .drop("dropped by mod"))
    }

    func testToolCallHookDeniesAndRewrites() async throws {
        try await makeMod("guard", """
        export const register = (on) => {
          on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
            if (String(e.command).includes('rm -rf')) return { deny: 'no recursive deletes' }
            return next(e)
          })
          on('tool.call', { tool: 'Read' }, async ($, e, next) => {
            const r = await next(e)
            return { ...r, text: r.text.replace('secret', '[redacted]') }
          })
        }
        """)
        let denied = await ModHost.shared.wrapToolCall(toolName: "terminal_command", argumentsJson: #"{"command":"rm -rf /tmp/x"}"#, callId: "1") {
            XCTFail("a denied call must not run")
            return ToolExecutionResult(success: true, output: "ran")
        }
        XCTAssertFalse(denied.success)
        XCTAssertTrue(denied.error?.contains("no recursive deletes") == true)

        let allowed = await ModHost.shared.wrapToolCall(toolName: "terminal_command", argumentsJson: #"{"command":"ls"}"#, callId: "2") {
            ToolExecutionResult(success: true, output: "listing")
        }
        XCTAssertTrue(allowed.success)
        XCTAssertEqual(allowed.output, "listing")

        let redacted = await ModHost.shared.wrapToolCall(toolName: "file_read", argumentsJson: #"{"path":"a.txt"}"#, callId: "3") {
            ToolExecutionResult(success: true, output: "the secret is 4")
        }
        XCTAssertEqual(redacted.output, "the [redacted] is 4")
    }

    func testModToolsAreOfferedAndCallable() async throws {
        try await makeMod("toolbox", """
        export const register = (on) => {
          on('session.start', async ($, e, next) => {
            await $.tool.register({ name: 'add', description: 'adds', inputSchema: { type: 'object', properties: { a: { type: 'number' }, b: { type: 'number' } } } })
            return next(e)
          })
          on('tool.call', { tool: 'mcp__toolbox__add' }, async ($, e) => ({ text: String(e.a + e.b) }))
        }
        """)
        try await Task.sleep(nanoseconds: 400_000_000)
        let defs = ModHost.shared.toolDefinitions()
        XCTAssertEqual(defs.map(\.name), ["mod__toolbox__add"])
        XCTAssertTrue(ModHost.shared.isModTool("mod__toolbox__add"))
        let result = await ModHost.shared.callModTool("mod__toolbox__add", argumentsJson: #"{"a":2,"b":3}"#, callId: "x")
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(result.output, "5")
    }

    func testStoreProcessAndRenderServices() async throws {
        try await makeMod("services", """
        export const register = (on) => {
          on('command.run', { command: 'go' }, async ($) => {
            await $.store.set('k', { n: 7 })
            const back = await $.store.get('k')
            const p = await $.process.run(['/bin/echo', 'hi'])
            return { text: `${back.n}:${p.stdout.trim()}:${p.exitCode}` }
          })
          on('ui.render', { component: 'AbovePrompt' }, async ($, e) => {
            const { Box, Text } = $.ui.resolve(e)
            return <Box><Text bold>drawn</Text></Box>
          })
        }
        """)
        let reply = await ModHost.shared.runCommand(plugin: "services", name: "go", args: "")
        XCTAssertEqual(reply, "7:hi:0")
        let drawn = await ModHost.shared.render(component: "AbovePrompt", requestId: "band")
        guard case .tree(let node) = drawn, case .element(let box) = node else { return XCTFail("expected a tree, got \(drawn)") }
        XCTAssertEqual(box.type, "Box")
        guard case .element(let text)? = box.children.first else { return XCTFail("no child") }
        XCTAssertEqual(text.type, "Text")
        XCTAssertEqual(text.children, [.text("drawn")])
    }

    func testAModThatThrowsOnLoadIsMarkedFailed() async throws {
        try await makeMod("broken", "export const register = () => { throw new Error('nope') }")
        ModHost.shared.refresh()
        let info = try XCTUnwrap(ModHost.shared.mods.first { $0.name == "broken" })
        XCTAssertEqual(info.status, .failed)
        XCTAssertTrue(info.error?.contains("nope") == true, info.error ?? "")
    }

    func testModCannotImportPackagesOrReachOutsideItsFolder() async throws {
        try await makeMod("escape", "import fs from 'fs'\nexport const register = () => { fs.readFileSync('/etc/passwd') }")
        ModHost.shared.refresh()
        XCTAssertEqual(ModHost.shared.mods.first { $0.name == "escape" }?.status, .failed)
    }

    // MARK: - Authoring

    func testCreateRejectsBadAndTakenNames() {
        XCTAssertNotNil(ModAuthoring.create(name: "Bad Name", description: "").error)
        XCTAssertNotNil(ModAuthoring.create(name: "x", description: "").error)
        XCTAssertTrue(ModAuthoring.create(name: "good-name", description: "d").ok)
        XCTAssertNotNil(ModAuthoring.create(name: "good-name", description: "d").error)
        XCTAssertNotNil(ModAuthoring.create(name: "other", description: "d", taken: ["other"]).error)
    }

    func testExportInstallRoundTripAndPublish() throws {
        let made = ModAuthoring.create(name: "roundtrip", description: "r")
        XCTAssertTrue(made.ok)
        let zip = home + "/roundtrip.zip"
        XCTAssertTrue(ModAuthoring.exportZip(root: made.path, to: zip).ok)

        let elsewhere = home + "/elsewhere"
        let installed = ModAuthoring.install(from: zip, directory: elsewhere)
        XCTAssertTrue(installed.ok, installed.error ?? "")
        XCTAssertEqual(installed.name, "roundtrip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere + "/roundtrip/hooks/register.tsx"))
        XCTAssertTrue(ModAuthoring.install(from: zip, directory: elsewhere).replaced)

        let market = home + "/market"
        try FileManager.default.createDirectory(atPath: market, withIntermediateDirectories: true)
        let published = ModAuthoring.publish(name: "roundtrip", version: "0.1.0", description: "r", root: made.path, marketDir: market)
        XCTAssertTrue(published.ok, published.error ?? "")
        XCTAssertEqual(published.installLines.count, 2)
        let listing = try XCTUnwrap(ModDiscovery.readJSON(market + "/.claude-plugin/marketplace.json"))
        XCTAssertEqual((listing["plugins"] as? [[String: Any]])?.first?["name"] as? String, "roundtrip")
    }

    func testRemoveOnlyTouchesTheAppsOwnFolder() {
        let made = ModAuthoring.create(name: "removable", description: "d")
        XCTAssertFalse(ModAuthoring.remove(root: home + "/somewhere/else").ok)
        XCTAssertTrue(ModAuthoring.remove(root: made.path).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
    }

    func testChangedExternalModIsHeldForReview() async throws {
        // A mod from another place that changed since it was switched on does not start unseen.
        let source = home + "/.GrizzyCode/mods/outside"
        try FileManager.default.createDirectory(atPath: source + "/.claude-plugin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: source + "/hooks", withIntermediateDirectories: true)
        try #"{"name":"outside","version":"1","description":"d"}"#.write(toFile: source + "/.claude-plugin/plugin.json", atomically: true, encoding: .utf8)
        try #"{"modules":["./r.ts"]}"#.write(toFile: source + "/hooks/hooks.json", atomically: true, encoding: .utf8)
        try "export const register = () => {}".write(toFile: source + "/hooks/r.ts", atomically: true, encoding: .utf8)
        _ = await ModHost.shared.setEnabled("outside", true)
        await ModHost.shared.stopAll()
        try "export const register = () => { /* changed */ }".write(toFile: source + "/hooks/r.ts", atomically: true, encoding: .utf8)
        await ModHost.shared.startEnabled()
        ModHost.shared.refresh()
        XCTAssertEqual(ModHost.shared.mods.first { $0.name == "outside" }?.status, .needsReview)
    }
}

/// Mods made for GrizzyCode and Claude Code are the same format; this loads the ones on this Mac
/// against the real engine, so a regression in compatibility shows up here. Skipped where there are none.
@MainActor
final class ModCompatibilityTests: XCTestCase {
    func testEveryGrizzyCodeModOnThisMacLoads() async throws {
        let dir = NSHomeDirectory() + "/.GrizzyCode/mods"
        let manifests = ModDiscovery.discover().filter { $0.root.hasPrefix(dir) }
        try XCTSkipIf(manifests.isEmpty, "no GrizzyCode mods installed")
        for manifest in manifests {
            await ModHost.shared.start(manifest)
            ModHost.shared.refresh()
            let info = ModHost.shared.mods.first { $0.name == manifest.name }
            XCTAssertEqual(info?.status, .running, "\(manifest.name): \(info?.error ?? "")")
        }
        await ModHost.shared.stopAll()
    }
}
