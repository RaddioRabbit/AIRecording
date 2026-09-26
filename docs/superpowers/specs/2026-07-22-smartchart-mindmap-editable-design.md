# 智能图表 v5：统一思维导图 + 大纲编辑 + PNG 导出 — 设计文档

- 日期：2026-07-22
- 状态：已实施
- 取代：v4 的"类型 → 七种不同图表形式"渲染层（`docs/superpowers/specs/2026-07-17-smartchart-content-type-skills-design.md` §6.2 的渲染部分）；**保留** v4 的内容分类器与各类型提取逻辑

## 1. 背景与问题

v4 已上线"内容分类 → 七种专属图表"（决策看板/问答卡/知识树/泳道/叙事弧/要点卡/重点句子）。新需求：

1. **图表形式统一为思维导图**：不管录音内容是什么类型，智能图表只出一种图——思维导图。
2. **可编辑**：图表结构以数据形式返回 App，用户在大纲界面里改文字、增删节点（不能调层级），预览实时刷新。
3. **可导出**：编辑满意后把思维导图导出为 PNG 图片。

关键约束：现有渲染产物是 WKWebView 中的 HTML+SVG 片段，CSP `script-src 'none'`，**不能在图内做交互编辑**。因此编辑必须发生在原生大纲界面，改的是结构数据，预览由后端确定性重渲染。

## 2. 目标与非目标

### 目标

- 六种内容类型（会议/访谈/讲座/对话/演讲/随手记）的提炼结果统一渲染为**思维导图**（中心主题 + 左右两侧展开分支，XMind 风格）；`other` 维持 highlights 兜底。
- 响应携带思维导图**结构数据**（`mindMap`），App 端展示大纲编辑界面：改文字、删除节点、在分支下新增节点。
- 编辑后预览实时刷新：新增 `/chart/render` 纯渲染接口（不调用 LLM，秒级响应）。
- 导出 PNG：以当前编辑结果为准，导出完整全图。
- 保留 v4 的分类器、按类型提取、安全机制与降级链。

### 非目标

- 不做层级调整（拖拽、缩进提升/降级、跨分支移动节点）——编辑能力限定为"改文字 + 增删节点"。
- 不放开 CSP `script-src 'none'`，预览图内仍无任何脚本与交互。
- 不做图表/编辑结果持久化（维持按需生成；重新生成丢弃未导出的编辑）。
- 不改内容分类器与各类型提取提示词。
- 不做一次多张图。

## 3. 总体架构

```
转写片段 → prepare_transcript → classify_content（不变）
  → 按 content_type 取出专属 skill → 分块并行提取 → 合并 → 校验（+一次修复）（均不变）
  → 【新】plan → MindMapDoc 归一化（每个 skill 一个 to_mindmap(plan) 映射）
  → 【新】统一思维导图渲染器 MindMapRenderer：MindMapDoc → HTML+SVG 片段
  → 响应：htmlFragment（预览）+ mindMap（结构数据）→ Swift
```

Swift 端编辑回路：

```
大纲编辑（原生列表：改文字/删行/加行，300ms 防抖）
  → POST /chart/render（编辑后的 MindMapDoc，无 LLM）
  → 新 htmlFragment → 刷新 ChartWebView 预览
导出：对预览做全尺寸快照 → PNG 写盘（NSSavePanel）
```

被替换的 v4 环节：七个 skill 各自的 `render()` 模板（决策看板/问答卡/知识树/泳道/叙事弧/要点卡六种退役；`other` 的 highlights 渲染器保留为兜底）。

## 4. 统一思维导图数据模型（MindMapDoc）

所有类型的 plan 归一化为同一棵树，三级结构：

```python
MindMapDoc = {
    "root":  {"id": str, "text": str},                       # 中心主题
    "branches": [                                            # 一级分支（4–8 个为宜）
        {"id": str, "text": str, "segment_ids": [str],
         "children": [                                       # 要点
             {"id": str, "text": str, "segment_ids": [str]}
         ]}
    ]
}
```

