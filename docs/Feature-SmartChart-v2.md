# SmartChart v2 — 内容感知智能图表重构

## Feature Ticket

| 项目 | 内容 |
|------|------|
| 文档版本 | v2.0 |
| 撰写日期 | 2026/05/30 |
| 对应 PRD | PRD-v1.0.md、PRD-v1.1-ChartAgent.md |
| 对应 TechSpec | TechSpec-v1.0.md、TechSpec-ChartAgent.md |
| 文档状态 | 待 CEO / 架构师确认 |
| 上游输入 | CEO 技术调研结论 |

---

## 1. 问题陈述

### 1.1 当前系统痛点

当前 ChartAgent（v1.1）存在四个结构性缺陷，导致"智能图表"功能名不副实：

| # | 痛点 | 具体表现 | 影响 |
|---|------|----------|------|
| 1 | **内容输入断层** | ChartAgent 接收的是 LLMService 已结构化的"会议纪要 Markdown"，而非原始转录文本。纪要本身已被格式化为"会议主题 / 参与人 / 关键决策 / 待办事项"，导致 ChartAgent 的输入已丢失原始内容的自然结构。 | 图表只能反映"会议纪要格式"，无法反映"内容本身结构"。 |
| 2 | **数据提取硬编码会议概念** | `data_extract` 的 mindmap prompt 明确要求按"参与人、核心观点、关键讨论、决策/结论、待办事项"组织；`_fallback_extract` 以"会议主题"为根节点。 | 非会议内容（访谈、讲座、播客）被强制套入会议模板，输出失真。 |
| 3 | **内容类型识别缺失** | 系统仅有"图表类型选择"（基于日期/百分比/数字等特征判断用时间线还是饼图），没有"对话内容类型识别"（这是访谈还是会议还是讲座）。 | 同一套提取策略和模板被应用于本质不同的内容，导致图表与内容不匹配。 |
| 4 | **模板呆板** | 当前 mindmap 模板渲染的是分类网格卡片（根节点 + 分类列 + 子节点），用户反馈"太呆板"；所有内容类型共用同一套视觉布局。 | 视觉呈现缺乏内容针对性，用户感知为"千篇一律的机器人输出"。 |

### 1.2 根因分析

```
原始转录文本 ──▶ LLMService（纪要生成）──▶ 会议纪要 Markdown
                                                    │
                                                    ▼（输入给 ChartAgent）
                                            ChartAgent 的 State 字段：
                                            - theme: "会议主题"
                                            - participants: ["参与人"]
                                            - key_decisions: ["决策"]
                                            - action_items: [{待办}]
                                            - timeline: ["时间线"]
                                            - markdownContent: "完整纪要"
                                                    │
                                                    ▼
                                            text_analysis 只能分析"纪要格式特征"
                                            （层级、条件、日期、数值）
                                                    │
                                                    ▼
                                            chart_type_select 基于格式特征选图表类型
                                            （mindmap / flowchart / timeline / ...）
                                                    │
                                                    ▼
                                            data_extract 的 prompt 硬编码会议概念
                                            （"从会议纪要中提取..."）
                                                    │
                                                    ▼
                                            模板渲染：所有内容共用同一套视觉模板
```

**核心问题**：整个流水线假设输入永远是"会议纪要"，没有内容类型感知层。

---

## 2. 目标与成功标准

### 2.1 业务目标

让"智能图表"真正智能——图表的类型、结构、视觉风格都应与**内容的自然类型**相匹配，而非与**纪要的格式**相匹配。

### 2.2 成功标准（可量化）

| 指标 | 当前值 | 目标值 | 测量方式 |
|------|--------|--------|----------|
| 内容类型识别准确率 | N/A（无此能力）| >= 85% | 人工标注 100 条测试样本 |
| 图表与内容类型匹配满意度 | 低（用户反馈"呆板"）| >= 4.0/5.0 | 用户问卷（20 人内测）|
| 非会议内容的图表可用率 | < 30%（强制套模板导致失真）| >= 80% | 人工评估 50 条非会议样本 |
| 数据提取 prompt 中会议专属词汇出现率 | 100% | 0% | 代码审查 + prompt 文本扫描 |

---

## 3. 范围边界

### 3.1 范围内（In Scope）

#### v2.0 核心改造（本 Feature Ticket 覆盖）

1. **内容类型识别层（Content Type Detection）**
   - 基于原始转录文本（+ 可选的纪要文本）识别内容类型
   - 规则引擎 + 轻量 LLM 混合策略
   - 输出内容类型标签 + 置信度

2. **内容类型 -> 图表策略映射（Chart Strategy Mapping）**
   - 每种内容类型定义：首选图表类型、备选图表类型、禁用图表类型
   - 每种内容类型定义：数据提取策略、视觉风格策略

3. **数据提取策略去会议化（Data Extraction Refactor）**
   - 移除所有 prompt 中的"会议纪要""参与人""待办事项"等会议专属硬编码
   - 改为基于内容自然结构的通用提取框架
   - 提取维度：主题/实体、关系、时间、数值、观点、情绪/语气

4. **内容感知图表类型扩展**
   - 新增内容类型专属图表模板（非通用模板的参数调整，而是新的模板类型）
   - 访谈：人物关系图、观点对比图
   - 讲座：知识图谱、章节大纲图
   - 日常对话：话题情绪流图
   - 播客：话题时间线 + 嘉宾发言分布图

5. **前后端接口改造**
   - Swift 端：请求体增加 `rawTranscription` 和 `contentTypeHint` 字段
   - Python 端：StateGraph 新增 `content_type_detect` 节点，调整节点顺序

### 3.2 范围外（Out of Scope）

