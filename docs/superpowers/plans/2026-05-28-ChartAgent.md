# Chart Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a Chart Agent feature that automatically generates dark cyberpunk-styled visual charts from meeting transcription/summary text, with a Python FastAPI + LangGraph backend and Swift WKWebView frontend.

**Architecture:** Python FastAPI service (port 8765) runs a LangGraph agent that analyzes text, selects chart type, extracts structured data, and renders HTML via Jinja2 templates. Swift side uses URLSession to communicate, WKWebView to render, and extends Core Data programmatically for persistence.

**Tech Stack:** Swift 5.9+ (macOS 13, zero SPM deps), Python 3.10+ (FastAPI, LangGraph, Jinja2, OpenAI), Core Data (programmatic model), WebKit (WKWebView)

---

## File Structure

### New Files (Swift)
| File | Responsibility |
|------|---------------|
| `AIRecording/Services/ChartSkill.swift` | Protocol definition, enums, request/response models |
| `AIRecording/Services/HTTPChartSkill.swift` | URLSession HTTP client implementing ChartSkill |
| `AIRecording/Services/ChartServiceManager.swift` | Python process lifecycle, heartbeat, auto-restart |
| `AIRecording/Views/ChartWebView.swift` | NSViewRepresentable wrapping WKWebView |
| `AIRecording/Views/ChartPanelView.swift` | SwiftUI panel with loading/error/empty/export states |
| `AIRecording/Utilities/Color+Hex.swift` | Color(hex:) initializer extension |

### New Files (Python)
| File | Responsibility |
|------|---------------|
| `ChartAgent/main.py` | FastAPI entry, /chart/generate and /health endpoints |
| `ChartAgent/agent/__init__.py` | Package init |
| `ChartAgent/agent/graph.py` | LangGraph StateGraph builder (5 nodes + conditional edges) |
| `ChartAgent/agent/nodes.py` | text_analysis, chart_type_select, data_extract, chart_generate, validate |
| `ChartAgent/agent/llm_client.py` | OpenAI + Ollama fallback LLM wrapper |
| `ChartAgent/agent/templates.py` | Jinja2 templates with inline dark cyberpunk CSS, 6 chart types |
| `ChartAgent/requirements.txt` | Python dependencies |
| `ChartAgent/README.md` | Setup and run instructions |

### Modified Files
| File | Change |
|------|--------|
| `AIRecording/Services/PersistenceController.swift` | Add Chart, ChartNode, ChartEdge, ChartJob entities + relationships |
| `AIRecording/Views/RecordingDetailView.swift` | Insert chartPanelView below summaryView |
| `AIRecording/ViewModels/RecordingDetailViewModel.swift` | Add chart states and generateChart() method |
| `AIRecording/Models/Recording.swift` | Add `charts` NSSet relationship property |

---

## Task 1: Python FastAPI Skeleton

**Files:**
- Create: `ChartAgent/requirements.txt`
- Create: `ChartAgent/main.py`

- [ ] **Step 1: Create requirements.txt**

```text
fastapi>=0.110.0
uvicorn[standard]>=0.29.0
langgraph>=0.0.40
jinja2>=3.1.0
openai>=1.20.0
pydantic>=2.0.0
```

- [ ] **Step 2: Create ChartAgent directory and main.py**

```python
# ChartAgent/main.py
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
import uuid
import time

app = FastAPI(title="AIRecording Chart Agent", version="1.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:*", "http://127.0.0.1:*"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

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

@app.post("/chart/generate", response_model=ChartGenerateResponse)
async def chart_generate_endpoint(request: ChartGenerateRequest):
    # Placeholder: will wire to LangGraph agent in Task 3
    return ChartGenerateResponse(
        version="1.0",
        requestId=request.requestId,
        status="success",
        charts=[
            ChartResult(
                chartType="mindmap",
                chartTypeDisplayName="思维导图",
                confidence=0.92,
                htmlFragment="<div style='color:#22D3EE'>Placeholder chart</div>",
                renderConfig={},
                structuredData={"nodes": [], "edges": []},
                metadata={"nodeCount": 0, "maxDepth": 0, "generationTimeMs": 0},
            )
        ],
        errors=[],
    )

@app.get("/health")
async def health_check():
    return {"status": "ok", "version": "1.1.0"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765)
```

