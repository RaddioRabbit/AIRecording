# 智能图表 v4：按录音内容类型路由图表 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 ChartAgent 从"LLM 自由路由 7 种通用图表"（v3）改为"内容分类器判定录音类型 → 该类型专属 skill 出固定图表"（v4），覆盖会议/访谈/讲座/对话/演讲/随手记/其他七种类型。

**Architecture:** LangGraph 流水线改为 `prepare_transcript → classify_content → extract_structured → merge_plans → validate_plan → render_chart → validate_render`；七个 skill 模块（`ChartAgent/agent/skills/`）各自内聚提取提示词、plan 模型、合并、校验、兜底、Jinja2 模板；渲染保持纯 HTML/CSS + 内联 SVG（无 JS），SVG 几何由 Python 确定性计算。v3 的时间预算、溯源校验、一次修复、点击跳音频机制全部保留。

**Tech Stack:** Python 3 / FastAPI / LangGraph / Pydantic v2 / Jinja2（ChartAgent）；SwiftUI / Combine（macOS 端）。

**设计依据：** `docs/superpowers/specs/2026-07-17-smartchart-content-type-skills-design.md`（已确认设计，本计划的唯一权威来源）。

---

## 前置条件（执行前必读）

1. **工作区有未提交的 v3 重构**（`templates.py` 已精简到 294 行、`ChartPanelView.swift` 已删除等）。本计划基于**当前工作区状态**编写。执行前必须先提交这批改动（例如 `git commit -am "refactor: 图表模板精简与面板合并"`），**不要 stash 或回退**，否则计划中的代码锚点全部失效。
2. 类型 ↔ 图表映射（全计划统一使用，不得改拼写）：

| content_type | 中文 | chart_type | 图表名 |
|---|---|---|---|
| meeting | 会议 | `decision_board` | 决策行动看板 |
| interview | 访谈 | `qa_cards` | 问答观点卡 |
| lecture | 讲座 | `knowledge_tree` | 知识大纲树 |
| dialogue | 对话 | `topic_swimlane` | 话题泳道图 |
| speech | 演讲 | `narrative_arc` | 叙事弧线图 |
| memo | 随手记 | `idea_card` | 灵感要点卡 |
| other | 其他 | `highlights` | 重点句子 |

3. Python 测试运行方式（在 `ChartAgent/` 目录下）：`PYTHONPATH=. python3 -m unittest discover -s tests -v`；单文件：`PYTHONPATH=. python3 -m unittest tests.test_classifier -v`。
4. Swift 验证：项目根目录 `swift build` / `swift test --filter SmartChartTests`。
5. LLM 打桩约定：`nodes.py` 与各新模块都用 `from .llm_client import call_llm` 模块级导入，测试用 `patch.object(<module>, "call_llm", side_effect=fake)` 打桩；fake 通过提示词中的标记串区分阶段（分类器提示词含 `"内容分类器"`；提取提示词含各自 chart_type 如 `'"decision_board"'`；修复提示词含 `"未通过校验"`）。

## 文件结构总览

**新建：**
- `ChartAgent/agent/textutils.py` — 共享纯函数：文本归一化、证据校验、重点句子规则、LLM JSON 解析、数字一致性
- `ChartAgent/agent/classifier.py` — 内容分类器（1 次 LLM 调用 + 置信度门槛 + 失败归 other）
- `ChartAgent/agent/skills/__init__.py` — skill 注册表 `SKILLS` 与 `skill_for_chart_type()`
- `ChartAgent/agent/skills/base.py` — `BaseSkill` 基类（渲染助手、通用修复提示词、共享常量）
- `ChartAgent/agent/skills/{meeting,interview,lecture,dialogue,speech,memo,other}.py` — 七个 skill
- `ChartAgent/tests/test_textutils.py`、`test_classifier.py`、`test_skills.py`、`test_pipeline.py`

**重写：**
- `ChartAgent/agent/graph.py` — v4 节点编排与状态字段
- `ChartAgent/agent/nodes.py` — 删除 v3 候选/路由代码，新增 classify/extract/merge/校验分发
- `ChartAgent/agent/schema.py` — v4 契约（ContentType/ChartType/forceContentType）
- `ChartAgent/agent/templates.py` — 删除 v3 六种图表模板，保留 DARK_CSS/BASE/highlights + 新增 `render_highlights()`
- `ChartAgent/main.py` — 版本 4.0、响应新增 contentType 字段
- `ChartAgent/tests/test_smartchart.py` — 全量重写为 v4 回归套件

**Swift 修改：**
- `AIRecording/Services/ChartSkill.swift` — ContentType 枚举、DTO 变更
- `AIRecording/Services/HTTPChartSkill.swift` — skillId/skillVersion 升级
- `AIRecording/Services/ChartServiceManager.swift` — 版本门升级到 4.0
- `AIRecording/ViewModels/RecordingDetailViewModel.swift` — `generateChart(forcedType:)`
- `AIRecording/Views/RecordingDetailView.swift` — 类型标签 + 指定类型重新生成菜单
- `Tests/AIRecordingTests/SmartChartTests.swift` — 契约测试更新

---

## Task 1: 共享文本工具模块 textutils

**Files:**
- Create: `ChartAgent/agent/textutils.py`
- Test: `ChartAgent/tests/test_textutils.py`

- [ ] **Step 1: 写失败测试**

创建 `ChartAgent/tests/test_textutils.py`：

```python
import unittest

from agent.textutils import (
    filter_known_segment_ids,
    is_highlight_sentence,
    normalize_text,
    numbers_have_evidence,
    parse_llm_json,
    source_text,
    tag_highlight,
    text_has_evidence,
)


class NormalizeTests(unittest.TestCase):
    def test_normalize_strips_punctuation_and_case(self):
        self.assertEqual(normalize_text(" 你好，World! "), "你好world")
        self.assertEqual(normalize_text(None), "")


class ParseJsonTests(unittest.TestCase):
    def test_parses_fenced_json(self):
        self.assertEqual(parse_llm_json("```json\n{\"a\": 1}\n```"), {"a": 1})

    def test_rejects_empty_and_non_dict(self):
        with self.assertRaises(ValueError):
            parse_llm_json("")
        with self.assertRaises(ValueError):
            parse_llm_json("[1, 2]")


class HighlightRuleTests(unittest.TestCase):
    def test_highlight_needs_marker_or_number(self):
        self.assertTrue(is_highlight_sentence("下个月必须完成私有化部署的验收工作"))
        self.assertTrue(is_highlight_sentence("这个方案可以支持 5 到 6 个人并发使用"))
        self.assertFalse(is_highlight_sentence("好的"))
        self.assertFalse(is_highlight_sentence("今天天气还行吧"))

    def test_tag_highlight_rules(self):
        self.assertEqual(tag_highlight("这个风险很大，可能延期"), "风险")
        self.assertEqual(tag_highlight("我们决定采用方案 B"), "关键判断")
        self.assertEqual(tag_highlight("并发数是 6 人"), "重要数据")
        self.assertEqual(tag_highlight("李老师负责下周完成"), "行动承诺")
        self.assertEqual(tag_highlight("因为成本太高所以放弃"), "因果依据")
        self.assertEqual(tag_highlight("这是一个普通的陈述句子用于测试"), "关键要点")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.segment_map = {
            "s1": {"id": "s1", "text": "我们决定下周完成部署，预算是 5 万元"},
            "s2": {"id": "s2", "text": "好的"},
        }

    def test_text_evidence(self):
        self.assertTrue(text_has_evidence("下周完成部署", ["s1"], self.segment_map))
        self.assertFalse(text_has_evidence("下个月完成部署", ["s1"], self.segment_map))

    def test_numbers_evidence(self):
        self.assertTrue(numbers_have_evidence("预算是 5 万元", ["s1"], self.segment_map))
        self.assertFalse(numbers_have_evidence("预算是 8 万元", ["s1"], self.segment_map))
        self.assertTrue(numbers_have_evidence("没有数字", ["s1"], self.segment_map))

    def test_filter_known_segment_ids_dedupes_and_drops_unknown(self):
        self.assertEqual(filter_known_segment_ids(["s1", "x9", "s1", "s2"], self.segment_map), ["s1", "s2"])

    def test_source_text_joins_in_order(self):
        self.assertEqual(source_text(["s2", "s1"], self.segment_map), "好的 我们决定下周完成部署，预算是 5 万元")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_textutils -v`
Expected: FAIL（`ModuleNotFoundError: No module named 'agent.textutils'`）

- [ ] **Step 3: 实现 textutils.py**

创建 `ChartAgent/agent/textutils.py`：

```python
"""共享文本工具：归一化、溯源证据、重点句子规则、LLM JSON 解析、数字一致性。

只放纯函数，不依赖 nodes/skills，避免循环导入。
"""
import json
import re
from typing import Any, Dict, List, Optional, Sequence

_PUNCTUATION_PATTERN = re.compile(
    r"[\s，。！？；：、“”‘’（）《》〈〉【】…—·,.!?;:'\"()<>\[\]{}\\\-_~`@#$%^&*+=|/]+"
)
IMPORTANT_MARKER_PATTERN = re.compile(
    r"重要|关键|必须|需要|决定|结论|风险|问题|目标|计划|截止|提醒|注意|总结|核心|一定|务必|应该"
)
FILLER_PATTERN = re.compile(r"^(嗯|啊|呃|哦|好|好的|对|是的|行|可以|喂|哈喽|大家好)[，。！？\s]*$")
NUMBER_PATTERN = re.compile(r"\d")
NUMBER_TOKEN_PATTERN = re.compile(r"\d+(?:\.\d+)?%?")


def normalize_text(value: Optional[str]) -> str:
    """小写并去除空白与中英文标点，用于证据包含判断。"""
    if not value:
        return ""
    return _PUNCTUATION_PATTERN.sub("", str(value)).lower()


def parse_llm_json(raw: str) -> Dict[str, Any]:
    """解析 LLM 返回的 JSON（容忍 ``` 围栏），顶层必须是对象。"""
    if not raw or not raw.strip():
        raise ValueError("LLM 没有返回文本")
    text = raw.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    parsed = json.loads(text)  # JSONDecodeError 是 ValueError 子类，直接上抛
    if not isinstance(parsed, dict):
        raise ValueError("LLM JSON 顶层必须是对象")
    return parsed


def is_filler(text: str) -> bool:
    return bool(FILLER_PATTERN.match(text.strip()))


def is_highlight_sentence(text: str) -> bool:
    stripped = text.strip()
    if len(stripped) < 10:
        return False
    if is_filler(stripped):
        return False
    return bool(IMPORTANT_MARKER_PATTERN.search(stripped) or NUMBER_PATTERN.search(stripped))


def tag_highlight(text: str) -> str:
    if re.search(r"风险|问题|隐患|失败|延期", text):
        return "风险"
    if re.search(r"决定|结论|认为|判断", text):
        return "关键判断"
    if NUMBER_PATTERN.search(text):
        return "重要数据"
    if re.search(r"负责|完成|截止|跟进|落实|承诺", text):
        return "行动承诺"
    if re.search(r"因为|由于|所以|因此|导致", text):
        return "因果依据"
    return "关键要点"


def source_text(segment_ids: Sequence[str], segment_map: Dict[str, Dict[str, Any]]) -> str:
    """按给定顺序拼接片段原文。"""
    return " ".join(str(segment_map[sid].get("text", "")) for sid in segment_ids if sid in segment_map)


def text_has_evidence(
    value: Optional[str], segment_ids: Sequence[str], segment_map: Dict[str, Dict[str, Any]]
) -> bool:
    """value 归一化后必须整体出现在来源片段原文中（用于必须逐字的字段：金句/重点句子）。"""
    normalized = normalize_text(value)
    if not normalized:
        return False
    return normalized in normalize_text(source_text(segment_ids, segment_map))


def numbers_have_evidence(
    value: Optional[str], segment_ids: Sequence[str], segment_map: Dict[str, Dict[str, Any]]
) -> bool:
    """value 中每个数字 token 都必须能在来源片段原文中找到（用于提炼类字段，允许改写但禁止编造数字）。

    边界匹配：数字前后不能再紧贴数字，避免 "5" 命中 "15" 这类误判。
    """
    source = source_text(segment_ids, segment_map)
    return all(
        re.search(r"(?<!\d)" + re.escape(token) + r"(?!\d)", source)
        for token in NUMBER_TOKEN_PATTERN.findall(value or "")
    )


def filter_known_segment_ids(
    segment_ids: Optional[Sequence[str]], segment_map: Dict[str, Dict[str, Any]]
) -> List[str]:
    """只保留真实存在的片段 id，去重并保持顺序。"""
    seen = set()
    result = []
    for sid in segment_ids or []:
        if sid in segment_map and sid not in seen:
            seen.add(sid)
            result.append(sid)
    return result


def format_mmss(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 60:02d}:{total % 60:02d}"
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_textutils -v`
Expected: 8 个测试全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/textutils.py ChartAgent/tests/test_textutils.py
git commit -m "feat: 图表v4基础设施——共享文本工具模块 textutils"
```

---

## Task 2: v4 API 契约（schema + 版本号，纯增量）

只增不删：新增 `ContentType`/`ChartType` 类型、请求 `forceContentType`、响应 `contentType` 字段（带默认值，保证 v3 流水线在本任务与 Task 12 之间仍可运行）；`ChartPlan` 等旧模型留到 Task 12 删除。

**Files:**
- Modify: `ChartAgent/agent/schema.py`（全文替换）
- Modify: `ChartAgent/main.py:13-14`（版本常量）
- Modify: `ChartAgent/tests/test_smartchart.py`（3 处版本断言更新）

- [ ] **Step 1: 更新版本相关的失败测试**

在 `ChartAgent/tests/test_smartchart.py` 中找到健康检查与版本拒绝相关测试（`SmartChartValidationTests` 内的 health/版本用例），把 `"3.0"` 期望改为 `"4.0"`，把 `"3.1.0"` 改为 `"4.0.0"`；把构造请求时显式传的 `version="3.0"` 改为 `version="4.0"`。同时在文件末尾（`SmartChartEndpointRaceTests` 之前）新增：

```python
class SmartChartSchemaV4Tests(unittest.TestCase):
    def test_request_accepts_force_content_type(self):
        payload = {
            "version": "4.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
            "forceContentType": "meeting",
        }
        request = SmartChartGenerateRequest.model_validate(payload)
        self.assertEqual(request.forceContentType, "meeting")

    def test_request_rejects_unknown_content_type(self):
        payload = {
            "version": "4.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
            "forceContentType": "podcast",
        }
        with self.assertRaises(ValidationError):
            SmartChartGenerateRequest.model_validate(payload)

    def test_request_rejects_v3_version(self):
        payload = {
            "version": "3.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
        }
        with self.assertRaises(ValidationError):
            SmartChartGenerateRequest.model_validate(payload)

    def test_response_defaults_content_type_to_other(self):
        response = SmartChartGenerateResponse(
            requestId="r1",
            status="failed",
            chartType="highlights",
            chartTypeDisplayName="重点句子",
            title="生成失败",
            htmlFragment="<div></div>",
            plan={"chartType": "highlights", "title": "生成失败", "highlightSentences": []},
            errors=["x"],
        )
        self.assertEqual(response.contentType, "other")
        self.assertEqual(response.contentTypeDisplayName, "其他")
```

（文件顶部 import 需有 `SmartChartGenerateResponse`：把 `from main import SmartChartGenerateRequest, app, health_check` 改为 `from main import SmartChartGenerateRequest, SmartChartGenerateResponse, app, health_check`。）

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_smartchart.SmartChartSchemaV4Tests -v`
Expected: FAIL（`forceContentType` 是 forbid 的额外字段 / contentType 不存在）

- [ ] **Step 3: 全文替换 schema.py**

```python
"""SmartChart API 契约（v4）：内容类型路由 + 按类型的图表计划。"""
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

VisualizationKind = Literal["comparison", "timeline", "relationship", "flow", "action", "quantitative", "highlights"]
ContentType = Literal["meeting", "interview", "lecture", "dialogue", "speech", "memo", "other"]
ChartType = Literal[
    "decision_board", "qa_cards", "knowledge_tree", "topic_swimlane", "narrative_arc", "idea_card", "highlights"
]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class TranscriptSegment(StrictModel):
    id: str = Field(min_length=1)
    speaker: str = ""
    startTime: float
    endTime: float
    text: str = Field(min_length=1)


class SmartChartGenerateRequest(StrictModel):
    version: Literal["4.0"] = "4.0"
    requestId: str = Field(min_length=1)
    recordingId: str = Field(min_length=1)
    segments: List[TranscriptSegment]
    summaryMarkdown: Optional[str] = None
    forceContentType: Optional[ContentType] = None


# ---- 以下为 v3 图表计划模型，v4 流水线（Task 12）切换后删除 ----

class ChartItem(StrictModel):
    id: str = Field(min_length=1)
    label: str = Field(min_length=1)
    role: Optional[str] = None
    segmentIds: List[str] = Field(default_factory=list)
    metadata: Optional[Dict[str, str]] = None


class ChartRelation(StrictModel):
    id: str = Field(min_length=1)
    fromItemId: str = Field(min_length=1)
    toItemId: str = Field(min_length=1)
    label: Optional[str] = None
    segmentIds: List[str] = Field(default_factory=list)


class ChartDataPoint(StrictModel):
    label: str = Field(min_length=1)
    rawValue: str = Field(min_length=1)
    numericValue: Optional[float] = None
    unit: Optional[str] = None
    segmentIds: List[str] = Field(default_factory=list)


class ChartSeries(StrictModel):
    id: str = Field(min_length=1)
    name: str = Field(min_length=1)
    unit: Optional[str] = None
    dataPoints: List[ChartDataPoint]


class HighlightSentence(StrictModel):
    segmentId: str = Field(min_length=1)
    text: str = Field(min_length=1)
    speaker: str = ""
    startTime: float
    endTime: float
    tag: str = Field(min_length=1)


class ChartPlan(StrictModel):
    visualizationKind: VisualizationKind
    title: str = Field(min_length=1)
    routingConfidence: float = Field(ge=0.0, le=1.0)
    items: List[ChartItem] = Field(default_factory=list)
    relations: List[ChartRelation] = Field(default_factory=list)
    series: List[ChartSeries] = Field(default_factory=list)
    highlightSentences: List[HighlightSentence] = Field(default_factory=list)


class SmartChartGenerateResponse(StrictModel):
    version: Literal["4.0"] = "4.0"
    requestId: str
    status: Literal["success", "failed"]
    contentType: ContentType = "other"
    contentTypeDisplayName: str = "其他"
    chartType: str
    chartTypeDisplayName: str
    title: str
    htmlFragment: str
    plan: Dict[str, Any]
    errors: List[str] = Field(default_factory=list)
    errorCode: Optional[str] = None
```

注意：`chartType` 从 `VisualizationKind` 放宽为 `str`（v4 图表标识是 `decision_board` 等新值）；`plan` 从 `ChartPlan` 放宽为 `Dict[str, Any]`（各 skill 自己的 plan 形状）。响应 `contentType`/`contentTypeDisplayName` 带默认值，main.py 在 Task 12 才写入真实值。

- [ ] **Step 4: 更新 main.py 版本常量**

`ChartAgent/main.py:13-14`：

```python
API_VERSION = "4.0"
SERVICE_VERSION = "4.0.0"
```

同时把 main.py 中 `_failed_response` 里构造响应时传入的 `plan=ChartPlan(...)` 改为普通 dict（`ChartPlan` 仍 import 着没关系，但响应 plan 字段类型已变为 Dict，直接传 dict 更一致）：

```python
plan={"chartType": "highlights", "title": "生成失败", "highlightSentences": []},
```

并把成功分支的 `plan=plan`（原 `ChartPlan.model_validate(...)` 结果）改为 `plan=plan.model_dump()`——不，**本任务先不动成功分支**：成功分支 `plan=ChartPlan.model_validate(...)` 会在 Task 12 整体重写。本任务只改版本常量、`_failed_response` 的 plan 实参，以及把端点里 `SmartChartGenerateResponse(...)` 成功分支的 `plan=plan` 改为 `plan=plan.model_dump()`（因为响应模型现在要求 Dict，传 ChartPlan 会报类型错误——strict 模式下 Dict[str, Any] 字段不接受 BaseModel 实例）。

- [ ] **Step 5: 运行全部测试**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest discover -s tests -v`
Expected: 全部 OK（含新的 4 个 schema 测试；v3 流程测试仍绿，因为 v3 流水线未动）

- [ ] **Step 6: Commit**

```bash
git add ChartAgent/agent/schema.py ChartAgent/main.py ChartAgent/tests/test_smartchart.py
git commit -m "feat: 图表v4协议——ContentType 契约与版本升级 4.0"
```

---

## Task 3: 内容分类器 classifier

**Files:**
- Create: `ChartAgent/agent/classifier.py`
- Test: `ChartAgent/tests/test_classifier.py`

- [ ] **Step 1: 写失败测试**

创建 `ChartAgent/tests/test_classifier.py`：