| # | 项目 | 说明 | 后续迭代 |
|---|------|------|----------|
| 1 | 实时图表生成 | 录音过程中实时生成图表 | v2.1+ |
| 2 | 用户自定义内容类型 | 用户训练自己的内容类型分类器 | v2.2+ |
| 3 | 多语言内容类型识别优化 | 当前优先中文和英文 | v2.1+ |
| 4 | 3D 图表 / 动态数据图表 | 视觉维度扩展 | v3.0 |
| 5 | 图表交互编辑（拖拽、增删节点）| 已在 v1.1 规划，本 ticket 不改动 | v1.1 延续 |
| 6 | 替换 WKWebView 渲染引擎 | 渲染层不变，仅模板和 CSS 调整 | v2.1+ |
| 7 | 云端模板市场 | 模板本地管理 | v3.0 |

### 3.3 改造边界说明

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Swift 端（前端）                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐  │
│  │ Recording    │  │ Recording    │  │ ChartPanelView           │  │
│  │ ListView     │  │ DetailView   │  │ （WKWebView 渲染不变）    │  │
│  └──────┬───────┘  └──────┬───────┘  └──────────────────────────┘  │
│         │                 │                                         │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────────────────────────┐  │
│  │RecordingList │  │RecordingDetail│  │ ChartGeneration         │  │
│  │ViewModel     │  │ViewModel      │  │ ViewModel                │  │
│  └──────────────┘  └──────┬───────┘  │ 【改造】组装请求时增加    │  │
│                           │          │ rawTranscription 字段     │  │
│              ┌────────────┼──────────│ 和 contentTypeHint 字段   │  │
│              ▼            ▼          └──────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                      Services（Singletons）                    │  │
│  │  AudioRecordingService  TranscriptionService                  │  │
│  │  LLMService（纪要生成） PersistenceController                  │  │
│  │  HTTPChartSkill 【改造】请求体字段扩展                         │  │
│  │  ChartServiceManager 【不变】服务生命周期                      │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│                              ▼ HTTP POST /chart/generate            │
│                              （请求体增加 raw_transcription 字段）   │
└─────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼ localhost:8765
┌─────────────────────────────────────────────────────────────────────┐
│                      Python FastAPI Service                         │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  FastAPI Router                                              │  │
│  │  POST /chart/generate 【改造】解析新字段，组装 State          │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  LangGraph Agent（StateGraph）【核心改造】                    │  │
│  │                                                              │  │
│  │  [Start] ──▶ content_type_detect ──▶ text_analysis          │  │
│  │              【新增】识别内容类型    【改造】基于类型调整特征   │  │
│  │                      │                                       │  │
│  │                      ▼                                       │  │
│  │              chart_type_select ──▶ data_extract             │  │
│  │              【改造】类型->策略映射  【改造】去会议化提取      │  │
│  │                      │                                       │  │
│  │                      ▼                                       │  │
│  │              chart_generate ──▶ validate ──▶ [End]          │  │
│  │              【改造】内容感知模板   【不变】                  │  │
│  │                                                              │  │
│  └──────────────────────────────────────────────────────────────┘  │
│                              │                                      │
│                              ▼                                      │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Jinja2 Template Engine 【改造】                              │  │
│  │  base.html.j2（暗黑极客风 CSS 变量不变）                      │  │
│  │  mindmap.html.j2 【改造】通用化，去除会议硬编码               │  │
│  │  flowchart.html.j2 【改造】通用化                             │  │
│  │  timeline.html.j2 【改造】通用化                             │  │
│  │  pie.html.j2 / bar.html.j2 【改造】通用化                    │  │
│  │  orgchart.html.j2 【改造】通用化                             │  │
│  │  kanban.html.j2 【改造】通用化                               │  │
│  │  interview_radar.html.j2 【新增】访谈观点雷达图               │  │
│  │  interview_relation.html.j2 【新增】访谈人物关系图            │  │
│  │  lecture_outline.html.j2 【新增】讲座章节大纲图               │  │
│  │  lecture_knowledge.html.j2 【新增】讲座知识图谱               │  │
│  │  conversation_topic.html.j2 【新增】对话话题情绪流图          │  │
│  │  podcast_timeline.html.j2 【新增】播客话题时间线              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. 内容类型识别策略

### 4.1 支持的内容类型

| 类型标识 | 中文名称 | 典型场景 | 核心特征 |
|----------|----------|----------|----------|
| `meeting` | 会议 | 需求评审、周会、复盘 | 多人轮流发言、决策点、待办、时间约束 |
| `interview` | 访谈 | 用户访谈、专家访谈、招聘面试 | 问答结构、 interviewer/interviewee 角色、观点引用 |
| `lecture` | 讲座 / 课程 | 学术报告、培训课程、TED | 单向输出为主、章节结构、知识点、术语密集 |
| `conversation` | 日常对话 | 朋友聊天、家庭讨论、头脑风暴 | 话题跳跃、无明确议程、情绪表达、非正式语言 |
| `podcast` | 播客 | 多人对谈节目、播客录制 | 主持人/嘉宾角色、话题分段、轻松语气、时长较长 |
| `speech` | 演讲 | 发布会、致辞、竞选演讲 | 高度结构化、修辞手法、情感高潮、听众互动少 |

### 4.2 识别信号体系（规则引擎）

规则引擎作为第一层快速筛选，计算成本低，无需 LLM 调用。

#### 4.2.1 信号定义

