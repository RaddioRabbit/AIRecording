"""memo skill：随手记 → 灵感要点卡。一句话核心想法 + 要点列表（≤8 条）。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..mindmap import MAX_BRANCHES
from ..schema import StrictModel
from ..textutils import (
    filter_known_segment_ids,
    normalize_text,
    numbers_have_evidence,
)
from .base import BaseSkill

MAX_POINTS = 8

_PROMPT = """你是随手记内容提炼器。这是一段单人即兴语音记录（口播/语音备忘）。请提炼：
1. coreIdea：整段记录的核心想法，一句话，不超过 40 字，必须忠实于原文。
2. coreSegmentIds：核心想法来源的片段 id 列表（只用输入片段中的 id）。
3. points：支撑要点列表，每条包含 text（要点，不超过 28 字）与 detail（一句展开说明，不超过 60 字，原文没有更多展开时为 null），必须来自原文明确表述，并携带来源 segmentIds。
禁止编造原文没有的内容；segmentIds 只能使用输入片段中的 id。
覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
只输出严格 JSON：
{"chartType":"idea_card","title":"随手记要点","coreIdea":"...","coreSegmentIds":["..."],"points":[{"text":"...","detail":null,"segmentIds":["..."]}]}
输入片段：
"""


class _Point(StrictModel):
    text: str = Field(min_length=1)
    detail: Optional[str] = None
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
                points.append({
                    "text": point.text[:28],
                    "detail": point.detail[:60] if point.detail else None,
                    "segmentIds": ids,
                })
        # 核心想法的来源：LLM 给的 coreSegmentIds → 否则要点 id 并集 → 否则首片段（保证渲染可溯源）
        core_ids = filter_known_segment_ids(model.coreSegmentIds, segment_map)
        if not core_ids:
            core_ids = list(dict.fromkeys(sid for point in points for sid in point["segmentIds"]))
        if not core_ids and source_segments:
            core_ids = [source_segments[0]["id"]]
        return {
            "chartType": "idea_card",
            "title": model.title,
            "coreIdea": model.coreIdea[:40],
            "coreSegmentIds": core_ids,
            "points": points,
            "truncatedCount": 0,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "随手记要点")
        core_idea = next((p["coreIdea"] for p in plans if p.get("coreIdea")), "")
        core_ids = next((p.get("coreSegmentIds") for p in plans if p.get("coreSegmentIds")), [])
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
                continue
            if not numbers_have_evidence(point["text"], ids, segment_map):
                errors.append(f"要点{index + 1}数字与原文不符")
            if point.get("detail") and not numbers_have_evidence(point["detail"], ids, segment_map):
                errors.append(f"要点{index + 1}说明数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        if not plan.get("coreIdea"):
            return None
        if not numbers_have_evidence(plan["coreIdea"], plan.get("coreSegmentIds") or [], segment_map):
            return None
        points = []
        for p in plan.get("points", []):
            ids = filter_known_segment_ids(p.get("segmentIds"), segment_map)
            if not ids or not numbers_have_evidence(p["text"], ids, segment_map):
                continue
            detail = p.get("detail")
            if detail and not numbers_have_evidence(detail, ids, segment_map):
                detail = None
            points.append({**p, "detail": detail, "segmentIds": ids})
        return {**plan, "points": points, "truncatedCount": 0}

    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        core_idea = str(plan.get("coreIdea", "")).strip()
        if not core_idea:
            return None
        branches = []
        for index, point in enumerate(plan.get("points", [])[:MAX_BRANCHES]):
            branch = self.make_mindmap_node(index, point.get("text", ""), point.get("segmentIds", []))
            if point.get("detail"):
                branch["children"] = [
                    self.make_mindmap_node(index, point["detail"], point.get("segmentIds", []), 0)
                ]
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": core_idea}, "branches": branches}