- `id`：后端生成的稳定节点 ID（`"b0"`, `"b0c2"` 这类路径式 ID），供编辑回路定位。
- `segment_ids`：沿用 v4 溯源机制；**编辑过文字的节点和手动新增的节点 `segment_ids` 置空**，点它不跳音频。
- 规模守卫（确定性代码）：分支 ≤ 8；每分支要点 ≤ 6；超出截断并在该分支末尾加"还有 N 项"节点。文本超长（分支 > 20 字、要点 > 40 字）截断加省略号。

### 4.1 各类型 plan → MindMapDoc 映射

| 类型 | root | branches | children |
|---|---|---|---|
| meeting | 录音主题（overview） | 各议题 title | 该议题的结论 + 行动项 |
| interview | 录音主题 | 各问题（≤8） | 核心回答 + 关键词标签 |
| lecture | 主题 topic | 各章节 title | 概念名（+note） |
| dialogue | 录音主题 | 各话题 topic（≤8） | 摘要 + 说话人/起止时间 |
| speech | 录音主题 | 四段 stage label | summary + 金句 |
| memo | core_idea | 各要点（每条要点直接作为一级分支，≤8 条） | 无（要点无子节点） |
| other | —（不走思维导图，见 §7 降级） | — | — |

映射函数 `to_mindmap(plan) -> MindMapDoc` 内聚在各 skill 内，替换原 `render()`。

## 5. 统一思维导图渲染器（MindMapRenderer）

新增 `ChartAgent/agent/mindmap.py`，唯一的思维导图渲染模块：

- **布局**：root 垂直居中于画布左侧 1/4 处；分支按数量均分到左右两侧（奇数时右侧多一个），同侧分支纵向均布；要点在分支外侧成列。全部坐标由 Python 确定性计算，LLM 不碰几何。
- **连线**：root→分支、分支→要点用三次贝塞尔曲线。
- **尺寸**：固定宽度 1200pt，高度按内容纵向扩展（SVG viewBox 自适应），预览区可滚动，导出为完整全图。
- **样式**：沿用 v4 深色主题（`templates.py` 的 `DARK_CSS`/`BASE_TEMPLATE`），分支带类型无关的调色板循环色。
- **溯源**：保留 `data-segment-ids` 属性与渲染片段结构校验，点图跳音频机制不变。
- **安全**：所有文本经 Jinja2 自动转义；渲染产物仍过 `validate_render` 结构校验。

## 6. API 协议（v4 → v5）

- `API_VERSION = "5.0"`，`SERVICE_VERSION = "5.0.0"`；Swift 端 `expectedServiceVersion` 同步升级，旧后端由版本自检自动驱逐。
- `SmartChartGenerateRequest`：不变（`version` 字面量升 `"5.0"`）。
- `SmartChartGenerateResponse`：新增 `mindMap: MindMapDoc | None`（`chartType == "mind_map"` 时必带；降级为 highlights 时为 null，此时 App 不显示大纲编辑）。
- `SmartChartGenerateResponse`：新增 `overview: str | None`（总览条文案；App 在编辑重渲染时回传给 `/chart/render`，保证编辑后总览条不丢失）。
- `chartType` 统一为 `"mind_map"`（六种思维导图类型都一样；`other` 走 highlights 兜底，见 §7），`chartTypeDisplayName = "思维导图"`；头部标签显示"会议 · 思维导图"样式。
- 多余字段拒绝、`extra="forbid"` 纪律不变。

### 6.1 新增 `POST /chart/render`

纯渲染接口，供编辑回路使用：

- 请求 `{version, requestId, recordingId, mindMap: MindMapDoc, theme: str}`；响应 `{version, requestId, status, htmlFragment, errorCode?}`。
- 请求可选 `overview: str | None`：App 回传 generate 响应中的总览条文案，渲染器原样渲染总览条，编辑后不丢失。
- **不调用 LLM**、不做分类、不做提取；只做 MindMapDoc schema 校验（`extra="forbid"`、规模守卫同 §4）→ MindMapRenderer 渲染 → 结构校验。预算 10s。
- 节点文本同样经 Jinja2 转义；`segment_ids` 对照请求附带的信息校验——**render 请求不附 segments**，因此只校验 ID 格式（字符串数组），不与原文对照（伪造 ID 最坏后果是点击跳转到一个不存在的时间点，无安全风险）。
- 限流：复用进程内串行队列；失败返回结构化 errorCode，App 端保留上一版预览并提示"刷新失败，请重试"。

