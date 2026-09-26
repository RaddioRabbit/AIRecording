> 2026-07-17：本文描述的部分 v3 内容已被 v4 设计取代，见 `docs/superpowers/specs/2026-07-17-smartchart-content-type-skills-design.md`。

# AIRecording — Chart Agent 技术规格文档

## 版本信息

| 项目 | 内容 |
|------|------|
| 文档版本 | v1.1 |
| 撰写日期 | 2026/05/28 |
| 对应 PRD | PRD-v1.1-ChartAgent.md |
| 文档状态 | 可执行规格，直接指导开发 |
| 目标平台 | macOS 13+ (Ventura)，Intel + Apple Silicon |
| 技术约束 | Swift 5.9+，零 SPM 依赖，Python 3.10+ |

---

## 1. 概述

### 1.1 文档目的

本文档是 Chart Agent 功能的**实现层技术规格**，聚焦代码级别的架构决策、接口定义、数据模型和可执行代码片段。与 PRD v1.1 的关系如下：

- **PRD v1.1**：定义"做什么"——产品功能、用户场景、验收标准、视觉规范
- **TechSpec 本文档**：定义"怎么做"——类设计、协议定义、算法实现、服务生命周期、错误处理、部署细节

### 1.2 适用范围

本文档适用于以下开发活动：
- Swift 端：Chart Skill Protocol、HTTP 客户端、WKWebView 渲染、Core Data 模型扩展、ViewModel/View 集成
- Python 端：FastAPI 服务、LangGraph Agent、Jinja2 模板系统、CSS 变量体系、LLM 配置
- 集成：Swift-Python 通信协议、服务生命周期管理、心跳检测

### 1.3 技术假设与约束

| 约束项 | 值 | 说明 |
|--------|-----|------|
| Swift 版本 | 5.9+ | 与现有项目一致，启用 StrictConcurrency |
| 最低 macOS | 13.0 | 与现有项目一致，覆盖 95%+ 活跃设备 |
| SwiftUI 版本 | macOS 13 可用特性 | 不使用 macOS 14+ 专属 API（如 `Observable` macro） |
| SPM 依赖 | 零 | 保持与现有项目一致，所有功能使用系统框架 |
| Python 版本 | 3.10+ | FastAPI + LangGraph 最低要求 |
| Python 依赖 | FastAPI, uvicorn, langgraph, jinja2, openai, requests | 安装时通过 pip 引导 |
| 网络协议 | HTTP/1.1（本地回环）| Swift URLSession → Python FastAPI |
| 渲染引擎 | WKWebView（WebKit）| macOS 13 完整支持，硬件加速 CSS |

### 1.4 与现有系统的集成点

Chart Agent 作为**新增能力模块**接入现有四层架构：

```
Presentation (SwiftUI Views)  → 新增 ChartPanelView, ChartWebView
    ↓
ViewModels (@MainActor)       → 新增 RecordingDetailViewModel 扩展（图表面板状态）
    ↓
Services (singletons)         → 新增 HTTPChartSkill, ChartServiceManager
    ↓
Data (Core Data)              → 扩展 Chart, ChartNode, ChartEdge, ChartJob 实体
```

---

## 2. 架构总览

### 2.1 系统架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AIRecording (Swift)                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐ │
│  │ Recording    │  │ Recording    │  │ SettingsView │  │ ChartPanelView   │ │
│  │ ListView     │  │ DetailView   │  │              │  │ (新增)           │ │
│  └──────┬───────┘  └──────┬───────┘  └──────────────┘  └──────────────────┘ │
│         │                 │                                                  │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────────────┐  ┌──────────────────┐ │
│  │RecordingList │  │RecordingDetail│  │ SettingsView │  │ ChartGeneration │ │
│  │ViewModel     │  │ViewModel      │  │ Model        │  │ ViewModel (新增) │ │
│  └──────────────┘  └──────┬───────┘  └──────────────┘  └──────────────────┘ │
│                           │                                                  │
│              ┌────────────┼────────────┐                                     │
│              ▼            ▼            ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                        Services (Singletons)                          │   │
│  │  AudioRecordingService  TranscriptionService  AudioPlayerService      │   │
│  │  LLMService             PersistenceController                         │   │
│  │  HTTPChartSkill (新增)  ChartServiceManager (新增)                   │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼ HTTP POST /chart/generate              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                        Data (Core Data + File System)                 │   │
│  │  Recording  Transcription  TranscriptionSegment  Chart (新增)        │   │
│  │  ChartNode (新增)  ChartEdge (新增)  ChartJob (新增)                 │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼ localhost:8765
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Python FastAPI Service                               │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  FastAPI Router                                                      │   │
│  │  POST /chart/generate  →  chart_generate_endpoint(request)          │   │
│  │  GET  /health          →  health_check()                            │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  LangGraph Agent (StateGraph)                                        │   │
│  │                                                                      │   │
│  │  [Start] ──▶ text_analysis ──▶ chart_type_select ──▶ data_extract   │   │
│  │                              (条件路由: 6种类型匹配)                   │   │
│  │                                              │                       │   │
│  │                                              ▼                       │   │
│  │                                    chart_generate ──▶ validate       │   │
│  │                                                          │           │   │
│  │                                        (失败, 重试<=2) ──┘           │   │
│  │                                              │                       │   │
│  │                                              ▼ 通过                  │   │
│  │                                           [End]                      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  Jinja2 Template Engine                                              │   │
│  │  base.html.j2 (暗黑极客风 CSS 变量)                                   │   │
│  │  mindmap.html.j2  flowchart.html.j2  timeline.html.j2               │   │
│  │  pie.html.j2  bar.html.j2  orgchart.html.j2  kanban.html.j2         │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│                                    │                                         │
│                                    ▼ HTML String                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼ HTTP Response (JSON)
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AIRecording (Swift)                             │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │  ChartWebView (NSViewRepresentable)                                  │   │
│  │  WKWebView.loadHTMLString(response.htmlFragment, baseURL: nil)      │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 各层职责说明

| 层级 | 组件 | 职责 |
|------|------|------|
| **Presentation** | `ChartPanelView` | SwiftUI 图表面板容器，管理加载/错误/空状态，提供导出操作 |
| **Presentation** | `ChartWebView` | `NSViewRepresentable` 包装 `WKWebView`，负责 HTML 注入与渲染 |
| **ViewModel** | `RecordingDetailViewModel` | 扩展图表面板状态（`isGeneratingChart`, `chartResult`），协调 Skill 调用 |
| **Service** | `HTTPChartSkill` | 实现 `ChartSkill` 协议，通过 `URLSession` 调用本地 FastAPI |
| **Service** | `ChartServiceManager` | Python 服务生命周期管理：检测、启动、心跳、自动重启 |
| **Python** | FastAPI App | HTTP 入口，请求校验，路由分发 |
| **Python** | LangGraph Agent | 状态图执行：文本分析 → 类型决策 → 数据提取 → 图表生成 → 校验 |
| **Python** | Jinja2 Templates | 暗黑极客风 HTML/CSS 生成，6 种图表类型模板 |
| **Data** | Core Data (扩展) | `Chart`, `ChartNode`, `ChartEdge`, `ChartJob` 持久化 |

---

## 3. 渲染方案（详细技术决策）

### 3.1 三种方案对比

| 维度 | 方案 A: WKWebView + HTML/CSS | 方案 B: Swift 原生渲染 | 方案 C: Mermaid.js + CSS 覆盖 |
|------|------------------------------|------------------------|-------------------------------|
| **实现复杂度** | 中：需构建自定义 CSS 框架 | 高：每种图表类型需手写布局算法 | 低：Mermaid 生成 SVG，只需覆盖 CSS |
| **视觉还原度** | **优**：完全控制每个像素，渐变/毛玻璃/发光效果完整支持 | 良：SwiftUI Canvas 可实现基础图形，复杂效果受限 | **差**：Mermaid 固定布局引擎，无法自定义节点位置、渐变连线、毛玻璃 |
| **暗黑极客风支持** | **完整**：CSS 变量体系全覆盖 | 部分：SwiftUI 渐变支持好，但毛玻璃/发光需自定义 Shader | 受限：仅能覆盖颜色，无法改布局/形状/连线样式 |
| **性能** | 良：WebKit 硬件加速 CSS，节点数 >50 需简化 | 优：原生渲染，无 WebView 开销 | 良：SVG 渲染轻量，但 Mermaid 解析有开销 |
| **交互性** | **优**：JS Bridge 支持点击/缩放/拖拽，CSS 悬浮流畅 | 良：SwiftUI Gesture 支持基础交互 | 良：Mermaid 支持基础点击 |
| **导出能力** | PNG（WKWebView 截图）/ SVG / HTML / JSON | PNG（SwiftUI ImageRenderer）/ 无原生 SVG | PNG / SVG（Mermaid 原生） |
| **包体积** | ~500KB（自定义 CSS/JS，无外部依赖）| ~200KB（纯代码）| ~1.5MB（Mermaid.js bundle）|
| **离线能力** | 完整 | 完整 | 完整 |
| **维护成本** | 中：CSS 框架需维护 | 高：每种新图表类型需写布局算法 | 低：但受限于 Mermaid 版本升级 |

### 3.2 推荐方案详述：WKWebView + Jinja2 模板 + 暗黑极客风 CSS

**决策结论：采用方案 A 作为主方案，方案 B 作为 P2 备选（柱状图/饼图性能敏感场景）。放弃方案 C。**

**核心理由：**
1. **暗黑极客风还原度是 P0 需求**（PRD v1.1 AC-CHT-013 ~ AC-CHT-016）。方案 C 的 Mermaid.js 是固定布局引擎，无法生成 PRD 要求的"层级彩色边框节点""青色渐变连接线""毛玻璃悬浮效果"等视觉特征。
2. **包体积控制**：方案 A 仅增加 ~500KB 自定义 CSS，方案 C 增加 ~1.5MB Mermaid bundle，且仍无法满足视觉需求。
3. **交互灵活性**：方案 A 的 HTML/CSS 支持完整的 JS Bridge 交互（节点点击、画布拖拽缩放），这是 P1 需求（交互式编辑）。

**渲染流水线：**

```
结构化数据 (JSON)
    ↓
Jinja2 模板渲染
    ↓
内联暗黑极客风 CSS (DARK_CSS 常量)
    ↓
完整 HTML 字符串
    ↓
HTTP 响应 → Swift
    ↓
WKWebView.loadHTMLString(html, baseURL: nil)
    ↓
WebKit 渲染引擎（硬件加速）
    ↓
用户可见图表
```

### 3.3 为什么放弃 Mermaid.js 作为主方案

Mermaid.js 在以下关键视觉需求上无法达标：

| PRD 视觉需求 | Mermaid 能力 | 差距 |
|--------------|-------------|------|
| 中心节点 cyan-purple 渐变文字 | 不支持文本渐变 | 无法通过 CSS 覆盖实现（SVG 文本渐变需 `linearGradient` 定义） |
| 层级彩色边框节点（左 border 3px） | 固定矩形节点，边框为四边统一 | 无法单独设置左边框颜色 |
| 青色渐变连接线 | 仅支持单色连线 | 不支持 CSS `linear-gradient` 作为 `stroke` |
| 毛玻璃悬浮效果 (`backdrop-filter`) | SVG 元素不支持 `backdrop-filter` | 无法覆盖 |
| 条件判断节点菱形 + 橙色边框 | 流程图支持菱形，但样式受限 | 边框颜色可覆盖，但无法添加"通过/拒绝"标签 |
| 时间线横向渐变轴线 | 时间线图为纵向 | 布局引擎固定，无法改为横向 |
| 看板三列布局 | 不支持 | 无看板类型 |

