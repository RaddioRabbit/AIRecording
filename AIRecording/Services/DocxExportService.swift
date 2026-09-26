import Foundation

/// Minimal OOXML docx generator using FileManager + Foundation.
/// Produces a valid .docx (ZIP) by shelling out to `/usr/bin/zip`.
enum DocxExportError: Error {
    case noRecording
    case noSummary
    case invalidDestination
    case zipFailed(Int32, String)
    case writeFailed(Error)
}

final class DocxExportService: @unchecked Sendable {
    static let shared = DocxExportService()
    private init() {}

    /// Export a recording summary to a .docx file at the given URL.
    func export(summary: String, recording: Recording, destinationURL: URL) async throws {
        guard !summary.isEmpty else {
            throw DocxExportError.noSummary
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Build directory structure
        let wordDir = tempDir.appendingPathComponent("word", isDirectory: true)
        let relsDir = tempDir.appendingPathComponent("_rels", isDirectory: true)
        let wordRelsDir = wordDir.appendingPathComponent("_rels", isDirectory: true)
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)

        // Write [Content_Types].xml
        let contentTypes = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>
"""
        try write(contentTypes, to: tempDir.appendingPathComponent("[Content_Types].xml"))

        // Write _rels/.rels
        let rels = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"""
        try write(rels, to: relsDir.appendingPathComponent(".rels"))

        // Write word/_rels/document.xml.rels (document -> styles)
        let documentRels = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
"""
        try write(documentRels, to: wordRelsDir.appendingPathComponent("document.xml.rels"))

        // Write word/styles.xml
        try write(Self.stylesXML, to: wordDir.appendingPathComponent("styles.xml"))

        // Build document.xml body
        let bodyXML = buildDocumentBody(summary: summary, recording: recording)

        let document = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
            xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
  <w:body>
\(bodyXML)
    <w:sectPr>
      <w:pgSz w:w="11906" w:h="16838"/>
      <w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800" w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>
"""
        try write(document, to: wordDir.appendingPathComponent("document.xml"))

        // ZIP the temp directory contents into destination
        try await zipDirectory(source: tempDir, destination: destinationURL)
    }

    // MARK: - Private helpers

    private func write(_ string: String, to url: URL) throws {
        do {
            try string.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw DocxExportError.writeFailed(error)
        }
    }

