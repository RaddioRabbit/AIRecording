# AI 纪要代码围栏剥离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI 纪要显示和导出中不再出现 ```markdown / ``` 代码围栏标记，历史数据同样生效。

**Architecture:** 在 `LLMService` 中新增 `stripCodeFences` 函数；生成纪要保存前剥离，提示词增加约束；ViewModel 加载历史纪要时兜底剥离。

**Tech Stack:** Swift, SwiftUI, XCTest（无第三方依赖）

**Spec:** `docs/superpowers/specs/2026-08-04-summary-markdown-fence-strip-design.md`

**Note:** 计划中的 commit 步骤需先征得用户确认后再执行（项目规则：未经明确要求不做 git 提交）。

---

### Task 1: `stripCodeFences` 函数 + 单元测试

**Files:**
- Modify: `AIRecording/Services/LLMService.swift`
- Test: `Tests/AIRecordingTests/LLMServiceTests.swift`（新建）

- [ ] **Step 1: 写失败的测试**

新建 `Tests/AIRecordingTests/LLMServiceTests.swift`：

```swift
import XCTest
@testable import AIRecording

final class LLMServiceTests: XCTestCase {

    func testStripCodeFences_removesMarkdownFence() {
        let input = "```markdown\n# 会议纪要\n\n内容\n```"
        XCTAssertEqual(stripCodeFences(input), "# 会议纪要\n\n内容")
    }

    func testStripCodeFences_removesPlainFence() {
        let input = "```\n# 会议纪要\n```"
        XCTAssertEqual(stripCodeFences(input), "# 会议纪要")
    }

    func testStripCodeFences_keepsUnfencedText() {
        let input = "# 会议纪要\n\n内容"
        XCTAssertEqual(stripCodeFences(input), "# 会议纪要\n\n内容")
    }

    func testStripCodeFences_keepsInnerCodeBlock() {
        let input = "# 纪要\n\n```swift\nlet a = 1\n```\n\n结尾"
        XCTAssertEqual(stripCodeFences(input), input)
    }

    func testStripCodeFences_trimsSurroundingWhitespace() {
        let input = "  \n```markdown\n内容\n```\n\n"
        XCTAssertEqual(stripCodeFences(input), "内容")
    }
}
```

注意：`testStripCodeFences_keepsInnerCodeBlock` 中首行不是 ``` 开头、末行不是 ```，函数应原样返回（去除首尾空白后）。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter LLMServiceTests`
Expected: 编译失败，`stripCodeFences` 未定义。

- [ ] **Step 3: 实现 `stripCodeFences`**

在 `AIRecording/Services/LLMService.swift` 文件末尾（`LLMService` 类之外）添加：

```swift
/// Strips a leading/trailing markdown code fence (e.g. ```markdown ... ```)
/// that some LLMs wrap around their entire response.
func stripCodeFences(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var lines = trimmed.components(separatedBy: .newlines)
    guard lines.count >= 2,
          lines[0].hasPrefix("```"),
          lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" else {
        return trimmed
    }
    lines.removeFirst()
    lines.removeLast()
    return lines.joined(separator: "\n")
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter LLMServiceTests`
Expected: 5 个测试全部 PASS。

- [ ] **Step 5: Commit（需用户确认）**

```bash
git add AIRecording/Services/LLMService.swift Tests/AIRecordingTests/LLMServiceTests.swift
git commit -m "feat: strip markdown code fences from LLM summary output"
```

---

### Task 2: 保存前剥离 + 提示词约束

**Files:**
- Modify: `AIRecording/Services/LLMService.swift`

- [ ] **Step 1: `generateSummary` 返回前剥离**

将 `generateSummary` 中：

```swift
let prompt = buildSummaryPrompt(transcriptionText)
return try await sendChatRequest(prompt: prompt)
```

改为：

```swift
let prompt = buildSummaryPrompt(transcriptionText)
let raw = try await sendChatRequest(prompt: prompt)
return stripCodeFences(raw)
```

- [ ] **Step 2: 提示词增加约束**

`buildSummaryPrompt` 中 `输出格式使用 Markdown，语言与输入文本保持一致。` 改为：

```
输出格式使用 Markdown，语言与输入文本保持一致。直接输出 Markdown 正文，不要用 ``` 代码块包裹整个输出。
```

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: Build complete，无错误。

- [ ] **Step 4: Commit（需用户确认）**

```bash
git add AIRecording/Services/LLMService.swift
git commit -m "feat: strip code fences before saving summary; prompt LLM not to wrap output"
```

---

### Task 3: 历史纪要显示兜底剥离

**Files:**
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift:182`

- [ ] **Step 1: 加载时剥离**

将 `loadRecording()` 中：

```swift
self.summary = rec.transcription?.summary
```

改为：

```swift
self.summary = rec.transcription?.summary.map(stripCodeFences)
```

- [ ] **Step 2: 编译 + 全量测试**

Run: `swift build && swift test`
Expected: Build complete；全部测试 PASS。

- [ ] **Step 3: Commit（需用户确认）**

```bash
git add AIRecording/ViewModels/RecordingDetailViewModel.swift
git commit -m "fix: strip code fences when displaying previously saved summaries"
```
