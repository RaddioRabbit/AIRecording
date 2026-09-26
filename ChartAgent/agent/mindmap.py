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
MAX_CHILDREN_PER_BRANCH = 10
MAX_BRANCH_TEXT_LENGTH = 28
MAX_CHILD_TEXT_LENGTH = 80

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

# 左右两侧要点列每行可容纳字符数与最大行数：block_height 与 lay_branch 共用，
# 每行字符数和行数上限都必须保持一致，否则块高与推进公式失配、要点重叠
LEFT_CHILD_CHARS_PER_LINE = 15
RIGHT_CHILD_CHARS_PER_LINE = 19
MAX_CHILD_LINES = 6

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

_JINJA_ENV = Environment(loader=DictLoader({"base.html.j2": BASE_TEMPLATE, "mindmap.html.j2": _TEMPLATE}), autoescape=True)


def _truncate(text: Any, limit: int) -> str:
    cleaned = " ".join(str(text).split())
    return cleaned if len(cleaned) <= limit else cleaned[:limit] + "…"


def guard_mindmap_doc(doc: Dict[str, Any]) -> Dict[str, Any]:
    """规模守卫（确定性）：分支 ≤8；每分支要点 ≤10，超出截断并在末尾加"还有 N 项"节点；
    分支文本 >28 字、要点 >80 字截断加省略号；要点 id 按路径式重建（b{i}c{j}）。
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
            _child_height(_wrap_text(str(c.get("text", "")), chars, MAX_CHILD_LINES)) + CHILD_GAP for c in children
        )
        return max(MIN_BRANCH_BLOCK_HEIGHT, total)

    left_blocks = [block_height(b, LEFT_CHILD_CHARS_PER_LINE) for b in left_branches]
    right_blocks = [block_height(b, RIGHT_CHILD_CHARS_PER_LINE) for b in right_branches]
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
                child_x, child_w, chars = CHILD_COLUMN_X_RIGHT, CHILD_WIDTH_RIGHT, RIGHT_CHILD_CHARS_PER_LINE
            else:
                child_x = BRANCH_COLUMN_X_LEFT + CHILD_INDENT_LEFT
                child_w = BRANCH_WIDTH_LEFT - CHILD_INDENT_LEFT
                chars = LEFT_CHILD_CHARS_PER_LINE
            child_lines = _wrap_text(str(child.get("text", "")), chars, MAX_CHILD_LINES)
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
        return _JINJA_ENV.get_template("mindmap.html.j2").render(
            layout=layout,
            plan=plan_context,
            theme=theme,
            title=title or guarded["root"]["text"],
            kind_display_name="思维导图",
            dark_css=DARK_CSS,
        )
