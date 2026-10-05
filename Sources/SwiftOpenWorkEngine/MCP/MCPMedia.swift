import Foundation

/// Images returned by MCP tools (browser and screenshot servers). They used to be reduced to the
/// text "[image image/png]", so a model driving a browser was blind. The bytes are written to a
/// file and the result text says where; `paths(in:)` finds them again so the engine can attach
/// the images to the tool result the way its own screenshots are.
public enum MCPMedia {
    static let marker = "saved to "

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swiftopenwork-mcp-media", isDirectory: true)
    }

    /// Write a base64 image and return the line that stands for it in the result text.
    public static func describeImage(base64: String, mimeType: String) -> String {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            return "[image \(mimeType)]"
        }
        let ext = mimeType.split(separator: "/").last.map { $0 == "jpeg" ? "jpg" : String($0) } ?? "png"
        let url = directory.appendingPathComponent("\(UUID().uuidString).\(ext.filter { $0.isLetter || $0.isNumber })")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return "[image \(mimeType)]"
        }
        return "[image \(mimeType) \(marker)\(url.path)]"
    }

    /// Paths of images saved by `describeImage` that appear in a result.
    public static func paths(in text: String) -> [String] {
        guard text.contains(marker),
              let regex = try? NSRegularExpression(pattern: #"\[image [^\]\s]+ saved to ([^\]]+)\]"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