Mermaid.js 适合快速生成标准图表，但不适合品牌级自定义视觉系统。对于 AIRecording 的暗黑极客风设计系统，必须采用自定义 HTML/CSS 方案。

---

## 4. LangGraph Agent 架构（核心实现）

### 4.1 StateGraph 完整定义

```python
# chart_agent.py
from typing import TypedDict, List, Dict, Any, Optional, Literal
from langgraph.graph import StateGraph, END

# ─── State TypedDict ─────────────────────────────────────────────────────────

class ChartNodeData(TypedDict):
    id: str
    label: str
    level: int
    node_type: str  # "root" | "branch" | "leaf" | "decision" | "milestone" | "task" | "data"
    color: Optional[str]
    metadata: Optional[Dict[str, Any]]

class ChartEdgeData(TypedDict):
    source: str
    target: str
    label: Optional[str]
    style: Optional[str]

class ChartAgentState(TypedDict):
    # 输入
    request_id: str
    theme: str
    participants: List[str]
    key_decisions: List[str]
    action_items: List[Dict[str, str]]
    timeline: List[str]
    markdown_content: str
    raw_transcription: Optional[str]
    preferences: Dict[str, Any]

    # 中间状态
    content_features: Dict[str, Any]       # text_analysis 输出
    selected_chart_type: str               # chart_type_select 输出
    confidence: float
    structured_data: Dict[str, Any]        # data_extract 输出
    html_fragment: Optional[str]           # chart_generate 输出
    render_config: Optional[Dict[str, Any]]

    # 校验与重试
    validation_result: Optional[Dict[str, Any]]
    retry_count: int
    error_message: Optional[str]

    # 输出
    status: Literal["success", "failed", "degraded"]
    charts: List[Dict[str, Any]]

# ─── 节点函数 ────────────────────────────────────────────────────────────────

def text_analysis(state: ChartAgentState) -> ChartAgentState:
    """
    分析输入文本的内容特征，提取决策所需的特征向量。
    使用 LLM + 规则混合策略。
    """
    ...

def chart_type_select(state: ChartAgentState) -> ChartAgentState:
    """
    基于 content_features 决策图表类型。
    规则引擎为主，LLM 为辅（处理模糊边界）。
    """
    ...

def data_extract(state: ChartAgentState) -> ChartAgentState:
    """
    根据 selected_chart_type，从文本中提取结构化数据（节点/边/时间/数值）。
    使用 LLM 提取 + 后处理标准化。
    """
    ...

def chart_generate(state: ChartAgentState) -> ChartAgentState:
    """
    使用 Jinja2 模板将 structured_data 渲染为暗黑极客风 HTML。
    """
    ...

def validate(state: ChartAgentState) -> ChartAgentState:
    """
    语法校验（HTML 闭合标签）+ 语义校验（流程图死路检测）+ 视觉规范校验（CSS 变量完整性）。
    """
    ...

# ─── Graph 构建 ──────────────────────────────────────────────────────────────

builder = StateGraph(ChartAgentState)

builder.add_node("text_analysis", text_analysis)
builder.add_node("chart_type_select", chart_type_select)
builder.add_node("data_extract", data_extract)
builder.add_node("chart_generate", chart_generate)
builder.add_node("validate", validate)

builder.set_entry_point("text_analysis")
builder.add_edge("text_analysis", "chart_type_select")
builder.add_edge("chart_type_select", "data_extract")
builder.add_edge("data_extract", "chart_generate")
builder.add_edge("chart_generate", "validate")

# 条件边：校验失败且重试次数 < 2 时回退 chart_generate
builder.add_conditional_edges(
    "validate",
    lambda state: "chart_generate" if (
        state.get("validation_result", {}).get("passed") is False
        and state.get("retry_count", 0) < 2
    ) else "end"
)

chart_agent = builder.compile()
```

### 4.2 条件路由决策表

图表类型选择基于**规则引擎 + LLM 辅助**的混合策略。规则引擎负责快速初筛，LLM 负责模糊边界裁决。

| 检测特征 | 权重 | 匹配图表类型 | 置信度阈值 | 关键词/正则示例 |
|----------|------|-------------|-----------|----------------|
| 层级化主题-子主题 >= 3 层 | 0.90 | `mindmap` | >= 0.70 | 包含"功能模块""子功能""优先级"等层级表达；正则：`(\d+\.[\d\.]+\s+)` 或 `(一、\|二、\|三、)` |
| 条件判断表达 >= 2 个 | 0.85 | `flowchart` | >= 0.70 | "如果...则...""取决于...""方案 A / 方案 B""是否""条件" |
| 日期/时间表达 >= 3 个 | 0.80 | `timeline` | >= 0.60 | 日期格式（`\d{4}[-/]\d{2}[-/]\d{2}`）或 "Q1""月底""截止""里程碑" |
| 数值/百分比/占比表达 >= 3 个 | 0.75 | `pie` / `bar` | >= 0.60 | `\d+\.?\d*%`"占比""增长""投票结果""预算""分配" |
| 人名 + 汇报/负责关系 >= 3 组 | 0.80 | `orgchart` | >= 0.60 | 人名（2-4 汉字）+ "汇报给""负责""下属""管理""团队" |
| 待办事项 >= 3 个 | 0.70 | `kanban` | >= 0.50 | "待办""进行中""已完成""TODO""Action Item""负责人" |

**决策逻辑伪代码：**

```python
def chart_type_select(state: ChartAgentState) -> ChartAgentState:
    features = state["content_features"]
    scores = {
        "mindmap": features.get("hierarchy_depth", 0) * 0.30 + features.get("topic_count", 0) * 0.10,
        "flowchart": features.get("condition_count", 0) * 0.425,
        "timeline": features.get("date_count", 0) * 0.267,
        "pie": features.get("percentage_count", 0) * 0.25,
        "bar": features.get("numeric_compare_count", 0) * 0.25,
        "orgchart": features.get("name_relation_count", 0) * 0.267,
        "kanban": features.get("todo_count", 0) * 0.233,
    }

    # 阈值表
    thresholds = {
        "mindmap": 0.70, "flowchart": 0.70, "timeline": 0.60,
        "pie": 0.60, "bar": 0.60, "orgchart": 0.60, "kanban": 0.50,
    }

    best_type = max(scores, key=scores.get)
    best_score = scores[best_type]

    if best_score >= thresholds[best_type]:
        state["selected_chart_type"] = best_type
        state["confidence"] = min(best_score, 1.0)
    else:
        # 降级为通用思维导图
        state["selected_chart_type"] = "mindmap"
        state["confidence"] = 0.5
        state["status"] = "degraded"

    return state
```

### 4.3 各节点实现伪代码

#### 4.3.1 text_analysis

```python
def text_analysis(state: ChartAgentState) -> ChartAgentState:
    text = state["markdown_content"]

    features = {
        "hierarchy_depth": count_hierarchy_depth(text),      # 最大层级深度
        "topic_count": count_topics(text),                   # 主题数量
        "condition_count": count_conditions(text),           # 条件判断数量
        "date_count": count_dates(text),                     # 日期/时间表达数量
        "percentage_count": count_percentages(text),         # 百分比数量
        "numeric_compare_count": count_numeric_comparisons(text),
        "name_relation_count": count_name_relations(text),   # 人名+关系数量
        "todo_count": count_todos(text),                     # 待办事项数量
        "text_length": len(text),
    }

    # 文本过短保护
    if features["text_length"] < 100:
        state["error_message"] = "内容过短，无法生成有意义的图表"
        state["status"] = "failed"
        return state

    state["content_features"] = features
    return state
```

#### 4.3.2 data_extract

```python
def data_extract(state: ChartAgentState) -> ChartAgentState:
    chart_type = state["selected_chart_type"]
    text = state["markdown_content"]

    # 使用 LLM 提取结构化数据
    prompt = build_extraction_prompt(chart_type, text)
    raw_json = call_llm(prompt)

    structured = parse_and_validate_json(raw_json, chart_type)
    state["structured_data"] = structured
    return state
```

#### 4.3.3 chart_generate

```python
def chart_generate(state: ChartAgentState) -> ChartAgentState:
    chart_type = state["selected_chart_type"]
    data = state["structured_data"]
    theme = state.get("preferences", {}).get("styleTheme", "darkCyberpunk")

    template = jinja_env.get_template(f"{chart_type}.html.j2")
    html = template.render(
        data=data,
        theme=theme,
        dark_css=DARK_CSS,
        title=state["theme"],
    )

    state["html_fragment"] = html
    state["render_config"] = {
        "styleTokens": DARK_CSS_TOKENS,
        "cssFramework": "dark-cyberpunk-v1",
    }
    return state
```

#### 4.3.4 validate

```python
def validate(state: ChartAgentState) -> ChartAgentState:
    html = state.get("html_fragment", "")
    retry = state.get("retry_count", 0)

    errors = []

    # 1. 语法校验：HTML 基本闭合
    if html.count("<div") != html.count("</div>"):
        errors.append("Unmatched div tags")

    # 2. 语义校验：流程图死路检测
    if state["selected_chart_type"] == "flowchart":
        if has_dead_end(state["structured_data"]):
            errors.append("Flowchart has dead end")

    # 3. 视觉规范校验：CSS 变量完整性
    required_vars = ["--bg", "--card", "--cyan", "--purple"]
    for var in required_vars:
        if var not in html:
            errors.append(f"Missing CSS variable: {var}")

    if errors:
        state["validation_result"] = {"passed": False, "errors": errors}
        state["retry_count"] = retry + 1
        if retry >= 2:
            state["status"] = "failed"
            state["error_message"] = "; ".join(errors)
    else:
        state["validation_result"] = {"passed": True}
        state["status"] = "success"

    return state
```

### 4.4 错误重试机制

```
chart_generate ──▶ validate
                      │
                      │ 失败 + retry < 2
                      └──────────▶ chart_generate (retry_count + 1)
                      │
                      │ 失败 + retry >= 2
                      └──────────▶ END (status: failed)
                      │
                      │ 通过
                      └──────────▶ END (status: success)
```

- 最多重试 2 次（总计最多 3 次生成尝试）
- 每次重试保留前一次的 `structured_data`，仅重新执行模板渲染
- 若 3 次均失败，返回 `status: failed` 和具体错误信息

---

## 5. Swift 侧实现

### 5.1 ChartSkill Protocol 完整定义

