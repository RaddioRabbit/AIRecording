import CoreData
import XCTest
@testable import AIRecording

final class DocxExportServiceTests: XCTestCase {
    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext { persistence.container.viewContext }

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
    }

    override func tearDown() {
        persistence = nil
        super.tearDown()
    }

    private func makeRecording() -> Recording {
        let recording = Recording(context: context)
        recording.id = UUID()
        recording.createdAt = Date()
        recording.updatedAt = Date()
        return recording
    }

    /// Exports `summary` to a temp .docx and returns the contents of
    /// `word/document.xml` plus the list of file names inside the zip.
    private func exportAndRead(_ summary: String) throws -> (documentXML: String, entries: [String]) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("docx")
        defer { try? FileManager.default.removeItem(at: destination) }

        try awaitDocxExport(summary: summary, to: destination)

        let documentXML = try unzipEntry(at: destination, name: "word/document.xml")
        let entries = (try? Process.runForOutput(
            "/usr/bin/unzip", ["-Z1", destination.path]
        ))?.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        return (documentXML, entries)
    }

    private func awaitDocxExport(summary: String, to url: URL) throws {
        let recording = makeRecording()
        var thrown: Error?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await DocxExportService.shared.export(
                    summary: summary, recording: recording, destinationURL: url)
            } catch {
                thrown = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let thrown { throw thrown }
    }

    private func unzipEntry(at docxURL: URL, name: String) throws -> String {
        try Process.runForOutput("/usr/bin/unzip", ["-p", docxURL.path, name])
    }

    // MARK: - Tests

    /// Regression: ordered list numbers must restart at 1 per list block,
    /// not use the markdown line index (bug: numbering started at 14).
    func testOrderedListNumberingRestartsAtOne() throws {
        let summary = """
        # 会议纪要

        ## 参与人
        - 甲
        - 乙

        ## 关键讨论要点
        1. 第一项
        2. 第二项
        """
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("1. 第一项"), "首条序号应为 1：\(xml)")
        XCTAssertTrue(xml.contains("2. 第二项"), "第二条序号应为 2")
        XCTAssertFalse(xml.contains("14. 第一项"), "不应使用全文行号作为序号")
    }

    /// Two separate ordered lists each number from 1.
    func testSeparateListsNumberIndependently() throws {
        let summary = """
        1. 甲一
        2. 甲二

        普通段落分隔。

        1. 乙一
        """
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("1. 甲一"))
        XCTAssertTrue(xml.contains("2. 甲二"))
        XCTAssertTrue(xml.contains("1. 乙一"), "第二个列表应重新从 1 开始")
    }

    /// Code fence markers (```markdown / ```) must not appear in the output.
    func testCodeFenceMarkersAreStripped() throws {
        let summary = """
        ```markdown
        # 会议纪要
        正文内容。
        ```
        """
        let (xml, _) = try exportAndRead(summary)
        XCTAssertFalse(xml.contains("```"), "围栏标记不应出现在 Word 中：\(xml)")
        XCTAssertTrue(xml.contains("正文内容。"), "围栏内的正文应保留")
    }

    /// `**bold**` becomes a real bold run; asterisks disappear.
    func testBoldMarkersBecomeBoldRuns() throws {
        let summary = "1. **数据分类与现状**：现有数据包括天气数据。"
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("<w:b/>"), "应包含加粗 run：\(xml)")
        XCTAssertTrue(xml.contains("数据分类与现状"))
        XCTAssertFalse(xml.contains("**"), "星号标记不应原样输出")
    }

    /// Unmatched asterisks are kept as literal text (nothing is lost).
    func testUnmatchedAsterisksAreKept() throws {
        let summary = "2 * 3 = 6"
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("2 * 3 = 6"))
    }

    /// The package must ship styles.xml and register it.
    func testStylesPartIsIncluded() throws {
        let (xml, entries) = try exportAndRead("正文。")
        XCTAssertTrue(entries.contains("word/styles.xml"), "zip 内应包含 styles.xml：\(entries)")
        XCTAssertTrue(entries.contains("word/_rels/document.xml.rels"))
        XCTAssertTrue(xml.contains("w:pStyle"), "段落应引用样式")
    }

    /// A GFM pipe table becomes a real <w:tbl>; pipes and the separator row
    /// must not leak into the output as literal text.
    func testPipeTableBecomesRealTable() throws {
        let summary = """
        ## 待办事项
        | 事项 | 负责人 | 截止日期 |
        |------|--------|----------|
        | 优化大屏 | 技术人员 | 本周五 |
        | 部署支持 | **负责人** | 另行安排 |
        """
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("<w:tbl>"), "应生成 Word 表格：\(xml)")
        XCTAssertTrue(xml.contains("<w:tblBorders>"), "表格应带边框")
        XCTAssertFalse(xml.contains("|------|"), "分隔行不应原样输出")
        XCTAssertFalse(xml.contains("| 事项 |"), "表头不应以管道文本形式输出")
        XCTAssertTrue(xml.contains("事项"))
        XCTAssertTrue(xml.contains("优化大屏"))
        XCTAssertTrue(xml.contains("部署支持"))
    }

    /// Header cells render bold with a light shading fill.
    func testTableHeaderIsBoldAndShaded() throws {
        let summary = """
        | 名称 | 数量 |
        |---|---|
        | 苹果 | 3 |
        """
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("w:fill=\"F2F2F2\""), "表头应有浅灰底色")
        XCTAssertTrue(xml.contains("<w:b/>"), "表头应加粗")
    }

    /// Body rows with fewer cells than the header are padded, extra cells
    /// are dropped — export never fails on ragged rows.
    func testRaggedTableRowsAreNormalized() throws {
        let summary = """
        | A | B | C |
        |---|---|---|
        | 只有一格 |
        | 一 | 二 | 三 | 四 |
        """
        let (xml, _) = try exportAndRead(summary)
        XCTAssertTrue(xml.contains("<w:tbl>"))
        XCTAssertTrue(xml.contains("只有一格"))
        XCTAssertTrue(xml.contains("三"))
        XCTAssertFalse(xml.contains("四"), "超出表头列数的格子应被丢弃")
    }

    /// A `|` line without a following separator row is not a table and is
    /// exported as plain text (nothing is lost).
    func testPipeLineWithoutSeparatorIsPlainText() throws {
        let summary = "这不是表格 | 只是文字"
        let (xml, _) = try exportAndRead(summary)
        XCTAssertFalse(xml.contains("<w:tbl>"))
        XCTAssertTrue(xml.contains("这不是表格 | 只是文字"))
    }
}

private extension Process {
    /// Runs a process and returns stdout as a String, throwing on failure.
    @discardableResult
    static func runForOutput(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DocxExportServiceTests", code: Int(process.terminationStatus))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
