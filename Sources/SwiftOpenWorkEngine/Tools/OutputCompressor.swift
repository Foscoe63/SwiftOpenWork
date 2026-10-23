import Foundation

/// Shortens tool output by what it is, rather than by where it happens to be long.
///
/// A flat head-and-tail cut keeps the start and end of a result and loses the middle, which is
/// where the failure usually is in a build log and where nearly all of the bytes are in a JSON
/// listing. Each kind here keeps the part that carries the information:
///
/// - **JSON**: structure and a sample. A hundred-item array becomes its shape, the first items and
///   the last, with a count of what was left out.
/// - **Build and test output**: errors, warnings, failures and the final verdict, with the
///   compiler's step-by-step noise dropped.
/// - **Logs**: repeated lines collapsed, the head and tail, and every line that looks like a
///   problem, wherever it falls.
///
/// Pure and synchronous. Nothing here decides *whether* to compress; `ToolResultPipeline` does,
/// and keeps the original so the cut can be undone.
public enum OutputCompressor {

    public enum Kind: String, Sendable {
        case json, build, log, text
    }

    // MARK: - Classification

    public static func classify(_ text: String, toolName: String) -> Kind {
        let trimmed = text.drop(while: { $0.isWhitespace })
        if let first = trimmed.first, first == "{" || first == "[", parsesAsJSON(text) { return .json }

        let canonical = ToolCallRepair.canonicalName(toolName)
        if canonical == "build_project" || canonical == "run_tests" { return .build }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 30 else { return .text }
        let sample = lines.prefix(400)
        let buildLines = sample.filter { buildNoise.matches(String($0)) || buildVerdict.matches(String($0)) }.count
        return buildLines >= 5 ? .build : .log
    }

    private static func parsesAsJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    // MARK: - Compression

    /// `text` shortened to roughly `targetChars`, or `text` itself when no better form was found.
    public static func compress(_ text: String, kind: Kind, targetChars: Int) -> String {
        switch kind {
        case .json: return compressJSON(text, targetChars: targetChars) ?? headAndTail(text, targetChars: targetChars)
        case .build, .log: return compressLines(text, kind: kind, targetChars: targetChars)
        case .text: return headAndTail(text, targetChars: targetChars)
        }
    }

    static func headAndTail(_ text: String, targetChars: Int) -> String {
        guard text.count > targetChars else { return text }
        let head = Int(Double(targetChars) * 0.6)
        let tail = targetChars - head
        let omitted = text.count - targetChars
        return String(text.prefix(head)) + "\n… [\(omitted) chars omitted] …\n" + String(text.suffix(tail))
    }

    // MARK: JSON

    struct JSONBudget {
        var head: Int
        var tail: Int
        var string: Int
        var depth: Int
        var keys: Int
    }

    static let jsonBudgets: [JSONBudget] = [
        JSONBudget(head: 3, tail: 1, string: 240, depth: 8, keys: 40),
        JSONBudget(head: 2, tail: 1, string: 120, depth: 6, keys: 24),
        JSONBudget(head: 1, tail: 0, string: 80, depth: 4, keys: 14),
    ]

