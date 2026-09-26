"""Rule-based temporal intent detection over the user's retrieval text."""

from __future__ import annotations

from typing import NamedTuple


# Must stay aligned with EvidenceContextBuilder.max_parents (default 6).
BRIEFING_MAX_PARENTS = 6

_GENERIC_FILLERS = (
    "说了什么", "讲了什么", "音频内容", "内容", "音频", "录音", "会议", "什么", "讲了", "说了",
)
_PARTICLES = "的了吗呢吧是"
_PUNCTUATION = "，。？！、：；,.?!:;~～ \t\n"

# Ordered: specific phrases must precede their bare-word substrings.
_TRIGGERS: tuple[tuple[str, str, int], ...] = (
    ("最新一次", "desc", 1),
    ("最新一场", "desc", 1),
    ("最后一场", "desc", 1),
    ("上一场", "desc", 1),
    ("上一个", "desc", 1),
    ("刚刚", "desc", 1),
    ("最新", "desc", 1),
    ("最近一次", "desc", 3),
    ("最近一场", "desc", 3),
    ("最近几场", "desc", 3),
    ("近期", "desc", 3),
    ("这几天", "desc", 3),
    ("最近", "desc", 3),
    ("最早", "asc", 1),
    ("第一场", "asc", 1),
    ("第一次", "asc", 1),
    ("最开始", "asc", 1),
)


class TemporalIntent(NamedTuple):
    phrase: str
    order: str  # "desc" = newest first, "asc" = oldest first
    limit: int


def detect_intent(text: str) -> TemporalIntent | None:
    if not text:
        return None
    for phrase, order, limit in _TRIGGERS:
        if phrase in text:
            return TemporalIntent(phrase=phrase, order=order, limit=limit)
    return None


def strip_intent(text: str, intent: TemporalIntent) -> str:
    return text.replace(intent.phrase, "")


def is_generic_query(core: str) -> bool:
    """True when removing fillers/particles leaves no real content words."""
    remainder = core
    for filler in _GENERIC_FILLERS:
        remainder = remainder.replace(filler, "")
    remainder = "".join(
        char for char in remainder if char not in _PARTICLES and char not in _PUNCTUATION
    )
    return len(remainder) < 2
