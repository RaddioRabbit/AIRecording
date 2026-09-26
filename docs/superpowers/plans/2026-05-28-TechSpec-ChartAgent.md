# Chart Agent 技术规格文档（TechSpec-ChartAgent.md）撰写计划

> **For agentic workers:** 本计划为单文档撰写任务，无需子代理，直接 inline 执行。

**Goal:** 基于 PRD v1.1 和现有代码上下文，撰写完整的 TechSpec-ChartAgent.md 技术规格文档，保存到 `/Volumes/HP P900/mac/WorkPlace/AIRecording/docs/TechSpec-ChartAgent.md`。

**Architecture:** 文档为纯 Markdown 技术规格，包含 12 个章节，覆盖 Swift + Python 双端实现细节、完整代码片段、架构决策和落地路径。

**Tech Stack:** Markdown, Swift 5.9, Python 3.10+, FastAPI, LangGraph, Jinja2, WKWebView

---

### Task 1: 收集并锁定所有输入源

**Files:**
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/docs/PRD-v1.1-ChartAgent.md`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/docs/TechSpec-v1.0.md`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/Package.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/Services/LLMService.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/Views/RecordingDetailView.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/ViewModels/RecordingDetailViewModel.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/Services/AudioRecordingService.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/Services/TranscriptionService.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/Services/AudioPlayerService.swift`
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/AIRecording/Services/PersistenceController.swift`

- [x] **Step 1: 读取所有输入源**
  已在前面步骤完成，所有文件已读取并缓存上下文。

- [x] **Step 2: 确认 PRD v1.1 关键接口定义**
  - 输入协议 JSON Schema（4.1.4 节）
  - 输出协议 JSON Schema（4.1.4 节）
  - Chart Skill Protocol（4.5.2 节）
  - Core Data 模型扩展（第 5 章）
  - 暗黑极客风 CSS 变量（4.3.3 节）
  - 6 大图表类型决策矩阵（4.1.3 节）

- [x] **Step 3: 确认现有代码约束**
  - macOS 13+，Swift 5.9，零 SPM 依赖
  - 现有服务全为 `static let shared` 单例模式
  - ViewModels 全为 `@MainActor` + `ObservableObject`
  - Core Data 为程序化模型（非 .xcdatamodeld 文件）
  - Combine 用于服务→ViewModel 通信

---

### Task 2: 撰写 TechSpec-ChartAgent.md 完整文档

**Files:**
- Create: `/Volumes/HP P900/mac/WorkPlace/AIRecording/docs/TechSpec-ChartAgent.md`

**文档结构（12 章）：**

1. 概述
2. 架构总览
3. 渲染方案（详细技术决策）
4. LangGraph Agent 架构（核心实现）
5. Swift 侧实现
6. Python 侧实现
7. Skill 接口规范
8. Swift-Python 集成方案
9. 数据流时序图
10. 技术风险与缓解
11. 落地路径
12. 文件清单

**撰写策略：**
- 所有代码片段必须完整、可编译/可运行
- Swift 代码仅使用 macOS 13 可用 API
- Python 代码仅使用标准库 + FastAPI + LangGraph
- 与 PRD v1.1 的接口定义、数据模型、CSS 变量保持一字不差
- 暗黑极客风 CSS 变量与 PRD 完全一致

---

### Task 3: 自检与验证

**Files:**
- Read: `/Volumes/HP P900/mac/WorkPlace/AIRecording/docs/TechSpec-ChartAgent.md`（撰写完成后读取验证）

- [ ] **Step 1: 章节完整性检查**
  确认 12 个章节全部存在，无遗漏。

- [ ] **Step 2: 代码可执行性检查**
  - Swift 代码无 macOS 14+ 专属 API
  - Python 依赖无 exotic 包
  - JSON Schema 与 PRD v1.1 一致

- [ ] **Step 3: 与 PRD v1.1 一致性检查**
  - 输入/输出协议字段一致
  - CSS 变量值一致
  - 图表类型枚举一致
  - 决策矩阵权重一致

- [ ] **Step 4: 文件成功创建确认**
  `ls -la /Volumes/HP P900/mac/WorkPlace/AIRecording/docs/TechSpec-ChartAgent.md`

---

**执行方式：** Inline Execution — 直接在本会话中撰写完整文档并保存。
