import Foundation
import CryptoKit
import SwiftOpenWorkCore

/// Where mods live and how they are found.
///
/// A mod is Claude Code's own format — `.claude-plugin/plugin.json` plus `hooks/hooks.json` naming
/// the modules to load — so one mod serves Claude Code, GrizzyCode and this app. Three places are
/// read: this app's folder (`~/.swiftopenwork/mods`, where new and installed mods go), Claude Code's
/// plugin installs, and GrizzyCode's folder. The last two are only ever read.
enum ModPaths {
    static let nativeSource = "SwiftOpenWork"
    static let claudeSource = "Claude Code"
    static let grizzySource = "GrizzyCode"

    nonisolated(unsafe) static var homeOverride: String?
    static var home: String { homeOverride ?? FileManager.default.homeDirectoryForCurrentUser.path }
    static func path(_ parts: String...) -> String { parts.reduce(home) { ($0 as NSString).appendingPathComponent($1) } }

    static var nativeDir: String { path(".swiftopenwork", "mods") }
    static var nativeData: String { path(".swiftopenwork", "mods-data") }
    static var storeFile: String { path(".swiftopenwork", "mods-store.json") }
    static var switchesFile: String { (nativeDir as NSString).appendingPathComponent("switches.json") }
    static var trustFile: String { (nativeDir as NSString).appendingPathComponent("trust.json") }
    static var grizzyDir: String { path(".GrizzyCode", "mods") }
    static var claudePlugins: String { path(".claude", "plugins", "installed_plugins.json") }
    /// Where a mod written for Claude Code believes its shared home is.
    static var claudeMods: String { path(".claude", "mods") }
    static var claudeModsData: String { path(".claude", "mods-data") }
}

enum ModDiscovery {
    static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A folder is a mod when it has a manifest and a hooks file naming modules that exist inside it.
    static func inspect(root: String, source: String, pluginId: String? = nil) -> ModManifest? {
        guard let manifest = readJSON((root as NSString).appendingPathComponent(".claude-plugin/plugin.json")),
              let name = manifest["name"] as? String, !name.isEmpty,
              let hooks = readJSON((root as NSString).appendingPathComponent("hooks/hooks.json")),
              let modules = hooks["modules"] as? [Any], !modules.isEmpty else { return nil }
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        let hooksDir = (base as NSString).appendingPathComponent("hooks")
        var entries: [String] = []
        for module in modules {
            guard let spec = module as? String else { return nil }
            let path = ((hooksDir as NSString).appendingPathComponent(spec) as NSString).standardizingPath
            guard path.hasPrefix(base + "/"), FileManager.default.fileExists(atPath: path) else { return nil }
            entries.append(path)
        }
        var options: [String: Any] = [:]
        for (key, def) in (manifest["userConfig"] as? [String: Any]) ?? [:] {
            if let def = def as? [String: Any], let value = def["default"] { options[key] = value }
        }
        return ModManifest(
            name: name,
            version: (manifest["version"] as? String) ?? "",
            description: (manifest["description"] as? String) ?? "",
            root: base, entries: entries, source: source,
            optionsJSON: ModRuntime.json(options), pluginId: pluginId
        )
    }

    static func discover() -> [ModManifest] {
        var found: [String: ModManifest] = [:]
        // Claude Code's installs, then GrizzyCode's folder, then ours: the nearest wins a name clash.
        if let installed = readJSON(ModPaths.claudePlugins), let plugins = installed["plugins"] as? [String: Any] {
            for (id, list) in plugins {
                for case let record as [String: Any] in (list as? [Any]) ?? [] {
                    guard let install = record["installPath"] as? String,
                          let mod = inspect(root: install, source: ModPaths.claudeSource, pluginId: id),
                          found[mod.name] == nil else { continue }
                    found[mod.name] = mod
                }
            }
        }
        for (dir, source) in [(ModPaths.grizzyDir, ModPaths.grizzySource), (ModPaths.nativeDir, ModPaths.nativeSource)] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for folder in names.sorted() {
                let path = (dir as NSString).appendingPathComponent(folder)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                      let mod = inspect(root: path, source: source) else { continue }
                found[mod.name] = mod
            }
        }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The folder name of a native or GrizzyCode mod, as the mod sees it under `~/.claude/mods`.
    static func pluginRoot(for mod: ModManifest) -> String {
        mod.source == ModPaths.claudeSource ? mod.root : (ModPaths.claudeMods as NSString).appendingPathComponent((mod.root as NSString).lastPathComponent)
    }

    /// A fingerprint of everything a mod would run, so a change made by someone else (an update, a
    /// replaced file) is noticed. Files are hashed in a stable order by path and content.
    static func digest(of mod: ModManifest) -> String {
        var hasher = SHA256()
        let root = URL(fileURLWithPath: mod.root)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return "" }
        var files: [URL] = []
        for case let url as URL in walker {
            let parts = url.pathComponents
            if parts.contains("node_modules") || parts.contains(".git") { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true { files.append(url) }
        }
        for url in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(url.path.dropFirst(root.path.count).utf8))
            if let data = try? Data(contentsOf: url) { hasher.update(data: data) }
        }
        // The plugin manifest sits in a hidden folder the walk skips; it names the modules, so include it.
        for hidden in [".claude-plugin/plugin.json"] {
            if let data = FileManager.default.contents(atPath: (mod.root as NSString).appendingPathComponent(hidden)) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The newest modification time among a mod's files, for noticing edits while it runs.
    static func newestModification(of mod: ModManifest) -> Date {
        var newest = Date.distantPast
        let root = URL(fileURLWithPath: mod.root)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return newest }
        for case let url as URL in walker {
            if url.pathComponents.contains("node_modules") || url.pathComponents.contains(".git") { walker.skipDescendants(); continue }
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > newest { newest = date }
        }
        return newest
    }
}
