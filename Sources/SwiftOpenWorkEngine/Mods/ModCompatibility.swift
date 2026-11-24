import Foundation

/// Most mods are made for Claude Code or GrizzyCode. This says what of one will not work in
/// SwiftOpenWork: hooks the app never raises (found by reading the mod), and calls to the app the
/// mod made that it has no answer for (noticed as they happen).
public enum ModCompatibility {
    /// Every event SwiftOpenWork raises to mods.
    public static let supportedEvents: Set<String> = [
        "session.start", "prompt.submit", "prompt.compose", "command.run", "tool.call",
        "turn.start", "turn.step", "turn.complete", "ui.render", "ui.press", "ui.close", "agent.spawn",
    ]

    private struct Cached { var stamp: Date; var events: [String] }
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    /// Hooks the mod registers that never fire here, sorted.
    static func unsupportedEvents(in manifest: ModManifest) -> [String] {
        let stamp = ModDiscovery.newestModification(of: manifest)
        lock.lock(); let hit = cache[manifest.root]; lock.unlock()
        if let hit, hit.stamp == stamp { return hit.events }
        let found = registeredEvents(in: manifest).subtracting(supportedEvents).sorted()
        lock.lock(); cache[manifest.root] = Cached(stamp: stamp, events: found); lock.unlock()
        return found
    }

    /// Event names passed to `on('<event>', …)` in the mod's own source (tests are not part of the mod).
    static func registeredEvents(in manifest: ModManifest) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\bon\(\s*['"`]([a-z][a-z-]*(?:\.[a-z][a-z-]*)+)['"`]"#) else { return [] }
        let hooks = (manifest.root as NSString).appendingPathComponent("hooks")
        guard let walker = FileManager.default.enumerator(atPath: hooks) else { return [] }
        var events: Set<String> = []
        for case let relative as String in walker {
            let lower = relative.lowercased()
            guard ["ts", "tsx", "js", "jsx", "mjs"].contains((lower as NSString).pathExtension),
                  !lower.contains(".test."), !lower.contains("node_modules"),
                  let text = try? String(contentsOfFile: (hooks as NSString).appendingPathComponent(relative), encoding: .utf8) else { continue }
            let whole = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: whole) {
                if let range = Range(match.range(at: 1), in: text) { events.insert(String(text[range])) }
            }
        }
        return events
    }

    /// What of the mod will not work here, as short sentences. Empty means nothing is known to be missing.
    static func notes(for manifest: ModManifest, unsupportedCalls: Set<String>) -> [String] {
        var notes: [String] = []
        let events = unsupportedEvents(in: manifest)
        if !events.isEmpty { notes.append("never fires here: " + events.joined(separator: ", ")) }
        if !unsupportedCalls.isEmpty { notes.append("asked the app for " + unsupportedCalls.sorted().map { "$." + $0 }.joined(separator: ", ") + ", which SwiftOpenWork lacks") }
        return notes
    }
}
