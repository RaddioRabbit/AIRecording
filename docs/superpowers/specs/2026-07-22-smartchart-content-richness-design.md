# 智能图表内容丰富化设计（v5）

- 日期：2026-07-22
- 状态：已获用户确认（方案一 + 厚版结构）
- 前置文档：`2026-07-17-smartchart-content-type-skills-design.md`（v4）
- 工作分支：`feature/smartchart-content-richness`（worktree：`../AIRecording-smartchart`）

## 1. 背景与问题

v4 上线后用户反馈：生成的智能图表**关于原录音的内容太少、缺少逻辑**，看图表无法理解录音讲了什么。

根因（代码级诊断）：

- 每个提取字段被提示词硬性限长（议题标题 ≤16 字、行动项 ≤25 字、讲座概念仅 ≤12 字的名字、对话 topic ≤10 字），normalize 阶段还有二次截断（如 `lecture.py` `name[:12]`）。
- 每类图表有总量守卫（4~10 个条目），图表天生只能装下"骨架碎片"。
- 字段已提取但未渲染：dialogue 的 `summary` 提取后模板不显示。
- 讲座 concept 的 `note`（一句话解释）在 v4 设计里存在，终审修复（`0eec3fd`）时被剔除。
- 所有图表缺少"这段录音整体讲了什么"的总览层；协议里的 `summaryMarkdown` 后端接收但不使用。

## 2. 目标与决策（来自用户确认）

- **范围**：七类内容图表全部加厚（meeting / interview / lecture / dialogue / speech / memo / other）。
- **目的**：用户看图表就能抓到**结论、待办、关键信息点**（不求逐字细节）。
- **厚度**：接近人工会议纪要——顶部总览 + 分区结构化（背景/要点/分歧/结论/行动）。
- **技术路线**：方案一——保持 v4"分块提取 → 合并 → 渲染"架构不动，只增强提示词、字段与模板，另加一步全局总览。不引入两阶段大纲生成（时间/复杂度代价不值）。

## 3. 总体结构（所有图表统一）

```
┌────────────────────────────────────┐
│ 标题 + 类型徽章（保留）              │
│ 总览条：一段话 + 关键统计（新增）      │
├────────────────────────────────────┤
│ 主体：各类型专属分区卡（加厚）        │
└────────────────────────────────────┘
```

通用规矩（沿用 v4，不变）：

- 每条内容绑定真实 `segment_ids`，点击图表元素跳转录音对应位置。
- 金句/引文必须逐字来自原文（`textutils` 校验）。
- 禁止编造原文没有的内容。
- 超长截断标注"还有 N 项"。
- 渲染产物仍为纯 HTML/CSS + 内联 SVG，无 JS（`ChartWebView` CSP `script-src 'none'` 不变）。

## 4. 新增：全局总览步骤（overview）

流水线位置：`classify_content` 之后、`extract_structured` 之前，新增 `generate_overview` 节点。

- 输入：全文采样（开头/中间/结尾，采样量大于分类器当前的 2000+1000+1000 字符）+ 内容类型。
- 输出：`overview` 字段——一段话（≤100 字），说清"这段录音讲了什么、定了什么结论、有哪些待办"；可附关键统计（如议题数、行动项数）。
- 独立时间预算 **15 秒**，失败/超时/低质 → `overview = null`，模板省略总览条，**不阻塞主流程**。
- 各类型模板在标题下渲染总览条（含 other/highlights 兜底）。

## 5. 各 skill 字段加厚与新限长

限长总体放宽约一倍；normalize 的 `[:N]` 截断与 `MAX_*` 守卫同步放宽；`llm_client` 的 `max_tokens` 4096 → 8192。

### 5.1 meeting · 决策行动看板

plan：`topics[]` 每项新增 `background`（≤60 字，可为 null）、`points[]`（≤4 条，每条 ≤50 字）、`disagreements[]`（≤2 条，每条 ≤40 字，可为空）。
调整：`title` ≤20 字；`conclusion` ≤60 字（可为 null）；`actions[].text` ≤40 字，owner/due 仅原文明确时填。
守卫：≤8 议题 ×（4 要点 + 2 分歧 + 6 行动项）。
渲染：议题卡 = 标题 + 背景 + 讨论要点列表 + 分歧/待定 + 结论高亮条 + 行动项行（owner/due 徽章）。

