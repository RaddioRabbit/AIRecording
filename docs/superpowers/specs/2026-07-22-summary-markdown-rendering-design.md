# AI 纪要 Markdown 渲染设计

日期：2026-07-22
分支：`fix/summary-markdown`（worktree：`AIRecording-markdown-fix`）

## 问题

录音详情页的「AI 纪要」用 `Text(summary)` 原样显示 LLM 返回的 Markdown 字符串，`##`、`**`、`-` 等标记符号直接裸露在界面上（见需求截图）。

根因：`AIRecording/Views/RecordingDetailView.swift` 的 `summaryView` 中 `Text(summary)` 不做任何 Markdown 解析。

## 方案选型

1. `Text(AttributedString(markdown:))` 一行替换 —— 行内样式（加粗）可渲染，但 SwiftUI 不会为 `#` 标题块应用字号层级，标题失去视觉区分。
2. **自写轻量 Markdown 渲染视图（采用）** —— 按行解析块级元素（标题/无序列表/有序列表/段落），块内用 `AttributedString(markdown:)`（`.inlineOnlyPreservingWhitespace`）渲染行内样式。约 130 行，零新依赖，符合项目"无第三方包"约定。
3. 引入 MarkdownUI 三方库 —— 效果最好但破坏零依赖约定，超出本需求范围。

## 设计

### 组件

新文件 `AIRecording/Views/MarkdownTextView.swift`，包含三部分：

- `MarkdownTextView: View` —— 接收原始 markdown 字符串，`VStack` 渲染所有块：
  - 标题：`#` → `.title3.bold()`，`##` → `.headline`，`###` 及以下 → `.subheadline` 半粗，顶部留 6pt 间距
  - 无序列表：圆点 `•` + 文本，左缩进 8pt，基线对齐
  - 有序列表：编号（等宽数字）+ 文本
  - 段落：普通正文
  - 表格：表头加粗 + 灰底，斑马纹数据行，细分隔线 + 圆角外框（`MarkdownTableView`，`LazyVGrid` 实现，兼容 macOS 13）
- `MarkdownBlockParser` —— 纯函数 `parse(_:) -> [MarkdownBlock]`，按行切块：
  - `#`–`######` + 空格 → 标题（无空格不识别，按段落兜底）
  - `- ` / `* ` / `• ` → 无序列表
  - `数字.` / `数字)` + 空格 → 有序列表
  - `|` 开头且下一行是分隔行（`|---|:-:|---:|`，冒号对齐标记可选）→ 表格；无分隔行不识别，按段落兜底；列数不齐的行截断/补空对齐表头
  - `---` / `***` / `___` → 水平线，跳过不渲染
  - 空行分隔块；连续普通行合并为一个段落
  - 行内标记（`**bold**` 等）原样保留在文本中，交给视图层 `AttributedString` 渲染（表格单元格同样支持）
- `MarkdownBlock: Equatable` —— `heading(level:text:)` / `bullet(text:)` / `numbered(index:text:)` / `paragraph(text:)` / `table(headers:rows:)`

### 兜底

任何无法识别的行按普通段落显示；`AttributedString` 解析失败时回退为原始字符串。任何输入都不会比现状（纯文本）更差。

### 接入点

`RecordingDetailView.swift` `summaryView` 中 `Text(summary)` 替换为 `MarkdownTextView(markdown: summary)`，保留原有 `.font(.body)`、`.lineSpacing(6)` 和 `ScrollView` + 400pt 高度限制。

### 不改动的部分

- `DocxExportService` 的 Word 导出（`导出 Word` 按钮）走独立路径，不在本次范围。
- LLM prompt 不改 —— 输出仍是 Markdown，只是显示端正确渲染。

## 测试

`Tests/AIRecordingTests/MarkdownBlockParserTests.swift`：标题层级、无空格标题兜底、无序/有序列表、行内标记保留、多行段落合并、空行分块、水平线跳过、典型纪要混合内容、空输入、表格（基本解析、对齐冒号、无分隔行兜底、列数不齐归一化、表格后接段落、单元格行内标记保留），共 17 个用例。

验证：`swift build` 通过；`swift test --filter MarkdownBlockParserTests` 17/17 通过。
