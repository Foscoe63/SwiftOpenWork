import Foundation

/// A team or bot written for another tool, in plain terms. Nothing here is connected or switched on.
public struct ExternalTeam: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var name: String
        public var title: String
        public var description: String
        public var instructions: String
        public var isLead: Bool
    }
    public var name: String
    public var summary: String
    public var members: [Member]
    public var connectors: [String]
    /// Scheduled routines in the file. They are not imported.
    public var routineCount: Int
}

/// Reads OpenMausBot / BotMRR playbooks (`botmrr` frontmatter) and botteams listings (`bot_roster`).
public enum ExternalTeamImport {
    public static let maxMembers = 12
    static let maxInstructionChars = 8000

    public static func convert(markdown: String) -> ExternalTeam? {
        guard let (front, body) = splitFrontmatter(markdown) else { return nil }
        var parser = MiniYAML(text: front)
        guard case .map(let root) = parser.parse() else { return nil }
        let team: ExternalTeam?
        if root["agents"] != nil || root["botmrr"] != nil { team = fromOpenMaus(root, body: body) }
        else if root["bot_roster"] != nil { team = fromBotteams(root) }
        else { team = nil }
        guard var t = team, !t.members.isEmpty else { return nil }
        t.members = Array(t.members.prefix(maxMembers))
        return t
    }

    private static func fromOpenMaus(_ root: [String: MiniYAML.Node], body: String) -> ExternalTeam? {
        guard let name = root["name"]?.string, !name.isEmpty else { return nil }
        let summary = root["summary"]?.string ?? root["tagline"]?.string ?? ""
        let chiefKey = root["chiefOfStaff"]?.string
        var playbooks: [String: (name: String, text: String)] = [:]
        for pb in root["playbooks"]?.items ?? [] {
            guard let key = pb["key"]?.string else { continue }
            playbooks[key] = (pb["name"]?.string ?? key, pb["instructions"]?.string ?? "")
        }
        var rules: [String: [String]] = [:]
        for room in root["rooms"]?.items ?? [] {
            guard let bulletin = room["bulletin"]?.string, !bulletin.isEmpty else { continue }
            for m in room["members"]?.strings ?? [] { rules[m, default: []].append("In \(room["name"]?.string ?? "the room"): \(bulletin)") }
        }
        var agents = root["agents"]?.items ?? []
        let single = agents.isEmpty
        if single { agents = [.map(root)] }
        var members: [ExternalTeam.Member] = []
        for agent in agents {
            guard let botName = agent["name"]?.string, !botName.isEmpty else { continue }
            let key = agent["key"]?.string ?? botName
            let description = agent["description"]?.string ?? summary
            var parts = [description]
            let pbs = (agent["playbooks"]?.strings ?? []).compactMap { playbooks[$0] }
            if !pbs.isEmpty {
                parts.append("Playbooks you follow when a request matches:")
                for pb in pbs { parts.append("### \(pb.name)\n\(pb.text)") }
            }
            if let r = rules[key], !r.isEmpty { parts.append("Team rules:\n" + r.map { "- \($0)" }.joined(separator: "\n")) }
            if single, !body.isEmpty { parts.append(body) }
            members.append(.init(name: botName, title: agent["title"]?.string ?? "", description: String(description.prefix(200)),
                                 instructions: clip(parts.filter { !$0.isEmpty }.joined(separator: "\n\n")), isLead: key == chiefKey))
        }
        return ExternalTeam(
            name: name, summary: summary, members: members,
            connectors: (root["requirements"]?["apps"]?.items ?? []).compactMap { $0["label"]?.string ?? $0["slug"]?.string },
            routineCount: root["routines"]?.items.count ?? 0
        )
    }

    private static func fromBotteams(_ root: [String: MiniYAML.Node]) -> ExternalTeam? {
        guard let name = root["name"]?.string, !name.isEmpty else { return nil }
        let rules = (root["suggest"]?.items ?? []).compactMap { s -> String? in s["on"]?.string == "false" ? nil : s["text"]?.string }
        let members: [ExternalTeam.Member] = (root["bot_roster"]?.items ?? []).compactMap { b in
            guard let n = b["name"]?.string, !n.isEmpty else { return nil }
            let persona = b["persona"]?.string ?? ""
            let text = rules.isEmpty ? persona : persona + "\n\nRules:\n" + rules.map { "- \($0)" }.joined(separator: "\n")
            return .init(name: n, title: root["section"]?.string ?? "", description: String(persona.prefix(200)), instructions: clip(text), isLead: false)
        }
        return ExternalTeam(name: name, summary: root["tagline"]?.string ?? "", members: members,
                            connectors: root["connectors"]?.strings ?? [], routineCount: root["routines"]?.items.count ?? 0)
    }

