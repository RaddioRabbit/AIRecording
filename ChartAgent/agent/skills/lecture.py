"""lecture skill：讲座 → 知识大纲树。主题 → 章节 → 概念三级结构。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence
from .base import BaseSkill

MAX_CHAPTERS = 8
MAX_CONCEPTS_PER_CHAPTER = 6
MAX_POINTS_PER_CHAPTER = 5

_PROMPT = """你是讲座内容结构化提取器。把讲座转写整理为三级知识结构。
要求：
1. topic：讲座主题（≤16字）。
2. chapters：章节列表，每章 title ≤16字；points 为该章的讲解要点（2-5 条，每条 ≤60字，忠于原文）；concepts 为该章的概念要点，name ≤16字，note 为该概念的一句话解释（≤40字，原文没有解释时为 null）。
3. 每章、每个概念都必须携带来源 segmentIds（只用输入片段中的 id）。
4. 只提取原文明确讲到的知识内容，禁止补充原文没有的知识。
5. 覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
只输出严格 JSON：
{"chartType":"knowledge_tree","title":"<讲座主题>","topic":"...","chapters":[{"title":"...","points":["..."],"concepts":[{"name":"...","note":null,"segmentIds":["..."]}],"segmentIds":["..."]}]}
输入片段：
"""


class _Concept(StrictModel):
    name: str = Field(min_length=1)
    note: Optional[str] = None
    segmentIds: List[str] = Field(min_length=1)


class _Chapter(StrictModel):
    title: str = Field(min_length=1)
    points: List[str] = Field(default_factory=list)
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
                    concepts.append({
                        "name": concept.name[:16],
                        "note": concept.note[:40] if concept.note else None,
                        "segmentIds": concept_ids,
                    })
            dropped_concepts += len(chapter.concepts) - len(concepts)
            chapters.append({
                "title": chapter.title[:16],
                "points": [p[:60] for p in chapter.points[:MAX_POINTS_PER_CHAPTER] if p.strip()],
                "concepts": concepts,
                "segmentIds": ids,
            })
        return {
            "chartType": "knowledge_tree",
            "title": model.title,
            "topic": model.topic[:16],
            "chapters": chapters,
            "truncatedCount": dropped_concepts,
        }

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
        if len(chapters) < 2 and not (len(chapters) == 1 and len(chapters[0]["concepts"]) >= 2):
            return None
        return {**plan, "chapters": chapters, "truncatedCount": 0}

    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, chapter in enumerate(plan.get("chapters", [])[:MAX_CHAPTERS]):
            branch = self.make_mindmap_node(index, chapter.get("title", ""), chapter.get("segmentIds", []))
            children: List[Dict[str, Any]] = []
            for point in chapter.get("points", []):
                children.append(self.make_mindmap_node(
                    index, point, chapter.get("segmentIds", []), len(children)))
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
