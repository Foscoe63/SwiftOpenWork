import Foundation

/// Tool calls a model wrote as *text* rather than through the provider's tool-calling channel.
///
/// This is the safety net under native tool calling: a local model whose template the runtime
/// doesn't recognise, or a provider without a tools API, still says `<tool_call>…</tool_call>` or
/// prints a JSON object. Three things about it are easy to get wrong, and the previous inline
/// version got all three wrong:
///
/// * **Nested JSON.** `{"tool":"x","parameters":{"path":"a"}}` was matched with a lazy
///   `\{[\s\S]*?\}`, which stops at the first `}` — the inner one — leaving invalid JSON that was
///   silently dropped. Any call with an object-valued argument vanished. Objects are now extracted
///   by balancing braces, string-aware.
/// * **Prose that looks like a call.** A ```json fence holding a `package.json` (`"name": "my-app"`)
///   was executed as a call to a tool named `my-app`. Outside the explicit `<function=…>` form, a
///   call must name a tool that exists.
/// * **Arguments as a string.** OpenAI-style `"arguments": "{\"path\":\"a\"}"` became `{}`.
public enum TextToolCallParser {

    public struct Call: Equatable, Sendable {
        public var tool: String
        public var args: String
    }

    /// - Parameter isKnownTool: whether a name is a tool this run can actually dispatch (built-in,
    ///   alias, MCP). Applied to every format except the explicit `<function=name>` one.
    public static func parse(_ text: String, isKnownTool: (String) -> Bool) -> [Call] {
        var calls: [Call] = []
        var seen = Set<String>()

        func add(_ call: Call) {
            let key = call.tool + "\u{1}" + call.args
            if seen.insert(key).inserted { calls.append(call) }
        }

        func addJSON(_ dict: [String: Any]) {
            guard let call = call(from: dict), isKnownTool(call.tool) else { return }
            add(call)
        }

        // 1. TOOL_CALL = { … }
        var searchStart = text.startIndex
        while let anchor = text.range(of: "TOOL_CALL", range: searchStart..<text.endIndex) {
            searchStart = anchor.upperBound
            guard let brace = text[anchor.upperBound...].firstIndex(of: "{"),
                  text[anchor.upperBound..<brace].allSatisfy({ $0 == "=" || $0.isWhitespace || $0 == ":" }),
                  let object = balancedObject(in: text, from: brace) else { continue }
            if let dict = jsonObject(object.text) { addJSON(dict) }
            searchStart = object.end
        }

        // 2. Fenced blocks: ```tool_call / ```json / bare ```
        for block in fencedBlocks(in: text) {
            var cursor = block.startIndex
            while let brace = block[cursor...].firstIndex(of: "{") {
                guard let object = balancedObject(in: block, from: brace) else { break }
                if let dict = jsonObject(object.text) { addJSON(dict) }
                cursor = object.end
            }
        }

        // 3. `<tool_call>{json}</tool_call>` (Hermes / Qwen2.5) and naked JSON, only if nothing
        //    matched above.
        if calls.isEmpty {
            var cursor = text.startIndex
            while let brace = text[cursor...].firstIndex(of: "{") {
                guard startsWithToolKey(text, at: brace),
                      let object = balancedObject(in: text, from: brace) else {
                    cursor = text.index(after: brace)
                    continue
                }
                if let dict = jsonObject(object.text) { addJSON(dict) }
                cursor = object.end
            }
        }

        // 4. Qwen-coder XML: <tool_call><function=name><parameter=key>value</parameter></function></tool_call>
        //    Explicit enough that the name is not validated — an unknown one gets a useful error.
        for call in xmlCalls(in: text) { add(call) }

        // 5. Inline `tool_name(param="value")`, only if nothing matched, and only for real tools —
        //    otherwise every `print(text="hi")` in an explanation would run.
        if calls.isEmpty {
            let pattern = "([a-zA-Z0-9_-]+)\\s*\\(\\s*([a-zA-Z0-9_-]+)\\s*=\\s*[\"']([^\"']+)[\"']\\s*\\)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = text as NSString
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 4 {
                    let tool = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard isKnownTool(tool) else { continue }
                    add(Call(tool: tool, args: encode([key: value])))
                }
            }
        }
        return calls
    }

    // MARK: - Shapes

    private static func call(from dict: [String: Any]) -> Call? {
        // `{"mcp": "server", "tool": "t", "arguments": {…}}`
        if let server = (dict["mcp"] as? String) ?? (dict["server"] as? String) {
            let tool = (dict["tool"] as? String) ?? (dict["action"] as? String) ?? (dict["name"] as? String) ?? "query"
            let wrapper: [String: Any] = ["server": server, "tool": tool, "arguments": arguments(in: dict)]
            return Call(tool: "mcp_call", args: encode(wrapper))
        }
        // `{"tool": "t", "parameters": {…}}` / `{"name": "t", "arguments": {…}}`
        // Also OpenAI's `{"function": {"name": "t", "arguments": "…"}}`.
        if let function = dict["function"] as? [String: Any], let name = function["name"] as? String {
            return Call(tool: name, args: encode(arguments(in: function)))
        }
        if let tool = (dict["tool"] as? String) ?? (dict["name"] as? String) {
            return Call(tool: tool, args: encode(arguments(in: dict)))
        }
        return nil
    }

    /// Arguments under any of the usual keys, as an object — decoding a JSON *string* when that is
    /// how the model sent them.
    private static func arguments(in dict: [String: Any]) -> [String: Any] {
        for key in ["parameters", "arguments", "args", "input"] {
            if let object = dict[key] as? [String: Any] { return object }
            if let string = dict[key] as? String, let object = jsonObject(string) { return object }
        }
        return [:]
    }

    private static func xmlCalls(in text: String) -> [Call] {
        let pattern = "<tool_call>[\\s\\S]*?<function=([a-zA-Z0-9_.-]+)>([\\s\\S]*?)(?:</function>|</tool_call>|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [Call] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = ns.substring(with: m.range(at: 2))
            var params: [String: Any] = [:]
            if let paramRegex = try? NSRegularExpression(pattern: "<parameter=([a-zA-Z0-9_.-]+)>([\\s\\S]*?)(?:</parameter>|$)") {
                let bodyNS = body as NSString
                for p in paramRegex.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) where p.numberOfRanges >= 3 {
                    let key = bodyNS.substring(with: p.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                    var value = bodyNS.substring(with: p.range(at: 2))
                    if value.hasPrefix("\n") { value.removeFirst() }
                    if value.hasSuffix("\n") { value.removeLast() }
                    params[key] = value
                }
            }
            out.append(Call(tool: name, args: encode(params)))
        }
        return out
    }

    // MARK: - Extraction

    /// Contents of each ``` fence (language tag dropped). An unterminated final fence counts —
    /// a call cut off by the token limit is still a call the model meant.
    static func fencedBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var cursor = text.startIndex
        while let open = text.range(of: "```", range: cursor..<text.endIndex) {
            var bodyStart = open.upperBound
            if let newline = text[bodyStart...].firstIndex(of: "\n"),
               text[bodyStart..<newline].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0.isWhitespace }) {
                bodyStart = text.index(after: newline)
            }
            if let close = text.range(of: "```", range: bodyStart..<text.endIndex) {
                blocks.append(String(text[bodyStart..<close.lowerBound]))
                cursor = close.upperBound
            } else {
                blocks.append(String(text[bodyStart...]))
                break
            }
        }
        return blocks
    }

    private static func startsWithToolKey(_ text: String, at brace: String.Index) -> Bool {
        let head = text[brace...].prefix(24).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        return ["{\"tool\"", "{\"name\"", "{\"mcp\"", "{\"server\"", "{\"function\""].contains { head.hasPrefix($0) }
    }

    /// The `{…}` starting at `from`, found by balancing braces and skipping over string contents
    /// (including escaped quotes). nil when it never closes.
    static func balancedObject(in text: String, from start: String.Index) -> (text: String, end: String.Index)? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return (String(text[start..<end]), end)
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
