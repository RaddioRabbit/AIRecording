"""interview skill：访谈 → 问答观点卡。问题 + 回答要点组 + 被访者原话金句 + 关键词标签。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..mindmap import MAX_BRANCHES
from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence, text_has_evidence
from .base import BaseSkill

MAX_QAS = 10
MAX_TAGS = 3
MAX_ANSWER_POINTS = 5

_PROMPT = """你是访谈内容结构化提取器。从访谈转写中提取问答对与观点要点。
要求：
1. qas：每个问答对包含 question（采访者的问题，≤30字，可为转述）、answerPoints（被访者的回答要点，2-5 条，每条 ≤70字，可提炼转述但必须忠于原文）、quote（被访者最有代表性的原句，逐字，≤60字，必要时截取；没有合适原句时为 null）、tags（1-3 个关键词）。
2. 每个问答对必须携带来源 segmentIds（只用输入片段中的 id）。
3. quote 必须逐字来自原文，禁止改写；answerPoints 中的数字必须与原文一致。
4. 覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
只输出严格 JSON：
{"chartType":"qa_cards","title":"<访谈主题，≤20字>","qas":[{"question":"...","answerPoints":["..."],"quote":null,"tags":["..."],"segmentIds":["..."]}]}
输入片段：
"""


class _QA(StrictModel):
    question: str = Field(min_length=1)
    answerPoints: List[str] = Field(default_factory=list)
    quote: Optional[str] = None
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
                    "question": qa.question[:30],
                    "answerPoints": [p[:70] for p in qa.answerPoints[:MAX_ANSWER_POINTS] if p.strip()],
                    "quote": qa.quote[:60] if qa.quote else None,
                    "tags": qa.tags[:MAX_TAGS],
                    "segmentIds": ids,
                })
        return {
            "chartType": "qa_cards",
            "title": model.title,
            "qas": qas,
            "truncatedCount": 0,
        }

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
        return errors

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
