# 智能图表 v4：按录音内容类型路由的图表生成 — 设计文档

- 日期：2026-07-17
- 状态：已确认设计（待实施）
- 取代：`docs/SmartChart-ContentFirst-Design.md`（v3，"不做内容类型识别"的决策）；复活 `docs/Feature-SmartChart-v2.md` 的类型感知思路，但改为"类型 → 图表"固定一对一映射

## 1. 背景与问题

当前 ChartAgent v3（FastAPI + LangGraph，端口 8765）由 LLM 自由路由到 7 种通用图表（comparison/timeline/relationship/flow/action/quantitative/highlights）。实际效果差：以"决策/行动图"为例，图表内容只是把原始转写句子（带 ASR 噪声、口语碎片）原样贴进深色卡片，没有提炼成结构化信息，用户反馈"质量非常不好"。

根因有二：

1. **图表形式不可预期**：LLM 现场决定图表类型，选择不稳定、与内容类型不匹配。
2. **提取提示词是通用的**：不针对内容类型，提取不出该类型特有的结构（会议的决议/行动项、讲座的知识层级等）。

参考 Tencent SuperSonic 的图表自动选择原理：LLM 负责理解，**确定性规则负责选图表形式**（语义类型 + 守卫条件 + 安全兜底）。本设计将该模式落地为"录音内容类型 → 固定图表表达"。

## 2. 目标与非目标

### 目标

- 根据录音内容自动分类为七种类型之一：**会议 / 访谈 / 讲座 / 对话 / 演讲 / 随手记 / 其他**。
- 每种类型固定对应一种图表表达（一对一映射），每种图表由一个专属 skill 实现。
- 图表内容必须结构化提炼，禁止把原始转写句子直接当作图表主体内容。
- 渲染继续使用纯 HTML/CSS + 内联 SVG（无 JavaScript），保持现有 CSP 安全模型。
- 保留 v3 全部安全与质量机制（见 §8）。

### 非目标

- 不引入 ECharts 或任何 JS 图表库（不放开 `script-src 'none'`）。
- 不做一次生成多张图；仍是每次一张主图。
- 不改 Core Data 模型，不做图表持久化（维持按需生成）。
- 不做 v2 曾设想的"类型内多策略/多模板"；严格一对一。

## 3. 类型定义与边界

| 类型 | 定义 | 判别要点 |
|---|---|---|
| 会议 meeting | 多人、有议题、产出结论/待办 | 有结论导向；出现决议、分工、截止时间 |
| 访谈 interview | 一问一答、角色分明 | 采访者提问 vs 被访者回答的交替结构 |
| 讲座 lecture | 单人为主、系统传授知识 | "概念→讲解→例子"结构，教学口吻 |
| 对话 dialogue | 多人自由讨论、不求结论 | 话题漂移、无明确决议产出 |
| 演讲 speech | 单人、面向观众的感染力表达 | 故事+观点+金句，有情绪曲线设计 |
| 随手记 memo | 单人即兴记录（口播/语音备忘） | 短、无结构、第一人称备忘口吻 |
| 其他 other | 无法归入以上六类 | 兜底分类 |

易混边界的判定规则：**会议 vs 对话**看是否产出结论；**讲座 vs 演讲**看是传授知识还是感染说服。

## 4. 总体架构（v4 流水线）

```
转写片段 → prepare_transcript → classify_content（分类器，1 次 LLM 调用）
  → 按 content_type 从 skill 注册表取出专属 skill
  → skill 分块并行提取（≤4 并发）→ 合并 → 校验（+一次修复）→ SVG 模板渲染 → 片段校验
  → HTML 片段 → Swift ChartWebView
```

被替换的 v3 环节：`extract_candidates → merge_candidates → route_and_plan`（通用候选提取 + LLM 自由路由图表类型）。图表形式不再由 LLM 现场决定，改由"类型 → 图表"代码映射决定。

新增模块目录 `ChartAgent/agent/skills/`：

- `base.py` — skill 协议（Protocol）与共享类型
- `__init__.py` — 注册表 `SKILLS: dict[ContentType, ChartSkill]`
- `meeting.py` / `interview.py` / `lecture.py` / `dialogue.py` / `speech.py` / `memo.py` / `other.py` — 七个 skill，各自内聚：提取提示词、plan 模型、合并、校验、兜底、Jinja2 模板字符串

`nodes.py` 相应重构：新增 `classify_content` 节点；提取/渲染节点改为按 `state.content_type` 分发到注册表中的 skill。

## 5. 内容分类器

- **输入**：转写元信息（总时长、不同 speakerId 数量、片段数、总字符数）+ 采样文本（开头约 2000 字符 + 中间约 1000 + 结尾约 1000，受 token 预算约束）。
- **说话人信号**：speakerId 去重计数作为强提示写入提示词（多人 → 会议/访谈/对话；单人 → 讲座/演讲/随手记）。仅作提示，不做硬排除（speakerId 可能缺失或不准）。
- **提示词**：给出 §3 的类型定义与边界判定规则，要求输出 JSON `{content_type, confidence, reason}`，temperature 0.0，单次调用。
- **决策规则（确定性）**：
  - `confidence ≥ 0.6` → 采用所分类别；
  - `< 0.6` → `other`；
  - LLM 失败/超时/JSON 非法 → `other`；
  - 请求带 `forceContentType` → 跳过分类器，直接使用指定类型。
