import Foundation
import AppKit
import CoreText

/// Writes the documents people actually hand to each other: Word, PDF, RTF, HTML and Excel files,
/// from Markdown or CSV text the agent produced.
///
/// Reading a document was always possible; producing one meant the agent shelling out to a library
/// that may not be installed. Word, RTF and HTML come from AppKit's own writers, PDF from CoreText,
/// and `.xlsx` is assembled by hand (it is a zip of small XML parts), so nothing needs installing.
public enum DocumentWriter {

    public enum Format: String, CaseIterable, Sendable {
        case docx, pdf, rtf, html, xlsx

        public init?(path: String) {
            switch (path as NSString).pathExtension.lowercased() {
            case "docx": self = .docx
            case "pdf": self = .pdf
            case "rtf": self = .rtf
            case "html", "htm": self = .html
            case "xlsx": self = .xlsx
            default: return nil
            }
        }
    }

    public struct Failure: Error, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// `content` is Markdown for text documents and CSV (or a Markdown table) for spreadsheets.
    @MainActor
    public static func write(content: String, to url: URL, format: Format) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch format {
        case .html:
            try Data(html(fromMarkdown: content).utf8).write(to: url, options: .atomic)
        case .xlsx:
            try writeSpreadsheet(rows: rows(from: content), to: url)
        case .docx, .rtf, .pdf:
            let attributed = try attributedString(fromMarkdown: content)
            switch format {
            case .docx:
                try attributedData(attributed, type: .officeOpenXML).write(to: url, options: .atomic)
            case .rtf:
                try attributedData(attributed, type: .rtf).write(to: url, options: .atomic)
            default:
                try pdf(from: attributed).write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Markdown → HTML

    /// The subset reports use: headings, paragraphs, bullet and numbered lists, block quotes, fenced
    /// code, pipe tables, rules, and inline bold, italic, code and links.
    public static func html(fromMarkdown markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var listKind: String?
        var inCode = false
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>" + inline(paragraph.joined(separator: " ")) + "</p>"); paragraph = [] }
        }
        func closeList() {
            if let kind = listKind { out.append("</\(kind)>"); listKind = nil }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            var html = "<table border=\"1\" cellspacing=\"0\" cellpadding=\"4\">"
            for (index, row) in table.enumerated() {
                let tag = index == 0 ? "th" : "td"
                html += "<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>"
            }
            out.append(html + "</table>")
            table = []
        }

        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("```") {
                flushParagraph(); closeList(); flushTable()
                out.append(inCode ? "</pre>" : "<pre>")
                inCode.toggle()
                continue
            }
            if inCode { out.append(escape(line)); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1 {
                flushParagraph(); closeList()
                let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                // The `---|---` separator row is structure, not data.
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
                table.append(cells)
                continue
            }
            flushTable()
            if trimmed.isEmpty { flushParagraph(); closeList(); continue }
            if let heading = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushParagraph(); closeList()
                let level = trimmed[heading].count - 1
                out.append("<h\(level)>" + inline(String(trimmed[heading.upperBound...])) + "</h\(level)>")
            } else if trimmed == "---" || trimmed == "***" {
                flushParagraph(); closeList(); out.append("<hr/>")
            } else if let bullet = trimmed.range(of: #"^[-*+] "#, options: .regularExpression) {
                flushParagraph()
                if listKind != "ul" { closeList(); out.append("<ul>"); listKind = "ul" }
                out.append("<li>" + inline(String(trimmed[bullet.upperBound...])) + "</li>")
            } else if let number = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushParagraph()
                if listKind != "ol" { closeList(); out.append("<ol>"); listKind = "ol" }
                out.append("<li>" + inline(String(trimmed[number.upperBound...])) + "</li>")
            } else if trimmed.hasPrefix("> ") {
                flushParagraph(); closeList()
                out.append("<blockquote>" + inline(String(trimmed.dropFirst(2))) + "</blockquote>")
            } else {
                closeList()
                paragraph.append(trimmed)
            }
        }
        flushParagraph(); closeList(); flushTable()
        if inCode { out.append("</pre>") }
        return "<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica;font-size:12pt}pre,code{font-family:Menlo,monospace;font-size:10pt}</style></head><body>"
            + out.joined(separator: "\n") + "</body></html>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var result = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"(?<![*\w])\*([^*\n]+)\*(?![*\w])"#, "<i>$1</i>"),
            (#"\[([^\]]+)\]\((https?://[^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules { result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        return result
    }

    // MARK: - Attributed output

    @MainActor
    static func attributedString(fromMarkdown markdown: String) throws -> NSAttributedString {
        guard let data = html(fromMarkdown: markdown).data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil
              ) else { throw Failure(message: "Could not lay the text out as a document.") }
        return attributed
    }

    static func attributedData(_ attributed: NSAttributedString, type: NSAttributedString.DocumentType) throws -> Data {
        do {
            return try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type])
        } catch {
            throw Failure(message: "Could not write the document: \(error.localizedDescription)")
        }
    }

    /// US Letter, one inch margins, paginated by CoreText.
    static func pdf(from attributed: NSAttributedString) throws -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 72
        let box = page.insetBy(dx: margin, dy: margin)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw Failure(message: "Could not create the PDF.") }
        var mediaBox = page
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw Failure(message: "Could not create the PDF.") }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var location = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: box, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < attributed.length
        context.closePDF()
        return data as Data
    }

    // MARK: - Spreadsheets

    /// CSV (quotes and embedded commas handled) or a Markdown pipe table.
    public static func rows(from text: String) -> [[String]] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("|") == true {
            return lines.compactMap { line -> [String]? in
                let cells = line.trimmingCharacters(in: .whitespaces).dropFirst().dropLast()
                    .split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                return cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) ? nil : cells
            }
        }
        return parseCSV(text)
    }

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if quoted {
                if c == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else { field.append(c) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func columnName(_ index: Int) -> String {
        var n = index, name = ""
        repeat { name = String(UnicodeScalar(UInt8(65 + n % 26))) + name; n = n / 26 - 1 } while n >= 0
        return name
    }

    static func sheetXML(rows: [[String]]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                if value.hasPrefix("=") && value.count > 1 {
                    xml += "<c r=\"\(ref)\"><f>\(escape(String(value.dropFirst())))</f></c>"
                } else if !value.isEmpty, Double(value) != nil, !value.hasPrefix("0") || value == "0" || value.hasPrefix("0.") {
                    xml += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    static func writeSpreadsheet(rows: [[String]], to url: URL) throws {
        guard !rows.isEmpty else { throw Failure(message: "A spreadsheet needs at least one row of CSV or a Markdown table.") }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("xlsx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let parts: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#,
            "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
            "xl/workbook.xml": #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#,
            "xl/worksheets/sheet1.xml": sheetXML(rows: rows),
        ]
        for (name, body) in parts {
            let file = staging.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: file)
        }
        try? fm.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-X", "-r", url.path, "[Content_Types].xml", "_rels", "xl"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw Failure(message: "Could not package the spreadsheet.") }
    }
}