| 信号类别 | 信号名称 | 检测方式 | 权重 |
|----------|----------|----------|------|
| **结构信号** | `turn_taking_ratio` | 说话人轮替频率（段落数 / 说话人数）| 高 |
| | `agenda_markers` | 议程标记词出现数（"首先""接下来""最后""总结一下"）| 高 |
| | `qa_pattern_count` | 问答模式匹配数（"问题是""答案是""你怎么看"）| 高 |
| | `monologue_ratio` | 最长连续单说话人段落占比 | 高 |
| **语义信号** | `decision_keywords` | 决策关键词（"决定""通过""同意""否决""方案A"）| 中 |
| | `action_item_markers` | 行动项标记（"TODO""待办""负责人""截止日期"）| 中 |
| | `opinion_markers` | 观点标记（"我认为""从我的角度""经验告诉我们"）| 中 |
| | `knowledge_density` | 术语/定义/概念密度（"定义为""即""概念""理论"）| 中 |
| | `emotion_markers` | 情绪表达密度（"开心""担心""愤怒""惊喜"+ emoji）| 低 |
| | `host_guest_pattern` | 主持人/嘉宾模式（"欢迎""感谢""请分享""接下来有请"）| 高 |
| **元数据信号** | `speaker_count` | 说话人数量 | 中 |
| | `duration_minutes` | 录音时长 | 低 |
| | `segment_count` | 转录片段数 | 低 |

#### 4.2.2 各内容类型的信号指纹

```python
CONTENT_TYPE_FINGERPRINTS = {
    "meeting": {
        "required": ["turn_taking_ratio >= 0.3", "speaker_count >= 2"],
        "strong_indicators": ["decision_keywords >= 2", "action_item_markers >= 2", "agenda_markers >= 3"],
        "weak_indicators": ["monologue_ratio < 0.6"],
        "anti_indicators": ["host_guest_pattern >= 3"],  # 播客容易误判为会议
    },
    "interview": {
        "required": ["speaker_count == 2", "qa_pattern_count >= 5"],
        "strong_indicators": ["opinion_markers >= 3", "turn_taking_ratio >= 0.5"],
        "weak_indicators": ["monologue_ratio < 0.7"],
        "anti_indicators": ["agenda_markers >= 5"],  # 讲座容易误判为访谈
    },
    "lecture": {
        "required": ["monologue_ratio >= 0.6"],
        "strong_indicators": ["knowledge_density >= 5", "agenda_markers >= 5"],
        "weak_indicators": ["speaker_count <= 2", "turn_taking_ratio < 0.3"],
        "anti_indicators": ["qa_pattern_count >= 10"],  # 访谈容易误判为讲座
    },
    "conversation": {
        "required": ["speaker_count >= 2"],
        "strong_indicators": ["emotion_markers >= 3", "agenda_markers < 2", "action_item_markers < 2"],
        "weak_indicators": ["turn_taking_ratio >= 0.4", "monologue_ratio < 0.5"],
        "anti_indicators": ["decision_keywords >= 3"],
    },
    "podcast": {
        "required": ["duration_minutes >= 20", "speaker_count >= 2"],
        "strong_indicators": ["host_guest_pattern >= 3", "turn_taking_ratio >= 0.3"],
        "weak_indicators": ["opinion_markers >= 3", "emotion_markers >= 2"],
        "anti_indicators": ["action_item_markers >= 5"],
    },
    "speech": {
        "required": ["speaker_count == 1", "monologue_ratio >= 0.9"],
        "strong_indicators": ["agenda_markers >= 3", "emotion_markers >= 3"],
        "weak_indicators": ["duration_minutes < 60"],
        "anti_indicators": ["qa_pattern_count >= 3"],
    },
}
```

#### 4.2.3 规则引擎评分逻辑

```python
def rule_based_detect(transcription: str, segments: list) -> dict:
    """
    基于规则的快速内容类型识别。
    返回: {type: str, confidence: float, signals: dict}
    """
    features = extract_features(transcription, segments)
    scores = {}

    for content_type, fingerprint in CONTENT_TYPE_FINGERPRINTS.items():
        score = 0.0
        max_possible = 0.0

        # required: 不满足直接排除
        for req in fingerprint["required"]:
            if not eval(req, {"__builtins__": {}}, features):
                score = -1.0
                break
        if score < 0:
            continue

        # strong_indicators: 权重 3.0
        for sig in fingerprint["strong_indicators"]:
            if eval(sig, {"__builtins__": {}}, features):
                score += 3.0
            max_possible += 3.0

        # weak_indicators: 权重 1.0
        for sig in fingerprint["weak_indicators"]:
            if eval(sig, {"__builtins__": {}}, features):
                score += 1.0
            max_possible += 1.0

        # anti_indicators: 命中则扣分 2.0
        for sig in fingerprint["anti_indicators"]:
            if eval(sig, {"__builtins__": {}}, features):
                score -= 2.0

        confidence = score / max_possible if max_possible > 0 else 0.0
        scores[content_type] = max(0.0, min(1.0, confidence))

    best_type = max(scores, key=scores.get) if scores else "conversation"
    best_confidence = scores.get(best_type, 0.0)

    return {
        "type": best_type,
        "confidence": best_confidence,
        "all_scores": scores,
        "signals": features,
    }
```

### 4.3 LLM 辅助裁决（混合策略）

规则引擎置信度 < 0.7 时，触发 LLM 进行二次裁决。

```python
LLM_CONTENT_TYPE_PROMPT = """
你是一位音频内容分析专家。请根据以下转录文本的特征，判断这段录音最可能属于哪种内容类型。

可选类型：
- meeting（会议）：多人讨论、有议程、有决策和待办事项
- interview（访谈）：问答结构、一方提问一方回答、观点挖掘
- lecture（讲座/课程）：单向知识输出、章节结构、术语密集
- conversation（日常对话）：非正式、话题跳跃、情绪表达、无明确议程
- podcast（播客）：主持人+嘉宾、轻松语气、话题分段、时长较长
- speech（演讲）：单人输出、高度结构化、修辞手法、面向听众

文本特征（已由规则引擎提取）：
{feature_summary}

原始转录文本前 2000 字：
{transcription_preview}

规则引擎初步判断：{rule_result}

请输出 JSON：
{
  "content_type": "类型标识",
  "confidence": 0.0-1.0,
  "reasoning": "简要推理过程（2-3 句话）",
  "alternative_types": ["次优类型1", "次优类型2"]
}
"""
```