    static func compressJSON(_ text: String, targetChars: Int) -> String? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var shape = ""
        if let array = value as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            if objects.count == array.count, !objects.isEmpty {
                var keys: [String] = []
                for object in objects.prefix(50) {
                    for key in object.keys.sorted() where !keys.contains(key) { keys.append(key) }
                }
                shape = "JSON array of \(array.count) objects; keys: \(keys.prefix(24).joined(separator: ", "))\n"
            } else {
                shape = "JSON array of \(array.count) items\n"
            }
        }
        var rendered = ""
        for budget in jsonBudgets {
            rendered = shape + render(value, budget, depth: 0)
            if rendered.count <= targetChars { return rendered }
        }
        return headAndTail(rendered, targetChars: targetChars)
    }

    private static func render(_ value: Any, _ b: JSONBudget, depth: Int) -> String {
        switch value {
        case let object as [String: Any]:
            if depth >= b.depth { return "{…\(object.count) keys}" }
            let keys = object.keys.sorted()
            var parts = keys.prefix(b.keys).map { quote($0) + ":" + render(object[$0] as Any, b, depth: depth + 1) }
            if keys.count > b.keys { parts.append("…+\(keys.count - b.keys) more keys") }
            return "{" + parts.joined(separator: ",") + "}"
        case let array as [Any]:
            if depth >= b.depth { return "[…\(array.count) items]" }
            if array.count <= b.head + b.tail + 1 {
                return "[" + array.map { render($0, b, depth: depth + 1) }.joined(separator: ",") + "]"
            }
            var parts = array.prefix(b.head).map { render($0, b, depth: depth + 1) }
            parts.append("…\(array.count - b.head - b.tail) of \(array.count) items omitted…")
            parts += array.suffix(b.tail).map { render($0, b, depth: depth + 1) }
            return "[" + parts.joined(separator: ",") + "]"
        case let string as String:
            return string.count > b.string
                ? quote(String(string.prefix(b.string))) + "…(\(string.count) chars)"
                : quote(string)
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : "\(number)"
        case is NSNull:
            return "null"
        default:
            return "\(value)"
        }
    }

    private static func quote(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: Logs and build output

    /// Lines worth keeping wherever they fall. "passed" is deliberately absent: a test run prints
    /// one per test, and the count is in the summary line.
    static let important = Pattern(
        #"error|fail|fatal|panic|exception|traceback|warning|assert|denied|refused|timed? ?out|cannot |can't |unable to|not found|no such|✗|✘|❌|crash|segfault|BUILD (FAILED|SUCCEEDED)|Build complete|Executed \d+ tests?|Test Suite .* (passed|failed)|exit(ed)? (code|status)"#
    )

    /// Compiler and build-system chatter that says a step ran, not what happened.
    static let buildNoise = Pattern(
        #"^\s*(CompileSwift|SwiftCompile|CompileC|CompileAssetCatalog|Ld |Libtool|ProcessInfoPlistFile|CodeSign|GenerateDSYMFile|CreateBuildDirectory|WriteAuxiliaryFile|SwiftDriver|SwiftEmitModule|SwiftMergeGeneratedHeaders|PhaseScriptExecution|CopySwiftLibs|Touch |MkDir|RegisterExecutionPolicyException|ProcessProductPackaging|Copy |Validate |Compiling |Linking |Planning|Fetching|Resolving|Computing|Build description|\[\d+/\d+\]|\s*(cd|env|export|builtin-)\b|/usr/bin/|/Applications/Xcode|/Library/Developer|Test Case .* (started|passed))"#
    )

    /// What counts as a problem in compiler output. Stricter than `important`: a verbose build
    /// echoes whole compiler command lines whose flags contain "error" and "warning".
    static let buildProblem = Pattern(
        #"(^|\s)(fatal error|error|warning|note):|\*\* (BUILD|TEST) |BUILD (FAILED|SUCCEEDED)|Build complete|Test Case .* failed|Test Suite .* (passed|failed)|Executed \d+ tests?|\bfailed\b|✗|✘|❌|Undefined symbols|ld: |Command .* failed|Assertion|crash"#
    )

    static let buildVerdict = Pattern(#"BUILD (FAILED|SUCCEEDED)|Build complete|Executed \d+ tests?|Compiling .*\.swift"#)

    /// A compiled, case-insensitive regex that tolerates being handed a bad pattern.
    struct Pattern: @unchecked Sendable {
        private let regex: NSRegularExpression?
        init(_ pattern: String) { regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
        func matches(_ line: String) -> Bool {
            guard let regex else { return false }
            return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    private static let digits = try? NSRegularExpression(pattern: #"\d+"#)

    /// Two lines that differ only in numbers (progress counters, timestamps, ids) share a key.
    private static func similarityKey(_ line: String) -> String {
        guard let digits else { return line }
        return digits.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "#")
    }

    static func compressLines(_ text: String, kind: Kind, targetChars: Int) -> String {
        let source = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let isBuild = kind == .build

        // 1. Drop build chatter and collapse runs of near-identical lines. A problem line is
        //    never dropped or merged, even when it repeats: each one may name a different file.
        struct Kept { var number: Int; var line: String; var repeats: Int; var isImportant: Bool }
        var kept: [Kept] = []
        var lastKey: String?
        for (index, raw) in source.enumerated() {
            let line = raw.trimmingCharacters(in: .newlines)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let flagged = isBuild ? buildProblem.matches(line) : important.matches(line)
            if isBuild, !flagged, buildNoise.matches(line) { continue }
            if !flagged {
                let key = similarityKey(line)
                if key == lastKey, !kept.isEmpty, !kept[kept.count - 1].isImportant {
                    kept[kept.count - 1].repeats += 1
                    continue
                }
                lastKey = key
            } else {
                lastKey = nil
            }
            kept.append(Kept(number: index + 1, line: line, repeats: 1, isImportant: flagged))
        }

        func render(_ item: Kept) -> String {
            let clipped = item.line.count > 300 ? String(item.line.prefix(300)) + "…" : item.line
            return item.repeats > 1 ? "\(clipped)  (×\(item.repeats) similar)" : clipped
        }

        let collapsed = kept.map(render).joined(separator: "\n")
        if collapsed.count <= targetChars {
            let note = kept.count < source.count
                ? "[\(source.count) lines reduced to \(kept.count): repeated and routine lines collapsed]\n"
                : ""
            return note + collapsed
        }

        // 2. Still too long: keep the first and last stretch and every problem line in between.
        let headCount = min(15, kept.count)
        let tailCount = min(40, max(0, kept.count - headCount))
        let tailStart = kept.count - tailCount
        var middleImportant = kept[headCount..<tailStart].indices.filter { kept[$0].isImportant }
        if middleImportant.count > 60 {
            middleImportant = Array(middleImportant.prefix(30)) + Array(middleImportant.suffix(30))
        }
        let chosen = Set(Array(0..<headCount) + middleImportant + Array(tailStart..<kept.count))

        var out: [String] = ["[\(source.count) lines; showing the start, the end and \(middleImportant.count) problem line(s) between]"]
        var previous = -1
        for i in chosen.sorted() {
            if previous >= 0, i != previous + 1 {
                out.append("… [lines \(kept[previous].number + 1)–\(kept[i].number - 1) omitted] …")
            }
            let prefix = (i >= headCount && i < tailStart) ? "L\(kept[i].number): " : ""
            out.append(prefix + render(kept[i]))
            previous = i
        }
        let joined = out.joined(separator: "\n")
        return joined.count > targetChars * 2 ? headAndTail(joined, targetChars: targetChars * 2) : joined
    }
}