```swift
// AIRecording/Services/ChartSkill.swift
import Foundation

// MARK: - Enums

enum ChartType: Int16, CaseIterable, Codable {
    case mindmap = 0
    case flowchart = 1
    case timeline = 2
    case pie = 3
    case bar = 4
    case orgChart = 5
    case kanban = 6
    case unknown = 99

    var displayName: String {
        switch self {
        case .mindmap: return "思维导图"
        case .flowchart: return "流程图"
        case .timeline: return "时间线"
        case .pie: return "饼图"
        case .bar: return "柱状图"
        case .orgChart: return "组织架构图"
        case .kanban: return "看板"
        case .unknown: return "未知"
        }
    }
}

enum ChartStatus: Int16, Codable {
    case pending = 0
    case analyzing = 1
    case generating = 2
    case rendering = 3
    case completed = 4
    case failed = 5
    case cancelled = 6
}

enum ChartSkillError: Error, Equatable {
    case serviceUnavailable
    case serviceNotRunning
    case invalidRequest
    case invalidResponse
    case generationFailed(String)
    case validationFailed(String)
    case networkError(underlying: Error)
    case timeout
    case contentTooShort
    case decodingFailed

    var localizedDescription: String {
        switch self {
        case .serviceUnavailable: return "图表服务不可用"
        case .serviceNotRunning: return "图表引擎未启动"
        case .invalidRequest: return "请求参数无效"
        case .invalidResponse: return "响应格式无效"
        case .generationFailed(let msg): return "生成失败: \(msg)"
        case .validationFailed(let msg): return "校验失败: \(msg)"
        case .networkError(let err): return "网络错误: \(err.localizedDescription)"
        case .timeout: return "图表生成超时"
        case .contentTooShort: return "内容过短，无法生成有意义的图表"
        case .decodingFailed: return "数据解析失败"
        }
    }
}

// MARK: - Data Models

struct ChartGenerateRequest: Codable {
    let version: String
    let requestId: String
    let content: ChartContent
    let preferences: ChartPreferences

    struct ChartContent: Codable {
        let theme: String
        let participants: [String]
        let keyDecisions: [String]
        let actionItems: [ActionItem]
        let timeline: [String]
        let markdownContent: String
        let rawTranscription: String?

        struct ActionItem: Codable {
            let content: String
            let assignee: String?
            let deadline: String?
        }
    }

    struct ChartPreferences: Codable {
        let primaryChartType: String  // "auto" or ChartType rawValue string
        let styleTheme: String        // "darkCyberpunk" (default)
        let outputFormats: [String]   // ["html", "png", "svg"]
    }
}

struct ChartGenerateResponse: Codable {
    let version: String
    let requestId: String
    let status: String  // "success" | "failed" | "degraded"
    let charts: [ChartResult]
    let errors: [String]
}

struct ChartResult: Codable {
    let chartType: String
    let chartTypeDisplayName: String
    let confidence: Double
    let htmlFragment: String
    let renderConfig: RenderConfig
    let structuredData: ChartStructuredData
    let metadata: ChartMetadata

    struct RenderConfig: Codable {
        let styleTokens: [String: String]
        let cssFramework: String
    }

    struct ChartStructuredData: Codable {
        let nodes: [ChartNodeDTO]
        let edges: [ChartEdgeDTO]

        struct ChartNodeDTO: Codable {
            let id: String
            let label: String
            let level: Int
            let nodeType: String
            let color: String?
            let metadata: [String: String]?
        }

        struct ChartEdgeDTO: Codable {
            let from: String
            let to: String
            let label: String?
        }
    }

    struct ChartMetadata: Codable {
        let nodeCount: Int
        let maxDepth: Int
        let generationTimeMs: Int
    }
}

struct ChartStyleConfig: Codable {
    let theme: String
    let bg: String
    let card: String
    let border: String
    let text: String
    let textSecondary: String
    let cyan: String
    let purple: String
    let orange: String
    let green: String
    let red: String
    let blue: String
    let cardRadius: String
    let cardShadow: String
    let glassBlur: String
    let gradientText: String
    let terminalBg: String
}

// MARK: - Protocol

protocol ChartSkill {
    var skillId: String { get }
    var skillVersion: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }

    func generate(request: ChartGenerateRequest) async throws -> ChartGenerateResponse
}
```

### 5.2 HTTPChartSkill 实现

```swift
// AIRecording/Services/HTTPChartSkill.swift
import Foundation

class HTTPChartSkill: ChartSkill {
    static let shared = HTTPChartSkill()

    let skillId = "chart.agent.v1"
    let skillVersion = "1.1.0"
    let displayName = "智能图表生成"

    private let baseURL: URL
    private let session: URLSession
    private let timeout: TimeInterval = 60

    var isAvailable: Bool {
        get async {
            await checkHealth()
        }
    }

    init(baseURL: URL = URL(string: "http://127.0.0.1:8765")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - ChartSkill

    func generate(request: ChartGenerateRequest) async throws -> ChartGenerateResponse {
        guard await isAvailable else {
            throw ChartSkillError.serviceNotRunning
        }

        let url = baseURL.appendingPathComponent("/chart/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = timeout

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw ChartSkillError.invalidRequest
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ChartSkillError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChartSkillError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChartSkillError.generationFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        do {
            let result = try JSONDecoder().decode(ChartGenerateResponse.self, from: data)
            if result.status == "failed", let firstError = result.errors.first {
                throw ChartSkillError.generationFailed(firstError)
            }
            return result
        } catch {
            throw ChartSkillError.decodingFailed
        }
    }

    // MARK: - Health Check

    func checkHealth() async -> Bool {
        let url = baseURL.appendingPathComponent("/health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }
}
```

### 5.3 ChartWebView（NSViewRepresentable 包装 WKWebView）

```swift
// AIRecording/Views/ChartWebView.swift
import SwiftUI
import WebKit

struct ChartWebView: NSViewRepresentable {
    let htmlContent: String
    var onNodeTap: ((String) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptEnabled = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // 透明背景
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let styledHTML = wrapWithDarkTheme(htmlContent)
        nsView.loadHTMLString(styledHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onNodeTap: onNodeTap)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var onNodeTap: ((String) -> Void)?

        init(onNodeTap: ((String) -> Void)?) {
            self.onNodeTap = onNodeTap
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 注入 JS Bridge（可选）
            let script = """
            document.querySelectorAll('.chart-node').forEach(node => {
                node.addEventListener('click', () => {
                    window.webkit.messageHandlers.nodeTap.postMessage(node.dataset.nodeId);
                });
            });
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    // MARK: - HTML Wrapper

    private func wrapWithDarkTheme(_ html: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        :root {
          --bg: #0F0F1A;
          --card: #1E1E2E;
          --border: #33334D;
          --text: #E2E8F0;
          --text-secondary: #94A3B8;
          --cyan: #22D3EE;
          --purple: #8B5CF6;
          --orange: #F59E0B;
          --green: #34C759;
          --red: #FF3B30;
          --blue: #3B82F6;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
          background: var(--bg);
          color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          padding: 20px;
          min-height: 100vh;
        }
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }
}
```

### 5.4 ChartPanelView（SwiftUI 视图）

```swift
// AIRecording/Views/ChartPanelView.swift
import SwiftUI

struct ChartPanelView: View {
    @StateObject private var viewModel: ChartPanelViewModel

    init(recordingId: UUID) {
        _viewModel = StateObject(wrappedValue: ChartPanelViewModel(recordingId: recordingId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            Divider()

            contentView
        }
        .padding()
        .background(Color(hex: "#1E1E2E"))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "#33334D"), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("智能图表")
                .font(.headline)
                .foregroundStyle(Color(hex: "#E2E8F0"))

            Spacer()

            if viewModel.isGenerating {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("生成中...")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "#94A3B8"))
                }
            } else if let chart = viewModel.chartResult {
                HStack(spacing: 8) {
                    Text(chart.chartTypeDisplayName)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color(hex: "#33334D"))
                        .cornerRadius(4)
                        .foregroundStyle(Color(hex: "#22D3EE"))

                    Button("导出 HTML") {
                        viewModel.exportHTML()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if let error = viewModel.errorMessage {
            errorView(message: error)
        } else if let chart = viewModel.chartResult {
            ChartWebView(htmlContent: chart.htmlFragment)
                .frame(minHeight: 400)
                .background(Color(hex: "#0F0F1A"))
                .cornerRadius(12)
        } else {
            emptyView
        }
    }

    private var emptyView: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Text("暂无图表")
                    .foregroundStyle(Color(hex: "#94A3B8"))
                Button("生成图表") {
                    viewModel.generateChart()
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(.vertical, 40)
    }

    private func errorView(message: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(Color(hex: "#F59E0B"))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color(hex: "#94A3B8"))
                    .multilineTextAlignment(.center)
                Button("重试") {
                    viewModel.generateChart()
                }
            }
            Spacer()
        }
        .padding(.vertical, 20)
    }
}

// MARK: - ViewModel

@MainActor
class ChartPanelViewModel: ObservableObject {
    @Published var isGenerating = false
    @Published var chartResult: ChartResult?
    @Published var errorMessage: String?

    private let recordingId: UUID
    private let chartSkill: ChartSkill

    init(recordingId: UUID, chartSkill: ChartSkill = HTTPChartSkill.shared) {
        self.recordingId = recordingId
        self.chartSkill = chartSkill
    }

    func generateChart() {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                // TODO: 从 Recording/Summary 组装真实请求数据
                let request = ChartGenerateRequest(
                    version: "1.0",
                    requestId: UUID().uuidString,
                    content: .init(
                        theme: "会议主题",
                        participants: [],
                        keyDecisions: [],
                        actionItems: [],
                        timeline: [],
                        markdownContent: "",
                        rawTranscription: nil
                    ),
                    preferences: .init(
                        primaryChartType: "auto",
                        styleTheme: "darkCyberpunk",
                        outputFormats: ["html"]
                    )
                )

                let response = try await chartSkill.generate(request: request)
                if let firstChart = response.charts.first {
                    self.chartResult = firstChart
                }
                self.isGenerating = false
            } catch {
                self.errorMessage = (error as? ChartSkillError)?.localizedDescription ?? error.localizedDescription
                self.isGenerating = false
            }
        }
    }

    func exportHTML() {
        guard let html = chartResult?.htmlFragment else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "chart_\(recordingId.uuidString.prefix(8)).html"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fullHTML = wrapAsStandaloneHTML(html)
            try fullHTML.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.errorMessage = "导出失败: \(error.localizedDescription)"
        }
    }

    private func wrapAsStandaloneHTML(_ fragment: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="UTF-8">
        <title>AIRecording 图表导出</title>
        <style>
        :root {
          --bg: #0F0F1A; --card: #1E1E2E; --border: #33334D;
          --text: #E2E8F0; --text-secondary: #94A3B8;
          --cyan: #22D3EE; --purple: #8B5CF6; --orange: #F59E0B;
          --green: #34C759; --red: #FF3B30; --blue: #3B82F6;
        }
        body { background: var(--bg); color: var(--text); font-family: -apple-system, sans-serif; padding: 40px; }
        </style>
        </head>
        <body>
        \(fragment)
        </body>
        </html>
        """
    }
}
```

### 5.5 Color Hex 扩展

```swift
// AIRecording/Utilities/Color+Hex.swift
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
```

---

## 6. Python 侧实现

### 6.1 项目结构

```
AIRecording/
├── AIRecording/                    # Swift 源码（已有）
│   └── ...
├── ChartAgent/                     # Python 服务（新增目录）
│   ├── main.py                     # FastAPI 入口
│   ├── agent/
│   │   ├── __init__.py
│   │   ├── graph.py                # StateGraph 定义
│   │   ├── nodes.py                # 5 个节点函数
│   │   ├── router.py               # 条件路由逻辑
│   │   └── llm_client.py           # LLM 封装（OpenAI + Ollama fallback）
│   ├── templates/
│   │   ├── base.html.j2            # 基模板 + 暗黑极客风 CSS
│   │   ├── mindmap.html.j2         # 思维导图模板
│   │   ├── flowchart.html.j2       # 流程图模板
│   │   ├── timeline.html.j2        # 时间线模板
│   │   ├── pie.html.j2             # 饼图模板
│   │   ├── bar.html.j2             # 柱状图模板
│   │   ├── orgchart.html.j2        # 组织架构图模板
│   │   └── kanban.html.j2          # 看板模板
│   ├── requirements.txt            # Python 依赖
│   └── README.md                   # 安装与启动说明
└── docs/
    └── TechSpec-ChartAgent.md
```

