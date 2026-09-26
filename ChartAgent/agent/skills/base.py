"""skill 基类与共享逻辑。

每个 skill 负责一种内容类型的图表：提取提示词 → plan 归一化 → 合并 → 校验 → 兜底 → 渲染。
贯穿纪律（设计文档 §6.1）：LLM 只产 JSON；每条内容必须绑定真实 segment_ids；
金句类字段逐字校验；提炼类字段数字一致性校验；SVG 几何由 Python 计算。
"""
import json
from typing import Any, Dict, List, Optional

from ..mindmap import MAX_BRANCH_TEXT_LENGTH, MAX_CHILD_TEXT_LENGTH

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
        """分支 >28 字、要点 >80 字截断加省略号；折叠连续空白。"""
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