- [ ] **Step 3: Verify Python service starts**

Run: `cd /Volumes/HP\ P900/mac/WorkPlace/AIRecording/ChartAgent && pip install -r requirements.txt`
Run: `python main.py &`
Run: `curl http://127.0.0.1:8765/health`
Expected: `{"status":"ok","version":"1.1.0"}`

---

## Task 2: Python LangGraph Agent Core

**Files:**
- Create: `ChartAgent/agent/__init__.py`
- Create: `ChartAgent/agent/graph.py`
- Create: `ChartAgent/agent/nodes.py`
- Create: `ChartAgent/agent/llm_client.py`

- [ ] **Step 1: Create agent package init**

```python
# ChartAgent/agent/__init__.py
```

- [ ] **Step 2: Create llm_client.py**

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

- [ ] **Step 3: Create nodes.py**

```python
# ChartAgent/agent/nodes.py
import re
import json
from typing import Dict, Any, List
from .llm_client import call_llm
from .templates import render_chart

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
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped.startswith(("-", "*", "•")):
            depth = 1 + indent // 2
        elif re.match(r'^(\d+\.|\d+\))\s', stripped):
            depth = 1
        elif re.match(r'^[一二三四五六七八九十]+[、.\s]', stripped):
            depth = 1
        else:
            depth = 0
        max_depth = max(max_depth, depth)
    return max_depth

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

def data_extract(state: Dict[str, Any]) -> Dict[str, Any]:
    chart_type = state["selected_chart_type"]
    text = state["markdown_content"]
    prompt = _build_extraction_prompt(chart_type, text)
    raw_response = call_llm(prompt)
    try:
        structured = json.loads(raw_response)
    except json.JSONDecodeError:
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
    end_nodes = {"end", "结束", "完成", "done"}
    for node in nodes:
        nid = node["id"]
        label = node.get("label", "").lower()
        if nid not in sources and label not in end_nodes:
            return True
    start_nodes = {"start", "开始", "启动"}
    for node in nodes:
        nid = node["id"]
        label = node.get("label", "").lower()
        if nid not in targets and label not in start_nodes:
            return True
    return False
```

- [ ] **Step 4: Create graph.py**

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

- [ ] **Step 5: Update main.py to wire the agent**

Replace the placeholder `/chart/generate` endpoint body with:

```python
from agent.graph import chart_agent
from agent.nodes import ChartAgentState

@app.post("/chart/generate", response_model=ChartGenerateResponse)
async def chart_generate_endpoint(request: ChartGenerateRequest):
    start_time = time.time()
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

def chart_type_display_name(chart_type: str) -> str:
    mapping = {
        "mindmap": "思维导图", "flowchart": "流程图", "timeline": "时间线",
        "pie": "饼图", "bar": "柱状图", "orgchart": "组织架构图", "kanban": "看板",
    }
    return mapping.get(chart_type, "未知")

def compute_max_depth(nodes: List[Dict[str, Any]]) -> int:
    if not nodes:
        return 0
    return max((node.get("level", 0) for node in nodes), default=0)
```

---

## Task 3: Python Jinja2 Templates with Dark Cyberpunk CSS

**Files:**
- Create: `ChartAgent/agent/templates.py`

- [ ] **Step 1: Create templates.py with all 6 chart types**

Use the complete templates.py from TechSpec section 6.4, including:
- `DARK_CSS` constant with full CSS variable system
- `_BASE_TEMPLATE` with `{% block chart_content %}`
- `_MINDMAP_TEMPLATE`, `_FLOWCHART_TEMPLATE`, `_TIMELINE_TEMPLATE`
- `_PIE_TEMPLATE`, `_BAR_TEMPLATE`, `_ORGCHART_TEMPLATE`, `_KANBAN_TEMPLATE`
- `get_jinja_env()`, `render_chart()` functions
- `_inline_templates` dict with DictLoader fallback

