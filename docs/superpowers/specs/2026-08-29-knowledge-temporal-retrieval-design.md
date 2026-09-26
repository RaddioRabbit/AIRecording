# 知识库时间感知问答(时间词识别 + 按日期取内容)设计

- 日期:2026-08-29
- 状态:已获用户批准(实现方案选"方案一:规则识别",聚焦范围选"最新 1 场、最近 3 场")
- 关联:`2026-08-12-recording-knowledge-rag-design.md`(RAG 主设计,本设计在其 §8 检索流程前增加时间意图步骤)、`2026-08-29-knowledge-config-completion-design.md`、`2026-08-29-knowledge-multi-provider-design.md`

## 1. 背景与问题

知识库 RAG 多路召回(FTS5 关键词 + 向量语义 + 纪要路由 + RRF + rerank)已实现。录音的日历时间(`documents.recorded_at`,来自 Swift 提交的 `recording.createdAt`)与切片音频内时间(`chunks.start_time/end_time`)均已入库,但存在三个断层:

| 断层 | 现状代码位置 |
|---|---|
| 排序不看时间 | `retrieval.py` 仅按 BM25/余弦排名经 RRF 融合,`recorded_at` 不参与 |
| AI 看不到日期 | `context.py::_render_parent` 只渲染 recording_id/segment_ids/片内秒数/说话人,无标题无录制日期 |
| 查询不可表达 | 问题中的"最新/最近"没有任何处理路径,只能靠字面撞词 |

结果:问"最新的音频内容是什么"返回的不是最新录音的内容。

**根因修复不需要重建索引**:`recorded_at` 已在库,只改检索逻辑、证据渲染与提示词。

## 2. 已确认的产品决策(与用户逐项确认)

| 议题 | 结论 |
|---|---|
| 实现方案 | 方案一:规则识别时间词,按日期锁定录音后在其内检索;不采用 LLM 意图抽取(每次问答多一次模型调用)与全局时间加权(污染普通问题排序) |
| "最新" | 日期最近的 1 场录音 |
| "最近" | 日期最近的 3 场录音 |
| "最早" | 日期最早的 1 场(与"最新"同一路径反向,顺带支持) |
| 普通问题 | 行为必须与现状完全一致 |

## 3. 目标 / 非目标

**目标:**

1. 问题含时间排序词时,确定性锁定目标录音(最新 1 场/最近 3 场/最早 1 场)并在目标范围内检索或概括。
2. 每段证据渲染录音标题与录制日期,LLM 可见;来源胶囊显示日期,用户可见。
3. 纯时间问题("最新的音频内容是什么")不依赖 embedding/rerank,降级路径下仍可回答。
4. 无时间词的问题检索行为零变化。

**非目标:**

- 不解析具体日期与范围说法("上周三的会""9月的会""近一个月")。
- 不做界面时间筛选器。
- 不改分块、embedding、SQLite schema,不需要重建索引。
- 不动录音、转写、纪要、聊天持久化链路。

## 4. 时间意图识别(Python 新模块 `agent/temporal.py`)

仅对**当前问题**做包含匹配(时间词绝不从追问历史中检测,防止历史中的"最新"劫持非时间追问;上一条用户问题仅在无时间词时拼接进内容检索文本,沿用主设计 §8.1),按表序命中即停:

| 顺序 | 触发词 | 意图 |
|---|---|---|
| 1 | 最新一次、最新一场、上一场、上一个、刚刚、最后一场 | 最新 1 场 |
| 2 | 最新 | 最新 1 场 |
| 3 | 最近一次、近期、这几天、最近几场 | 最近 3 场 |
| 4 | 最近 | 最近 3 场 |
| 5 | 最早、第一场、第一次、最开始 | 最早 1 场 |

- 具体短语先于宽泛词,避免"最近一次"被"最近"提前命中。
- 触发词表为内置常量,不进用户设置(沿用主设计 §8.3 参数原则)。
- 已知局限:"最新"作为子串出现在无关词中会误触发,第一版接受;词表按真实误报再收紧。
- 剔除时间词(strip):从检索文本中移除命中的触发词后得到 `core`。

### 4.1 纯时间问题判定(is_generic)

`core` 再移除通用填充词(音频、内容、录音、会议、说了什么、讲了什么、什么)后剩余有效字符数 < 2,判定为纯时间问题,走概括路径;否则走限定检索路径。

## 5. 检索流程改造(`agent/retrieval.py`)

```
retrieve(query):
  intent = temporal.detect(query)
  if intent is None: 现有四路流程原样执行
  else:
    targets = store.recording_ids_by_recency(intent.order, intent.limit)   # 新 store 方法
    if not targets: 落回现有流程(空库自然走拒答)
    core = temporal.strip(query)
    if temporal.is_generic(core):   # 路径 B:概括
        parents = store.sample_generation_parents(targets)   # 每场 max(1, ⌈6/场数⌉) 个
        证据直接由父块构建(复用 _render_parent),不走 RRF/rerank
    else:                           # 路径 A:限定检索
        summary 路由跳过(目标已定)
        四路退化为目标内两路:search_vector/search_fts 传 recording_ids=targets
        RRF → rerank 流程不变
```

