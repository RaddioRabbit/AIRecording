"""录音内容分类器：把转写内容分类为七种内容类型之一。

设计要点（对应设计文档 §5）：
- 输入 = 元信息（时长/说话人数/片段数）+ 采样文本（开头/中间/结尾）
- 说话人数是强提示但不硬排除（speakerId 可能缺失或不准）
- 任何失败/低置信度都归 other，分类器永远不让请求失败
"""
import math
from typing import Any, Dict, List, Optional, Tuple

from .llm_client import LLMError, call_llm
from .textutils import parse_llm_json

CONTENT_TYPES = ("meeting", "interview", "lecture", "dialogue", "speech", "memo", "other")
CLASSIFY_CONFIDENCE_THRESHOLD = 0.6
HEAD_SAMPLE_CHARS = 2000
MIDDLE_SAMPLE_CHARS = 1000
TAIL_SAMPLE_CHARS = 1000

_TYPE_DEFINITIONS = """- meeting 会议：多人、有议题、产出结论或待办
- interview 访谈：一问一答、角色分明（提问者 vs 回答者）
- lecture 讲座：单人为主、系统传授知识（概念→讲解→例子）
- dialogue 对话：多人自由讨论、不追求结论
- speech 演讲：单人、面向观众的感染力表达（故事+观点+金句）
- memo 随手记：单人即兴记录（口播/语音备忘），短且随意
- other 其他：无法确定或均不符合"""


def _sample_transcript(text: str) -> Tuple[str, str, str]:
    if len(text) <= HEAD_SAMPLE_CHARS + MIDDLE_SAMPLE_CHARS + TAIL_SAMPLE_CHARS:
        return text, "", ""
    head = text[:HEAD_SAMPLE_CHARS]
    tail = text[-TAIL_SAMPLE_CHARS:]
    middle_start = max((len(text) - MIDDLE_SAMPLE_CHARS) // 2, len(head))
    middle = text[middle_start:middle_start + MIDDLE_SAMPLE_CHARS]
    return head, middle, tail


def _speaker_count(segments: List[Dict[str, Any]]) -> int:
    return len({str(s.get("speaker", "")).strip() for s in segments if str(s.get("speaker", "")).strip()})


def _total_duration(segments: List[Dict[str, Any]]) -> float:
    return max((float(s.get("endTime", 0.0) or 0.0) for s in segments), default=0.0)


def build_classify_prompt(segments: List[Dict[str, Any]], transcript_text: str) -> str:
    head, middle, tail = _sample_transcript(transcript_text)
    samples = f"【开头】{head}"
    if middle:
        samples += f"\n【中间】{middle}"
    if tail:
        samples += f"\n【结尾】{tail}"
    return (
        "你是录音内容分类器。根据元信息与采样文本，把录音分类为七种内容类型之一：\n"
        f"{_TYPE_DEFINITIONS}\n"
        "边界判定：是否产出结论区分 meeting 与 dialogue；传授知识 vs 感染说服区分 lecture 与 speech；"
        "有明显问答交替才是 interview。\n"
        "只输出严格 JSON：{\"content_type\":\"...\",\"confidence\":0.0,\"reason\":\"≤30字\"}\n"
        "confidence 取 0-1，不确定时给低分。\n"
        f"元信息：时长 {_total_duration(segments):.0f} 秒；说话人数 {_speaker_count(segments)}；片段数 {len(segments)}；总字符数 {len(transcript_text)}\n"
        f"采样文本：\n{samples}"
    )


def classify_content(
    segments: List[Dict[str, Any]], transcript_text: str, deadline: Optional[float] = None
) -> Tuple[str, float, str]:
    """返回 (content_type, confidence, reason)。任何异常都归 other，绝不抛出。"""
    try:
        prompt = build_classify_prompt(segments, transcript_text)
        if deadline is None:
            raw = call_llm(prompt, temperature=0.0)
        else:
            raw = call_llm(prompt, temperature=0.0, deadline=deadline)
        parsed = parse_llm_json(raw)
        content_type = str(parsed.get("content_type", ""))
        confidence = float(parsed.get("confidence", 0.0) or 0.0)
        if math.isnan(confidence):
            confidence = 0.0
        confidence = max(0.0, min(1.0, confidence))
        reason = str(parsed.get("reason") or "")[:60]
    except (LLMError, ValueError, TypeError, AttributeError) as error:
        return "other", 0.0, f"classify_failed:{type(error).__name__}"
    if content_type not in CONTENT_TYPES:
        return "other", 0.0, f"unknown_type:{content_type[:20]}"
    if not confidence >= CLASSIFY_CONFIDENCE_THRESHOLD:
        return "other", confidence, f"low_confidence:{content_type}"
    return content_type, confidence, reason