### 6.2 FastAPI 服务入口

```python
# ChartAgent/main.py
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
import uuid
import time

from agent.graph import chart_agent
from agent.nodes import ChartAgentState

app = FastAPI(title="AIRecording Chart Agent", version="1.1.0")

# CORS：仅允许本地回环
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:*", "http://127.0.0.1:*"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# ─── Request/Response Models ────────────────────────────────────────────────

class ActionItem(BaseModel):
    content: str
    assignee: Optional[str] = None
    deadline: Optional[str] = None

class ChartContent(BaseModel):
    theme: str
    participants: List[str] = []
    keyDecisions: List[str] = []
    actionItems: List[ActionItem] = []
    timeline: List[str] = []
    markdownContent: str
    rawTranscription: Optional[str] = None

class ChartPreferences(BaseModel):
    primaryChartType: str = "auto"
    styleTheme: str = "darkCyberpunk"
    outputFormats: List[str] = ["html"]

class ChartGenerateRequest(BaseModel):
    version: str = "1.0"
    requestId: str = Field(default_factory=lambda: str(uuid.uuid4()))
    content: ChartContent
    preferences: ChartPreferences = ChartPreferences()

class ChartResult(BaseModel):
    chartType: str
    chartTypeDisplayName: str
    confidence: float
    htmlFragment: str
    renderConfig: Dict[str, Any]
    structuredData: Dict[str, Any]
    metadata: Dict[str, Any]

class ChartGenerateResponse(BaseModel):
    version: str = "1.0"
    requestId: str
    status: str
    charts: List[ChartResult]
    errors: List[str]

# ─── Endpoints ──────────────────────────────────────────────────────────────

@app.post("/chart/generate", response_model=ChartGenerateResponse)
async def chart_generate_endpoint(request: ChartGenerateRequest):
    start_time = time.time()

    # 组装 State
    state: ChartAgentState = {
        "request_id": request.requestId,
        "theme": request.content.theme,
        "participants": request.content.participants,
        "key_decisions": request.content.keyDecisions,
        "action_items": [item.model_dump() for item in request.content.actionItems],
        "timeline": request.content.timeline,
        "markdown_content": request.content.markdownContent,
        "raw_transcription": request.content.rawTranscription,
        "preferences": request.preferences.model_dump(),
        "content_features": {},
        "selected_chart_type": "",
        "confidence": 0.0,
        "structured_data": {},
        "html_fragment": None,
        "render_config": None,
        "validation_result": None,
        "retry_count": 0,
        "error_message": None,
        "status": "success",
        "charts": [],
    }

    try:
        result_state = chart_agent.invoke(state)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    generation_time_ms = int((time.time() - start_time) * 1000)

    if result_state.get("status") == "failed":
        return ChartGenerateResponse(
            version="1.0",
            requestId=request.requestId,
            status="failed",
            charts=[],
            errors=[result_state.get("error_message", "Unknown error")],
        )

    chart_result = ChartResult(
        chartType=result_state["selected_chart_type"],
        chartTypeDisplayName=chart_type_display_name(result_state["selected_chart_type"]),
        confidence=result_state.get("confidence", 0.0),
        htmlFragment=result_state.get("html_fragment", ""),
        renderConfig=result_state.get("render_config", {}),
        structuredData=result_state.get("structured_data", {}),
        metadata={
            "nodeCount": len(result_state.get("structured_data", {}).get("nodes", [])),
            "maxDepth": compute_max_depth(result_state.get("structured_data", {}).get("nodes", [])),
            "generationTimeMs": generation_time_ms,
        },
    )

    return ChartGenerateResponse(
        version="1.0",
        requestId=request.requestId,
        status=result_state.get("status", "success"),
        charts=[chart_result],
        errors=[],
    )

@app.get("/health")
async def health_check():
    return {"status": "ok", "version": "1.1.0"}

# ─── Helpers ────────────────────────────────────────────────────────────────

def chart_type_display_name(chart_type: str) -> str:
    mapping = {
        "mindmap": "思维导图",
        "flowchart": "流程图",
        "timeline": "时间线",
        "pie": "饼图",
        "bar": "柱状图",
        "orgchart": "组织架构图",
        "kanban": "看板",
    }
    return mapping.get(chart_type, "未知")

def compute_max_depth(nodes: List[Dict[str, Any]]) -> int:
    if not nodes:
        return 0
    return max((node.get("level", 0) for node in nodes), default=0)

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765)
```

### 6.3 LangGraph Agent 完整代码

```python
# ChartAgent/agent/graph.py
from langgraph.graph import StateGraph, END
from typing import TypedDict, List, Dict, Any, Optional, Literal

from .nodes import (
    text_analysis,
    chart_type_select,
    data_extract,
    chart_generate,
    validate,
)

class ChartAgentState(TypedDict):
    request_id: str
    theme: str
    participants: List[str]
    key_decisions: List[str]
    action_items: List[Dict[str, str]]
    timeline: List[str]
    markdown_content: str
    raw_transcription: Optional[str]
    preferences: Dict[str, Any]
    content_features: Dict[str, Any]
    selected_chart_type: str
    confidence: float
    structured_data: Dict[str, Any]
    html_fragment: Optional[str]
    render_config: Optional[Dict[str, Any]]
    validation_result: Optional[Dict[str, Any]]
    retry_count: int
    error_message: Optional[str]
    status: Literal["success", "failed", "degraded"]
    charts: List[Dict[str, Any]]

def build_chart_agent():
    builder = StateGraph(ChartAgentState)

    builder.add_node("text_analysis", text_analysis)
    builder.add_node("chart_type_select", chart_type_select)
    builder.add_node("data_extract", data_extract)
    builder.add_node("chart_generate", chart_generate)
    builder.add_node("validate", validate)

    builder.set_entry_point("text_analysis")
    builder.add_edge("text_analysis", "chart_type_select")
    builder.add_edge("chart_type_select", "data_extract")
    builder.add_edge("data_extract", "chart_generate")
    builder.add_edge("chart_generate", "validate")

    def route_from_validate(state: ChartAgentState) -> str:
        validation = state.get("validation_result", {})
        retry = state.get("retry_count", 0)
        if validation.get("passed") is False and retry < 2:
            return "chart_generate"
        return END

    builder.add_conditional_edges("validate", route_from_validate)

    return builder.compile()

chart_agent = build_chart_agent()
```

```python
# ChartAgent/agent/nodes.py
import re
import json
from typing import Dict, Any, List
from .llm_client import call_llm
from .templates import render_chart

# ─── text_analysis ──────────────────────────────────────────────────────────

def text_analysis(state: Dict[str, Any]) -> Dict[str, Any]:
    text = state["markdown_content"]

    features = {
        "hierarchy_depth": _count_hierarchy_depth(text),
        "topic_count": len(re.findall(r'^[\s]*[-•*]\s+', text, re.MULTILINE)),
        "condition_count": len(re.findall(r'如果|若|取决于|方案[AB]|是否|条件', text)),
        "date_count": len(re.findall(r'\d{4}[-/]\d{2}[-/]\d{2}|Q[1-4]|月底|截止|里程碑|阶段', text)),
        "percentage_count": len(re.findall(r'\d+\.?\d*%|占比|百分比', text)),
        "numeric_compare_count": len(re.findall(r'\d+\.?\d*\s*[万亿]?元|\d+\.?\d*\s*个|增长|下降', text)),
        "name_relation_count": len(re.findall(r'汇报给|负责|下属|管理.*团队', text)),
        "todo_count": len(re.findall(r'待办|TODO|Action Item|进行中|已完成|负责人', text)),
        "text_length": len(text),
    }

    if features["text_length"] < 100:
        state["error_message"] = "内容过短，无法生成有意义的图表"
        state["status"] = "failed"
        return state

    state["content_features"] = features
    return state

def _count_hierarchy_depth(text: str) -> int:
    max_depth = 0
    for line in text.split("\n"):
        depth = 0
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped.startswith(("-", "*", "•")):
            depth = 1 + indent // 2
        elif re.match(r'^(\d+\.|\d+\))\s', stripped):
            depth = 1
        elif re.match(r'^[一二三四五六七八九十]+[、.\s]', stripped):
            depth = 1
        max_depth = max(max_depth, depth)
    return max_depth

# ─── chart_type_select ──────────────────────────────────────────────────────

def chart_type_select(state: Dict[str, Any]) -> Dict[str, Any]:
    features = state["content_features"]

    scores = {
        "mindmap": features.get("hierarchy_depth", 0) * 0.30 + features.get("topic_count", 0) * 0.05,
        "flowchart": features.get("condition_count", 0) * 0.425,
        "timeline": features.get("date_count", 0) * 0.267,
        "pie": features.get("percentage_count", 0) * 0.25,
        "bar": features.get("numeric_compare_count", 0) * 0.20,
        "orgchart": features.get("name_relation_count", 0) * 0.267,
        "kanban": features.get("todo_count", 0) * 0.233,
    }

    thresholds = {
        "mindmap": 0.70, "flowchart": 0.70, "timeline": 0.60,
        "pie": 0.60, "bar": 0.60, "orgchart": 0.60, "kanban": 0.50,
    }

    best_type = max(scores, key=scores.get)
    best_score = scores[best_type]

    if best_score >= thresholds[best_type]:
        state["selected_chart_type"] = best_type
        state["confidence"] = min(best_score, 1.0)
    else:
        state["selected_chart_type"] = "mindmap"
        state["confidence"] = 0.5
        state["status"] = "degraded"

    return state

# ─── data_extract ───────────────────────────────────────────────────────────

def data_extract(state: Dict[str, Any]) -> Dict[str, Any]:
    chart_type = state["selected_chart_type"]
    text = state["markdown_content"]

    prompt = _build_extraction_prompt(chart_type, text)
    raw_response = call_llm(prompt)

    try:
        structured = json.loads(raw_response)
    except json.JSONDecodeError:
        # 尝试从 markdown code block 提取
        match = re.search(r'```json\s*(.*?)\s*```', raw_response, re.DOTALL)
        if match:
            structured = json.loads(match.group(1))
        else:
            structured = {"nodes": [], "edges": []}

    state["structured_data"] = structured
    return state

def _build_extraction_prompt(chart_type: str, text: str) -> str:
    templates = {
        "mindmap": """从以下文本中提取思维导图结构。输出 JSON：
{"nodes": [{"id": "1", "label": "根节点", "level": 0, "node_type": "root"}, ...],
 "edges": [{"from": "1", "to": "2"}, ...]}""",
        "flowchart": """从以下文本中提取流程图结构。输出 JSON：
{"nodes": [{"id": "1", "label": "开始", "level": 0, "node_type": "root"}, {"id": "2", "label": "条件", "level": 1, "node_type": "decision"}, ...],
 "edges": [{"from": "1", "to": "2", "label": "是"}, ...]}""",
        "timeline": """从以下文本中提取时间线事件。输出 JSON：
{"nodes": [{"id": "1", "label": "事件描述", "level": 0, "node_type": "milestone", "metadata": {"date": "2024-01-01"}}, ...],
 "edges": []}""",
        "pie": """从以下文本中提取分类占比数据。输出 JSON：
{"nodes": [{"id": "1", "label": "分类A", "level": 0, "node_type": "data", "metadata": {"value": 30, "percentage": "30%"}}, ...],
 "edges": []}""",
        "bar": """从以下文本中提取分类对比数据。输出 JSON：
{"nodes": [{"id": "1", "label": "分类A", "level": 0, "node_type": "data", "metadata": {"value": 100}}, ...],
 "edges": []}""",
        "orgchart": """从以下文本中提取组织架构关系。输出 JSON：
{"nodes": [{"id": "1", "label": "姓名/职位", "level": 0, "node_type": "root"}, ...],
 "edges": [{"from": "1", "to": "2", "label": "下属"}, ...]}""",
        "kanban": """从以下文本中提取看板任务。输出 JSON：
{"nodes": [{"id": "1", "label": "任务内容", "level": 0, "node_type": "task", "metadata": {"status": "todo", "assignee": "负责人"}}, ...],
 "edges": []}""",
    }
    base = templates.get(chart_type, templates["mindmap"])
    return f"{base}\n\n文本内容：\n{text}\n\n仅输出 JSON，不要其他解释。"

# ─── chart_generate ─────────────────────────────────────────────────────────

def chart_generate(state: Dict[str, Any]) -> Dict[str, Any]:
    chart_type = state["selected_chart_type"]
    data = state["structured_data"]
    theme = state.get("preferences", {}).get("styleTheme", "darkCyberpunk")

    html = render_chart(chart_type, data, theme, title=state["theme"])

    state["html_fragment"] = html
    state["render_config"] = {
        "styleTokens": _dark_css_tokens(),
        "cssFramework": "dark-cyberpunk-v1",
    }
    return state

def _dark_css_tokens() -> Dict[str, str]:
    return {
        "bg": "#0F0F1A",
        "cardBg": "#1E1E2E",
        "border": "#33334D",
        "text": "#E2E8F0",
        "textSecondary": "#94A3B8",
        "cyan": "#22D3EE",
        "purple": "#8B5CF6",
        "orange": "#F59E0B",
        "green": "#34C759",
        "red": "#FF3B30",
        "blue": "#3B82F6",
        "cardRadius": "16px",
        "cardShadow": "0 12px 32px rgba(0,0,0,0.3)",
        "glassBlur": "blur(12px)",
        "gradientText": "linear-gradient(135deg, #22D3EE, #8B5CF6)",
        "terminalBg": "#0A0A14",
    }

# ─── validate ───────────────────────────────────────────────────────────────

def validate(state: Dict[str, Any]) -> Dict[str, Any]:
    html = state.get("html_fragment", "")
    retry = state.get("retry_count", 0)
    errors = []

    if html.count("<div") != html.count("</div>"):
        errors.append("Unmatched div tags")

    if state["selected_chart_type"] == "flowchart":
        edges = state.get("structured_data", {}).get("edges", [])
        nodes = state.get("structured_data", {}).get("nodes", [])
        if _has_dead_end(nodes, edges):
            errors.append("Flowchart has dead end")

    required_vars = ["--bg", "--card", "--cyan", "--purple"]
    for var in required_vars:
        if var not in html:
            errors.append(f"Missing CSS variable: {var}")

    if errors:
        state["validation_result"] = {"passed": False, "errors": errors}
        state["retry_count"] = retry + 1
        if retry >= 2:
            state["status"] = "failed"
            state["error_message"] = "; ".join(errors)
    else:
        state["validation_result"] = {"passed": True}
        state["status"] = "success"

    return state

def _has_dead_end(nodes: List[Dict], edges: List[Dict]) -> bool:
    if not nodes or not edges:
        return False
    node_ids = {n["id"] for n in nodes}
    sources = {e["from"] for e in edges}
    targets = {e["to"] for e in edges}
    # 检查是否有非结束节点没有出边
    end_nodes = {"end", "结束", "完成", "done"}
    for node in nodes:
        nid = node["id"]
        label = node.get("label", "").lower()
        if nid not in sources and label not in end_nodes and len(edges) > 0:
            return True
    # 检查是否有节点没有入边（非开始节点）
    start_nodes = {"start", "开始", "启动"}
    for node in nodes:
        nid = node["id"]
        label = node.get("label", "").lower()
        if nid not in targets and label not in start_nodes and len(edges) > 0:
            return True
    return False
```

