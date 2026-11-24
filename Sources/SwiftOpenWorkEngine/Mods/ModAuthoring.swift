import Foundation

/// Making, installing, exporting, publishing and removing mods. Everything this app creates or
/// installs lives in its own folder (`~/.swiftopenwork/mods`); nothing here writes to Claude Code's
/// plugin folders or to a marketplace unless the person picks that marketplace folder to publish to.
public enum ModAuthoring {
    public struct Outcome: Sendable, Equatable {
        public var ok: Bool
        public var name: String = ""
        public var path: String = ""
        public var replaced = false
        public var unchanged = false
        public var error: String?
        public var installLines: [String] = []
        public var marketName: String = ""
    }

    /// What the agent is told when asked to make or install a mod. Kept short; `docs/MODS.md` has the full guide.
    public static let agentGuide = """
    Mods: if asked to build or install a mod for this app, put it in ~/.swiftopenwork/mods/<name>/ (lowercase letters, digits and dashes; not the name of an existing mod). Never write into ~/.claude, a marketplace folder or another mod, and never use `claude plugin install`: writing the folder is the install. Keep its saved data in ~/.swiftopenwork/mods-data/<name>/ or use $.store.
    Layout: .claude-plugin/plugin.json {"name","version","description"}; hooks/hooks.json {"modules": ["./register.tsx"]}; hooks/register.tsx exporting `register = (on) => { on('<event>', [matcher], async ($, e, next) => result) }`. Events: session.start, prompt.submit, prompt.compose, command.run, tool.call, turn.start, turn.step, turn.complete, ui.render, ui.press. `await next(e)` runs the rest of the chain; return a value to answer. Register a slash command in session.start with $.command.register({name, description}) and answer it with on('command.run', {command: name}, ...) returning {text}. A tool: $.tool.register({name, description, inputSchema}) then on('tool.call', {tool: 'mcp__<mod>__<name>'}, ...) returning {text}. `$` has ui, session, model, fs, process, http, store, state, clock, command, tool, mcp. The code runs sandboxed: no Node, eval or package imports; TypeScript and JSX are fine. Settings → Mods turns it on and reloads it when a file is saved.
    """

    private static func failure(_ message: String) -> Outcome { Outcome(ok: false, error: message) }

