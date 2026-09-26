"""skill 注册表：content_type → skill 实例；chart_type → skill（渲染分发用）。"""
from typing import Dict

from .base import CONTENT_TYPE_DISPLAY_NAMES, BaseSkill
from .dialogue import DialogueSkill
from .interview import InterviewSkill
from .lecture import LectureSkill
from .meeting import MeetingSkill
from .memo import MemoSkill
from .other import OtherSkill
from .speech import SpeechSkill

SKILLS: Dict[str, BaseSkill] = {
    skill.content_type: skill
    for skill in [
        DialogueSkill(),
        InterviewSkill(),
        LectureSkill(),
        MeetingSkill(),
        MemoSkill(),
        OtherSkill(),
        SpeechSkill(),
    ]
}

CHART_TYPE_DISPLAY_NAMES = {skill.chart_type: skill.display_name for skill in SKILLS.values()}
CHART_TYPE_DISPLAY_NAMES["mind_map"] = "思维导图"


def skill_for_chart_type(chart_type: str) -> BaseSkill:
    for skill in SKILLS.values():
        if skill.chart_type == chart_type:
            return skill
    return SKILLS["other"]


__all__ = ["BaseSkill", "CONTENT_TYPE_DISPLAY_NAMES", "CHART_TYPE_DISPLAY_NAMES", "SKILLS", "skill_for_chart_type"]