## 7. 错误处理与降级链

1. 分类器失败/低置信度 → `other` → highlights（无大纲编辑，仅预览）。同 v4。
2. skill 提取失败/内容不足 → 类型内 fallback → highlights。同 v4。
3. **新增**：plan → MindMapDoc 归一化后分支数 = 0 → 降级 highlights。
4. `/chart/render` 校验/渲染失败 → 返回 errorCode；App 保留上一版预览，大纲内容不丢。
5. 端到端 105s 预算、逐环节 deadline、最后一刻竞态修复等 v4 机制全部保留。
6. 绝不白屏；错误以结构化 errorCode 返回。

## 8. Swift 端集成

- `ChartServiceManager`：`expectedServiceVersion` 升至 `"5.0.0"`。
- `ChartSkill.swift`：新增 `MindMapDocDTO`（root/branches/children，含 id、text、segmentIds）；响应 DTO 新增 `mindMap`；新增 `render(mindMap:)` 请求 DTO。
- `RecordingDetailViewModel`：
  - 持有 `mindMapDoc: MindMapDocDTO?` 与编辑状态；大纲编辑操作（改文字/删节点/分支下加节点）修改本地 doc。
  - 300ms 防抖后调用 `/chart/render`，成功则更新 `htmlFragment`；走 `ChartRequestGate` 单调令牌防旧响应覆盖。
  - 重新生成（含 forceContentType）→ 丢弃本地编辑，以新响应为准。
- 图表面板 UI：
  - 头部：类型标签"会议 · 思维导图"、重新生成菜单（自动 + 七种类型，不变）、**新增"导出 PNG"按钮**（`mindMap != nil` 时可用）。
  - 上区：`ChartWebView` 预览（不变，可滚动）。
  - 下区：大纲编辑列表（原生 SwiftUI）。每行：缩进 + `TextField`；行尾悬停"删除"；每个分支末尾"+ 添加要点"。无拖拽、无缩进调整。
- PNG 导出：对 `ChartWebView` 做全内容尺寸快照（`WKWebView.takeSnapshot` 配置完整 rect）→ `NSImage` → PNG data → `NSSavePanel` 写盘，默认文件名 `<录音标题>-思维导图.png`。

## 9. 测试策略

Python 端（`ChartAgent/tests/`，LLM 全部打桩）：

- **to_mindmap 映射**：六种类型 plan 各一，断言 MindMapDoc 结构正确、segment_ids 保留、规模守卫截断并生成"还有 N 项"。
- **MindMapRenderer**：最小 MindMapDoc 可渲染且含 `data-segment-ids`；分支左右分配正确；XSS 转义；超高 viewBox 扩展。
- **`/chart/render`**：合法 MindMapDoc 往返渲染；非法字段拒绝（`extra="forbid"`）；空分支拒绝；不调用 LLM（打桩断言零调用）；10s 预算。
- **端到端**：七种合成转写样本跑完整流水线，六种类型断言 `chartType == "mind_map"` 且响应带 `mindMap`，`other` 样本断言走 highlights；分支数为 0 → highlights 降级链。
- **契约**：v5 版本号、`mindMap` 字段、多余字段拒绝。

Swift 端（`Tests/AIRecordingTests/`）：

- v5 响应解码（含 `mindMap`，highlights 时为 nil）。
- 大纲编辑：改文字/删节点/加节点后 doc 状态正确；编辑节点 segmentIds 置空。
- 防抖：连续编辑只触发一次 render 请求；`ChartRequestGate` 丢弃过期响应。
- 重新生成清空编辑状态；版本门 `"5.0.0"`。
- PNG 导出：快照数据非空、文件可写（用临时目录）。

测试夹具：沿用 v4 的七种类型合成转写样本；新增一份标准 MindMapDoc 夹具。

## 10. 迁移说明

- 无需数据迁移（图表按需生成，无持久化）。
- 版本自检驱逐旧后端，用户无感切换。
- v4 六种图表模板（decision_board/qa_cards/knowledge_tree/topic_swimlane/narrative_arc/idea_card）随本版本退役；highlights 渲染器保留为 `other` 与全局兜底。