- **预算**：分类器预留约 10s；超时即归 `other`，不影响后续出图。

## 6. 七个 skill 的契约与图表定义

### 6.1 通用契约

每个 skill 实现：

```python
class ChartSkill(Protocol):
    content_type: ContentType       # 类型枚举
    chart_type: str                 # 图表类型标识
    display_name: str               # 图表中文名
    plan_model: type[BaseModel]     # 该类型的 plan Pydantic 模型
    def extraction_prompt(chunk, segment_index) -> str   # 分块提取提示词
    def merge(plans: list) -> BaseModel                  # 合并各分块 plan
    def validate(plan, segment_map) -> list[str]         # 溯源 + 进入条件校验
    def fallback(plan, segment_map) -> BaseModel | None  # 类型内兜底；None → 全局降级
    def render(plan) -> str                              # Jinja2 → HTML+SVG 片段
```

**贯穿所有 skill 的硬规矩**：

1. LLM 只产出结构化 JSON，永远不直接生成 HTML/SVG。
2. 图表中每条内容必须绑定真实 `segment_ids`（对照 `segment_map` 校验；伪造/未知 ID → 一次 LLM 修复 → 失败则降级）。
3. 所有文本经 Jinja2 自动转义（XSS 防护）。
4. 所有 SVG 几何（坐标、连线、弧线）由 Python 确定性计算，LLM 不碰坐标。
5. 规模守卫为确定性代码（supersonic 风格）；截断时图上标注"还有 N 项"。
6. 任何 skill 失败/内容不足的最终出口都是 `other` 的 highlights 图，保证任何录音都有输出。

### 6.2 类型 → 图表映射与各 skill 定义

| 类型 | chart_type | 图表 | 渲染 |
|---|---|---|---|
| meeting | `decision_board` | 决策行动看板 | HTML/CSS 卡片 |
| interview | `qa_cards` | 问答观点卡 | HTML/CSS 卡片 |
| lecture | `knowledge_tree` | 知识大纲树 | SVG 树（Python 布局） |
| dialogue | `topic_swimlane` | 话题泳道图 | SVG 泳道（Python 布局） |
| speech | `narrative_arc` | 叙事弧线图 | SVG 固定弧线 |
| memo | `idea_card` | 灵感要点卡 | HTML/CSS 卡片 |
| other | `highlights` | 重点句子 | 复用 v3 渲染器 |

**会议 · 决策行动看板** — `MeetingPlan {topics: [{title, conclusion: str|None, actions: [{text, owner: str|None, due: str|None}], segment_ids}]}`。提取议题 → 每议题的结论 + 行动项（事项/负责人/截止时间，须原文依据）。守卫：议题 ≤ 8、每议题行动项 ≤ 6。进入条件：≥1 个议题。议题无行动项时只显示结论；无议题 → highlights。

**访谈 · 问答观点卡** — `InterviewPlan {qas: [{question, key_answer, tags: [str] (≤3), segment_ids}]}`。提取问答对：问题、被访者核心回答（原话金句）、关键词标签。守卫：问答对 ≤ 10。进入条件：≥2 个问答对；否则 → highlights。

**讲座 · 知识大纲树** — `LecturePlan {topic, chapters: [{title, concepts: [{name, note: str|None}], segment_ids}]}`。三级结构：主题 → 章节 → 概念要点。守卫：章节 ≤ 8、每章概念 ≤ 6，超出折叠并标注"还有 N 项"。进入条件：≥2 章，或 ≥1 章且 ≥2 概念；否则 → highlights。布局：root 顶部居中，章节一排均布，概念在各章下方成列；Python 计算坐标，超高时 SVG viewBox 纵向扩展。

**对话 · 话题泳道图** — `DialoguePlan {speakers: [str], blocks: [{speaker, topic, summary: str|None, start, end, segment_ids}]}`（按 start 排序）。提取说话人列表 + 话题块（谁/话题/起止时间）。守卫：说话人 ≤ 4（超出合并为"其他人"）、话题块 ≤ 20。进入条件：≥2 个说话人且 ≥3 个话题块；否则 → highlights。布局：x 轴 = 真实时间比例，每个说话人一条泳道，块宽 ∝ 时长（设最小可读宽度）。

**演讲 · 叙事弧线图** — `SpeechPlan {stages: [{stage: opening|buildup|climax|closing, label, summary, quote: str|None, segment_ids}]}`。固定四段结构；climax 必须配金句原话。进入条件：≥3 段且含 climax；否则 → highlights。布局：固定三次贝塞尔弧线，四段在弧线上取固定参数位置，金句标注在高潮节点。

