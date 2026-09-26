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
            if normalize_text(sentence.get("text")) not in normalize_text(source.get("text", "")):
                errors.append(f"重点句子{index + 1}与原文不符")
            start_time = float(sentence["startTime"]) if sentence.get("startTime") is not None else -1
            end_time = float(sentence["endTime"]) if sentence.get("endTime") is not None else -1
            if abs(start_time - float(source.get("startTime", 0))) > 0.01:
                errors.append(f"重点句子{index + 1}开始时间与原文不符")
            if abs(end_time - float(source.get("endTime", 0))) > 0.01:
                errors.append(f"重点句子{index + 1}结束时间与原文不符")
            source_speaker = str(source.get("speaker", ""))
            if source_speaker and sentence.get("speaker", "") != source_speaker:
                errors.append(f"重点句子{index + 1}说话人与原文不符")
        return errors

    def render(self, plan: Dict[str, Any], theme: str, title: str) -> str:
        return render_highlights(plan, theme, title)
