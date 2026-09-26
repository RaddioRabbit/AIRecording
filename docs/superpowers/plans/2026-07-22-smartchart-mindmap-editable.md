# 智能图表 v5：统一思维导图 + 大纲编辑 + PNG 导出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把智能图表从 v4「七种类型七种图」升级为 v5「六种类型统一渲染为思维导图 + App 端大纲编辑（改文字/增删节点）+ PNG 导出」，新增纯渲染接口 `POST /chart/render`，API 升级 v5.0。

**Architecture:** Python 端在 v4 流水线（prepare → classify → overview → extract → merge → validate）之后新增 `mindmap_normalize` 节点：各 skill 的 `to_mindmap(plan)` 把类型 plan 归一化为 MindMapDoc（root → branches → children 三级），再由唯一的 `MindMapRenderer`（`ChartAgent/agent/mindmap.py`，全部几何确定性计算）渲染为 HTML+SVG 片段；`other`/highlights 保留旧渲染作兜底。响应新增 `mindMap` 结构数据。Swift 端持有 MindMapDocDTO，原生大纲界面编辑后 300ms 防抖调 `/chart/render`（无 LLM），PNG 导出用 `WKWebView.takeSnapshot` 全尺寸快照 + `NSSavePanel`。

**Tech Stack:** Python 3 / FastAPI / LangGraph / Pydantic v2（`extra="forbid"`）/ Jinja2（autoescape）；Swift 5.9 / SwiftUI / AppKit（WKWebView、NSSavePanel）/ XCTest；Python 测试用 unittest（`PYTHONPATH=. python3 -m unittest discover -s tests -v`，在 `ChartAgent/` 目录下运行，解释器用 `ChartAgent/.venv/bin/python`）。

## 实施前必读（与现状的出入，执行时注意）

1. **ChartPersistence 已存在**：v4 已把 `SmartChartGenerateResponse` 持久化（`RecordingDetailViewModel.swift:176-177, 348`）。v5 设计 §2 说"不做图表持久化"，但本计划**保留现有持久化行为不动**（DTO 新增 `mindMap` 字段随 Codable 自动持久化），仅保证"重新生成丢弃未导出的编辑"。
2. **v4 设计文档与代码的字段差异**：实际 plan 字段以代码为准——interview 是 `answerPoints/quote/tags`（不是 `key_answer`）；dialogue 块含 `keyPoints/start/end`；speech 段含 `points`；memo 含 `coreSegmentIds/detail`。本计划的 `to_mindmap` 映射按**真实代码字段**编写。
3. **memo 无要点时**：`MemoPlan` 允许只有 `coreIdea` 没有 `points`，此时映射出的 MindMapDoc 分支数为 0，按设计 §7.3 降级 highlights。
4. **布局取舍**：root 固定在画布宽 1200pt 的 1/4 处（x=300）时，左侧放不下"分支列 + 要点列"两列。具体几何：右侧两列（分支 x=430、要点 x=680），左侧单列（分支 x=16，要点在分支**下方**成列缩进排布），root 与左列水平不相交（root x=220..380，左列 x=16..206）。这是对设计 §5「要点在分支外侧成列」在固定宽度下的确定性落地。
5. 现有测试必须同步更新：`ChartAgent/tests/test_skills.py` 中六个 skill 的 render/layout 测试随渲染器退役删除；`ChartAgent/tests/test_pipeline.py` 的 chartType 断言与版本字面量升级；`Tests/AIRecordingTests/SmartChartTests.swift` 的 v4 版本门断言升级。这些更新已写进对应任务的步骤里。
6. 纪律：Python 日志一律 `observability.log_event`，Swift 一律 `AppLogger.log`，禁止 `print`；不记录转写原文、提示词、LLM 响应。

---

## Task 1: MindMapDoc 规模守卫 + MindMapRenderer 渲染器

新建 `ChartAgent/agent/mindmap.py`：`guard_mindmap_doc`（规模守卫：分支 ≤8、每分支要点 ≤6、超出加"还有 N 项"节点、文本截断加省略号、按序重建 id）、`layout_mindmap`（确定性几何布局）、`MindMapRenderer`（Jinja2 → HTML+SVG 片段）。

**Files:**
- Create: `ChartAgent/agent/mindmap.py`
- Test: `ChartAgent/tests/test_mindmap.py`

- [ ] **Step 1: 写失败测试**

创建 `ChartAgent/tests/test_mindmap.py`：

```python
"""MindMapDoc 规模守卫与思维导图渲染器测试（v5）。不涉及 LLM。"""
import unittest

from agent.mindmap import (
    MAX_BRANCHES,
    MAX_CHILDREN_PER_BRANCH,
    MindMapRenderer,
    guard_mindmap_doc,
    layout_mindmap,
)


def make_doc(branch_count=2, children_per_branch=2):
    branches = []
    for b in range(branch_count):
        children = [
            {"id": f"b{b}c{c}", "text": f"要点{b}-{c}", "segment_ids": [f"s{b}{c}"]}
            for c in range(children_per_branch)
        ]
        branches.append({"id": f"b{b}", "text": f"分支{b}", "segment_ids": [f"s{b}"], "children": children})
    return {"root": {"id": "root", "text": "测试主题"}, "branches": branches}


class MindMapGuardTests(unittest.TestCase):
    def test_caps_branches_at_eight(self):
        doc = guard_mindmap_doc(make_doc(branch_count=11, children_per_branch=0))
        self.assertEqual(len(doc["branches"]), MAX_BRANCHES)

    def test_caps_children_and_appends_overflow_note(self):
        doc = guard_mindmap_doc(make_doc(branch_count=1, children_per_branch=9))
        children = doc["branches"][0]["children"]
        self.assertEqual(len(children), MAX_CHILDREN_PER_BRANCH + 1)
        self.assertEqual(children[-1]["text"], "还有 3 项")
        self.assertEqual(children[-1]["id"], "b0c6")
        self.assertEqual(children[-1]["segment_ids"], [])

    def test_no_overflow_note_when_within_limit(self):
        doc = guard_mindmap_doc(make_doc(branch_count=1, children_per_branch=6))
        self.assertEqual(len(doc["branches"][0]["children"]), 6)

    def test_truncates_branch_and_child_text(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["text"] = "支" * 25
        doc["branches"][0]["children"][0]["text"] = "点" * 45
        guarded = guard_mindmap_doc(doc)
        self.assertEqual(guarded["branches"][0]["text"], "支" * 20 + "…")
        self.assertEqual(guarded["branches"][0]["children"][0]["text"], "点" * 40 + "…")

    def test_regenerates_sequential_child_ids(self):
        doc = make_doc(branch_count=1, children_per_branch=2)
        doc["branches"][0]["children"][0]["id"] = "weird"
        guarded = guard_mindmap_doc(doc)
        self.assertEqual([c["id"] for c in guarded["branches"][0]["children"]], ["b0c0", "b0c1"])


class MindMapRendererTests(unittest.TestCase):
    def test_minimal_doc_renders_with_segment_ids(self):
        html = MindMapRenderer().render(make_doc(), "darkCyberpunk", "测试主题")
        self.assertIn("<svg", html)
        self.assertIn('data-segment-ids="s0"', html)
        self.assertIn('data-segment-ids="s00"', html)
        self.assertIn("思维导图", html)
        self.assertIn("测试主题", html)

    def test_renders_empty_branches_doc(self):
        doc = {"root": {"id": "root", "text": "只有主题"}, "branches": []}
        html = MindMapRenderer().render(doc, "darkCyberpunk", "只有主题")
        self.assertIn("<svg", html)
        self.assertIn("只有主题", html)
        self.assertIn("data-segment-ids", html)

    def test_escapes_xss_in_all_text_fields(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["root"]["text"] = "<script>alert(1)</script>"
        doc["branches"][0]["text"] = "<img src=x onerror=alert(1)>"
        doc["branches"][0]["children"][0]["text"] = "<b>bold</b>"
        html = MindMapRenderer().render(doc, "darkCyberpunk", "t")
        self.assertNotIn("<script>", html)
        self.assertNotIn("<img src=x", html)
        self.assertNotIn("<b>bold</b>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_odd_branch_count_gives_right_side_one_more(self):
        layout = layout_mindmap(make_doc(branch_count=5, children_per_branch=1))
        sides = [node["side"] for node in layout["nodes"] if node["kind"] == "branch"]
        self.assertEqual(sides.count("right"), 3)
        self.assertEqual(sides.count("left"), 2)

    def test_even_branch_count_splits_evenly(self):
        layout = layout_mindmap(make_doc(branch_count=4, children_per_branch=0))
        sides = [node["side"] for node in layout["nodes"] if node["kind"] == "branch"]
        self.assertEqual(sides.count("right"), 2)
        self.assertEqual(sides.count("left"), 2)

    def test_viewbox_grows_with_content_and_width_fixed(self):
        small = layout_mindmap(make_doc(branch_count=1, children_per_branch=1))
        large = layout_mindmap(make_doc(branch_count=8, children_per_branch=6))
        self.assertGreater(large["height"], small["height"])
        self.assertEqual(large["width"], 1200.0)

    def test_empty_segment_ids_render_empty_attribute(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["children"][0]["segment_ids"] = []
        html = MindMapRenderer().render(doc, "darkCyberpunk", "t")
        self.assertIn('data-segment-ids=""', html)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap -v
```

预期输出：`ModuleNotFoundError: No module named 'agent.mindmap'`（全部用例 error）。

- [ ] **Step 3: 最小实现**

创建 `ChartAgent/agent/mindmap.py`：