```python
import json
import unittest
from unittest.mock import patch

from agent import classifier
from agent.llm_client import LLMError


def make_segments(count=3, speakers=("甲", "乙")):
    return [
        {
            "id": f"s{i}",
            "speaker": speakers[i % len(speakers)],
            "startTime": float(i * 5),
            "endTime": float(i * 5 + 5),
            "text": f"第{i}段内容，讨论部署方案与分工安排。",
        }
        for i in range(count)
    ]


class ClassifyContentTests(unittest.TestCase):
    def test_returns_classified_type_when_confident(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "meeting", "confidence": 0.9, "reason": "有议题和分工"}, ensure_ascii=False
        )):
            content_type, confidence, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "meeting")
        self.assertAlmostEqual(confidence, 0.9)
        self.assertEqual(reason, "有议题和分工")

    def test_low_confidence_falls_back_to_other(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "meeting", "confidence": 0.5, "reason": "不确定"}
        )):
            content_type, _, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")
        self.assertTrue(reason.startswith("low_confidence"))

    def test_confidence_exactly_at_threshold_is_accepted(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "lecture", "confidence": 0.6, "reason": "ok"}
        )):
            content_type, _, _ = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "lecture")

    def test_llm_failure_returns_other(self):
        with patch.object(classifier, "call_llm", side_effect=LLMError(LLMError.TIMEOUT, "超时")):
            content_type, confidence, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual((content_type, confidence), ("other", 0.0))
        self.assertTrue(reason.startswith("classify_failed"))

    def test_invalid_json_returns_other(self):
        with patch.object(classifier, "call_llm", return_value="不是 JSON"):
            content_type, _, _ = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")

    def test_unknown_type_returns_other(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "podcast", "confidence": 0.99, "reason": "x"}
        )):
            content_type, _, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")
        self.assertTrue(reason.startswith("unknown_type"))

    def test_prompt_contains_metadata_and_samples(self):
        captured = {}

        def fake_llm(prompt, temperature=0.3, deadline=None):
            captured["prompt"] = prompt
            return json.dumps({"content_type": "other", "confidence": 0.1, "reason": "x"})

        long_text = "开" * 2500 + "中" * 2000 + "尾" * 1500
        with patch.object(classifier, "call_llm", side_effect=fake_llm):
            classifier.classify_content(make_segments(count=4, speakers=("甲", "乙", "丙")), long_text)
        prompt = captured["prompt"]
        self.assertIn("内容分类器", prompt)
        self.assertIn("说话人数 3", prompt)
        self.assertIn("片段数 4", prompt)
        self.assertIn("【开头】", prompt)
        self.assertIn("【中间】", prompt)
        self.assertIn("【结尾】", prompt)

    def test_short_text_not_split_into_middle_tail(self):
        captured = {}

        def fake_llm(prompt, temperature=0.3, deadline=None):
            captured["prompt"] = prompt
            return json.dumps({"content_type": "memo", "confidence": 0.9, "reason": "短"})

        with patch.object(classifier, "call_llm", side_effect=fake_llm):
            classifier.classify_content(make_segments(count=1, speakers=("甲",)), "很短的转写")
        self.assertNotIn("【中间】", captured["prompt"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_classifier -v`
Expected: FAIL（`No module named 'agent.classifier'`）

- [ ] **Step 3: 实现 classifier.py**

创建 `ChartAgent/agent/classifier.py`：

```python
"""录音内容分类器：把转写内容分类为七种内容类型之一。

设计要点（对应设计文档 §5）：
- 输入 = 元信息（时长/说话人数/片段数）+ 采样文本（开头/中间/结尾）
- 说话人数是强提示但不硬排除（speakerId 可能缺失或不准）
- 任何失败/低置信度都归 other，分类器永远不让请求失败
"""
from typing import Any, Dict, List, Optional, Tuple

from .llm_client import LLMError, call_llm
from .textutils import parse_llm_json

CONTENT_TYPES = ("meeting", "interview", "lecture", "dialogue", "speech", "memo", "other")
CLASSIFY_CONFIDENCE_THRESHOLD = 0.6
HEAD_SAMPLE_CHARS = 2000
MIDDLE_SAMPLE_CHARS = 1000
TAIL_SAMPLE_CHARS = 1000

_TYPE_DEFINITIONS = """- meeting 会议：多人、有议题、产出结论或待办
- interview 访谈：一问一答、角色分明（提问者 vs 回答者）
- lecture 讲座：单人为主、系统传授知识（概念→讲解→例子）
- dialogue 对话：多人自由讨论、不追求结论
- speech 演讲：单人、面向观众的感染力表达（故事+观点+金句）
- memo 随手记：单人即兴记录（口播/语音备忘），短且随意
- other 其他：无法确定或均不符合"""


def _sample_transcript(text: str) -> Tuple[str, str, str]:
    if len(text) <= HEAD_SAMPLE_CHARS + MIDDLE_SAMPLE_CHARS + TAIL_SAMPLE_CHARS:
        return text, "", ""
    head = text[:HEAD_SAMPLE_CHARS]
    tail = text[-TAIL_SAMPLE_CHARS:]
    middle_start = max((len(text) - MIDDLE_SAMPLE_CHARS) // 2, len(head))
    middle = text[middle_start:middle_start + MIDDLE_SAMPLE_CHARS]
    return head, middle, tail


def _speaker_count(segments: List[Dict[str, Any]]) -> int:
    return len({str(s.get("speaker", "")).strip() for s in segments if str(s.get("speaker", "")).strip()})


def _total_duration(segments: List[Dict[str, Any]]) -> float:
    return max((float(s.get("endTime", 0.0) or 0.0) for s in segments), default=0.0)


def build_classify_prompt(segments: List[Dict[str, Any]], transcript_text: str) -> str:
    head, middle, tail = _sample_transcript(transcript_text)
    samples = f"【开头】{head}"
    if middle:
        samples += f"\n【中间】{middle}"
    if tail:
        samples += f"\n【结尾】{tail}"
    return (
        "你是录音内容分类器。根据元信息与采样文本，把录音分类为七种内容类型之一：\n"
        f"{_TYPE_DEFINITIONS}\n"
        "边界判定：是否产出结论区分 meeting 与 dialogue；传授知识 vs 感染说服区分 lecture 与 speech；"
        "有明显问答交替才是 interview。\n"
        "只输出严格 JSON：{\"content_type\":\"...\",\"confidence\":0.0,\"reason\":\"≤30字\"}\n"
        "confidence 取 0-1，不确定时给低分。\n"
        f"元信息：时长 {_total_duration(segments):.0f} 秒；说话人数 {_speaker_count(segments)}；片段数 {len(segments)}；总字符数 {len(transcript_text)}\n"
        f"采样文本：\n{samples}"
    )


def classify_content(
    segments: List[Dict[str, Any]], transcript_text: str, deadline: Optional[float] = None
) -> Tuple[str, float, str]:
    """返回 (content_type, confidence, reason)。任何异常都归 other，绝不抛出。"""
    try:
        prompt = build_classify_prompt(segments, transcript_text)
        if deadline is None:
            raw = call_llm(prompt, temperature=0.0)
        else:
            raw = call_llm(prompt, temperature=0.0, deadline=deadline)
        parsed = parse_llm_json(raw)
        content_type = str(parsed.get("content_type", ""))
        confidence = float(parsed.get("confidence", 0.0) or 0.0)
        reason = str(parsed.get("reason") or "")[:60]
    except (LLMError, ValueError, TypeError, AttributeError) as error:
        return "other", 0.0, f"classify_failed:{type(error).__name__}"
    if content_type not in CONTENT_TYPES:
        return "other", 0.0, f"unknown_type:{content_type[:20]}"
    if not confidence >= CLASSIFY_CONFIDENCE_THRESHOLD:
        return "other", confidence, f"low_confidence:{content_type}"
    return content_type, confidence, reason
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_classifier -v`
Expected: 8 个测试全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/classifier.py ChartAgent/tests/test_classifier.py
git commit -m "feat: 图表v4——录音内容分类器（七类+置信度门槛+失败归其他）"
```

---

## Task 4: 渲染基础（templates.py 纯增量）

为七个新图表准备 CSS 类，并暴露 skill 模板继承所需的公共件。本任务**不删除任何 v3 内容**（删除在 Task 12）。

**Files:**
- Modify: `ChartAgent/agent/templates.py`
- Test: `ChartAgent/tests/test_skills.py`（新建，先只放渲染基础测试）

- [ ] **Step 1: 写失败测试**

创建 `ChartAgent/tests/test_skills.py`：

```python
import unittest

from agent.templates import BASE_TEMPLATE, DARK_CSS, render_highlights


def highlights_plan():
    return {
        "chartType": "highlights",
        "title": "重点句子",
        "highlightSentences": [
            {
                "segmentId": "s1",
                "text": "我们决定下周完成部署",
                "speaker": "甲",
                "startTime": 0.0,
                "endTime": 5.0,
                "tag": "关键判断",
            }
        ],
        "truncatedCount": 0,
    }


class RenderFoundationTests(unittest.TestCase):
    def test_render_highlights_outputs_segment_ids(self):
        html = render_highlights(highlights_plan(), "darkCyberpunk", "重点句子")
        self.assertIn('data-segment-ids="s1"', html)
        self.assertIn("我们决定下周完成部署", html)
        self.assertIn("重点句子", html)

    def test_render_highlights_escapes_xss(self):
        plan = highlights_plan()
        plan["highlightSentences"][0]["text"] = "<script>alert(1)</script>"
        html = render_highlights(plan, "darkCyberpunk", "重点句子")
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_new_chart_css_classes_exist(self):
        for css_class in (
            ".sc-idea-core", ".sc-point-row", ".sc-topic-title", ".sc-conclusion",
            ".sc-action-row", ".sc-badge-owner", ".sc-badge-due",
            ".sc-qa-question", ".sc-qa-answer", ".sc-truncate-note",
        ):
            self.assertIn(css_class, DARK_CSS)

    def test_base_template_is_public(self):
        self.assertIn("smartchart-container", BASE_TEMPLATE)
        self.assertIn("{% block chart_content %}", BASE_TEMPLATE)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: FAIL（`cannot import name 'BASE_TEMPLATE'`）

- [ ] **Step 3: 修改 templates.py（纯增量）**

3a. 在 `DARK_CSS` 字符串末尾（收尾引号之前）追加：

```css
.sc-idea-core{background:#2b1a4e;border:1px solid #7c3aed;border-radius:10px;padding:14px 16px;color:#e9d5ff;font-weight:600;font-size:15px;line-height:1.5;margin-bottom:10px}
.sc-point-row{display:flex;gap:8px;align-items:flex-start;padding:8px 10px;border-radius:8px;background:#1E1E2E;margin-bottom:6px;cursor:pointer}
.sc-point-marker{color:#22d3ee;flex:none}
.sc-topic-card{margin-bottom:12px}
.sc-topic-title{color:#7aa2ff;font-weight:600;font-size:14px;margin-bottom:8px}
.sc-conclusion{display:flex;gap:8px;align-items:center;background:#12291f;border-left:3px solid #34d399;border-radius:6px;padding:8px 10px;color:#a7f3d0;margin-bottom:8px;line-height:1.5}
.sc-conclusion-label{flex:none;background:#065f46;color:#a7f3d0;border-radius:8px;padding:1px 8px;font-size:11px}
.sc-action-row{display:flex;gap:8px;align-items:center;background:#1E1E2E;border-radius:6px;padding:7px 10px;margin-bottom:6px}
.sc-action-text{flex:1;color:#e5e7eb;line-height:1.5}
.sc-badge{flex:none;border-radius:10px;padding:1px 8px;font-size:11px}
.sc-badge-owner{background:#5b21b6;color:#ddd6fe}
.sc-badge-due{background:#92400e;color:#fde68a}
.sc-qa-card{margin-bottom:12px}
.sc-qa-question{display:inline-block;background:#164e63;color:#67e8f9;border-radius:12px;padding:3px 10px;font-size:13px;margin-bottom:8px}
.sc-qa-answer{border-left:3px solid #22d3ee;background:#1E1E2E;border-radius:6px;padding:8px 10px;color:#e5e7eb;line-height:1.6;margin-bottom:8px}
.sc-qa-tags{display:flex;gap:6px}
.sc-truncate-note{color:#64748b;font-size:12px;text-align:center;padding:6px}
```

3b. 在 `_BASE_TEMPLATE` 定义之后加公开别名：

```python
BASE_TEMPLATE = _BASE_TEMPLATE  # 公开别名：skill 模板通过 {% extends "base.html.j2" %} 继承
```

3c. 在文件末尾追加公共渲染入口（复用现有 `_JINJA_ENV`，其中已注册 `base.html.j2` 与 `highlights.html.j2`）：

```python
def render_highlights(plan: dict, theme: str, title: str = "") -> str:
    """重点句子图表的公共渲染入口（other skill 与全局兜底共用）。"""
    template = _JINJA_ENV.get_template("highlights.html.j2")
    return template.render(
        plan=plan,
        theme=theme,
        title=title or plan.get("title", "重点句子"),
        kind_display_name="重点句子",
        dark_css=DARK_CSS,
    )
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills tests.test_smartchart -v`
Expected: 全部 OK（v3 套件不受影响）

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/templates.py ChartAgent/tests/test_skills.py
git commit -m "feat: 图表v4渲染基础——新图表CSS类、BASE_TEMPLATE公开与 render_highlights 入口"
```

---

## Task 5: skill 框架（BaseSkill + 注册表 + other 兜底 skill）

**Files:**
- Create: `ChartAgent/agent/skills/__init__.py`
- Create: `ChartAgent/agent/skills/base.py`
- Create: `ChartAgent/agent/skills/other.py`
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

在 `ChartAgent/tests/test_skills.py` 末尾（`if __name__` 之前）追加：

```python
from agent.skills import SKILLS, skill_for_chart_type