    // Mod names become folder names and part of tool names, so they stay plain.
    private static let nameRule = try! NSRegularExpression(pattern: "^[a-z0-9]+(-[a-z0-9]+)*$")
    public static func isValidName(_ name: String) -> Bool {
        name.count >= 2 && name.count <= 40
            && nameRule.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastDash = true
        for scalar in lowered.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) { out.unicodeScalars.append(scalar); lastDash = false }
            else if !lastDash { out += "-"; lastDash = true }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func template(name: String, description: String) -> String {
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [description]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        import type { Register } from 'claude-code'

        // \(name): \(description)
        // A mod is a function that hooks into events: on('<event>', [matcher], async ($, event, next) => result).
        // `$` is the app: $.ui (toast, status, ask, open), $.session, $.model, $.fs, $.process, $.http,
        // $.store, $.clock, $.command, $.tool.
        // `await next(event)` lets the rest of the chain run; return a value to answer instead.

        export const register: Register = (on) => {
          // Make /\(name) show up in the slash menu.
          on('session.start', async ($, e, next) => {
            await $.command.register({ name: '\(name)', description: \(quoted) })
            return next(e)
          })

          // Run it.
          on('command.run', { command: '\(name)' }, async ($, e) => {
            const turns = await $.session.turns()
            $.ui.toast('\(name) ran')
            return { text: `\(name) is working. This chat has ${turns} turn(s). You typed: ${e.args || '(nothing)'}` }
          })
        }

        """
    }

    /// Scaffolds a working mod in this app's mods folder. `taken` are names already in use from any
    /// source, so a new mod can never shadow or overwrite one that came from elsewhere.
    public static func create(name rawName: String, description rawDescription: String, taken: [String] = [], directory: String? = nil) -> Outcome {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return failure("Give the mod a name.") }
        if !isValidName(name) { return failure("Use lowercase letters, digits and single dashes, 2–40 characters (for example “my-mod”).") }
        if taken.contains(name) { return failure("A mod called “\(name)” already exists. Pick another name.") }
        let dir = directory ?? ModPaths.nativeDir
        let root = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: root) { return failure("The folder \(root) already exists.") }
        var description = rawDescription.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        description = String(description.prefix(300))
        if description.isEmpty { description = "The \(name) mod" }
        do {
            let fm = FileManager.default
            try fm.createDirectory(atPath: (root as NSString).appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
            try fm.createDirectory(atPath: (root as NSString).appendingPathComponent("hooks"), withIntermediateDirectories: true)
            let manifest: [String: Any] = ["name": name, "version": "0.1.0", "description": description, "author": ["name": NSUserName()]]
            try writeJSON(manifest, to: (root as NSString).appendingPathComponent(".claude-plugin/plugin.json"))
            try writeJSON(["modules": ["./register.tsx"]], to: (root as NSString).appendingPathComponent("hooks/hooks.json"))
            try template(name: name, description: description).write(toFile: (root as NSString).appendingPathComponent("hooks/register.tsx"), atomically: true, encoding: .utf8)
            try "# \(name)\n\n\(description)\n\nEdit `hooks/register.tsx`; the app reloads the mod when you save it.\n"
                .write(toFile: (root as NSString).appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(atPath: root)
            return failure("Could not create the mod: \(error.localizedDescription)")
        }
        return Outcome(ok: true, name: name, path: root)
    }

    private static func writeJSON(_ object: Any, to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Install

    private static let skipped: Set<String> = [".DS_Store", "node_modules", ".git"]

    /// Copy a mod folder, leaving out junk and links.
    static func copyMod(from: String, to: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: to, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: from) where !skipped.contains(item) {
            let a = (from as NSString).appendingPathComponent(item), b = (to as NSString).appendingPathComponent(item)
            let attrs = try fm.attributesOfItem(atPath: a)
            switch attrs[.type] as? FileAttributeType {
            case .typeSymbolicLink: continue
            case .typeDirectory: try copyMod(from: a, to: b)
            default: try fm.copyItem(atPath: a, toPath: b)
            }
        }
    }

    private static func inside(_ child: String, of parent: String) -> Bool {
        let c = URL(fileURLWithPath: child).standardizedFileURL.path, p = URL(fileURLWithPath: parent).standardizedFileURL.path
        return c != p && c.hasPrefix(p + "/")
    }

    private static let safeFolder = try! NSRegularExpression(pattern: "^[A-Za-z0-9][\\w.-]{0,63}$")

    /// Install a mod from a folder, or from a `.zip` / `.plugin` archive.
    public static func install(from source: String, directory: String? = nil) -> Outcome {
        let fm = FileManager.default
        let dir = directory ?? ModPaths.nativeDir
        var temp: String?
        defer { if let temp { try? fm.removeItem(atPath: temp) } }
        var root = source
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &isDir) else { return failure("That file is gone.") }
        if !isDir.boolValue {
            let scratch = NSTemporaryDirectory() + "swiftopenwork-mod-" + UUID().uuidString
            temp = scratch
            do { try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true) } catch { return failure(error.localizedDescription) }
            let result = run("/usr/bin/unzip", ["-q", "-o", source, "-d", scratch])
            guard result.status == 0 else { return failure("Could not open that archive as a zip: \(result.output.prefix(200))") }
            guard let found = findRoot(in: scratch) else { return failure("That isn’t a mod: it needs .claude-plugin/plugin.json and hooks/hooks.json with a module.") }
            root = found
        }
        guard let mod = ModDiscovery.inspect(root: root, source: ModPaths.nativeSource) else {
            return failure("That isn’t a mod: it needs .claude-plugin/plugin.json and hooks/hooks.json with a module.")
        }
        let folder = mod.name.replacingOccurrences(of: "[^\\w.-]", with: "-", options: .regularExpression)
        guard safeFolder.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)) != nil, !folder.allSatisfy({ $0 == "." }) else {
            return failure("“\(mod.name)” can’t be used as a mod name.")
        }
        let dest = (dir as NSString).appendingPathComponent(folder)
        if URL(fileURLWithPath: root).standardizedFileURL.path == URL(fileURLWithPath: dest).standardizedFileURL.path {
            return Outcome(ok: true, name: mod.name, path: dest, unchanged: true)
        }
        if inside(dir, of: root) { return failure("Pick the mod’s own folder, not a folder that contains your mods.") }
        let replaced = fm.fileExists(atPath: dest)
        let stage = dest + ".new-\(getpid())"
        try? fm.removeItem(atPath: stage)
        defer { try? fm.removeItem(atPath: stage) }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try copyMod(from: root, to: stage)
            try? fm.removeItem(atPath: dest)
            try fm.moveItem(atPath: stage, toPath: dest)
        } catch { return failure("Could not install the mod: \(error.localizedDescription)") }
        return Outcome(ok: true, name: mod.name, path: dest, replaced: replaced)
    }

    /// The folder holding `.claude-plugin/plugin.json`, at the top of an extracted archive or a level or two down.
    private static func findRoot(in directory: String, depth: Int = 0) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: (directory as NSString).appendingPathComponent(".claude-plugin/plugin.json")) { return directory }
        guard depth < 3 else { return nil }
        for item in ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).sorted() where item != "__MACOSX" {
            let child = (directory as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue, let found = findRoot(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - Export, publish, remove

    /// Zip a mod so it can be shared: this app's “Install from folder or .zip” and Claude Code's
    /// plugin loader both read the layout, with the mod's files at the top level.
    public static func exportZip(root: String, to file: String) -> Outcome {
        try? FileManager.default.removeItem(atPath: file)
        let result = run("/usr/bin/zip", ["-q", "-r", "-X", URL(fileURLWithPath: file).path, ".", "-x", "*.DS_Store", "-x", "node_modules/*", "-x", ".git/*"], cwd: root)
        guard result.status == 0 else { return failure("Could not create the zip: \(result.output.prefix(200))") }
        return Outcome(ok: true, path: file)
    }

    public struct PublishPlan: Sendable, Equatable {
        public var marketName: String
        public var isNew: Bool
        public var replaces: Bool
        public var folder: String
        public var error: String?
    }

    private static func marketFile(_ dir: String) -> String { (dir as NSString).appendingPathComponent(".claude-plugin/marketplace.json") }

    /// What a publish would touch, for the confirmation. Nothing is written.
    public static func planPublish(name: String, marketDir: String) -> PublishPlan {
        let file = marketFile(marketDir)
        let folder = (marketDir as NSString).appendingPathComponent("plugins/" + name)
        var market: [String: Any]?
        if FileManager.default.fileExists(atPath: file) {
            guard let parsed = ModDiscovery.readJSON(file), parsed["plugins"] is [Any] else {
                return PublishPlan(marketName: "", isNew: false, replaces: false, folder: folder, error: "That folder’s marketplace.json is not valid, so nothing was changed.")
            }
            market = parsed
        }
        let listed = ((market?["plugins"] as? [[String: Any]]) ?? []).contains { ($0["name"] as? String) == name }
        return PublishPlan(
            marketName: (market?["name"] as? String) ?? (slug((marketDir as NSString).lastPathComponent).isEmpty ? "my-mods" : slug((marketDir as NSString).lastPathComponent)),
            isNew: market == nil, replaces: listed || FileManager.default.fileExists(atPath: folder), folder: folder, error: nil
        )
    }

    /// Put the mod into a marketplace folder (`plugins/<name>` plus an entry in `marketplace.json`):
    /// the layout `/plugin marketplace add <folder>` reads in Claude Code. Returns the lines to share.
    public static func publish(name: String, version: String, description: String, root: String, marketDir rawMarket: String) -> Outcome {
        let fm = FileManager.default
        let marketDir = URL(fileURLWithPath: rawMarket).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: marketDir, isDirectory: &isDir), isDir.boolValue else { return failure("That marketplace folder doesn’t exist.") }
        let plan = planPublish(name: name, marketDir: marketDir)
        if let error = plan.error { return failure(error) }
        guard safeFolder.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { return failure("“\(name)” can’t be published under that name.") }
        let modRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        if modRoot == plan.folder { return failure("This mod already lives in that marketplace.") }
        if inside(marketDir, of: modRoot) || inside(modRoot, of: plan.folder) { return failure("Pick a marketplace folder that is separate from the mod’s own folder.") }
        var market: [String: Any] = ["name": plan.marketName, "owner": ["name": NSUserName()], "description": "", "plugins": [Any]()]
        if !plan.isNew, let existing = ModDiscovery.readJSON(marketFile(marketDir)) { market = existing }
        let stage = plan.folder + ".new-\(getpid())"
        try? fm.removeItem(atPath: stage)
        defer { try? fm.removeItem(atPath: stage) }
        do {
            try fm.createDirectory(atPath: (marketDir as NSString).appendingPathComponent("plugins"), withIntermediateDirectories: true)
            try copyMod(from: modRoot, to: stage)
            try? fm.removeItem(atPath: plan.folder)
            try fm.moveItem(atPath: stage, toPath: plan.folder)
        } catch { return failure("Could not copy the mod: \(error.localizedDescription)") }
        var plugins = ((market["plugins"] as? [[String: Any]]) ?? []).filter { ($0["name"] as? String) != name }
        plugins.append(["name": name, "source": "./plugins/\(name)", "description": description, "version": version.isEmpty ? "0.1.0" : version])
        plugins.sort { (($0["name"] as? String) ?? "") < (($1["name"] as? String) ?? "") }
        market["plugins"] = plugins
        do {
            try fm.createDirectory(atPath: (marketFile(marketDir) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try writeJSON(market, to: marketFile(marketDir))
        } catch { return failure("Could not write marketplace.json: \(error.localizedDescription)") }
        let marketName = (market["name"] as? String) ?? plan.marketName
        return Outcome(ok: true, name: name, path: plan.folder, replaced: plan.replaces,
                       installLines: ["/plugin marketplace add \(marketDir)", "/plugin install \(name)@\(marketName)"], marketName: marketName)
    }

    /// Only mods in this app's own folder can be removed here.
    public static func remove(root: String, directory: String? = nil) -> Outcome {
        let dir = URL(fileURLWithPath: directory ?? ModPaths.nativeDir).standardizedFileURL.path
        let path = URL(fileURLWithPath: root).standardizedFileURL.path
        guard (path as NSString).deletingLastPathComponent == dir else {
            return failure("Only mods in this app’s mods folder can be removed here. Remove Claude Code plugins in Claude Code.")
        }
        do { try FileManager.default.removeItem(atPath: path) } catch { return failure(error.localizedDescription) }
        return Outcome(ok: true, path: path)
    }

    // MARK: - Processes

    static func run(_ tool: String, _ arguments: [String], cwd: String? = nil) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