```python
"""统一思维导图渲染器（v5）。

MindMapDoc（三级：root → branches → children）→ HTML + 内联 SVG 片段。
纪律（设计文档 §5）：全部几何由本模块确定性计算，LLM 不碰坐标；
文本一律经 Jinja2 自动转义；每个节点保留 data-segment-ids（空列表输出空属性，占位不跳音频）。
布局：root 垂直居中于画布左侧 1/4 处；分支按数量均分到左右两侧（奇数右侧多一）；
右侧为"分支列 + 要点列"两列，左侧单列、要点在分支下方成列（1200pt 固定宽下的确定性取舍）。
"""
from typing import Any, Dict, List, Optional

from jinja2 import DictLoader, Environment

from .templates import BASE_TEMPLATE, DARK_CSS

# ---- 规模守卫（设计文档 §4）----
MAX_BRANCHES = 8
MAX_CHILDREN_PER_BRANCH = 6
MAX_BRANCH_TEXT_LENGTH = 20
MAX_CHILD_TEXT_LENGTH = 40

# ---- 画布与几何常量（单位 pt）----
CANVAS_WIDTH = 1200.0
SIDE_MARGIN = 24.0
ROOT_CENTER_X = 300.0          # 画布左侧 1/4
ROOT_WIDTH = 160.0             # root x ∈ [220, 380]，与左列（≤206）不相交
ROOT_MIN_HEIGHT = 56.0
ROOT_LINE_HEIGHT = 17.0
BRANCH_HEIGHT = 34.0
BRANCH_LINE_HEIGHT = 13.0
BRANCH_COLUMN_X_LEFT = 16.0
BRANCH_WIDTH_LEFT = 190.0
BRANCH_COLUMN_X_RIGHT = 430.0
BRANCH_WIDTH_RIGHT = 210.0
CHILD_LINE_HEIGHT = 12.0
CHILD_COLUMN_X_RIGHT = 680.0
CHILD_WIDTH_RIGHT = 210.0
CHILD_INDENT_LEFT = 24.0       # 左侧要点在分支下方缩进
CHILD_GAP = 6.0
BRANCH_GAP = 28.0
MIN_BRANCH_BLOCK_HEIGHT = 52.0

# 类型无关的分支调色板循环色
BRANCH_COLORS = ["#22D3EE", "#8B5CF6", "#F59E0B", "#34C759", "#3B82F6", "#FF3B30", "#F472B6", "#2DD4BF"]

_TEMPLATE = """
{% extends "base.html.j2" %}
{% block chart_content %}
<svg viewBox="0 0 {{ layout.width|int }} {{ layout.height|int }}" width="100%" role="img" aria-label="思维导图">
  {% for edge in layout.edges %}
  <path d="{{ edge.d }}" fill="none" stroke="{{ edge.color }}" stroke-width="1.5"/>
  {% endfor %}
  <g data-segment-ids="">
    <rect x="{{ '%.1f'|format(layout.root.x) }}" y="{{ '%.1f'|format(layout.root.y) }}" width="{{ layout.root.w|int }}" height="{{ layout.root.h|int }}" rx="12" fill="#7c3aed"/>
    <text x="{{ '%.1f'|format(layout.root.x + layout.root.w / 2) }}" y="{{ '%.1f'|format(layout.root.y + 20) }}" text-anchor="middle" fill="#ffffff" font-size="14" font-weight="600">{% for line in layout.root.lines %}<tspan x="{{ '%.1f'|format(layout.root.x + layout.root.w / 2) }}" dy="{{ 0 if loop.first else 17 }}">{{ line }}</tspan>{% endfor %}</text>
  </g>
  {% for node in layout.nodes %}
  <g data-segment-ids="{{ node.segment_ids|join(',') }}"{% if node.segment_ids %} style="cursor:pointer"{% endif %}>
    <rect x="{{ '%.1f'|format(node.x) }}" y="{{ '%.1f'|format(node.y) }}" width="{{ node.w|int }}" height="{{ node.h|int }}" rx="{{ 10 if node.kind == 'branch' else 6 }}" fill="{{ node.fill }}" stroke="{{ node.color }}" stroke-width="1.2"/>
    <text x="{{ '%.1f'|format(node.x + node.w / 2) }}" y="{{ '%.1f'|format(node.y + (16 if node.kind == 'branch' else 13)) }}" text-anchor="middle" fill="{{ node.text_color }}" font-size="{{ 12 if node.kind == 'branch' else 11 }}">{% for line in node.lines %}<tspan x="{{ '%.1f'|format(node.x + node.w / 2) }}" dy="{{ 0 if loop.first else node.line_height }}">{{ line }}</tspan>{% endfor %}</text>
  </g>
  {% endfor %}
</svg>
{% endblock %}
"""


def _truncate(text: Any, limit: int) -> str:
    cleaned = " ".join(str(text).split())
    return cleaned if len(cleaned) <= limit else cleaned[:limit] + "…"


def guard_mindmap_doc(doc: Dict[str, Any]) -> Dict[str, Any]:
    """规模守卫（确定性）：分支 ≤8；每分支要点 ≤6，超出截断并在末尾加"还有 N 项"节点；
    分支文本 >20 字、要点 >40 字截断加省略号；要点 id 按路径式重建（b{i}c{j}）。
    输入输出都是 plain dict；不改动 branch id（由编辑回路维护）。"""
    root = doc.get("root") or {}
    guarded_root = {"id": str(root.get("id") or "root"), "text": str(root.get("text") or "")}
    branches: List[Dict[str, Any]] = []
    for branch_index, branch in enumerate((doc.get("branches") or [])[:MAX_BRANCHES]):
        raw_children = branch.get("children") or []
        overflow = max(0, len(raw_children) - MAX_CHILDREN_PER_BRANCH)
        children: List[Dict[str, Any]] = []
        for child_index, child in enumerate(raw_children[:MAX_CHILDREN_PER_BRANCH]):
            children.append({
                "id": f"b{branch_index}c{child_index}",
                "text": _truncate(child.get("text", ""), MAX_CHILD_TEXT_LENGTH),
                "segment_ids": [str(sid) for sid in (child.get("segment_ids") or [])],
            })
        if overflow:
            children.append({
                "id": f"b{branch_index}c{MAX_CHILDREN_PER_BRANCH}",
                "text": f"还有 {overflow} 项",
                "segment_ids": [],
            })
        branches.append({
            "id": str(branch.get("id") or f"b{branch_index}"),
            "text": _truncate(branch.get("text", ""), MAX_BRANCH_TEXT_LENGTH),
            "segment_ids": [str(sid) for sid in (branch.get("segment_ids") or [])],
            "children": children,
        })
    return {"root": guarded_root, "branches": branches}


def _wrap_text(text: str, max_chars_per_line: int, max_lines: int) -> List[str]:
    chars_per_line = max(4, max_chars_per_line)
    lines: List[str] = []
    remaining = text
    while remaining and len(lines) < max_lines:
        lines.append(remaining[:chars_per_line])
        remaining = remaining[chars_per_line:]
    if remaining and lines:
        lines[-1] = lines[-1][: max(1, chars_per_line - 1)] + "…"
    return lines or [""]


def _child_height(lines: List[str]) -> float:
    return 10.0 + CHILD_LINE_HEIGHT * len(lines)


def layout_mindmap(doc: Dict[str, Any]) -> Dict[str, Any]:
    """确定性布局。返回 {width, height, root, nodes, edges}；
    nodes 元素含 id/kind(root|branch|child)/side(left|right)/x/y/w/h/lines/color/fill/text_color/segment_ids；
    edges 元素含 d（三次贝塞尔 path）/color。"""
    branches = list(doc.get("branches") or [])
    count = len(branches)
    right_count = (count + 1) // 2  # 奇数时右侧多一个
    left_branches = branches[: count - right_count]
    right_branches = branches[count - right_count:]

    # 左右两侧要点列宽不同 → 每行可容纳字符数不同（左 15 / 右 19），
    # 块高度必须按各自侧的实际排字计算，且与下方 lay_branch 的推进公式保持一致。
    def block_height(branch: Dict[str, Any], chars: int) -> float:
        children = branch.get("children") or []
        if not children:
            return BRANCH_HEIGHT
        total = BRANCH_HEIGHT + sum(
            _child_height(_wrap_text(str(c.get("text", "")), chars, 3)) + CHILD_GAP for c in children
        )
        return max(MIN_BRANCH_BLOCK_HEIGHT, total)

    left_blocks = [block_height(b, 15) for b in left_branches]
    right_blocks = [block_height(b, 19) for b in right_branches]
    left_height = sum(left_blocks) + BRANCH_GAP * max(0, len(left_blocks) - 1)
    right_height = sum(right_blocks) + BRANCH_GAP * max(0, len(right_blocks) - 1)

    root_lines = _wrap_text(str(doc.get("root", {}).get("text", "")), 11, 4)
    root_height = max(ROOT_MIN_HEIGHT, 26.0 + ROOT_LINE_HEIGHT * len(root_lines))

    content_height = max(left_height, right_height, root_height, 1.0)
    height = SIDE_MARGIN * 2 + content_height
    root_x = ROOT_CENTER_X - ROOT_WIDTH / 2
    root_y = SIDE_MARGIN + (content_height - root_height) / 2
    root_mid_y = root_y + root_height / 2

    layout: Dict[str, Any] = {
        "width": CANVAS_WIDTH,
        "height": height,
        "root": {
            "id": str(doc.get("root", {}).get("id", "root")),
            "x": root_x, "y": root_y, "w": ROOT_WIDTH, "h": root_height, "lines": root_lines,
        },
        "nodes": [],
        "edges": [],
    }

    def bezier(x1: float, y1: float, x2: float, y2: float) -> str:
        dx = max(24.0, abs(x2 - x1) * 0.6)
        c1x = x1 + dx if x2 >= x1 else x1 - dx
        c2x = x2 - dx if x2 >= x1 else x2 + dx
        return f"M {x1:.1f} {y1:.1f} C {c1x:.1f} {y1:.1f}, {c2x:.1f} {y2:.1f}, {x2:.1f} {y2:.1f}"

    def lay_branch(branch: Dict[str, Any], color: str, side: str, y: float) -> None:
        branch_x = BRANCH_COLUMN_X_LEFT if side == "left" else BRANCH_COLUMN_X_RIGHT
        branch_w = BRANCH_WIDTH_LEFT if side == "left" else BRANCH_WIDTH_RIGHT
        branch_lines = _wrap_text(str(branch.get("text", "")), 15 if side == "left" else 17, 2)
        layout["nodes"].append({
            "id": branch["id"], "kind": "branch", "side": side,
            "x": branch_x, "y": y, "w": branch_w, "h": BRANCH_HEIGHT,
            "lines": branch_lines, "line_height": int(BRANCH_LINE_HEIGHT),
            "color": color, "fill": "#1E1E2E", "text_color": color,
            "segment_ids": branch.get("segment_ids") or [],
        })
        # root → 分支连线
        branch_mid_y = y + BRANCH_HEIGHT / 2
        if side == "left":
            layout["edges"].append({"d": bezier(root_x, root_mid_y, branch_x + branch_w, branch_mid_y), "color": color})
        else:
            layout["edges"].append({"d": bezier(root_x + ROOT_WIDTH, root_mid_y, branch_x, branch_mid_y), "color": color})
        # 要点：右侧在分支外侧成列；左侧在分支下方缩进成列
        child_y = y if side == "right" else y + BRANCH_HEIGHT + CHILD_GAP
        for child in branch.get("children") or []:
            if side == "right":
                child_x, child_w, chars = CHILD_COLUMN_X_RIGHT, CHILD_WIDTH_RIGHT, 19
            else:
                child_x = BRANCH_COLUMN_X_LEFT + CHILD_INDENT_LEFT
                child_w = BRANCH_WIDTH_LEFT - CHILD_INDENT_LEFT
                chars = 15
            child_lines = _wrap_text(str(child.get("text", "")), chars, 3)
            child_h = _child_height(child_lines)
            layout["nodes"].append({
                "id": child["id"], "kind": "child", "side": side,
                "x": child_x, "y": child_y, "w": child_w, "h": child_h,
                "lines": child_lines, "line_height": int(CHILD_LINE_HEIGHT),
                "color": color, "fill": "#16162A", "text_color": "#94A3B8",
                "segment_ids": child.get("segment_ids") or [],
            })
            if side == "right":
                layout["edges"].append({
                    "d": bezier(branch_x + branch_w, branch_mid_y, child_x, child_y + child_h / 2),
                    "color": "#475569",
                })
            else:
                layout["edges"].append({
                    "d": bezier(branch_x + CHILD_INDENT_LEFT / 2, y + BRANCH_HEIGHT, child_x, child_y + child_h / 2),
                    "color": "#475569",
                })
            child_y += child_h + CHILD_GAP

    y = SIDE_MARGIN + (content_height - left_height) / 2
    for index, branch in enumerate(left_branches):
        color = BRANCH_COLORS[index % len(BRANCH_COLORS)]
        lay_branch(branch, color, "left", y)
        y += left_blocks[index] + BRANCH_GAP

    y = SIDE_MARGIN + (content_height - right_height) / 2
    for offset, branch in enumerate(right_branches):
        color = BRANCH_COLORS[(len(left_branches) + offset) % len(BRANCH_COLORS)]
        lay_branch(branch, color, "right", y)
        y += right_blocks[offset] + BRANCH_GAP

    return layout


class MindMapRenderer:
    """唯一的思维导图渲染入口：MindMapDoc → HTML + 内联 SVG 片段。"""

    def render(self, doc: Dict[str, Any], theme: str, title: str, overview: Optional[str] = None) -> str:
        guarded = guard_mindmap_doc(doc)
        layout = layout_mindmap(guarded)
        plan_context: Dict[str, Any] = {}
        if overview:
            plan_context["overview"] = overview
        env = Environment(
            loader=DictLoader({"base.html.j2": BASE_TEMPLATE, "mindmap.html.j2": _TEMPLATE}),
            autoescape=True,
        )
        return env.get_template("mindmap.html.j2").render(
            layout=layout,
            plan=plan_context,
            theme=theme,
            title=title or guarded["root"]["text"],
            kind_display_name="思维导图",
            dark_css=DARK_CSS,
        )
```

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap -v
```

预期输出：`Ran 12 tests ... OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/mindmap.py ChartAgent/tests/test_mindmap.py
git commit -m "feat(chart-agent): add MindMapDoc guards and MindMapRenderer (v5)"
```

---

## Task 2: BaseSkill 增加 to_mindmap 契约与节点构造助手

在 `ChartAgent/agent/skills/base.py` 增加：`to_mindmap(plan)`（默认返回 None，六个类型 skill 覆写）、`make_node_id`（路径式 id）、`truncate_mindmap_text`（截断加省略号）、`make_mindmap_node`（节点构造）。`other` 不实现 `to_mindmap`（保持 None，走 highlights）。

**Files:**
- Modify: `ChartAgent/agent/skills/base.py`（第 1-12 行 imports 区；第 47-53 行 `fallback` 之后插入新方法）
- Test: `ChartAgent/tests/test_mindmap.py`

- [ ] **Step 1: 追加失败测试**

在 `ChartAgent/tests/test_mindmap.py` 末尾（`if __name__` 之前）追加：

```python
from agent.skills import SKILLS
from agent.skills.base import BaseSkill


class MindMapNodeHelperTests(unittest.TestCase):
    def test_make_node_id_path_style(self):
        self.assertEqual(BaseSkill.make_node_id(0), "b0")
        self.assertEqual(BaseSkill.make_node_id(0, 2), "b0c2")
        self.assertEqual(BaseSkill.make_node_id(7, 5), "b7c5")

    def test_truncate_mindmap_text_limits(self):
        self.assertEqual(BaseSkill.truncate_mindmap_text("支" * 25, is_branch=True), "支" * 20 + "…")
        self.assertEqual(BaseSkill.truncate_mindmap_text("点" * 45, is_branch=False), "点" * 40 + "…")
        self.assertEqual(BaseSkill.truncate_mindmap_text("短文本", is_branch=True), "短文本")

    def test_make_mindmap_node_branch_has_children_list(self):
        node = SKILLS["meeting"].make_mindmap_node(1, "议题", ["s1"])
        self.assertEqual(node, {"id": "b1", "text": "议题", "segment_ids": ["s1"], "children": []})

    def test_make_mindmap_node_child_has_no_children_key(self):
        node = SKILLS["meeting"].make_mindmap_node(1, "要点", ["s2"], 0)
        self.assertEqual(node, {"id": "b1c0", "text": "要点", "segment_ids": ["s2"]})
        self.assertNotIn("children", node)

    def test_base_skill_to_mindmap_defaults_to_none(self):
        self.assertIsNone(SKILLS["other"].to_mindmap({"chartType": "highlights", "title": "x"}))
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap.MindMapNodeHelperTests -v
```

预期输出：`AttributeError: type object 'BaseSkill' has no attribute 'make_node_id'`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/agent/skills/base.py`。将第 7-12 行的 import 区改为：

```python
import json
from typing import Any, Dict, List, Optional

from jinja2 import DictLoader, Environment

from ..mindmap import MAX_BRANCH_TEXT_LENGTH, MAX_CHILD_TEXT_LENGTH
from ..templates import BASE_TEMPLATE, DARK_CSS
```

在第 51-53 行 `fallback` 方法之后、`# ---- 修复提示词（通用，可覆写）----` 注释之前插入：