def other_segments():
    return [
        {"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "嗯，好的"},
        {"id": "s2", "speaker": "甲", "startTime": 5.0, "endTime": 10.0, "text": "我们决定下周完成私有化部署的验收"},
        {"id": "s3", "speaker": "乙", "startTime": 10.0, "endTime": 15.0, "text": "今天天气不错"},
        {"id": "s4", "speaker": "乙", "startTime": 15.0, "endTime": 20.0, "text": "记得提醒我买周五的车票啊"},
    ]


class OtherSkillTests(unittest.TestCase):
    def test_registry_contains_other(self):
        self.assertIs(SKILLS["other"], skill_for_chart_type("highlights"))
        self.assertFalse(SKILLS["other"].uses_llm_extraction)

    def test_extract_deterministic_picks_highlight_sentences(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        self.assertEqual(plan["chartType"], "highlights")
        texts = [s["text"] for s in plan["highlightSentences"]]
        self.assertIn("我们决定下周完成私有化部署的验收", texts)
        self.assertIn("记得提醒我买周五的车票啊", texts)
        self.assertNotIn("嗯，好的", texts)
        self.assertNotIn("今天天气不错", texts)
        # 按时间排序
        starts = [s["startTime"] for s in plan["highlightSentences"]]
        self.assertEqual(starts, sorted(starts))

    def test_extract_deterministic_falls_back_to_any_long_segment(self):
        segments = [{"id": "s1", "speaker": "", "startTime": 0.0, "endTime": 5.0, "text": "随便聊聊今天发生的事情"}]
        plan = SKILLS["other"].extract_deterministic(segments)
        self.assertEqual(len(plan["highlightSentences"]), 1)
        self.assertEqual(plan["highlightSentences"][0]["tag"], "关键要点")

    def test_extract_deterministic_caps_at_12_with_truncated_count(self):
        segments = [
            {"id": f"s{i}", "speaker": "", "startTime": float(i * 5), "endTime": float(i * 5 + 5),
             "text": f"这是第 {i} 条必须关注的重要内容"}
            for i in range(15)
        ]
        plan = SKILLS["other"].extract_deterministic(segments)
        self.assertEqual(len(plan["highlightSentences"]), 12)
        self.assertEqual(plan["truncatedCount"], 3)

    def test_render_shows_truncate_note_when_capped(self):
        segments = [
            {"id": f"s{i}", "speaker": "", "startTime": float(i * 5), "endTime": float(i * 5 + 5),
             "text": f"这是第 {i} 条必须关注的重要内容"}
            for i in range(15)
        ]
        plan = SKILLS["other"].extract_deterministic(segments)
        html = SKILLS["other"].render(plan, "darkCyberpunk", "重点句子")
        self.assertIn("还有 3 条重点句子未展示", html)

    def test_validate_rejects_forged_segment(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        plan["highlightSentences"][0]["segmentId"] = "forged"
        segment_map = {s["id"]: s for s in other_segments()}
        self.assertTrue(SKILLS["other"].validate(plan, segment_map))

    def test_validate_passes_own_output(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        segment_map = {s["id"]: s for s in other_segments()}
        self.assertEqual(SKILLS["other"].validate(plan, segment_map), [])

    def test_render_contains_segment_ids(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        html = SKILLS["other"].render(plan, "darkCyberpunk", "重点句子")
        self.assertIn("data-segment-ids", html)


if __name__ == "__main__":
    unittest.main()
```

（注意替换文件末尾原有的 `if __name__ == "__main__":` 块，保持唯一。）

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: FAIL（`No module named 'agent.skills'`）

- [ ] **Step 3: 实现三个文件**

创建 `ChartAgent/agent/skills/base.py`：

```python
"""skill 基类与共享逻辑。

每个 skill 负责一种内容类型的图表：提取提示词 → plan 归一化 → 合并 → 校验 → 兜底 → 渲染。
贯穿纪律（设计文档 §6.1）：LLM 只产 JSON；每条内容必须绑定真实 segment_ids；
金句类字段逐字校验；提炼类字段数字一致性校验；SVG 几何由 Python 计算。
"""
import json
from typing import Any, Dict, List, Optional

from jinja2 import DictLoader, Environment

from ..templates import BASE_TEMPLATE, DARK_CSS

CONTENT_TYPE_DISPLAY_NAMES = {
    "meeting": "会议",
    "interview": "访谈",
    "lecture": "讲座",
    "dialogue": "对话",
    "speech": "演讲",
    "memo": "随手记",
    "other": "其他",
}


class BaseSkill:
    content_type: str = "other"
    chart_type: str = "highlights"
    display_name: str = "重点句子"
    uses_llm_extraction: bool = True

    # ---- 提取（子类实现）----
    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        raise NotImplementedError

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        """把 LLM 原始 JSON 归一化为合法 plan dict；结构非法抛 ValueError；
        引用未知 segment_ids 的元素直接丢弃。"""
        raise NotImplementedError

    # ---- 合并（子类实现）----
    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        raise NotImplementedError

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        raise NotImplementedError

    # ---- 校验 / 兜底（子类实现）----
    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        raise NotImplementedError

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        """类型内兜底：保留有原文依据的元素；救不回来返回 None（→ 全局降级 highlights）。"""
        return None

    # ---- 修复提示词（通用，可覆写）----
    def repair_prompt(
        self, plan: Dict[str, Any], errors: List[str], segments: List[Dict[str, Any]]
    ) -> str:
        return (
            f"下面的{self.display_name}图表数据未通过校验。只根据给定转写片段纠正一次；"
            "无法可靠纠正时，返回一个只包含有原文依据元素的最小版本。\n"
            f"校验错误：\n{json.dumps(errors, ensure_ascii=False, indent=2)}\n"
            f"原数据：\n{json.dumps(plan, ensure_ascii=False)}\n"
            f"转写片段：\n{json.dumps(segments, ensure_ascii=False, indent=2)}\n"
            "只输出与原数据相同结构的严格 JSON，不要输出其他文字。"
        )

    # ---- 渲染（子类实现）----
    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        raise NotImplementedError

    # ---- 共享渲染助手 ----
    def _render_jinja(self, template_body: str, *, plan: Dict[str, Any], theme: str, title: str, **extra: Any) -> str:
        env = Environment(
            loader=DictLoader({"base.html.j2": BASE_TEMPLATE, "chart.html.j2": template_body}),
            autoescape=True,
        )
        return env.get_template("chart.html.j2").render(
            plan=plan,
            theme=theme,
            title=title or plan.get("title", ""),
            kind_display_name=self.display_name,
            dark_css=DARK_CSS,
            **extra,
        )
```

创建 `ChartAgent/agent/skills/other.py`：

```python
"""other skill：重点句子（兜底图表）。

完全确定性、不依赖 LLM——它是所有 skill 失败时的最终出口，必须永远可用。
复用 v3 的重点句子判定规则与渲染器。
"""
from typing import Any, Dict, List

from ..templates import render_highlights
from ..textutils import is_filler, is_highlight_sentence, normalize_text, tag_highlight
from .base import BaseSkill

MAX_SENTENCES = 12


class OtherSkill(BaseSkill):
    content_type = "other"
    chart_type = "highlights"
    display_name = "重点句子"
    uses_llm_extraction = False

    def extract_deterministic(self, segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        ordered = sorted(segments, key=lambda s: float(s.get("startTime", 0.0) or 0.0))
        sentences = []
        seen = set()

        def append_sentence(segment: Dict[str, Any], tag: str) -> None:
            key = (segment.get("id"), normalize_text(segment.get("text", "")))
            if key in seen:
                return
            seen.add(key)
            sentences.append({
                "segmentId": segment["id"],
                "text": str(segment.get("text", "")).strip(),
                "speaker": str(segment.get("speaker", "")),
                "startTime": float(segment.get("startTime", 0.0) or 0.0),
                "endTime": float(segment.get("endTime", 0.0) or 0.0),
                "tag": tag,
            })

        for segment in ordered:
            text = str(segment.get("text", "")).strip()
            if is_highlight_sentence(text):
                append_sentence(segment, tag_highlight(text))
        if not sentences:
            for segment in ordered:
                text = str(segment.get("text", "")).strip()
                if len(text) >= 10 and not is_filler(text):
                    append_sentence(segment, "关键要点")
        truncated = max(0, len(sentences) - MAX_SENTENCES)
        return {
            "chartType": "highlights",
            "title": "重点句子",
            "highlightSentences": sentences[:MAX_SENTENCES],
            "truncatedCount": truncated,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        if plans:
            return plans[0]
        return {"chartType": "highlights", "title": "重点句子", "highlightSentences": [], "truncatedCount": 0}

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        return not plan.get("highlightSentences")

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        from ..textutils import normalize_text as _normalize

        errors = []
        sentences = plan.get("highlightSentences") or []
        if not sentences:
            return ["highlights 没有可靠重点句子"]
        for index, sentence in enumerate(sentences):
            segment_id = sentence.get("segmentId", "")
            source = segment_map.get(segment_id)
            if source is None:
                errors.append(f"重点句子{index + 1}引用了不存在的片段 {segment_id}")
                continue
            if _normalize(sentence.get("text")) not in _normalize(source.get("text", "")):
                errors.append(f"重点句子{index + 1}与原文不符")
            if abs(float(sentence.get("startTime", -1)) - float(source.get("startTime", 0))) > 0.01:
                errors.append(f"重点句子{index + 1}开始时间与原文不符")
            if abs(float(sentence.get("endTime", -1)) - float(source.get("endTime", 0))) > 0.01:
                errors.append(f"重点句子{index + 1}结束时间与原文不符")
            source_speaker = str(source.get("speaker", ""))
            if source_speaker and sentence.get("speaker", "") != source_speaker:
                errors.append(f"重点句子{index + 1}说话人与原文不符")
        return errors

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        return render_highlights(plan, theme, title)
```

创建 `ChartAgent/agent/skills/__init__.py`：

```python
"""skill 注册表：content_type → skill 实例；chart_type → skill（渲染分发用）。"""
from typing import Dict

from .base import CONTENT_TYPE_DISPLAY_NAMES, BaseSkill
from .other import OtherSkill

SKILLS: Dict[str, BaseSkill] = {skill.content_type: skill for skill in [OtherSkill()]}

CHART_TYPE_DISPLAY_NAMES = {skill.chart_type: skill.display_name for skill in SKILLS.values()}


def skill_for_chart_type(chart_type: str) -> BaseSkill:
    for skill in SKILLS.values():
        if skill.chart_type == chart_type:
            return skill
    return SKILLS["other"]


__all__ = ["BaseSkill", "CONTENT_TYPE_DISPLAY_NAMES", "CHART_TYPE_DISPLAY_NAMES", "SKILLS", "skill_for_chart_type"]
```

3d. 给 `templates.py` 的 `_HIGHLIGHTS_TEMPLATE` 追加截断标注（设计文档 §6.1 要求规模截断必须标注；`OtherSkill.extract_deterministic` 会计算 `truncatedCount`，v3 旧 plan 没有该字段时 Jinja 按 falsy 跳过，安全）。在模板末尾 `{% else %}<div class="sc-empty">没有提取到重点句子</div>{% endif %}` 之后、`{% endblock %}` 之前追加：

```jinja
{% if plan['truncatedCount'] %}<div class="sc-truncate-note">还有 {{ plan['truncatedCount'] }} 条重点句子未展示</div>{% endif %}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/ ChartAgent/agent/templates.py ChartAgent/tests/test_skills.py
git commit -m "feat: 图表skill框架——BaseSkill 基类、注册表、other 兜底skill 与重点句子截断标注"
```

---

## Task 6: memo skill —— 灵感要点卡

**Files:**
- Create: `ChartAgent/agent/skills/memo.py`
- Modify: `ChartAgent/agent/skills/__init__.py`（注册）
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

```python
from agent.skills.memo import MemoSkill


def memo_raw():
    return {
        "chartType": "idea_card",
        "title": "图表改造想法",
        "coreIdea": "把图表生成按内容类型路由",
        "coreSegmentIds": ["s1"],
        "points": [
            {"text": "分类器要能给其他兜底", "segmentIds": ["s1"]},
            {"text": "参考 supersonic 的规则树", "segmentIds": ["s2", "ghost"]},
        ],
    }


def memo_source_segments():
    return [
        {"id": "s1", "speaker": "", "startTime": 0.0, "endTime": 5.0, "text": "分类器要能给其他兜底，这个很重要"},
        {"id": "s2", "speaker": "", "startTime": 5.0, "endTime": 10.0, "text": "参考 supersonic 的规则树来做"},
    ]


class MemoSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = MemoSkill()
        self.segment_map = {s["id"]: s for s in memo_source_segments()}

    def test_normalize_drops_unknown_segment_ids(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        self.assertEqual(plan["chartType"], "idea_card")
        self.assertEqual(plan["points"][1]["segmentIds"], ["s2"])
        self.assertEqual(plan["coreSegmentIds"], ["s1"])

    def test_normalize_falls_back_core_ids_to_first_segment(self):
        raw = memo_raw()
        raw["coreSegmentIds"] = ["ghost"]
        raw["points"] = []
        plan = self.skill.normalize(raw, memo_source_segments())
        self.assertEqual(plan["coreSegmentIds"], ["s1"])

    def test_normalize_rejects_bad_shape(self):
        with self.assertRaises(ValueError):
            self.skill.normalize({"chartType": "idea_card"}, memo_source_segments())

    def test_merge_dedupes_and_truncates_at_8(self):
        plans = [
            {"chartType": "idea_card", "title": "t", "coreIdea": "c", "coreSegmentIds": ["s1"],
             "points": [{"text": f"要点{i}", "segmentIds": ["s1"]} for i in range(6)], "truncatedCount": 0},
            {"chartType": "idea_card", "title": "t", "coreIdea": "c", "coreSegmentIds": ["s2"],
             "points": [{"text": "要点0", "segmentIds": ["s2"]}] + [{"text": f"要点新{i}", "segmentIds": ["s2"]} for i in range(5)],
             "truncatedCount": 0},
        ]
        merged = self.skill.merge(plans)
        self.assertEqual(len(merged["points"]), 8)
        self.assertEqual(merged["truncatedCount"], 3)  # 11 去重后 10 条 - 8
        self.assertEqual(merged["coreSegmentIds"], ["s1"])

    def test_validate_entry_condition(self):
        self.assertTrue(self.skill.validate({"chartType": "idea_card", "title": "t", "coreIdea": "", "points": []}, self.segment_map))

    def test_validate_rejects_fabricated_numbers(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["points"][0]["text"] = "下周三前完成 80% 的改造"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_fallback_drops_invalid_points_keeps_core(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["points"][0]["segmentIds"] = ["ghost"]
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(len(salvaged["points"]), 1)

    def test_validate_rejects_fabricated_core_idea_numbers(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["coreIdea"] = "3 天内完成 80% 的改造"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("核心想法" in e and "数字" in e for e in errors))

    def test_fallback_returns_none_when_core_numbers_fabricated(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["coreIdea"] = "3 天内完成 80% 的改造"
        self.assertIsNone(self.skill.fallback(plan, self.segment_map))

    def test_fallback_resets_truncated_count(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["truncatedCount"] = 5
        plan["points"][0]["segmentIds"] = ["ghost"]
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["truncatedCount"], 0)

    def test_render_contains_core_idea_and_segment_ids(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("把图表生成按内容类型路由", html)
        self.assertIn('data-segment-ids="s1"', html)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"idea_card"', self.skill.extraction_prompt(memo_source_segments()))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.MemoSkillTests -v`
Expected: FAIL（`No module named 'agent.skills.memo'`）

- [ ] **Step 3: 实现 memo.py**

```python
"""memo skill：随手记 → 灵感要点卡。一句话核心想法 + 要点列表（≤8 条）。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import (
    filter_known_segment_ids,
    normalize_text,
    numbers_have_evidence,
)
from .base import BaseSkill

MAX_POINTS = 8

_PROMPT = """你是随手记内容提炼器。这是一段单人即兴语音记录（口播/语音备忘）。请提炼：
1. coreIdea：整段记录的核心想法，一句话，不超过 30 字，必须忠实于原文。
2. coreSegmentIds：核心想法来源的片段 id 列表（只用输入片段中的 id）。
3. points：支撑要点列表，每条不超过 25 字，必须来自原文明确表述，并携带来源 segmentIds。
禁止编造原文没有的内容；segmentIds 只能使用输入片段中的 id。
只输出严格 JSON：
{"chartType":"idea_card","title":"随手记要点","coreIdea":"...","coreSegmentIds":["..."],"points":[{"text":"...","segmentIds":["..."]}]}
输入片段：
"""

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<div class="sc-card">
  <div class="sc-idea-core" data-segment-ids="{{ plan.coreSegmentIds|join(',') }}">{{ plan.coreIdea }}</div>
  {% for point in plan.points %}
  <div class="sc-point-row" data-segment-ids="{{ point.segmentIds|join(',') }}">
    <span class="sc-point-marker">▸</span>
    <span class="sc-label">{{ point.text }}</span>
  </div>
  {% endfor %}
</div>
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 条要点未展示</div>{% endif %}
{% endblock %}
"""


class _Point(StrictModel):
    text: str = Field(min_length=1)
    segmentIds: List[str] = Field(min_length=1)


class _MemoPlan(StrictModel):
    chartType: Literal["idea_card"]
    title: str = Field(min_length=1)
    coreIdea: str = Field(min_length=1)
    coreSegmentIds: List[str] = Field(default_factory=list)
    points: List[_Point] = Field(default_factory=list)
    truncatedCount: int = 0


class MemoSkill(BaseSkill):
    content_type = "memo"
    chart_type = "idea_card"
    display_name = "灵感要点卡"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _MemoPlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"memo plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        points = []
        for point in model.points:
            ids = filter_known_segment_ids(point.segmentIds, segment_map)
            if ids:
                points.append({"text": point.text, "segmentIds": ids})
        # 核心想法的来源：LLM 给的 coreSegmentIds → 否则要点 id 并集 → 否则首片段（保证渲染可溯源）
        core_ids = filter_known_segment_ids(model.coreSegmentIds, segment_map)
        if not core_ids:
            core_ids = list(dict.fromkeys(sid for point in points for sid in point["segmentIds"]))
        if not core_ids and source_segments:
            core_ids = [source_segments[0]["id"]]
        return {
            "chartType": "idea_card",
            "title": model.title,
            "coreIdea": model.coreIdea,
            "coreSegmentIds": core_ids,
            "points": points,
            "truncatedCount": model.truncatedCount,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "随手记要点")
        core_idea = next((p["coreIdea"] for p in plans if p.get("coreIdea")), "")
        core_ids = next((p.get("coreSegmentIds") for p in plans if p.get("coreSegmentIds")), [])
        seen, points = set(), []
        for plan in plans:
            for point in plan.get("points", []):
                key = normalize_text(point["text"])
                if key and key not in seen:
                    seen.add(key)
                    points.append(point)
        truncated = max(0, len(points) - MAX_POINTS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "idea_card",
            "title": title,
            "coreIdea": core_idea,
            "coreSegmentIds": core_ids,
            "points": points[:MAX_POINTS],
            "truncatedCount": truncated,
        }

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        return not plan.get("coreIdea") and not plan.get("points")

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        errors = []
        if not plan.get("coreIdea"):
            errors.append("memo 缺少核心想法")
        elif not numbers_have_evidence(plan["coreIdea"], plan.get("coreSegmentIds") or [], segment_map):
            errors.append("核心想法数字与原文不符")
        for index, point in enumerate(plan.get("points", [])):
            ids = point.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"要点{index + 1}缺少有效来源片段")
            elif not numbers_have_evidence(point["text"], ids, segment_map):
                errors.append(f"要点{index + 1}数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        if not plan.get("coreIdea"):
            return None
        if not numbers_have_evidence(plan["coreIdea"], plan.get("coreSegmentIds") or [], segment_map):
            return None
        points = [
            p for p in plan.get("points", [])
            if filter_known_segment_ids(p.get("segmentIds"), segment_map)
            and numbers_have_evidence(p["text"], p["segmentIds"], segment_map)
        ]
        return {**plan, "points": points, "truncatedCount": 0}

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title)
```

注册（`skills/__init__.py`）：import `MemoSkill`，加入列表：

```python
from .memo import MemoSkill
from .other import OtherSkill

SKILLS: Dict[str, BaseSkill] = {skill.content_type: skill for skill in [MemoSkill(), OtherSkill()]}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/memo.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_skills.py
git commit -m "feat: 随手记 skill——灵感要点卡"
```

---

## Task 7: meeting skill —— 决策行动看板

**Files:**
- Create: `ChartAgent/agent/skills/meeting.py`
- Modify: `ChartAgent/agent/skills/__init__.py`（注册）
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

```python
from agent.skills.meeting import MeetingSkill


def meeting_raw():
    return {
        "chartType": "decision_board",
        "title": "DeepSeek 部署讨论会",
        "topics": [
            {
                "title": "私有化部署方案",
                "conclusion": "当天完成部署并接入知识库问答",
                "actions": [
                    {"text": "提供可外网访问的电脑", "owner": "李老师", "due": "今天"},
                    {"text": "调研语音卡技术参数", "owner": None, "due": None},
                ],
                "segmentIds": ["s1", "s2"],
            },
            {"title": "幽灵议题", "conclusion": None, "actions": [], "segmentIds": ["ghost"]},
        ],
    }


def meeting_source_segments():
    return [
        {"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0,
         "text": "私有化部署方案今天定一下，结论就是当天完成部署并接入知识库问答"},
        {"id": "s2", "speaker": "乙", "startTime": 5.0, "endTime": 10.0,
         "text": "李老师今天提供可外网访问的电脑，另外还要调研语音卡技术参数"},
    ]


class MeetingSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = MeetingSkill()
        self.segment_map = {s["id"]: s for s in meeting_source_segments()}

    def test_normalize_drops_topic_with_only_unknown_ids(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        self.assertEqual(len(plan["topics"]), 1)
        self.assertEqual(plan["topics"][0]["title"], "私有化部署方案")

    def test_validate_passes_legit_plan(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_at_least_one_topic(self):
        plan = {"chartType": "decision_board", "title": "t", "topics": [], "truncatedCount": 0}
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_action_numbers(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["topics"][0]["actions"][0]["text"] = "3 天内提供 5 台电脑"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_merge_caps_topics_at_8(self):
        big = {"chartType": "decision_board", "title": "t", "truncatedCount": 0, "topics": [
            {"title": f"议题{i}", "conclusion": None, "actions": [], "segmentIds": ["s1"]} for i in range(10)
        ]}
        merged = self.skill.merge([big])
        self.assertEqual(len(merged["topics"]), 8)
        self.assertEqual(merged["truncatedCount"], 2)

    def test_render_contains_conclusion_actions_and_segment_ids(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("当天完成部署并接入知识库问答", html)
        self.assertIn("李老师", html)
        self.assertIn('data-segment-ids="s1,s2"', html)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"decision_board"', self.skill.extraction_prompt(meeting_source_segments()))

    def test_merge_same_topic_dedupes_actions_and_unions_ids(self):
        plans = [
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "conclusion": None,
                         "actions": [{"text": "提供电脑", "owner": None, "due": None}],
                         "segmentIds": ["s1"]}]},
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "conclusion": None,
                         "actions": [{"text": "提供电脑", "owner": None, "due": None},
                                     {"text": "提供电脑", "owner": None, "due": None},
                                     {"text": "调研参数", "owner": None, "due": None}],
                         "segmentIds": ["s2"]}]},
        ]
        merged = self.skill.merge(plans)
        self.assertEqual(len(merged["topics"]), 1)
        actions = merged["topics"][0]["actions"]
        self.assertEqual([a["text"] for a in actions], ["提供电脑", "调研参数"])
        self.assertEqual(merged["topics"][0]["segmentIds"], ["s1", "s2"])

    def test_validate_rejects_fabricated_due_numbers(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["topics"][0]["actions"][0]["due"] = "3 天后"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("时间数字" in e for e in errors))

    def test_fallback_strips_fabricated_due_keeps_action(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["topics"][0]["actions"][0]["due"] = "3 天后"
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        action = salvaged["topics"][0]["actions"][0]
        self.assertEqual(action["text"], "提供可外网访问的电脑")
        self.assertIsNone(action["due"])

    def test_fallback_resets_truncated_count(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["truncatedCount"] = 4
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["truncatedCount"], 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.MeetingSkillTests -v`
Expected: FAIL（`No module named 'agent.skills.meeting'`）

- [ ] **Step 3: 实现 meeting.py**

```python
"""meeting skill：会议 → 决策行动看板。议题 → 结论 + 行动项（负责人/截止时间）。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence
from .base import BaseSkill

MAX_TOPICS = 8
MAX_ACTIONS_PER_TOPIC = 6

_PROMPT = """你是会议内容结构化提取器。从会议转写片段中提取议题、结论与行动项。
要求：
1. topics：按议题组织，每个议题 title 不超过 16 字。
2. conclusion：该议题达成的结论；原文没有明确结论时为 null。
3. actions：行动项（任务/分工/截止时间），text 不超过 25 字；owner（负责人）与 due（时间）仅当原文明确时填写，否则为 null。行动项必须有原文依据（如"负责""完成""提供""对接""下周前"等表述）。
4. 每个议题必须携带来源 segmentIds（只用输入片段中的 id）。
5. 禁止编造原文没有的内容。
只输出严格 JSON：
{"chartType":"decision_board","title":"<会议主题，≤20字>","topics":[{"title":"...","conclusion":null,"actions":[{"text":"...","owner":null,"due":null}],"segmentIds":["..."]}]}
输入片段：
"""

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
{% for topic in plan.topics %}
<div class="sc-card sc-topic-card" data-segment-ids="{{ topic.segmentIds|join(',') }}">
  <div class="sc-topic-title">{{ topic.title }}</div>
  {% if topic.conclusion %}
  <div class="sc-conclusion"><span class="sc-conclusion-label">结论</span><span>{{ topic.conclusion }}</span></div>
  {% endif %}
  {% for action in topic.actions %}
  <div class="sc-action-row">
    <span class="sc-action-text">{{ action.text }}</span>
    {% if action.owner %}<span class="sc-badge sc-badge-owner">{{ action.owner }}</span>{% endif %}
    {% if action.due %}<span class="sc-badge sc-badge-due">{{ action.due }}</span>{% endif %}
  </div>
  {% endfor %}
</div>
{% endfor %}
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 个议题未展示</div>{% endif %}
{% endblock %}
"""


class _Action(StrictModel):
    text: str = Field(min_length=1)
    owner: Optional[str] = None
    due: Optional[str] = None


class _Topic(StrictModel):
    title: str = Field(min_length=1)
    conclusion: Optional[str] = None
    actions: List[_Action] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)


class _MeetingPlan(StrictModel):
    chartType: Literal["decision_board"]
    title: str = Field(min_length=1)
    topics: List[_Topic] = Field(default_factory=list)
    truncatedCount: int = 0


class MeetingSkill(BaseSkill):
    content_type = "meeting"
    chart_type = "decision_board"
    display_name = "决策行动看板"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _MeetingPlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"meeting plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        topics = []
        for topic in model.topics:
            ids = filter_known_segment_ids(topic.segmentIds, segment_map)
            if not ids:
                continue
            topics.append({
                "title": topic.title,
                "conclusion": topic.conclusion,
                "actions": [
                    {"text": a.text, "owner": a.owner, "due": a.due}
                    for a in topic.actions[:MAX_ACTIONS_PER_TOPIC]
                ],
                "segmentIds": ids,
            })
        return {
            "chartType": "decision_board",
            "title": model.title,
            "topics": topics,
            "truncatedCount": model.truncatedCount,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "会议要点")
        seen, topics = set(), []
        for plan in plans:
            for topic in plan.get("topics", []):
                key = normalize_text(topic["title"])
                if not key:
                    continue
                if key in seen:
                    # 同议题合并：补充新行动项与来源
                    existing = next(t for t in topics if normalize_text(t["title"]) == key)
                    known_actions = {normalize_text(a["text"]) for a in existing["actions"]}
                    for action in topic.get("actions", []):
                        if normalize_text(action["text"]) not in known_actions and len(existing["actions"]) < MAX_ACTIONS_PER_TOPIC:
                            existing["actions"].append(action)
                            known_actions.add(normalize_text(action["text"]))
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + topic.get("segmentIds", [])))
                    continue
                seen.add(key)
                topics.append(topic)
        truncated = max(0, len(topics) - MAX_TOPICS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "decision_board",
            "title": title,
            "topics": topics[:MAX_TOPICS],
            "truncatedCount": truncated,
        }

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        return not plan.get("topics")

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        topics = plan.get("topics") or []
        if not topics:
            return ["meeting 需要至少一个议题"]
        errors = []
        for index, topic in enumerate(topics):
            ids = topic.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"议题{index + 1}缺少有效来源片段")
                continue
            if not numbers_have_evidence(topic.get("title"), ids, segment_map):
                errors.append(f"议题{index + 1}标题数字与原文不符")
            if topic.get("conclusion") and not numbers_have_evidence(topic["conclusion"], ids, segment_map):
                errors.append(f"议题{index + 1}结论数字与原文不符")
            for action_index, action in enumerate(topic.get("actions", [])):
                if not numbers_have_evidence(action.get("text"), ids, segment_map):
                    errors.append(f"议题{index + 1}行动项{action_index + 1}数字与原文不符")
                if action.get("due") and not numbers_have_evidence(action["due"], ids, segment_map):
                    errors.append(f"议题{index + 1}行动项{action_index + 1}时间数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        topics = []
        for topic in plan.get("topics", []):
            ids = topic.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                continue
            if not numbers_have_evidence(topic.get("title"), ids, segment_map):
                continue
            conclusion = topic.get("conclusion")
            if conclusion and not numbers_have_evidence(conclusion, ids, segment_map):
                conclusion = None
            actions = [
                {
                    "text": a["text"],
                    "owner": a.get("owner"),
                    "due": a.get("due") if a.get("due") and numbers_have_evidence(a["due"], ids, segment_map) else None,
                }
                for a in topic.get("actions", [])
                if numbers_have_evidence(a.get("text"), ids, segment_map)
            ]
            topics.append({**topic, "conclusion": conclusion, "actions": actions})
        if not topics:
            return None
        return {**plan, "topics": topics, "truncatedCount": 0}

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title)
```

注册（`skills/__init__.py`）：import `MeetingSkill`，列表改为 `[MeetingSkill(), MemoSkill(), OtherSkill()]`。

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/meeting.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_skills.py
git commit -m "feat: 会议 skill——决策行动看板"
```

---

## Task 8: interview skill —— 问答观点卡

**Files:**
- Create: `ChartAgent/agent/skills/interview.py`
- Modify: `ChartAgent/agent/skills/__init__.py`（注册）
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

```python
from agent.skills.interview import InterviewSkill


def interview_raw():
    return {
        "chartType": "qa_cards",
        "title": "私有化部署访谈",
        "qas": [
            {
                "question": "为什么坚持私有化部署？",
                "keyAnswer": "数据不能出内网，这是红线",
                "tags": ["数据安全"],
                "segmentIds": ["s2"],
            },
            {
                "question": "未来会扩展吗？",
                "keyAnswer": "先做 5-6 人的盒子试点",
                "tags": ["扩展", "试点"],
                "segmentIds": ["s4"],
            },
        ],
    }


def interview_source_segments():
    return [
        {"id": "s1", "speaker": "采访者", "startTime": 0.0, "endTime": 5.0, "text": "为什么坚持私有化部署？"},
        {"id": "s2", "speaker": "被访者", "startTime": 5.0, "endTime": 10.0, "text": "数据不能出内网，这是红线，云上大模型再便宜也不用"},
        {"id": "s3", "speaker": "采访者", "startTime": 10.0, "endTime": 15.0, "text": "未来会扩展吗？"},
        {"id": "s4", "speaker": "被访者", "startTime": 15.0, "endTime": 20.0, "text": "先做 5-6 人的盒子试点，稳定后再推广"},
    ]


class InterviewSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = InterviewSkill()
        self.segment_map = {s["id"]: s for s in interview_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_verbatim_key_answer(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["keyAnswer"] = "数据绝对不能出内网哦"  # 非原文逐字
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e for e in errors))

    def test_validate_requires_two_qa_pairs(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"] = plan["qas"][:1]
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_merge_caps_at_10(self):
        big = {"chartType": "qa_cards", "title": "t", "truncatedCount": 0, "qas": [
            {"question": f"问题{i}？", "keyAnswer": "数据不能出内网，这是红线", "tags": [], "segmentIds": ["s2"]}
            for i in range(12)
        ]}
        merged = self.skill.merge([big])
        self.assertEqual(len(merged["qas"]), 10)
        self.assertEqual(merged["truncatedCount"], 2)

    def test_render_contains_question_answer_tags(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("为什么坚持私有化部署？", html)
        self.assertIn("数据不能出内网，这是红线", html)
        self.assertIn("数据安全", html)
        self.assertIn('data-segment-ids="s2"', html)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"qa_cards"', self.skill.extraction_prompt(interview_source_segments()))

    def test_fallback_resets_truncated_count(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["truncatedCount"] = 3
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["truncatedCount"], 0)

    def test_validate_rejects_numeric_distortion_in_key_answer(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][1]["keyAnswer"] = "先做 56 人的盒子试点"  # 5-6 → 56 数字扭曲
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_fallback_drops_question_with_fabricated_numbers(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["question"] = "未来会扩展到 99 人吗？"
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNone(salvaged)  # 只剩 1 个问答 → 不满足进入条件

    def test_fallback_rebuilds_filtered_segment_ids(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["segmentIds"] = ["s2", "forged"]
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["qas"][0]["segmentIds"], ["s2"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.InterviewSkillTests -v`
Expected: FAIL（`No module named 'agent.skills.interview'`）

- [ ] **Step 3: 实现 interview.py**

```python
"""interview skill：访谈 → 问答观点卡。问题 + 被访者原话金句 + 关键词标签。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence, text_has_evidence
from .base import BaseSkill

MAX_QAS = 10
MAX_TAGS = 3

_PROMPT = """你是访谈内容结构化提取器。从访谈转写中提取问答对。
要求：
1. qas：每个问答对包含 question（采访者的问题，≤20字，可为转述）、keyAnswer（被访者的核心回答，必须是原文原句，≤50字，必要时截取）、tags（1-3 个关键词）。
2. 每个问答对必须携带来源 segmentIds（只用输入片段中的 id）。
3. keyAnswer 必须逐字来自原文，禁止改写。
只输出严格 JSON：
{"chartType":"qa_cards","title":"<访谈主题，≤20字>","qas":[{"question":"...","keyAnswer":"...","tags":["..."],"segmentIds":["..."]}]}
输入片段：
"""

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
{% for qa in plan.qas %}
<div class="sc-card sc-qa-card" data-segment-ids="{{ qa.segmentIds|join(',') }}">
  <div class="sc-qa-question">Q：{{ qa.question }}</div>
  <div class="sc-qa-answer">&ldquo;{{ qa.keyAnswer }}&rdquo;</div>
  {% if qa.tags %}
  <div class="sc-qa-tags">{% for tag in qa.tags %}<span class="sc-tag">{{ tag }}</span>{% endfor %}</div>
  {% endif %}
</div>
{% endfor %}
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 个问答未展示</div>{% endif %}
{% endblock %}
"""


class _QA(StrictModel):
    question: str = Field(min_length=1)
    keyAnswer: str = Field(min_length=1)
    tags: List[str] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)


class _InterviewPlan(StrictModel):
    chartType: Literal["qa_cards"]
    title: str = Field(min_length=1)
    qas: List[_QA] = Field(default_factory=list)
    truncatedCount: int = 0


class InterviewSkill(BaseSkill):
    content_type = "interview"
    chart_type = "qa_cards"
    display_name = "问答观点卡"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _InterviewPlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"interview plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        qas = []
        for qa in model.qas:
            ids = filter_known_segment_ids(qa.segmentIds, segment_map)
            if ids:
                qas.append({
                    "question": qa.question,
                    "keyAnswer": qa.keyAnswer,
                    "tags": qa.tags[:MAX_TAGS],
                    "segmentIds": ids,
                })
        return {
            "chartType": "qa_cards",
            "title": model.title,
            "qas": qas,
            "truncatedCount": model.truncatedCount,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "访谈要点")
        seen, qas = set(), []
        for plan in plans:
            for qa in plan.get("qas", []):
                key = normalize_text(qa["question"])
                if key and key not in seen:
                    seen.add(key)
                    qas.append(qa)
        truncated = max(0, len(qas) - MAX_QAS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "qa_cards",
            "title": title,
            "qas": qas[:MAX_QAS],
            "truncatedCount": truncated,
        }

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        return len(plan.get("qas") or []) < 2

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        qas = plan.get("qas") or []
        if len(qas) < 2:
            return ["interview 需要至少两个问答对"]
        errors = []
        for index, qa in enumerate(qas):
            ids = qa.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"问答{index + 1}缺少有效来源片段")
                continue
            if not text_has_evidence(qa.get("keyAnswer"), ids, segment_map):
                errors.append(f"问答{index + 1}的回答必须逐字来自原文")
            elif not numbers_have_evidence(qa.get("keyAnswer"), ids, segment_map):
                errors.append(f"问答{index + 1}的回答数字与原文不符")
            if not numbers_have_evidence(qa.get("question"), ids, segment_map):
                errors.append(f"问答{index + 1}问题数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        qas = []
        for qa in plan.get("qas", []):
            ids = filter_known_segment_ids(qa.get("segmentIds"), segment_map)
            if not ids:
                continue
            if not text_has_evidence(qa.get("keyAnswer"), ids, segment_map):
                continue
            if not numbers_have_evidence(qa.get("keyAnswer"), ids, segment_map):
                continue
            if not numbers_have_evidence(qa.get("question"), ids, segment_map):
                continue
            qas.append({**qa, "segmentIds": ids})
        if len(qas) < 2:
            return None
        return {**plan, "qas": qas, "truncatedCount": 0}

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title)
```

注册（`skills/__init__.py`）：import `InterviewSkill`，列表改为 `[InterviewSkill(), MeetingSkill(), MemoSkill(), OtherSkill()]`。

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/interview.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_skills.py
git commit -m "feat: 访谈 skill——问答观点卡"
```

---

## Task 9: lecture skill —— 知识大纲树（SVG 树布局）

**Files:**
- Create: `ChartAgent/agent/skills/lecture.py`
- Modify: `ChartAgent/agent/skills/__init__.py`（注册）
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

```python
from agent.skills.lecture import LectureSkill


def lecture_raw():
    return {
        "chartType": "knowledge_tree",
        "title": "Transformer 原理精讲",
        "topic": "Transformer 原理",
        "chapters": [
            {
                "title": "注意力机制",
                "concepts": [
                    {"name": "QKV 计算", "note": "查询键值三路投影", "segmentIds": ["s1"]},
                    {"name": "多头注意力", "note": None, "segmentIds": ["s1"]},
                ],
                "segmentIds": ["s1"],
            },
            {
                "title": "位置编码",
                "concepts": [{"name": "正弦编码", "note": "用 sin/cos 表示位置", "segmentIds": ["s2"]}],
                "segmentIds": ["s2"],
            },
        ],
    }


def lecture_source_segments():
    return [
        {"id": "s1", "speaker": "讲师", "startTime": 0.0, "endTime": 30.0,
         "text": "先讲注意力机制，核心是 QKV 计算，也就是查询键值三路投影，还有多头注意力"},
        {"id": "s2", "speaker": "讲师", "startTime": 30.0, "endTime": 60.0,
         "text": "第二个概念是位置编码，正弦编码用 sin 和 cos 表示位置"},
    ]


class LectureSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = LectureSkill()
        self.segment_map = {s["id"]: s for s in lecture_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_entry_condition(self):
        # 只有一章一概念 → 不满足进入条件
        raw = lecture_raw()
        raw["chapters"] = [raw["chapters"][1]]
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_concept_numbers(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        plan["chapters"][0]["concepts"][0]["name"] = "3 层注意力机制"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_merge_caps_chapters_at_8(self):
        big = {"chartType": "knowledge_tree", "title": "t", "topic": "t", "truncatedCount": 0, "chapters": [
            {"title": f"章{i}", "concepts": [{"name": f"概念{i}", "note": None, "segmentIds": ["s1"]}], "segmentIds": ["s1"]}
            for i in range(10)
        ]}
        merged = self.skill.merge([big])
        self.assertEqual(len(merged["chapters"]), 8)
        self.assertEqual(merged["truncatedCount"], 2)

    def test_layout_positions_are_deterministic(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        layout_a = self.skill.layout_tree(plan["chapters"])
        layout_b = self.skill.layout_tree(plan["chapters"])
        self.assertEqual(layout_a, layout_b)
        self.assertEqual(len(layout_a["chapters"]), 2)
        # 每章有一条 root→chapter 边，每个概念一条 chapter→concept 边
        self.assertEqual(len(layout_a["edges"]), 2 + 3)

    def test_render_svg_contains_nodes_and_segment_ids(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("<svg", html)
        self.assertIn("注意力机制", html)
        self.assertIn("QKV 计算", html)
        self.assertIn('data-segment-ids="s1"', html)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"knowledge_tree"', self.skill.extraction_prompt(lecture_source_segments()))

    def test_normalize_counts_dropped_concepts_in_truncated_count(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"] = raw["chapters"][0]["concepts"] + [
            {"name": f"额外概念{i}", "note": None, "segmentIds": ["s1"]} for i in range(5)
        ]  # 2 + 5 = 7 个概念，超出上限 6 → 丢弃 1
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["chapters"][0]["concepts"]), 6)
        self.assertEqual(plan["truncatedCount"], 1)

    def test_normalize_truncates_overlong_strings(self):
        raw = lecture_raw()
        raw["topic"] = "这是一个非常非常非常长的讲座主题名称"  # 17 字 → 截到 16
        raw["chapters"][0]["title"] = "这是一个非常非常长的章节标题"  # 14 字 → 截到 12
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["topic"]), 16)
        self.assertEqual(len(plan["chapters"][0]["title"]), 12)

    def test_validate_rejects_fabricated_topic_numbers(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        plan["topic"] = "2024 年 Transformer 原理"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("主题" in e for e in errors))

    def test_fallback_returns_none_when_topic_numbers_fabricated(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        plan["topic"] = "2024 年 Transformer 原理"
        self.assertIsNone(self.skill.fallback(plan, self.segment_map))

    def test_layout_bounds_at_max_capacity(self):
        chapters = [
            {"title": f"章{i}", "concepts": [{"name": f"概念{j}", "note": None, "segmentIds": ["s1"]} for j in range(6)], "segmentIds": ["s1"]}
            for i in range(8)
        ]
        layout = self.skill.layout_tree(chapters)
        for chapter in layout["chapters"]:
            self.assertLessEqual(chapter["x"] + chapter["w"], layout["width"])
            for concept in chapter["concepts"]:
                self.assertLessEqual(concept["y"] + concept["h"], layout["height"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.LectureSkillTests -v`
Expected: FAIL（`No module named 'agent.skills.lecture'`）

- [ ] **Step 3: 实现 lecture.py**

```python
"""lecture skill：讲座 → 知识大纲树。主题 → 章节 → 概念三级结构，SVG 树布局由 Python 计算。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence
from .base import BaseSkill

MAX_CHAPTERS = 8
MAX_CONCEPTS_PER_CHAPTER = 6

_PROMPT = """你是讲座内容结构化提取器。把讲座转写整理为三级知识结构。
要求：
1. topic：讲座主题（≤16字）。
2. chapters：章节列表，每章 title ≤12字；concepts 为该章的概念要点，name ≤12字，note 为一句话解释（≤25字，可为 null）。
3. 每章、每个概念都必须携带来源 segmentIds（只用输入片段中的 id）。
4. 只提取原文明确讲到的知识内容，禁止补充原文没有的知识。
只输出严格 JSON：
{"chartType":"knowledge_tree","title":"<讲座主题>","topic":"...","chapters":[{"title":"...","concepts":[{"name":"...","note":null,"segmentIds":["..."]}],"segmentIds":["..."]}]}
输入片段：
"""

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<svg viewBox="0 0 {{ layout.width|int }} {{ layout.height|int }}" width="100%" role="img" aria-label="知识大纲树">
  {% for edge in layout.edges %}
  <line x1="{{ '%.1f'|format(edge.x1) }}" y1="{{ '%.1f'|format(edge.y1) }}" x2="{{ '%.1f'|format(edge.x2) }}" y2="{{ '%.1f'|format(edge.y2) }}" stroke="#475569" stroke-width="1.5"/>
  {% endfor %}
  <rect x="{{ '%.1f'|format(layout.root.x) }}" y="{{ layout.root.y }}" width="{{ layout.root.w|int }}" height="{{ layout.root.h|int }}" rx="10" fill="#7c3aed"/>
  <text x="{{ '%.1f'|format(layout.root.x + layout.root.w / 2) }}" y="{{ layout.root.y + 24 }}" text-anchor="middle" fill="#ffffff" font-size="14" font-weight="600">{{ plan.topic }}</text>
  {% for chapter in layout.chapters %}
  <g data-segment-ids="{{ chapter.segmentIds|join(',') }}" style="cursor:pointer">
    <rect x="{{ '%.1f'|format(chapter.x) }}" y="{{ chapter.y|int }}" width="{{ chapter.w|int }}" height="{{ chapter.h|int }}" rx="8" fill="#1E1E2E" stroke="#7c3aed" stroke-width="1.5"/>
    <text x="{{ '%.1f'|format(chapter.x + chapter.w / 2) }}" y="{{ chapter.y + 22 }}" text-anchor="middle" fill="#c4b5fd" font-size="12">{{ chapter.title }}</text>
  </g>
  {% for concept in chapter.concepts %}
  <g data-segment-ids="{{ concept.segmentIds|join(',') }}" style="cursor:pointer">
    <rect x="{{ '%.1f'|format(concept.x) }}" y="{{ '%.1f'|format(concept.y) }}" width="{{ concept.w|int }}" height="{{ concept.h|int }}" rx="6" fill="#16162a" stroke="#334155"/>
    <text x="{{ '%.1f'|format(concept.x + concept.w / 2) }}" y="{{ '%.1f'|format(concept.y + 16) }}" text-anchor="middle" fill="#94a3b8" font-size="10">{{ concept.name }}</text>
  </g>
  {% endfor %}
  {% endfor %}
</svg>
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 项未展示</div>{% endif %}
{% endblock %}
"""


class _Concept(StrictModel):
    name: str = Field(min_length=1)
    note: Optional[str] = None
    segmentIds: List[str] = Field(min_length=1)


class _Chapter(StrictModel):
    title: str = Field(min_length=1)
    concepts: List[_Concept] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)


class _LecturePlan(StrictModel):
    chartType: Literal["knowledge_tree"]
    title: str = Field(min_length=1)
    topic: str = Field(min_length=1)
    chapters: List[_Chapter] = Field(default_factory=list)
    truncatedCount: int = 0


class LectureSkill(BaseSkill):
    content_type = "lecture"
    chart_type = "knowledge_tree"
    display_name = "知识大纲树"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _LecturePlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"lecture plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        chapters = []
        dropped_concepts = 0
        for chapter in model.chapters:
            ids = filter_known_segment_ids(chapter.segmentIds, segment_map)
            if not ids:
                dropped_concepts += len(chapter.concepts)
                continue
            concepts = []
            for concept in chapter.concepts[:MAX_CONCEPTS_PER_CHAPTER]:
                concept_ids = filter_known_segment_ids(concept.segmentIds, segment_map)
                if concept_ids:
                    concepts.append({"name": concept.name[:12], "note": concept.note, "segmentIds": concept_ids})
            dropped_concepts += len(chapter.concepts) - len(concepts)
            chapters.append({"title": chapter.title[:12], "concepts": concepts, "segmentIds": ids})
        return {
            "chartType": "knowledge_tree",
            "title": model.title,
            "topic": model.topic[:16],
            "chapters": chapters,
            "truncatedCount": model.truncatedCount + dropped_concepts,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "讲座大纲")
        topic = next((p["topic"] for p in plans if p.get("topic")), title)
        seen, chapters = set(), []
        for plan in plans:
            for chapter in plan.get("chapters", []):
                key = normalize_text(chapter["title"])
                if key and key not in seen:
                    seen.add(key)
                    chapters.append(chapter)
        truncated = max(0, len(chapters) - MAX_CHAPTERS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "knowledge_tree",
            "title": title,
            "topic": topic,
            "chapters": chapters[:MAX_CHAPTERS],
            "truncatedCount": truncated,
        }

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        chapters = plan.get("chapters") or []
        return len(chapters) < 2 and not (len(chapters) == 1 and len(chapters[0].get("concepts", [])) >= 2)

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        chapters = plan.get("chapters") or []
        if len(chapters) < 2 and not (len(chapters) == 1 and len(chapters[0].get("concepts", [])) >= 2):
            return ["lecture 需要至少两章，或一章包含至少两个概念"]
        errors = []
        all_ids = list(dict.fromkeys(sid for chapter in chapters for sid in (chapter.get("segmentIds") or [])))
        if not numbers_have_evidence(plan.get("topic"), all_ids, segment_map):
            errors.append("主题数字与原文不符")
        for index, chapter in enumerate(chapters):
            ids = chapter.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"章节{index + 1}缺少有效来源片段")
                continue
            if not numbers_have_evidence(chapter.get("title"), ids, segment_map):
                errors.append(f"章节{index + 1}标题数字与原文不符")
            for concept in chapter.get("concepts", []):
                concept_ids = concept.get("segmentIds") or []
                if not filter_known_segment_ids(concept_ids, segment_map):
                    errors.append(f"章节{index + 1}概念「{concept.get('name', '?')}」缺少有效来源片段")
                elif not numbers_have_evidence(concept.get("name"), concept_ids, segment_map):
                    errors.append(f"章节{index + 1}概念「{concept.get('name', '?')}」数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        all_ids = list(dict.fromkeys(sid for chapter in plan.get("chapters", []) for sid in (chapter.get("segmentIds") or [])))
        if not numbers_have_evidence(plan.get("topic"), all_ids, segment_map):
            return None
        chapters = []
        for chapter in plan.get("chapters", []):
            ids = filter_known_segment_ids(chapter.get("segmentIds"), segment_map)
            if not ids:
                continue
            if not numbers_have_evidence(chapter.get("title"), ids, segment_map):
                continue
            concepts = [
                {**c, "segmentIds": filter_known_segment_ids(c.get("segmentIds"), segment_map)}
                for c in chapter.get("concepts", [])
                if filter_known_segment_ids(c.get("segmentIds"), segment_map)
                and numbers_have_evidence(c.get("name"), c["segmentIds"], segment_map)
            ]
            chapters.append({**chapter, "concepts": concepts, "segmentIds": ids})
        if len(chapters) < 2 and not (len(chapters) == 1 and len(chapters[0]["concepts"]) >= 2):
            return None
        return {**plan, "chapters": chapters, "truncatedCount": 0}

    # ---- SVG 布局（确定性几何）----
    @staticmethod
    def layout_tree(chapters: List[Dict[str, Any]]) -> Dict[str, Any]:
        node_w, node_h, gap_x = 150.0, 34.0, 16.0
        root_w, root_h = 236.0, 38.0
        concept_h, concept_gap = 24.0, 8.0
        top_y, chapter_y = 16.0, 84.0
        count = max(len(chapters), 1)
        width = max(620.0, count * (node_w + gap_x) + gap_x)
        root = {"x": width / 2 - root_w / 2, "y": top_y, "w": root_w, "h": root_h}
        laid_chapters, edges = [], []
        max_concepts = 1
        for index, chapter in enumerate(chapters):
            cx = gap_x + index * (node_w + gap_x)
            concepts = chapter.get("concepts", [])[:MAX_CONCEPTS_PER_CHAPTER]
            max_concepts = max(max_concepts, len(concepts))
            edges.append({"x1": width / 2, "y1": top_y + root_h, "x2": cx + node_w / 2, "y2": chapter_y})
            laid_concepts = []
            for ci, concept in enumerate(concepts):
                concept_y = chapter_y + node_h + 14 + ci * (concept_h + concept_gap)
                edges.append({"x1": cx + node_w / 2, "y1": chapter_y + node_h, "x2": cx + node_w / 2, "y2": concept_y})
                laid_concepts.append({
                    "x": cx, "y": concept_y, "w": node_w, "h": concept_h,
                    "name": concept["name"], "segmentIds": concept.get("segmentIds", []),
                })
            laid_chapters.append({
                "x": cx, "y": chapter_y, "w": node_w, "h": node_h,
                "title": chapter["title"], "segmentIds": chapter.get("segmentIds", []),
                "concepts": laid_concepts,
            })
        height = chapter_y + node_h + 14 + max_concepts * (concept_h + concept_gap) + 24
        return {"width": width, "height": height, "root": root, "chapters": laid_chapters, "edges": edges}

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        layout = self.layout_tree(plan.get("chapters", []))
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title, layout=layout)
```

注册（`skills/__init__.py`）：import `LectureSkill`，列表改为 `[InterviewSkill(), LectureSkill(), MeetingSkill(), MemoSkill(), OtherSkill()]`。

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/lecture.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_skills.py
git commit -m "feat: 讲座 skill——知识大纲树（SVG 树布局）"
```

---

## Task 10: dialogue skill —— 话题泳道图（SVG 泳道布局）

**Files:**
- Create: `ChartAgent/agent/skills/dialogue.py`
- Modify: `ChartAgent/agent/skills/__init__.py`（注册）
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

```python
from agent.skills.dialogue import DialogueSkill


def dialogue_raw():
    return {
        "chartType": "topic_swimlane",
        "title": "方案讨论",
        "speakers": ["甲", "乙"],
        "blocks": [
            {"speaker": "甲", "topic": "预算", "summary": "预算有限", "start": 0.0, "end": 10.0, "segmentIds": ["s1"]},
            {"speaker": "乙", "topic": "预算回应", "summary": None, "start": 10.0, "end": 20.0, "segmentIds": ["s2"]},
            {"speaker": "甲", "topic": "进度", "summary": "下周推进", "start": 20.0, "end": 30.0, "segmentIds": ["s3"]},
        ],
    }


def dialogue_source_segments():
    return [
        {"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 10.0, "text": "预算确实有限，要省着点用"},
        {"id": "s2", "speaker": "乙", "startTime": 10.0, "endTime": 20.0, "text": "预算这边我来想办法协调"},
        {"id": "s3", "speaker": "甲", "startTime": 20.0, "endTime": 30.0, "text": "那进度我们下周继续推进"},
    ]


class DialogueSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = DialogueSkill()
        self.segment_map = {s["id"]: s for s in dialogue_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_two_speakers_and_three_blocks(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"] = plan["blocks"][:2]
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_block_time_outside_source(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"][0]["start"] = 99.0
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_summary_numbers(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"][0]["summary"] = "预算砍了 30%"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("摘要" in e and "数字" in e for e in errors))

    def test_normalize_merges_overflow_speakers_into_others(self):
        raw = dialogue_raw()
        raw["speakers"] = ["甲", "乙", "丙", "丁", "戊"]
        raw["blocks"].append({"speaker": "戊", "topic": "补充", "summary": None, "start": 30.0, "end": 40.0, "segmentIds": ["s3"]})
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(len(plan["speakers"]), 4)
        self.assertIn("其他人", plan["speakers"])
        self.assertEqual(plan["blocks"][-1]["speaker"], "其他人")

    def test_layout_is_deterministic_and_within_bounds(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        layout = self.skill.layout_swimlane(plan["speakers"], plan["blocks"])
        for block in layout["blocks"]:
            self.assertGreaterEqual(block["x"], 90.0)
            self.assertLessEqual(block["x"] + block["w"], layout["width"] - 20.0 + 0.01)

    def test_render_svg_contains_lanes_blocks_and_segment_ids(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("<svg", html)
        self.assertIn("预算", html)
        self.assertIn('data-segment-ids="s2"', html)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"topic_swimlane"', self.skill.extraction_prompt(dialogue_source_segments()))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.DialogueSkillTests -v`
Expected: FAIL（`No module named 'agent.skills.dialogue'`）

- [ ] **Step 3: 实现 dialogue.py**

```python
"""dialogue skill：对话 → 话题泳道图。说话人泳道 × 时间轴上的话题块。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, format_mmss, normalize_text, numbers_have_evidence
from .base import BaseSkill

MAX_SPEAKERS = 4
MAX_BLOCKS = 20
OTHERS_LABEL = "其他人"

_PROMPT = """你是对话内容结构化提取器。把多人自由讨论整理为话题块。
要求：
1. speakers：说话人列表（使用片段中的 speaker 字段原值）。
2. blocks：话题块，包含 speaker（该话题的主导人）、topic（话题名，≤10字）、summary（一句话，≤20字，可为 null）、start/end（该话题的起止时间，秒，来自片段时间）、segmentIds。
3. 话题块按时间顺序排列；只提取明确出现的话题，禁止臆测。
只输出严格 JSON：
{"chartType":"topic_swimlane","title":"<对话主题，≤20字>","speakers":["..."],"blocks":[{"speaker":"...","topic":"...","summary":null,"start":0.0,"end":0.0,"segmentIds":["..."]}]}
输入片段：
"""

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<svg viewBox="0 0 {{ layout.width|int }} {{ layout.height|int }}" width="100%" role="img" aria-label="话题泳道图">
  {% for lane in layout.lanes %}
  <text x="12" y="{{ '%.1f'|format(lane.y + 40) }}" fill="{{ lane.color }}" font-size="12">{{ lane.name }}</text>
  <line x1="90" y1="{{ '%.1f'|format(lane.y + 32) }}" x2="{{ layout.width|int - 20 }}" y2="{{ '%.1f'|format(lane.y + 32) }}" stroke="#1E1E2E" stroke-width="1"/>
  {% endfor %}
  {% for block in layout.blocks %}
  <g data-segment-ids="{{ block.segmentIds|join(',') }}" style="cursor:pointer">
    <rect x="{{ '%.1f'|format(block.x) }}" y="{{ '%.1f'|format(block.y) }}" width="{{ '%.1f'|format(block.w) }}" height="{{ block.h|int }}" rx="8" fill="{{ block.fill }}"/>
    <text x="{{ '%.1f'|format(block.x + block.w / 2) }}" y="{{ '%.1f'|format(block.y + block.h / 2 + 4) }}" text-anchor="middle" fill="{{ block.textColor }}" font-size="11">{{ block.topic }}</text>
  </g>
  {% endfor %}
  <text x="{{ layout.width|int - 20 }}" y="{{ layout.height|int - 10 }}" text-anchor="end" fill="#64748b" font-size="10">{{ layout.timeLabel }}</text>
</svg>
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 个话题块未展示</div>{% endif %}
{% endblock %}
"""

_LANE_COLORS = ["#164e63", "#3b1f5e", "#5e3a1f", "#1f3a24"]
_LANE_TEXT_COLORS = ["#67e8f9", "#c4b5fd", "#fdba74", "#86efac"]


class _Block(StrictModel):
    speaker: str = Field(min_length=1)
    topic: str = Field(min_length=1)
    summary: Optional[str] = None
    start: float
    end: float
    segmentIds: List[str] = Field(min_length=1)


class _DialoguePlan(StrictModel):
    chartType: Literal["topic_swimlane"]
    title: str = Field(min_length=1)
    speakers: List[str] = Field(default_factory=list)
    blocks: List[_Block] = Field(default_factory=list)
    truncatedCount: int = 0


class DialogueSkill(BaseSkill):
    content_type = "dialogue"
    chart_type = "topic_swimlane"
    display_name = "话题泳道图"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _DialoguePlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"dialogue plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        # 说话人：声明列表 ∪ 块中出现的，保持顺序；超出 MAX_SPEAKERS 合并为「其他人」
        ordered_speakers = list(dict.fromkeys([*model.speakers, *(b.speaker for b in model.blocks)]))
        if len(ordered_speakers) > MAX_SPEAKERS:
            kept = ordered_speakers[:MAX_SPEAKERS - 1] + [OTHERS_LABEL]
        else:
            kept = ordered_speakers
        kept_set = set(kept)
        blocks = []
        for block in model.blocks:
            ids = filter_known_segment_ids(block.segmentIds, segment_map)
            if not ids:
                continue
            start, end = float(block.start), float(block.end)
            if end < start:
                start, end = end, start
            blocks.append({
                "speaker": block.speaker if block.speaker in kept_set else OTHERS_LABEL,
                "topic": block.topic[:10],
                "summary": block.summary,
                "start": start,
                "end": end,
                "segmentIds": ids,
            })
        blocks.sort(key=lambda b: b["start"])
        return {
            "chartType": "topic_swimlane",
            "title": model.title,
            "speakers": kept,
            "blocks": blocks,
            "truncatedCount": model.truncatedCount,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "对话脉络")
        speakers: List[str] = []
        blocks: List[Dict[str, Any]] = []
        for plan in plans:
            for speaker in plan.get("speakers", []):
                if speaker not in speakers:
                    speakers.append(speaker)
            blocks.extend(plan.get("blocks", []))
        if len(speakers) > MAX_SPEAKERS:
            kept = speakers[:MAX_SPEAKERS - 1] + [OTHERS_LABEL]
            kept_set = set(kept)
            blocks = [{**b, "speaker": b["speaker"] if b["speaker"] in kept_set else OTHERS_LABEL} for b in blocks]
            speakers = kept
        seen, deduped = set(), []
        for block in sorted(blocks, key=lambda b: b["start"]):
            key = (block["speaker"], normalize_text(block["topic"]), round(block["start"]))
            if key not in seen:
                seen.add(key)
                deduped.append(block)
        truncated = max(0, len(deduped) - MAX_BLOCKS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "topic_swimlane",
            "title": title,
            "speakers": speakers,
            "blocks": deduped[:MAX_BLOCKS],
            "truncatedCount": truncated,
        }

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        return len(plan.get("speakers") or []) < 2 or len(plan.get("blocks") or []) < 3

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        speakers = plan.get("speakers") or []
        blocks = plan.get("blocks") or []
        if len(speakers) < 2 or len(blocks) < 3:
            return ["dialogue 需要至少两个说话人和三个话题块"]
        errors = []
        speaker_set = set(speakers)
        for index, block in enumerate(blocks):
            if block.get("speaker") not in speaker_set:
                errors.append(f"话题块{index + 1}说话人不在列表中")
            ids = block.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"话题块{index + 1}缺少有效来源片段")
                continue
            source_starts = [float(segment_map[sid].get("startTime", 0.0)) for sid in ids]
            source_ends = [float(segment_map[sid].get("endTime", 0.0)) for sid in ids]
            block_lo = min(float(block.get("start", 0.0)), float(block.get("end", 0.0)))
            block_hi = max(float(block.get("start", 0.0)), float(block.get("end", 0.0)))
            if block_lo < min(source_starts) - 0.5 or block_hi > max(source_ends) + 0.5:
                errors.append(f"话题块{index + 1}时间超出来源片段范围")
            if not numbers_have_evidence(block.get("topic"), ids, segment_map):
                errors.append(f"话题块{index + 1}话题数字与原文不符")
            if block.get("summary") and not numbers_have_evidence(block["summary"], ids, segment_map):
                errors.append(f"话题块{index + 1}摘要数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        blocks = []
        for block in plan.get("blocks", []):
            ids = filter_known_segment_ids(block.get("segmentIds"), segment_map)
            if not ids:
                continue
            source_starts = [float(segment_map[sid].get("startTime", 0.0)) for sid in ids]
            source_ends = [float(segment_map[sid].get("endTime", 0.0)) for sid in ids]
            block_lo = min(float(block.get("start", 0.0)), float(block.get("end", 0.0)))
            block_hi = max(float(block.get("start", 0.0)), float(block.get("end", 0.0)))
            if block_lo < min(source_starts) - 0.5 or block_hi > max(source_ends) + 0.5:
                continue
            if not numbers_have_evidence(block.get("topic"), ids, segment_map):
                continue
            if block.get("summary") and not numbers_have_evidence(block["summary"], ids, segment_map):
                continue
            blocks.append({**block, "segmentIds": ids})
        if len(plan.get("speakers") or []) < 2 or len(blocks) < 3:
            return None
        return {**plan, "blocks": blocks, "truncatedCount": 0}

    # ---- SVG 布局（确定性几何）----
    @staticmethod
    def layout_swimlane(speakers: List[str], blocks: List[Dict[str, Any]]) -> Dict[str, Any]:
        width, left, right, top, lane_h, block_h = 860.0, 96.0, 20.0, 34.0, 64.0, 40.0
        t0 = min((float(b["start"]) for b in blocks), default=0.0)
        t1 = max((float(b["end"]) for b in blocks), default=1.0)
        span = max(t1 - t0, 1.0)
        scale = (width - left - right) / span
        lane_index = {speaker: i for i, speaker in enumerate(speakers)}
        lanes = [
            {"name": speaker, "y": top + i * lane_h, "color": _LANE_TEXT_COLORS[i % len(_LANE_TEXT_COLORS)]}
            for i, speaker in enumerate(speakers)
        ]
        laid = []
        for index, block in enumerate(blocks):
            x = left + (float(block["start"]) - t0) * scale
            w = max((float(block["end"]) - float(block["start"])) * scale, 96.0)
            if x + w > width - right:
                w = width - right - x
            y = top + lane_index.get(block["speaker"], 0) * lane_h + (lane_h - block_h) / 2
            laid.append({
                **block,
                "x": x, "y": y, "w": w, "h": block_h,
                "fill": _LANE_COLORS[index % len(_LANE_COLORS)],
                "textColor": _LANE_TEXT_COLORS[index % len(_LANE_TEXT_COLORS)],
            })
        height = top + max(len(speakers), 1) * lane_h + 44
        return {
            "width": width,
            "height": height,
            "lanes": lanes,
            "blocks": laid,
            "timeLabel": f"{format_mmss(t0)} – {format_mmss(t1)}",
        }

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        layout = self.layout_swimlane(plan.get("speakers", []), plan.get("blocks", []))
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title, layout=layout)
```

注册（`skills/__init__.py`）：import `DialogueSkill`，列表改为 `[DialogueSkill(), InterviewSkill(), LectureSkill(), MeetingSkill(), MemoSkill(), OtherSkill()]`。

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/dialogue.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_skills.py
git commit -m "feat: 对话 skill——话题泳道图（SVG 泳道布局）"
```

---

## Task 11: speech skill —— 叙事弧线图（SVG 弧线布局）

**Files:**
- Create: `ChartAgent/agent/skills/speech.py`
- Modify: `ChartAgent/agent/skills/__init__.py`（注册）
- Test: `ChartAgent/tests/test_skills.py`（追加）

- [ ] **Step 1: 追加失败测试**

```python
from agent.skills.speech import SpeechSkill


def speech_raw():
    return {
        "chartType": "narrative_arc",
        "title": "改变的力量",
        "stages": [
            {"stage": "opening", "label": "一个故事", "summary": "从个人经历讲起", "quote": None, "segmentIds": ["s1"]},
            {"stage": "buildup", "label": "问题浮现", "summary": "现状有多糟", "quote": None, "segmentIds": ["s2"]},
            {"stage": "climax", "label": "顿悟时刻", "summary": "答案就在眼前", "quote": "改变从今晚开始", "segmentIds": ["s3"]},
            {"stage": "closing", "label": "呼吁行动", "summary": "每个人都可以", "quote": None, "segmentIds": ["s4"]},
        ],
    }


def speech_source_segments():
    return [
        {"id": "s1", "speaker": "演讲者", "startTime": 0.0, "endTime": 30.0, "text": "三年前我经历了一件改变我的事"},
        {"id": "s2", "speaker": "演讲者", "startTime": 30.0, "endTime": 60.0, "text": "你会发现现状比我们想象的更糟糕"},
        {"id": "s3", "speaker": "演讲者", "startTime": 60.0, "endTime": 90.0, "text": "所以我说，改变从今晚开始，就在你我手中"},
        {"id": "s4", "speaker": "演讲者", "startTime": 90.0, "endTime": 120.0, "text": "每个人都可以迈出第一步"},
    ]


class SpeechSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = SpeechSkill()
        self.segment_map = {s["id"]: s for s in speech_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_climax_with_verbatim_quote(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"][2]["quote"] = "改变从明天开始"  # 非原文
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e for e in errors))

    def test_validate_requires_three_stages_including_climax(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"] = [s for s in plan["stages"] if s["stage"] != "climax"]
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_summary_numbers(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"][0]["summary"] = "3 年前亏损 500 万"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("摘要" in e and "数字" in e for e in errors))

    def test_validate_rejects_numeric_distortion_in_climax_quote(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"][2]["quote"] = "改变从今晚 8 点开始"  # 原文无数字 8
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e or "数字" in e for e in errors))

    def test_layout_stage_points_match_canonical_positions(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        layout = self.skill.layout_arc(plan["stages"])
        self.assertEqual(len(layout["points"]), 4)
        climax = next(p for p in layout["points"] if p["stage"] == "climax")
        self.assertEqual((climax["x"], climax["y"]), (560.0, 58.0))
        self.assertGreater(climax["quoteWidth"], 100.0)

    def test_render_svg_contains_arc_quote_and_segment_ids(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("<svg", html)
        self.assertIn("改变从今晚开始", html)
        self.assertIn('data-segment-ids="s3"', html)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"narrative_arc"', self.skill.extraction_prompt(speech_source_segments()))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.SpeechSkillTests -v`
Expected: FAIL（`No module named 'agent.skills.speech'`）

- [ ] **Step 3: 实现 speech.py**

```python
"""speech skill：演讲 → 叙事弧线图。固定四段结构（开场/铺垫/高潮/收尾）映射到固定弧线。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence, text_has_evidence
from .base import BaseSkill

MAX_STAGES = 4

_PROMPT = """你是演讲内容结构化提取器。把演讲转写映射到四段叙事结构。
要求：
1. stages：按 opening（开场）、buildup（铺垫）、climax（高潮）、closing（收尾）四段提取；每段 label（小标题，≤10字）、summary（≤20字）、segmentIds。
2. climax 段必须附 quote：演讲中最有感染力的原句（逐字，≤30字）。
3. 若某段在片段中找不到依据则省略该段，但 climax 不可省略。
只输出严格 JSON：
{"chartType":"narrative_arc","title":"<演讲主题，≤20字>","stages":[{"stage":"opening","label":"...","summary":"...","quote":null,"segmentIds":["..."]}]}
输入片段：
"""

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<svg viewBox="0 0 {{ layout.width|int }} {{ layout.height|int }}" width="100%" role="img" aria-label="叙事弧线图">
  <path d="{{ layout.arcPath }}" fill="none" stroke="#7c3aed" stroke-width="2.5"/>
  {% for point in layout.points %}
  <g data-segment-ids="{{ point.segmentIds|join(',') }}" style="cursor:pointer">
    <circle cx="{{ '%.1f'|format(point.x) }}" cy="{{ '%.1f'|format(point.y) }}" r="{{ 7 if point.stage == 'climax' else 5 }}" fill="{{ '#fbbf24' if point.stage == 'climax' else '#22d3ee' }}"/>
    <text x="{{ '%.1f'|format(point.x) }}" y="{{ '%.1f'|format(point.y + 22) }}" text-anchor="middle" fill="#94a3b8" font-size="11">{{ point.stageLabel }} · {{ point.label }}</text>
    {% if point.summary %}
    <text x="{{ '%.1f'|format(point.x) }}" y="{{ '%.1f'|format(point.y + 38) }}" text-anchor="middle" fill="#64748b" font-size="9">{{ point.summary }}</text>
    {% endif %}
  </g>
  {% if point.stage == 'climax' and point.quote %}
  <g data-segment-ids="{{ point.segmentIds|join(',') }}" style="cursor:pointer">
    <rect x="{{ '%.1f'|format(point.x - point.quoteWidth / 2) }}" y="{{ '%.1f'|format(point.y - 36) }}" width="{{ '%.1f'|format(point.quoteWidth) }}" height="22" rx="11" fill="#451a03" stroke="#fbbf24"/>
    <text x="{{ '%.1f'|format(point.x) }}" y="{{ '%.1f'|format(point.y - 21) }}" text-anchor="middle" fill="#fde68a" font-size="11">&ldquo;{{ point.quote }}&rdquo;</text>
  </g>
  {% endif %}
  {% endfor %}
</svg>
{% endblock %}
"""

_STAGE_ORDER = ["opening", "buildup", "climax", "closing"]
_STAGE_LABELS = {"opening": "开场", "buildup": "铺垫", "climax": "高潮", "closing": "收尾"}
# 固定弧线上的节点坐标（与 _ARC_PATH 走向一致；高潮留出上方金句位）
_STAGE_POINTS = {"opening": (40.0, 172.0), "buildup": (330.0, 100.0), "climax": (560.0, 58.0), "closing": (820.0, 120.0)}
_ARC_PATH = "M 20 180 C 200 175, 280 110, 340 98 S 480 40, 560 58 S 760 110, 840 122"


class _Stage(StrictModel):
    stage: Literal["opening", "buildup", "climax", "closing"]
    label: str = Field(min_length=1)
    summary: Optional[str] = None
    quote: Optional[str] = None
    segmentIds: List[str] = Field(min_length=1)


class _SpeechPlan(StrictModel):
    chartType: Literal["narrative_arc"]
    title: str = Field(min_length=1)
    stages: List[_Stage] = Field(default_factory=list)
    truncatedCount: int = 0


class SpeechSkill(BaseSkill):
    content_type = "speech"
    chart_type = "narrative_arc"
    display_name = "叙事弧线图"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _SpeechPlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"speech plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        stages = []
        seen_stages = set()
        for stage in model.stages:
            if stage.stage in seen_stages:
                continue
            ids = filter_known_segment_ids(stage.segmentIds, segment_map)
            if not ids:
                continue
            seen_stages.add(stage.stage)
            stages.append({
                "stage": stage.stage,
                "label": stage.label,
                "summary": stage.summary,
                "quote": stage.quote,
                "segmentIds": ids,
            })
        stages.sort(key=lambda s: _STAGE_ORDER.index(s["stage"]))
        return {
            "chartType": "narrative_arc",
            "title": model.title,
            "stages": stages,
            "truncatedCount": model.truncatedCount,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "演讲结构")
        by_stage: Dict[str, Dict[str, Any]] = {}
        for plan in plans:
            for stage in plan.get("stages", []):
                name = stage["stage"]
                if name not in by_stage:
                    by_stage[name] = stage
                else:
                    existing = by_stage[name]
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + stage.get("segmentIds", [])))
                    if not existing.get("quote") and stage.get("quote"):
                        existing["quote"] = stage["quote"]
        stages = [by_stage[name] for name in _STAGE_ORDER if name in by_stage]
        return {"chartType": "narrative_arc", "title": title, "stages": stages, "truncatedCount": 0}

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        stages = plan.get("stages") or []
        return len(stages) < 3 or not any(s["stage"] == "climax" for s in stages)

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        stages = plan.get("stages") or []
        if len(stages) < 3 or not any(s["stage"] == "climax" for s in stages):
            return ["speech 需要至少三段结构且包含高潮段"]
        errors = []
        for stage in stages:
            ids = stage.get("segmentIds") or []
            label = _STAGE_LABELS.get(stage["stage"], stage["stage"])
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"{label}段缺少有效来源片段")
                continue
            if stage["stage"] == "climax":
                if not stage.get("quote"):
                    errors.append("高潮段必须配金句原话")
                elif not text_has_evidence(stage["quote"], ids, segment_map):
                    errors.append("高潮段金句必须逐字来自原文")
                elif not numbers_have_evidence(stage["quote"], ids, segment_map):
                    errors.append("高潮段金句数字与原文不符")
            if not numbers_have_evidence(stage.get("label"), ids, segment_map):
                errors.append(f"{label}段标题数字与原文不符")
            if stage.get("summary") and not numbers_have_evidence(stage["summary"], ids, segment_map):
                errors.append(f"{label}段摘要数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        stages = []
        for stage in plan.get("stages", []):
            ids = filter_known_segment_ids(stage.get("segmentIds"), segment_map)
            if not ids:
                continue
            if not numbers_have_evidence(stage.get("label"), ids, segment_map):
                continue
            if stage.get("summary") and not numbers_have_evidence(stage["summary"], ids, segment_map):
                continue
            if stage["stage"] == "climax" and not (
                stage.get("quote") and text_has_evidence(stage["quote"], ids, segment_map)
                and numbers_have_evidence(stage["quote"], ids, segment_map)
            ):
                continue
            stages.append({**stage, "segmentIds": ids})
        if len(stages) < 3 or not any(s["stage"] == "climax" for s in stages):
            return None
        return {**plan, "stages": stages, "truncatedCount": 0}

    # ---- SVG 布局（确定性几何）----
    @staticmethod
    def layout_arc(stages: List[Dict[str, Any]]) -> Dict[str, Any]:
        points = []
        for stage in stages:
            x, y = _STAGE_POINTS.get(stage["stage"], (430.0, 120.0))
            quote = stage.get("quote") or ""
            quote_width = min(max(len(quote) * 12 + 28, 120.0), 420.0)
            points.append({
                **stage,
                "x": x,
                "y": y,
                "stageLabel": _STAGE_LABELS.get(stage["stage"], stage["stage"]),
                "quoteWidth": quote_width,
            })
        return {"width": 860.0, "height": 230.0, "arcPath": _ARC_PATH, "points": points}

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        layout = self.layout_arc(plan.get("stages", []))
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title, layout=layout)
```

注册（`skills/__init__.py`）：import `SpeechSkill`，最终列表（**Task 12 依赖这个完整顺序**）：

```python
from .base import CONTENT_TYPE_DISPLAY_NAMES, BaseSkill
from .dialogue import DialogueSkill
from .interview import InterviewSkill
from .lecture import LectureSkill
from .meeting import MeetingSkill
from .memo import MemoSkill
from .other import OtherSkill
from .speech import SpeechSkill

SKILLS: Dict[str, BaseSkill] = {
    skill.content_type: skill
    for skill in [
        DialogueSkill(),
        InterviewSkill(),
        LectureSkill(),
        MeetingSkill(),
        MemoSkill(),
        OtherSkill(),
        SpeechSkill(),
    ]
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 OK

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/speech.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_skills.py
git commit -m "feat: 演讲 skill——叙事弧线图（SVG 弧线布局）"
```

---

## Task 12: v4 流水线切换（graph/nodes/main 重写 + 退役 v3 代码 + 回归测试）

这是核心任务：用"分类器 + skill 分发"替换 v3 的"候选提取 + 自由路由"，并删除 v3 专属代码。七个 skill 已在前面的任务中就绪并各自测试通过。

**Files:**
- Rewrite: `ChartAgent/agent/graph.py`
- Rewrite: `ChartAgent/agent/nodes.py`
- Rewrite: `ChartAgent/main.py`
- Modify: `ChartAgent/agent/schema.py`（删除 v3 模型）
- Modify: `ChartAgent/agent/templates.py`（删除 v3 六种图表模板）
- Rewrite: `ChartAgent/tests/test_smartchart.py`
- Create: `ChartAgent/tests/test_pipeline.py`

- [ ] **Step 1: 写 test_pipeline.py（端到端，先失败）**

创建 `ChartAgent/tests/test_pipeline.py`：

```python
"""v4 端到端流水线测试：类型路由、强制类型、降级链、渲染校验、HTTP 契约。LLM 全部打桩。"""
import json
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from agent import nodes
from agent.graph import chart_agent
from agent.llm_client import LLMError
from main import app


def seg(segment_id, text, start, speaker="发言人"):
    return {"id": segment_id, "speaker": speaker, "startTime": start, "endTime": start + 5.0, "text": text}


def base_state(segments, **overrides):
    state = {
        "request_id": "request-1",
        "recording_id": "recording-1",
        "segments": segments,
        "summary_markdown": "",
        "preferences": {"styleTheme": "darkCyberpunk"},
        "force_content_type": None,
        "chunk_plans": [],
        "plan": None,
        "html_fragment": None,
        "render_config": None,
        "validation_result": None,
        "retry_count": 0,
        "error_message": None,
        "error_code": None,
        "status": "success",
    }
    state.update(overrides)
    return state


def classify_response(content_type, confidence=0.9):
    return json.dumps({"content_type": content_type, "confidence": confidence, "reason": "test"}, ensure_ascii=False)


def router_fake(extraction_marker, extraction_plan, classify_type):
    def fake(prompt, temperature=0.3, deadline=None):
        if "内容分类器" in prompt:
            return classify_response(classify_type)
        if extraction_marker and extraction_marker in prompt:
            return json.dumps(extraction_plan, ensure_ascii=False)
        raise AssertionError(f"未预期的提示词: {prompt[:100]}")
    return fake


MEETING_SEGMENTS = [
    seg("s1", "我们今天讨论私有化部署的议题，结论就是当天完成部署", 0.0, "甲"),
    seg("s2", "李老师今天提供一台可外网访问的电脑，然后接入知识库问答", 5.0, "乙"),
    seg("s3", "好的，那我这边配合做好后续推进", 10.0, "甲"),
]
MEETING_PLAN = {
    "chartType": "decision_board",
    "title": "私有化部署讨论会",
    "topics": [
        {"title": "私有化部署", "conclusion": "当天完成部署",
         "actions": [{"text": "提供一台可外网访问的电脑", "owner": "李老师", "due": "今天"}],
         "segmentIds": ["s1", "s2"]}
    ],
}

INTERVIEW_SEGMENTS = [
    seg("s1", "你为什么坚持私有化部署？", 0.0, "采访者"),
    seg("s2", "数据不能出内网，这是红线，云上大模型再便宜也不用", 5.0, "被访者"),
    seg("s3", "那未来会扩展吗？", 10.0, "采访者"),
    seg("s4", "先做个小范围试点，稳定后再推广", 15.0, "被访者"),
]
INTERVIEW_PLAN = {
    "chartType": "qa_cards",
    "title": "部署访谈",
    "qas": [
        {"question": "为什么坚持私有化部署？", "keyAnswer": "数据不能出内网，这是红线", "tags": ["数据安全"], "segmentIds": ["s2"]},
        {"question": "未来会扩展吗？", "keyAnswer": "先做个小范围试点", "tags": ["扩展"], "segmentIds": ["s4"]},
    ],
}

LECTURE_SEGMENTS = [
    seg("s1", "今天我们讲 Transformer，先讲注意力机制", 0.0, "讲师"),
    seg("s2", "注意力机制的核心是 QKV 计算和多头注意力", 5.0, "讲师"),
    seg("s3", "第二个概念是位置编码，正弦编码用 sin 和 cos", 10.0, "讲师"),
]
LECTURE_PLAN = {
    "chartType": "knowledge_tree",
    "title": "Transformer 精讲",
    "topic": "Transformer",
    "chapters": [
        {"title": "注意力机制", "concepts": [{"name": "QKV 计算", "note": None, "segmentIds": ["s2"]}], "segmentIds": ["s2"]},
        {"title": "位置编码", "concepts": [{"name": "正弦编码", "note": None, "segmentIds": ["s3"]}], "segmentIds": ["s3"]},
    ],
}

DIALOGUE_SEGMENTS = [
    seg("s1", "预算这块确实有点紧张，大家想想办法", 0.0, "甲"),
    seg("s2", "预算我来协调，那进度呢？", 10.0, "乙"),
    seg("s3", "进度下周继续推，不急", 20.0, "甲"),
    seg("s4", "行，那就这么定", 30.0, "乙"),
]
DIALOGUE_PLAN = {
    "chartType": "topic_swimlane",
    "title": "项目讨论",
    "speakers": ["甲", "乙"],
    "blocks": [
        {"speaker": "甲", "topic": "预算", "summary": None, "start": 0.0, "end": 10.0, "segmentIds": ["s1"]},
        {"speaker": "乙", "topic": "预算协调", "summary": None, "start": 10.0, "end": 20.0, "segmentIds": ["s2"]},
        {"speaker": "甲", "topic": "进度", "summary": None, "start": 20.0, "end": 30.0, "segmentIds": ["s3"]},
    ],
}

SPEECH_SEGMENTS = [
    seg("s1", "三年前我经历了一件改变我的事", 0.0, "演讲者"),
    seg("s2", "你会发现现状比想象中更糟糕", 30.0, "演讲者"),
    seg("s3", "所以我说，改变从今晚开始，就在你我手中", 60.0, "演讲者"),
    seg("s4", "每个人都可以迈出第一步", 90.0, "演讲者"),
]
SPEECH_PLAN = {
    "chartType": "narrative_arc",
    "title": "改变",
    "stages": [
        {"stage": "opening", "label": "故事", "summary": None, "quote": None, "segmentIds": ["s1"]},
        {"stage": "buildup", "label": "现状", "summary": None, "quote": None, "segmentIds": ["s2"]},
        {"stage": "climax", "label": "顿悟", "summary": None, "quote": "改变从今晚开始", "segmentIds": ["s3"]},
        {"stage": "closing", "label": "行动", "summary": None, "quote": None, "segmentIds": ["s4"]},
    ],
}

MEMO_PLAN = {
    "chartType": "idea_card",
    "title": "随手记要点",
    "coreIdea": "图表要按内容类型路由",
    "coreSegmentIds": ["s1"],
    "points": [{"text": "分类器要能给其他兜底", "segmentIds": ["s1"]}],
}


class PipelineTypeRoutingTests(unittest.TestCase):
    """七种类型各跑一遍完整流水线，断言 content_type 与 chartType 的固定映射。"""

    def run_pipeline(self, marker, plan, classify_type, segments):
        with patch.object(nodes, "call_llm", side_effect=router_fake(marker, plan, classify_type)):
            return chart_agent.invoke(base_state(segments))

    def test_meeting_routes_to_decision_board(self):
        result = self.run_pipeline('"decision_board"', MEETING_PLAN, "meeting", MEETING_SEGMENTS)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["content_type"], "meeting")
        self.assertEqual(result["plan"]["chartType"], "decision_board")
        self.assertIn("私有化部署", result["html_fragment"])

    def test_interview_routes_to_qa_cards(self):
        result = self.run_pipeline('"qa_cards"', INTERVIEW_PLAN, "interview", INTERVIEW_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "qa_cards")
        self.assertIn("数据不能出内网，这是红线", result["html_fragment"])

    def test_lecture_routes_to_knowledge_tree(self):
        result = self.run_pipeline('"knowledge_tree"', LECTURE_PLAN, "lecture", LECTURE_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "knowledge_tree")
        self.assertIn("<svg", result["html_fragment"])
        self.assertIn("注意力机制", result["html_fragment"])

    def test_dialogue_routes_to_topic_swimlane(self):
        result = self.run_pipeline('"topic_swimlane"', DIALOGUE_PLAN, "dialogue", DIALOGUE_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "topic_swimlane")
        self.assertIn("<svg", result["html_fragment"])

    def test_speech_routes_to_narrative_arc(self):
        result = self.run_pipeline('"narrative_arc"', SPEECH_PLAN, "speech", SPEECH_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "narrative_arc")
        self.assertIn("改变从今晚开始", result["html_fragment"])

    def test_memo_routes_to_idea_card(self):
        result = self.run_pipeline('"idea_card"', MEMO_PLAN, "memo", MEETING_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "idea_card")
        self.assertIn("图表要按内容类型路由", result["html_fragment"])

    def test_other_uses_deterministic_highlights_without_extraction_llm(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("other")
            raise AssertionError("other 类型不应再调用提取 LLM")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")


class PipelineForceTypeTests(unittest.TestCase):
    def test_forced_content_type_skips_classifier(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                raise AssertionError("强制类型时不应调用分类器")
            if '"idea_card"' in prompt:
                return json.dumps(MEMO_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS, force_content_type="memo"))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["content_type"], "memo")
        self.assertEqual(result["plan"]["chartType"], "idea_card")

    def test_low_confidence_falls_back_to_other(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting", 0.4)
            raise AssertionError("低置信度应归 other，不应再调用提取")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["content_type"], "other")
        self.assertEqual(result["plan"]["chartType"], "highlights")

    def test_classifier_llm_failure_falls_back_to_other(self):
        def fake(prompt, temperature=0.3, deadline=None):
            raise LLMError(LLMError.TIMEOUT, "超时")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["content_type"], "other")
        self.assertEqual(result["plan"]["chartType"], "highlights")


class PipelineDegradationTests(unittest.TestCase):
    def test_all_chunk_extraction_failures_degrade_to_highlights(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            raise LLMError(LLMError.TIMEOUT, "提取超时")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertTrue(result["validation_result"]["degraded"])

    def test_invalid_plan_repaired_once_then_highlights(self):
        calls = {"repair": 0}

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "未通过校验" in prompt:
                calls["repair"] += 1
                return json.dumps({"chartType": "decision_board", "title": "x", "topics": []}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps({
                    "chartType": "decision_board", "title": "x",
                    "topics": [{"title": "部署 100 台", "conclusion": None,
                                "actions": [{"text": "3 天内搞定 100 台电脑", "owner": None, "due": None}],
                                "segmentIds": ["s1"]}],
                }, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(calls["repair"], 1)  # 修复只调用一次
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")

    def test_short_transcript_fails_terminally(self):
        result = chart_agent.invoke(base_state([seg("s1", "嗯", 0.0)]))
        self.assertEqual(result["status"], "failed")

    def test_render_fragment_balanced_and_traceable(self):
        with patch.object(nodes, "call_llm", side_effect=router_fake('"decision_board"', MEETING_PLAN, "meeting")):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        html = result["html_fragment"]
        self.assertEqual(html.count("<div"), html.count("</div>"))
        self.assertIn('data-segment-ids="s1,s2"', html)


class PipelineEndpointTests(unittest.TestCase):
    def test_response_contains_v4_content_type_fields(self):
        payload = {"version": "4.0", "requestId": "r1", "recordingId": "rec1", "segments": MEETING_SEGMENTS}
        with patch.object(nodes, "call_llm", side_effect=router_fake('"decision_board"', MEETING_PLAN, "meeting")):
            response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["contentType"], "meeting")
        self.assertEqual(body["contentTypeDisplayName"], "会议")
        self.assertEqual(body["chartType"], "decision_board")
        self.assertEqual(body["chartTypeDisplayName"], "决策行动看板")

    def test_endpoint_passes_force_content_type(self):
        payload = {"version": "4.0", "requestId": "r1", "recordingId": "rec1",
                   "segments": MEETING_SEGMENTS, "forceContentType": "memo"}
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                raise AssertionError("强制类型时不应调用分类器")
            if '"idea_card"' in prompt:
                return json.dumps(MEMO_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with patch.object(nodes, "call_llm", side_effect=fake):
            response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.json()["contentType"], "memo")


if __name__ == "__main__":
    unittest.main()
```

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_pipeline -v`
Expected: FAIL（nodes 没有 `classify_content` 等新节点，图还是 v3 的）

- [ ] **Step 2: 重写 graph.py（全文替换）**

```python
"""SmartChart v4 LangGraph 编排：prepare → classify → extract → merge → validate → render → validate_render。"""
from typing import Any, Dict, List, Literal, Optional, TypedDict

from langgraph.graph import END, StateGraph

from .nodes import (
    classify_content,
    extract_structured,
    merge_plans,
    prepare_transcript,
    render_chart_node,
    validate_plan,
    validate_render,
)


class ChartAgentState(TypedDict, total=False):
    request_id: str
    recording_id: str
    segments: List[Dict[str, Any]]
    summary_markdown: str
    preferences: Dict[str, Any]
    transcript_text: str
    segment_map: Dict[str, Dict[str, Any]]
    force_content_type: Optional[str]
    content_type: str
    classify_confidence: float
    classify_reason: str
    chunk_plans: List[Dict[str, Any]]
    plan: Optional[Dict[str, Any]]
    html_fragment: Optional[str]
    render_config: Optional[Dict[str, Any]]
    validation_result: Optional[Dict[str, Any]]
    retry_count: int
    error_message: Optional[str]
    error_code: Optional[str]
    deadline: float
    status: Literal["success", "failed"]


def _continue_or_end(state: ChartAgentState) -> str:
    return END if state.get("status") == "failed" else "continue"


def build_chart_agent():
    builder = StateGraph(ChartAgentState)
    builder.add_node("prepare_transcript", prepare_transcript)
    builder.add_node("classify_content", classify_content)
    builder.add_node("extract_structured", extract_structured)
    builder.add_node("merge_plans", merge_plans)
    builder.add_node("validate_plan", validate_plan)
    builder.add_node("render_chart", render_chart_node)
    builder.add_node("validate_render", validate_render)
    builder.set_entry_point("prepare_transcript")
    builder.add_conditional_edges("prepare_transcript", _continue_or_end, {"continue": "classify_content", END: END})
    builder.add_conditional_edges("classify_content", _continue_or_end, {"continue": "extract_structured", END: END})
    builder.add_conditional_edges("extract_structured", _continue_or_end, {"continue": "merge_plans", END: END})
    builder.add_conditional_edges("merge_plans", _continue_or_end, {"continue": "validate_plan", END: END})
    builder.add_conditional_edges("validate_plan", _continue_or_end, {"continue": "render_chart", END: END})
    builder.add_conditional_edges("render_chart", _continue_or_end, {"continue": "validate_render", END: END})
    builder.add_edge("validate_render", END)
    return builder.compile()


chart_agent = build_chart_agent()
```

- [ ] **Step 3: 重写 nodes.py（全文替换）**

```python
"""SmartChart v4 流水线节点。

prepare_transcript → classify_content → extract_structured → merge_plans
→ validate_plan → render_chart → validate_render

分工：skill 负责类型内逻辑（提示词/校验/渲染），本模块负责编排、时间预算与并发。
"""
import json
import os
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List, Optional, Tuple

from . import classifier
from .classifier import CONTENT_TYPES
from .llm_client import LLMError, MIN_REMAINING_SECONDS, call_llm
from .observability import log_event, safe_error_fields
from .skills import SKILLS, skill_for_chart_type
from .skills.base import BaseSkill
from .textutils import parse_llm_json as _parse_json

CHUNK_CHARACTER_BUDGET = 12000
EXTRACTION_CONCURRENCY = 4
ROUTE_RESERVED_SECONDS = 25.0
REPAIR_MIN_SECONDS = 12.0


# ---------- 基础工具 ----------

def _fail(state: Dict[str, Any], message: str, error_code: Optional[str] = None) -> Dict[str, Any]:
    state["status"] = "failed"
    state["error_message"] = message
    if error_code:
        state["error_code"] = error_code
    return state


def _elapsed_ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _remaining_budget(state: Dict[str, Any]) -> float:
    deadline = state.get("deadline")
    if deadline is None:
        return float("inf")
    return deadline - time.monotonic()


def _extraction_concurrency() -> int:
    raw = os.environ.get("CHART_EXTRACTION_CONCURRENCY", "")
    try:
        value = int(raw) if raw else EXTRACTION_CONCURRENCY
    except ValueError:
        return EXTRACTION_CONCURRENCY
    return max(1, min(value, EXTRACTION_CONCURRENCY))


def _extraction_deadline(request_deadline: Optional[float]) -> Optional[float]:
    if request_deadline is None:
        return None
    return request_deadline - ROUTE_RESERVED_SECONDS


def _call_llm(prompt: str, temperature: float, deadline: Optional[float] = None) -> str:
    if deadline is None:
        return call_llm(prompt, temperature=temperature)
    return call_llm(prompt, temperature=temperature, deadline=deadline)


def _chunk_segments(
    segments: List[Dict[str, Any]], budget: int = CHUNK_CHARACTER_BUDGET
) -> List[List[Dict[str, Any]]]:
    """按片段边界贪心分块，单块字符预算 budget；超大单片段独立成块。"""
    chunks: List[List[Dict[str, Any]]] = []
    current: List[Dict[str, Any]] = []
    current_size = 0
    for segment in segments:
        size = len(json.dumps(segment, ensure_ascii=False))
        if current and current_size + size > budget:
            chunks.append(current)
            current, current_size = [], 0
        current.append(segment)
        current_size += size
    if current:
        chunks.append(current)
    return chunks


def _deduplicated(values: List[str]) -> List[str]:
    return list(dict.fromkeys(values))


def _skill_for_state(state: Dict[str, Any]) -> BaseSkill:
    return SKILLS.get(state.get("content_type") or "other") or SKILLS["other"]


# ---------- 节点 ----------

def prepare_transcript(state: Dict[str, Any]) -> Dict[str, Any]:
    started = time.monotonic()
    segments = [s for s in state.get("segments", []) if str(s.get("text", "")).strip()]
    if not segments:
        return _fail(state, "没有完整转录")
    state["segments"] = segments
    transcript_text = "\n".join(f"[{s['id']}] {s.get('speaker', '')}: {s['text']}" for s in segments)
    if len(transcript_text) < 30:
        return _fail(state, "转录内容过短且没有重点句子")
    state["transcript_text"] = transcript_text
    state["segment_map"] = {s["id"]: s for s in segments}
    state["status"] = "success"
    log_event("INFO", "prepare_transcript", state.get("request_id"), state.get("recording_id"),
              segmentCount=len(segments), elapsedMs=_elapsed_ms(started))
    return state


def classify_content(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    forced = state.get("force_content_type")
    if forced in CONTENT_TYPES:
        state["content_type"] = forced
        state["classify_confidence"] = 1.0
        state["classify_reason"] = "forced"
        log_event("INFO", "classify_content", state.get("request_id"), state.get("recording_id"),
                  contentType=forced, confidence=1.0, forced=True, elapsedMs=_elapsed_ms(started))
        return state
    content_type, confidence, reason = classifier.classify_content(
        state.get("segments", []), state.get("transcript_text", ""), deadline=state.get("deadline")
    )
    state["content_type"] = content_type
    state["classify_confidence"] = confidence
    state["classify_reason"] = reason
    log_event("INFO", "classify_content", state.get("request_id"), state.get("recording_id"),
              contentType=content_type, confidence=round(confidence, 3),
              elapsedMs=_elapsed_ms(started))
    return state


def _extract_chunk_plan(
    skill: BaseSkill,
    chunk_index: int,
    chunk: List[Dict[str, Any]],
    chunk_count: int,
    deadline: Optional[float],
    request_id: Optional[str],
    recording_id: Optional[str],
) -> Tuple[int, Optional[Dict[str, Any]], Optional[BaseException]]:
    try:
        raw = _parse_json(_call_llm(skill.extraction_prompt(chunk), temperature=0.2, deadline=deadline))
        return chunk_index, skill.normalize(raw, chunk), None
    except Exception as error:
        log_event("WARNING", "extract_chunk", request_id, recording_id,
                  chunkIndex=chunk_index, chunkCount=chunk_count, result="failed", **safe_error_fields(error))
        return chunk_index, None, error


def extract_structured(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    skill = _skill_for_state(state)
    segments = state.get("segments", [])
    if not skill.uses_llm_extraction:
        state["chunk_plans"] = [skill.extract_deterministic(segments)]
        log_event("INFO", "extract_structured", state.get("request_id"), state.get("recording_id"),
                  contentType=skill.content_type, chunks=0, elapsedMs=_elapsed_ms(started))
        return state
    chunks = _chunk_segments(segments)
    concurrency = _extraction_concurrency()
    extraction_deadline = _extraction_deadline(state.get("deadline"))
    chunk_count = len(chunks)
    collected: List[Tuple[int, Dict[str, Any]]] = []
    failed_chunks = 0
    for wave_start in range(0, chunk_count, concurrency):
        if extraction_deadline is not None and extraction_deadline - time.monotonic() < MIN_REMAINING_SECONDS:
            log_event("WARNING", "extract_chunk", state.get("request_id"), state.get("recording_id"),
                      result="skipped_low_budget", remainingChunks=chunk_count - wave_start)
            break
        wave = chunks[wave_start:wave_start + concurrency]
        with ThreadPoolExecutor(max_workers=concurrency, thread_name_prefix="chart-extract") as executor:
            futures = [
                executor.submit(
                    _extract_chunk_plan, skill, wave_start + offset, chunk, chunk_count,
                    extraction_deadline, state.get("request_id"), state.get("recording_id"),
                )
                for offset, chunk in enumerate(wave)
            ]
            for future in as_completed(futures):
                index, plan, error = future.result()
                if error is not None or plan is None:
                    failed_chunks += 1
                else:
                    collected.append((index, plan))
    state["chunk_plans"] = [plan for index, plan in sorted(collected, key=lambda item: item[0])]
    log_event("INFO", "extract_structured", state.get("request_id"), state.get("recording_id"),
              contentType=skill.content_type, chunks=chunk_count, failedChunks=failed_chunks,
              elapsedMs=_elapsed_ms(started))
    return state


def merge_plans(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed" or state.get("plan"):
        return state
    started = time.monotonic()
    skill = _skill_for_state(state)
    merged = skill.merge(state.get("chunk_plans", []))
    if skill.is_empty(merged):
        return _degrade_to_highlights(state, "extraction_empty")
    state["plan"] = merged
    log_event("INFO", "merge_plans", state.get("request_id"), state.get("recording_id"),
              contentType=skill.content_type, elapsedMs=_elapsed_ms(started))
    return state


def _degrade_to_highlights(state: Dict[str, Any], reason: str) -> Dict[str, Any]:
    plan = SKILLS["other"].extract_deterministic(state.get("segments", []))
    if not plan.get("highlightSentences"):
        return _fail(state, "没有可用的重点句子，无法生成图表")
    state["plan"] = plan
    state["validation_result"] = {"passed": False, "degraded": True, "reason": reason}
    state["status"] = "success"
    log_event("WARNING", "degrade_to_highlights", state.get("request_id"), state.get("recording_id"), reason=reason)
    return state


def validate_plan(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    plan = state.get("plan")
    if not plan:
        return _degrade_to_highlights(state, "plan_missing")
    started = time.monotonic()
    skill = skill_for_chart_type(str(plan.get("chartType", "highlights")))
    segment_map = state.get("segment_map", {})
    errors = skill.validate(plan, segment_map)
    if errors and state.get("retry_count", 0) < 1:
        state["retry_count"] = 1
        if _remaining_budget(state) >= REPAIR_MIN_SECONDS:
            repaired: Optional[Dict[str, Any]] = None
            try:
                repaired_raw = _parse_json(_call_llm(
                    skill.repair_prompt(plan, errors, state.get("segments", [])),
                    temperature=0.0,
                    deadline=state.get("deadline"),
                ))
                candidate = skill.normalize(repaired_raw, state.get("segments", []))
                retry_errors = skill.validate(candidate, segment_map)
                if not retry_errors:
                    repaired = candidate
                else:
                    errors = retry_errors
            except Exception as error:
                log_event("WARNING", "repair_plan", state.get("request_id"), state.get("recording_id"),
                          result="failed", **safe_error_fields(error))
            if repaired is not None:
                state["plan"] = repaired
                state["validation_result"] = {"passed": True, "repaired": True}
                log_event("INFO", "validate_plan", state.get("request_id"), state.get("recording_id"),
                          result="repaired", elapsedMs=_elapsed_ms(started))
                return state
        else:
            log_event("WARNING", "repair_plan", state.get("request_id"), state.get("recording_id"),
                      result="skipped_low_budget")
    if not errors:
        previous = state.get("validation_result") or {}
        result: Dict[str, Any] = {"passed": True}
        if previous.get("degraded"):
            result["degraded"] = True
            result["reason"] = previous.get("reason")
        state["validation_result"] = result
        log_event("INFO", "validate_plan", state.get("request_id"), state.get("recording_id"),
                  result="passed", elapsedMs=_elapsed_ms(started))
        return state
    fallback = skill.fallback(plan, segment_map)
    if fallback is not None and not skill.is_empty(fallback):
        state["plan"] = fallback
        state["validation_result"] = {"passed": False, "errors": errors, "degraded": True, "reason": "skill_fallback"}
        log_event("WARNING", "validate_plan", state.get("request_id"), state.get("recording_id"),
                  result="skill_fallback", elapsedMs=_elapsed_ms(started))
        return state
    return _degrade_to_highlights(state, "validation_failed")


def render_chart_node(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    plan = state.get("plan") or {}
    theme = state.get("preferences", {}).get("styleTheme", "darkCyberpunk")
    skill = skill_for_chart_type(str(plan.get("chartType", "highlights")))
    try:
        state["html_fragment"] = skill.render(plan, theme, str(plan.get("title", "")))
        state["render_config"] = {"cssFramework": "smartchart-v4"}
    except Exception as error:
        log_event("ERROR", "render", state.get("request_id"), state.get("recording_id"), **safe_error_fields(error))
        return _fail(state, f"图表渲染失败：{error}")
    log_event("INFO", "render", state.get("request_id"), state.get("recording_id"),
              chartType=plan.get("chartType", "highlights"), elapsedMs=_elapsed_ms(started))
    return state


def validate_render(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    html = state.get("html_fragment") or ""
    errors = []
    if not html.strip():
        errors.append("渲染结果为空")
    if "data-segment-ids" not in html:
        errors.append("渲染结果缺少 data-segment-ids")
    if html.count("<div") != html.count("</div>"):
        errors.append("渲染结果 div 标签不平衡")
    if errors:
        state["validation_result"] = {"passed": False, "errors": errors}
        return _fail(state, "；".join(errors))
    state["status"] = "success"
    return state
```

注意（执行时核对）：上述文件整体替换 783 行的旧 nodes.py，以下 v3 符号随替换一并消失，不得再被引用：`extract_candidates`、`merge_candidates`、`route_and_plan`、`_llm_extract_candidates`、`_llm_route_and_plan`、`_repair_plan`、`_extract_segment_candidates`、`_validate_llm_candidates`、`_degrade_route_to_highlights`、`_fallback_highlights_plan`、`_validate_plan`、`_normalize_text`、`_source_text`、`_parse_json`（新版从 textutils 别名导入）、`ALLOWED_KINDS`、`CAUSAL_PATTERN`、`DATE_PATTERN`、`NUMBER_PATTERN`、`CHUNK_TIME...` 等候选期常量。替换后执行 `grep -n "candidates\|route_and_plan" ChartAgent/agent/*.py` 确认无残留引用。

- [ ] **Step 4: 重写 main.py（全文替换）**

```python
"""ChartAgent v4 HTTP 服务：POST /chart/generate + GET /health。"""
import asyncio
import html
import os
import time
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException

from agent.graph import ChartAgentState, chart_agent
from agent.observability import log_event, safe_error_fields
from agent.schema import SmartChartGenerateRequest, SmartChartGenerateResponse
from agent.skills import CHART_TYPE_DISPLAY_NAMES, CONTENT_TYPE_DISPLAY_NAMES

API_VERSION = "4.0"
SERVICE_VERSION = "4.0.0"
DEFAULT_TIME_BUDGET_SECONDS = 105.0
ENDPOINT_RESPONSE_RESERVE_SECONDS = 0.5
GRAPH_COMPLETION_MARGIN_SECONDS = 2.0

app = FastAPI(title="ChartAgent", version=SERVICE_VERSION)


def _time_budget_seconds() -> float:
    raw = os.environ.get("CHART_TIME_BUDGET_SECONDS", "")
    try:
        value = float(raw) if raw else DEFAULT_TIME_BUDGET_SECONDS
    except ValueError:
        return DEFAULT_TIME_BUDGET_SECONDS
    return value if value > 0 else DEFAULT_TIME_BUDGET_SECONDS


def _duration_ms(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


def _graph_timeout_seconds(budget_seconds: float) -> float:
    return max(0.01, budget_seconds - min(ENDPOINT_RESPONSE_RESERVE_SECONDS, budget_seconds / 2))


def _llm_configured() -> bool:
    return bool(os.environ.get("OPENAI_API_KEY") or os.environ.get("OLLAMA_MODEL"))


@app.get("/health")
async def health_check():
    return {
        "status": "ok",
        "apiVersion": API_VERSION,
        "serviceVersion": SERVICE_VERSION,
        "llmConfigured": _llm_configured(),
    }


def _error_html(message: str) -> str:
    safe_message = html.escape(message)
    return (
        '<div style="padding:24px;border-radius:12px;background:#2a1215;color:#fca5a5;'
        'font-size:14px;line-height:1.6">图表生成失败：' + safe_message + "</div>"
    )


def _failed_response(request_id: str, message: str, error_code: Optional[str] = None) -> SmartChartGenerateResponse:
    return SmartChartGenerateResponse(
        requestId=request_id,
        status="failed",
        contentType="other",
        contentTypeDisplayName="其他",
        chartType="highlights",
        chartTypeDisplayName="重点句子",
        title="生成失败",
        htmlFragment=_error_html(message),
        plan={"chartType": "highlights", "title": "生成失败", "highlightSentences": []},
        errors=[message],
        errorCode=error_code,
    )


@app.post("/chart/generate", response_model=SmartChartGenerateResponse)
async def chart_generate_endpoint(request: SmartChartGenerateRequest):
    budget_seconds = _time_budget_seconds()
    started = time.monotonic()
    graph_timeout = _graph_timeout_seconds(budget_seconds)
    work_deadline = started + graph_timeout - GRAPH_COMPLETION_MARGIN_SECONDS
    log_event("INFO", "request_received", request.requestId, request.recordingId,
              segmentCount=len(request.segments), budgetSeconds=budget_seconds,
              forceContentType=request.forceContentType)
    state: ChartAgentState = {
        "request_id": request.requestId,
        "recording_id": request.recordingId,
        "segments": [segment.model_dump() for segment in request.segments],
        "summary_markdown": request.summaryMarkdown or "",
        "preferences": {"styleTheme": "darkCyberpunk"},
        "force_content_type": request.forceContentType,
        "chunk_plans": [],
        "plan": None,
        "html_fragment": None,
        "render_config": None,
        "validation_result": None,
        "retry_count": 0,
        "error_message": None,
        "error_code": None,
        "deadline": work_deadline,
        "status": "success",
    }
    try:
        result_state = await asyncio.wait_for(
            asyncio.to_thread(chart_agent.invoke, state),
            timeout=graph_timeout,
        )
    except asyncio.TimeoutError:
        log_event("WARNING", "request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode="TIMEOUT", durationMs=_duration_ms(started))
        return _failed_response(request.requestId, "图表生成超时", "TIMEOUT")
    except Exception as error:
        log_event("ERROR", "request_finished", request.requestId, request.recordingId,
                  result="failed", durationMs=_duration_ms(started), **safe_error_fields(error))
        raise HTTPException(status_code=500, detail="图表服务内部错误") from error

    if result_state.get("status") == "failed":
        message = result_state.get("error_message") or "图表生成失败"
        log_event("WARNING", "request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode=result_state.get("error_code"), durationMs=_duration_ms(started))
        return _failed_response(request.requestId, message, result_state.get("error_code"))

    plan = result_state.get("plan") or {}
    content_type = result_state.get("content_type") or "other"
    chart_type = str(plan.get("chartType", "highlights"))
    log_event("INFO", "request_finished", request.requestId, request.recordingId,
              result="success", contentType=content_type, chartType=chart_type,
              durationMs=_duration_ms(started))
    return SmartChartGenerateResponse(
        requestId=request.requestId,
        status="success",
        contentType=content_type,
        contentTypeDisplayName=CONTENT_TYPE_DISPLAY_NAMES.get(content_type, "其他"),
        chartType=chart_type,
        chartTypeDisplayName=CHART_TYPE_DISPLAY_NAMES.get(chart_type, "重点句子"),
        title=str(plan.get("title", "")),
        htmlFragment=result_state.get("html_fragment") or "",
        plan=plan,
        errors=[],
    )


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("PORT", "8765")))
```

- [ ] **Step 5: 清理 schema.py 与 templates.py 的 v3 残留**

5a. `schema.py`：删除以下符号（Task 2 标记的 v3 模型）：`VisualizationKind`、`ChartItem`、`ChartRelation`、`ChartDataPoint`、`ChartSeries`、`HighlightSentence`、`ChartPlan`。其余不动。

5b. `templates.py`：删除 `_COMPARISON_TEMPLATE`、`_TIMELINE_TEMPLATE`、`_RELATIONSHIP_TEMPLATE`、`_FLOW_TEMPLATE`、`_ACTION_TEMPLATE`、`_QUANTITATIVE_TEMPLATE`、`_DISPLAY_NAMES`、`_prepare_plan`、`_quantitative_display_mode`、`render_chart`；把 `_TEMPLATES` 改为只注册两项：

```python
_TEMPLATES = {
    "base.html.j2": _BASE_TEMPLATE,
    "highlights.html.j2": _HIGHLIGHTS_TEMPLATE,
}
```

保留：`DARK_CSS`（含 Task 4 新增类）、`_BASE_TEMPLATE`、`BASE_TEMPLATE`、`_HIGHLIGHTS_TEMPLATE`、`_JINJA_ENV`、`render_highlights`。执行后 `grep -n "render_chart\b" ChartAgent/ -r` 应只剩 nodes.py 的 `render_chart_node`。

- [ ] **Step 6: 重写 test_smartchart.py**

**保留不动**：`SmartChartLLMClientTests`（整个类从当前文件原样复制）、`SmartChartSchemaV4Tests`（Task 2 所加）。

**删除**：`SmartChartRuntimeTests`、`SmartChartRoutingTests`、`SmartChartValidationTests`、旧 `SmartChartTimeBudgetTests`、`SmartChartRepairBudgetTests`、旧 `SmartChartEndpointTimeoutTests`、旧 `SmartChartLoggingTests`、旧 `SmartChartEndpointRaceTests`，以及文件顶部不再使用的 import（`from agent.templates import render_chart` 等）。

**在 `SmartChartSchemaV4Tests` 追加**：

```python
    def test_request_rejects_extra_fields(self):
        payload = {
            "version": "4.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
            "unexpected": 1,
        }
        with self.assertRaises(ValidationError):
            SmartChartGenerateRequest.model_validate(payload)
```

**新增以下类**（import 区需含 `asyncio, os, time`、`from agent import nodes`、`from agent.graph import chart_agent`、`from agent.llm_client import LLMError`、`from fastapi.testclient import TestClient`、`from main import app, health_check`，以及从 test_pipeline 复制的 `seg`/`base_state`/`classify_response`/`MEETING_SEGMENTS`/`MEETING_PLAN` 辅助——直接复制粘贴这几个函数与常量到本文件顶部，两个测试文件各自独立）：

```python
class SmartChartHealthTests(unittest.TestCase):
    def test_health_reports_v4(self):
        result = asyncio.run(health_check())
        self.assertEqual(result["apiVersion"], "4.0")
        self.assertEqual(result["serviceVersion"], "4.0.0")


class SmartChartTimeBudgetTests(unittest.TestCase):
    def test_extraction_deadline_respects_route_reserve(self):
        deadline = time.monotonic() + 100
        self.assertAlmostEqual(nodes._extraction_deadline(deadline), deadline - nodes.ROUTE_RESERVED_SECONDS, places=2)

    def test_extraction_concurrency_env_clamped(self):
        with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "99"}):
            self.assertEqual(nodes._extraction_concurrency(), 4)
        with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "0"}):
            self.assertEqual(nodes._extraction_concurrency(), 1)

    def test_low_budget_skips_repair_llm(self):
        bad_plan = {
            "chartType": "decision_board", "title": "x",
            "topics": [{"title": "部署 100 台", "conclusion": None,
                        "actions": [{"text": "3 天内搞定 100 台电脑", "owner": None, "due": None}],
                        "segmentIds": ["s1"]}],
        }

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "未通过校验" in prompt:
                raise AssertionError("低预算不应调用修复 LLM")
            if '"decision_board"' in prompt:
                return json.dumps(bad_plan, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        state = base_state(MEETING_SEGMENTS, deadline=time.monotonic() + 5)
        with patch.object(nodes, "ROUTE_RESERVED_SECONDS", 1.0):
            with patch.object(nodes, "call_llm", side_effect=fake):
                result = chart_agent.invoke(state)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")  # 修复被跳过 → 兜底


class SmartChartEndpointTimeoutTests(unittest.TestCase):
    def test_non_cooperative_graph_cut_off_returns_timeout(self):
        payload = {"version": "4.0", "requestId": "r1", "recordingId": "rec1", "segments": MEETING_SEGMENTS}
        with patch.dict(os.environ, {"CHART_TIME_BUDGET_SECONDS": "3"}):
            with patch("main.chart_agent.invoke", side_effect=lambda state: time.sleep(30)):
                response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "failed")
        self.assertEqual(body["errorCode"], "TIMEOUT")


class SmartChartEndpointRaceTests(unittest.TestCase):
    def test_last_second_extraction_timeout_still_returns_degraded_highlights(self):
        payload = {"version": "4.0", "requestId": "r1", "recordingId": "rec1", "segments": MEETING_SEGMENTS}

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if deadline is not None:
                time.sleep(max(0.0, deadline - time.monotonic() - 0.2))
            raise LLMError(LLMError.TIMEOUT, "最后一刻超时")

        with patch.dict(os.environ, {"CHART_TIME_BUDGET_SECONDS": "6"}):
            with patch.object(nodes, "ROUTE_RESERVED_SECONDS", 1.0):
                with patch.object(nodes, "call_llm", side_effect=fake):
                    response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "success")  # 竞态下也必须返回降级结果而非 TIMEOUT
        self.assertEqual(body["chartType"], "highlights")


class SmartChartLoggingTests(unittest.TestCase):
    def test_pipeline_logs_stages_without_transcript_or_secrets(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with self.assertLogs("chart_agent", level="INFO") as captured:
            with patch.object(nodes, "call_llm", side_effect=fake):
                chart_agent.invoke(base_state(MEETING_SEGMENTS))
        output = "\n".join(captured.output)
        for stage in ("classify_content", "extract_structured", "render"):
            self.assertIn(stage, output)
        self.assertNotIn("李老师今天提供", output)  # 转写原文不得入日志
        self.assertNotIn("Bearer", output)
        self.assertNotIn("sk-", output)
```

- [ ] **Step 7: 全量运行 Python 测试**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest discover -s tests -v`
Expected: 全部 OK（test_textutils / test_classifier / test_skills / test_pipeline / test_smartchart）

- [ ] **Step 8: Commit**

```bash
git add ChartAgent/agent/graph.py ChartAgent/agent/nodes.py ChartAgent/main.py \
        ChartAgent/agent/schema.py ChartAgent/agent/templates.py \
        ChartAgent/tests/test_smartchart.py ChartAgent/tests/test_pipeline.py
git commit -m "feat: 图表v4流水线——分类器路由替换自由路由，退役 v3 通用图表"
```

---

## Task 13: Swift 端契约升级（ContentType + forceContentType + 版本门）

**Files:**
- Modify: `AIRecording/Services/ChartSkill.swift`
- Modify: `AIRecording/Services/HTTPChartSkill.swift`
- Modify: `AIRecording/Services/ChartServiceManager.swift`
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`
- Test: `Tests/AIRecordingTests/SmartChartTests.swift`

- [ ] **Step 1: 先核查旧 DTO 的引用范围**

Run: `grep -rn "VisualizationKind\|ChartPlan\|HighlightSentence\|ChartItem\|ChartRelation\|ChartDataPoint\|ChartSeries" AIRecording/ Tests/ --include="*.swift" | grep -v "ChartSkill.swift"`
Expected: 只有 `Tests/AIRecordingTests/SmartChartTests.swift` 中的测试辅助代码引用它们（`successResponseJSON` 构造的 JSON 字符串、`testEarliestSourceUsesStartTimeInsteadOfArrayOrder` 只用 `ChartSourceResolver`）。若有生产代码引用，停下来评估后再决定保留范围。同时确认 `Package.swift` 没有显式列出已删除的 `ChartPanelView.swift`：`grep -n "ChartPanelView" Package.swift` 应无输出。

- [ ] **Step 2: 更新失败测试**

2a. `SmartChartTests.swift` 全文替换 health JSON 中的版本号：`"apiVersion":"3.0"` → `"4.0"`，`"serviceVersion":"3.1.0"` → `"4.0.0"`；把 `testHealthRequiresV3Protocol` 改名为 `testHealthRequiresV4Protocol`（断言 apiVersion 为 `"4.0"`）；`testSupportedHealthRequiresMatchingServiceVersion` 期望 `"4.0.0"`。

2b. `successResponseJSON(requestId:)` 改为 v4 载荷：

```swift
private func successResponseJSON(requestId: String) -> String {
    """
    {
      "version": "4.0",
      "requestId": "\(requestId)",
      "status": "success",
      "contentType": "meeting",
      "contentTypeDisplayName": "会议",
      "chartType": "decision_board",
      "chartTypeDisplayName": "决策行动看板",
      "title": "测试图表",
      "htmlFragment": "<div data-segment-ids=\\"s1\\">ok</div>",
      "plan": {"chartType": "decision_board", "title": "测试图表", "topics": []},
      "errors": []
    }
    """
}
```

2c. 新增测试（用 `httpOK` 直接构造响应，不依赖可能变化的辅助签名；`makeService`/`makeRequest`/`bodyData`/`successResponseJSON` 为文件内现有辅助）：

```swift
private func httpOK(_ url: URL) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
}

private let healthV4JSON = #"{"status":"ok","apiVersion":"4.0","serviceVersion":"4.0.0","llmConfigured":true}"#

func testResponseDecodesContentTypeFields() async throws {
    let service = makeService { request in
        if request.url?.path == "/health" {
            return (self.httpOK(request.url!), Data(self.healthV4JSON.utf8))
        }
        return (self.httpOK(request.url!), Data(self.successResponseJSON(requestId: "r1").utf8))
    }
    let result = try await service.generate(request: makeRequest(requestId: "r1"))
    XCTAssertEqual(result.contentType, .meeting)
    XCTAssertEqual(result.contentTypeDisplayName, "会议")
    XCTAssertEqual(result.chartType, "decision_board")
    XCTAssertEqual(result.chartTypeDisplayName, "决策行动看板")
}

func testForceContentTypeIsEncodedWhenSet() async throws {
    var capturedBody: Data?
    let service = makeService { request in
        if request.url?.path == "/health" {
            return (self.httpOK(request.url!), Data(self.healthV4JSON.utf8))
        }
        capturedBody = self.bodyData(from: request)
        return (self.httpOK(request.url!), Data(self.successResponseJSON(requestId: "r1").utf8))
    }
    var request = makeRequest(requestId: "r1")
    request.forceContentType = .lecture
    _ = try await service.generate(request: request)
    let json = try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any]
    XCTAssertEqual(json?["forceContentType"] as? String, "lecture")
    XCTAssertEqual(json?["version"] as? String, "4.0")
}

func testForceContentTypeOmittedWhenNil() async throws {
    var capturedBody: Data?
    let service = makeService { request in
        if request.url?.path == "/health" {
            return (self.httpOK(request.url!), Data(self.healthV4JSON.utf8))
        }
        capturedBody = self.bodyData(from: request)
        return (self.httpOK(request.url!), Data(self.successResponseJSON(requestId: "r1").utf8))
    }
    _ = try await service.generate(request: makeRequest(requestId: "r1"))
    let json = try JSONSerialization.jsonObject(with: XCTUnwrap(capturedBody)) as? [String: Any]
    XCTAssertNil(json?["forceContentType"])
}
```

Run: `swift test --filter SmartChartTests`
Expected: 编译失败（`ContentType` 不存在 / `forceContentType` 不存在 / `chartType` 类型不匹配）

- [ ] **Step 3: 修改 ChartSkill.swift**

3a. 把 `enum VisualizationKind`（约 line 5-25）整体替换为：

```swift
enum ContentType: String, CaseIterable, Codable {
    case meeting, interview, lecture, dialogue, speech, memo, other

    var displayName: String {
        switch self {
        case .meeting: return "会议"
        case .interview: return "访谈"
        case .lecture: return "讲座"
        case .dialogue: return "对话"
        case .speech: return "演讲"
        case .memo: return "随手记"
        case .other: return "其他"
        }
    }
}
```

3b. `SmartChartGenerateRequest` 增加 `forceContentType` 并把默认版本改为 `"4.0"`：

```swift
struct SmartChartGenerateRequest: Codable {
    var version: String
    var requestId: String
    var recordingId: String
    var segments: [TranscriptSegmentDTO]
    var summaryMarkdown: String?
    var forceContentType: ContentType?

    init(
        version: String = "4.0",
        requestId: String = UUID().uuidString,
        recordingId: String,
        segments: [TranscriptSegmentDTO],
        summaryMarkdown: String? = nil,
        forceContentType: ContentType? = nil
    ) {
        self.version = version
        self.requestId = requestId
        self.recordingId = recordingId
        self.segments = segments
        self.summaryMarkdown = summaryMarkdown
        self.forceContentType = forceContentType
    }
}
```

3c. `SmartChartGenerateResponse` 替换为（`chartType` 变为 `String`，新增 contentType 字段，删除 `plan`）：

```swift
struct SmartChartGenerateResponse: Codable {
    var version: String
    var requestId: String
    var status: String
    var contentType: ContentType
    var contentTypeDisplayName: String
    var chartType: String
    var chartTypeDisplayName: String
    var title: String
    var htmlFragment: String
    var errors: [String]
    var errorCode: String?
}
```

3d. 删除 3a 之后悬空的旧 DTO（以 Step 1 的 grep 结果为准）：`ChartItem`、`ChartRelation`、`ChartDataPoint`、`ChartSeries`、`HighlightSentence`、`ChartPlan`。同步删除 `SmartChartTests.swift` 中引用它们的辅助代码（若有）。保留 `ChartSourceResolver`、`ChartStatus`、`ChartSkillError`、legacy `ChartResult`/`ChartStyleConfig`（如 grep 证明其自洽）。

- [ ] **Step 4: 修改 HTTPChartSkill.swift 与 ChartServiceManager.swift**

4a. `HTTPChartSkill.swift:6-8` 区域：

```swift
let skillId = "chart.agent.v4"
let skillVersion = "4.0.0"
```

4b. `ChartServiceManager.swift:10`：

```swift
nonisolated static let expectedServiceVersion = "4.0.0"
```

同文件 `isSupportedHealth` 中的字面量 `"3.0"` 改为 `"4.0"`：

```swift
nonisolated static func isSupportedHealth(_ health: ChartHealthInfo) -> Bool {
    health.status == "ok" && health.apiVersion == "4.0" && health.serviceVersion == expectedServiceVersion
}
```

- [ ] **Step 5: 修改 RecordingDetailViewModel.swift**

把 `func generateChart()`（约 line 300）的签名与请求构造改为：

```swift
func generateChart(forcedType: ContentType? = nil) {
```

请求构造处（函数体内构建 `SmartChartGenerateRequest` 的位置）增加 `forceContentType`：

```swift
let request = SmartChartGenerateRequest(
    requestId: UUID().uuidString,
    recordingId: recording?.id?.uuidString ?? objectID.uriRepresentation().absoluteString,
    segments: segmentDTOs,
    summaryMarkdown: summary,
    forceContentType: forcedType
)
```

其余逻辑（gate token、错误映射、`isGeneratingChart`）不变。所有现有调用点 `generateChart()` 因默认参数无需改动。

- [ ] **Step 6: 运行 Swift 测试**

Run: `swift test --filter SmartChartTests`
Expected: 全部通过

- [ ] **Step 7: Commit**

```bash
git add AIRecording/Services/ChartSkill.swift AIRecording/Services/HTTPChartSkill.swift \
        AIRecording/Services/ChartServiceManager.swift AIRecording/ViewModels/RecordingDetailViewModel.swift \
        Tests/AIRecordingTests/SmartChartTests.swift
git commit -m "feat: Swift 端图表v4契约——ContentType、强制类型请求与版本门 4.0"
```

---

## Task 14: 图表面板 UI（类型标签 + 指定类型重新生成）

**Files:**
- Modify: `AIRecording/Views/RecordingDetailView.swift`（`chartPanelView`，约 line 426 起）

- [ ] **Step 1: 修改类型标签**

把 `chartPanelView` 中的：

```swift
Text(chart.chartTypeDisplayName)
    .font(.caption)
    .foregroundStyle(.secondary)
```

改为：

```swift
Text("\(chart.contentTypeDisplayName) · \(chart.chartTypeDisplayName)")
    .font(.caption)
    .foregroundStyle(.secondary)
```

- [ ] **Step 2: 在"重新生成"按钮旁加类型菜单**

把 `HStack(spacing: 8) { ... }` 中 `Button("重新生成")` 之后追加：

```swift
Menu {
    Button("自动识别") { viewModel.generateChart() }
    Divider()
    ForEach(ContentType.allCases, id: \.self) { type in
        Button(type.displayName) { viewModel.generateChart(forcedType: type) }
    }
} label: {
    Image(systemName: "ellipsis.circle")
}
.menuStyle(.borderlessButton)
.menuIndicator(.hidden)
.fixedSize()
```

- [ ] **Step 3: 构建与测试**

Run: `swift build && swift test --filter SmartChartTests`
Expected: 构建成功、测试通过

- [ ] **Step 4: Commit**

```bash
git add AIRecording/Views/RecordingDetailView.swift
git commit -m "feat: 图表面板类型标签与指定类型重新生成菜单"
```

---

## Task 15: 文档更新与全量验证

**Files:**
- Modify: `ChartAgent/README.md`
- Modify: `docs/TechSpec-ChartAgent.md`
- Modify: `AGENTS.md`

- [ ] **Step 1: 更新 ChartAgent/README.md**

把文件开头到"## 工作方式"一节末尾（当前第 1-11 行）替换为：

```markdown
# ChartAgent

AIRecording 的智能图表服务（v4）：按录音内容类型路由到专属图表 skill。使用 FastAPI、LangGraph、Pydantic 和 Jinja2。

## 工作方式

1. 内容分类器（1 次 LLM 调用）把录音判定为七种内容类型之一：会议、访谈、讲座、对话、演讲、随手记、其他；置信度不足或失败归"其他"。
2. 每种类型由 `agent/skills/` 下的专属 skill 处理，固定产出一种图表：会议→决策行动看板、访谈→问答观点卡、讲座→知识大纲树、对话→话题泳道图、演讲→叙事弧线图、随手记→灵感要点卡、其他→重点句子。
3. skill 内：按片段边界分块并行提取 → 合并 → 溯源校验（金句逐字、提炼字段数字一致）→ 一次修复 → 确定性 Jinja2 模板渲染 HTML + 内联 SVG（无 JavaScript）。
4. 任何环节失败都沿"类型内兜底 → 重点句子"降级，保证任何录音都有输出；请求带 `forceContentType` 时跳过分类器。
```

并把第 49 行"健康响应中的 `apiVersion` 必须为 `3.0`。"改为"健康响应中的 `apiVersion` 必须为 `4.0`，`serviceVersion` 为 `4.0.0`。"

- [ ] **Step 2: docs/TechSpec-ChartAgent.md 加指引**

在文件顶部追加一行：

```markdown
> 2026-07-17：本文描述的部分 v3 内容已被 v4 设计取代，见 `docs/superpowers/specs/2026-07-17-smartchart-content-type-skills-design.md`。
```

- [ ] **Step 3: AGENTS.md 设计文档清单补充**

在 `AGENTS.md` 的 "Design docs" 一节的文档列表中追加：

```markdown
- `docs/superpowers/specs/2026-07-17-smartchart-content-type-skills-design.md` — 智能图表 v4（按内容类型路由到七种专属图表 skill）
```

- [ ] **Step 4: 全量验证**

```bash
cd ChartAgent && PYTHONPATH=. python3 -m unittest discover -s tests -v
cd .. && swift build && swift test
```

Expected: Python 全绿、Swift 构建成功、全部测试通过。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/README.md docs/TechSpec-ChartAgent.md AGENTS.md
git commit -m "docs: 图表v4文档更新——README/TechSpec/AGENTS 同步"
```

---

## 完成后的手工验收（不阻塞，建议执行）

1. 启动应用，`ChartServiceManager` 应自动驱逐旧后端并拉起 4.0.0 服务（日志 `~/Library/Logs/AIRecording/chart-agent.log`）。
2. 对一段会议录音生成图表：面板应显示"会议 · 决策行动看板"，议题/结论/行动项结构化展示，点击卡片跳转音频。
3. 用省略号菜单强制以"讲座"重新生成同一段录音：应显示"讲座 · 知识大纲树"（内容不足时降级为重点句子，此时显示"讲座 · 重点句子"——类型标签保留分类/指定结果，图表形态降级）。


---

## 附录：执行期修订记录（评审驱动，已落实到代码与测试）

以下为执行过程中由代码评审触发、并已提交修复的偏差汇总；相关任务的代码块以仓库当前代码为准。

**Task 10 dialogue（commit 992cd49）**：
1. `validate` 来源时间查找改用 `filter_known_segment_ids` 过滤后的 ids（混合未知 id 不再抛 KeyError）
2. `normalize` 统计未知 id 丢弃的块数计入 `truncatedCount`；`title[:20]`、`summary[:20]` 截断
3. 说话人溢出合并对「其他人」去重
4. `fallback` 增加说话人归属检查
5. `layout_swimlane` 重写：泳道内按 x 贪心分配**子行**防最小宽度块重叠（碰撞判定 `>=`，首尾相接也分行）；块颜色按泳道编码（fill/textColor 由 lane 决定）；`label` 按块宽截断（≈(w−12)/11 字）；零宽块 clamp（w≥12 并回缩 x）；泳道携带动态 `height`；说话人名截 6 字
6. 模板：泳道标签/分隔线按 `lane.height` 定位；块文本用截断后的 `block.label`
7. 新增 5 个测试（混合 id 容错、子行堆叠、颜色随泳道、丢弃计数、标签截断）

**Task 11 speech（commit 71c7aed）**：
1. `normalize` 长度强制：`label[:10]`、`summary[:20]`、`quote[:30]`（SVG 文本不换行不裁剪，提示词长度上限必须代码强制）
2. `_STAGE_POINTS` 端点内移并贴合弧线：opening (70,178)、closing (790,115)（原 x=40/820 居中文字会裁出 860 宽 viewBox）；climax 保持 (560,58)
3. `layout_arc` 端点（opening/closing）摘要展示截断至 14 字
4. 清理未使用的 `normalize_text` import 与 `MAX_STAGES` 常量
5. 新增 2 个测试（长度截断、端点文字界内）

**Task 12 流水线（commits 3865b55 / f579bc9 / 18dec5a）**：
1. `nodes.classify_content` 加 5 行桥接：调用期间临时把 `classifier.call_llm` 绑定为 nodes 当前 `call_llm`（finally 恢复）——测试桩 `patch.object(nodes, "call_llm")` 才能拦截分类调用；生产环境两处引用本就相同，幂等
2. dialogue 时间校验语义放宽（validate/fallback 一致）：只锚定块 start 落在来源片段范围 ±0.5s 内，不再校验 end（end 表示"持续到下一话题"，仅影响块宽布局，不影响溯源）
3. `other.validate` 时间戳改 None 判断（`or -1` 会误杀合法 0.0 起点，导致降级路径白跑一次修复 LLM）
4. `_error_html` 恢复 `html.escape`；`render_chart_node` 异常恢复 `log_event("ERROR", "render", ...)`；分类日志去掉 LLM 自由文本 `reason` 字段（防转写内容入日志）
5. 超时测试 `sleep(30)→sleep(10)`（套件提速 ~20s）

**终审修复（commit 0eec3fd）**：
1. 分类器 10s 预算落实（spec §5）：`CLASSIFY_RESERVED_SECONDS = 10.0`，传入分类器的 deadline 钳制为 `min(deadline, now+10s)`
2. 置信度钳制：NaN→0.0（维持归 other 语义），钳到 [0,1]（inf 不再进入日志）
3. truncatedCount 一律代码计算、不透传 LLM 值（memo/meeting/interview/speech normalize→0；lecture/dialogue→各自 dropped 计数）
4. lecture 剔除死数据 note 字段（提示词/模型/normalize/夹具同步清理）
5. dialogue merge「其他人」去重；other.validate 去掉函数级重复 import

**既往同步（已直接写回对应任务代码块）**：textutils 数字边界匹配（Task 1）；分类器加固（Task 3）；重点句子截断标注（Task 5）；memo coreIdea 数字校验与兜底计数（Task 6）；meeting 合并去重/due 校验/兜底计数（Task 7）；interview 金句数字防扭曲与兜底重建 ids（Task 8）；lecture 概念丢弃计数/SVG 长度强制/主题数字校验（Task 9）；dialogue 时间校验倒置区间修正与摘要数字校验（Task 10 主体）；speech 摘要与金句数字校验、兜底一致性（Task 11 代码块已含）。
