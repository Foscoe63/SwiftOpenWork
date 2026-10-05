import Foundation

/// Readable text from an HTML page. `fetch_url` used to hand the model raw markup, so scripts,
/// styles and attributes took most of the 40K characters a result is allowed.
public enum HTMLText {

    /// Whether a response is HTML worth converting, from its content type or its first bytes.
    public static func looksLikeHTML(contentType: String?, body: String) -> Bool {
        if let contentType, contentType.lowercased().contains("html") { return true }
        let head = body.prefix(512).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    public static func convert(_ html: String) -> String {
        var text = html
        // Whole elements that carry no reading text.
        for tag in ["script", "style", "noscript", "svg", "template", "head"] {
            text = replace(text, pattern: "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: " ", options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
        text = replace(text, pattern: "<!--.*?-->", with: " ", options: [.dotMatchesLineSeparators])
        // Headings and list items keep a little structure; block ends become line breaks.
        text = replace(text, pattern: "<h([1-6])\\b[^>]*>", with: "\n\n# ", options: [.caseInsensitive])
        text = replace(text, pattern: "<li\\b[^>]*>", with: "\n- ", options: [.caseInsensitive])
        text = replace(text, pattern: "<(br|hr)\\b[^>]*>", with: "\n", options: [.caseInsensitive])
        text = replace(text, pattern: "</(p|div|section|article|header|footer|tr|table|ul|ol|h[1-6]|pre|blockquote)\\s*>", with: "\n", options: [.caseInsensitive])
        text = replace(text, pattern: "</t[dh]\\s*>", with: " | ", options: [.caseInsensitive])
        // Links keep their address, which is often the point of fetching a page.
        text = replace(
            text, pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>"#, with: "$2 ($1)",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        text = replace(text, pattern: "<[^>]+>", with: "", options: [])
        text = decodeEntities(text)
        // Collapse runs of spaces within lines and runs of blank lines.
        text = replace(text, pattern: "[ \\t\\u{00A0}]+", with: " ", options: [])
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        text = replace(text, pattern: "\n{3,}", with: "\n\n", options: [])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&copy;": "©"]
        for (entity, value) in named where entity != "&amp;" { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result),
                      let hex = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hex].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        // Last, so "&amp;lt;" becomes "&lt;" and not "<".
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replace(_ text: String, pattern: String, with template: String, options: NSRegularExpression.Options) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }
}