```python
    # ---- 思维导图映射（v5；除 other 外的子类实现）----
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """把本类型的 plan 映射为 MindMapDoc 三级结构（root/branches/children）。
        返回 None 表示无法映射（调用方降级 highlights）。
        子类必须用 make_mindmap_node 构造节点，保证 id 与文本守卫一致。"""
        return None

    @staticmethod
    def make_node_id(branch_index: int, child_index: Optional[int] = None) -> str:
        """路径式节点 id：分支 "b0"，要点 "b0c2"。"""
        if child_index is None:
            return f"b{branch_index}"
        return f"b{branch_index}c{child_index}"

    @staticmethod
    def truncate_mindmap_text(text: Any, *, is_branch: bool) -> str:
        """分支 >20 字、要点 >40 字截断加省略号；折叠连续空白。"""
        limit = MAX_BRANCH_TEXT_LENGTH if is_branch else MAX_CHILD_TEXT_LENGTH
        cleaned = " ".join(str(text).split())
        return cleaned if len(cleaned) <= limit else cleaned[:limit] + "…"

    def make_mindmap_node(
        self,
        branch_index: int,
        text: Any,
        segment_ids: List[str],
        child_index: Optional[int] = None,
    ) -> Dict[str, Any]:
        """构造 MindMapDoc 节点：分支（child_index=None）带空 children 列表，要点不带。"""
        node: Dict[str, Any] = {
            "id": self.make_node_id(branch_index, child_index),
            "text": self.truncate_mindmap_text(text, is_branch=child_index is None),
            "segment_ids": [str(sid) for sid in segment_ids],
        }
        if child_index is None:
            node["children"] = []
        return node
```

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap -v
```

预期输出：`Ran 17 tests ... OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/base.py ChartAgent/tests/test_mindmap.py
git commit -m "feat(chart-agent): add to_mindmap contract and node helpers to BaseSkill"
```

---

## Task 3: meeting skill — to_mindmap 替换 render

`MeetingSkill` 实现 `to_mindmap(plan)`：root=会议标题，branches=各议题，children=结论 + 行动项（负责人/截止拼接进文本）。删除 `_TEMPLATE` 与 `render`（决策行动看板退役）。

**Files:**
- Modify: `ChartAgent/agent/skills/meeting.py`（删除第 31-63 行 `_TEMPLATE`；删除第 232-233 行 `render`；类内新增 `to_mindmap`）
- Test: `ChartAgent/tests/test_skills.py`（`MeetingSkillTests` 内删除 `test_render_contains_conclusion_actions_and_segment_ids`（第 348-353 行）与 `test_render_contains_rich_sections`（第 452 行至第 496 行），新增映射测试）

- [ ] **Step 1: 追加失败测试**

在 `ChartAgent/tests/test_skills.py` 的 `MeetingSkillTests` 类内追加：

```python
    def test_to_mindmap_maps_topics_conclusions_actions(self):
        plan = {
            "chartType": "decision_board",
            "title": "私有化部署讨论会",
            "topics": [
                {"title": "私有化部署", "conclusion": "当天完成部署",
                 "actions": [{"text": "提供一台可外网访问的电脑", "owner": "李老师", "due": "今天"}],
                 "segmentIds": ["s1", "s2"]},
            ],
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "私有化部署讨论会"})
        self.assertEqual(len(doc["branches"]), 1)
        branch = doc["branches"][0]
        self.assertEqual(branch["id"], "b0")
        self.assertEqual(branch["text"], "私有化部署")
        self.assertEqual(branch["segment_ids"], ["s1", "s2"])
        self.assertEqual([c["id"] for c in branch["children"]], ["b0c0", "b0c1"])
        texts = [c["text"] for c in branch["children"]]
        self.assertIn("结论：当天完成部署", texts)
        self.assertIn("提供一台可外网访问的电脑（李老师 · 今天）", texts)

    def test_to_mindmap_topic_without_conclusion_and_actions_has_no_children(self):
        plan = {
            "chartType": "decision_board", "title": "t",
            "topics": [{"title": "待定议题", "conclusion": None, "actions": [], "segmentIds": ["s1"]}],
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        self.assertEqual(doc["branches"][0]["children"], [])

    def test_to_mindmap_returns_none_without_topics(self):
        self.assertIsNone(SKILLS["meeting"].to_mindmap({"chartType": "decision_board", "title": "x", "topics": []}))

    def test_to_mindmap_truncates_long_branch_text(self):
        plan = {
            "chartType": "decision_board", "title": "t",
            "topics": [{"title": "这是一个远远超过二十个字符限制的会议议题标题文字内容", "conclusion": None,
                        "actions": [], "segmentIds": ["s1"]}],
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        self.assertEqual(len(doc["branches"][0]["text"]), 21)
        self.assertTrue(doc["branches"][0]["text"].endswith("…"))
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.MeetingSkillTests -v
```

预期输出：新增 4 个用例 fail——`to_mindmap` 目前走 `BaseSkill` 默认实现返回 None，首个断言报 `TypeError: 'NoneType' object is not subscriptable`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/agent/skills/meeting.py`：

1. 删除第 31-63 行的 `_TEMPLATE = """..."""` 整块常量。
2. 删除第 232-233 行的 `render` 方法。
3. 在 `fallback` 方法之后（原 `render` 位置）新增：

```python
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, topic in enumerate(plan.get("topics", [])[:MAX_TOPICS]):
            segment_ids = topic.get("segmentIds", [])
            branch = self.make_mindmap_node(index, topic.get("title", ""), segment_ids)
            children: List[Dict[str, Any]] = []
            if topic.get("conclusion"):
                children.append(self.make_mindmap_node(
                    index, "结论：" + str(topic["conclusion"]), segment_ids, len(children)))
            for action in topic.get("actions", []):
                text = str(action.get("text", ""))
                extras = [str(v) for v in (action.get("owner"), action.get("due")) if v]
                if extras:
                    text += "（" + " · ".join(extras) + "）"
                children.append(self.make_mindmap_node(index, text, segment_ids, len(children)))
            branch["children"] = children
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": str(plan.get("title", "会议要点"))}, "branches": branches}
```

4. 修改 `ChartAgent/tests/test_skills.py`：删除 `MeetingSkillTests` 内的 `test_render_contains_conclusion_actions_and_segment_ids`（原第 348-353 行）和 `test_render_contains_rich_sections`（原第 452-496 行）两个测试方法（渲染器已退役）。

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.MeetingSkillTests tests.test_mindmap -v
```

预期输出：`OK`（MeetingSkillTests 剩余用例 + 新增 4 个 + test_mindmap 17 个全部通过）。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/meeting.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart-agent): meeting skill to_mindmap replaces decision_board render"
```

---

## Task 4: lecture skill — to_mindmap 替换 render 与 layout_tree

`LectureSkill` 实现 `to_mindmap(plan)`：root=topic，branches=各章节，children=概念（note 拼接为「概念名：note」）。删除 `_TEMPLATE`、`layout_tree` 与 `render`（知识大纲树退役）。

**Files:**
- Modify: `ChartAgent/agent/skills/lecture.py`（删除第 26-59 行 `_TEMPLATE`；删除第 226-261 行 `layout_tree` 与 `render`；新增 `to_mindmap`）
- Test: `ChartAgent/tests/test_skills.py`（`LectureSkillTests` 内删除 `test_layout_positions_are_deterministic`、`test_render_svg_contains_nodes_and_segment_ids`、`test_render_chapter_cards_contain_note_and_points`、`test_layout_bounds_at_max_capacity` 四个方法，新增映射测试）

- [ ] **Step 1: 追加失败测试**

在 `LectureSkillTests` 类内追加：

```python
    def test_to_mindmap_maps_chapters_and_concepts(self):
        plan = {
            "chartType": "knowledge_tree", "title": "Transformer 精讲", "topic": "Transformer",
            "chapters": [
                {"title": "注意力机制", "points": ["核心讲解"],
                 "concepts": [{"name": "QKV 计算", "note": "查询键值", "segmentIds": ["s2"]}],
                 "segmentIds": ["s2"]},
                {"title": "位置编码", "points": [],
                 "concepts": [{"name": "正弦编码", "note": None, "segmentIds": ["s3"]}],
                 "segmentIds": ["s3"]},
            ],
        }
        doc = SKILLS["lecture"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "Transformer"})
        self.assertEqual([b["id"] for b in doc["branches"]], ["b0", "b1"])
        self.assertEqual(doc["branches"][0]["text"], "注意力机制")
        self.assertEqual(doc["branches"][0]["segment_ids"], ["s2"])
        child = doc["branches"][0]["children"][0]
        self.assertEqual(child["id"], "b0c0")
        self.assertEqual(child["text"], "QKV 计算：查询键值")
        self.assertEqual(child["segment_ids"], ["s2"])
        self.assertEqual(doc["branches"][1]["children"][0]["text"], "正弦编码")

    def test_to_mindmap_uses_title_when_topic_missing(self):
        plan = {"chartType": "knowledge_tree", "title": "备用标题", "topic": "",
                "chapters": [{"title": "章", "points": [], "concepts": [], "segmentIds": ["s1"]}]}
        doc = SKILLS["lecture"].to_mindmap(plan)
        self.assertEqual(doc["root"]["text"], "备用标题")

    def test_to_mindmap_returns_none_without_chapters(self):
        self.assertIsNone(SKILLS["lecture"].to_mindmap(
            {"chartType": "knowledge_tree", "title": "x", "topic": "x", "chapters": []}))
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.LectureSkillTests -v
```

预期输出：新增 3 个用例报 `TypeError: 'NoneType' object is not subscriptable`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/agent/skills/lecture.py`：

1. 删除第 26-59 行 `_TEMPLATE` 常量。
2. 删除第 226-261 行的 `layout_tree` 静态方法与 `render` 方法。
3. 在 `fallback` 方法之后新增：

```python
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, chapter in enumerate(plan.get("chapters", [])[:MAX_CHAPTERS]):
            branch = self.make_mindmap_node(index, chapter.get("title", ""), chapter.get("segmentIds", []))
            children: List[Dict[str, Any]] = []
            for concept in chapter.get("concepts", []):
                text = str(concept.get("name", ""))
                if concept.get("note"):
                    text += "：" + str(concept["note"])
                children.append(self.make_mindmap_node(
                    index, text, concept.get("segmentIds", []), len(children)))
            branch["children"] = children
            branches.append(branch)
        if not branches:
            return None
        root_text = str(plan.get("topic") or plan.get("title", "讲座大纲"))
        return {"root": {"id": "root", "text": root_text}, "branches": branches}
```

4. 修改 `ChartAgent/tests/test_skills.py`：删除 `LectureSkillTests` 内的 `test_layout_positions_are_deterministic`（原第 671-679 行）、`test_render_svg_contains_nodes_and_segment_ids`（原第 680-687 行）、`test_render_chapter_cards_contain_note_and_points`（原第 747-756 行）、`test_layout_bounds_at_max_capacity`（原第 768-802 行）四个测试方法。

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.LectureSkillTests -v
```

预期输出：`OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/lecture.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart-agent): lecture skill to_mindmap replaces knowledge_tree render"
```

---

## Task 5: interview skill — to_mindmap 替换 render

`InterviewSkill` 实现 `to_mindmap(plan)`：root=访谈标题，branches=各问题（≤8），children=回答要点 + 原话金句（加引号）+ 关键词标签（# 前缀）。

**Files:**
- Modify: `ChartAgent/agent/skills/interview.py`（删除 `_TEMPLATE` 常量与文件末尾的 `render` 方法；import 区加 `from ..mindmap import MAX_BRANCHES`；新增 `to_mindmap`）
- Test: `ChartAgent/tests/test_skills.py`（`InterviewSkillTests` 内删除 `test_render_contains_question_answer_tags`（原第 529-536 行）与 `test_render_contains_points_and_quote`（原第 598-638 行），新增映射测试）

- [ ] **Step 1: 追加失败测试**

在 `InterviewSkillTests` 类内追加：

```python
    def test_to_mindmap_maps_qas_answers_quotes_tags(self):
        plan = {
            "chartType": "qa_cards", "title": "部署访谈",
            "qas": [
                {"question": "为什么坚持私有化部署？", "answerPoints": ["数据安全是底线"],
                 "quote": "数据不能出内网，这是红线", "tags": ["数据安全"], "segmentIds": ["s2"]},
                {"question": "未来会扩展吗？", "answerPoints": ["先小范围试点"],
                 "quote": None, "tags": [], "segmentIds": ["s4"]},
            ],
        }
        doc = SKILLS["interview"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "部署访谈"})
        self.assertEqual([b["text"] for b in doc["branches"]], ["为什么坚持私有化部署？", "未来会扩展吗？"])
        first_children = doc["branches"][0]["children"]
        self.assertEqual([c["id"] for c in first_children], ["b0c0", "b0c1", "b0c2"])
        texts = [c["text"] for c in first_children]
        self.assertIn("数据安全是底线", texts)
        self.assertIn("“数据不能出内网，这是红线”", texts)
        self.assertIn("#数据安全", texts)
        self.assertEqual(doc["branches"][1]["children"][0]["text"], "先小范围试点")

    def test_to_mindmap_returns_none_without_qas(self):
        self.assertIsNone(SKILLS["interview"].to_mindmap({"chartType": "qa_cards", "title": "x", "qas": []}))

    def test_to_mindmap_caps_branches_at_eight(self):
        plan = {
            "chartType": "qa_cards", "title": "t",
            "qas": [{"question": f"问题{i}", "answerPoints": [], "quote": None, "tags": [],
                     "segmentIds": [f"s{i}"]} for i in range(10)],
        }
        doc = SKILLS["interview"].to_mindmap(plan)
        self.assertEqual(len(doc["branches"]), 8)
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.InterviewSkillTests -v
```

预期输出：新增 3 个用例报 `TypeError: 'NoneType' object is not subscriptable`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/agent/skills/interview.py`：

1. 删除 `_TEMPLATE = """..."""` 常量（文件第 25-41 行附近）。
2. 在 import 区（现有 `from ..textutils import ...` 一行之后）加：

```python
from ..mindmap import MAX_BRANCHES
```

3. 删除文件末尾的 `render` 方法，在原位置新增：

```python
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, qa in enumerate(plan.get("qas", [])[:MAX_BRANCHES]):
            segment_ids = qa.get("segmentIds", [])
            branch = self.make_mindmap_node(index, qa.get("question", ""), segment_ids)
            children: List[Dict[str, Any]] = []
            for point in qa.get("answerPoints", []):
                children.append(self.make_mindmap_node(index, point, segment_ids, len(children)))
            if qa.get("quote"):
                children.append(self.make_mindmap_node(
                    index, "“" + str(qa["quote"]) + "”", segment_ids, len(children)))
            for tag in qa.get("tags", []):
                children.append(self.make_mindmap_node(index, "#" + str(tag), segment_ids, len(children)))
            branch["children"] = children
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": str(plan.get("title", "访谈要点"))}, "branches": branches}
```

4. 修改 `ChartAgent/tests/test_skills.py`：删除 `InterviewSkillTests` 内的 `test_render_contains_question_answer_tags`（原第 529-536 行）与 `test_render_contains_points_and_quote`（原第 598-638 行）两个测试方法。

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.InterviewSkillTests -v
```

预期输出：`OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/interview.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart-agent): interview skill to_mindmap replaces qa_cards render"
```

---

## Task 6: dialogue skill — to_mindmap 替换 render 与 layout_swimlane

`DialogueSkill` 实现 `to_mindmap(plan)`：root=对话标题，branches=各话题块（≤8），children=摘要 + 关键点 + 一行「说话人 · mm:ss-mm:ss」元信息。删除 `_TEMPLATE`、`_LANE_COLORS`/`_LANE_TEXT_COLORS`、`layout_swimlane`、`render`（话题泳道图退役）。

**Files:**
- Modify: `ChartAgent/agent/skills/dialogue.py`（删除第 26-52 行 `_TEMPLATE`、第 54-55 行颜色常量、第 213-276 行 `layout_swimlane` 与 `render`；import 区加 `from ..mindmap import MAX_BRANCHES`；新增 `to_mindmap`）
- Test: `ChartAgent/tests/test_skills.py`（`DialogueSkillTests` 内删除 `test_render_block_cards_contain_summary_and_key_points`、`test_layout_is_deterministic_and_within_bounds`、`test_render_svg_contains_lanes_blocks_and_segment_ids`、`test_layout_stacks_colliding_blocks_in_subrows`、`test_layout_colors_follow_lane`、`test_layout_truncates_topic_label_to_block_width` 六个方法，新增映射测试）

- [ ] **Step 1: 追加失败测试**

在 `DialogueSkillTests` 类内追加：

```python
    def test_to_mindmap_maps_blocks_with_speaker_time_meta(self):
        plan = {
            "chartType": "topic_swimlane", "title": "项目讨论", "speakers": ["甲", "乙"],
            "blocks": [
                {"speaker": "甲", "topic": "预算", "summary": "预算紧张要想办法", "keyPoints": ["控制开支"],
                 "start": 0.0, "end": 10.0, "segmentIds": ["s1"]},
                {"speaker": "乙", "topic": "进度", "summary": None, "keyPoints": [],
                 "start": 65.0, "end": 90.0, "segmentIds": ["s2"]},
            ],
        }
        doc = SKILLS["dialogue"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "项目讨论"})
        self.assertEqual([b["text"] for b in doc["branches"]], ["预算", "进度"])
        first_texts = [c["text"] for c in doc["branches"][0]["children"]]
        self.assertIn("预算紧张要想办法", first_texts)
        self.assertIn("控制开支", first_texts)
        self.assertIn("甲 · 00:00-00:10", first_texts)
        second_texts = [c["text"] for c in doc["branches"][1]["children"]]
        self.assertEqual(second_texts, ["乙 · 01:05-01:30"])

    def test_to_mindmap_returns_none_without_blocks(self):
        self.assertIsNone(SKILLS["dialogue"].to_mindmap(
            {"chartType": "topic_swimlane", "title": "x", "speakers": [], "blocks": []}))

    def test_to_mindmap_caps_branches_at_eight(self):
        plan = {
            "chartType": "topic_swimlane", "title": "t", "speakers": ["甲"],
            "blocks": [{"speaker": "甲", "topic": f"话题{i}", "summary": None, "keyPoints": [],
                        "start": float(i * 10), "end": float(i * 10 + 5), "segmentIds": [f"s{i}"]}
                       for i in range(12)],
        }
        doc = SKILLS["dialogue"].to_mindmap(plan)
        self.assertEqual(len(doc["branches"]), 8)
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.DialogueSkillTests -v
```

预期输出：新增 3 个用例报 `TypeError: 'NoneType' object is not subscriptable`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/agent/skills/dialogue.py`：

1. 删除第 26-52 行 `_TEMPLATE` 常量、第 54-55 行 `_LANE_COLORS`/`_LANE_TEXT_COLORS`、第 213-276 行 `layout_swimlane` 与 `render`。
2. import 区加 `from ..mindmap import MAX_BRANCHES`。
3. 在 `fallback` 方法之后新增：

```python
    @staticmethod
    def _fmt_mmss(seconds: Any) -> str:
        total = int(float(seconds or 0))
        return f"{total // 60:02d}:{total % 60:02d}"

    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, block in enumerate(plan.get("blocks", [])[:MAX_BRANCHES]):
            segment_ids = block.get("segmentIds", [])
            branch = self.make_mindmap_node(index, block.get("topic", ""), segment_ids)
            children: List[Dict[str, Any]] = []
            if block.get("summary"):
                children.append(self.make_mindmap_node(index, block["summary"], segment_ids, len(children)))
            for point in block.get("keyPoints", []):
                children.append(self.make_mindmap_node(index, point, segment_ids, len(children)))
            children.append(self.make_mindmap_node(
                index,
                f"{block.get('speaker', '')} · {self._fmt_mmss(block.get('start'))}-{self._fmt_mmss(block.get('end'))}",
                segment_ids,
                len(children),
            ))
            branch["children"] = children
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": str(plan.get("title", "对话脉络"))}, "branches": branches}
```

4. 修改 `ChartAgent/tests/test_skills.py`：删除 `DialogueSkillTests` 内的 `test_render_block_cards_contain_summary_and_key_points`（原第 854-864 行）、`test_layout_is_deterministic_and_within_bounds`（原第 874-880 行）、`test_render_svg_contains_lanes_blocks_and_segment_ids`（原第 881-887 行）、`test_layout_stacks_colliding_blocks_in_subrows`（原第 897-906 行）、`test_layout_colors_follow_lane`（原第 907-912 行）、`test_layout_truncates_topic_label_to_block_width`（原第 919-953 行）六个测试方法。

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.DialogueSkillTests -v
```

预期输出：`OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/dialogue.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart-agent): dialogue skill to_mindmap replaces topic_swimlane render"
```

---

## Task 7: speech skill — to_mindmap 替换 render 与 layout_arc

`SpeechSkill` 实现 `to_mindmap(plan)`：root=演讲标题，branches=各 stage 的 label（保持 opening→buildup→climax→closing 顺序），children=summary + points + 金句（加引号）。删除 `_TEMPLATE`、`_STAGE_POINTS`/`_ARC_PATH`、`layout_arc`、`render`（叙事弧线图退役）。

**Files:**
- Modify: `ChartAgent/agent/skills/speech.py`（删除 `_TEMPLATE` 常量、第 58-59 行 `_STAGE_POINTS`/`_ARC_PATH`、第 194-215 行 `layout_arc` 与 `render`；新增 `to_mindmap`）
- Test: `ChartAgent/tests/test_skills.py`（`SpeechSkillTests` 内删除 `test_layout_stage_points_match_canonical_positions`、`test_render_svg_contains_arc_quote_and_segment_ids`、`test_render_stage_cards_contain_points_and_summary`、`test_layout_endpoint_text_fits_viewbox` 四个方法，新增映射测试）

- [ ] **Step 1: 追加失败测试**

在 `SpeechSkillTests` 类内追加：

```python
    def test_to_mindmap_maps_stages_summary_points_quote(self):
        plan = {
            "chartType": "narrative_arc", "title": "改变",
            "stages": [
                {"stage": "opening", "label": "故事", "summary": "三年前的转折", "points": [],
                 "quote": None, "segmentIds": ["s1"]},
                {"stage": "climax", "label": "顿悟", "summary": None, "points": ["现状可改变"],
                 "quote": "改变从今晚开始", "segmentIds": ["s3"]},
            ],
        }
        doc = SKILLS["speech"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "改变"})
        self.assertEqual([b["text"] for b in doc["branches"]], ["故事", "顿悟"])
        self.assertEqual([c["text"] for c in doc["branches"][0]["children"]], ["三年前的转折"])
        climax_texts = [c["text"] for c in doc["branches"][1]["children"]]
        self.assertEqual(climax_texts, ["现状可改变", "“改变从今晚开始”"])
        self.assertEqual(doc["branches"][1]["children"][0]["segment_ids"], ["s3"])

    def test_to_mindmap_returns_none_without_stages(self):
        self.assertIsNone(SKILLS["speech"].to_mindmap(
            {"chartType": "narrative_arc", "title": "x", "stages": []}))
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.SpeechSkillTests -v
```

预期输出：新增 2 个用例报 `TypeError: 'NoneType' object is not subscriptable`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/agent/skills/speech.py`：

1. 删除 `_TEMPLATE` 常量、第 58-59 行 `_STAGE_POINTS` 与 `_ARC_PATH`、第 194-215 行 `layout_arc` 与 `render`。
2. 在 `fallback` 方法之后新增：

```python
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, stage in enumerate(plan.get("stages", [])):
            segment_ids = stage.get("segmentIds", [])
            branch = self.make_mindmap_node(index, stage.get("label", ""), segment_ids)
            children: List[Dict[str, Any]] = []
            if stage.get("summary"):
                children.append(self.make_mindmap_node(index, stage["summary"], segment_ids, len(children)))
            for point in stage.get("points", []):
                children.append(self.make_mindmap_node(index, point, segment_ids, len(children)))
            if stage.get("quote"):
                children.append(self.make_mindmap_node(
                    index, "“" + str(stage["quote"]) + "”", segment_ids, len(children)))
            branch["children"] = children
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": str(plan.get("title", "演讲结构"))}, "branches": branches}
```

3. 修改 `ChartAgent/tests/test_skills.py`：删除 `SpeechSkillTests` 内的 `test_layout_stage_points_match_canonical_positions`（原第 987-994 行）、`test_render_svg_contains_arc_quote_and_segment_ids`（原第 995-1001 行）、`test_render_stage_cards_contain_points_and_summary`（原第 1044-1054 行）、`test_layout_endpoint_text_fits_viewbox`（原第 1055-1067 行）四个测试方法。

- [ ] **Step 4: 运行确认通过**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.SpeechSkillTests -v
```

预期输出：`OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/speech.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart-agent): speech skill to_mindmap replaces narrative_arc render"
```

---

## Task 8: memo skill — to_mindmap 替换 render；清理 BaseSkill 孤儿渲染助手

`MemoSkill` 实现 `to_mindmap(plan)`：root=coreIdea，每条要点（text + detail 拼接）直接作为一级分支、无子节点；coreIdea 为空或无要点 → None（分支数 0 → 降级 highlights）。同时清理 BaseSkill 中因 render 退役而无人使用的 `_render_jinja` 及其专用 import。

**Files:**
- Modify: `ChartAgent/agent/skills/memo.py`（删除第 27-45 行 `_TEMPLATE`、第 164-165 行 `render`；import 区加 `from ..mindmap import MAX_BRANCHES`；新增 `to_mindmap`）
- Modify: `ChartAgent/agent/skills/base.py`（删除第 72-85 行 `_render_jinja`；删除不再使用的 `from jinja2 import DictLoader, Environment` 与 `from ..templates import BASE_TEMPLATE, DARK_CSS` 两行 import）
- Test: `ChartAgent/tests/test_skills.py`（`MemoSkillTests` 内删除 `test_render_contains_core_idea_and_segment_ids`（原第 218-223 行）与 `test_render_contains_detail`（原第 277-314 行），新增映射测试）

- [ ] **Step 1: 追加失败测试**

在 `MemoSkillTests` 类内追加：

```python
    def test_to_mindmap_maps_core_idea_and_points_as_branches(self):
        plan = {
            "chartType": "idea_card", "title": "随手记要点",
            "coreIdea": "图表要按内容类型路由", "coreSegmentIds": ["s1"],
            "points": [
                {"text": "分类器要能给其他兜底", "detail": "否则白屏", "segmentIds": ["s1"]},
                {"text": "渲染统一成思维导图", "detail": None, "segmentIds": ["s2"]},
            ],
        }
        doc = SKILLS["memo"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "图表要按内容类型路由"})
        self.assertEqual([b["id"] for b in doc["branches"]], ["b0", "b1"])
        self.assertEqual(doc["branches"][0]["text"], "分类器要能给其他兜底：否则白屏")
        self.assertEqual(doc["branches"][0]["segment_ids"], ["s1"])
        self.assertEqual(doc["branches"][0]["children"], [])
        self.assertEqual(doc["branches"][1]["text"], "渲染统一成思维导图")

    def test_to_mindmap_returns_none_without_core_idea(self):
        self.assertIsNone(SKILLS["memo"].to_mindmap(
            {"chartType": "idea_card", "title": "x", "coreIdea": "", "points": []}))

    def test_to_mindmap_returns_none_without_points(self):
        # 只有 coreIdea 时分支数为 0，交给调用方降级 highlights（设计 §7.3）
        self.assertIsNone(SKILLS["memo"].to_mindmap(
            {"chartType": "idea_card", "title": "x", "coreIdea": "只有核心想法", "points": []}))
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_skills.MeetingSkillTests tests.test_skills.MemoSkillTests -v
```

预期输出：`MemoSkillTests` 新增 3 个用例报 `TypeError: 'NoneType' object is not subscriptable`。

- [ ] **Step 3: 最小实现**

1. 修改 `ChartAgent/agent/skills/memo.py`：删除第 27-45 行 `_TEMPLATE` 与第 164-165 行 `render`；import 区加 `from ..mindmap import MAX_BRANCHES`；在 `fallback` 之后新增：

```python
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        core_idea = str(plan.get("coreIdea", "")).strip()
        if not core_idea:
            return None
        branches = []
        for index, point in enumerate(plan.get("points", [])[:MAX_BRANCHES]):
            text = str(point.get("text", ""))
            if point.get("detail"):
                text += "：" + str(point["detail"])
            branches.append(self.make_mindmap_node(index, text, point.get("segmentIds", [])))
        if not branches:
            return None
        return {"root": {"id": "root", "text": core_idea}, "branches": branches}
```

2. 修改 `ChartAgent/agent/skills/base.py`：删除 `_render_jinja` 方法（第 72-85 行）；删除 import 区不再使用的两行 `from jinja2 import DictLoader, Environment` 与 `from ..templates import BASE_TEMPLATE, DARK_CSS`。
3. 修改 `ChartAgent/tests/test_skills.py`：删除 `MemoSkillTests` 内的 `test_render_contains_core_idea_and_segment_ids`（原第 218-223 行）与 `test_render_contains_detail`（原第 277-314 行）两个测试方法。

- [ ] **Step 4: 运行确认通过（全量 Python 测试，确认无孤儿引用）**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -v
```

预期输出：`Ran 190+ tests ... OK`。注意 `OtherSkillTests.test_render_*` 仍须通过（`other.py` 的 `render` 直接调用 `templates.render_highlights`，不依赖 `_render_jinja`）。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/skills/memo.py ChartAgent/agent/skills/base.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart-agent): memo skill to_mindmap; drop orphaned render helpers"
```

---

## Task 9: nodes/graph 接线 — mindmap_normalize 节点 + render_chart 分发 + _assert_render_fragment

在 `nodes.py` 新增 `mindmap_normalize_node`（plan → MindMapDoc 归一化，分支数 0 降级 highlights）与 `_assert_render_fragment`（渲染产物结构校验，供节点与 `/chart/render` 端点共用）；改造 `render_chart_node`：`chartType == "mind_map"` 走 `MindMapRenderer`，否则走 skill render（highlights）；`validate_render` 复用 `_assert_render_fragment`。`graph.py` 在 `validate_plan` 与 `render_chart` 之间插入 `mindmap_normalize` 节点。`skills/__init__.py` 的 `CHART_TYPE_DISPLAY_NAMES` 增加 `"mind_map": "思维导图"`。

**Files:**
- Modify: `ChartAgent/agent/nodes.py`（import 区第 14-21 行；`render_chart_node` 第 326-344 行整体替换；`validate_render` 第 347-362 行整体替换；`validate_plan` 之后即第 323 行后插入 `mindmap_normalize_node` 与 `_assert_render_fragment`）
- Modify: `ChartAgent/agent/graph.py`（第 6-15 行 import；第 49-67 行装配）
- Modify: `ChartAgent/agent/skills/__init__.py`（第 26 行 `CHART_TYPE_DISPLAY_NAMES`）
- Test: `ChartAgent/tests/test_mindmap_pipeline.py`（新建，本任务只放节点级用例）

- [ ] **Step 1: 写失败测试**

创建 `ChartAgent/tests/test_mindmap_pipeline.py`：

```python
"""v5 流水线思维导图改造测试：mindmap_normalize 节点、渲染分发、降级链。LLM 全部打桩。"""
import json
import unittest
from unittest.mock import patch

from agent import nodes
from agent.graph import chart_agent

from tests.test_pipeline import (
    MEETING_PLAN,
    MEETING_SEGMENTS,
    base_state,
    classify_response,
    router_fake,
)


class MindmapNormalizeNodeTests(unittest.TestCase):
    def test_meeting_plan_normalized_to_mind_map(self):
        state = base_state(MEETING_SEGMENTS, content_type="meeting", plan=dict(MEETING_PLAN))
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        doc = result["plan"]["mindMap"]
        self.assertEqual(doc["root"], {"id": "root", "text": "私有化部署讨论会"})
        self.assertEqual(doc["branches"][0]["id"], "b0")
        self.assertEqual(doc["branches"][0]["text"], "私有化部署")
        self.assertEqual(doc["branches"][0]["segment_ids"], ["s1", "s2"])

    def test_highlights_plan_passes_through_untouched(self):
        highlights_plan = {
            "chartType": "highlights", "title": "重点句子",
            "highlightSentences": [{"segmentId": "s1", "text": "重点", "speaker": "甲",
                                    "startTime": 0.0, "endTime": 5.0, "tag": "关键判断"}],
            "truncatedCount": 0,
        }
        state = base_state(MEETING_SEGMENTS, content_type="other", plan=highlights_plan)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertNotIn("mindMap", result["plan"])

    def test_empty_branches_degrades_to_highlights(self):
        plan = {"chartType": "idea_card", "title": "随手记要点",
                "coreIdea": "只有想法没有要点", "coreSegmentIds": ["s1"], "points": []}
        state = base_state(MEETING_SEGMENTS, content_type="memo", plan=plan)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertTrue(result["validation_result"]["degraded"])
        self.assertEqual(result["validation_result"]["reason"], "mindmap_empty")

    def test_failed_state_passes_through(self):
        state = base_state(MEETING_SEGMENTS, status="failed", plan=None)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["status"], "failed")
        self.assertIsNone(result["plan"])

    def test_missing_plan_degrades_to_highlights(self):
        state = base_state(MEETING_SEGMENTS, content_type="meeting", plan=None)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "highlights")


class AssertRenderFragmentTests(unittest.TestCase):
    def test_accepts_balanced_traceable_fragment(self):
        nodes._assert_render_fragment('<div data-segment-ids="s1">ok</div>')

    def test_rejects_empty(self):
        with self.assertRaises(ValueError):
            nodes._assert_render_fragment("   ")

    def test_rejects_missing_segment_ids(self):
        with self.assertRaises(ValueError):
            nodes._assert_render_fragment("<div>ok</div>")

    def test_rejects_unbalanced_divs(self):
        with self.assertRaises(ValueError):
            nodes._assert_render_fragment('<div data-segment-ids="s1"><div>ok</div>')


class MindMapRenderDispatchTests(unittest.TestCase):
    def test_pipeline_meeting_renders_mind_map_svg(self):
        with patch.object(nodes, "call_llm", side_effect=router_fake('"decision_board"', MEETING_PLAN, "meeting")):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        html = result["html_fragment"]
        self.assertIn("<svg", html)
        self.assertIn("私有化部署讨论会", html)
        self.assertIn('data-segment-ids="s1,s2"', html)
        self.assertEqual(html.count("<div"), html.count("</div>"))

    def test_pipeline_degraded_highlights_still_uses_highlights_renderer(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("other")
            raise AssertionError("other 类型不应调用提取 LLM")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertNotIn("mindMap", result["plan"])
        self.assertNotIn("<svg", result["html_fragment"])

    def test_mind_map_render_keeps_overview_bar(self):
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
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn('<div class="sc-overview">', result["html_fragment"])
        self.assertIn("会议确认了私有化部署的排期与分工", result["html_fragment"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap_pipeline -v
```

预期输出：`AttributeError: module 'agent.nodes' has no attribute 'mindmap_normalize_node'`。

- [ ] **Step 3: 最小实现**

1. 修改 `ChartAgent/agent/nodes.py` import 区，在 `from .skills import SKILLS, skill_for_chart_type` 一行之后加：

```python
from .mindmap import MindMapRenderer
```

并在文件顶部常量区（第 23-28 行 `CHUNK_CHARACTER_BUDGET` 等附近）加：

```python
MIND_MAP_CHART_TYPE = "mind_map"
```

2. 在 `validate_plan` 函数结束之后（原第 323 行 `return _degrade_to_highlights(state, "validation_failed")` 之后）插入：

```python
def mindmap_normalize_node(state: Dict[str, Any]) -> Dict[str, Any]:
    """plan → MindMapDoc 归一化：六种类型统一出 mind_map；other/highlights 原样放行。
    归一化结果分支数为 0 → 降级 highlights（设计文档 §7.3）。"""
    if state.get("status") == "failed":
        return state
    plan = state.get("plan")
    if not plan:
        return _degrade_to_highlights(state, "plan_missing")
    if str(plan.get("chartType", "highlights")) == "highlights":
        return state
    started = time.monotonic()
    skill = _skill_for_state(state)
    doc = skill.to_mindmap(plan)
    if doc is None or not doc.get("branches"):
        return _degrade_to_highlights(state, "mindmap_empty")
    plan["chartType"] = MIND_MAP_CHART_TYPE
    plan["mindMap"] = doc
    state["plan"] = plan
    log_event("INFO", "mindmap_normalize", state.get("request_id"), state.get("recording_id"),
              contentType=state.get("content_type"), branchCount=len(doc.get("branches", [])),
              elapsedMs=_elapsed_ms(started))
    return state


def _assert_render_fragment(html: str) -> None:
    """渲染产物结构校验（validate_render 节点与 /chart/render 端点共用）；不通过抛 ValueError。"""
    if not html.strip():
        raise ValueError("渲染结果为空")
    if "data-segment-ids" not in html:
        raise ValueError("渲染结果缺少 data-segment-ids")
    if html.count("<div") != html.count("</div>"):
        raise ValueError("渲染结果 div 标签不平衡")
```

3. 将 `render_chart_node`（原第 326-344 行）整体替换为：

```python
def render_chart_node(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    started = time.monotonic()
    plan = state.get("plan") or {}
    theme = state.get("preferences", {}).get("styleTheme", "darkCyberpunk")
    chart_type = str(plan.get("chartType", "highlights"))
    try:
        if chart_type == MIND_MAP_CHART_TYPE:
            state["html_fragment"] = MindMapRenderer().render(
                plan.get("mindMap") or {"root": {"id": "root", "text": str(plan.get("title", ""))}, "branches": []},
                theme,
                str(plan.get("title", "")),
                overview=state.get("overview"),
            )
        else:
            if state.get("overview"):
                plan["overview"] = state["overview"]
                state["plan"] = plan
            skill = skill_for_chart_type(chart_type)
            state["html_fragment"] = skill.render(plan, theme, str(plan.get("title", "")))
        state["render_config"] = {"cssFramework": "smartchart-v5"}
    except Exception as error:
        log_event("ERROR", "render", state.get("request_id"), state.get("recording_id"), **safe_error_fields(error))
        return _fail(state, f"图表渲染失败：{error}")
    log_event("INFO", "render", state.get("request_id"), state.get("recording_id"),
              chartType=chart_type, elapsedMs=_elapsed_ms(started))
    return state
```

4. 将 `validate_render`（原第 347-362 行）整体替换为：

```python
def validate_render(state: Dict[str, Any]) -> Dict[str, Any]:
    if state.get("status") == "failed":
        return state
    try:
        _assert_render_fragment(state.get("html_fragment") or "")
    except ValueError as error:
        state["validation_result"] = {"passed": False, "errors": [str(error)]}
        return _fail(state, str(error))
    state["status"] = "success"
    return state
```

5. 修改 `ChartAgent/agent/graph.py`：import 块（第 6-15 行）加入 `mindmap_normalize_node`；docstring 改为 `"""SmartChart v5 LangGraph 编排：prepare → classify → overview → extract → merge → validate → mindmap_normalize → render → validate_render。"""`；`build_chart_agent` 中在 `builder.add_node("validate_plan", validate_plan)` 之后加 `builder.add_node("mindmap_normalize", mindmap_normalize_node)`，并把 `validate_plan → render_chart` 的边改为：

```python
    builder.add_conditional_edges("validate_plan", _continue_or_end, {"continue": "mindmap_normalize", END: END})
    builder.add_conditional_edges("mindmap_normalize", _continue_or_end, {"continue": "render_chart", END: END})
```

6. 修改 `ChartAgent/agent/skills/__init__.py` 第 26 行，改为：

```python
CHART_TYPE_DISPLAY_NAMES = {skill.chart_type: skill.display_name for skill in SKILLS.values()}
CHART_TYPE_DISPLAY_NAMES["mind_map"] = "思维导图"
```

- [ ] **Step 4: 运行确认通过（新测试文件）**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap_pipeline -v
```

预期输出：`Ran 11 tests ... OK`。注意：此时全量测试尚不会全绿——`tests/test_pipeline.py` 的旧断言（chartType 为六种旧类型）会在下一任务更新，本任务只要求 `test_mindmap_pipeline` 通过。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/nodes.py ChartAgent/agent/graph.py ChartAgent/agent/skills/__init__.py ChartAgent/tests/test_mindmap_pipeline.py
git commit -m "feat(chart-agent): wire mindmap_normalize node and mind_map render dispatch"
```

---

## Task 10: 既有流水线测试升级（六种类型 → mind_map 断言）

`tests/test_pipeline.py` 的流水线断言升级为 v5：六种类型 chartType 统一断言 `"mind_map"`，端点版本字面量与显示名在 Task 11 处理，本任务只改节点级/图级断言，保证全量 Python 测试转绿。

**Files:**
- Modify: `ChartAgent/tests/test_pipeline.py`（`PipelineTypeRoutingTests` 6 个路由用例的断言；`PipelineForceTypeTests.test_forced_content_type_skips_classifier` 的 chartType 断言）

- [ ] **Step 1: 运行确认失败（基线）**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_pipeline.PipelineTypeRoutingTests tests.test_pipeline.PipelineForceTypeTests -v
```

预期输出：6 个路由用例 fail（`AssertionError: 'mind_map' != 'decision_board'` 等），`test_forced_content_type_skips_classifier` fail（`'mind_map' != 'idea_card'`）；其余（降级、竞态类）通过。

- [ ] **Step 2: 最小实现（更新断言与用例名）**

对 `ChartAgent/tests/test_pipeline.py` 做如下替换：

1. `PipelineTypeRoutingTests` 中六个用例改名并改断言（方法体其余部分不变）：
   - `test_meeting_routes_to_decision_board` → `test_meeting_routes_to_mind_map`，断言改为 `self.assertEqual(result["plan"]["chartType"], "mind_map")`，保留 `assertIn("私有化部署", ...)`。
   - `test_interview_routes_to_qa_cards` → `test_interview_routes_to_mind_map`，断言改为 `self.assertEqual(result["plan"]["chartType"], "mind_map")`，保留 `assertIn("数据不能出内网，这是红线", ...)`（该句作为金句要点进入思维导图）。
   - `test_lecture_routes_to_knowledge_tree` → `test_lecture_routes_to_mind_map`，chartType 断言改 `"mind_map"`，保留 `"<svg"` 与 `"注意力机制"` 断言。
   - `test_dialogue_routes_to_topic_swimlane` → `test_dialogue_routes_to_mind_map`，chartType 断言改 `"mind_map"`，保留 `"<svg"` 断言。
   - `test_speech_routes_to_narrative_arc` → `test_speech_routes_to_mind_map`，chartType 断言改 `"mind_map"`，保留 `"改变从今晚开始"` 断言。
   - `test_memo_routes_to_idea_card` → `test_memo_routes_to_mind_map`，chartType 断言改 `"mind_map"`，保留 `"图表要按内容类型路由"` 断言（作为 root 文本出现）。
2. `PipelineTypeRoutingTests` 类 docstring 改为 `"""七种类型各跑一遍完整流水线，六种类型统一断言 chartType == "mind_map"，other 走 highlights。"""`。
3. `PipelineForceTypeTests.test_forced_content_type_skips_classifier` 的 `self.assertEqual(result["plan"]["chartType"], "idea_card")` 改为 `self.assertEqual(result["plan"]["chartType"], "mind_map")`。

- [ ] **Step 3: 运行确认通过（全量）**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -v
```

预期输出：`Ran 200+ tests ... OK`（除 `PipelineEndpointTests` 的版本相关用例——`test_response_contains_v4_content_type_fields` 仍用 `"4.0"` 版本字面量，在 v4 schema 下此刻仍通过；它在 Task 11 升级后由该任务的步骤同步修正）。

- [ ] **Step 4: Commit**

```bash
git add ChartAgent/tests/test_pipeline.py
git commit -m "test(chart-agent): assert unified mind_map chartType for six content types"
```

---

## Task 11: schema v5 — MindMapDoc 模型、mindMap 响应字段、/chart/render 契约

`schema.py` 整体升级 v5：`version` 字面量 `"4.0"` → `"5.0"`；新增 `MindMapRoot`/`MindMapChild`/`MindMapBranch`/`MindMapDoc`（全部 `StrictModel`，extra="forbid"）；`SmartChartGenerateResponse` 新增 `mindMap: Optional[MindMapDoc]`；新增 `SmartChartRenderRequest`/`SmartChartRenderResponse`；`ChartType` 字面量改为 `mind_map | highlights`。

**Files:**
- Modify: `ChartAgent/agent/schema.py`（全文 45 行整体替换）
- Modify: `ChartAgent/main.py`（第 134-145 行 `/chart/generate` 成功响应组装，新增 `mindMap` 字段）
- Modify: `ChartAgent/tests/test_pipeline.py`（`PipelineEndpointTests` 两个用例的版本字面量与断言）
- Modify: `ChartAgent/tests/test_smartchart.py`（`SmartChartSchemaV4Tests` 类与版本字面量、`SmartChartEndpointTimeoutTests`/`SmartChartEndpointRaceTests` 的 payload 版本）

- [ ] **Step 1: 追加失败测试**

在 `ChartAgent/tests/test_mindmap_pipeline.py` 末尾（`if __name__` 之前）追加：

```python
from pydantic import ValidationError

from agent.schema import (
    MindMapDoc,
    SmartChartGenerateResponse,
    SmartChartRenderRequest,
)


class SchemaV5ContractTests(unittest.TestCase):
    def test_generate_response_accepts_mindmap(self):
        response = SmartChartGenerateResponse(
            requestId="r1", status="success", contentType="meeting", contentTypeDisplayName="会议",
            chartType="mind_map", chartTypeDisplayName="思维导图", title="t", htmlFragment="<div/>",
            mindMap={"root": {"id": "root", "text": "主题"},
                     "branches": [{"id": "b0", "text": "分支", "segment_ids": ["s1"], "children": []}]},
            plan={},
        )
        self.assertEqual(response.version, "5.0")
        self.assertEqual(response.mindMap.branches[0].segment_ids, ["s1"])

    def test_generate_response_mindmap_defaults_none(self):
        response = SmartChartGenerateResponse(
            requestId="r1", status="success", chartType="highlights",
            chartTypeDisplayName="重点句子", title="t", htmlFragment="<div/>", plan={},
        )
        self.assertIsNone(response.mindMap)

    def test_mindmap_doc_rejects_extra_fields(self):
        with self.assertRaises(ValidationError):
            MindMapDoc.model_validate({
                "root": {"id": "root", "text": "t"},
                "branches": [{"id": "b0", "text": "b", "segment_ids": [], "children": [], "bogus": 1}],
            })

    def test_mindmap_doc_rejects_empty_text(self):
        with self.assertRaises(ValidationError):
            MindMapDoc.model_validate({
                "root": {"id": "root", "text": ""},
                "branches": [],
            })

    def test_render_request_contract(self):
        request = SmartChartRenderRequest.model_validate({
            "version": "5.0", "requestId": "r1", "recordingId": "rec1", "theme": "darkCyberpunk",
            "mindMap": {"root": {"id": "root", "text": "t"}, "branches": []},
        })
        self.assertEqual(request.theme, "darkCyberpunk")

    def test_render_request_rejects_v4_version(self):
        with self.assertRaises(ValidationError):
            SmartChartRenderRequest.model_validate({
                "version": "4.0", "requestId": "r1", "recordingId": "rec1",
                "mindMap": {"root": {"id": "root", "text": "t"}, "branches": []},
            })
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap_pipeline.SchemaV5ContractTests -v
```

预期输出：`ImportError: cannot import name 'MindMapDoc' from 'agent.schema'`。

- [ ] **Step 3: 最小实现（schema.py 整体替换 + 端点测试升级）**

1. 将 `ChartAgent/agent/schema.py` 全文替换为：

```python
"""SmartChart API 契约（v5）：内容类型路由 + 统一思维导图 + 纯渲染接口 /chart/render。"""
from typing import Any, Dict, List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field

ContentType = Literal["meeting", "interview", "lecture", "dialogue", "speech", "memo", "other"]
ChartType = Literal["mind_map", "highlights"]
MIND_MAP_CHART_TYPE: str = "mind_map"


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class TranscriptSegment(StrictModel):
    id: str = Field(min_length=1)
    speaker: str = ""
    startTime: float
    endTime: float
    text: str = Field(min_length=1)


class MindMapNode(StrictModel):
    id: str = Field(min_length=1)
    text: str = Field(min_length=1)
    segment_ids: List[str] = Field(default_factory=list)


class MindMapChild(MindMapNode):
    pass


class MindMapBranch(MindMapNode):
    children: List[MindMapChild] = Field(default_factory=list)


class MindMapRoot(StrictModel):
    """中心主题：无 segment_ids（extra="forbid" 保证客户端不得多传）。"""
    id: str = Field(min_length=1)
    text: str = Field(min_length=1)


class MindMapDoc(StrictModel):
    root: MindMapRoot
    branches: List[MindMapBranch] = Field(default_factory=list)


class SmartChartGenerateRequest(StrictModel):
    version: Literal["5.0"] = "5.0"
    requestId: str = Field(min_length=1)
    recordingId: str = Field(min_length=1)
    segments: List[TranscriptSegment]
    summaryMarkdown: Optional[str] = None
    forceContentType: Optional[ContentType] = None


class SmartChartGenerateResponse(StrictModel):
    version: Literal["5.0"] = "5.0"
    requestId: str
    status: Literal["success", "failed"]
    contentType: ContentType = "other"
    contentTypeDisplayName: str = "其他"
    chartType: str
    chartTypeDisplayName: str
    title: str
    htmlFragment: str
    mindMap: Optional[MindMapDoc] = None
    plan: Dict[str, Any]
    errors: List[str] = Field(default_factory=list)
    errorCode: Optional[str] = None


class SmartChartRenderRequest(StrictModel):
    """POST /chart/render 请求：编辑后的 MindMapDoc 重渲染，不调用 LLM。
    segment_ids 只校验格式（字符串数组），不与原文对照（请求不附 segments）。"""
    version: Literal["5.0"] = "5.0"
    requestId: str = Field(min_length=1)
    recordingId: str = Field(min_length=1)
    mindMap: MindMapDoc
    theme: str = "darkCyberpunk"


class SmartChartRenderResponse(StrictModel):
    version: Literal["5.0"] = "5.0"
    requestId: str
    status: Literal["success", "failed"]
    htmlFragment: str = ""
    errorCode: Optional[str] = None
```

2. 修改 `ChartAgent/tests/test_pipeline.py` 的 `PipelineEndpointTests`：
   - `test_response_contains_v4_content_type_fields` 改名为 `test_response_contains_v5_mind_map_fields`；payload 中 `"version": "4.0"` 改为 `"version": "5.0"`；断言改为：

```python
        self.assertEqual(body["contentType"], "meeting")
        self.assertEqual(body["contentTypeDisplayName"], "会议")
        self.assertEqual(body["chartType"], "mind_map")
        self.assertEqual(body["chartTypeDisplayName"], "思维导图")
        self.assertIsNotNone(body["mindMap"])
        self.assertEqual(body["mindMap"]["root"]["text"], "私有化部署讨论会")
```

   - `test_endpoint_passes_force_content_type` 的 payload 中 `"version": "4.0"` 改为 `"version": "5.0"`。

3. 修改 `ChartAgent/main.py` 第 134-145 行 `/chart/generate` 成功响应组装，在 `htmlFragment=result_state.get("html_fragment") or "",` 之后插入一行（highlights 时 `plan.get("mindMap")` 为 None，响应即为 null）：

```python
        mindMap=plan.get("mindMap"),
```

4. 修改 `ChartAgent/tests/test_smartchart.py`：
   - `SmartChartSchemaV4Tests` 类改名为 `SmartChartSchemaV5Tests`；`test_request_accepts_force_content_type`、`test_request_rejects_unknown_content_type`、`test_request_rejects_extra_fields` 三个 payload 中的 `"version": "4.0"` 改为 `"version": "5.0"`；`test_request_rejects_v3_version` 保持不变（v3 仍应被拒绝）。
   - `SmartChartEndpointTimeoutTests` 与 `SmartChartEndpointRaceTests` 两个 payload 中的 `"version": "4.0"` 改为 `"version": "5.0"`。

- [ ] **Step 4: 运行确认通过（全量）**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -v
```

预期输出：`Ran 210+ tests ... OK`（`main.py` 的 `/health` 版本常量仍为 4.0/4.0.0，`test_health_reports_v4` 此刻仍通过，在 Task 12 升级）。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/schema.py ChartAgent/main.py ChartAgent/tests/test_pipeline.py ChartAgent/tests/test_mindmap_pipeline.py ChartAgent/tests/test_smartchart.py
git commit -m "feat(chart-agent): schema v5 with MindMapDoc, mindMap field and render contract"
```

---

## Task 12: main.py — API/SERVICE 版本升 v5、新增 POST /chart/render

`main.py`：`API_VERSION = "5.0"`、`SERVICE_VERSION = "5.0.0"`；新增 `/chart/render` 纯渲染端点（不调用 LLM，只做 schema 校验 → MindMapRenderer → `_assert_render_fragment`，10s 预算，进程内串行队列用 `threading.Lock` 实现限流串行语义）。同步升级 `test_smartchart.py` 的健康检查断言。（`/chart/generate` 响应的 `mindMap` 字段已在 Task 11 接线。）

**Files:**
- Modify: `ChartAgent/main.py`（第 1-20 行 docstring/import/常量区；第 147 行 `if __name__` 之前插入新端点）
- Modify: `ChartAgent/tests/test_smartchart.py`（`SmartChartHealthTests` 的版本断言）
- Test: `ChartAgent/tests/test_mindmap_render_endpoint.py`（新建）

- [ ] **Step 1: 写失败测试**

创建 `ChartAgent/tests/test_mindmap_render_endpoint.py`：

```python
"""POST /chart/render 契约测试（v5）：纯渲染、零 LLM 调用、extra="forbid"、10s 预算常量。"""
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import main
from agent import nodes
from main import app


def mindmap_payload(**overrides):
    payload = {
        "version": "5.0",
        "requestId": "render-1",
        "recordingId": "rec-1",
        "theme": "darkCyberpunk",
        "mindMap": {
            "root": {"id": "root", "text": "周会纪要"},
            "branches": [
                {"id": "b0", "text": "议题一", "segment_ids": ["s1"],
                 "children": [{"id": "b0c0", "text": "结论：当天完成", "segment_ids": ["s1"]}]}
            ],
        },
    }
    payload.update(overrides)
    return payload


class ChartRenderEndpointTests(unittest.TestCase):
    def _post(self, payload):
        def forbidden_llm(*args, **kwargs):
            raise AssertionError("/chart/render 不得调用 LLM")

        with patch.object(nodes, "call_llm", side_effect=forbidden_llm):
            return TestClient(app).post("/chart/render", json=payload)

    def test_valid_mindmap_roundtrip(self):
        response = self._post(mindmap_payload())
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["version"], "5.0")
        self.assertEqual(body["requestId"], "render-1")
        self.assertEqual(body["status"], "success")
        self.assertIn("周会纪要", body["htmlFragment"])
        self.assertIn('data-segment-ids="s1"', body["htmlFragment"])
        self.assertIsNone(body["errorCode"])

    def test_extra_field_rejected_422(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"][0]["bogus"] = 1
        self.assertEqual(self._post(payload).status_code, 422)

    def test_root_with_segment_ids_rejected_422(self):
        payload = mindmap_payload()
        payload["mindMap"]["root"]["segment_ids"] = ["s1"]
        self.assertEqual(self._post(payload).status_code, 422)

    def test_missing_mindmap_rejected_422(self):
        payload = mindmap_payload()
        del payload["mindMap"]
        self.assertEqual(self._post(payload).status_code, 422)

    def test_wrong_version_rejected_422(self):
        self.assertEqual(self._post(mindmap_payload(version="4.0")).status_code, 422)

    def test_empty_text_rejected_422(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"][0]["text"] = ""
        self.assertEqual(self._post(payload).status_code, 422)

    def test_empty_branches_render_root_only(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"] = []
        body = self._post(payload).json()
        self.assertEqual(body["status"], "success")
        self.assertIn("周会纪要", body["htmlFragment"])

    def test_arbitrary_segment_ids_pass_format_only_check(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"][0]["segment_ids"] = ["forged-id-9"]
        body = self._post(payload).json()
        self.assertEqual(body["status"], "success")
        self.assertIn('data-segment-ids="forged-id-9"', body["htmlFragment"])

    def test_xss_text_escaped(self):
        payload = mindmap_payload()
        payload["mindMap"]["root"]["text"] = "<script>alert(1)</script>"
        body = self._post(payload).json()
        self.assertNotIn("<script>", body["htmlFragment"])
        self.assertIn("&lt;script&gt;", body["htmlFragment"])

    def test_top_level_extra_field_rejected_422(self):
        payload = mindmap_payload()
        payload["surprise"] = True
        self.assertEqual(self._post(payload).status_code, 422)

    def test_render_budget_is_ten_seconds(self):
        self.assertEqual(main.RENDER_ENDPOINT_BUDGET_SECONDS, 10.0)


class ChartRenderFailureTests(unittest.TestCase):
    def test_renderer_exception_returns_structured_error(self):
        with patch.object(main.MindMapRenderer, "render", side_effect=RuntimeError("boom")):
            response = TestClient(app).post("/chart/render", json=mindmap_payload())
        body = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(body["status"], "failed")
        self.assertEqual(body["errorCode"], "RENDER_FAILED")
        self.assertEqual(body["htmlFragment"], "")


class GenerateEndpointV5Tests(unittest.TestCase):
    def test_health_reports_v5(self):
        body = TestClient(app).get("/health").json()
        self.assertEqual(body["apiVersion"], "5.0")
        self.assertEqual(body["serviceVersion"], "5.0.0")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行确认失败**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest tests.test_mindmap_render_endpoint -v
```

预期输出：`404 Not Found`（`/chart/render` 不存在）与 `test_health_reports_v5` 断言失败（当前为 4.0/4.0.0）、`AttributeError: module 'main' has no attribute 'RENDER_ENDPOINT_BUDGET_SECONDS'`。

- [ ] **Step 3: 最小实现**

修改 `ChartAgent/main.py`：

1. 文件 docstring 改为 `"""ChartAgent v5 HTTP 服务：POST /chart/generate + POST /chart/render + GET /health。"""`；import 区第 2-13 行替换为：

```python
import asyncio
import html
import os
import threading
import time
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException

from agent.graph import ChartAgentState, chart_agent
from agent.mindmap import MindMapRenderer
from agent.nodes import _assert_render_fragment
from agent.observability import log_event, safe_error_fields
from agent.schema import (
    SmartChartGenerateRequest,
    SmartChartGenerateResponse,
    SmartChartRenderRequest,
    SmartChartRenderResponse,
)
from agent.skills import CHART_TYPE_DISPLAY_NAMES, CONTENT_TYPE_DISPLAY_NAMES
```

2. 常量区（第 16-20 行）替换为：

```python
API_VERSION = "5.0"
SERVICE_VERSION = "5.0.0"
DEFAULT_TIME_BUDGET_SECONDS = 105.0
ENDPOINT_RESPONSE_RESERVE_SECONDS = 0.5
GRAPH_COMPLETION_MARGIN_SECONDS = 2.0
RENDER_ENDPOINT_BUDGET_SECONDS = 10.0

# /chart/render 进程内串行队列：纯渲染零 LLM，串行执行即可满足限流语义
_render_queue_lock = threading.Lock()
```

3. 在 `if __name__ == "__main__":` 之前插入新端点：

```python
def _render_failed_response(request_id: str, error_code: str) -> SmartChartRenderResponse:
    return SmartChartRenderResponse(requestId=request_id, status="failed", htmlFragment="", errorCode=error_code)


def _render_mindmap_sync(request: SmartChartRenderRequest) -> SmartChartRenderResponse:
    with _render_queue_lock:
        try:
            html_fragment = MindMapRenderer().render(
                request.mindMap.model_dump(), request.theme, request.mindMap.root.text
            )
            _assert_render_fragment(html_fragment)
        except ValueError:
            return _render_failed_response(request.requestId, "INVALID_MINDMAP")
        except Exception:
            return _render_failed_response(request.requestId, "RENDER_FAILED")
        return SmartChartRenderResponse(
            requestId=request.requestId, status="success", htmlFragment=html_fragment
        )


@app.post("/chart/render", response_model=SmartChartRenderResponse)
async def chart_render_endpoint(request: SmartChartRenderRequest):
    """纯渲染接口：编辑后的 MindMapDoc → htmlFragment。不调用 LLM、不做分类与提取；
    segment_ids 只经 schema 校验格式（字符串数组），不与原文对照。预算 10s。"""
    started = time.monotonic()
    log_event("INFO", "render_request_received", request.requestId, request.recordingId,
              branchCount=len(request.mindMap.branches))
    try:
        result = await asyncio.wait_for(
            asyncio.to_thread(_render_mindmap_sync, request),
            timeout=RENDER_ENDPOINT_BUDGET_SECONDS,
        )
    except asyncio.TimeoutError:
        log_event("WARNING", "render_request_finished", request.requestId, request.recordingId,
                  result="failed", errorCode="TIMEOUT", durationMs=_duration_ms(started))
        return _render_failed_response(request.requestId, "TIMEOUT")
    log_event("INFO", "render_request_finished", request.requestId, request.recordingId,
              result=result.status, durationMs=_duration_ms(started))
    return result
```

4. 修改 `ChartAgent/tests/test_smartchart.py`：`SmartChartHealthTests.test_health_reports_v4` 改名为 `test_health_reports_v5`，断言 `"4.0"`→`"5.0"`、`"4.0.0"`→`"5.0.0"`。

- [ ] **Step 4: 运行确认通过（全量）**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -v
```

预期输出：`Ran 215+ tests ... OK`。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/main.py ChartAgent/tests/test_mindmap_render_endpoint.py ChartAgent/tests/test_smartchart.py
git commit -m "feat(chart-agent): API v5.0 and POST /chart/render pure-render endpoint"
```

---

## Task 13: Swift DTO — MindMapDocDTO、响应 mindMap 字段、render 请求/响应模型

`ChartSkill.swift` 新增思维导图 DTO（`MindMapRootDTO`/`MindMapNodeDTO`/`MindMapBranchDTO`/`MindMapDocDTO`，`segment_ids` 蛇形映射）；`SmartChartGenerateResponse` 新增可选 `mindMap`；请求默认版本升 `"5.0"`；新增 `SmartChartRenderRequest`/`SmartChartRenderResponse`。注意 root 无 `segment_ids`（后端 extra="forbid"）。

**Files:**
- Modify: `AIRecording/Services/ChartSkill.swift`（第 84 行 `TranscriptSegmentDTO` 之后插入 Mind Map DTO 区；第 98 行默认版本；第 115-129 行响应 DTO 加字段；第 129 行后插入 render DTO）
- Test: `Tests/AIRecordingTests/SmartChartV5DTOTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

创建 `Tests/AIRecordingTests/SmartChartV5DTOTests.swift`：

```swift
import Foundation
import XCTest
@testable import AIRecording

final class SmartChartV5DTOTests: XCTestCase {
    private let mindMapJSON = """
    {
      "root": {"id": "root", "text": "周会纪要"},
      "branches": [
        {"id": "b0", "text": "议题一", "segment_ids": ["s1", "s2"],
         "children": [
           {"id": "b0c0", "text": "结论：当天完成", "segment_ids": ["s1"]},
           {"id": "b0c1", "text": "新要点", "segment_ids": []}
         ]}
      ]
    }
    """

    func testV5ResponseDecodesMindMap() throws {
        let json = """
        {
          "version": "5.0",
          "requestId": "r1",
          "status": "success",
          "contentType": "meeting",
          "contentTypeDisplayName": "会议",
          "chartType": "mind_map",
          "chartTypeDisplayName": "思维导图",
          "title": "周会纪要",
          "htmlFragment": "<div data-segment-ids=\\"s1\\">ok</div>",
          "mindMap": \(mindMapJSON),
          "plan": {},
          "errors": []
        }
        """
        let response = try JSONDecoder().decode(SmartChartGenerateResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.version, "5.0")
        XCTAssertEqual(response.chartType, "mind_map")
        let mindMap = try XCTUnwrap(response.mindMap)
        XCTAssertEqual(mindMap.root.text, "周会纪要")
        XCTAssertEqual(mindMap.branches.count, 1)
        XCTAssertEqual(mindMap.branches[0].segmentIds, ["s1", "s2"])
        XCTAssertEqual(mindMap.branches[0].children[1].id, "b0c1")
        XCTAssertEqual(mindMap.branches[0].children[1].segmentIds, [])
    }

    func testV5ResponseDecodesNullMindMapForHighlights() throws {
        let json = """
        {
          "version": "5.0",
          "requestId": "r1",
          "status": "success",
          "contentType": "other",
          "contentTypeDisplayName": "其他",
          "chartType": "highlights",
          "chartTypeDisplayName": "重点句子",
          "title": "重点句子",
          "htmlFragment": "<div data-segment-ids=\\"s1\\">ok</div>",
          "mindMap": null,
          "plan": {},
          "errors": []
        }
        """
        let response = try JSONDecoder().decode(SmartChartGenerateResponse.self, from: Data(json.utf8))
        XCTAssertNil(response.mindMap)
    }

    func testRenderRequestEncodesSnakeCaseSegmentIdsAndV5() throws {
        let doc = MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会纪要"),
            branches: [
                MindMapBranchDTO(id: "b0", text: "议题一", segmentIds: ["s1"], children: [
                    MindMapNodeDTO(id: "b0c0", text: "结论", segmentIds: ["s1"]),
                ]),
            ]
        )
        let request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: doc)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "5.0")
        let mindMap = try XCTUnwrap(json["mindMap"] as? [String: Any])
        let root = try XCTUnwrap(mindMap["root"] as? [String: Any])
        XCTAssertNil(root["segment_ids"], "root 不得携带 segment_ids（后端 extra=forbid）")
        let branches = try XCTUnwrap(mindMap["branches"] as? [[String: Any]])
        XCTAssertEqual(branches[0]["segment_ids"] as? [String], ["s1"])
        let children = try XCTUnwrap(branches[0]["children"] as? [[String: Any]])
        XCTAssertEqual(children[0]["segment_ids"] as? [String], ["s1"])
    }

    func testRenderResponseDecodes() throws {
        let json = """
        {"version": "5.0", "requestId": "r1", "status": "success",
         "htmlFragment": "<svg></svg>", "errorCode": null}
        """
        let response = try JSONDecoder().decode(SmartChartRenderResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.status, "success")
        XCTAssertEqual(response.htmlFragment, "<svg></svg>")
        XCTAssertNil(response.errorCode)
    }

    func testGenerateRequestDefaultsToV5() {
        let request = SmartChartGenerateRequest(
            recordingId: "rec-1",
            segments: [TranscriptSegmentDTO(id: "s1", speaker: "甲", startTime: 0, endTime: 1, text: "内容")]
        )
        XCTAssertEqual(request.version, "5.0")
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter SmartChartV5DTOTests
```

预期输出：编译错误 `cannot find 'MindMapDocDTO' in scope` 等。

- [ ] **Step 3: 最小实现**

修改 `AIRecording/Services/ChartSkill.swift`：

1. 在第 84 行 `TranscriptSegmentDTO` 定义之后插入：

```swift
// MARK: - Mind Map DTOs (v5)

/// 思维导图中心主题节点。无 segmentIds（后端 root 模型 extra="forbid"）。
struct MindMapRootDTO: Codable, Equatable {
    var id: String
    var text: String
}

/// 思维导图要点节点（二级）。
struct MindMapNodeDTO: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var segmentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, text
        case segmentIds = "segment_ids"
    }
}