    private static func clip(_ s: String) -> String { s.count > maxInstructionChars ? String(s.prefix(maxInstructionChars)) : s }

    static func splitFrontmatter(_ text: String) -> (String, String)? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        return (lines[1..<end].joined(separator: "\n"), lines[(end + 1)...].joined(separator: "\n"))
    }

    public enum FetchError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    /// Downloads a small https text file (a GitHub page link is turned into its raw address first).
    public static func download(_ source: URL, session: URLSession = .shared) async throws -> String {
        let url = GitHubSource.rawURL(for: source)
        guard url.scheme?.lowercased() == "https" else { throw FetchError.failed("Only https links can be imported.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("text/markdown, text/plain, application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw FetchError.failed("The server answered \(http.statusCode).") }
        guard data.count <= 512 * 1024, let text = String(data: data, encoding: .utf8) else { throw FetchError.failed("The file is too large or unreadable.") }
        return text
    }
}

// MARK: - A small YAML reader

/// Just enough YAML for frontmatter: nested maps, lists, quoted and plain scalars, inline `[a, b]`
/// lists, and `|` / `>` block text. Anchors, tags and multi-document files are not supported.
struct MiniYAML {
    indirect enum Node {
        case scalar(String)
        case list([Node])
        case map([String: Node])

        var string: String? { if case .scalar(let s) = self { return s }; return nil }
        var items: [Node] { if case .list(let l) = self { return l }; return [] }
        var strings: [String] { items.compactMap(\.string) }
        subscript(key: String) -> Node? { if case .map(let m) = self { return m[key] }; return nil }
    }

    private struct Line { var indent: Int; var text: String }
    private var lines: [Line] = []
    private var pos = 0