### 6.4 Jinja2 模板系统

```python
# ChartAgent/agent/templates.py
import os
from jinja2 import Environment, FileSystemLoader, DictLoader

# 模板目录（相对于 main.py）
TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "..", "templates")

# 若目录不存在，使用内联模板（便于打包）
_inline_templates = {
    "base.html.j2": _BASE_TEMPLATE,
    "mindmap.html.j2": _MINDMAP_TEMPLATE,
    "flowchart.html.j2": _FLOWCHART_TEMPLATE,
    "timeline.html.j2": _TIMELINE_TEMPLATE,
    "pie.html.j2": _PIE_TEMPLATE,
    "bar.html.j2": _BAR_TEMPLATE,
    "orgchart.html.j2": _ORGCHART_TEMPLATE,
    "kanban.html.j2": _KANBAN_TEMPLATE,
}

def get_jinja_env():
    if os.path.exists(TEMPLATE_DIR):
        return Environment(loader=FileSystemLoader(TEMPLATE_DIR))
    return Environment(loader=DictLoader(_inline_templates))

_jinja_env = get_jinja_env()

def render_chart(chart_type: str, data: dict, theme: str, title: str = "") -> str:
    template = _jinja_env.get_template(f"{chart_type}.html.j2")
    return template.render(
        data=data,
        theme=theme,
        title=title,
        dark_css=DARK_CSS,
    )
```

#### 6.4.1 基模板（含完整暗黑极客风 CSS）

```python
# ChartAgent/agent/templates.py (continued)

DARK_CSS = """
:root {
  --bg: #0F0F1A;
  --card: #1E1E2E;
  --border: #33334D;
  --text: #E2E8F0;
  --text-secondary: #94A3B8;
  --cyan: #22D3EE;
  --purple: #8B5CF6;
  --orange: #F59E0B;
  --green: #34C759;
  --red: #FF3B30;
  --blue: #3B82F6;
  --card-radius: 16px;
  --card-border: 1px solid #33334D;
  --card-shadow: 0 12px 32px rgba(0,0,0,0.3);
  --glass-blur: blur(12px);
  --glass-bg: rgba(15, 15, 26, 0.85);
  --gradient-text: linear-gradient(135deg, #22D3EE, #8B5CF6);
  --terminal-bg: #0A0A14;
  --tech-border-width: 3px;
  --font-main: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-mono: "SF Mono", Monaco, "Cascadia Code", monospace;
}

.chart-container {
  background: var(--bg);
  color: var(--text);
  font-family: var(--font-main);
  padding: 24px;
  border-radius: var(--card-radius);
}

.chart-title {
  font-size: 24px;
  font-weight: 700;
  background: var(--gradient-text);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  margin-bottom: 20px;
}

.chart-card {
  background: var(--card);
  border: var(--card-border);
  border-radius: var(--card-radius);
  padding: 16px;
  box-shadow: var(--card-shadow);
  transition: transform 0.2s ease, box-shadow 0.2s ease;
}

.chart-card:hover {
  transform: translateY(-4px);
  box-shadow: 0 16px 40px rgba(0,0,0,0.4);
}

.tech-item {
  border-left: var(--tech-border-width) solid var(--cyan);
  padding-left: 12px;
  margin: 8px 0;
}

.tech-item.purple { border-left-color: var(--purple); }
.tech-item.orange { border-left-color: var(--orange); }
.tech-item.green { border-left-color: var(--green); }
.tech-item.red { border-left-color: var(--red); }
.tech-item.blue { border-left-color: var(--blue); }

.stat-num {
  font-size: 36px;
  font-weight: 700;
  color: var(--cyan);
}

.stat-label {
  font-size: 13px;
  color: var(--text-secondary);
}

.terminal {
  background: var(--terminal-bg);
  font-family: var(--font-mono);
  padding: 12px;
  border-radius: 8px;
  font-size: 13px;
  color: var(--text-secondary);
}
"""

_BASE_TEMPLATE = """
<div class="chart-container">
  {% if title %}<div class="chart-title">{{ title }}</div>{% endif %}
  {% block chart_content %}{% endblock %}
</div>
"""
```

#### 6.4.2 思维导图模板（完整）

```python
_MINDMAP_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.mindmap { display: flex; flex-direction: column; align-items: center; gap: 16px; }
.mindmap-root {
  background: var(--gradient-text);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  font-size: 20px;
  font-weight: 700;
  padding: 12px 24px;
  text-align: center;
}
.mindmap-level {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 12px;
  position: relative;
}
.mindmap-level::before {
  content: '';
  position: absolute;
  top: -8px;
  left: 50%;
  width: 2px;
  height: 8px;
  background: linear-gradient(to bottom, var(--cyan), var(--purple));
}
.mindmap-node {
  background: var(--card);
  border: var(--card-border);
  border-radius: var(--card-radius);
  padding: 10px 16px;
  font-size: 14px;
  position: relative;
}
.mindmap-node.level-0 { border-left: 3px solid var(--cyan); }
.mindmap-node.level-1 { border-left: 3px solid var(--purple); }
.mindmap-node.level-2 { border-left: 3px solid var(--orange); }
.mindmap-node.level-3 { border-left: 3px solid var(--green); }
.mindmap-connector {
  width: 100%;
  height: 2px;
  background: linear-gradient(to right, var(--cyan), var(--purple));
  margin: 4px 0;
}
</style>
<div class="mindmap">
  {% set root = data.nodes | selectattr('level', 'equalto', 0) | first %}
  {% if root %}
  <div class="mindmap-root">{{ root.label }}</div>
  {% endif %}
  {% for level in range(1, 5) %}
    {% set level_nodes = data.nodes | selectattr('level', 'equalto', level) | list %}
    {% if level_nodes %}
    <div class="mindmap-connector"></div>
    <div class="mindmap-level">
      {% for node in level_nodes %}
      <div class="mindmap-node level-{{ level }} chart-node" data-node-id="{{ node.id }}">
        {{ node.label }}
      </div>
      {% endfor %}
    </div>
    {% endif %}
  {% endfor %}
</div>
{% endblock %}
"""
```

#### 6.4.3 流程图模板（完整）

```python
_FLOWCHART_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.flowchart { display: flex; flex-direction: column; gap: 0; position: relative; padding-left: 32px; }
.flowchart::before {
  content: '';
  position: absolute;
  left: 11px;
  top: 0;
  bottom: 0;
  width: 3px;
  background: linear-gradient(to bottom, var(--cyan), var(--purple));
  border-radius: 2px;
}
.flow-step {
  display: flex;
  align-items: center;
  gap: 16px;
  margin: 8px 0;
  position: relative;
}
.flow-dot {
  width: 24px;
  height: 24px;
  border-radius: 50%;
  background: var(--bg);
  border: 2px solid var(--cyan);
  flex-shrink: 0;
  position: absolute;
  left: -26px;
  top: 50%;
  transform: translateY(-50%);
}
.flow-card {
  background: var(--card);
  border: var(--card-border);
  border-radius: var(--card-radius);
  padding: 14px 18px;
  flex: 1;
  box-shadow: var(--card-shadow);
}
.flow-card.decision {
  border-color: var(--orange);
  background: rgba(245, 158, 11, 0.08);
}
.flow-label {
  font-size: 12px;
  padding: 2px 8px;
  border-radius: 4px;
  margin-left: 8px;
}
.flow-label.yes { background: rgba(52, 199, 89, 0.15); color: var(--green); }
.flow-label.no { background: rgba(255, 59, 48, 0.15); color: var(--red); }
</style>
<div class="flowchart">
  {% for node in data.nodes %}
  <div class="flow-step">
    <div class="flow-dot"></div>
    <div class="flow-card {% if node.node_type == 'decision' %}decision{% endif %} chart-node" data-node-id="{{ node.id }}">
      {{ node.label }}
      {% set outgoing = data.edges | selectattr('from', 'equalto', node.id) | list %}
      {% for edge in outgoing %}
        {% if edge.label %}
        <span class="flow-label {% if '通过' in edge.label or '是' in edge.label %}yes{% else %}no{% endif %}">{{ edge.label }}</span>
        {% endif %}
      {% endfor %}
    </div>
  </div>
  {% endfor %}
</div>
{% endblock %}
"""
```