/// 思维导图一级分支。
struct MindMapBranchDTO: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var segmentIds: [String]
    var children: [MindMapNodeDTO]

    enum CodingKeys: String, CodingKey {
        case id, text, children
        case segmentIds = "segment_ids"
    }
}

/// 思维导图结构数据：root（中心主题）+ branches（一级分支，各带要点）。
struct MindMapDocDTO: Codable, Equatable {
    var root: MindMapRootDTO
    var branches: [MindMapBranchDTO]
}
```

2. `SmartChartGenerateRequest` init 的默认版本（第 98 行）`version: String = "4.0"` 改为 `version: String = "5.0"`。
3. `SmartChartGenerateResponse`（第 115-129 行）在 `var htmlFragment: String` 之后插入：

```swift
    /// 思维导图结构数据；chartType == "mind_map" 时必带，highlights 兜底时为 nil。
    var mindMap: MindMapDocDTO?
```

4. 在 `SmartChartGenerateResponse` 定义之后插入：

```swift
/// POST /chart/render 请求：编辑后的思维导图确定性重渲染（无 LLM）。
struct SmartChartRenderRequest: Codable {
    var version: String = "5.0"
    var requestId: String = UUID().uuidString
    var recordingId: String
    var mindMap: MindMapDocDTO
    var theme: String = "darkCyberpunk"
}