### 4.4 识别结果输出格式

```json
{
  "content_type": "interview",
  "confidence": 0.92,
  "detection_method": "rule+llm",
  "rule_scores": {
    "meeting": 0.45,
    "interview": 0.85,
    "lecture": 0.20,
    "conversation": 0.30,
    "podcast": 0.60,
    "speech": 0.10
  },
  "signals": {
    "speaker_count": 2,
    "turn_taking_ratio": 0.62,
    "qa_pattern_count": 12,
    "monologue_ratio": 0.35,
    "opinion_markers": 8
  }
}
```

---

## 5. 内容类型 -> 图表策略映射表

### 5.1 映射总表

| 内容类型 | 首选图表 | 备选图表 1 | 备选图表 2 | 禁用图表 | 视觉风格关键词 |
|----------|----------|-----------|-----------|----------|--------------|
| `meeting` | mindmap（议题结构图） | flowchart（决策流程图） | timeline（项目时间线） | — | 结构化、专业、清晰 |
| `interview` | interview_radar（观点雷达图） | interview_relation（人物关系图） | mindmap（话题思维导图） | orgchart, kanban | 对比、深度、人物 |
| `lecture` | lecture_outline（章节大纲图） | lecture_knowledge（知识图谱） | timeline（知识点时间线） | orgchart, kanban | 层级、知识、系统 |
| `conversation` | conversation_topic（话题情绪流图） | mindmap（话题发散图） | — | orgchart, flowchart | 流动、情绪、自然 |
| `podcast` | podcast_timeline（话题时间线） | interview_radar（嘉宾观点对比） | mindmap（话题脑图） | orgchart, kanban | 轻松、分段、多元 |
| `speech` | lecture_outline（演讲结构图） | timeline（演讲时间线） | mindmap（论点脑图） | orgchart, kanban | 力量、节奏、结构 |

### 5.2 各内容类型的数据提取策略

#### 5.2.1 会议（meeting）—— 保留并通用化

```
提取维度：
- 主题/议题（根节点）
- 讨论分支（子议题、不同意见）
- 决策点（条件判断、结论）
- 行动项（任务、负责人、时间）
- 时间线（里程碑、截止日期）

Prompt 去会议化改造：
旧："从以下会议纪要中提取参与人、核心观点、关键讨论、决策/结论、待办事项"
新："从以下文本中提取讨论的主题结构、各方观点、形成的共识或决策、后续行动"
```

#### 5.2.2 访谈（interview）

```
提取维度：
- 受访者核心观点（按话题分类）
- 提问者引导的问题线
- 人物角色和关系（采访者 vs 被采访者）
- 观点强度/确定性（"一定""可能""我觉得"）
- 关键引用（金句、数据引用）

新图表类型：
1. interview_radar（观点雷达图）：
   - 多个话题维度，受访者观点的立场分布
   - 可视化：雷达图 / 多轴对比图

2. interview_relation（人物关系图）：
   - 采访者与受访者关系
   - 提及的第三方人物/机构关系
   - 可视化：人物节点 + 关系连线
```

#### 5.2.3 讲座（lecture）

```
提取维度：
- 章节/模块结构（大纲层级）
- 核心概念和定义
- 概念之间的关系（包含、因果、对比）
- 案例/例子
- 知识点的时间顺序

新图表类型：
1. lecture_outline（章节大纲图）：
   - 树状层级：课程 -> 章节 -> 知识点 -> 细节
   - 类似 mindmap，但强调知识层级而非讨论层级

2. lecture_knowledge（知识图谱）：
   - 概念节点 + 关系边（"定义为""导致""对比于"）
   - 可视化：网络图 / 力导向图
```

#### 5.2.4 日常对话（conversation）

```
提取维度：
- 话题转移路径（话题 A -> 话题 B -> 话题 C）
- 每个话题的情绪倾向（积极/消极/中性）
- 说话人在各话题中的参与度
- 关键共识或分歧点

新图表类型：
1. conversation_topic（话题情绪流图）：
   - 横轴：时间/对话进度
   - 纵轴：话题分类
   - 颜色：情绪倾向（绿=积极，红=消极，灰=中性）
   - 可视化：流线图 / Sankey 图变体
```

#### 5.2.5 播客（podcast）

```
提取维度：
- 话题分段（每个话题的起止时间）
- 各嘉宾在各话题中的发言量
- 话题之间的关联
- 笑点/高潮点标记

新图表类型：
1. podcast_timeline（话题时间线）：
   - 横轴：时间线
   - 纵轴：话题条带
   - 条带宽度：该话题在该时段的发言量
   - 可视化：甘特图变体 / 话题流带
```

#### 5.2.6 演讲（speech）

```
提取维度：
- 演讲结构（开场 -> 论点 1 -> 论点 2 -> 结论）
- 修辞手法标记（排比、反问、引用）
- 情感高潮点
- 核心论点和支持论据

图表复用：
- 首选 lecture_outline（演讲结构图）
- 备选 timeline（情感/论点时间线）
```

### 5.3 通用数据提取框架（替代硬编码 prompt）