#### 6.4.4 其他模板（占位简写）

```python
_TIMELINE_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.timeline { display: flex; gap: 16px; overflow-x: auto; padding: 16px 0; }
.timeline-axis { position: relative; display: flex; align-items: flex-start; gap: 20px; }
.timeline-axis::before {
  content: ''; position: absolute; top: 20px; left: 0; right: 0; height: 3px;
  background: linear-gradient(to right, var(--cyan), var(--purple)); border-radius: 2px;
}
.timeline-node {
  position: relative; min-width: 180px; padding-top: 36px;
}
.timeline-dot {
  width: 16px; height: 16px; border-radius: 50%; background: var(--cyan);
  position: absolute; top: 12px; left: 50%; transform: translateX(-50%);
  box-shadow: 0 0 12px var(--cyan);
}
.timeline-card {
  background: var(--card); border: var(--card-border); border-radius: var(--card-radius);
  padding: 12px; box-shadow: var(--card-shadow);
}
.timeline-date { color: var(--cyan); font-size: 13px; font-weight: 600; }
.timeline-desc { color: var(--text-secondary); font-size: 13px; margin-top: 4px; }
</style>
<div class="timeline">
  <div class="timeline-axis">
    {% for node in data.nodes %}
    <div class="timeline-node">
      <div class="timeline-dot"></div>
      <div class="timeline-card chart-node" data-node-id="{{ node.id }}">
        <div class="timeline-date">{{ node.metadata.date if node.metadata else '' }}</div>
        <div class="timeline-desc">{{ node.label }}</div>
      </div>
    </div>
    {% endfor %}
  </div>
</div>
{% endblock %}
"""

_PIE_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.pie-chart { display: flex; gap: 24px; align-items: center; flex-wrap: wrap; }
.pie-visual { width: 200px; height: 200px; border-radius: 50%;
  background: conic-gradient(
    {% set colors = ['var(--cyan)', 'var(--purple)', 'var(--orange)', 'var(--green)', 'var(--red)', 'var(--blue)'] %}
    {% for node in data.nodes %}
      {{ colors[loop.index0 % colors|length] }} {{ loop.index0 * (360 / data.nodes|length) }}deg {{ (loop.index0 + 1) * (360 / data.nodes|length) }}deg{% if not loop.last %},{% endif %}
    {% endfor %}
  );
}
.pie-legend { display: flex; flex-direction: column; gap: 8px; }
.pie-item { display: flex; align-items: center; gap: 8px; font-size: 14px; }
.pie-color { width: 12px; height: 12px; border-radius: 3px; }
.pie-value { color: var(--cyan); font-weight: 700; }
</style>
<div class="pie-chart">
  <div class="pie-visual"></div>
  <div class="pie-legend">
    {% for node in data.nodes %}
    <div class="pie-item">
      <div class="pie-color" style="background: {{ colors[loop.index0 % colors|length] }}"></div>
      <span>{{ node.label }}</span>
      <span class="pie-value">{{ node.metadata.percentage if node.metadata else '' }}</span>
    </div>
    {% endfor %}
  </div>
</div>
{% endblock %}
"""

_BAR_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.bar-chart { display: flex; align-items: flex-end; gap: 16px; height: 200px; padding: 20px;
  background: var(--card); border-radius: var(--card-radius); border: var(--card-border);
}
.bar-item { display: flex; flex-direction: column; align-items: center; gap: 8px; flex: 1; }
.bar-fill {
  width: 100%; max-width: 60px; border-radius: 6px 6px 0 0;
  background: linear-gradient(to top, var(--cyan), var(--purple));
  min-height: 4px;
}
.bar-label { font-size: 12px; color: var(--text-secondary); text-align: center; }
.bar-value { font-size: 14px; color: var(--cyan); font-weight: 700; }
</style>
<div class="bar-chart">
  {% for node in data.nodes %}
  {% set max_val = data.nodes | map(attribute='metadata.value') | map('float') | max %}
  {% set val = (node.metadata.value | float) if node.metadata else 0 %}
  {% set pct = (val / max_val * 100) if max_val > 0 else 0 %}
  <div class="bar-item">
    <div class="bar-value">{{ node.metadata.value if node.metadata else 0 }}</div>
    <div class="bar-fill" style="height: {{ pct }}%"></div>
    <div class="bar-label">{{ node.label }}</div>
  </div>
  {% endfor %}
</div>
{% endblock %}
"""

_ORGCHART_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.orgchart { display: flex; flex-direction: column; align-items: center; gap: 16px; }
.org-level {
  display: flex; justify-content: center; gap: 16px;
  padding: 12px; border-radius: 12px; width: 100%;
}
.org-level.level-0 { background: rgba(34, 211, 238, 0.08); border: 1px solid var(--cyan); }
.org-level.level-1 { background: rgba(139, 92, 246, 0.08); border: 1px solid var(--purple); }
.org-level.level-2 { background: rgba(245, 158, 11, 0.08); border: 1px solid var(--orange); }
.org-level.level-3 { background: rgba(52, 199, 89, 0.08); border: 1px solid var(--green); }
.org-node {
  background: var(--card); border: var(--card-border); border-radius: 12px;
  padding: 10px 16px; text-align: center; font-size: 14px;
}
.org-arrow { color: var(--text-secondary); font-size: 20px; }
</style>
<div class="orgchart">
  {% for level in range(4) %}
    {% set level_nodes = data.nodes | selectattr('level', 'equalto', level) | list %}
    {% if level_nodes %}
    <div class="org-level level-{{ level }}">
      {% for node in level_nodes %}
      <div class="org-node chart-node" data-node-id="{{ node.id }}">
        <div>{{ node.label }}</div>
        {% if node.metadata and node.metadata.position %}
        <div style="font-size: 12px; color: var(--text-secondary); margin-top: 4px;">{{ node.metadata.position }}</div>
        {% endif %}
      </div>
      {% endfor %}
    </div>
    {% if not loop.last %}
    <div class="org-arrow">&#8595;</div>
    {% endif %}
    {% endif %}
  {% endfor %}
</div>
{% endblock %}
"""

_KANBAN_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<style>
.kanban { display: flex; gap: 16px; }
.kanban-column { flex: 1; background: var(--card); border-radius: var(--card-radius);
  border: var(--card-border); padding: 12px;
}
.kanban-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
.kanban-title { font-size: 14px; font-weight: 600; }
.kanban-count { font-size: 24px; font-weight: 700; color: var(--cyan); }
.kanban-card {
  background: var(--bg); border-radius: 10px; padding: 10px; margin-bottom: 8px;
  border-left: 3px solid var(--purple); font-size: 13px;
}
.kanban-card.todo { border-left-color: var(--purple); }
.kanban-card.inprogress { border-left-color: var(--orange); }
.kanban-card.done { border-left-color: var(--green); }
.kanban-meta { color: var(--text-secondary); font-size: 11px; margin-top: 6px; }
</style>
<div class="kanban">
  {% set statuses = [
    ('todo', '待办', 'purple'),
    ('inprogress', '进行中', 'orange'),
    ('done', '已完成', 'green')
  ] %}
  {% for status_key, status_label, color in statuses %}
    {% set status_nodes = data.nodes | selectattr('metadata.status', 'equalto', status_key) | list %}
    <div class="kanban-column">
      <div class="kanban-header">
        <span class="kanban-title">{{ status_label }}</span>
        <span class="kanban-count">{{ status_nodes | length }}</span>
      </div>
      {% for node in status_nodes %}
      <div class="kanban-card {{ status_key }} chart-node" data-node-id="{{ node.id }}">
        <div>{{ node.label }}</div>
        {% if node.metadata %}
        <div class="kanban-meta">
          {% if node.metadata.assignee %}负责人: {{ node.metadata.assignee }}{% endif %}
          {% if node.metadata.deadline %} | 截止: {{ node.metadata.deadline }}{% endif %}
        </div>
        {% endif %}
      </div>
      {% endfor %}
    </div>
  {% endfor %}
</div>
{% endblock %}
"""
```

### 6.5 LLM 配置（OpenAI 默认 + Ollama fallback）

```python
# ChartAgent/agent/llm_client.py
import os
import json
from typing import Optional

try:
    import openai
    HAS_OPENAI = True
except ImportError:
    HAS_OPENAI = False

def call_llm(prompt: str, temperature: float = 0.3) -> str:
    """
    优先使用 OpenAI API，若未配置则 fallback 到 Ollama 本地模型。
    """
    api_key = os.environ.get("OPENAI_API_KEY", "")
    base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")

    if api_key and HAS_OPENAI:
        return _call_openai(prompt, api_key, base_url, temperature)

    return _call_ollama(prompt, temperature)

def _call_openai(prompt: str, api_key: str, base_url: str, temperature: float) -> str:
    client = openai.OpenAI(api_key=api_key, base_url=base_url)
    response = client.chat.completions.create(
        model=os.environ.get("LLM_MODEL", "gpt-4o-mini"),
        messages=[{"role": "user", "content": prompt}],
        temperature=temperature,
        max_tokens=4096,
    )
    return response.choices[0].message.content or ""

def _call_ollama(prompt: str, temperature: float) -> str:
    import urllib.request
    req = urllib.request.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps({
            "model": os.environ.get("OLLAMA_MODEL", "llama3"),
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": temperature},
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        return data.get("response", "")
```

### 6.6 Python 依赖清单

```text
# ChartAgent/requirements.txt
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
langgraph>=0.0.40
jinja2>=3.1.0
openai>=1.20.0
pydantic>=2.0.0
```

---

## 7. Skill 接口规范