/// POST /chart/render 响应。
struct SmartChartRenderResponse: Codable {
    var version: String
    var requestId: String
    var status: String
    var htmlFragment: String
    var errorCode: String?
}
```

- [ ] **Step 4: 运行确认通过**

```bash
swift test --filter SmartChartV5DTOTests
```

预期输出：`Test Suite 'SmartChartV5DTOTests' passed`（5 个用例）。

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Services/ChartSkill.swift Tests/AIRecordingTests/SmartChartV5DTOTests.swift
git commit -m "feat(chart): Swift DTOs for MindMapDoc, mindMap field and render request (v5)"
```

---

## Task 14: HTTPChartSkill.render + 版本门升 5.0.0

`HTTPChartSkill` 新增 `render(request:)`（POST /chart/render，15s 超时，仅 checkHealth 不拉起服务——编辑回路依附于已生成的会话）；`skillId`/`skillVersion` 升 v5。`ChartServiceManager.expectedServiceVersion` 升 `"5.0.0"`、`isSupportedHealth` 的 apiVersion 门升 `"5.0"`。同步升级既有版本门测试。

**Files:**
- Modify: `AIRecording/Services/HTTPChartSkill.swift`（第 6-7 行；第 107 行 `generate` 之后插入 `render`）
- Modify: `AIRecording/Services/ChartServiceManager.swift`（第 10 行 `expectedServiceVersion`；第 91 行 apiVersion 门）
- Modify: `Tests/AIRecordingTests/SmartChartTests.swift`（`testHealthRequiresV4Protocol`、`testSupportedHealthRequiresMatchingServiceVersion`、`healthV4JSON` 及各内联 health JSON 的版本字面量）

