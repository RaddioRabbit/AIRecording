# 智能图表内容丰富化（v5）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让七类智能图表从"骨架碎片"加厚为"总览 + 分区结构化内容"，用户看图表即可抓到原录音的结论、待办与关键信息点。

**Architecture:** 保持 v4"分类 → 分块提取 → 合并 → 校验 → 渲染"流水线不动。在分类后新增 `generate_overview` 节点（独立 15s 预算，失败不阻塞），产出一句话总览注入 plan，由 `BASE_TEMPLATE` 统一渲染总览条；六个 LLM skill 的提示词/字段/模板加厚（会议、访谈、讲座、对话、演讲、随手记），校验与降级逻辑同步适配。改动全部在 `ChartAgent/`（Python），Swift 侧零改动。

**Tech Stack:** Python 3 + FastAPI + LangGraph + pydantic + Jinja2（内联模板）；测试用 stdlib unittest，运行方式 `cd ChartAgent && PYTHONPATH=. python3 -m unittest discover -s tests -v`。

**Spec:** `docs/superpowers/specs/2026-07-22-smartchart-content-richness-design.md`

**工作目录：** 所有操作在 worktree `/Volumes/HP P900/mac/WorkPlace/AIRecording-smartchart`（分支 `feature/smartchart-content-richness`）中进行。

---

## 关键背景（执行者必读）

- 所有 skill 在 `ChartAgent/agent/skills/`，每个文件包含：`_PROMPT`（提取提示词）、`_TEMPLATE`（Jinja2 内联模板）、pydantic 私有模型、`XxxSkill(BaseSkill)`（normalize/merge/is_empty/validate/fallback/render）。
- 测试桩约定：`tests/test_pipeline.py` 用 `patch.object(nodes, "call_llm", side_effect=fake)`，fake 按提示词内容路由响应，**未预期的提示词会 raise AssertionError**——新增任何 LLM 调用都必须同步更新这些 fake。
- `validate_render` 要求渲染结果含 `data-segment-ids` 且 div 平衡。
- LLM `max_tokens` 在 `ChartAgent/agent/llm_client.py:100`（当前 4096）。

---

### Task 1: 总览条渲染基础（BASE_TEMPLATE + CSS）

所有模板都继承 `templates.py` 的 `BASE_TEMPLATE`，在徽章与内容块之间插入总览条，七类图表（含 highlights 兜底）一次到位。

**Files:**
- Modify: `ChartAgent/agent/templates.py:84-91`（`_BASE_TEMPLATE`）、`:6-81`（`DARK_CSS`）
- Test: `ChartAgent/tests/test_skills.py`（`RenderFoundationTests`）

- [ ] **Step 1: 写失败测试**

在 `ChartAgent/tests/test_skills.py` 的 `RenderFoundationTests` 类中追加：

```python
    def test_base_template_renders_overview_when_present(self):
        plan = highlights_plan()
        plan["overview"] = "本次录音讨论了私有化部署的排期与分工。"
        html = render_highlights(plan, "darkCyberpunk", "重点句子")
        self.assertIn("sc-overview", html)
        self.assertIn("本次录音讨论了私有化部署的排期与分工。", html)

    def test_base_template_omits_overview_when_absent(self):
        html = render_highlights(highlights_plan(), "darkCyberpunk", "重点句子")
        self.assertNotIn("sc-overview", html)

    def test_overview_css_class_exists(self):
        self.assertIn(".sc-overview", DARK_CSS)
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.RenderFoundationTests -v`
Expected: 3 个新测试 FAIL（`sc-overview` 未定义）

- [ ] **Step 3: 实现**

`ChartAgent/agent/templates.py` 的 `DARK_CSS` 末尾（`.sc-truncate-note` 行之后）追加：

```python
.sc-overview{background:#232742;border-left:3px solid #7aa2ff;color:#c6cbe0;font-size:13px;line-height:1.7;padding:10px 14px;border-radius:0 8px 8px 0;margin-bottom:14px}
.sc-section-label{color:#6f7590;font-size:11px;letter-spacing:1px;margin:10px 0 4px}
.sc-point{color:#b8bdd4;font-size:12.5px;line-height:1.7;padding-left:14px;position:relative}
.sc-disagreement{color:#e8b96a}
```

`_BASE_TEMPLATE` 改为：

```python
_BASE_TEMPLATE = """
<style>{{ dark_css | safe }}</style>
<div class="smartchart-container">
  {% if title %}<div class="smartchart-title">{{ title }}</div>{% endif %}
  <div class="smartchart-kind-badge">{{ kind_display_name }}</div>
  {% if plan.overview %}<div class="sc-overview">{{ plan.overview }}</div>{% endif %}
  {% block chart_content %}{% endblock %}
</div>
"""
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills -v`
Expected: 全部 PASS（旧测试不受影响）

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/templates.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 基础模板新增总览条渲染与样式"
```

---

### Task 2: 全局总览节点（overview 模块 + 流水线接入 + max_tokens 8192）

**Files:**
- Create: `ChartAgent/agent/overview.py`
- Modify: `ChartAgent/agent/nodes.py`、`ChartAgent/agent/graph.py`、`ChartAgent/agent/llm_client.py:100`
- Test: `ChartAgent/tests/test_overview.py`（新建）、`ChartAgent/tests/test_pipeline.py`（fakes 适配）

- [ ] **Step 1: 写失败测试**

新建 `ChartAgent/tests/test_overview.py`：

```python
"""全局总览（v5）：采样、解析、节点行为（正常/异常/截断）、端到端渲染。LLM 全部打桩。"""
import json
import unittest
from unittest.mock import patch

from agent import nodes
from agent.graph import chart_agent
from agent.overview import MAX_OVERVIEW_CHARS, build_overview_prompt, parse_overview

from tests.test_pipeline import MEETING_PLAN, MEETING_SEGMENTS, base_state, classify_response


class OverviewPromptTests(unittest.TestCase):
    def test_prompt_contains_samples_and_type(self):
        text = "\n".join(f"[s{i}] 甲: 内容{i}" for i in range(200))
        prompt = build_overview_prompt(text, "会议")
        self.assertIn("会议", prompt)
        self.assertIn("【开头】", prompt)
        self.assertIn("【中间】", prompt)
        self.assertIn("【结尾】", prompt)
        self.assertIn("总览撰写器", prompt)

    def test_prompt_sampling_budget(self):
        text = "x" * 20000
        prompt = build_overview_prompt(text, "会议")
        # 头 3000 + 中 2000 + 尾 2000，加上模板文字，总长度有界
        self.assertLess(len(prompt), 8000)


class OverviewParseTests(unittest.TestCase):
    def test_parse_normal_json(self):
        self.assertEqual(parse_overview('{"overview":"讨论了部署安排"}'), "讨论了部署安排")

    def test_parse_truncates_at_100_chars(self):
        long_text = "总" * 150
        result = parse_overview(json.dumps({"overview": long_text}))
        self.assertEqual(len(result), MAX_OVERVIEW_CHARS)

    def test_parse_bad_json_returns_none(self):
        self.assertIsNone(parse_overview("不是 JSON"))

    def test_parse_missing_field_returns_none(self):
        self.assertIsNone(parse_overview('{"foo":"bar"}'))