### 7.1 输入协议（JSON Schema）

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ChartGenerateRequest",
  "type": "object",
  "required": ["version", "requestId", "content"],
  "properties": {
    "version": {
      "type": "string",
      "enum": ["1.0"],
      "description": "协议版本"
    },
    "requestId": {
      "type": "string",
      "format": "uuid",
      "description": "请求唯一标识"
    },
    "content": {
      "type": "object",
      "required": ["theme", "markdownContent"],
      "properties": {
        "theme": { "type": "string", "description": "会议主题" },
        "participants": { "type": "array", "items": { "type": "string" } },
        "keyDecisions": { "type": "array", "items": { "type": "string" } },
        "actionItems": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "content": { "type": "string" },
              "assignee": { "type": ["string", "null"] },
              "deadline": { "type": ["string", "null"] }
            }
          }
        },
        "timeline": { "type": "array", "items": { "type": "string" } },
        "markdownContent": { "type": "string", "minLength": 100, "description": "完整 Markdown 纪要" },
        "rawTranscription": { "type": ["string", "null"] }
      }
    },
    "preferences": {
      "type": "object",
      "properties": {
        "primaryChartType": { "type": "string", "default": "auto" },
        "styleTheme": { "type": "string", "default": "darkCyberpunk" },
        "outputFormats": { "type": "array", "items": { "type": "string" }, "default": ["html"] }
      }
    }
  }
}
```

### 7.2 输出协议（JSON Schema）

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ChartGenerateResponse",
  "type": "object",
  "required": ["version", "requestId", "status", "charts", "errors"],
  "properties": {
    "version": { "type": "string", "enum": ["1.0"] },
    "requestId": { "type": "string" },
    "status": { "type": "string", "enum": ["success", "failed", "degraded"] },
    "charts": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["chartType", "chartTypeDisplayName", "confidence", "htmlFragment", "renderConfig", "structuredData", "metadata"],
        "properties": {
          "chartType": { "type": "string", "enum": ["mindmap", "flowchart", "timeline", "pie", "bar", "orgchart", "kanban"] },
          "chartTypeDisplayName": { "type": "string" },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
          "htmlFragment": { "type": "string", "description": "暗黑极客风 HTML 片段" },
          "renderConfig": {
            "type": "object",
            "properties": {
              "styleTokens": { "type": "object", "additionalProperties": { "type": "string" } },
              "cssFramework": { "type": "string" }
            }
          },
          "structuredData": {
            "type": "object",
            "properties": {
              "nodes": {
                "type": "array",
                "items": {
                  "type": "object",
                  "properties": {
                    "id": { "type": "string" },
                    "label": { "type": "string" },
                    "level": { "type": "integer" },
                    "nodeType": { "type": "string" },
                    "color": { "type": ["string", "null"] },
                    "metadata": { "type": ["object", "null"] }
                  }
                }
              },
              "edges": {
                "type": "array",
                "items": {
                  "type": "object",
                  "properties": {
                    "from": { "type": "string" },
                    "to": { "type": "string" },
                    "label": { "type": ["string", "null"] }
                  }
                }
              }
            }
          },
          "metadata": {
            "type": "object",
            "properties": {
              "nodeCount": { "type": "integer" },
              "maxDepth": { "type": "integer" },
              "generationTimeMs": { "type": "integer" }
            }
          }
        }
      }
    },
    "errors": { "type": "array", "items": { "type": "string" } }
  }
}
```

### 7.3 错误码定义

| 错误码 | Swift 枚举 | HTTP Status | 说明 | 用户提示 |
|--------|-----------|-------------|------|----------|
| `SERVICE_UNAVAILABLE` | `.serviceUnavailable` | 503 | Python 服务未响应 | "图表服务不可用，正在启动..." |
| `SERVICE_NOT_RUNNING` | `.serviceNotRunning` | — | 心跳检测失败 | "图表引擎未启动，请检查安装" |
| `INVALID_REQUEST` | `.invalidRequest` | 400 | 请求参数校验失败 | "请求参数无效" |
| `INVALID_RESPONSE` | `.invalidResponse` | 502 | 响应格式异常 | "响应格式错误，请重试" |
| `GENERATION_FAILED` | `.generationFailed(msg)` | 500 | Agent 执行失败 | 显示具体错误信息 |
| `VALIDATION_FAILED` | `.validationFailed(msg)` | 500 | 校验失败（3次重试后） | "图表校验失败，请重试" |
| `NETWORK_ERROR` | `.networkError(err)` | — | URLSession 网络错误 | "网络错误，请检查连接" |
| `TIMEOUT` | `.timeout` | 504 | 超过 60 秒 | "图表生成超时，请稍后重试" |
| `CONTENT_TOO_SHORT` | `.contentTooShort` | 400 | 文本 < 100 字 | "内容过短，无法生成有意义的图表" |
| `DECODING_FAILED` | `.decodingFailed` | 500 | JSON 解析失败 | "数据解析失败，请重试" |

### 7.4 版本兼容性策略

- **协议版本**：当前 `version: "1.0"`，通过 `version` 字段标识
- **向前兼容**：Swift 端解析响应时，忽略未知字段（`JSONDecoder` 默认行为）
- **向后兼容**：Python 端接收请求时，缺失字段使用默认值
- **升级路径**：
  1. v1.1 新增字段时，Swift 和 Python 同时支持新旧格式
  2. v2.0 破坏性变更时，通过 `version` 字段路由到不同处理逻辑
  3. 废弃字段保留至少 2 个 minor 版本

---

## 8. Swift-Python 集成方案

### 8.1 为什么选 HTTP API（而非子进程或 PythonKit）

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| **HTTP API** | 解耦清晰，LangGraph 生态原生支持 HTTP；可独立调试 Python 服务；心跳/重启机制成熟 | 需管理端口占用 | **选中** |
| **子进程 (Process)** | 无需端口管理；启动即通信 | Swift 与 Python 间无标准 IPC 协议；需自定义 stdin/stdout 协议；LangGraph 异常难以捕获 | 放弃 |
| **PythonKit** | 直接调用 Python 函数，无序列化开销 | 需要内嵌 Python 解释器；macOS 沙盒限制；与 LangGraph 的 asyncio 事件循环冲突；包体积剧增 | 放弃 |

### 8.2 服务生命周期管理

```swift
// AIRecording/Services/ChartServiceManager.swift
import Foundation

class ChartServiceManager: ObservableObject {
    static let shared = ChartServiceManager()

    @Published private(set) var isRunning = false
    @Published private(set) var lastHeartbeat: Date?

    private let servicePort = 8765
    private let serviceHost = "127.0.0.1"
    private var heartbeatTimer: Timer?
    private var process: Process?

    private init() {
        startHeartbeatMonitoring()
    }

    // MARK: - Service Control

    func ensureServiceRunning() async -> Bool {
        if await checkHealth() {
            isRunning = true
            return true
        }

        // 尝试启动
        do {
            try startService()
            // 等待服务就绪（最多 10 秒）
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await checkHealth() {
                    isRunning = true
                    return true
                }
            }
        } catch {
            print("Failed to start chart service: \(error)")
        }

        isRunning = false
        return false
    }

    func stopService() {
        process?.terminate()
        process = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        isRunning = false
    }

    // MARK: - Private

    private func startService() throws {
        let pythonPath = findPythonPath()
        let scriptPath = findScriptPath()

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw ChartSkillError.serviceUnavailable
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]
        process.environment = [
            "PORT": "\(servicePort)",
            "PYTHONUNBUFFERED": "1",
        ]

        // 重定向输出到日志
        let logPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/AIRecording/chart-agent.log")
        try? FileManager.default.createDirectory(at: logPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let logHandle = try? FileHandle(forWritingTo: logPath) {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        try process.run()
        self.process = process
    }

    private func checkHealth() async -> Bool {
        guard let url = URL(string: "http://\(serviceHost):\(servicePort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private func startHeartbeatMonitoring() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let healthy = await self.checkHealth()
                await MainActor.run {
                    self.isRunning = healthy
                    if healthy {
                        self.lastHeartbeat = Date()
                    }
                }
                if !healthy && self.process != nil {
                    // 自动重启
                    _ = await self.ensureServiceRunning()
                }
            }
        }
    }

    // MARK: - Path Resolution

    private func findPythonPath() -> String {
        // 1. 检查 bundled Python
        let bundled = Bundle.main.path(forResource: "python3", ofType: nil)
        if let bundled = bundled, FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        // 2. 检查系统 Python
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "python3" // fallback to PATH
    }

    private func findScriptPath() -> String {
        // 1. 检查 bundled ChartAgent
        if let bundled = Bundle.main.path(forResource: "ChartAgent/main", ofType: "py") {
            return bundled
        }
        // 2. 检查开发路径（相对可执行文件）
        let execPath = Bundle.main.bundlePath
        let devPath = (execPath as NSString).appendingPathComponent("../ChartAgent/main.py")
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return ""
    }
}
```

### 8.3 心跳检测与自动重启

- **心跳间隔**：10 秒
- **超时时间**：3 秒
- **自动重启条件**：心跳连续失败 1 次即触发重启（本地服务，快速恢复优先）
- **重启策略**：
  1. 终止旧进程（`process.terminate()`）
  2. 重新执行 `startService()`
  3. 最多等待 10 秒就绪
  4. 若重启失败，标记 `isRunning = false`，等待下次请求时再次尝试

### 8.4 端口管理

| 策略 | 端口 | 适用场景 | 决策 |
|------|------|----------|------|
| 固定端口 | 8765 | 开发阶段，简单直接 | **Phase 1-3 采用** |
| 随机端口 | 动态分配 | 避免端口冲突，生产环境 | Phase 4 评估 |
| Unix Socket | `/tmp/chart-agent.sock` | 无端口占用问题，更安全 | Phase 4 评估，需 FastAPI + Uvicorn 支持 |

**当前决策：固定端口 8765**。原因：
1. 本地回环仅本机可访问，无安全风险
2. 简化配置，Swift 和 Python 无需动态协商端口
3. 若端口被占用，启动时 Uvicorn 会报错，Swift 端检测到后提示用户

---

## 9. 数据流时序图

```
用户点击"生成图表"
    │
    ▼
RecordingDetailView
    │
    ▼ 调用
RecordingDetailViewModel.generateChart()
    │
    ▼ 组装 ChartGenerateRequest（从 Recording + Summary）
ChartPanelViewModel
    │
    ▼ 调用 generate(request:)
HTTPChartSkill
    │
    ▼ POST /chart/generate (localhost:8765)
URLSession
    │
    ▼ HTTP Request JSON
FastAPI (Python)
    │
    ▼ 校验 + 组装 ChartAgentState
chart_generate_endpoint()
    │
    ▼ 调用 chart_agent.invoke(state)
LangGraph StateGraph
    │
    ├──▶ text_analysis ──▶ chart_type_select ──▶ data_extract ──▶ chart_generate ──▶ validate
    │                                                          │
    │                                         (失败, retry<2) ──┘
    │                                                          │
    │                                         (通过 or 重试耗尽) ──▶ END
    │
    ▼ 返回 result_state
chart_generate_endpoint()
    │
    ▼ 组装 ChartGenerateResponse
HTTP Response JSON
    │
    ▼
HTTPChartSkill (Swift)
    │
    ▼ 解码为 ChartGenerateResponse
ChartPanelViewModel
    │
    ▼ 更新 @Published chartResult
ChartPanelView
    │
    ▼ 传递 htmlFragment
ChartWebView
    │
    ▼ loadHTMLString(html, baseURL: nil)
WKWebView (WebKit)
    │
    ▼ 渲染引擎解析 HTML + CSS
    │
    ▼ 用户可见暗黑极客风图表
```

**关键时序约束：**
- 端到端时间目标：< 30 秒（PRD CHT-PERF-003）
- HTTP 请求超时：60 秒（覆盖 LLM 推理时间）
- 服务启动等待：最多 10 秒（20 次 x 500ms 轮询）

---

## 10. 技术风险与缓解