- [ ] **Step 1: 写失败测试（先加新用例，再改旧断言）**

在 `Tests/AIRecordingTests/SmartChartTests.swift` 的 `SmartChartTests` 类内追加：

```swift
    private let healthV5JSON = #"{"status":"ok","apiVersion":"5.0","serviceVersion":"5.0.0","llmConfigured":true}"#

    private func makeMindMapDoc() -> MindMapDocDTO {
        MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会纪要"),
            branches: [
                MindMapBranchDTO(id: "b0", text: "议题一", segmentIds: ["s1"], children: [
                    MindMapNodeDTO(id: "b0c0", text: "结论", segmentIds: ["s1"]),
                ]),
            ]
        )
    }

    func testRenderPostsToChartRenderEndpoint() async throws {
        var capturedBody: Data?
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(url: request.url!, json: self.healthV5JSON)
            }
            XCTAssertEqual(request.url?.path, "/chart/render")
            capturedBody = self.bodyData(from: request)
            return self.response(url: request.url!, json: """
                {"version":"5.0","requestId":"render-1","status":"success",
                 "htmlFragment":"<svg>mind</svg>","errorCode":null}
                """)
        }
        var request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: makeMindMapDoc())
        request.requestId = "render-1"
        let response = try await service.render(request: request)
        XCTAssertEqual(response.htmlFragment, "<svg>mind</svg>")
        let body = try XCTUnwrap(capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["version"] as? String, "5.0")
        XCTAssertNotNil(json["mindMap"])
    }

    func testRenderFailedStatusMapsToValidationFailed() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(url: request.url!, json: self.healthV5JSON)
            }
            return self.response(url: request.url!, json: """
                {"version":"5.0","requestId":"render-1","status":"failed",
                 "htmlFragment":"","errorCode":"INVALID_MINDMAP"}
                """)
        }
        var request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: makeMindMapDoc())
        request.requestId = "render-1"
        do {
            _ = try await service.render(request: request)
            XCTFail("Expected validationFailed")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .validationFailed("INVALID_MINDMAP"))
        }
    }

    func testRenderRejectsMismatchedRequestID() async throws {
        let service = makeService { request in
            if request.url?.path == "/health" {
                return self.response(url: request.url!, json: self.healthV5JSON)
            }
            return self.response(url: request.url!, json: """
                {"version":"5.0","requestId":"other-id","status":"success",
                 "htmlFragment":"<svg/>","errorCode":null}
                """)
        }
        var request = SmartChartRenderRequest(recordingId: "rec-1", mindMap: makeMindMapDoc())
        request.requestId = "render-1"
        do {
            _ = try await service.render(request: request)
            XCTFail("Expected invalidResponse")
        } catch let error as ChartSkillError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testHealthRequiresV5Protocol() async {
        let v4Service = makeService { request in
            self.response(url: request.url!, json: self.healthV4JSON)
        }
        XCTAssertFalse(await v4Service.checkHealth(), "v4 后端必须被版本自检驱逐")

        let v5Service = makeService { request in
            self.response(url: request.url!, json: self.healthV5JSON)
        }
        XCTAssertTrue(await v5Service.checkHealth())
    }
```