```python
# 取代 _build_extraction_prompt 中的硬编码模板

def build_universal_extraction_prompt(content_type: str, chart_type: str, text: str) -> str:
    """
    基于内容类型和图表类型，构建通用的数据提取 prompt。
    不包含任何会议专属词汇。
    """

    extraction_dimensions = {
        "themes": "识别文本中的核心主题或议题",
        "entities": "识别关键人物、组织、概念、地点",
        "relations": "识别实体之间的关系（支持、反对、因果、包含等）",
        "timeline": "识别时间相关表达和顺序",
        "numerics": "识别数值、比例、统计数据",
        "opinions": "识别观点、立场、态度表达",
        "emotions": "识别情绪倾向（积极、消极、中性）",
        "hierarchy": "识别层级结构（总分、父子、从属）",
    }

    chart_type_instructions = {
        "mindmap": "提取层级化的主题结构，适合树状展开",
        "flowchart": "提取流程、决策点和分支路径",
        "timeline": "提取按时间顺序排列的事件",
        "pie": "提取分类占比数据",
        "bar": "提取分类对比数据",
        "interview_radar": "提取多个话题维度上的观点立场",
        "interview_relation": "提取人物/实体及其关系",
        "lecture_outline": "提取章节/知识点的层级结构",
        "lecture_knowledge": "提取概念节点和它们之间的关系",
        "conversation_topic": "提取话题转移路径和情绪变化",
        "podcast_timeline": "提取话题分段和发言分布",
    }

    return f"""
你是一位内容结构化分析专家。请从以下文本中提取结构化数据，用于生成可视化图表。

【内容类型】{CONTENT_TYPE_NAMES[content_type]}
【图表类型】{CHART_TYPE_NAMES[chart_type]}

【提取维度】
{format_dimensions(extraction_dimensions, content_type)}

【图表特定要求】
{chart_type_instructions.get(chart_type, "提取适合该图表类型的结构化数据")}

【输出格式】
输出标准 JSON：
{{
  "nodes": [
    {{"id": "唯一标识", "label": "显示文本", "level": 层级数字, "node_type": "类型", "metadata": {{}}}}
  ],
  "edges": [
    {{"from": "源节点id", "to": "目标节点id", "label": "关系标签"}}
  ],
  "content_type_meta": {{
    "detected_themes": ["主题1", "主题2"],
    "key_entities": ["实体1", "实体2"],
    "overall_tone": "整体语气"
  }}
}}

【文本内容】
{text}

仅输出 JSON，不要其他解释。
"""
```

---

## 6. 新图表类型定义

### 6.1 访谈 - 观点雷达图（interview_radar）

```
用途：展示受访者在多个话题维度上的立场分布
数据结构：
  nodes: [{id, label: "话题维度", level: 0, metadata: {angle: 0-360}}]
  edges: []  // 雷达图无边
  // 额外：radar_values: [{dimension: "话题", value: 0-10, interviewee: "姓名"}]

视觉风格：
  - 多边形雷达图，每个顶点一个话题维度
  - 多受访者用不同颜色多边形叠加
  - 背景：暗色，网格线 subtle
  - 数据区域：半透明填充 + 边框
```

### 6.2 访谈 - 人物关系图（interview_relation）

```
用途：展示访谈中涉及的人物/实体及其关系
数据结构：
  nodes: [{id, label, level, node_type: "person"/"organization"/"topic", metadata: {role}}]
  edges: [{from, to, label: "关系类型"}]

视觉风格：
  - 力导向布局或环形布局
  - 人物节点：圆形，头像占位
  - 组织节点：方形
  - 关系线：带标签的曲线
```

### 6.3 讲座 - 章节大纲图（lecture_outline）

```
用途：展示讲座的章节结构和知识点层级
数据结构：
  nodes: [{id, label, level: 0=章/1=节/2=知识点/3=细节, node_type}]
  edges: [{from, to}]

视觉风格：
  - 树状思维导图变体
  - 层级颜色：章=cyan, 节=purple, 知识点=orange, 细节=green
  - 知识点节点可折叠/展开
```

### 6.4 讲座 - 知识图谱（lecture_knowledge）

```
用途：展示讲座中的概念及其关系
数据结构：
  nodes: [{id, label, level, node_type: "concept"/"definition"/"example"}]
  edges: [{from, to, label: "定义为"/"导致"/"对比于"/"包含"}]

视觉风格：
  - 力导向网络图
  - 概念节点大小与重要性相关
  - 关系线颜色按关系类型区分
```

### 6.5 日常对话 - 话题情绪流图（conversation_topic）

```
用途：展示对话中话题的转移和情绪变化
数据结构：
  nodes: [{id, label: "话题", level, metadata: {start_time, end_time, emotion_score}}]
  edges: [{from, to, label: "转移方式"}]

视觉风格：
  - 横轴：时间线
  - 纵轴：话题分类（多条平行流带）
  - 流带颜色：情绪分数映射到色温
  - 流带宽度：该话题在该时段的发言量
```

### 6.6 播客 - 话题时间线（podcast_timeline）

```
用途：展示播客中各话题的时段分布和嘉宾参与度
数据结构：
  nodes: [{id, label: "话题段", level, metadata: {start_time, end_time, speaker_contributions}}]
  edges: []

视觉风格：
  - 甘特图变体
  - 横轴：时间
  - 每行：一个话题
  - 条段颜色：按主导嘉宾区分
  - 条段长度：话题持续时间
```

---

## 7. 数据提取策略改造说明

### 7.1 当前问题代码（v1.1）

