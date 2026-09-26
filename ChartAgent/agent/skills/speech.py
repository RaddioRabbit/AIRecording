"""speech skill：演讲 → 叙事弧线图。固定四段结构（开场/铺垫/高潮/收尾）映射到固定弧线。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence, text_has_evidence
from .base import BaseSkill

_PROMPT = """你是演讲内容结构化提取器。把演讲转写映射到四段叙事结构。
要求：
1. stages：按 opening（开场）、buildup（铺垫）、climax（高潮）、closing（收尾）四段提取；每段 label（小标题，≤14字）、summary（这一段讲了什么，≤60字）、points（该段要点，1-5 条，每条 ≤60字，忠于原文）、segmentIds。
2. climax 段必须附 quote：演讲中最有感染力的原句（逐字，≤40字）。
3. 若某段在片段中找不到依据则省略该段，但 climax 不可省略。
4. 覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
只输出严格 JSON：
{"chartType":"narrative_arc","title":"<演讲主题，≤20字>","stages":[{"stage":"opening","label":"...","summary":"...","points":["..."],"quote":null,"segmentIds":["..."]}]}
输入片段：
"""

MAX_POINTS_PER_STAGE = 5

_STAGE_ORDER = ["opening", "buildup", "climax", "closing"]
_STAGE_LABELS = {"opening": "开场", "buildup": "铺垫", "climax": "高潮", "closing": "收尾"}


class _Stage(StrictModel):
    stage: Literal["opening", "buildup", "climax", "closing"]
    label: str = Field(min_length=1)
    summary: Optional[str] = None
    points: List[str] = Field(default_factory=list)
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
                "label": stage.label[:14],
                "summary": stage.summary[:60] if stage.summary else None,
                "points": [p[:60] for p in stage.points[:MAX_POINTS_PER_STAGE] if p.strip()],
                "quote": stage.quote[:40] if stage.quote else None,
                "segmentIds": ids,
            })
        stages.sort(key=lambda s: _STAGE_ORDER.index(s["stage"]))
        return {
            "chartType": "narrative_arc",
            "title": model.title,
            "stages": stages,
            "truncatedCount": 0,
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
                    if not existing.get("summary") and stage.get("summary"):
                        existing["summary"] = stage["summary"]
                    known = {normalize_text(p) for p in existing.get("points", [])}
                    for point in stage.get("points", []):
                        if normalize_text(point) not in known and len(existing["points"]) < MAX_POINTS_PER_STAGE:
                            existing["points"].append(point)
                            known.add(normalize_text(point))
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
            for point_index, point in enumerate(stage.get("points", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"{label}段要点{point_index + 1}数字与原文不符")
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
            points = [p for p in stage.get("points", []) if numbers_have_evidence(p, ids, segment_map)]
            stages.append({**stage, "points": points, "segmentIds": ids})
        if len(stages) < 3 or not any(s["stage"] == "climax" for s in stages):
            return None
        return {**plan, "stages": stages, "truncatedCount": 0}

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