**随手记 · 灵感要点卡** — `MemoPlan {core_idea, points: [{text, segment_ids}]}`。提取一句话核心想法 + 要点列表。守卫：要点 ≤ 8。进入条件：core_idea 非空（要点可为空）；否则 → highlights。

**其他 · 重点句子** — 完整复用 v3 highlights 提取与渲染（重点原句按时间排序）。同时作为所有 skill 的全局兜底。

## 7. API 协议（v3 → v4）

- `API_VERSION = "4.0"`，`SERVICE_VERSION = "4.0.0"`（与 Swift 端 `expectedServiceVersion` 同步升级，旧后端由现有版本自检自动驱逐）。
- 请求 `SmartChartGenerateRequest` 新增可选字段 `forceContentType: ContentType | None`（默认 null = 自动分类）。其余字段不变（`version, requestId, recordingId, segments[], summaryMarkdown?`，`summaryMarkdown` 维持接收但不使用）。
- 响应 `SmartChartGenerateResponse` 新增 `contentType: str`、`contentTypeDisplayName: str`；`chartType/chartTypeDisplayName` 按 §6.2 映射返回。
- 多余字段拒绝、`extra="forbid"` 等 v3 契约纪律不变。

## 8. 保留的 v3 机制

- 端到端时间预算 105s（`CHART_TIME_BUDGET_SECONDS`），逐环节 deadline 传播，per-attempt 超时 = `min(cap, remaining)`。
- 分块并行提取（分块只在片段边界切分，并发 ≤ 4，单块失败不拖垮整体）。
- 提取截止 = 请求截止 − 25s 渲染/校验预留；修复需剩余 ≥ 12s；最后一刻超时也必须返回降级结果（v3 竞态修复保留）。
- 原文溯源校验、一次 LLM 修复、Jinja2 自动转义、渲染片段结构校验（`data-segment-ids`、标签平衡）。
- 结构化 JSON 日志（新增 `content_type`、分类耗时、skill 各阶段耗时）；不记录转写原文、提示词、密钥；日志轮转。
- Swift 端：WKWebView CSP（`script-src 'none'`）、`segmentTap` 点击跳音频、`ChartRequestGate` 单调令牌、版本自检驱逐旧后端。

## 9. Swift 端集成

- `ChartServiceManager`：`expectedServiceVersion` 升至 `"4.0.0"`（apiVersion 门 `"4.0"`）。
- `ChartSkill.swift`：新增 `ContentType` 枚举与 DTO 字段（`contentType/contentTypeDisplayName`），请求 DTO 新增可选 `forceContentType`。
- `RecordingDetailViewModel.generateChart(forcedType:)`：支持强制类型重新生成。
- 图表面板：头部类型标签显示"会议 · 决策行动看板"样式；"重新生成"按钮增加类型选择菜单（自动 + 七种类型），选择后以 `forceContentType` 重新生成——这是分类错误的手动安全阀。
- `ChartWebView` 不变。

## 10. 错误处理与降级链

1. 分类器 LLM 失败/超时/输出非法 → `other` → highlights。
2. 置信度 < 0.6 → `other` → highlights。
3. skill 提取：单块失败跳过；全部失败 → 类型内 fallback；仍无内容 → highlights。
4. plan 校验失败 → 一次 LLM 修复（剩余 ≥ 12s）→ 失败 → 类型内 fallback → highlights。
5. 任何环节超预算 → 返回当前可用的最好结果，至少保证 highlights。
6. 绝不白屏、绝不超时无响应；错误以结构化 errorCode 返回。

## 11. 测试策略

Python 端（`ChartAgent/tests/`，LLM 全部打桩）：

- **分类器**：七种类型典型样本各一，断言分类正确；置信度门槛生效；LLM 失败 → `other`；`forceContentType` 跳过分类器；说话人计数进入提示词。
- **每个 skill**：最小合法 plan 可渲染且含 `data-segment-ids`；伪造 segment_ids 被拒；空内容走类型内 fallback → highlights；规模守卫截断并标注；XSS 转义；进入条件不满足 → highlights。
- **端到端**：七种合成转写样本各跑完整流水线，断言 `contentType` 与 `chartType` 映射正确、降级链正确。
- **预算/竞态**：分类器超时 → `other`；提取超时 → 兜底；最后一刻超时仍返回降级结果（保留 v3 竞态回归）。
- **契约**：v4 版本号、`forceContentType` 生效、多余字段拒绝。

Swift 端（`Tests/AIRecordingTests/`）：v4 响应解码、版本门、`forceContentType` 请求构造、类型标签显示。

测试夹具：为七种类型各造一段短合成转写文本，长期复用。

## 12. 迁移说明

- 无需数据迁移（图表按需生成，无持久化）。
- 版本自检机制保证旧版后端进程被自动驱逐，用户无感切换。
- v3 的 7 种通用图表（comparison/timeline/relationship/flow/action/quantitative）随自由路由一并退役；highlights 保留为 `other` 与全局兜底。