```python
# ChartAgent/agent/nodes.py (v1.1)

def _build_extraction_prompt(chart_type: str, text: str) -> str:
    templates = {
        "mindmap": """从以下文本中提取思维导图结构。输出 JSON：
{"nodes": [{"id": "1", "label": "根节点", "level": 0, "node_type": "root"}, ...],
 "edges": [...]}""",
        # ... 其他模板
    }
    base = templates.get(chart_type, templates["mindmap"])
    return f"{base}\n\n文本内容：\n{text}\n\n仅输出 JSON，不要其他解释。"
```

**问题**：
1. Prompt 中无内容类型信息
2. 所有内容类型共用同一套提取模板
3. mindmap 的示例根节点标签为"根节点"，实际渲染时 fallback 为"会议主题"

### 7.2 改造后代码结构（v2.0）

```python
# ChartAgent/agent/nodes.py (v2.0)

def content_type_detect(state: Dict[str, Any]) -> Dict[str, Any]:
    """
    【新增节点】识别内容类型。
    优先使用规则引擎，置信度不足时调用 LLM。
    """
    raw_transcription = state.get("raw_transcription", "")
    markdown_content = state.get("markdown_content", "")

    # 1. 规则引擎快速判断
    segments = parse_segments(raw_transcription)
    rule_result = rule_based_detect(raw_transcription, segments)

    # 2. 置信度不足时 LLM 裁决
    if rule_result["confidence"] < 0.7:
        llm_result = llm_content_type_detect(
            transcription_preview=raw_transcription[:2000],
            feature_summary=format_features(rule_result["signals"]),
            rule_result=f"{rule_result['type']} (confidence: {rule_result['confidence']})"
        )
        # 融合规则 + LLM 结果
        final_type, final_confidence = fuse_results(rule_result, llm_result)
    else:
        final_type = rule_result["type"]
        final_confidence = rule_result["confidence"]

    state["content_type"] = final_type
    state["content_type_confidence"] = final_confidence
    state["content_type_signals"] = rule_result["signals"]
    return state


def data_extract(state: Dict[str, Any]) -> Dict[str, Any]:
    """
    【改造节点】基于内容类型的通用数据提取。
    """
    chart_type = state["selected_chart_type"]
    content_type = state["content_type"]  # 新增依赖
    text = state["markdown_content"]
    raw_text = state.get("raw_transcription", text)

    # 使用通用提取框架，传入内容类型和图表类型
    prompt = build_universal_extraction_prompt(content_type, chart_type, raw_text)
    raw_response = call_llm(prompt)

    structured = parse_and_validate_json(raw_response, chart_type)

    # 注入内容类型元数据
    structured["content_type_meta"] = {
        "detected_type": content_type,
        "confidence": state.get("content_type_confidence", 0.0),
    }

    state["structured_data"] = structured
    return state
```

### 7.3 改造后的 StateGraph

```
[Start] ──▶ content_type_detect ──▶ text_analysis ──▶ chart_type_select
               【新增】                 【改造】            【改造】
               识别内容类型             基于类型调整特征    类型->策略映射
                                              │
                                              ▼
                                    data_extract ──▶ chart_generate ──▶ validate
                                    【改造】去会议化    【改造】内容感知模板   【不变】
```

### 7.4 移除的硬编码会议概念清单

| 位置 | 原文（v1.1） | 改造后（v2.0） |
|------|-------------|---------------|
| `ChartAgentState` 字段 | `theme`, `participants`, `key_decisions`, `action_items`, `timeline` | 保留但改为可选字段；新增 `content_type`, `raw_transcription` |
| mindmap prompt | 示例根节点 label: "根节点"，fallback: "会议主题" | 根节点 label: 自动提取的核心主题 |
| mindmap prompt | 提取要求包含"参与人、核心观点、关键讨论、决策/结论、待办事项" | 提取要求改为"主题结构、各方观点、形成的共识或决策、后续行动" |
| flowchart prompt | 隐含假设：流程来自会议决策 | 明确说明：提取文本中的流程、决策点和分支路径 |
| kanban prompt | 提取"待办事项"，状态列固定为"待办/进行中/已完成" | 提取"行动项"，状态列根据内容类型动态确定 |
| orgchart prompt | 提取"组织架构关系"，隐含公司场景 | 提取"人物/实体关系"，适用于任何关系场景 |

---

## 8. 前后端改造边界

### 8.1 Swift 端改造清单

| # | 文件 | 改造内容 | 优先级 |
|---|------|----------|--------|
| 1 | `ChartGenerateRequest.swift` | 增加 `rawTranscription: String?` 字段；`content` 中的 `theme`/`participants`/`keyDecisions`/`actionItems`/`timeline` 改为可选 | P0 |
| 2 | `RecordingDetailViewModel.swift` | `generateChart()` 组装请求时，传入 `rawTranscription`（从 `Recording` 关联的 `Transcription` 实体获取完整转录文本） | P0 |
| 3 | `ChartGenerateResponse.swift` | 增加 `contentType: String` 和 `contentTypeConfidence: Double` 字段 | P1 |
| 4 | `ChartPanelView.swift` | 在图表头部显示检测到的内容类型标签（如"访谈 · 观点雷达图"） | P1 |
| 5 | `ChartType.swift` | 新增枚举值：`interviewRadar`, `interviewRelation`, `lectureOutline`, `lectureKnowledge`, `conversationTopic`, `podcastTimeline` | P0 |

### 8.2 Python 端改造清单

| # | 文件 | 改造内容 | 优先级 |
|---|------|----------|--------|
| 1 | `main.py` | 解析请求中的 `raw_transcription` 字段，传入 State | P0 |
| 2 | `graph.py` | 新增 `content_type_detect` 节点；调整节点顺序 | P0 |
| 3 | `nodes.py` | 新增 `content_type_detect()` 函数；改造 `text_analysis()` 基于内容类型调整特征权重；改造 `data_extract()` 使用通用提取框架 | P0 |
| 4 | `templates.py` | 新增 6 个内容感知模板；改造现有模板去除会议硬编码 | P0 |
| 5 | `router.py` | 改造 `chart_type_select()` 使用内容类型 -> 图表策略映射表 | P0 |

