import XCTest
@testable import AIRecording

final class MarkdownBlockParserTests: XCTestCase {

    func testHeadingLevels() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("# 标题"),
            [.heading(level: 1, text: "标题")]
        )
        XCTAssertEqual(
            MarkdownBlockParser.parse("## 一、关键讨论要点"),
            [.heading(level: 2, text: "一、关键讨论要点")]
        )
        XCTAssertEqual(
            MarkdownBlockParser.parse("### 小节"),
            [.heading(level: 3, text: "小节")]
        )
    }

    func testHeadingWithoutSpaceIsParagraph() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("#标题"),
            [.paragraph(text: "#标题")]
        )
    }

    func testBulletList() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("- 第一条\n* 第二条"),
            [.bullet(text: "第一条"), .bullet(text: "第二条")]
        )
    }

    func testNumberedList() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("1. 当前 Demo 的实现形态\n2. 大屏问数的故事线约束"),
            [.numbered(index: 1, text: "当前 Demo 的实现形态"),
             .numbered(index: 2, text: "大屏问数的故事线约束")]
        )
    }

    func testParagraphKeepsInlineMarkdown() {
        // Inline styles like **bold** are preserved in the text and rendered
        // by the view via AttributedString; the parser must not strip them.
        XCTAssertEqual(
            MarkdownBlockParser.parse("这是**加粗**内容"),
            [.paragraph(text: "这是**加粗**内容")]
        )
    }

    func testMultiLineParagraphJoinedWithSpace() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("第一行\n第二行"),
            [.paragraph(text: "第一行 第二行")]
        )
    }

    func testBlankLineSeparatesBlocks() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("段落一\n\n段落二"),
            [.paragraph(text: "段落一"), .paragraph(text: "段落二")]
        )
    }

    func testHorizontalRuleSkipped() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("上文\n\n---\n\n下文"),
            [.paragraph(text: "上文"), .paragraph(text: "下文")]
        )
    }

    func testTypicalSummaryShape() {
        let markdown = """
        ## 一、关键讨论要点（按重要性排序）

        1. **当前 Demo 的实现形态与下一步 AI 化目标**
           - 演示中图表排版和位置为事先固定
           - 真正的"AI 大屏"应当让 AI 动态决定图表类型
        2. **大屏问数的故事线约束与交互边界**

        ## 二、待办事项

        - 验证 AI 版面动态生成能力
        """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [
                .heading(level: 2, text: "一、关键讨论要点（按重要性排序）"),
                .numbered(index: 1, text: "**当前 Demo 的实现形态与下一步 AI 化目标**"),
                .bullet(text: "演示中图表排版和位置为事先固定"),
                .bullet(text: "真正的\"AI 大屏\"应当让 AI 动态决定图表类型"),
                .numbered(index: 2, text: "**大屏问数的故事线约束与交互边界**"),
                .heading(level: 2, text: "二、待办事项"),
                .bullet(text: "验证 AI 版面动态生成能力"),
            ]
        )
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownBlockParser.parse(""), [])
        XCTAssertEqual(MarkdownBlockParser.parse("\n\n  \n"), [])
    }

    // MARK: - Tables

    func testBasicTable() {
        let markdown = """
        | 事项 | 负责人 | 期望节点 |
        |------|--------|----------|
        | 完善演示系统 | 雅欣 | 向谢主任演示前 |
        | 优化演示脚本 | 雅欣 | 尽快 |
        """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.table(headers: ["事项", "负责人", "期望节点"],
                    rows: [["完善演示系统", "雅欣", "向谢主任演示前"],
                           ["优化演示脚本", "雅欣", "尽快"]])]
        )
    }

    func testTableSeparatorWithAlignmentColons() {
        let markdown = """
        | 左对齐 | 居中 | 右对齐 |
        |:---|:---:|---:|
        | a | b | c |
        """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.table(headers: ["左对齐", "居中", "右对齐"], rows: [["a", "b", "c"]])]
        )
    }

    func testPipeLineWithoutSeparatorIsParagraph() {
        // A single pipe line without a separator row is not a table.
        XCTAssertEqual(
            MarkdownBlockParser.parse("| 这不是表格 | 没有分隔行 |"),
            [.paragraph(text: "| 这不是表格 | 没有分隔行 |")]
        )
    }

    func testTableWithoutLeadingPipes() {
        let markdown = """
        事项 | 负责人
        ---|---
        a | b
        """
        // Rows must start with "|" per our simplified grammar; header line
        // doesn't, so this is paragraph text, not a table.
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.paragraph(text: "事项 | 负责人 ---|--- a | b")]
        )
    }

    func testTableRaggedRowsAreNormalized() {
        let markdown = """
        | 一 | 二 | 三 |
        |---|---|---|
        | a | b |
        | x | y | z | w |
        """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.table(headers: ["一", "二", "三"],
                    rows: [["a", "b", ""], ["x", "y", "z"]])]
        )
    }

    func testTableFollowedByOtherContent() {
        let markdown = """
        | 事项 | 负责人 |
        |------|--------|
        | 写 PPT | 雅欣 |

        后续跟进。
        """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.table(headers: ["事项", "负责人"], rows: [["写 PPT", "雅欣"]]),
             .paragraph(text: "后续跟进。")]
        )
    }

    func testTableKeepsInlineMarkdownInCells() {
        let markdown = """
        | 要点 | 状态 |
        |------|------|
        | **版面动态生成** | 进行中 |
        """
        XCTAssertEqual(
            MarkdownBlockParser.parse(markdown),
            [.table(headers: ["要点", "状态"], rows: [["**版面动态生成**", "进行中"]])]
        )
    }
}
