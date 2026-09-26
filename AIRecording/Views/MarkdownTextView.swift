import SwiftUI

/// Renders AI-generated summaries written in Markdown (headings, bold/italic,
/// bullet & numbered lists, tables) as styled text instead of showing raw
/// markup symbols.
struct MarkdownTextView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlockParser.parse(markdown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            markdownInlineText(text)
                .font(headingFont(for: level))
                .padding(.top, 6)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                markdownInlineText(text)
            }
            .padding(.leading, 8)
        case .numbered(let index, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index).")
                    .monospacedDigit()
                markdownInlineText(text)
            }
        case .paragraph(let text):
            markdownInlineText(text)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case ...1: return .title3.bold()
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

/// A simple Markdown table: bold header row on a tinted background, zebra body
/// rows, hairline separators and a rounded outer border. Cells render inline
/// Markdown (bold etc.) like any other block.
private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .leading),
              count: max(headers.count, 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    markdownInlineText(header)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06))
                }
            }
            if !rows.isEmpty {
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            markdownInlineText(cell)
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    if rowIndex < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Renders inline Markdown (bold, italic, code) in a single line/paragraph.
/// Falls back to the raw string if parsing fails, so output is never worse
/// than plain text.
private func markdownInlineText(_ markdown: String) -> Text {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    if let attributed = try? AttributedString(markdown: markdown, options: options) {
        return Text(attributed)
    }
    return Text(markdown)
}

/// Splits a Markdown string into block-level elements. Line-based and forgiving:
/// anything that is not a recognized heading/list/table marker becomes
/// paragraph text.
enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            if line.hasPrefix("|"), let table = parseTable(lines, startAt: index) {
                flushParagraph()
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }
            if let heading = parseHeading(line) {
                flushParagraph()
                blocks.append(heading)
            } else if let bullet = parseBullet(line) {
                flushParagraph()
                blocks.append(bullet)
            } else if let numbered = parseNumbered(line) {
                flushParagraph()
                blocks.append(numbered)
            } else if isHorizontalRule(line) {
                flushParagraph()
            } else {
                paragraphLines.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for char in line {
            if char == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func parseBullet(_ line: String) -> MarkdownBlock? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            let text = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                return .bullet(text: text)
            }
        }
        return nil
    }

    private static func parseNumbered(_ line: String) -> MarkdownBlock? {
        var digits = ""
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            digits.append(line[index])
            index = line.index(after: index)
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard index < line.endIndex, line[index] == "." || line[index] == ")" else { return nil }
        index = line.index(after: index)
        guard index < line.endIndex, line[index] == " " else { return nil }
        let text = String(line[index...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .numbered(index: number, text: text)
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        ["---", "***", "___"].contains(line)
    }

    // MARK: - Tables

    /// Parses a GFM-style pipe table starting at `start`. Requires a header
    /// line followed by a separator line (`|---|---|`); body rows are optional.
    /// Returns nil when the lines are not a valid table, so the caller falls
    /// back to paragraph rendering.
    private static func parseTable(_ lines: [String], startAt start: Int)
        -> (block: MarkdownBlock, nextIndex: Int)? {
        guard start + 1 < lines.count else { return nil }
        let headerLine = lines[start].trimmingCharacters(in: .whitespaces)
        let separatorLine = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard isTableSeparator(separatorLine) else { return nil }

        let headers = splitTableRow(headerLine)
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
            guard rowLine.hasPrefix("|") else { break }
            rows.append(splitTableRow(rowLine))
            index += 1
        }

        // Normalize ragged rows to the header column count.
        let normalized = rows.map { row -> [String] in
            var cells = Array(row.prefix(headers.count))
            while cells.count < headers.count {
                cells.append("")
            }
            return cells
        }
        return (.table(headers: headers, rows: normalized), index)
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var trimmed = line
        if trimmed.hasPrefix("|") {
            trimmed = String(trimmed.dropFirst())
        }
        if trimmed.hasSuffix("|") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let dashes = cell.replacingOccurrences(of: ":", with: "")
            return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
        }
    }
}

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(index: Int, text: String)
    case paragraph(text: String)
    case table(headers: [String], rows: [[String]])
}