### 8.3 接口变更说明

**请求体变更（v1.1 -> v2.0）**：

```diff
  {
    "version": "2.0",
    "requestId": "uuid",
    "content": {
-     "theme": "会议主题",
+     "theme": "内容主题",
-     "participants": ["参与人1"],
+     "participants": ["参与人1"],  // 可选
-     "keyDecisions": ["决策1"],
+     "keyDecisions": ["决策1"],    // 可选
-     "actionItems": [{...}],
+     "actionItems": [{...}],       // 可选
-     "timeline": ["时间点"],
+     "timeline": ["时间点"],       // 可选
      "markdownContent": "完整 Markdown",
+     "rawTranscription": "原始转录文本"  // 【新增】必填
    },
    "preferences": {
      "primaryChartType": "auto",
+     "contentTypeHint": "auto",     // 【新增】可选，用户手动指定内容类型
      "styleTheme": "darkCyberpunk",
      "outputFormats": ["html"]
    }
  }
```

**响应体变更（v1.1 -> v2.0）**：

```diff
  {
-   "version": "1.0",
+   "version": "2.0",
    "requestId": "uuid",
    "status": "success",
    "charts": [
      {
        "chartType": "interview_radar",
        "chartTypeDisplayName": "观点雷达图",
        "confidence": 0.92,
+       "contentType": "interview",           // 【新增】
+       "contentTypeConfidence": 0.88,        // 【新增】
        "htmlFragment": "...",
        "renderConfig": {...},
        "structuredData": {...},
        "metadata": {...}
      }
    ],
    "errors": []
  }
```

---

## 9. 验收标准

### 9.1 内容类型识别

- [ ] **AC-SC2-001**：系统能识别至少 5 种内容类型（meeting, interview, lecture, conversation, podcast, speech 中至少 5 种）
- [ ] **AC-SC2-002**：每种内容类型有明确的识别信号定义（规则引擎层面可检查）
- [ ] **AC-SC2-003**：规则引擎识别准确率 >= 70%（100 条测试样本）
- [ ] **AC-SC2-004**：规则 + LLM 混合识别准确率 >= 85%（100 条测试样本）
- [ ] **AC-SC2-005**：识别结果包含置信度分数和推理信号

### 9.2 图表策略映射

- [ ] **AC-SC2-006**：每种内容类型至少对应 1 种首选图表 + 1 种备选图表
- [ ] **AC-SC2-007**：内容类型 -> 图表映射表在代码中可检查（非隐含逻辑）
- [ ] **AC-SC2-008**：用户可手动覆盖自动识别的内容类型（`contentTypeHint`）

### 9.3 数据提取去会议化

- [ ] **AC-SC2-009**：所有 LLM prompt 中不再出现"会议纪要""参与人""待办事项"等会议专属词汇
- [ ] **AC-SC2-010**：`data_extract` 的 prompt 模板基于内容类型动态生成
- [ ] **AC-SC2-011**：非会议内容（访谈、讲座）的图表可用率 >= 80%（人工评估 50 条样本）

### 9.4 新图表类型

- [ ] **AC-SC2-012**：至少实现 3 种新的内容感知图表类型（interview_radar, lecture_outline, conversation_topic 等）
- [ ] **AC-SC2-013**：新图表类型采用与现有图表一致的暗黑极客风视觉系统
- [ ] **AC-SC2-014**：新图表类型的数据提取准确率 >= 75%（人工评估）

### 9.5 接口与集成

- [ ] **AC-SC2-015**：Swift 端请求体包含 `raw_transcription` 字段
- [ ] **AC-SC2-016**：Python 端正确解析并使用 `raw_transcription`
- [ ] **AC-SC2-017**：响应体包含 `contentType` 和 `contentTypeConfidence`
- [ ] **AC-SC2-018**：协议版本升级到 "2.0"，v1.1 请求仍兼容（向后兼容）

### 9.6 性能

- [ ] **AC-SC2-019**：内容类型识别耗时 < 2 秒（规则引擎）/ < 5 秒（含 LLM）
- [ ] **AC-SC2-020**：端到端图表生成时间 < 35 秒（含内容类型识别）

---

## 10. 改造优先级建议

### 10.1 优先级矩阵

| 阶段 | 任务 | 优先级 | 预估工时 | 阻塞下游 |
|------|------|--------|----------|----------|
| **Phase 1** | 内容类型识别层（规则引擎 + LLM 混合） | P0 | 3 天 | 所有后续任务 |
| **Phase 1** | 数据提取 prompt 去会议化（通用提取框架） | P0 | 2 天 | Phase 2 |
| **Phase 1** | 内容类型 -> 图表策略映射表实现 | P0 | 1 天 | Phase 2 |
| **Phase 2** | 改造现有模板（mindmap/flowchart/timeline 等去会议化） | P0 | 3 天 | Phase 3 |
| **Phase 2** | 新增 3 个内容感知图表模板（interview_radar, lecture_outline, conversation_topic） | P0 | 4 天 | Phase 4 |
| **Phase 3** | Swift 端接口改造（请求体/响应体字段扩展） | P0 | 2 天 | Phase 4 |
| **Phase 3** | Python 端 StateGraph 改造（新增节点、调整路由） | P0 | 2 天 | Phase 4 |
| **Phase 4** | 集成测试（6 种内容类型 x 3 种图表 = 18 个测试用例） | P0 | 3 天 | Phase 5 |
| **Phase 5** | 新增剩余 3 个内容感知图表模板（interview_relation, lecture_knowledge, podcast_timeline） | P1 | 3 天 | — |
| **Phase 5** | UI 优化（内容类型标签显示、用户手动覆盖） | P1 | 2 天 | — |
| **Phase 5** | 测试集扩充与准确率调优 | P1 | 2 天 | — |