同时把 `healthV4JSON`（第 406 行）改为返回 v4 旧版（保持不变即可，它现在充当"应被驱逐的旧后端"夹具）；将 `testHealthRequiresV4Protocol`（第 12-41 行）与 `testSupportedHealthRequiresMatchingServiceVersion`（第 43-55 行）中的 v4 断言改为 v5（详见 Step 3 第 3 条）。

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter SmartChartTests
```

预期输出：编译错误 `value of type 'HTTPChartSkill' has no member 'render'`。

- [ ] **Step 3: 最小实现**

1. 修改 `AIRecording/Services/HTTPChartSkill.swift`：第 6-7 行改为 `let skillId = "chart.agent.v5"`、`let skillVersion = "5.0.0"`；在 `generate` 方法结束之后（第 107 行后）插入：

```swift
    /// 纯渲染接口（编辑回路专用）：只要求服务在线，不主动拉起服务、不走 LLM 链路。
    func render(request: SmartChartRenderRequest) async throws -> SmartChartRenderResponse {
        let available = await checkHealth()
        if !available {
            throw ChartSkillError.serviceNotRunning
        }

        let url = baseURL.appendingPathComponent("/chart/render")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 15

        do {
            urlRequest.httpBody = try JSONEncoder().encode(request)
        } catch {
            throw ChartSkillError.invalidRequest
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw ChartSkillError.timeout
        } catch {
            throw ChartSkillError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChartSkillError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ChartSkillError.generationFailed("HTTP \(httpResponse.statusCode)")
        }

        let result: SmartChartRenderResponse
        do {
            result = try JSONDecoder().decode(SmartChartRenderResponse.self, from: data)
        } catch {
            throw ChartSkillError.decodingFailed
        }
        guard result.requestId == request.requestId else {
            throw ChartSkillError.invalidResponse
        }
        if result.status == "failed" {
            if result.errorCode == "TIMEOUT" {
                throw ChartSkillError.timeout
            }
            throw ChartSkillError.validationFailed(result.errorCode ?? "RENDER_FAILED")
        }
        return result
    }
```

2. 修改 `AIRecording/Services/ChartServiceManager.swift`：第 10 行 `nonisolated static let expectedServiceVersion = "4.0.0"` 改为 `"5.0.0"`；第 91 行 `health.apiVersion == "4.0"` 改为 `health.apiVersion == "5.0"`；第 87 行注释中的 "v4 protocol" 改为 "v5 protocol"。
3. 修改 `Tests/AIRecordingTests/SmartChartTests.swift`：
   - `testHealthRequiresV4Protocol` 改名为 `testHealthRejectsStaleBackends`：v2 用例保持（仍应拒绝）；中间"同协议旧 build"用例的 JSON 改为 `#"{"status":"ok","apiVersion":"5.0","serviceVersion":"4.0.0","llmConfigured":true}"#`（同协议旧 build 仍拒绝）；最后健康用例的 JSON 改为 v5 字面量。
   - `testSupportedHealthRequiresMatchingServiceVersion`：`current` 改为 `ChartHealthInfo(status: "ok", apiVersion: "5.0", serviceVersion: "5.0.0")`；`stale` 改为 `serviceVersion: "4.0.0"`；`wrongProtocol` 保持 `"2.0"`；`down` 的 apiVersion 改 `"5.0"`。
   - `testFailedResponsePreservesGenerationError`、`testBackendTimeoutErrorCodeMapsToTimeout`、`testURLSessionTimedOutMapsToTimeout`、`testMismatchedResponseRequestIDThrowsInvalidResponse`、`testGenerateFiltersBlankSegmentsBeforeSending` 中内联的 health JSON 字符串里的 `"apiVersion":"4.0","serviceVersion":"4.0.0"` 全部改为 `"apiVersion":"5.0","serviceVersion":"5.0.0"`。
   - `healthV4JSON`（第 406 行）保持不变（作为"旧版后端"夹具被 `testHealthRequiresV5Protocol` 引用）。
   - `testResponseDecodesContentTypeFields`、`testForceContentTypeIsEncodedWhenSet`、`testForceContentTypeOmittedWhenNil` 三个用例中内联的 `Data(self.healthV4JSON.utf8)` 改为 `Data(self.healthV5JSON.utf8)`（健康门升级后 v4 响应会导致 `checkHealth` 失败）。
   - `successResponseJSON(requestId:)` 中 `"version": "4.0"` 改为 `"version": "5.0"`；`failedResponseJSON`、`timeoutFailedResponseJSON` 中 `"version":"4.0"` 改为 `"version":"5.0"`；`testForceContentTypeIsEncodedWhenSet` 的 `XCTAssertEqual(json?["version"] as? String, "4.0")` 改为 `"5.0"`。

- [ ] **Step 4: 运行确认通过**

```bash
swift test --filter SmartChartTests
```

预期输出：全部通过（含 4 个新增 render/版本门用例）。

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Services/HTTPChartSkill.swift AIRecording/Services/ChartServiceManager.swift Tests/AIRecordingTests/SmartChartTests.swift
git commit -m "feat(chart): HTTP render endpoint client and v5.0.0 version gate"
```

---

## Task 15: RecordingDetailViewModel — mindMapDoc 持有、编辑操作、300ms 防抖渲染

ViewModel 新增：`mindMapDoc`/`chartHtmlFragment`/`isRenderingMindMap`/`mindMapEditError` 状态；`applyChartResponse` 统一装配（生成与持久化恢复共用）；编辑操作（改 root/分支/要点文字、删分支/要点、分支末尾加要点；文字编辑后节点 `segmentIds` 置空）；`scheduleMindMapRender` 300ms 防抖 → `renderEditedMindMap`（走 `ChartRequestGate`、生成进行中不发起、失败保留旧预览）；`sanitizedForRender` 把空白文本替换为"未命名"（后端要求 text 非空）。渲染客户端经 `MindMapRendering` 协议注入便于测试。

**Files:**
- Modify: `AIRecording/Services/ChartSkill.swift`（文件末尾 `ChartRequestGate` 之后插入 `MindMapRendering` 协议）
- Modify: `AIRecording/Services/HTTPChartSkill.swift`（文件末尾追加 conformance extension）
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`（第 31-36 行状态区；第 44-45 行私有区；第 176-177 行持久化恢复；`generateChart` 第 314-352 行；`cleanup` 第 452-461 行；`generateChart` 之后插入思维导图编辑区）
- Test: `Tests/AIRecordingTests/MindMapEditingTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

创建 `Tests/AIRecordingTests/MindMapEditingTests.swift`：

```swift
import CoreData
import Foundation
import XCTest
@testable import AIRecording

final class StubMindMapRenderer: MindMapRendering {
    var requests: [SmartChartRenderRequest] = []
    var error: Error?

    func render(request: SmartChartRenderRequest) async throws -> SmartChartRenderResponse {
        requests.append(request)
        if let error { throw error }
        return SmartChartRenderResponse(
            version: "5.0",
            requestId: request.requestId,
            status: "success",
            htmlFragment: "<div data-segment-ids=\"\">rendered-\(requests.count)</div>",
            errorCode: nil
        )
    }
}

@MainActor
final class MindMapEditingTests: XCTestCase {
    private var stub: StubMindMapRenderer!

    override func setUp() {
        super.setUp()
        stub = StubMindMapRenderer()
    }

    private func makeViewModel() -> RecordingDetailViewModel {
        let controller = PersistenceController(inMemory: true)
        let recording = Recording(context: controller.container.viewContext)
        recording.id = UUID()
        let viewModel = RecordingDetailViewModel(objectID: recording.objectID)
        viewModel.mindMapRenderer = stub
        return viewModel
    }

    private var sampleDoc: MindMapDocDTO {
        MindMapDocDTO(
            root: MindMapRootDTO(id: "root", text: "周会"),
            branches: [
                MindMapBranchDTO(id: "b0", text: "议题一", segmentIds: ["s1"], children: [
                    MindMapNodeDTO(id: "b0c0", text: "结论一", segmentIds: ["s1"]),
                ]),
                MindMapBranchDTO(id: "b1", text: "议题二", segmentIds: ["s2"], children: []),
            ]
        )
    }

    func testUpdateRootTextChangesDoc() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateRootText("新的中心主题")
        XCTAssertEqual(viewModel.mindMapDoc?.root.text, "新的中心主题")
    }

    func testUpdateBranchTextClearsSegmentIds() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改过的议题")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].text, "改过的议题")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].segmentIds, [])
    }

    func testUpdateChildTextClearsSegmentIds() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateChildText(branchId: "b0", childId: "b0c0", text: "改过的结论")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children[0].text, "改过的结论")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children[0].segmentIds, [])
        // 未编辑的兄弟节点不受影响
        XCTAssertEqual(viewModel.mindMapDoc?.branches[1].segmentIds, ["s2"])
    }

    func testDeleteBranchRemovesIt() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.deleteBranch(branchId: "b0")
        XCTAssertEqual(viewModel.mindMapDoc?.branches.map(\.id), ["b1"])
    }

    func testDeleteChildRemovesIt() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.deleteChild(branchId: "b0", childId: "b0c0")
        XCTAssertEqual(viewModel.mindMapDoc?.branches[0].children, [])
    }

    func testAddChildAppendsSequentialIdWithEmptySegmentIds() {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.addChild(branchId: "b0")
        viewModel.addChild(branchId: "b0")
        let children = viewModel.mindMapDoc?.branches[0].children ?? []
        XCTAssertEqual(children.map(\.id), ["b0c0", "b0c1", "b0c2"])
        XCTAssertEqual(children[1].segmentIds, [])
        XCTAssertEqual(children[2].text, "新要点")
    }

    func testDebounceMergesRapidEditsIntoOneRender() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改 1")
        viewModel.updateBranchText(branchId: "b0", text: "改 2")
        viewModel.addChild(branchId: "b1")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(stub.requests.count, 1, "300ms 内的连续编辑必须合并为一次 render 请求")
        XCTAssertEqual(viewModel.chartHtmlFragment, "<div data-segment-ids=\"\">rendered-1</div>")
        viewModel.cleanup()
    }

    func testRenderSkippedWhileGenerating() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.isGeneratingChart = true
        await viewModel.renderEditedMindMap()
        XCTAssertEqual(stub.requests.count, 0)
        viewModel.cleanup()
    }

    func testFailedRenderKeepsPreviewAndSetsError() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.chartHtmlFragment = "<div data-segment-ids=\"\">old</div>"
        stub.error = ChartSkillError.serviceNotRunning
        await viewModel.renderEditedMindMap()
        XCTAssertEqual(viewModel.chartHtmlFragment, "<div data-segment-ids=\"\">old</div>", "失败必须保留上一版预览")
        XCTAssertEqual(viewModel.mindMapEditError, "预览刷新失败，请重试")
        XCTAssertNotNil(viewModel.mindMapDoc, "失败不得丢弃大纲内容")
        viewModel.cleanup()
    }

    func testSanitizedForRenderReplacesBlankText() {
        let viewModel = makeViewModel()
        var doc = sampleDoc
        doc.branches[0].text = "   "
        let sanitized = viewModel.sanitizedForRender(doc)
        XCTAssertEqual(sanitized.branches[0].text, "未命名")
        XCTAssertEqual(sanitized.branches[0].children[0].text, "结论一")
    }

    func testCleanupCancelsPendingRender() async throws {
        let viewModel = makeViewModel()
        viewModel.mindMapDoc = sampleDoc
        viewModel.updateBranchText(branchId: "b0", text: "改")
        viewModel.cleanup()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(stub.requests.count, 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter MindMapEditingTests
```

预期输出：编译错误 `cannot find type 'MindMapRendering' in scope`、`value of type 'RecordingDetailViewModel' has no member 'mindMapDoc'` 等。

- [ ] **Step 3: 最小实现**

1. 修改 `AIRecording/Services/ChartSkill.swift`，在 `ChartRequestGate` 类之后（文件末尾）追加：

```swift
// MARK: - Mind Map Rendering (v5)

/// /chart/render 纯渲染客户端抽象，便于 ViewModel 在测试中注入桩实现。
protocol MindMapRendering {
    func render(request: SmartChartRenderRequest) async throws -> SmartChartRenderResponse
}
```

2. 修改 `AIRecording/Services/HTTPChartSkill.swift`，在文件末尾追加：

```swift
extension HTTPChartSkill: MindMapRendering {}
```

3. 修改 `AIRecording/ViewModels/RecordingDetailViewModel.swift`：
   - 状态区（第 33 行 `@Published var chartError: String?` 之后）插入：

```swift
    @Published var mindMapDoc: MindMapDocDTO?
    @Published var chartHtmlFragment: String?
    @Published var isRenderingMindMap = false
    @Published var mindMapEditError: String?
```

   - 私有区（第 44 行 `private var chartTask: Task<Void, Never>?` 之后）插入：

```swift
    private var renderTask: Task<Void, Never>?
    /// /chart/render 客户端（测试注入桩实现）。
    var mindMapRenderer: any MindMapRendering = HTTPChartSkill.shared
```

   - 持久化恢复（第 176-177 行）将 `chartResult = restored` 替换为 `applyChartResponse(restored)`。
   - `generateChart`：第 315 行 `chartTask?.cancel()` 之后插入 `renderTask?.cancel()` 与 `renderTask = nil`（两行）；第 319 行 `chartError = nil` 之后插入：

```swift
        // 重新生成丢弃未导出的编辑，以新响应为准（设计文档 §8）
        mindMapDoc = nil
        chartHtmlFragment = nil
        mindMapEditError = nil
```

   - `generateChart` 内第 346 行 `chartResult = response` 替换为 `applyChartResponse(response)`。
   - `cleanup()`（第 452-461 行）在 `chartTask = nil` 之后插入 `renderTask?.cancel()` 与 `renderTask = nil`。
   - 在 `generateChart` 方法结束之后（第 367 行后）插入思维导图编辑区：

```swift
    // MARK: - Mind Map Editing (v5)

    private func applyChartResponse(_ response: SmartChartGenerateResponse) {
        chartResult = response
        chartHtmlFragment = response.htmlFragment
        mindMapDoc = response.mindMap
        mindMapEditError = nil
    }

    func updateRootText(_ text: String) {
        guard mindMapDoc != nil else { return }
        mindMapDoc?.root.text = text
        scheduleMindMapRender()
    }

    /// 文字编辑使节点脱离原文依据：segmentIds 置空，点图不再跳音频（设计文档 §4）。
    func updateBranchText(branchId: String, text: String) {
        guard let index = mindMapDoc?.branches.firstIndex(where: { $0.id == branchId }) else { return }
        mindMapDoc?.branches[index].text = text
        mindMapDoc?.branches[index].segmentIds = []
        scheduleMindMapRender()
    }

    func updateChildText(branchId: String, childId: String, text: String) {
        guard let branchIndex = mindMapDoc?.branches.firstIndex(where: { $0.id == branchId }),
              let childIndex = mindMapDoc?.branches[branchIndex].children.firstIndex(where: { $0.id == childId })
        else { return }
        mindMapDoc?.branches[branchIndex].children[childIndex].text = text
        mindMapDoc?.branches[branchIndex].children[childIndex].segmentIds = []
        scheduleMindMapRender()
    }

    func deleteBranch(branchId: String) {
        guard var doc = mindMapDoc,
              let index = doc.branches.firstIndex(where: { $0.id == branchId }) else { return }
        doc.branches.remove(at: index)
        mindMapDoc = doc
        scheduleMindMapRender()
    }

    func deleteChild(branchId: String, childId: String) {
        guard var doc = mindMapDoc,
              let branchIndex = doc.branches.firstIndex(where: { $0.id == branchId }),
              let childIndex = doc.branches[branchIndex].children.firstIndex(where: { $0.id == childId })
        else { return }
        doc.branches[branchIndex].children.remove(at: childIndex)
        mindMapDoc = doc
        scheduleMindMapRender()
    }

    /// 只能在分支末尾新增要点；新节点 segmentIds 为空（无原文依据）。
    func addChild(branchId: String) {
        guard var doc = mindMapDoc,
              let index = doc.branches.firstIndex(where: { $0.id == branchId }) else { return }
        let childId = "\(branchId)c\(doc.branches[index].children.count)"
        doc.branches[index].children.append(MindMapNodeDTO(id: childId, text: "新要点", segmentIds: []))
        mindMapDoc = doc
        scheduleMindMapRender()
    }

    /// 300ms 防抖：连续编辑合并为一次 /chart/render 请求。
    private func scheduleMindMapRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderEditedMindMap()
        }
    }

    /// 调 /chart/render 重渲染编辑后的 doc；走 ChartRequestGate 防旧响应覆盖；
    /// 生成进行中不发起；失败保留上一版预览，大纲内容不丢（设计文档 §7.4）。
    func renderEditedMindMap() async {
        guard let doc = mindMapDoc, !isGeneratingChart else { return }
        let token = chartGate.begin()
        let request = SmartChartRenderRequest(
            recordingId: recording?.id?.uuidString ?? objectID.uriRepresentation().absoluteString,
            mindMap: sanitizedForRender(doc)
        )
        isRenderingMindMap = true
        do {
            let response = try await mindMapRenderer.render(request: request)
            isRenderingMindMap = false
            guard chartGate.isCurrent(token), !Task.isCancelled else { return }
            chartHtmlFragment = response.htmlFragment
            mindMapEditError = nil
        } catch {
            isRenderingMindMap = false
            guard chartGate.isCurrent(token) else { return }
            mindMapEditError = "预览刷新失败，请重试"
            AppLogger.log(.warning, category: "chart", event: "mindmap_render_failed",
                          recordingId: recording?.id?.uuidString,
                          metadata: ["errorType": String(describing: type(of: error))])
        }
    }

    /// 发送前把空白文本替换为占位文字（后端 schema 要求 text 非空）；本地编辑内容不变。
    func sanitizedForRender(_ doc: MindMapDocDTO) -> MindMapDocDTO {
        func clean(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "未命名" : trimmed
        }
        return MindMapDocDTO(
            root: MindMapRootDTO(id: doc.root.id, text: clean(doc.root.text)),
            branches: doc.branches.map { branch in
                MindMapBranchDTO(
                    id: branch.id,
                    text: clean(branch.text),
                    segmentIds: branch.segmentIds,
                    children: branch.children.map {
                        MindMapNodeDTO(id: $0.id, text: clean($0.text), segmentIds: $0.segmentIds)
                    }
                )
            }
        )
    }