| 风险 | 可能性 | 影响 | 缓解措施 | 负责人 |
|------|--------|------|----------|--------|
| **Python 运行时包体积** | 中 | 中 | 检测系统 Python（`which python3`），引导用户 `pip install -r requirements.txt`；不内嵌 Python 解释器 | claude-pe-lead |
| **离线可用性** | 中 | 高 | LLM 配置支持 Ollama fallback（本地 `llama3`/`qwen`）；无网络时自动切换 | claude-cp-arch |
| **HTML 渲染性能** | 低 | 中 | 节点数 > 50 时自动简化视图（隐藏低层级节点）；CSS 动画优先于 JS 动画 | claude-cp-arch |
| **Python 服务稳定性** | 中 | 高 | 10 秒心跳检测 + 自动重启；崩溃后保留输入数据，用户可手动重试；日志写入 `~/Library/Logs/AIRecording/` | claude-cp-arch |
| **隐私合规** | 低 | 高 | 转录文本脱敏预处理（正则过滤手机号、邮箱、身份证号）；用户设置中提供"完全本地模式"（禁用云端 LLM） | claude-cp-arch |
| **LangGraph 版本兼容性** | 中 | 中 | `requirements.txt` 锁定版本（`langgraph>=0.0.40,<0.1.0`）；关键接口封装适配层，隔离版本变更影响 | claude-cp-arch |
| **macOS 13 API 限制** | 低 | 高 | 所有 Swift 代码仅使用 macOS 13 可用 API；CI 在 macOS 13 虚拟机验证 | claude-qa-lead |
| **WKWebView 内存泄漏** | 低 | 中 | `ChartWebView` 使用 `NSViewRepresentable` 生命周期管理；`updateNSView` 复用而非重建 WKWebView | claude-cp-arch |

---

## 11. 落地路径

### Phase 1: 基础设施（预估 3 天）

| 任务 | 文件 | 说明 |
|------|------|------|
| 1.1 创建 ChartAgent Python 目录结构 | `ChartAgent/` | main.py, agent/, templates/, requirements.txt |
| 1.2 实现 FastAPI 骨架 + /health | `ChartAgent/main.py` | 可独立运行，验证端口 8765 |
| 1.3 实现 Swift ChartSkill Protocol | `AIRecording/Services/ChartSkill.swift` | Protocol + 数据模型 + 错误定义 |
| 1.4 实现 Color+Hex 扩展 | `AIRecording/Utilities/Color+Hex.swift` | 供 ChartPanelView 使用 |
| 1.5 实现 ChartWebView | `AIRecording/Views/ChartWebView.swift` | NSViewRepresentable 包装 WKWebView |
| 1.6 验证 Python 服务可启动 | — | `cd ChartAgent && pip install -r requirements.txt && python main.py` |

### Phase 2: Python 服务核心（预估 5 天）

| 任务 | 文件 | 说明 |
|------|------|------|
| 2.1 实现 LangGraph StateGraph | `ChartAgent/agent/graph.py` | 5 节点 + 条件边 |
| 2.2 实现 text_analysis + chart_type_select | `ChartAgent/agent/nodes.py` | 规则引擎 + 决策矩阵 |
| 2.3 实现 data_extract（LLM 提取） | `ChartAgent/agent/nodes.py` | OpenAI/Ollama 双后端 |
| 2.4 实现 chart_generate（Jinja2） | `ChartAgent/agent/templates.py` | 基模板 + mindmap + flowchart |
| 2.5 实现 validate + 重试机制 | `ChartAgent/agent/nodes.py` | HTML 校验 + 语义校验 |
| 2.6 实现 timeline + kanban 模板 | `ChartAgent/agent/templates.py` | P1 图表类型 |
| 2.7 集成测试（curl / Postman） | — | 验证端到端生成 |

### Phase 3: Swift 集成（预估 4 天）

| 任务 | 文件 | 说明 |
|------|------|------|
| 3.1 实现 HTTPChartSkill | `AIRecording/Services/HTTPChartSkill.swift` | URLSession 调用 FastAPI |
| 3.2 实现 ChartServiceManager | `AIRecording/Services/ChartServiceManager.swift` | 服务生命周期 + 心跳 |
| 3.3 实现 ChartPanelView + ViewModel | `AIRecording/Views/ChartPanelView.swift` | SwiftUI 图表面板 |
| 3.4 扩展 RecordingDetailView | `AIRecording/Views/RecordingDetailView.swift` | 在 summaryView 下方插入 ChartPanelView |
| 3.5 扩展 RecordingDetailViewModel | `AIRecording/ViewModels/RecordingDetailViewModel.swift` | 新增 generateChart() 方法 |
| 3.6 扩展 Core Data 模型 | `AIRecording/Services/PersistenceController.swift` | 新增 Chart, ChartNode, ChartEdge, ChartJob |

### Phase 4: 打磨与导出（预估 3 天）

| 任务 | 文件 | 说明 |
|------|------|------|
| 4.1 实现 pie + bar + orgchart 模板 | `ChartAgent/agent/templates.py` | P2 图表类型补齐 |
| 4.2 实现导出 HTML 功能 | `ChartPanelViewModel.exportHTML()` | NSSavePanel + 自包含 HTML |
| 4.3 实现导出 PNG 功能（WKWebView 截图） | `ChartWebView` 扩展 | `takeSnapshot` API |
| 4.4 错误处理完善 | 多文件 | 重试提示、服务未启动引导 |
| 4.5 性能优化 | 多文件 | 节点数限制、CSS 优化 |
| 4.6 集成测试 | — | 6 大场景端到端验证 |

**总预估工时：约 15 个工作日（3 周）**

---

## 12. 文件清单

### 新增文件

| 路径 | 说明 | 章节 |
|------|------|------|
| `AIRecording/Services/ChartSkill.swift` | ChartSkill Protocol + 数据模型 + 错误定义 | 5.1 |
| `AIRecording/Services/HTTPChartSkill.swift` | URLSession HTTP 客户端实现 | 5.2 |
| `AIRecording/Services/ChartServiceManager.swift` | Python 服务生命周期管理 | 8.2 |
| `AIRecording/Views/ChartWebView.swift` | NSViewRepresentable 包装 WKWebView | 5.3 |
| `AIRecording/Views/ChartPanelView.swift` | SwiftUI 图表面板 + ViewModel | 5.4 |
| `AIRecording/Utilities/Color+Hex.swift` | Color hex 字符串初始化扩展 | 5.5 |
| `ChartAgent/main.py` | FastAPI 服务入口 | 6.2 |
| `ChartAgent/agent/__init__.py` | Python 包初始化 | 6.3 |
| `ChartAgent/agent/graph.py` | LangGraph StateGraph 构建 | 6.3 |
| `ChartAgent/agent/nodes.py` | 5 个节点函数实现 | 6.3 |
| `ChartAgent/agent/llm_client.py` | OpenAI + Ollama LLM 封装 | 6.5 |
| `ChartAgent/agent/templates.py` | Jinja2 模板 + 暗黑极客风 CSS | 6.4 |
| `ChartAgent/templates/base.html.j2` | Jinja2 基模板（可选外置） | 6.4 |
| `ChartAgent/templates/mindmap.html.j2` | 思维导图模板（可选外置） | 6.4 |
| `ChartAgent/templates/flowchart.html.j2` | 流程图模板（可选外置） | 6.4 |
| `ChartAgent/templates/timeline.html.j2` | 时间线模板（可选外置） | 6.4 |
| `ChartAgent/templates/pie.html.j2` | 饼图模板（可选外置） | 6.4 |
| `ChartAgent/templates/bar.html.j2` | 柱状图模板（可选外置） | 6.4 |
| `ChartAgent/templates/orgchart.html.j2` | 组织架构图模板（可选外置） | 6.4 |
| `ChartAgent/templates/kanban.html.j2` | 看板模板（可选外置） | 6.4 |
| `ChartAgent/requirements.txt` | Python 依赖清单 | 6.6 |
| `ChartAgent/README.md` | Python 服务安装与启动说明 | — |

### 修改文件

| 路径 | 修改内容 | 章节 |
|------|----------|------|
| `AIRecording/Views/RecordingDetailView.swift` | 在 summaryView 下方插入 ChartPanelView | 5.4 |
| `AIRecording/ViewModels/RecordingDetailViewModel.swift` | 新增 `isGeneratingChart`, `chartResult`, `generateChart()` | 5.4 |
| `AIRecording/Services/PersistenceController.swift` | 新增 Chart, ChartNode, ChartEdge, ChartJob 实体定义 | PRD 5.2-5.5 |
| `Package.swift` | 无需修改（零 SPM 依赖原则保持） | — |

---

## 附录 A：暗黑极客风 CSS 变量速查

```css
:root {
  --bg: #0F0F1A;
  --card: #1E1E2E;
  --border: #33334D;
  --text: #E2E8F0;
  --text-secondary: #94A3B8;
  --cyan: #22D3EE;
  --purple: #8B5CF6;
  --orange: #F59E0B;
  --green: #34C759;
  --red: #FF3B30;
  --blue: #3B82F6;
  --card-radius: 16px;
  --card-border: 1px solid #33334D;
  --card-shadow: 0 12px 32px rgba(0,0,0,0.3);
  --glass-blur: blur(12px);
  --glass-bg: rgba(15, 15, 26, 0.85);
  --gradient-text: linear-gradient(135deg, #22D3EE, #8B5CF6);
  --terminal-bg: #0A0A14;
  --tech-border-width: 3px;
}
```

## 附录 B：启动命令速查

```bash
# 1. 安装 Python 依赖
cd ChartAgent
pip install -r requirements.txt

# 2. 启动服务（开发模式）
python main.py
# 或
uvicorn main:app --host 127.0.0.1 --port 8765 --reload

# 3. 测试健康检查
curl http://127.0.0.1:8765/health

# 4. 测试生成接口
curl -X POST http://127.0.0.1:8765/chart/generate \
  -H "Content-Type: application/json" \
  -d '{
    "version": "1.0",
    "requestId": "test-001",
    "content": {
      "theme": "产品需求评审",
      "participants": ["张三", "李四"],
      "keyDecisions": ["采用方案A"],
      "actionItems": [{"content": "完成设计稿", "assignee": "张三", "deadline": "2024-06-01"}],
      "timeline": ["2024-05-20: 启动", "2024-06-01: 设计完成"],
      "markdownContent": "## 产品需求评审\n\n### 功能模块\n- 用户管理\n  - 注册登录\n  - 权限控制\n- 数据统计\n  - 日活统计\n  - 留存分析\n\n### 决策\n如果用户量 > 10万，则采用微服务架构。\n\n### 待办\n- [ ] 完成设计稿（张三，6月1日）\n- [ ] 技术评审（李四，6月5日）\n"
    },
    "preferences": {
      "primaryChartType": "auto",
      "styleTheme": "darkCyberpunk",
      "outputFormats": ["html"]
    }
  }'
```

## 附录 C：与 PRD v1.1 的映射表

| PRD 章节 | TechSpec 章节 | 说明 |
|----------|--------------|------|
| 4.1 Agent 状态图 | 4.1 StateGraph 定义 | 完整实现 |
| 4.1.3 决策矩阵 | 4.2 条件路由决策表 | 规则引擎实现 |
| 4.1.4 输入/输出协议 | 7.1 / 7.2 JSON Schema | 字段一致 |
| 4.2.1 图表类型 | 5.1 ChartType 枚举 | 6 大类型 + unknown |
| 4.2.2 模板系统 | 6.4 Jinja2 模板 | 基模板 + 6 种类型 |
| 4.3.3 暗黑极客风 CSS | 6.4.1 DARK_CSS | 变量值与 PRD 一致 |
| 4.5.2 Skill 接口 | 5.1 ChartSkill Protocol | 与 PRD 一致 |
| 5.2-5.5 Core Data 模型 | 12 文件清单 | 实体扩展 |
| 6.1 性能需求 | 9 时序图 + 10 风险 | 时序约束明确 |
| 8.1 里程碑 | 11 落地路径 | 4 Phase 映射 |