### 10.2 推荐实施顺序

```
Week 1: Phase 1（核心识别层）
  - Day 1-2: 规则引擎实现（信号提取 + 评分逻辑）
  - Day 3: LLM 裁决 prompt 设计与测试
  - Day 4-5: 通用提取框架 + 去会议化 prompt 改造

Week 2: Phase 2（模板层）
  - Day 1: 内容类型 -> 图表映射表实现
  - Day 2-3: 现有模板去会议化改造
  - Day 4-5: 新增 3 个 P0 内容感知模板

Week 3: Phase 3-4（集成与测试）
  - Day 1-2: 前后端接口改造
  - Day 3-5: 集成测试 + bugfix

Week 4: Phase 5（扩展与打磨）—— 可后续迭代
  - 新增 P1 模板
  - UI 优化
  - 准确率调优
```

### 10.3 关键决策点

| 决策点 | 建议 | 决策人 | 截止时间 |
|--------|------|--------|----------|
| 内容类型识别是否支持用户手动覆盖 | 支持（`contentTypeHint` 字段）| claude-cp-arch | Phase 1 结束 |
| 规则引擎置信度阈值 | 0.7（< 0.7 触发 LLM）| claude-cp-arch | Phase 1 结束 |
| 新模板视觉风格 | 复用现有暗黑极客风 CSS 变量，仅布局调整 | claude-xd-lead | Phase 2 开始 |
| 是否保留 v1.1 的会议专用 prompt 作为 fallback | 否，完全替换为通用框架 | claude-cp-lead | Phase 1 结束 |
| 测试集来源 | 内部录制 20 条 + 公开数据集 80 条 | claude-qa-lead | Phase 3 开始 |

---

## 11. 风险与缓解

| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|----------|
| 内容类型识别准确率不达标（< 85%） | 中 | 高 | 建立 100+ 条标注测试集持续调优；提供用户手动覆盖兜底 |
| 规则引擎与 LLM 结果冲突频繁 | 中 | 中 | 设计清晰的融合策略（LLM 优先但需高置信度）；记录冲突样本用于规则优化 |
| 新模板开发周期长（尤其是 conversation_topic 流线图） | 中 | 中 | P0 只实现 3 个新模板，其余 P1；流线图可用简化版条形图替代 |
| 原始转录文本过长导致 LLM token 超限 | 高 | 中 | 转录文本截断至 8000 tokens（约 6000 汉字），保留首尾和中间采样 |
| 向后兼容问题（v1.1 Swift 端调用 v2.0 Python 端） | 低 | 高 | Python 端同时支持 version "1.0" 和 "2.0" 请求；v1.0 请求默认 content_type="meeting" |
| 暗黑极客风 CSS 在新模板上的适配问题 | 低 | 低 | 所有新模板复用现有 CSS 变量体系，仅调整布局类 |

---

## 12. 下游交付物

### 12.1 交付给 claude-xd-lead（视觉设计）

- [ ] 6 种新图表类型的布局草图和交互描述（见第 6 章）
- [ ] 视觉风格约束：复用现有暗黑极客风 CSS 变量，不引入新颜色
- [ ] 优先级：interview_radar > lecture_outline > conversation_topic > 其余

### 12.2 交付给 claude-cp-arch（架构实现）

- [ ] 完整的 StateGraph 改造方案（新增节点、调整路由）
- [ ] 前后端接口变更清单（请求体/响应体字段变更）
- [ ] 规则引擎信号定义和评分逻辑（可直接实现）
- [ ] LLM prompt 模板（内容类型识别 + 通用数据提取）
- [ ] 内容类型 -> 图表策略映射表代码定义
- [ ] 向后兼容策略（v1.0 / v2.0 协议共存）

### 12.3 交付给 claude-qa-lead（测试）

- [ ] 验收标准清单（第 9 章）
- [ ] 测试集建议：6 种内容类型 x 至少 15 条样本 = 90 条
- [ ] 性能基准：内容类型识别 < 2s（规则）/ < 5s（含 LLM）；端到端 < 35s

---

## 13. 附录

### 13.1 术语表

| 术语 | 定义 |
|------|------|
| 内容类型（Content Type） | 录音内容的自然分类（会议、访谈、讲座、日常对话、播客、演讲） |
| 内容类型识别（Content Type Detection） | 基于转录文本特征判断内容类型的过程 |
| 图表策略映射（Chart Strategy Mapping） | 内容类型 -> 首选图表/备选图表/禁用图表的映射规则 |
| 通用提取框架（Universal Extraction Framework） | 不依赖特定内容类型的结构化数据提取方法 |
| 信号指纹（Signal Fingerprint） | 某种内容类型在规则引擎中的特征模式定义 |
| 暗黑极客风（Dark Cyberpunk） | 现有视觉设计系统，v2.0 新模板复用此体系 |

### 13.2 参考文档

- PRD-v1.0.md — 基础产品需求
- PRD-v1.1-ChartAgent.md — Chart Agent v1.1 产品需求
- TechSpec-v1.0.md — 技术选型与架构
- TechSpec-ChartAgent.md — Chart Agent v1.1 技术规格

### 13.3 文档变更记录

| 版本 | 日期 | 变更内容 | 作者 |
|------|------|----------|------|
| v2.0 | 2026/05/30 | 初始版本：内容感知智能图表重构 Feature Ticket | claude-cp-lead |