```

- [ ] **Step 4: 运行确认通过**

```bash
swift test --filter MindMapEditingTests
```

预期输出：`Test Suite 'MindMapEditingTests' passed`（11 个用例）。

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Services/ChartSkill.swift AIRecording/Services/HTTPChartSkill.swift AIRecording/ViewModels/RecordingDetailViewModel.swift Tests/AIRecordingTests/MindMapEditingTests.swift
git commit -m "feat(chart): outline editing state with 300ms debounced re-render"
```

---

## Task 16: 大纲编辑 UI + 图表面板重写

`RecordingDetailView.swift`：头部抽出 `chartHeaderView`（类型标签"会议 · 思维导图"、重新生成按钮与类型菜单不变、刷新中指示、编辑错误提示）；预览改用 `viewModel.chartHtmlFragment`；`mindMapDoc != nil` 时下方显示原生大纲编辑区（root 一行 + 分支行 + 要点行缩进 + 行尾悬停删除 + 分支末尾"+ 添加要点"）。新增 `MindMapOutlineRow` 组件。无拖拽、无层级调整。

**Files:**
- Modify: `AIRecording/Views/RecordingDetailView.swift`（`chartPanelView` 第 424-509 行整体替换；文件末尾 `TranscriptionParagraphRow` 之前插入 `MindMapOutlineRow`）

- [ ] **Step 1: 基线构建确认**

```bash
swift build
```

预期输出：`Build complete!`（Task 15 完成后当前代码可编译，VM 已带新接口但 UI 未接）。

- [ ] **Step 2: 最小实现**

1. 将 `chartPanelView`（第 424-509 行）整体替换为：

```swift
    @ViewBuilder
    private var chartHeaderView: some View {
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
            } else if viewModel.isRenderingMindMap {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("刷新中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let chart = viewModel.chartResult {
                HStack(spacing: 8) {
                    Text("\(chart.contentTypeDisplayName) · \(chart.chartTypeDisplayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let editError = viewModel.mindMapEditError {
                        Text(editError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("重新生成") {
                        viewModel.generateChart()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                }
            }
        }
    }

    @ViewBuilder
    private var mindMapOutlineSection: some View {
        if let doc = viewModel.mindMapDoc {
            VStack(alignment: .leading, spacing: 4) {
                Text("大纲编辑")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                MindMapOutlineRow(
                    text: Binding(
                        get: { doc.root.text },
                        set: { viewModel.updateRootText($0) }
                    ),
                    indent: 0,
                    showsDelete: false,
                    onDelete: {}
                )
                ForEach(doc.branches) { branch in
                    MindMapOutlineRow(
                        text: Binding(
                            get: { branch.text },
                            set: { viewModel.updateBranchText(branchId: branch.id, text: $0) }
                        ),
                        indent: 1,
                        showsDelete: true,
                        onDelete: { viewModel.deleteBranch(branchId: branch.id) }
                    )
                    ForEach(branch.children) { child in
                        MindMapOutlineRow(
                            text: Binding(
                                get: { child.text },
                                set: { viewModel.updateChildText(branchId: branch.id, childId: child.id, text: $0) }
                            ),
                            indent: 2,
                            showsDelete: true,
                            onDelete: { viewModel.deleteChild(branchId: branch.id, childId: child.id) }
                        )
                    }
                    Button("+ 添加要点") {
                        viewModel.addChild(branchId: branch.id)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                }
            }
            .padding(12)
            .background(Color(hex: "#16162A"))
            .cornerRadius(12)
        }
    }

    @ViewBuilder
    private var chartPanelView: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartHeaderView

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
            } else if viewModel.chartResult != nil {
                ChartWebView(
                    htmlContent: viewModel.chartHtmlFragment ?? "",
                    onSegmentTap: { segmentIds in
                        viewModel.seekToEarliestSegment(segmentIds)
                    }
                )
                .frame(minHeight: 400)
                .background(Color(hex: "#0F0F1A"))
                .cornerRadius(12)

                mindMapOutlineSection
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

2. 在文件末尾 `struct TranscriptionParagraphRow: View` 之前插入：

```swift
/// 大纲编辑行：缩进 + TextField + 行尾悬停删除。无拖拽、无层级调整（设计文档 §8）。
struct MindMapOutlineRow: View {
    @Binding var text: String
    let indent: Int
    let showsDelete: Bool
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(indent == 0 ? .headline : (indent == 1 ? .body : .callout))
            if showsDelete && isHovering {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, CGFloat(indent * 24))
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
```

- [ ] **Step 3: 构建 + 全量 Swift 测试确认通过**

```bash
swift build && swift test
```

预期输出：`Build complete!`，测试全部通过。

- [ ] **Step 4: 人工验证清单（运行 App）**

- 生成一张会议类图表：头部显示"会议 · 思维导图"，预览为左右展开的思维导图，下方出现大纲编辑区。
- 在大纲里改一个分支文字：约 300ms 后预览刷新；改过的节点点击不再跳音频。
- 删除一个要点、在某个分支末尾"+ 添加要点"：预览同步刷新。
- 断开后端（kill 8765 端口进程后编辑）：预览保留上一版，头部出现"预览刷新失败，请重试"。

- [ ] **Step 5: Commit**

```bash
git add AIRecording/Views/RecordingDetailView.swift
git commit -m "feat(chart): outline editing UI below mind map preview"
```

---

## Task 17: PNG 导出

`ChartWebView` 注册当前 WKWebView（弱引用）供快照；新文件 `MindMapPNGExporter.swift`：`snapshotFullPage`（读 `document.documentElement.scrollWidth/Height` → `WKSnapshotConfiguration` 全内容 rect → `takeSnapshot`）、`pngData(from:)`（纯函数）、`defaultFileName`（`<录音标题>-思维导图.png`，剔除文件系统非法字符）；VM 新增 `exportMindMapPNG`（NSSavePanel 写盘）；头部加"导出 PNG"按钮（`mindMapDoc == nil` 时禁用）。

**Files:**
- Modify: `AIRecording/Views/ChartWebView.swift`（第 4-7 行结构体头部；`makeNSView` 第 24-27 行）
- Create: `AIRecording/Views/MindMapPNGExporter.swift`
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`（思维导图编辑区末尾追加 `exportMindMapPNG`）
- Modify: `AIRecording/Views/RecordingDetailView.swift`（`chartHeaderView` 的 Menu 之后加导出按钮）
- Test: `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`（新建）

- [ ] **Step 1: 写失败测试**

创建 `Tests/AIRecordingTests/MindMapPNGExporterTests.swift`：

```swift
import AppKit
import XCTest
@testable import AIRecording

final class MindMapPNGExporterTests: XCTestCase {
    func testPNGDataFromImageIsNonEmpty() {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()

        let data = MindMapPNGExporter.pngData(from: image)
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data?.count ?? 0, 0)
        // PNG 魔数
        XCTAssertEqual(data?.prefix(8).count, 8)
        XCTAssertEqual(data?.first, 0x89)
    }

    func testPNGDataWritableToTempFile() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(MindMapPNGExporter.pngData(from: image))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(NSImage(contentsOf: url))
    }

    func testDefaultFileNameSanitizesIllegalCharacters() {
        XCTAssertEqual(
            MindMapPNGExporter.defaultFileName(recordingTitle: "周会/复盘: 9月"),
            "周会 复盘  9月-思维导图.png"
        )
        XCTAssertEqual(MindMapPNGExporter.defaultFileName(recordingTitle: "   "), "录音-思维导图.png")
        XCTAssertEqual(MindMapPNGExporter.defaultFileName(recordingTitle: "常规标题"), "常规标题-思维导图.png")
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter MindMapPNGExporterTests
```

预期输出：编译错误 `cannot find 'MindMapPNGExporter' in scope`。

- [ ] **Step 3: 最小实现**

1. 修改 `AIRecording/Views/ChartWebView.swift`：结构体头部（第 4-7 行）改为：

```swift
struct ChartWebView: NSViewRepresentable {
    let htmlContent: String
    var onSegmentTap: (([String]) -> Void)?

    /// 最近一次创建的 WebView（PNG 全尺寸快照的源）；弱引用，面板销毁后自动失效。
    static weak var currentWebView: WKWebView?
```

   `makeNSView` 中 `let webView = WKWebView(frame: .zero, configuration: configuration)` 之后插入一行 `Self.currentWebView = webView`。

2. 创建 `AIRecording/Views/MindMapPNGExporter.swift`：

```swift
import AppKit
import WebKit

/// 思维导图 PNG 导出：对图表 WebView 做完整内容尺寸快照（含滚动区外的全图）。
enum MindMapPNGExporter {
    /// 读页面实际内容尺寸，按完整 rect 快照，返回 NSImage。
    /// evaluateJavaScript 与 WKUserScript 同属应用侧注入，不受页面 CSP script-src 'none' 限制。
    static func snapshotFullPage(of webView: WKWebView) async throws -> NSImage {
        let contentSize: CGSize = try await withCheckedThrowingContinuation { continuation in
            let script = "({width: Math.ceil(document.documentElement.scrollWidth),"
                + " height: Math.ceil(document.documentElement.scrollHeight)})"
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let dict = result as? [String: Any],
                          let width = dict["width"] as? CGFloat,
                          let height = dict["height"] as? CGFloat,
                          width > 0, height > 0 {
                    continuation.resume(returning: CGSize(width: width, height: height))
                } else {
                    continuation.resume(throwing: ChartSkillError.invalidResponse)
                }
            }
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: contentSize)
        return try await webView.takeSnapshot(configuration: configuration)
    }

    /// NSImage → PNG 数据（纯函数，可单测）。
    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 导出默认文件名："<录音标题>-思维导图.png"，剔除文件系统非法字符。
    static func defaultFileName(recordingTitle: String) -> String {
        let cleaned = recordingTitle
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "录音" : cleaned
        return "\(base)-思维导图.png"
    }
}
```

3. 修改 `AIRecording/ViewModels/RecordingDetailViewModel.swift`，在思维导图编辑区末尾（`sanitizedForRender` 之后）追加：

```swift
    /// 导出当前编辑结果对应预览的完整全图为 PNG（NSSavePanel 写盘）。
    func exportMindMapPNG() {
        guard mindMapDoc != nil, let recording else { return }
        guard let webView = ChartWebView.currentWebView else {
            mindMapEditError = "图表尚未渲染完成，无法导出"
            return
        }
        Task {
            do {
                let image = try await MindMapPNGExporter.snapshotFullPage(of: webView)
                guard let pngData = MindMapPNGExporter.pngData(from: image) else {
                    throw ChartSkillError.invalidResponse
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = MindMapPNGExporter.defaultFileName(
                    recordingTitle: recording.displayTitle
                )
                panel.canCreateDirectories = true
                let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
                guard response == .OK, let url = panel.url else { return }
                try pngData.write(to: url, options: .atomic)
                AppLogger.log(.info, category: "chart", event: "mindmap_png_exported",
                              recordingId: recording.id?.uuidString)
            } catch {
                mindMapEditError = "导出失败，请重试"
                AppLogger.log(.error, category: "chart", event: "mindmap_png_export_failed",
                              recordingId: recording.id?.uuidString,
                              metadata: ["errorType": String(describing: type(of: error))])
            }
        }
    }
```

4. 修改 `AIRecording/Views/RecordingDetailView.swift`：在 `chartHeaderView` 的 `Menu { ... }.fixedSize()` 之后追加：

```swift
                    Button("导出 PNG") {
                        viewModel.exportMindMapPNG()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.mindMapDoc == nil)
```

- [ ] **Step 4: 运行确认通过**

```bash
swift build && swift test --filter MindMapPNGExporterTests
```

预期输出：`Build complete!`，3 个用例通过。

- [ ] **Step 5: 人工验证 + Commit**

运行 App，生成思维导图后点"导出 PNG"：NSSavePanel 默认文件名 `<录音标题>-思维导图.png`；保存后用预览打开图片，确认是**完整全图**（含滚动区外内容）、深色背景、文字清晰。然后：

```bash
git add AIRecording/Views/ChartWebView.swift AIRecording/Views/MindMapPNGExporter.swift AIRecording/ViewModels/RecordingDetailViewModel.swift AIRecording/Views/RecordingDetailView.swift Tests/AIRecordingTests/MindMapPNGExporterTests.swift
git commit -m "feat(chart): export mind map preview as full-size PNG"
```

---

## Task 18: 端到端收尾 — 全量测试、文档同步、迁移确认

**Files:**
- Modify: `ChartAgent/README.md`（第 1-9 行的服务描述改为 v5）
- Modify: `AGENTS.md`（Design docs 一节补充 v5 设计文档与本计划）
- Modify: `docs/superpowers/specs/2026-07-22-smartchart-mindmap-editable-design.md`（状态行：已确认设计（待实施）→ 已实施）

- [ ] **Step 1: 全量 Python 测试**

```bash
cd ChartAgent && PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -v
```

预期输出：`Ran 215+ tests ... OK`。

- [ ] **Step 2: 全量 Swift 测试**

```bash
swift build && swift test
```

预期输出：`Build complete!`，全部测试套件通过（SmartChartTests、SmartChartV5DTOTests、MindMapEditingTests、MindMapPNGExporterTests、ChartPersistenceTests 等）。

- [ ] **Step 3: 文档同步**

1. `ChartAgent/README.md` 第 1-9 行改为：

```markdown
# ChartAgent

AIRecording 的智能图表服务（v5）：六种内容类型（会议/访谈/讲座/对话/演讲/随手记）统一渲染为思维导图，`other` 走重点句子兜底。使用 FastAPI、LangGraph、Pydantic 和 Jinja2。

## 工作方式

1. 内容分类器（1 次 LLM 调用）把录音判定为七种内容类型之一；置信度不足或失败归"其他"。
2. 六种类型由 `agent/skills/` 下的专属 skill 分块并行提取 → 合并 → 溯源校验 → 一次修复，随后由 `to_mindmap(plan)` 归一化为统一的 MindMapDoc（root → branches → children），`agent/mindmap.py` 的 MindMapRenderer 确定性渲染为 HTML + 内联 SVG（无 JavaScript）。
3. 响应同时携带 `mindMap` 结构数据；App 端大纲编辑后调 `POST /chart/render`（纯渲染、无 LLM、10s 预算）刷新预览。
4. 任何环节失败都沿"类型内兜底 → 重点句子"降级，保证任何录音都有输出；请求带 `forceContentType` 时跳过分类器。
```

2. `AGENTS.md` 的 Design docs 一节，在 v4 设计文档条目之后追加一行：

```markdown
- `docs/superpowers/specs/2026-07-22-smartchart-mindmap-editable-design.md` — 智能图表 v5（统一思维导图 + 大纲编辑 + PNG 导出，实施计划见 `docs/superpowers/plans/2026-07-22-smartchart-mindmap-editable.md`）
```

3. `docs/superpowers/specs/2026-07-22-smartchart-mindmap-editable-design.md` 第 4 行 `- 状态：已确认设计（待实施）` 改为 `- 状态：已实施`。

- [ ] **Step 4: 迁移确认（设计 §10）**

- 无数据迁移：图表按需生成，MindMapDoc 随响应内存持有；既有 `ChartPersistence` 行为不变。
- 版本自检驱逐：`expectedServiceVersion = "5.0.0"` + apiVersion 门 `"5.0"`，旧 v4 后端进程被 `ensureServiceRunning` 自动 SIGTERM 替换（`testHealthRequiresV5Protocol` 覆盖）。
- v4 六种模板已随 Task 3-8 退役；highlights 渲染器保留（`OtherSkillTests` 全绿）。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/README.md AGENTS.md docs/superpowers/specs/2026-07-22-smartchart-mindmap-editable-design.md
git commit -m "docs: mark smartchart v5 implemented, sync README and AGENTS"
```