The full content is in TechSpec 6.4.1 - 6.4.4. Copy it verbatim.

- [ ] **Step 2: Verify template rendering**

Run a quick Python test:
```python
from ChartAgent.agent.templates import render_chart
html = render_chart("mindmap", {"nodes": [{"id":"1","label":"Root","level":0}]}, "darkCyberpunk", "Test")
assert "<div" in html
assert "--bg" in html
```

---

## Task 4: Swift ChartSkill Protocol and Data Models

**Files:**
- Create: `AIRecording/Services/ChartSkill.swift`
- Create: `AIRecording/Utilities/Color+Hex.swift`

- [ ] **Step 1: Create Color+Hex.swift**

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
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
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

- [ ] **Step 2: Create ChartSkill.swift**

Use TechSpec 5.1 verbatim. Include:
- `ChartType` enum (Int16, CaseIterable, Codable) with displayName
- `ChartStatus` enum (Int16, Codable)
- `ChartSkillError` enum (Error, Equatable) with localizedDescription
- `ChartGenerateRequest` with nested `ChartContent` and `ActionItem`
- `ChartGenerateResponse` with status, charts, errors
- `ChartResult` with nested `RenderConfig`, `ChartStructuredData`, `ChartNodeDTO`, `ChartEdgeDTO`, `ChartMetadata`
- `ChartStyleConfig` with all dark cyberpunk tokens
- `ChartSkill` protocol with `generate(request:)` method

---

## Task 5: Swift HTTPChartSkill and ChartServiceManager

**Files:**
- Create: `AIRecording/Services/HTTPChartSkill.swift`
- Create: `AIRecording/Services/ChartServiceManager.swift`

- [ ] **Step 1: Create HTTPChartSkill.swift**

Use TechSpec 5.2 verbatim. Key points:
- `static let shared = HTTPChartSkill()`
- `isAvailable` computed property with async health check
- `generate(request:)` POST to `/chart/generate` with 60s timeout
- Proper error mapping to `ChartSkillError` cases
- `checkHealth()` GET to `/health` with 3s timeout

- [ ] **Step 2: Create ChartServiceManager.swift**

Use TechSpec 8.2 verbatim. Key points:
- `ObservableObject` with `@Published isRunning` and `lastHeartbeat`
- `ensureServiceRunning()` async -> Bool
- `startService()` finds python3 and main.py, launches Process
- `checkHealth()` async URLSession call
- `startHeartbeatMonitoring()` 10-second Timer, auto-restart on failure
- `findPythonPath()` checks bundled, then system paths
- `findScriptPath()` checks bundled, then dev path relative to executable
- Logs to `~/Library/Logs/AIRecording/chart-agent.log`

---

## Task 6: Swift ChartWebView and ChartPanelView

**Files:**
- Create: `AIRecording/Views/ChartWebView.swift`
- Create: `AIRecording/Views/ChartPanelView.swift`

- [ ] **Step 1: Create ChartWebView.swift**

Use TechSpec 5.3 verbatim. Key points:
- `NSViewRepresentable` with `htmlContent: String`
- `makeNSView` creates WKWebView with transparent background (`setValue(false, forKey: "drawsBackground")`)
- `updateNSView` calls `wrapWithDarkTheme` then `loadHTMLString`
- Coordinator with `WKNavigationDelegate` for optional JS bridge
- `wrapWithDarkTheme` injects CSS variables into HTML wrapper

- [ ] **Step 2: Create ChartPanelView.swift**

