"""dialogue skill：对话 → 话题泳道图。说话人泳道 × 时间轴上的话题块。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..mindmap import MAX_BRANCHES
from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence
from .base import BaseSkill

MAX_SPEAKERS = 4
MAX_BLOCKS = 20
MAX_KEY_POINTS_PER_BLOCK = 4
OTHERS_LABEL = "其他人"

_PROMPT = """你是对话内容结构化提取器。把多人自由讨论整理为话题块。
要求：
1. speakers：说话人列表（使用片段中的 speaker 字段原值）。
2. blocks：话题块，包含 speaker（该话题的主导人）、topic（话题名，≤14字）、summary（这一话题聊了什么，≤60字，可为 null）、keyPoints（该话题的关键信息点，1-4 条，每条 ≤50字，必须来自原文明确表述）、start/end（该话题的起止时间，秒，来自片段时间）、segmentIds。
3. 话题块按时间顺序排列；只提取明确出现的话题，禁止臆测。
4. 覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
只输出严格 JSON：
{"chartType":"topic_swimlane","title":"<对话主题，≤20字>","speakers":["..."],"blocks":[{"speaker":"...","topic":"...","summary":null,"keyPoints":["..."],"start":0.0,"end":0.0,"segmentIds":["..."]}]}
输入片段：
"""


class _Block(StrictModel):
    speaker: str = Field(min_length=1)
    topic: str = Field(min_length=1)
    summary: Optional[str] = None
    keyPoints: List[str] = Field(default_factory=list)
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
            kept = list(dict.fromkeys(ordered_speakers[:MAX_SPEAKERS - 1] + [OTHERS_LABEL]))
        else:
            kept = ordered_speakers
        kept_set = set(kept)
        dropped = 0
        blocks = []
        for block in model.blocks:
            ids = filter_known_segment_ids(block.segmentIds, segment_map)
            if not ids:
                dropped += 1
                continue
            start, end = float(block.start), float(block.end)
            if end < start:
                start, end = end, start
            blocks.append({
                "speaker": block.speaker if block.speaker in kept_set else OTHERS_LABEL,
                "topic": block.topic[:14],
                "summary": block.summary[:60] if block.summary else None,
                "keyPoints": [p[:50] for p in block.keyPoints[:MAX_KEY_POINTS_PER_BLOCK] if p.strip()],
                "start": start,
                "end": end,
                "segmentIds": ids,
            })
        blocks.sort(key=lambda b: b["start"])
        return {
            "chartType": "topic_swimlane",
            "title": model.title[:20],
            "speakers": kept,
            "blocks": blocks,
            "truncatedCount": dropped,
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
            kept = list(dict.fromkeys(speakers[:MAX_SPEAKERS - 1] + [OTHERS_LABEL]))
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
            ids = filter_known_segment_ids(block.get("segmentIds"), segment_map)
            if not ids:
                errors.append(f"话题块{index + 1}缺少有效来源片段")
                continue
            source_starts = [float(segment_map[sid].get("startTime", 0.0)) for sid in ids]
            source_ends = [float(segment_map[sid].get("endTime", 0.0)) for sid in ids]
            # 话题块的 end 语义是“持续到下一个话题”，允许越过来源片段结尾；
            # 锚点是 start——start 必须落在来源片段的时间范围内（±0.5s 容差）。
            block_start = float(block.get("start", 0.0))
            if block_start < min(source_starts) - 0.5 or block_start > max(source_ends) + 0.5:
                errors.append(f"话题块{index + 1}时间超出来源片段范围")
            if not numbers_have_evidence(block.get("topic"), ids, segment_map):
                errors.append(f"话题块{index + 1}话题数字与原文不符")
            if block.get("summary") and not numbers_have_evidence(block["summary"], ids, segment_map):
                errors.append(f"话题块{index + 1}摘要数字与原文不符")
            for point_index, point in enumerate(block.get("keyPoints", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"话题块{index + 1}信息点{point_index + 1}数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        blocks = []
        speaker_set = set(plan.get("speakers") or [])
        for block in plan.get("blocks", []):
            if block.get("speaker") not in speaker_set:
                continue
            ids = filter_known_segment_ids(block.get("segmentIds"), segment_map)
            if not ids:
                continue
            source_starts = [float(segment_map[sid].get("startTime", 0.0)) for sid in ids]
            source_ends = [float(segment_map[sid].get("endTime", 0.0)) for sid in ids]
            block_start = float(block.get("start", 0.0))
            if block_start < min(source_starts) - 0.5 or block_start > max(source_ends) + 0.5:
                continue
            if not numbers_have_evidence(block.get("topic"), ids, segment_map):
                continue
            if block.get("summary") and not numbers_have_evidence(block["summary"], ids, segment_map):
                continue
            key_points = [p for p in block.get("keyPoints", []) if numbers_have_evidence(p, ids, segment_map)]
            blocks.append({**block, "keyPoints": key_points, "segmentIds": ids})
        if len(plan.get("speakers") or []) < 2 or len(blocks) < 3:
            return None
        return {**plan, "blocks": blocks, "truncatedCount": 0}

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