class OverviewNodeTests(unittest.TestCase):
    def test_node_stores_overview_on_success(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了部署排期"}, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        state = base_state(MEETING_SEGMENTS, content_type="meeting")
        nodes.prepare_transcript(state)
        with patch.object(nodes, "call_llm", side_effect=fake):
            state = nodes.generate_overview(state)
        self.assertEqual(state["overview"], "会议确认了部署排期")
        self.assertEqual(state["status"], "success")

    def test_node_llm_failure_yields_none_and_continues(self):
        def fake(prompt, temperature=0.3, deadline=None):
            from agent.llm_client import LLMError
            raise LLMError(LLMError.TIMEOUT, "超时")

        state = base_state(MEETING_SEGMENTS, content_type="meeting")
        nodes.prepare_transcript(state)
        with patch.object(nodes, "call_llm", side_effect=fake):
            state = nodes.generate_overview(state)
        self.assertIsNone(state["overview"])
        self.assertEqual(state["status"], "success")  # 不阻塞主流程

    def test_node_bad_json_yields_none_and_continues(self):
        def fake(prompt, temperature=0.3, deadline=None):
            return "这不是 JSON"

        state = base_state(MEETING_SEGMENTS, content_type="meeting")
        nodes.prepare_transcript(state)
        with patch.object(nodes, "call_llm", side_effect=fake):
            state = nodes.generate_overview(state)
        self.assertIsNone(state["overview"])
        self.assertEqual(state["status"], "success")


class OverviewEndToEndTests(unittest.TestCase):
    def test_pipeline_renders_overview_bar(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了部署排期与分工"}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError(f"未预期的提示词: {prompt[:100]}")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertIn("sc-overview", result["html_fragment"])
        self.assertIn("会议确认了部署排期与分工", result["html_fragment"])
        self.assertEqual(result["plan"]["overview"], "会议确认了部署排期与分工")

    def test_pipeline_without_overview_still_renders(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                from agent.llm_client import LLMError
                raise LLMError(LLMError.TIMEOUT, "超时")
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError(f"未预期的提示词: {prompt[:100]}")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertNotIn("sc-overview", result["html_fragment"])
        self.assertIn("私有化部署", result["html_fragment"])  # 图表主体不受影响


if __name__ == "__main__":
    unittest.main()
```

同时在 `ChartAgent/tests/test_pipeline.py` 的 `router_fake` 中加入总览分支（放在分类器分支之后）：

```python
def router_fake(extraction_marker, extraction_plan, classify_type):
    def fake(prompt, temperature=0.3, deadline=None):
        if "内容分类器" in prompt:
            return classify_response(classify_type)
        if "总览撰写器" in prompt:
            return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
        if extraction_marker and extraction_marker in prompt:
            return json.dumps(extraction_plan, ensure_ascii=False)
        raise AssertionError(f"未预期的提示词: {prompt[:100]}")
    return fake
```

再给 `test_pipeline.py` 中四个局部 fake 各加同样的两行分支（位置：紧随 `"内容分类器"` 分支之后）：
`test_forced_content_type_skips_classifier`、`test_low_confidence_falls_back_to_other`、`test_invalid_plan_repaired_once_then_highlights`、`test_endpoint_passes_force_content_type`：

```python
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
```

注意：
- `test_forced_content_type_skips_classifier` 与 `test_endpoint_passes_force_content_type` 的 fake 中，总览分支要放在 `"内容分类器"` 分支（raise AssertionError）之后、提取分支之前——总览节点在强制类型时仍会调用 LLM。
- `test_all_chunk_extraction_failures_degrade_to_highlights` 与 `test_classifier_llm_failure_falls_back_to_other` 的 fake 对非分类器调用一律 raise LLMError，总览节点会捕获并置 None，**无需改动**。

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_overview -v`
Expected: FAIL（`agent.overview` 模块不存在 / `nodes.generate_overview` 不存在）

- [ ] **Step 3: 实现**

**3a. 新建 `ChartAgent/agent/overview.py`：**

```python
"""全局总览（v5）：一段话概括整段录音。独立时间预算，失败不阻塞主流程。"""
from typing import Optional

from .textutils import parse_llm_json

MAX_OVERVIEW_CHARS = 100
_HEAD_CHARS = 3000
_MID_CHARS = 2000
_TAIL_CHARS = 2000

_PROMPT = """你是录音内容总览撰写器。根据采样文本，用一段话概括这段{type_name}录音：讲了什么主题、得出了什么结论、有哪些待办事项。
要求：
1. 只写一段话，不超过 100 字。
2. 只基于采样文本中明确出现的信息，禁止编造。
3. 不要分点、不要用引号包裹整段。
只输出严格 JSON：
{{"overview":"..."}}
采样文本：
【开头】
{head}
【中间】
{mid}
【结尾】
{tail}
"""


def _sample(transcript_text: str):
    head = transcript_text[:_HEAD_CHARS]
    tail = transcript_text[-_TAIL_CHARS:] if len(transcript_text) > _HEAD_CHARS else ""
    middle_start = max(len(transcript_text) // 2 - _MID_CHARS // 2, len(head))
    mid = transcript_text[middle_start:middle_start + _MID_CHARS]
    return head, mid, tail


def build_overview_prompt(transcript_text: str, type_display_name: str) -> str:
    head, mid, tail = _sample(transcript_text)
    return _PROMPT.format(type_name=type_display_name, head=head, mid=mid, tail=tail)


def parse_overview(raw: str) -> Optional[str]:
    try:
        data = parse_llm_json(raw)
    except ValueError:
        return None
    overview = data.get("overview")
    if not isinstance(overview, str) or not overview.strip():
        return None
    return overview.strip()[:MAX_OVERVIEW_CHARS]
```

**3b. `ChartAgent/agent/nodes.py`：**

导入处（`:14-20` 区域）追加：

```python
from .overview import build_overview_prompt, parse_overview
from .skills.base import CONTENT_TYPE_DISPLAY_NAMES, BaseSkill
```

（原 `from .skills.base import BaseSkill` 一行替换为上面这行。）

常量区（`:22-26`）追加：

```python
OVERVIEW_RESERVED_SECONDS = 15.0
```

在 `classify_content` 之后新增节点函数：

```python
def generate_overview(state: Dict[str, Any]) -> Dict[str, Any]:
    """全局总览：一段话概括整段录音。失败/超时/低质 → overview=None，不阻塞主流程。"""
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    state["overview"] = None
    try:
        deadline = state.get("deadline")
        overview_deadline = (
            min(deadline, time.monotonic() + OVERVIEW_RESERVED_SECONDS) if deadline is not None else None
        )
        type_name = CONTENT_TYPE_DISPLAY_NAMES.get(state.get("content_type") or "other", "其他")
        raw = _call_llm(
            build_overview_prompt(state.get("transcript_text", ""), type_name),
            temperature=0.3,
            deadline=overview_deadline,
        )
        state["overview"] = parse_overview(raw)
    except Exception as error:
        log_event("WARNING", "generate_overview", state.get("request_id"), state.get("recording_id"),
                  result="skipped", **safe_error_fields(error))
    log_event("INFO", "generate_overview", state.get("request_id"), state.get("recording_id"),
              hasOverview=state["overview"] is not None, elapsedMs=_elapsed_ms(started))
    return state
```

`render_chart_node`（`:298-313`）在 `plan = state.get("plan") or {}` 之后注入总览：

```python
    plan = state.get("plan") or {}
    if state.get("overview"):
        plan["overview"] = state["overview"]
        state["plan"] = plan
```

**3c. `ChartAgent/agent/graph.py`：**

- import 列表加 `generate_overview`。
- `ChartAgentState` 加一行：`overview: Optional[str]`。
- 接线改为：`classify_content → generate_overview → extract_structured`：

```python
    builder.add_node("generate_overview", generate_overview)
    ...
    builder.add_conditional_edges("classify_content", _continue_or_end, {"continue": "generate_overview", END: END})
    builder.add_conditional_edges("generate_overview", _continue_or_end, {"continue": "extract_structured", END: END})
```

（删除原 `classify_content → extract_structured` 那条。）

**3d. `ChartAgent/agent/llm_client.py:100`：** `max_tokens=4096` → `max_tokens=8192`。

**3e. `ChartAgent/main.py` 的初始 state（`:89-106`）加一行：** `"overview": None,`

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest discover -s tests -v`
Expected: 全部 PASS（含 test_pipeline 原有测试，fakes 已适配）

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/overview.py ChartAgent/agent/nodes.py ChartAgent/agent/graph.py ChartAgent/agent/llm_client.py ChartAgent/main.py ChartAgent/tests/test_overview.py ChartAgent/tests/test_pipeline.py
git commit -m "feat(chart): 新增全局总览节点，LLM max_tokens 提升至 8192"
```

---

### Task 3: meeting skill 加厚（背景/讨论要点/分歧）

**Files:**
- Modify: `ChartAgent/agent/skills/meeting.py`（全文涉及 `_PROMPT`、`_TEMPLATE`、`_Topic`、`normalize`、`merge`、`validate`、`fallback`）
- Test: `ChartAgent/tests/test_skills.py`（`MeetingSkillTests`）

- [ ] **Step 1: 写失败测试**

在 `MeetingSkillTests` 中追加（`meeting_raw` 保持不变——新字段全部可选，旧 fixture 仍合法）：

```python
    def test_normalize_keeps_rich_fields(self):
        raw = meeting_raw()
        raw["topics"][0]["background"] = "甲方要求数据不出内网"
        raw["topics"][0]["points"] = ["演示了知识库问答系统", "确认语义模糊匹配可用"]
        raw["topics"][0]["disagreements"] = ["部署时间未达成一致"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        topic = plan["topics"][0]
        self.assertEqual(topic["background"], "甲方要求数据不出内网")
        self.assertEqual(topic["points"], ["演示了知识库问答系统", "确认语义模糊匹配可用"])
        self.assertEqual(topic["disagreements"], ["部署时间未达成一致"])

    def test_normalize_truncates_rich_fields(self):
        raw = meeting_raw()
        raw["topics"][0]["background"] = "背" * 80
        raw["topics"][0]["points"] = ["点"] * 6
        raw["topics"][0]["disagreements"] = ["歧"] * 4
        plan = self.skill.normalize(raw, meeting_source_segments())
        topic = plan["topics"][0]
        self.assertEqual(len(topic["background"]), 60)
        self.assertEqual(len(topic["points"]), 4)
        self.assertEqual(len(topic["disagreements"]), 2)

    def test_validate_rejects_fabricated_point_numbers(self):
        raw = meeting_raw()
        raw["topics"][0]["points"] = ["预算砍了 30%"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("要点" in e and "数字" in e for e in errors))

    def test_merge_same_topic_unions_points_and_disagreements(self):
        plans = [
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "background": None, "points": ["要点甲"], "disagreements": [],
                         "conclusion": None, "actions": [], "segmentIds": ["s1"]}]},
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "background": "背景乙", "points": ["要点甲", "要点乙"],
                         "disagreements": ["分歧丙"], "conclusion": "结论乙", "actions": [], "segmentIds": ["s2"]}]},
        ]
        merged = self.skill.merge(plans)
        topic = merged["topics"][0]
        self.assertEqual(topic["points"], ["要点甲", "要点乙"])
        self.assertEqual(topic["disagreements"], ["分歧丙"])
        self.assertEqual(topic["background"], "背景乙")
        self.assertEqual(topic["conclusion"], "结论乙")

    def test_fallback_filters_fabricated_points(self):
        raw = meeting_raw()
        raw["topics"][0]["points"] = ["预算砍了 30%"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["topics"][0]["points"], [])

    def test_render_contains_rich_sections(self):
        raw = meeting_raw()
        raw["topics"][0]["background"] = "甲方要求数据不出内网"
        raw["topics"][0]["points"] = ["演示了知识库问答系统"]
        raw["topics"][0]["disagreements"] = ["部署时间未达成一致"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("甲方要求数据不出内网", html)
        self.assertIn("演示了知识库问答系统", html)
        self.assertIn("部署时间未达成一致", html)
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.MeetingSkillTests -v`
Expected: 新测试 FAIL（normalize 丢弃新字段 / 模板无新区块）

- [ ] **Step 3: 实现**（`ChartAgent/agent/skills/meeting.py`）

常量区替换为：

```python
MAX_TOPICS = 8
MAX_ACTIONS_PER_TOPIC = 6
MAX_POINTS_PER_TOPIC = 4
MAX_DISAGREEMENTS_PER_TOPIC = 2
```

`_PROMPT` 替换为：

```python
_PROMPT = """你是会议内容结构化提取器。从会议转写片段中提取议题、背景、讨论要点、分歧、结论与行动项。
要求：
1. topics：按议题组织，每个议题 title 不超过 20 字。
2. background：为什么讨论这个议题，不超过 60 字；原文没有相关背景时为 null。
3. points：该议题的关键讨论要点，1-4 条，每条不超过 50 字，必须来自原文明确表述。
4. disagreements：未达成一致的分歧或待定事项，0-2 条，每条不超过 40 字；没有则为空列表。
5. conclusion：该议题达成的结论，不超过 60 字；原文没有明确结论时为 null。
6. actions：行动项（任务/分工/截止时间），text 不超过 40 字；owner（负责人）与 due（时间）仅当原文明确时填写，否则为 null。行动项必须有原文依据（如"负责""完成""提供""对接""下周前"等表述）。
7. 每个议题必须携带来源 segmentIds（只用输入片段中的 id）。
8. 禁止编造原文没有的内容。
只输出严格 JSON：
{"chartType":"decision_board","title":"<会议主题，≤20字>","topics":[{"title":"...","background":null,"points":["..."],"disagreements":[],"conclusion":null,"actions":[{"text":"...","owner":null,"due":null}],"segmentIds":["..."]}]}
输入片段：
"""
```

`_TEMPLATE` 替换为：

```python
_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
{% for topic in plan.topics %}
<div class="sc-card sc-topic-card" data-segment-ids="{{ topic.segmentIds|join(',') }}">
  <div class="sc-topic-title">{{ topic.title }}</div>
  {% if topic.background %}
  <div class="sc-section-label">背景</div>
  <div class="sc-point">{{ topic.background }}</div>
  {% endif %}
  {% if topic.points %}
  <div class="sc-section-label">讨论要点</div>
  {% for point in topic.points %}<div class="sc-point">· {{ point }}</div>{% endfor %}
  {% endif %}
  {% if topic.disagreements %}
  <div class="sc-section-label">分歧 / 待定</div>
  {% for item in topic.disagreements %}<div class="sc-point sc-disagreement">· {{ item }}</div>{% endfor %}
  {% endif %}
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
```

`_Topic` 模型替换为：

```python
class _Topic(StrictModel):
    title: str = Field(min_length=1)
    background: Optional[str] = None
    points: List[str] = Field(default_factory=list)
    disagreements: List[str] = Field(default_factory=list)
    conclusion: Optional[str] = None
    actions: List[_Action] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)
```

`normalize` 中 topics.append 的字典替换为：

```python
            topics.append({
                "title": topic.title[:20],
                "background": topic.background[:60] if topic.background else None,
                "points": [p[:50] for p in topic.points[:MAX_POINTS_PER_TOPIC] if p.strip()],
                "disagreements": [d[:40] for d in topic.disagreements[:MAX_DISAGREEMENTS_PER_TOPIC] if d.strip()],
                "conclusion": topic.conclusion[:60] if topic.conclusion else None,
                "actions": [
                    {"text": a.text, "owner": a.owner, "due": a.due}
                    for a in topic.actions[:MAX_ACTIONS_PER_TOPIC]
                ],
                "segmentIds": ids,
            })
```

`merge` 中"同议题合并"分支（`if key in seen:` 块）替换为：

```python
                if key in seen:
                    # 同议题合并：补充新要点/分歧/行动项与来源，回填缺失的背景/结论
                    existing = next(t for t in topics if normalize_text(t["title"]) == key)
                    known_points = {normalize_text(p) for p in existing.get("points", [])}
                    for point in topic.get("points", []):
                        if normalize_text(point) not in known_points and len(existing["points"]) < MAX_POINTS_PER_TOPIC:
                            existing["points"].append(point)
                            known_points.add(normalize_text(point))
                    known_dis = {normalize_text(d) for d in existing.get("disagreements", [])}
                    for item in topic.get("disagreements", []):
                        if normalize_text(item) not in known_dis and len(existing["disagreements"]) < MAX_DISAGREEMENTS_PER_TOPIC:
                            existing["disagreements"].append(item)
                            known_dis.add(normalize_text(item))
                    if not existing.get("background") and topic.get("background"):
                        existing["background"] = topic["background"]
                    if not existing.get("conclusion") and topic.get("conclusion"):
                        existing["conclusion"] = topic["conclusion"]
                    known_actions = {normalize_text(a["text"]) for a in existing["actions"]}
                    for action in topic.get("actions", []):
                        if normalize_text(action["text"]) not in known_actions and len(existing["actions"]) < MAX_ACTIONS_PER_TOPIC:
                            existing["actions"].append(action)
                            known_actions.add(normalize_text(action["text"]))
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + topic.get("segmentIds", [])))
                    continue
```

`validate` 的 for 循环体内、行动项校验之前追加：

```python
            if topic.get("background") and not numbers_have_evidence(topic["background"], ids, segment_map):
                errors.append(f"议题{index + 1}背景数字与原文不符")
            for point_index, point in enumerate(topic.get("points", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"议题{index + 1}要点{point_index + 1}数字与原文不符")
            for dis_index, item in enumerate(topic.get("disagreements", [])):
                if not numbers_have_evidence(item, ids, segment_map):
                    errors.append(f"议题{index + 1}分歧{dis_index + 1}数字与原文不符")
```

`fallback` 中 `topics.append({**topic, ...})` 一行替换为：

```python
            background = topic.get("background")
            if background and not numbers_have_evidence(background, ids, segment_map):
                background = None
            points = [p for p in topic.get("points", []) if numbers_have_evidence(p, ids, segment_map)]
            disagreements = [d for d in topic.get("disagreements", []) if numbers_have_evidence(d, ids, segment_map)]
            topics.append({**topic, "background": background, "points": points,
                           "disagreements": disagreements, "conclusion": conclusion, "actions": actions})
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.MeetingSkillTests tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/meeting.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 会议看板加厚——背景/讨论要点/分歧字段"
```

---

### Task 4: interview skill 加厚（answerPoints + quote 替代 keyAnswer）

**Files:**
- Modify: `ChartAgent/agent/skills/interview.py`（`_PROMPT`、`_TEMPLATE`、`_QA`、`normalize`、`merge`、`validate`、`fallback`）
- Test: `ChartAgent/tests/test_skills.py`（`interview_raw` fixture + `InterviewSkillTests`）

- [ ] **Step 1: 更新 fixture 与受影响测试（先改测试，确认失败）**

`interview_raw()` 整体替换为：

```python
def interview_raw():
    return {
        "chartType": "qa_cards",
        "title": "私有化部署访谈",
        "qas": [
            {
                "question": "为什么坚持私有化部署？",
                "answerPoints": ["数据安全是底线，不接受云端方案"],
                "quote": "数据不能出内网，这是红线",
                "tags": ["数据安全"],
                "segmentIds": ["s2"],
            },
            {
                "question": "未来会扩展吗？",
                "answerPoints": ["先小范围试点，稳定后再推广"],
                "quote": "先做 5-6 人的盒子试点",
                "tags": ["扩展", "试点"],
                "segmentIds": ["s4"],
            },
        ],
    }
```

受影响的既有测试逐个修改：

- `test_validate_requires_verbatim_key_answer` 整体替换为：

```python
    def test_validate_requires_verbatim_quote(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["quote"] = "数据绝对不能出内网哦"  # 非原文逐字
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e for e in errors))
```

- `test_validate_rejects_numeric_distortion_in_key_answer` 整体替换为：

```python
    def test_validate_rejects_numeric_distortion_in_quote(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][1]["quote"] = "先做 56 人的盒子试点"  # 5-6 → 56 数字扭曲
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e or "数字" in e for e in errors))
```

- `test_merge_caps_at_10` 中 big fixture 的 qas 元素替换为：

```python
            {"question": f"问题{i}？", "answerPoints": ["数据不能出内网，这是红线"], "quote": None,
             "tags": [], "segmentIds": ["s2"]}
```

- `test_render_contains_question_answer_tags`、`test_fallback_resets_truncated_count`、`test_fallback_drops_question_with_fabricated_numbers`、`test_fallback_rebuilds_filtered_segment_ids`、`test_normalize_and_validate_pass`、`test_validate_requires_two_qa_pairs`：**不改**（新 fixture 下仍有效）。

新增测试：

```python
    def test_validate_rejects_fabricated_answer_point_numbers(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["answerPoints"] = ["预算砍了 30%"]
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("要点" in e and "数字" in e for e in errors))

    def test_validate_requires_answer_points(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["answerPoints"] = []
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("回答要点" in e for e in errors))

    def test_fallback_drops_qa_when_all_points_fabricated(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["answerPoints"] = ["预算砍了 30%"]
        plan["qas"][0]["quote"] = None
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNone(salvaged)  # 只剩 1 个问答 → 不满足进入条件

    def test_merge_same_question_unions_points(self):
        plans = [
            {"chartType": "qa_cards", "title": "t", "truncatedCount": 0, "qas": [
                {"question": "为什么私有化？", "answerPoints": ["要点甲"], "quote": None, "tags": [], "segmentIds": ["s2"]}]},
            {"chartType": "qa_cards", "title": "t", "truncatedCount": 0, "qas": [
                {"question": "为什么私有化？", "answerPoints": ["要点甲", "要点乙"], "quote": "原句", "tags": [], "segmentIds": ["s4"]}]},
        ]
        merged = self.skill.merge(plans)
        self.assertEqual(len(merged["qas"]), 1)
        self.assertEqual(merged["qas"][0]["answerPoints"], ["要点甲", "要点乙"])
        self.assertEqual(merged["qas"][0]["quote"], "原句")
        self.assertEqual(merged["qas"][0]["segmentIds"], ["s2", "s4"])

    def test_render_contains_points_and_quote(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("数据安全是底线，不接受云端方案", html)
        self.assertIn("数据不能出内网，这是红线", html)
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.InterviewSkillTests -v`
Expected: 多个测试 FAIL（`_QA` 仍要求 `keyAnswer`，`extra="forbid"` 使新 fixture 校验失败）

- [ ] **Step 3: 实现**（`ChartAgent/agent/skills/interview.py`）

常量区追加：

```python
MAX_ANSWER_POINTS = 3
```

`_PROMPT` 替换为：

```python
_PROMPT = """你是访谈内容结构化提取器。从访谈转写中提取问答对与观点要点。
要求：
1. qas：每个问答对包含 question（采访者的问题，≤30字，可为转述）、answerPoints（被访者的回答要点，1-3 条，每条 ≤60字，可提炼转述但必须忠于原文）、quote（被访者最有代表性的原句，逐字，≤60字，必要时截取；没有合适原句时为 null）、tags（1-3 个关键词）。
2. 每个问答对必须携带来源 segmentIds（只用输入片段中的 id）。
3. quote 必须逐字来自原文，禁止改写；answerPoints 中的数字必须与原文一致。
只输出严格 JSON：
{"chartType":"qa_cards","title":"<访谈主题，≤20字>","qas":[{"question":"...","answerPoints":["..."],"quote":null,"tags":["..."],"segmentIds":["..."]}]}
输入片段：
"""
```

`_TEMPLATE` 替换为：

```python
_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
{% for qa in plan.qas %}
<div class="sc-card sc-qa-card" data-segment-ids="{{ qa.segmentIds|join(',') }}">
  <div class="sc-qa-question">Q：{{ qa.question }}</div>
  {% for point in qa.answerPoints %}<div class="sc-point">· {{ point }}</div>{% endfor %}
  {% if qa.quote %}<div class="sc-qa-answer">&ldquo;{{ qa.quote }}&rdquo;</div>{% endif %}
  {% if qa.tags %}
  <div class="sc-qa-tags">{% for tag in qa.tags %}<span class="sc-tag">{{ tag }}</span>{% endfor %}</div>
  {% endif %}
</div>
{% endfor %}
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 个问答未展示</div>{% endif %}
{% endblock %}
"""
```

`_QA` 模型替换为：

```python
class _QA(StrictModel):
    question: str = Field(min_length=1)
    answerPoints: List[str] = Field(default_factory=list)
    quote: Optional[str] = None
    tags: List[str] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)
```

`normalize` 中 qas.append 的字典替换为：

```python
                qas.append({
                    "question": qa.question[:30],
                    "answerPoints": [p[:60] for p in qa.answerPoints[:MAX_ANSWER_POINTS] if p.strip()],
                    "quote": qa.quote[:60] if qa.quote else None,
                    "tags": qa.tags[:MAX_TAGS],
                    "segmentIds": ids,
                })
```

`merge` 替换为：

```python
    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "访谈要点")
        seen, qas = set(), []
        for plan in plans:
            for qa in plan.get("qas", []):
                key = normalize_text(qa["question"])
                if not key:
                    continue
                if key in seen:
                    existing = next(q for q in qas if normalize_text(q["question"]) == key)
                    known = {normalize_text(p) for p in existing.get("answerPoints", [])}
                    for point in qa.get("answerPoints", []):
                        if normalize_text(point) not in known and len(existing["answerPoints"]) < MAX_ANSWER_POINTS:
                            existing["answerPoints"].append(point)
                            known.add(normalize_text(point))
                    if not existing.get("quote") and qa.get("quote"):
                        existing["quote"] = qa["quote"]
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + qa.get("segmentIds", [])))
                    continue
                seen.add(key)
                qas.append(qa)
        truncated = max(0, len(qas) - MAX_QAS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "qa_cards",
            "title": title,
            "qas": qas[:MAX_QAS],
            "truncatedCount": truncated,
        }
```

`validate` 的 for 循环体替换为：

```python
        for index, qa in enumerate(qas):
            ids = qa.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"问答{index + 1}缺少有效来源片段")
                continue
            if not qa.get("answerPoints"):
                errors.append(f"问答{index + 1}缺少回答要点")
            for point_index, point in enumerate(qa.get("answerPoints", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"问答{index + 1}要点{point_index + 1}数字与原文不符")
            if qa.get("quote"):
                if not text_has_evidence(qa["quote"], ids, segment_map):
                    errors.append(f"问答{index + 1}的引文必须逐字来自原文")
                elif not numbers_have_evidence(qa["quote"], ids, segment_map):
                    errors.append(f"问答{index + 1}的引文数字与原文不符")
            if not numbers_have_evidence(qa.get("question"), ids, segment_map):
                errors.append(f"问答{index + 1}问题数字与原文不符")
```

`fallback` 替换为：

```python
    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        qas = []
        for qa in plan.get("qas", []):
            ids = filter_known_segment_ids(qa.get("segmentIds"), segment_map)
            if not ids:
                continue
            if not numbers_have_evidence(qa.get("question"), ids, segment_map):
                continue
            points = [p for p in qa.get("answerPoints", []) if numbers_have_evidence(p, ids, segment_map)]
            if not points:
                continue
            quote = qa.get("quote")
            if quote and not (
                text_has_evidence(quote, ids, segment_map) and numbers_have_evidence(quote, ids, segment_map)
            ):
                quote = None
            qas.append({**qa, "answerPoints": points, "quote": quote, "segmentIds": ids})
        if len(qas) < 2:
            return None
        return {**plan, "qas": qas, "truncatedCount": 0}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.InterviewSkillTests tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/interview.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 访谈卡片加厚——回答要点组 + 逐字引文"
```

---

### Task 5: lecture skill 加厚（概念恢复 note 解释 + 章节讲解要点）

note 放在章节卡内的概念列表中，**不进 SVG 树节点**（SVG 布局不变，避免几何溢出）。

**Files:**
- Modify: `ChartAgent/agent/skills/lecture.py`（`_PROMPT`、`_TEMPLATE`、`_Concept`、`_Chapter`、`normalize`、`merge`、`validate`、`fallback`、`render`）
- Test: `ChartAgent/tests/test_skills.py`（`LectureSkillTests`）

- [ ] **Step 1: 写失败测试**

`test_normalize_truncates_overlong_strings` 整体替换（章节限长 12→16，topic 仍为 16）：

```python
    def test_normalize_truncates_overlong_strings(self):
        raw = lecture_raw()
        raw["topic"] = "这是一个非常非常非常长的讲座主题名称"  # 17 字 → 截到 16
        raw["chapters"][0]["title"] = "这是一个非常非常非常非常长的章节标题"  # 18 字 → 截到 16
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["topic"]), 16)
        self.assertEqual(len(plan["chapters"][0]["title"]), 16)
```

新增测试：

```python
    def test_normalize_keeps_concept_note_and_chapter_points(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "查询键值三路投影"
        raw["chapters"][0]["points"] = ["注意力机制是 Transformer 的核心"]
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(plan["chapters"][0]["concepts"][0]["note"], "查询键值三路投影")
        self.assertEqual(plan["chapters"][0]["points"], ["注意力机制是 Transformer 的核心"])

    def test_normalize_truncates_note_and_points(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "注" * 50
        raw["chapters"][0]["points"] = ["点"] * 5
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["chapters"][0]["concepts"][0]["note"]), 40)
        self.assertEqual(len(plan["chapters"][0]["points"]), 3)

    def test_validate_rejects_fabricated_note_numbers(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "分为 3 层结构"
        plan = self.skill.normalize(raw, lecture_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("解释" in e and "数字" in e for e in errors))

    def test_merge_same_chapter_unions_points_and_concepts(self):
        plans = [
            {"chartType": "knowledge_tree", "title": "t", "topic": "t", "truncatedCount": 0,
             "chapters": [{"title": "注意力", "points": ["要点甲"],
                           "concepts": [{"name": "QKV", "note": None, "segmentIds": ["s1"]}], "segmentIds": ["s1"]}]},
            {"chartType": "knowledge_tree", "title": "t", "topic": "t", "truncatedCount": 0,
             "chapters": [{"title": "注意力", "points": ["要点甲", "要点乙"],
                           "concepts": [{"name": "QKV", "note": "三路投影", "segmentIds": ["s1"]},
                                        {"name": "多头", "note": None, "segmentIds": ["s1"]}], "segmentIds": ["s1"]}]},
        ]
        merged = self.skill.merge(plans)
        chapter = merged["chapters"][0]
        self.assertEqual(chapter["points"], ["要点甲", "要点乙"])
        self.assertEqual([c["name"] for c in chapter["concepts"]], ["QKV", "多头"])
        self.assertEqual(chapter["concepts"][0]["note"], "三路投影")

    def test_render_chapter_cards_contain_note_and_points(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "查询键值三路投影"
        raw["chapters"][0]["points"] = ["注意力机制是核心"]
        plan = self.skill.normalize(raw, lecture_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("<svg", html)  # SVG 树保留
        self.assertIn("查询键值三路投影", html)
        self.assertIn("注意力机制是核心", html)
```

注意：`test_merge_caps_chapters_at_8` 与 `test_layout_bounds_at_max_capacity` 的 fixture 已含 `"note": None`，新模型下仍合法，**不改**。

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.LectureSkillTests -v`
Expected: 新测试 FAIL（normalize 无 note/points 字段）

- [ ] **Step 3: 实现**（`ChartAgent/agent/skills/lecture.py`）

常量区追加：

```python
MAX_POINTS_PER_CHAPTER = 3
```

`_PROMPT` 替换为：

```python
_PROMPT = """你是讲座内容结构化提取器。把讲座转写整理为三级知识结构。
要求：
1. topic：讲座主题（≤16字）。
2. chapters：章节列表，每章 title ≤16字；points 为该章的讲解要点（1-3 条，每条 ≤50字，忠于原文）；concepts 为该章的概念要点，name ≤16字，note 为该概念的一句话解释（≤40字，原文没有解释时为 null）。
3. 每章、每个概念都必须携带来源 segmentIds（只用输入片段中的 id）。
4. 只提取原文明确讲到的知识内容，禁止补充原文没有的知识。
只输出严格 JSON：
{"chartType":"knowledge_tree","title":"<讲座主题>","topic":"...","chapters":[{"title":"...","points":["..."],"concepts":[{"name":"...","note":null,"segmentIds":["..."]}],"segmentIds":["..."]}]}
输入片段：
"""
```

`_TEMPLATE` 替换为（SVG 部分不变，尾部新增章节卡）：

```python
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
{% for chapter in plan.chapters %}
<div class="sc-card" data-segment-ids="{{ chapter.segmentIds|join(',') }}">
  <div class="sc-topic-title">{{ chapter.title }}</div>
  {% for point in chapter.points %}<div class="sc-point">· {{ point }}</div>{% endfor %}
  {% for concept in chapter.concepts %}
  <div class="sc-point" data-segment-ids="{{ concept.segmentIds|join(',') }}">◆ {{ concept.name }}{% if concept.note %} —— {{ concept.note }}{% endif %}</div>
  {% endfor %}
</div>
{% endfor %}
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 项未展示</div>{% endif %}
{% endblock %}
"""
```

`_Concept` / `_Chapter` 模型替换为：

```python
class _Concept(StrictModel):
    name: str = Field(min_length=1)
    note: Optional[str] = None
    segmentIds: List[str] = Field(min_length=1)


class _Chapter(StrictModel):
    title: str = Field(min_length=1)
    points: List[str] = Field(default_factory=list)
    concepts: List[_Concept] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)
```

`normalize` 中 concepts.append 与 chapters.append 替换为：

```python
                if concept_ids:
                    concepts.append({
                        "name": concept.name[:16],
                        "note": concept.note[:40] if concept.note else None,
                        "segmentIds": concept_ids,
                    })
```

```python
            chapters.append({
                "title": chapter.title[:16],
                "points": [p[:50] for p in chapter.points[:MAX_POINTS_PER_CHAPTER] if p.strip()],
                "concepts": concepts,
                "segmentIds": ids,
            })
```

`merge` 替换为：

```python
    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "讲座大纲")
        topic = next((p["topic"] for p in plans if p.get("topic")), title)
        seen, chapters = set(), []
        for plan in plans:
            for chapter in plan.get("chapters", []):
                key = normalize_text(chapter["title"])
                if not key:
                    continue
                if key in seen:
                    existing = next(c for c in chapters if normalize_text(c["title"]) == key)
                    known_points = {normalize_text(p) for p in existing.get("points", [])}
                    for point in chapter.get("points", []):
                        if normalize_text(point) not in known_points and len(existing["points"]) < MAX_POINTS_PER_CHAPTER:
                            existing["points"].append(point)
                            known_points.add(normalize_text(point))
                    known_concepts = {normalize_text(c["name"]) for c in existing.get("concepts", [])}
                    for concept in chapter.get("concepts", []):
                        ckey = normalize_text(concept["name"])
                        if ckey in known_concepts:
                            match = next(c for c in existing["concepts"] if normalize_text(c["name"]) == ckey)
                            if not match.get("note") and concept.get("note"):
                                match["note"] = concept["note"]
                            match["segmentIds"] = list(dict.fromkeys(match["segmentIds"] + concept.get("segmentIds", [])))
                        elif len(existing["concepts"]) < MAX_CONCEPTS_PER_CHAPTER:
                            existing["concepts"].append(concept)
                            known_concepts.add(ckey)
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + chapter.get("segmentIds", [])))
                    continue
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
```

`validate` 中章节循环内、概念校验之前追加 points 校验；概念校验的 `elif` 块替换为：

```python
            for point_index, point in enumerate(chapter.get("points", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"章节{index + 1}要点{point_index + 1}数字与原文不符")
            for concept in chapter.get("concepts", []):
                concept_ids = concept.get("segmentIds") or []
                if not filter_known_segment_ids(concept_ids, segment_map):
                    errors.append(f"章节{index + 1}概念「{concept.get('name', '?')}」缺少有效来源片段")
                elif not numbers_have_evidence(concept.get("name"), concept_ids, segment_map):
                    errors.append(f"章节{index + 1}概念「{concept.get('name', '?')}」数字与原文不符")
                elif concept.get("note") and not numbers_have_evidence(concept["note"], concept_ids, segment_map):
                    errors.append(f"章节{index + 1}概念「{concept.get('name', '?')}」解释数字与原文不符")
```

`fallback` 中 concepts 列表推导替换为：

```python
            concepts = []
            for c in chapter.get("concepts", []):
                concept_ids = filter_known_segment_ids(c.get("segmentIds"), segment_map)
                if not concept_ids or not numbers_have_evidence(c.get("name"), concept_ids, segment_map):
                    continue
                note = c.get("note")
                if note and not numbers_have_evidence(note, concept_ids, segment_map):
                    note = None
                concepts.append({**c, "note": note, "segmentIds": concept_ids})
            points = [p for p in chapter.get("points", []) if numbers_have_evidence(p, ids, segment_map)]
            chapters.append({**chapter, "points": points, "concepts": concepts, "segmentIds": ids})
```

`render` 不变（模板自己遍历 `plan.chapters`）。

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.LectureSkillTests tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/lecture.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 讲座大纲加厚——概念解释 note + 章节讲解要点"
```

---

### Task 6: dialogue skill 加厚（补渲染 summary + keyPoints + 话题块卡）

泳道 SVG 保持不变；在 SVG 下方新增每个话题块的卡片（说话人 · 话题 · 时间 · summary · 关键信息点）。

**Files:**
- Modify: `ChartAgent/agent/skills/dialogue.py`（`_PROMPT`、`_TEMPLATE`、`_Block`、`normalize`、`validate`、`fallback`、`render`）
- Test: `ChartAgent/tests/test_skills.py`（`DialogueSkillTests`）

- [ ] **Step 1: 写失败测试**

```python
    def test_normalize_keeps_key_points_and_long_summary(self):
        raw = dialogue_raw()
        raw["blocks"][0]["summary"] = "预算确实有限，需要省着点用，各项开支都要重新评估"
        raw["blocks"][0]["keyPoints"] = ["各项开支重新评估"]
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(plan["blocks"][0]["summary"], "预算确实有限，需要省着点用，各项开支都要重新评估")
        self.assertEqual(plan["blocks"][0]["keyPoints"], ["各项开支重新评估"])

    def test_normalize_truncates_rich_fields(self):
        raw = dialogue_raw()
        raw["blocks"][0]["topic"] = "这是一个非常非常长的话题名称"  # 15 字 → 截到 14
        raw["blocks"][0]["summary"] = "摘" * 70
        raw["blocks"][0]["keyPoints"] = ["点"] * 4
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(len(plan["blocks"][0]["topic"]), 14)
        self.assertEqual(len(plan["blocks"][0]["summary"]), 60)
        self.assertEqual(len(plan["blocks"][0]["keyPoints"]), 2)

    def test_validate_rejects_fabricated_key_point_numbers(self):
        raw = dialogue_raw()
        raw["blocks"][0]["keyPoints"] = ["预算砍了 30%"]
        plan = self.skill.normalize(raw, dialogue_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("信息点" in e and "数字" in e for e in errors))

    def test_render_block_cards_contain_summary_and_key_points(self):
        raw = dialogue_raw()
        raw["blocks"][0]["summary"] = "预算确实有限，要省着点用"
        raw["blocks"][0]["keyPoints"] = ["各项开支重新评估"]
        plan = self.skill.normalize(raw, dialogue_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("<svg", html)  # 泳道图保留
        self.assertIn("预算确实有限，要省着点用", html)  # summary 现在会被渲染
        self.assertIn("各项开支重新评估", html)
        self.assertIn("00:00", html)  # 块时间
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.DialogueSkillTests -v`
Expected: 新测试 FAIL（normalize 无 keyPoints / summary 被截到 20 字 / 模板无块卡）

- [ ] **Step 3: 实现**（`ChartAgent/agent/skills/dialogue.py`）

常量区追加：

```python
MAX_KEY_POINTS_PER_BLOCK = 2
```

`_PROMPT` 替换为：

```python
_PROMPT = """你是对话内容结构化提取器。把多人自由讨论整理为话题块。
要求：
1. speakers：说话人列表（使用片段中的 speaker 字段原值）。
2. blocks：话题块，包含 speaker（该话题的主导人）、topic（话题名，≤14字）、summary（这一话题聊了什么，≤60字，可为 null）、keyPoints（该话题的关键信息点，0-2 条，每条 ≤40字，必须来自原文明确表述）、start/end（该话题的起止时间，秒，来自片段时间）、segmentIds。
3. 话题块按时间顺序排列；只提取明确出现的话题，禁止臆测。
只输出严格 JSON：
{"chartType":"topic_swimlane","title":"<对话主题，≤20字>","speakers":["..."],"blocks":[{"speaker":"...","topic":"...","summary":null,"keyPoints":[],"start":0.0,"end":0.0,"segmentIds":["..."]}]}
输入片段：
"""
```

`_TEMPLATE` 替换为（SVG 部分不变，尾部新增块卡）：

```python
_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<svg viewBox="0 0 {{ layout.width|int }} {{ layout.height|int }}" width="100%" role="img" aria-label="话题泳道图">
  {% for lane in layout.lanes %}
  <text x="12" y="{{ '%.1f'|format(lane.y + lane.height / 2 + 4) }}" fill="{{ lane.color }}" font-size="12">{{ lane.name }}</text>
  <line x1="90" y1="{{ '%.1f'|format(lane.y + lane.height) }}" x2="{{ layout.width|int - 20 }}" y2="{{ '%.1f'|format(lane.y + lane.height) }}" stroke="#1E1E2E" stroke-width="1"/>
  {% endfor %}
  {% for block in layout.blocks %}
  <g data-segment-ids="{{ block.segmentIds|join(',') }}" style="cursor:pointer">
    <rect x="{{ '%.1f'|format(block.x) }}" y="{{ '%.1f'|format(block.y) }}" width="{{ '%.1f'|format(block.w) }}" height="{{ block.h|int }}" rx="8" fill="{{ block.fill }}"/>
    <text x="{{ '%.1f'|format(block.x + block.w / 2) }}" y="{{ '%.1f'|format(block.y + block.h / 2 + 4) }}" text-anchor="middle" fill="{{ block.textColor }}" font-size="11">{{ block.label }}</text>
  </g>
  {% endfor %}
  <text x="{{ layout.width|int - 20 }}" y="{{ layout.height|int - 10 }}" text-anchor="end" fill="#64748b" font-size="10">{{ layout.timeLabel }}</text>
</svg>
{% for block in plan.blocks %}
<div class="sc-card" data-segment-ids="{{ block.segmentIds|join(',') }}">
  <div class="sc-topic-title">{{ block.speaker }} · {{ block.topic }}</div>
  <div class="sc-meta">{{ mmss(block.start) }} – {{ mmss(block.end) }}</div>
  {% if block.summary %}<div class="sc-point">{{ block.summary }}</div>{% endif %}
  {% for point in block.keyPoints %}<div class="sc-point">· {{ point }}</div>{% endfor %}
</div>
{% endfor %}
{% if plan.truncatedCount %}<div class="sc-truncate-note">还有 {{ plan.truncatedCount }} 个话题块未展示</div>{% endif %}
{% endblock %}
"""
```

`_Block` 模型替换为：

```python
class _Block(StrictModel):
    speaker: str = Field(min_length=1)
    topic: str = Field(min_length=1)
    summary: Optional[str] = None
    keyPoints: List[str] = Field(default_factory=list)
    start: float
    end: float
    segmentIds: List[str] = Field(min_length=1)
```

`normalize` 中 blocks.append 的字典替换为：

```python
            blocks.append({
                "speaker": block.speaker if block.speaker in kept_set else OTHERS_LABEL,
                "topic": block.topic[:14],
                "summary": block.summary[:60] if block.summary else None,
                "keyPoints": [p[:40] for p in block.keyPoints[:MAX_KEY_POINTS_PER_BLOCK] if p.strip()],
                "start": start,
                "end": end,
                "segmentIds": ids,
            })
```

`validate` 中 summary 校验行之后追加：

```python
            for point_index, point in enumerate(block.get("keyPoints", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"话题块{index + 1}信息点{point_index + 1}数字与原文不符")
```

`fallback` 中 `blocks.append({**block, "segmentIds": ids})` 一行替换为：

```python
            key_points = [p for p in block.get("keyPoints", []) if numbers_have_evidence(p, ids, segment_map)]
            blocks.append({**block, "keyPoints": key_points, "segmentIds": ids})
```

`render` 替换为：

```python
    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        layout = self.layout_swimlane(plan.get("speakers", []), plan.get("blocks", []))
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title, layout=layout, mmss=format_mmss)
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.DialogueSkillTests tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/dialogue.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 对话泳道加厚——补渲染 summary + 话题块卡"
```

---

### Task 7: speech skill 加厚（阶段要点组）

弧线 SVG 保持不变；在 SVG 下方新增每个阶段的卡片（阶段名 · 小标题 · summary · 要点列表 · 金句）。

**Files:**
- Modify: `ChartAgent/agent/skills/speech.py`（`_PROMPT`、`_TEMPLATE`、`_Stage`、`normalize`、`merge`、`validate`、`fallback`、`render`）
- Test: `ChartAgent/tests/test_skills.py`（`SpeechSkillTests`）

- [ ] **Step 1: 写失败测试**

`test_normalize_truncates_label_summary_quote` 整体替换（限长 10/20/30 → 14/60/40）：

```python
    def test_normalize_truncates_label_summary_quote(self):
        raw = speech_raw()
        raw["stages"][0]["label"] = "这是一个非常非常长的小标题"  # 13 字 → 不截断；再验证超长的
        raw["stages"][1]["label"] = "这是一个特别特别特别长的小标题啊"  # 16 字 → 截到 14
        raw["stages"][0]["summary"] = "摘" * 70  # → 截到 60
        raw["stages"][2]["quote"] = "改变从今晚开始" + "句" * 40  # → 截到 40
        plan = self.skill.normalize(raw, speech_source_segments())
        self.assertEqual(len(plan["stages"][1]["label"]), 14)
        self.assertEqual(len(plan["stages"][0]["summary"]), 60)
        self.assertEqual(len(plan["stages"][2]["quote"]), 40)
```

新增测试：

```python
    def test_normalize_keeps_stage_points(self):
        raw = speech_raw()
        raw["stages"][2]["points"] = ["演讲者分享了自己的转折经历", "现场反响热烈"]
        plan = self.skill.normalize(raw, speech_source_segments())
        self.assertEqual(plan["stages"][2]["points"], ["演讲者分享了自己的转折经历", "现场反响热烈"])

    def test_validate_rejects_fabricated_point_numbers(self):
        raw = speech_raw()
        raw["stages"][0]["points"] = ["现场观众 500 人"]
        plan = self.skill.normalize(raw, speech_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("要点" in e and "数字" in e for e in errors))

    def test_merge_same_stage_unions_points(self):
        plans = [
            {"chartType": "narrative_arc", "title": "t", "truncatedCount": 0, "stages": [
                {"stage": "climax", "label": "顿悟", "summary": None, "quote": "改变从今晚开始",
                 "points": ["要点甲"], "segmentIds": ["s3"]}]},
            {"chartType": "narrative_arc", "title": "t", "truncatedCount": 0, "stages": [
                {"stage": "climax", "label": "顿悟", "summary": None, "quote": None,
                 "points": ["要点甲", "要点乙"], "segmentIds": ["s4"]}]},
        ]
        merged = self.skill.merge(plans)
        stage = merged["stages"][0]
        self.assertEqual(stage["points"], ["要点甲", "要点乙"])
        self.assertEqual(stage["quote"], "改变从今晚开始")
        self.assertEqual(stage["segmentIds"], ["s3", "s4"])

    def test_render_stage_cards_contain_points_and_summary(self):
        raw = speech_raw()
        raw["stages"][0]["summary"] = "从个人经历讲起，引出主题"
        raw["stages"][0]["points"] = ["三年前的转折经历"]
        plan = self.skill.normalize(raw, speech_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("<svg", html)  # 弧线保留
        self.assertIn("开场 · 一个故事", html)
        self.assertIn("三年前的转折经历", html)
        self.assertIn("改变从今晚开始", html)  # 金句高亮保留
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.SpeechSkillTests -v`
Expected: 新测试 FAIL + 替换后的截断测试 FAIL（新限长未生效）

- [ ] **Step 3: 实现**（`ChartAgent/agent/skills/speech.py`）

常量区（`_STAGE_ORDER` 之前）追加：

```python
MAX_POINTS_PER_STAGE = 3
```

`_PROMPT` 替换为：

```python
_PROMPT = """你是演讲内容结构化提取器。把演讲转写映射到四段叙事结构。
要求：
1. stages：按 opening（开场）、buildup（铺垫）、climax（高潮）、closing（收尾）四段提取；每段 label（小标题，≤14字）、summary（这一段讲了什么，≤60字）、points（该段要点，0-3 条，每条 ≤50字，忠于原文）、segmentIds。
2. climax 段必须附 quote：演讲中最有感染力的原句（逐字，≤40字）。
3. 若某段在片段中找不到依据则省略该段，但 climax 不可省略。
只输出严格 JSON：
{"chartType":"narrative_arc","title":"<演讲主题，≤20字>","stages":[{"stage":"opening","label":"...","summary":"...","points":[],"quote":null,"segmentIds":["..."]}]}
输入片段：
"""
```

`_TEMPLATE` 替换为（SVG 部分不变，尾部新增阶段卡）：

```python
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
{% for stage in plan.stages %}
<div class="sc-card" data-segment-ids="{{ stage.segmentIds|join(',') }}">
  <div class="sc-topic-title">{{ stage_labels[stage.stage] }} · {{ stage.label }}</div>
  {% if stage.summary %}<div class="sc-point">{{ stage.summary }}</div>{% endif %}
  {% for point in stage.points %}<div class="sc-point">· {{ point }}</div>{% endfor %}
  {% if stage.quote %}<div class="sc-conclusion"><span class="sc-conclusion-label">金句</span><span>&ldquo;{{ stage.quote }}&rdquo;</span></div>{% endif %}
</div>
{% endfor %}
{% endblock %}
"""
```

`_Stage` 模型替换为：

```python
class _Stage(StrictModel):
    stage: Literal["opening", "buildup", "climax", "closing"]
    label: str = Field(min_length=1)
    summary: Optional[str] = None
    points: List[str] = Field(default_factory=list)
    quote: Optional[str] = None
    segmentIds: List[str] = Field(min_length=1)
```

`normalize` 中 stages.append 的字典替换为：

```python
            stages.append({
                "stage": stage.stage,
                "label": stage.label[:14],
                "summary": stage.summary[:60] if stage.summary else None,
                "points": [p[:50] for p in stage.points[:MAX_POINTS_PER_STAGE] if p.strip()],
                "quote": stage.quote[:40] if stage.quote else None,
                "segmentIds": ids,
            })
```

`merge` 的 else 分支（同名 stage 合并）替换为：

```python
                else:
                    existing = by_stage[name]
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + stage.get("segmentIds", [])))
                    if not existing.get("quote") and stage.get("quote"):
                        existing["quote"] = stage["quote"]
                    if not existing.get("summary") and stage.get("summary"):
                        existing["summary"] = stage["summary"]
                    known = {normalize_text(p) for p in existing.get("points", [])}
                    for point in stage.get("points", []):
                        if normalize_text(point) not in known and len(existing["points"]) < MAX_POINTS_PER_STAGE:
                            existing["points"].append(point)
                            known.add(normalize_text(point))
```

（`normalize_text` 需加入 speech.py 顶部从 `..textutils` 的 import 列表。）

`validate` 中 summary 校验行之后追加：

```python
            for point_index, point in enumerate(stage.get("points", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"{label}段要点{point_index + 1}数字与原文不符")
```

`fallback` 中 `stages.append({**stage, "segmentIds": ids})` 一行替换为：

```python
            points = [p for p in stage.get("points", []) if numbers_have_evidence(p, ids, segment_map)]
            stages.append({**stage, "points": points, "segmentIds": ids})
```

`render` 替换为：

```python
    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        layout = self.layout_arc(plan.get("stages", []))
        return self._render_jinja(_TEMPLATE, plan=plan, theme=theme, title=title, layout=layout, stage_labels=_STAGE_LABELS)
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.SpeechSkillTests tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/speech.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 演讲弧线加厚——阶段要点组 + 阶段卡"
```

---

### Task 8: memo skill 加厚（要点展开说明 detail）

**Files:**
- Modify: `ChartAgent/agent/skills/memo.py`（`_PROMPT`、`_TEMPLATE`、`_Point`、`normalize`、`merge`、`validate`、`fallback`）
- Test: `ChartAgent/tests/test_skills.py`（`MemoSkillTests`）

- [ ] **Step 1: 写失败测试**

```python
    def test_normalize_keeps_point_detail(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "兜底规则在分类失败时接管"
        plan = self.skill.normalize(raw, memo_source_segments())
        self.assertEqual(plan["points"][0]["detail"], "兜底规则在分类失败时接管")

    def test_normalize_truncates_core_idea_and_detail(self):
        raw = memo_raw()
        raw["coreIdea"] = "核" * 50
        raw["points"][0]["text"] = "要" * 50
        raw["points"][0]["detail"] = "详" * 70
        plan = self.skill.normalize(raw, memo_source_segments())
        self.assertEqual(len(plan["coreIdea"]), 40)
        self.assertEqual(len(plan["points"][0]["text"]), 40)
        self.assertEqual(len(plan["points"][0]["detail"]), 60)

    def test_validate_rejects_fabricated_detail_numbers(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "预计节省 30% 成本"
        plan = self.skill.normalize(raw, memo_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("说明" in e and "数字" in e for e in errors))

    def test_fallback_strips_fabricated_detail_keeps_point(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "预计节省 30% 成本"
        plan = self.skill.normalize(raw, memo_source_segments())
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertIsNone(salvaged["points"][0]["detail"])

    def test_render_contains_detail(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "兜底规则在分类失败时接管"
        plan = self.skill.normalize(raw, memo_source_segments())
        html = self.skill.render(plan, "darkCyberpunk", plan["title"])
        self.assertIn("兜底规则在分类失败时接管", html)
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.MemoSkillTests -v`
Expected: 新测试 FAIL（`_Point` 无 detail 字段，`extra="forbid"` 报错）

- [ ] **Step 3: 实现**（`ChartAgent/agent/skills/memo.py`）

`_PROMPT` 替换为：

```python
_PROMPT = """你是随手记内容提炼器。这是一段单人即兴语音记录（口播/语音备忘）。请提炼：
1. coreIdea：整段记录的核心想法，一句话，不超过 40 字，必须忠实于原文。
2. coreSegmentIds：核心想法来源的片段 id 列表（只用输入片段中的 id）。
3. points：支撑要点列表，每条包含 text（要点，不超过 40 字）与 detail（一句展开说明，不超过 60 字，原文没有更多展开时为 null），必须来自原文明确表述，并携带来源 segmentIds。
禁止编造原文没有的内容；segmentIds 只能使用输入片段中的 id。
只输出严格 JSON：
{"chartType":"idea_card","title":"随手记要点","coreIdea":"...","coreSegmentIds":["..."],"points":[{"text":"...","detail":null,"segmentIds":["..."]}]}
输入片段：
"""
```

`_TEMPLATE` 的 point 循环替换为：

```python
  {% for point in plan.points %}
  <div class="sc-point-row" data-segment-ids="{{ point.segmentIds|join(',') }}">
    <span class="sc-point-marker">▸</span>
    <span>
      <span class="sc-label">{{ point.text }}</span>
      {% if point.detail %}<div class="sc-meta">{{ point.detail }}</div>{% endif %}
    </span>
  </div>
  {% endfor %}
```

`_Point` 模型替换为：

```python
class _Point(StrictModel):
    text: str = Field(min_length=1)
    detail: Optional[str] = None
    segmentIds: List[str] = Field(min_length=1)
```

`normalize` 中 points.append 替换为：

```python
            if ids:
                points.append({
                    "text": point.text[:40],
                    "detail": point.detail[:60] if point.detail else None,
                    "segmentIds": ids,
                })
```

返回字典中 `"coreIdea": model.coreIdea,` 一行替换为：

```python
            "coreIdea": model.coreIdea[:40],
```

`merge` 的 point 去重循环替换为（重复要点回填 detail）：

```python
        seen, points = set(), []
        for plan in plans:
            for point in plan.get("points", []):
                key = normalize_text(point["text"])
                if not key:
                    continue
                if key in seen:
                    existing = next(p for p in points if normalize_text(p["text"]) == key)
                    if not existing.get("detail") and point.get("detail"):
                        existing["detail"] = point["detail"]
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + point.get("segmentIds", [])))
                    continue
                seen.add(key)
                points.append(point)
```

`validate` 的要点校验追加 detail 检查（`elif` 块替换为）：

```python
        for index, point in enumerate(plan.get("points", [])):
            ids = point.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"要点{index + 1}缺少有效来源片段")
                continue
            if not numbers_have_evidence(point["text"], ids, segment_map):
                errors.append(f"要点{index + 1}数字与原文不符")
            if point.get("detail") and not numbers_have_evidence(point["detail"], ids, segment_map):
                errors.append(f"要点{index + 1}说明数字与原文不符")
```

`fallback` 的 points 列表推导替换为：

```python
        points = []
        for p in plan.get("points", []):
            ids = filter_known_segment_ids(p.get("segmentIds"), segment_map)
            if not ids or not numbers_have_evidence(p["text"], ids, segment_map):
                continue
            detail = p.get("detail")
            if detail and not numbers_have_evidence(detail, ids, segment_map):
                detail = None
            points.append({**p, "detail": detail, "segmentIds": ids})
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_skills.MemoSkillTests tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/memo.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): 随手记加厚——要点展开说明 detail"
```

---

### Task 9: 全量回归 + 端到端结构断言

**Files:**
- Test: `ChartAgent/tests/test_pipeline.py`（`PipelineDegradationTests` 追加结构断言）
- 全仓验证

- [ ] **Step 1: 补充端到端断言**

在 `test_pipeline.py` 的 `PipelineTypeRoutingTests` 类中追加：

```python
    def test_meeting_chart_contains_overview_and_rich_sections(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了私有化部署的排期与分工"}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError(f"未预期的提示词: {prompt[:100]}")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        html = result["html_fragment"]
        self.assertIn("sc-overview", html)
        self.assertIn("会议确认了私有化部署的排期与分工", html)
        self.assertEqual(html.count("<div"), html.count("</div>"))
        self.assertIn('data-segment-ids="s1,s2"', html)

    def test_degraded_highlights_keep_overview(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了私有化部署的排期与分工"}, ensure_ascii=False)
            raise LLMError(LLMError.TIMEOUT, "提取超时")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertIn("sc-overview", result["html_fragment"])  # 降级也保留总览条
```

- [ ] **Step 2: 运行两个新测试**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest tests.test_pipeline -v`
Expected: 全部 PASS

- [ ] **Step 3: 全量回归（Python）**

Run: `cd ChartAgent && PYTHONPATH=. python3 -m unittest discover -s tests -v`
Expected: 全部 PASS，0 failures

- [ ] **Step 4: Swift 侧零改动确认 + 编译验证**

Run: `git diff --stat main...HEAD -- AIRecording/ Package.swift` → Expected: 无输出（Swift 侧无改动）
Run: `swift build 2>&1 | tail -3` → Expected: Build complete（确认 worktree 本身可编译）

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/tests/test_pipeline.py
git commit -m "test(chart): 端到端总览条与降级保留断言"
```

---

## Self-Review 记录（计划作者已核对）

- **Spec 覆盖**：§4 总览节点 → Task 2；§5.1~5.6 六个 skill → Task 3~8；§5.7 highlights 总览条 → Task 1（BASE_TEMPLATE）+ Task 9（降级断言）；§6 校验/合并 → 各 skill 任务内；§7 降级链 → Task 2（overview 不阻塞）+ Task 9；§8 Swift 侧 → Task 9 Step 4（确认零改动）；§9 测试 → 各任务 TDD + Task 9 全量回归。
- **类型一致性**：`generate_overview` / `build_overview_prompt` / `parse_overview` / `MAX_OVERVIEW_CHARS` / `OVERVIEW_RESERVED_SECONDS` / `MAX_ANSWER_POINTS` / `MAX_POINTS_PER_CHAPTER` / `MAX_KEY_POINTS_PER_BLOCK` / `MAX_POINTS_PER_STAGE` / `MAX_POINTS_PER_TOPIC` / `MAX_DISAGREEMENTS_PER_TOPIC` 在定义任务与使用任务间一致。
- **known-good 陷阱**：`render_highlights` 与 `skill.render` 都接收 plan dict，总览注入发生在 `render_chart_node`，所有类型（含降级 highlights）共用同一路径。