- `recording_ids_by_recency`:`documents` 表按 `recorded_at DESC/ASC` 排序,同日并列时按 `created_at DESC, rowid DESC` 决出稳定顺序。
- `sample_generation_parents`:对每场录音按 `chunk_index` 排序的 generation 父块均匀抽样,首块必取,覆盖会议首中尾;不足时全取。每场抽样数 = `max(1, ⌈max_parents / 场数⌉)`(max_parents 即现有常量 6),保证总父块数不超过现有证据块预算;多场录音按日期新→旧依次取样。
- 路径 A 中目标录音内检索不到证据(如"最新会议里预算怎么定的"而该会未提预算)→ 走现有空证据拒答,不回退到全库检索(保持"答案必须来自回答所指范围"的直觉)。
- 路径 B 证据顺序:录音按日期新→旧,录音内按 chunk 顺序,sourceId 依此编号。

## 6. 证据元数据与提示词

### 6.1 证据来源(schema.py / context.py / store.py)

- `EvidenceSource` 新增 `title: str`、`recordedAt: str`(ISO 日期 `YYYY-MM-DD`)。
- `store` 新增 `documents_meta(recording_ids) -> dict[recording_id, (title, recorded_at)]`(单条 IN 查询)。
- `_render_parent` 头部在 `recording_id:` 之前增加两行:`title:`、`recorded_at:`。

### 6.2 回答提示词(answering.py)

在严格证据规则中追加一条:"每条来源标注了录音标题与录制日期;涉及'最新/最近/最早/时间先后'的问题,必须依据来源日期作答,不得推测任何未出现的日期。"

### 6.3 SSE 与 Swift

- `sources` 事件随 `EvidenceSource` 自然携带新字段;Swift 侧 `Codable` 忽略未知字段,无需改 DTO 即可兼容。
- 来源胶囊 UI 显示日期:Swift 从 Core Data `Recording.createdAt` 取值,胶囊由"标题"改为"标题 · yyyy/MM/dd";录音已删除时维持现状("录音已删除",禁用跳转)。
- KnowledgeAgent service version 递增,防止复用旧进程(沿用 §5.1 版本校验机制);Python/Swift 同仓库同发布,无跨版本兼容负担。

## 7. 降级与边界

| 场景 | 行为 |
|---|---|
| 空知识库 | `targets` 为空,落回现有流程,空证据拒答 |
| embedding 不可用 + 路径 A | 目标内 FTS-only(现有降级语义收窄到目标范围) |
| embedding/rerank 均不可用 + 路径 B | 照常回答(路径 B 天然不依赖两者) |
| 目标内检索无证据 | 空证据拒答,不回退全库 |
| 时间词只认当前问题 | 历史消息含"最新"不触发时间分支;历史拼接仅用于无时间词问题的内容检索 |
| 同日多场录音 | `created_at` 决胜,顺序稳定 |

## 8. 测试策略

Python(pytest):

- 触发词表逐条匹配、短语优先于宽泛词、无时间词不触发、历史消息中的时间词不触发(防劫持,含回归用例);
- strip 与 is_generic 判定(纯时间/半实质/全实质);
- `recording_ids_by_recency` 排序、方向、limit 与同日决胜;
- `sample_generation_parents` 均匀抽样(0/1/6/20 个父块)与多场顺序;
- 路径 A 只返回目标录音 chunks 且跳过 summary 路由;路径 B 不调用 reranker(注入 spy 断言);
- `EvidenceSource` 新字段、`_render_parent` 渲染行、提示词包含日期规则;
- 无时间词且无上一条用户历史时,检索行为与现状逐字节一致;有历史时按主设计 §8.1 融合历史(均有回归用例)。

Swift(XCTest):

- Core Data `Recording.createdAt` 到来源胶囊展示文本的装配(含删除态)。

手工验收:

1. 问"最新的音频内容是什么" → 返回日期最新录音的内容,来源胶囊日期正确;
2. 问"最近讲了什么" → 覆盖最近 3 场;
3. 问普通问题 → 行为与现在一致;
4. 移除语义服务 Key → "最新"问题仍可回答(路径 B);
5. 同一天多场录音 → "最新"取其中 created_at 最新一场。

## 9. 文件改动清单

| 文件 | 改动 |
|---|---|
| `KnowledgeAgent/agent/temporal.py`(新) | 触发词表、detect/strip/is_generic |
| `KnowledgeAgent/agent/store.py` | `recording_ids_by_recency`、`sample_generation_parents`、`documents_meta` |
| `KnowledgeAgent/agent/retrieval.py` | 时间意图分支、路径 A 限定检索、路径 B 概括 |
| `KnowledgeAgent/agent/context.py` | `_render_parent` 增加 title/recorded_at 行;路径 B 直接由父块构建证据的入口 |
| `KnowledgeAgent/agent/schema.py` | `EvidenceSource` 加 `title`/`recordedAt` |
| `KnowledgeAgent/agent/answering.py` | 提示词日期规则 |
| `KnowledgeAgent/agent/main.py` | service version 递增 |
| `AIRecording/Views/RecordingDetailView.swift`(来源胶囊所在视图) | 胶囊显示"标题 · 日期" |
| 两侧测试文件 | §8 用例 |