    private func zipDirectory(source: URL, destination: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // zip -r destination.zip . -x "*.DS_Store"
        process.arguments = [
            "-r", destination.path, ".",
            "-x", "*.DS_Store"
        ]
        process.currentDirectoryURL = source

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let msg = String(data: data, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: DocxExportError.zipFailed(proc.terminationStatus, msg))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: DocxExportError.zipFailed(-1, error.localizedDescription))
            }
        }
    }

    // MARK: - Markdown -> OOXML body

    private func buildDocumentBody(summary: String, recording: Recording) -> String {
        var paragraphs: [String] = []

        // Title
        let title = recording.displayTitle
        paragraphs.append(makeParagraph(text: title, style: "Title"))

        // Date & Duration
        let dateStr = recording.formattedDate
        let durationStr = recording.formattedDuration
        paragraphs.append(makeParagraph(text: "日期: \(dateStr)    时长: \(durationStr)", style: "Subtitle"))

        // Empty line
        paragraphs.append(makeParagraph(text: "", style: "Normal"))

        // Parse Markdown lines
        let lines = summary.components(separatedBy: .newlines)
        var i = 0
        var orderedListCounter = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                paragraphs.append(makeParagraph(text: "", style: "Normal"))
                orderedListCounter = 0
                i += 1
                continue
            }

            // Code fence marker (e.g. ```markdown, ```, ```json) — skip the
            // marker line itself, keep the content inside the fence.
            if trimmed.hasPrefix("```") {
                orderedListCounter = 0
                i += 1
                continue
            }

            // GFM pipe table: header row followed by a |---|---| separator.
            if trimmed.hasPrefix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                var tableLines: [String] = []
                var j = i
                while j < lines.count {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    tableLines.append(t)
                    j += 1
                }
                paragraphs.append(makeTable(tableLines))
                // Word needs a paragraph between a table and whatever follows.
                paragraphs.append(makeParagraph(text: "", style: "Normal"))
                orderedListCounter = 0
                i = j
                continue
            }

            // Heading
            if let headingLevel = headingLevel(of: trimmed) {
                let text = trimmed.replacingOccurrences(of: "^#+\\s+", with: "", options: .regularExpression)
                let style = headingStyle(level: headingLevel)
                paragraphs.append(makeParagraph(text: text, style: style))
                orderedListCounter = 0
                i += 1
                continue
            }

            // Unordered list item
            if isUnorderedListItem(trimmed) {
                let text = trimmed.replacingOccurrences(of: "^[-*]\\s+", with: "", options: .regularExpression)
                paragraphs.append(makeParagraph(text: "• \(text)", style: "ListParagraph"))
                orderedListCounter = 0
                i += 1
                continue
            }

            // Ordered list item — numbered per contiguous list block, from 1.
            if isOrderedListItem(trimmed) {
                let text = trimmed.replacingOccurrences(of: "^\\d+[\\.\\)、]\\s*", with: "", options: .regularExpression)
                orderedListCounter += 1
                paragraphs.append(makeParagraph(text: "\(orderedListCounter). \(text)", style: "ListParagraph"))
                i += 1
                continue
            }

            // Normal paragraph
            paragraphs.append(makeParagraph(text: trimmed, style: "Normal"))
            orderedListCounter = 0
            i += 1
        }

        return paragraphs.joined(separator: "\n")
    }

    private func headingLevel(of line: String) -> Int? {
        let prefixes = ["# ", "## ", "### ", "#### ", "##### ", "###### "]
        for (index, prefix) in prefixes.enumerated() {
            if line.hasPrefix(prefix) {
                return index + 1
            }
        }
        return nil
    }

    private func headingStyle(level: Int) -> String {
        switch level {
        case 1: return "Heading1"
        case 2: return "Heading2"
        case 3: return "Heading3"
        default: return "Heading3"
        }
    }

    private func isUnorderedListItem(_ line: String) -> Bool {
        return line.range(of: "^[-*]\\s+", options: .regularExpression) != nil
    }

    private func isOrderedListItem(_ line: String) -> Bool {
        return line.range(of: "^\\d+[\\.\\)、]\\s*", options: .regularExpression) != nil
    }

    private func makeParagraph(text: String, style: String) -> String {
        return """
    <w:p>
      <w:pPr>
        <w:pStyle w:val="\(style)"/>
      </w:pPr>
      \(makeRunsXML(text))
    </w:p>
"""
    }

    /// Builds the `<w:r>` runs for a text fragment, converting inline
    /// `**bold**` / `*italic*` markers into formatted runs.
    private func makeRunsXML(_ text: String, forceBold: Bool = false) -> String {
        return parseInlineRuns(text).map { run -> String in
            let bold = run.bold || forceBold
            var rPr = ""
            if bold || run.italic {
                var props = ""
                if bold { props += "<w:b/>" }
                if run.italic { props += "<w:i/>" }
                rPr = "<w:rPr>\(props)</w:rPr>"
            }
            return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escapeXML(run.text))</w:t></w:r>"
        }.joined()
    }

    // MARK: - GFM pipe tables

    /// A table separator row like `|---|---|` or `|:---|:---:|---:|`.
    private func isTableSeparator(_ line: String) -> Bool {
        return line.range(of: "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)+\\|?$",
                          options: .regularExpression) != nil
    }

    private func splitTableRow(_ line: String) -> [String] {
        var row = line
        if row.hasPrefix("|") { row = String(row.dropFirst()) }
        if row.hasSuffix("|") { row = String(row.dropLast()) }
        return row.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Converts parsed table lines (header, separator, body rows) into a
    /// bordered `<w:tbl>` with a bold, shaded header row and equal column
    /// widths spanning the page. Rows with the wrong cell count are padded
    /// or truncated to match the header.
    private func makeTable(_ lines: [String]) -> String {
        let header = splitTableRow(lines[0])
        let columnCount = max(header.count, 1)
        let bodyRows = lines.dropFirst(2).map { splitTableRow($0) }

        // Page width 11906 - left/right margins 1800*2 = 8306 twips.
        let columnWidth = 8306 / columnCount

        func normalized(_ row: [String]) -> [String] {
            var cells = row
            if cells.count > columnCount { cells = Array(cells.prefix(columnCount)) }
            while cells.count < columnCount { cells.append("") }
            return cells
        }

        func cell(_ text: String, isHeader: Bool) -> String {
            let shading = isHeader
                ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>"
                : ""
            return """
          <w:tc>
            <w:tcPr><w:tcW w:w="\(columnWidth)" w:type="dxa"/>\(shading)</w:tcPr>
            <w:p>\(makeRunsXML(text, forceBold: isHeader))</w:p>
          </w:tc>
        """
        }

        func rowXML(_ cells: [String], isHeader: Bool) -> String {
            let cellsXML = normalized(cells).map { cell($0, isHeader: isHeader) }.joined(separator: "\n")
            return "      <w:tr>\n\(cellsXML)\n      </w:tr>"
        }

        let grid = (0..<columnCount)
            .map { _ in "<w:gridCol w:w=\"\(columnWidth)\"/>" }
            .joined()

        var rows = [rowXML(header, isHeader: true)]
        rows += bodyRows.map { rowXML($0, isHeader: false) }

        return """
    <w:tbl>
      <w:tblPr>
        <w:tblW w:w="5000" w:type="pct"/>
        <w:tblBorders>
          <w:top w:val="single" w:sz="4" w:space="0" w:color="999999"/>
          <w:left w:val="single" w:sz="4" w:space="0" w:color="999999"/>
          <w:bottom w:val="single" w:sz="4" w:space="0" w:color="999999"/>
          <w:right w:val="single" w:sz="4" w:space="0" w:color="999999"/>
          <w:insideH w:val="single" w:sz="4" w:space="0" w:color="999999"/>
          <w:insideV w:val="single" w:sz="4" w:space="0" w:color="999999"/>
        </w:tblBorders>
        <w:tblCellMar>
          <w:top w:w="60" w:type="dxa"/>
          <w:left w:w="108" w:type="dxa"/>
          <w:bottom w:w="60" w:type="dxa"/>
          <w:right w:w="108" w:type="dxa"/>
        </w:tblCellMar>
      </w:tblPr>
      <w:tblGrid>\(grid)</w:tblGrid>
    \(rows.joined(separator: "\n"))
    </w:tbl>
"""
    }

    // MARK: - Inline Markdown (bold / italic)

    private struct InlineRun {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    /// Splits text into runs, converting `**bold**` / `__bold__` and
    /// `*italic*` / `_italic_` markers into formatted runs. No nesting;
    /// unmatched markers are kept as literal text so nothing is lost.
    private func parseInlineRuns(_ text: String) -> [InlineRun] {
        let markers: [(marker: String, bold: Bool)] = [
            ("**", true), ("__", true), ("*", false), ("_", false)
        ]
        var runs: [InlineRun] = []
        var plain = ""
        var i = text.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            runs.append(InlineRun(text: plain, bold: false, italic: false))
            plain = ""
        }

        while i < text.endIndex {
            var matched = false
            for entry in markers where text[i...].hasPrefix(entry.marker) {
                let contentStart = text.index(i, offsetBy: entry.marker.count)
                if let close = text.range(of: entry.marker, range: contentStart..<text.endIndex),
                   close.lowerBound > contentStart {
                    flushPlain()
                    let content = String(text[contentStart..<close.lowerBound])
                    runs.append(InlineRun(text: content, bold: entry.bold, italic: !entry.bold))
                    i = close.upperBound
                    matched = true
                    break
                }
            }
            if !matched {
                plain.append(text[i])
                i = text.index(after: i)
            }
        }
        flushPlain()

        if runs.isEmpty {
            runs.append(InlineRun(text: "", bold: false, italic: false))
        }
        return runs
    }

    // MARK: - Styles

    /// word/styles.xml — real Word styles so headings render bold/large and
    /// list paragraphs get a hanging indent. Font sizes are in half-points.
    private static let stylesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:rPr><w:sz w:val="21"/><w:szCs w:val="21"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Title">
    <w:name w:val="Title"/>
    <w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:after="240"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Subtitle">
    <w:name w:val="Subtitle"/>
    <w:basedOn w:val="Normal"/>
    <w:rPr><w:color w:val="666666"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
    <w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading2">
    <w:name w:val="heading 2"/>
    <w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="200" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading3">
    <w:name w:val="heading 3"/>
    <w:basedOn w:val="Normal"/>
    <w:pPr><w:spacing w:before="160" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="ListParagraph">
    <w:name w:val="List Paragraph"/>
    <w:basedOn w:val="Normal"/>
    <w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr>
  </w:style>
</w:styles>
"""

    private func escapeXML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