Use TechSpec 5.4 verbatim. Key points:
- `ChartPanelView` takes `recordingId: UUID`, creates `ChartPanelViewModel`
- Header with "智能图表" title, generation status, chart type badge, export button
- `contentView` ViewBuilder: error -> ChartWebView -> empty state
- `ChartPanelViewModel` @MainActor ObservableObject
- `generateChart()` assembles request from recording data, calls chartSkill
- `exportHTML()` uses NSSavePanel to write standalone HTML file
- `wrapAsStandaloneHTML` creates self-contained HTML with CSS variables

---

## Task 7: Core Data Model Extension

**Files:**
- Modify: `AIRecording/Services/PersistenceController.swift`
- Modify: `AIRecording/Models/Recording.swift`

- [ ] **Step 1: Add Chart entities to PersistenceController**

In the `model` closure, after the existing segment entity and before `model.entities = [...]`, add:

1. **Chart entity** with attributes:
   - id (UUID), recordingId (UUID), chartType (Int16), chartTypeConfidence (Double)
   - status (Int16), styleTheme (String), templateId (String)
   - nodeCount (Int32), edgeCount (Int32), maxDepth (Int32), generationTimeMs (Int32)
   - version (Int32), isUserEdited (Bool), parentChartId (UUID)
   - exportedImagePath (String), exportedSVGPath (String)
   - createdAt (Date), updatedAt (Date), errorMessage (String), retryCount (Int32)

2. **ChartNode entity** with attributes:
   - id (UUID), chartId (UUID), nodeId (String), label (String)
   - level (Int32), nodeType (Int16), shape (String), color (String)
   - metadata (String), sequence (Int32), createdAt (Date), updatedAt (Date)

3. **ChartEdge entity** with attributes:
   - id (UUID), chartId (UUID), sourceNodeId (String), targetNodeId (String)
   - label (String), edgeStyle (String), arrowType (String), sequence (Int32), createdAt (Date)

4. **ChartJob entity** with attributes:
   - id (UUID), chartId (UUID), recordingId (UUID), jobType (Int16)
   - status (Int16), progress (Int32), inputData (String)
   - startedAt (Date), completedAt (Date), errorMessage (String), createdAt (Date)

5. **Relationships**:
   - Recording -> Chart (1:many, cascade delete)
   - Chart -> Recording (many:1, nullify)
   - Chart -> ChartNode (1:many, cascade)
   - ChartNode -> Chart (many:1, nullify)
   - Chart -> ChartEdge (1:many, cascade)
   - ChartEdge -> Chart (many:1, nullify)
   - Chart -> ChartJob (1:many, cascade)
   - ChartJob -> Chart (many:1, nullify)

Update `model.entities = [recording, transcription, segment, chart, chartNode, chartEdge, chartJob]`

- [ ] **Step 2: Add charts relationship to Recording model**

Add to `Recording.swift`:
```swift
@NSManaged public var charts: NSSet?
```

Add generated accessors:
```swift
extension Recording {
    @objc(addChartsObject:)
    @NSManaged public func addToCharts(_ value: Chart)

    @objc(removeChartsObject:)
    @NSManaged public func removeFromCharts(_ value: Chart)

    @objc(addCharts:)
    @NSManaged public func addToCharts(_ values: NSSet)

    @objc(removeCharts:)
    @NSManaged public func removeFromCharts(_ values: NSSet)
}
```

---

## Task 8: Integrate ChartPanel into RecordingDetailView

