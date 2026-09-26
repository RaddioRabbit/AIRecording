"""全局总览（v5）：一段话概括整段录音。独立时间预算，失败不阻塞主流程。"""
from typing import Optional

from .textutils import parse_llm_json

MAX_OVERVIEW_CHARS = 100
_HEAD_CHARS = 3000
_MID_CHARS = 2000
_TAIL_CHARS = 2000

_PROMPT = """你是录音内容总览撰写器。根据采样文本，用一段话概括这段{type_name}录音：讲了什么主题、得出了什么结论、有哪些待办事项。
要求：
1. 只写一段话，不超过 100 字。
2. 只基于采样文本中明确出现的信息，禁止编造。
3. 不要分点、不要用引号包裹整段。
只输出严格 JSON：
{{"overview":"..."}}
采样文本：
【开头】
{head}
【中间】
{mid}
【结尾】
{tail}
"""


def _sample(transcript_text: str):
    head = transcript_text[:_HEAD_CHARS]
    tail = transcript_text[-_TAIL_CHARS:] if len(transcript_text) > _HEAD_CHARS else ""
    middle_start = max(len(transcript_text) // 2 - _MID_CHARS // 2, len(head))
    mid = transcript_text[middle_start:middle_start + _MID_CHARS]
    return head, mid, tail


def build_overview_prompt(transcript_text: str, type_display_name: str) -> str:
    head, mid, tail = _sample(transcript_text)
    return _PROMPT.format(type_name=type_display_name, head=head, mid=mid, tail=tail)


def parse_overview(raw: str) -> Optional[str]:
    try:
        data = parse_llm_json(raw)
    except ValueError:
        return None
    overview = data.get("overview")
    if not isinstance(overview, str) or not overview.strip():
        return None
    return overview.strip()[:MAX_OVERVIEW_CHARS]
