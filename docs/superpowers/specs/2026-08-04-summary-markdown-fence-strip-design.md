# 设计：剥离 AI 纪要中的代码围栏标记

日期：2026-08-04
状态：已确认

## 背景

AI 纪要功能调用 DeepSeek 生成会议纪要。模型有时会把整个输出包裹在 ```` ```markdown ... ``` ```` 代码块中，App 将原始文本直接存入 Core Data 并渲染，导致纪要开头显示 ```` ```markdown ````、结尾显示 ```` ``` ````（见用户截图）。

## 目标

界面显示和「导出 Word」中均不再出现代码围栏标记，包括历史已生成的纪要。

## 方案（已选定：方案 A）

### 1. 新增剥离函数 `stripCodeFences`

位置：`AIRecording/Services/LLMService.swift`（文件内私有函数即可，纪要由该服务产出）。

逻辑：

- 文本去首尾空白后，若第一行以 ```` ``` ```` 开头（如 ```` ```markdown ````、```` ``` ````）且最后一行是 ```` ``` ````，剥掉首行围栏和末行围栏，返回中间内容。
- 否则原样返回。

### 2. 保存前剥离

`LLMService.generateSummary`（或 `sendChatRequest` 返回处）在返回结果前调用 `stripCodeFences`，保证存入 Core Data 的 `Transcription.summary` 是干净文本。

### 3. 提示词约束

`buildSummaryPrompt` 中增加一句：直接输出 Markdown 正文，不要用 ``` 代码块包裹整个输出。

### 4. 旧数据兜底

`RecordingDetailViewModel` 加载已有纪要处（`self.summary = rec.transcription?.summary`）也过一遍 `stripCodeFences`，历史脏数据显示时不再带标记。函数需对 ViewModel 可见（internal 即可）。

### 5. 验证

- `swift build` 编译通过。
- 单元测试：带 ```` ```markdown ```` 围栏的样本剥离后无围栏；不带围栏的样本原样返回；`swift test` 通过。

## 不做的事（YAGNI）

- 不处理正文中合法的代码块（纪要正文内嵌代码块不在本次范围，实际场景几乎不会出现）。
- 不迁移/清洗数据库中已存的脏数据（显示层兜底已覆盖）。