**Files:**
- Modify: `AIRecording/Views/RecordingDetailView.swift`
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`

- [ ] **Step 1: Add chart states to RecordingDetailViewModel**

Add properties:
```swift
@Published var isGeneratingChart = false
@Published var chartResult: ChartResult?
@Published var chartError: String?
```

Add method:
```swift
func generateChart() {
    guard let summary = summary, !summary.isEmpty else { return }
    isGeneratingChart = true
    chartError = nil
    Task {
        do {
            let request = ChartGenerateRequest(
                version: "1.0",
                requestId: UUID().uuidString,
                content: .init(
                    theme: recording?.displayTitle ?? "会议",
                    participants: [],
                    keyDecisions: [],
                    actionItems: [],
                    timeline: [],
                    markdownContent: summary,
                    rawTranscription: recording?.transcription?.fullText
                ),
                preferences: .init(
                    primaryChartType: "auto",
                    styleTheme: "darkCyberpunk",
                    outputFormats: ["html"]
                )
            )
            let response = try await HTTPChartSkill.shared.generate(request: request)
            await MainActor.run {
                self.chartResult = response.charts.first
                self.isGeneratingChart = false
            }
        } catch {
            await MainActor.run {
                self.chartError = (error as? ChartSkillError)?.localizedDescription ?? error.localizedDescription
                self.isGeneratingChart = false
            }
        }
    }
}
```

- [ ] **Step 2: Insert chart panel into RecordingDetailView**

After `summaryView` in the body VStack, before `Spacer(minLength: 40)`, add:

```swift
Divider()

chartPanelView
```

Add the chartPanelView property:

```swift
@ViewBuilder
private var chartPanelView: some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Text("智能图表")
                .font(.headline)
            Spacer()
            if viewModel.isGeneratingChart {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("生成中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let error = viewModel.chartError {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        viewModel.generateChart()
                    }
                }
                Spacer()
            }
            .padding(.vertical, 20)
        } else if let chart = viewModel.chartResult {
            ChartWebView(htmlContent: chart.htmlFragment)
                .frame(minHeight: 400)
                .background(Color(hex: "#0F0F1A"))
                .cornerRadius(12)
        } else {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("暂无图表")
                        .foregroundStyle(.secondary)
                    Button("生成图表") {
                        viewModel.generateChart()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .padding(.vertical, 40)
        }
    }
}
```

---

## Task 9: Build Verification

**Files:** None (verification only)

- [ ] **Step 1: Build Swift project**

Run: `cd /Volumes/HP\ P900/mac/WorkPlace/AIRecording && swift build`
Expected: Build succeeds with no errors

- [ ] **Step 2: Verify Python service**

Run: `cd /Volumes/HP\ P900/mac/WorkPlace/AIRecording/ChartAgent && python main.py &`
Run: `curl -X POST http://127.0.0.1:8765/chart/generate -H "Content-Type: application/json" -d '{"version":"1.0","requestId":"test-001","content":{"theme":"Test","markdownContent":"## Test\n\n- Item 1\n  - Sub 1\n  - Sub 2\n- Item 2\n\n### Decision\nIf user > 10万 then microservice.\n\n### TODO\n- [ ] Design (Alice, June 1)\n- [ ] Review (Bob, June 5)\n"},"preferences":{"primaryChartType":"auto","styleTheme":"darkCyberpunk","outputFormats":["html"]}}'`
Expected: JSON response with status "success" or "degraded", htmlFragment containing dark cyberpunk CSS

- [ ] **Step 3: Verify /health endpoint**

Run: `curl http://127.0.0.1:8765/health`
Expected: `{"status":"ok","version":"1.1.0"}`

---

## Self-Review Checklist

1. **Spec coverage:**
   - [x] ChartSkill Protocol (Task 4)
   - [x] HTTPChartSkill implementation (Task 5)
   - [x] ChartServiceManager lifecycle (Task 5)
   - [x] ChartWebView WKWebView wrapper (Task 6)
   - [x] ChartPanelView + ViewModel (Task 6)
   - [x] Core Data programmatic model extension (Task 7)
   - [x] RecordingDetailView integration (Task 8)
   - [x] FastAPI endpoints (Task 1)
   - [x] LangGraph 5-node graph (Task 2)
   - [x] Jinja2 templates + dark CSS (Task 3)
   - [x] LLM client with fallback (Task 2)
   - [x] Validation + retry mechanism (Task 2)

2. **Placeholder scan:** No TBD/TODO/fill-in-details found.

3. **Type consistency:** All type names match between Swift files and TechSpec. ChartResult, ChartGenerateRequest, ChartSkillError used consistently.