### 5.2 interview · 问答观点卡

plan：`qas[]` 的 `keyAnswer` 拆为 `answerPoints[]`（≤3 条，每条 ≤60 字，可为转述）+ `quote`（逐字原句，≤60 字，校验保留，可为 null）。
调整：`question` ≤30 字；tags 1~3 个不变。守卫 ≤10 问答对。
渲染：Q 卡 = 问题 + 回答要点列表 + 引文块 + 标签。

### 5.3 lecture · 知识大纲

plan：`concepts[]` 恢复 `note`（一句话解释，≤40 字，v4 设计曾有、终审被剔除，本次恢复）；`chapters[]` 新增 `points[]`（≤3 条讲解要点，每条 ≤50 字）。
调整：章节 title ≤16 字；concept name ≤16 字。守卫：8 章 × 6 概念。
渲染：章节卡 = 标题 + 讲解要点 + 概念列表（名字 —— 解释）。note 一律放在卡内概念列表中，不进 SVG 树节点（避免几何溢出，SVG 布局不变）。

### 5.4 dialogue · 话题泳道图

plan：`blocks[]` 的 `summary` 放宽至 ≤60 字；新增 `keyPoints[]`（≤2 条，每条 ≤40 字，可为空）。
调整：topic ≤14 字。守卫：≤4 泳道、20 块。
渲染：**补上 summary 的渲染**（v4 提取未显示）；块下展示 keyPoints。

### 5.5 speech · 叙事弧线图

plan：`stages[]` 新增 `points[]`（≤3 条，每条 ≤50 字）。
调整：label ≤14 字；summary ≤60 字；climax quote ≤40 字（逐字校验保留）。
渲染：弧线 4 节点保留，每阶段下方要点列表；高潮金句高亮。

### 5.6 memo · 灵感要点卡

plan：`points[]` 每项由字符串改为 `{text ≤40 字, detail ≤60 字（可 null）}`。
调整：coreIdea ≤40 字。守卫 ≤8 条。
渲染：coreIdea 顶部高亮 + 要点卡（text + 展开说明）。

### 5.7 other · highlights（兜底）

判定规则不变（纯正则）；仅新增总览条渲染与每条句子保留 说话人·时间。

## 6. 校验与合并

- `validate_plan` 适配新字段：`segment_ids` 溯源校验覆盖 points/answerPoints/keyPoints 等所有新列表字段；quote 逐字校验不变。
- 数字一致性校验不变。
- 合并（`merge_plans`）：新字段随主键去重合并（同议题的 points/disagreements 求并集，按各自守卫截断）。
- LLM 修复重试（剩余 ≥12s 时 1 次）逻辑不变。

## 7. 降级链

1. overview 失败/超时 → 渲染无总览条的图表（新增环节，唯一变化）。
2. 单 skill 提取/校验失败 → 类型内 fallback（v4 已有，简化版结构不变）。
3. 全局兜底 → highlights。
4. 总预算仍 105s（overview ≤15s，分类 ≤10s，其余不变）；Swift 侧 120s 超时不变。

## 8. Swift 侧

- 协议不变：响应仍以 `htmlFragment` 承载，`SmartChartGenerateResponse` 可选增加 `overview` 字段（仅调试/日志用途，不渲染）。
- `ChartPersistence` 兼容：旧 HTML 照常显示。
- UI 文案、重新生成菜单、点击跳转逻辑均不变。
- 如厚版图表普遍变高，仅可能微调 `ChartWebView` 高度策略（实现时确认，非必须）。

## 9. 测试

Python（`ChartAgent/tests/`）：

- 每个 skill：新字段的 normalize 截断/守卫单测、validate 溯源单测、fallback 单测（更新现有 fixture）。
- `generate_overview` 节点：mock LLM 的正常/超时/坏 JSON 三分支单测。
- 端到端：七类各一份样本转写 → render 快照，断言总览条与新分区结构存在、`data-segment-ids` 存在、div 平衡。

Swift：无新增测试；`swift build && swift test` 全绿确认无回归。

## 10. 非目标（YAGNI）

- 不做两阶段大纲生成、不做图表类型新增、不做交互式展开/折叠（HTML 无 JS）。
- 不改分类器阈值与七类映射。
- 不动 v1/v2 遗留实体（ChartJob/ChartNode/ChartEdge）。
- 不做多语言总览（沿用转写原文语言）。