    init(text: String) {
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = raw.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: trimmed))
        }
    }

    mutating func parse() -> Node? {
        guard !lines.isEmpty else { return nil }
        return block(indent: lines[0].indent)
    }

    private mutating func block(indent: Int) -> Node {
        if lines[pos].text == "-" || lines[pos].text.hasPrefix("- ") { return list(indent: indent) }
        return map(indent: indent)
    }

    private mutating func list(indent: Int) -> Node {
        var out: [Node] = []
        while pos < lines.count, lines[pos].indent == indent, lines[pos].text == "-" || lines[pos].text.hasPrefix("- ") {
            let rest = String(lines[pos].text.dropFirst()).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                pos += 1
                if pos < lines.count, lines[pos].indent > indent { out.append(block(indent: lines[pos].indent)) }
            } else if Self.splitKey(rest) != nil {
                // "- key: value": the item is a map whose first line is this one, shifted past the dash.
                let offset = lines[pos].text.count - rest.count
                lines[pos] = Line(indent: indent + offset, text: rest)
                out.append(map(indent: indent + offset))
            } else {
                out.append(.scalar(Self.scalar(rest)))
                pos += 1
            }
        }
        return .list(out)
    }

    private mutating func map(indent: Int) -> Node {
        var out: [String: Node] = [:]
        while pos < lines.count, lines[pos].indent == indent, let (key, value) = Self.splitKey(lines[pos].text) {
            pos += 1
            if value == "|" || value == ">" || value.hasPrefix("|-") || value.hasPrefix(">-") {
                var parts: [String] = []
                while pos < lines.count, lines[pos].indent > indent { parts.append(lines[pos].text); pos += 1 }
                out[key] = .scalar(parts.joined(separator: value.hasPrefix("|") ? "\n" : " "))
            } else if value.isEmpty {
                if pos < lines.count, lines[pos].indent > indent {
                    out[key] = block(indent: lines[pos].indent)
                } else if pos < lines.count, lines[pos].indent == indent, lines[pos].text.hasPrefix("- ") {
                    out[key] = list(indent: indent)   // "key:" followed by a list at the same indent
                } else {
                    out[key] = .scalar("")
                }
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                let inner = value.dropFirst().dropLast()
                out[key] = .list(inner.split(separator: ",").map { .scalar(Self.scalar(String($0).trimmingCharacters(in: .whitespaces))) }
                    .filter { $0.string?.isEmpty == false })
            } else {
                out[key] = .scalar(Self.scalar(value))
            }
        }
        // Skip a stray over-indented line rather than looping forever.
        if pos < lines.count, lines[pos].indent > indent, out.isEmpty { pos += 1 }
        return .map(out)
    }

    /// Splits `key: value` at the first colon that ends a key (not inside quotes, not part of a URL).
    private static func splitKey(_ text: String) -> (String, String)? {
        guard let first = text.first, first != "\"", first != "'", first != "[", first != "{" else { return nil }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == ":" {
                let next = text.index(after: i)
                if next == text.endIndex || text[next] == " " {
                    let key = String(text[..<i]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { return nil }
                    return (key, next == text.endIndex ? "" : String(text[next...]).trimmingCharacters(in: .whitespaces))
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private static func scalar(_ raw: String) -> String {
        var s = raw
        if s.count >= 2, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            let quote = s.first!
            s = String(s.dropFirst().dropLast())
            if quote == "\"" { s = s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n") }
        } else if let hash = s.range(of: " #") {
            s = String(s[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}

// MARK: - GitHub links

/// Turns GitHub page links into the raw file, or lists the team files in a repository.
public enum GitHubSource {
    struct Ref { var owner: String; var repo: String; var branch: String?; var path: String; var isFile: Bool }
    public struct Listing: Equatable, Sendable, Identifiable { public var id: String; public var name: String; public var url: URL }

    static func parse(_ url: URL) -> Ref? {
        guard url.scheme?.lowercased() == "https", ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let p = url.pathComponents.filter { $0 != "/" }
        guard p.count >= 2 else { return nil }
        let repo = p[1].hasSuffix(".git") ? String(p[1].dropLast(4)) : p[1]
        if p.count >= 5, p[2] == "blob" { return Ref(owner: p[0], repo: repo, branch: p[3], path: p[4...].joined(separator: "/"), isFile: true) }
        if p.count >= 4, p[2] == "tree" { return Ref(owner: p[0], repo: repo, branch: p[3], path: p.dropFirst(4).joined(separator: "/"), isFile: false) }
        guard p.count == 2 else { return nil }
        return Ref(owner: p[0], repo: repo, branch: nil, path: "", isFile: false)
    }

    public static func rawURL(for url: URL) -> URL {
        guard let r = parse(url), r.isFile, let branch = r.branch else { return url }
        return URL(string: "https://raw.githubusercontent.com/\(r.owner)/\(r.repo)/\(branch)/\(r.path)") ?? url
    }

    public static func isRepoLink(_ url: URL) -> Bool { parse(url).map { !$0.isFile } ?? false }

    private struct Item: Decodable { var name: String; var type: String; var download_url: String? }

    /// The team files in a repository (the first of packages/, bots/, teams/ that has any), or in one folder of it.
    public static func listing(for url: URL, session: URLSession = .shared) async throws -> [Listing] {
        guard let r = parse(url), !r.isFile else { throw ExternalTeamImport.FetchError.failed("That is not a GitHub repository link.") }
        for folder in r.path.isEmpty ? ["packages", "bots", "teams"] : [r.path] {
            var comps = URLComponents(string: "https://api.github.com/repos/\(r.owner)/\(r.repo)/contents/\(folder)")
            if let b = r.branch { comps?.queryItems = [URLQueryItem(name: "ref", value: b)] }
            guard let api = comps?.url, let text = try? await ExternalTeamImport.download(api, session: session),
                  let items = try? JSONDecoder().decode([Item].self, from: Data(text.utf8)) else { continue }
            let found: [Listing] = items.compactMap { item in
                guard item.type == "file", item.name.lowercased().hasSuffix(".md"),
                      !["README.MD", "CONTRIBUTING.MD", "LICENSE.MD"].contains(item.name.uppercased()),
                      let raw = item.download_url, raw.hasPrefix("https://raw.githubusercontent.com/"), let u = URL(string: raw) else { return nil }
                let slug = String(item.name.dropLast(3))
                return Listing(id: "\(folder)/\(slug)", name: slug.replacingOccurrences(of: "-", with: " ").capitalized, url: u)
            }
            if !found.isEmpty { return Array(found.prefix(200)) }
        }
        throw ExternalTeamImport.FetchError.failed("No team files were found in that repository.")
    }
}
