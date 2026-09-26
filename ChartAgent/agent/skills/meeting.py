"""meeting skill：会议 → 决策行动看板。议题 → 背景/讨论要点/分歧/结论 + 行动项（负责人/截止时间）。"""
import json
from typing import Any, Dict, List, Literal, Optional

from pydantic import Field, ValidationError

from ..schema import StrictModel
from ..textutils import filter_known_segment_ids, normalize_text, numbers_have_evidence
from .base import BaseSkill

MAX_TOPICS = 8
MAX_ACTIONS_PER_TOPIC = 6
MAX_POINTS_PER_TOPIC = 6
MAX_DISAGREEMENTS_PER_TOPIC = 3

_PROMPT = """你是会议内容结构化提取器。从会议转写片段中提取议题、背景、讨论要点、分歧、结论与行动项。
要求：
1. topics：按议题组织，每个议题 title 不超过 20 字。
2. background：为什么讨论这个议题，不超过 60 字；原文没有相关背景时为 null。
3. points：该议题的关键讨论要点，2-6 条，每条不超过 60 字，必须来自原文明确表述。
4. disagreements：未达成一致的分歧或待定事项，0-3 条，每条不超过 40 字；没有则为空列表。
5. conclusion：该议题达成的结论，不超过 60 字；原文没有明确结论时为 null。
6. actions：行动项（任务/分工/截止时间），text 不超过 40 字；owner（负责人）与 due（时间）仅当原文明确时填写，否则为 null。行动项必须有原文依据（如"负责""完成""提供""对接""下周前"等表述）。
7. 每个议题必须携带来源 segmentIds（只用输入片段中的 id）。
8. 覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
9. 禁止编造原文没有的内容。
只输出严格 JSON：
{"chartType":"decision_board","title":"<会议主题，≤20字>","topics":[{"title":"...","background":null,"points":["..."],"disagreements":[],"conclusion":null,"actions":[{"text":"...","owner":null,"due":null}],"segmentIds":["..."]}]}
输入片段：
"""


class _Action(StrictModel):
    text: str = Field(min_length=1)
    owner: Optional[str] = None
    due: Optional[str] = None


class _Topic(StrictModel):
    title: str = Field(min_length=1)
    background: Optional[str] = None
    points: List[str] = Field(default_factory=list)
    disagreements: List[str] = Field(default_factory=list)
    conclusion: Optional[str] = None
    actions: List[_Action] = Field(default_factory=list)
    segmentIds: List[str] = Field(min_length=1)


class _MeetingPlan(StrictModel):
    chartType: Literal["decision_board"]
    title: str = Field(min_length=1)
    topics: List[_Topic] = Field(default_factory=list)
    truncatedCount: int = 0


class MeetingSkill(BaseSkill):
    content_type = "meeting"
    chart_type = "decision_board"
    display_name = "决策行动看板"

    def extraction_prompt(self, chunk: List[Dict[str, Any]]) -> str:
        return _PROMPT + json.dumps(chunk, ensure_ascii=False, indent=2)

    def normalize(self, raw: Dict[str, Any], source_segments: List[Dict[str, Any]]) -> Dict[str, Any]:
        try:
            model = _MeetingPlan.model_validate(raw)
        except ValidationError as error:
            raise ValueError(f"meeting plan 无效：{error}") from error
        segment_map = {s["id"]: s for s in source_segments}
        topics = []
        for topic in model.topics:
            ids = filter_known_segment_ids(topic.segmentIds, segment_map)
            if not ids:
                continue
            topics.append({
                "title": topic.title[:20],
                "background": topic.background[:60] if topic.background else None,
                "points": [p[:60] for p in topic.points[:MAX_POINTS_PER_TOPIC] if p.strip()],
                "disagreements": [d[:40] for d in topic.disagreements[:MAX_DISAGREEMENTS_PER_TOPIC] if d.strip()],
                "conclusion": topic.conclusion[:60] if topic.conclusion else None,
                "actions": [
                    {"text": a.text, "owner": a.owner, "due": a.due}
                    for a in topic.actions[:MAX_ACTIONS_PER_TOPIC]
                ],
                "segmentIds": ids,
            })
        return {
            "chartType": "decision_board",
            "title": model.title,
            "topics": topics,
            "truncatedCount": 0,
        }

    def merge(self, plans: List[Dict[str, Any]]) -> Dict[str, Any]:
        title = next((p["title"] for p in plans if p.get("title")), "会议要点")
        seen, topics = set(), []
        for plan in plans:
            for topic in plan.get("topics", []):
                key = normalize_text(topic["title"])
                if not key:
                    continue
                if key in seen:
                    # 同议题合并：补充新要点/分歧/行动项与来源，回填缺失的背景/结论
                    existing = next(t for t in topics if normalize_text(t["title"]) == key)
                    known_points = {normalize_text(p) for p in existing.get("points", [])}
                    for point in topic.get("points", []):
                        if normalize_text(point) not in known_points and len(existing["points"]) < MAX_POINTS_PER_TOPIC:
                            existing["points"].append(point)
                            known_points.add(normalize_text(point))
                    known_dis = {normalize_text(d) for d in existing.get("disagreements", [])}
                    for item in topic.get("disagreements", []):
                        if normalize_text(item) not in known_dis and len(existing["disagreements"]) < MAX_DISAGREEMENTS_PER_TOPIC:
                            existing["disagreements"].append(item)
                            known_dis.add(normalize_text(item))
                    if not existing.get("background") and topic.get("background"):
                        existing["background"] = topic["background"]
                    if not existing.get("conclusion") and topic.get("conclusion"):
                        existing["conclusion"] = topic["conclusion"]
                    known_actions = {normalize_text(a["text"]) for a in existing["actions"]}
                    for action in topic.get("actions", []):
                        if normalize_text(action["text"]) not in known_actions and len(existing["actions"]) < MAX_ACTIONS_PER_TOPIC:
                            existing["actions"].append(action)
                            known_actions.add(normalize_text(action["text"]))
                    existing["segmentIds"] = list(dict.fromkeys(existing["segmentIds"] + topic.get("segmentIds", [])))
                    continue
                seen.add(key)
                topics.append(topic)
        truncated = max(0, len(topics) - MAX_TOPICS) + sum(p.get("truncatedCount", 0) for p in plans)
        return {
            "chartType": "decision_board",
            "title": title,
            "topics": topics[:MAX_TOPICS],
            "truncatedCount": truncated,
        }

    def is_empty(self, plan: Dict[str, Any]) -> bool:
        return not plan.get("topics")

    def validate(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> List[str]:
        topics = plan.get("topics") or []
        if not topics:
            return ["meeting 需要至少一个议题"]
        errors = []
        for index, topic in enumerate(topics):
            ids = topic.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                errors.append(f"议题{index + 1}缺少有效来源片段")
                continue
            if not numbers_have_evidence(topic.get("title"), ids, segment_map):
                errors.append(f"议题{index + 1}标题数字与原文不符")
            if topic.get("conclusion") and not numbers_have_evidence(topic["conclusion"], ids, segment_map):
                errors.append(f"议题{index + 1}结论数字与原文不符")
            if topic.get("background") and not numbers_have_evidence(topic["background"], ids, segment_map):
                errors.append(f"议题{index + 1}背景数字与原文不符")
            for point_index, point in enumerate(topic.get("points", [])):
                if not numbers_have_evidence(point, ids, segment_map):
                    errors.append(f"议题{index + 1}要点{point_index + 1}数字与原文不符")
            for dis_index, item in enumerate(topic.get("disagreements", [])):
                if not numbers_have_evidence(item, ids, segment_map):
                    errors.append(f"议题{index + 1}分歧{dis_index + 1}数字与原文不符")
            for action_index, action in enumerate(topic.get("actions", [])):
                if not numbers_have_evidence(action.get("text"), ids, segment_map):
                    errors.append(f"议题{index + 1}行动项{action_index + 1}数字与原文不符")
                if action.get("due") and not numbers_have_evidence(action["due"], ids, segment_map):
                    errors.append(f"议题{index + 1}行动项{action_index + 1}时间数字与原文不符")
        return errors

    def fallback(self, plan: Dict[str, Any], segment_map: Dict[str, Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        topics = []
        for topic in plan.get("topics", []):
            ids = topic.get("segmentIds") or []
            if not filter_known_segment_ids(ids, segment_map):
                continue
            if not numbers_have_evidence(topic.get("title"), ids, segment_map):
                continue
            conclusion = topic.get("conclusion")
            if conclusion and not numbers_have_evidence(conclusion, ids, segment_map):
                conclusion = None
            actions = [
                {
                    "text": a["text"],
                    "owner": a.get("owner"),
                    "due": a.get("due") if a.get("due") and numbers_have_evidence(a["due"], ids, segment_map) else None,
                }
                for a in topic.get("actions", [])
                if numbers_have_evidence(a.get("text"), ids, segment_map)
            ]
            background = topic.get("background")
            if background and not numbers_have_evidence(background, ids, segment_map):
                background = None
            points = [p for p in topic.get("points", []) if numbers_have_evidence(p, ids, segment_map)]
            disagreements = [d for d in topic.get("disagreements", []) if numbers_have_evidence(d, ids, segment_map)]
            topics.append({**topic, "background": background, "points": points,
                           "disagreements": disagreements, "conclusion": conclusion, "actions": actions})
        if not topics:
            return None
        return {**plan, "topics": topics, "truncatedCount": 0}

    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        branches = []
        for index, topic in enumerate(plan.get("topics", [])[:MAX_TOPICS]):
            segment_ids = topic.get("segmentIds", [])
            branch = self.make_mindmap_node(index, topic.get("title", ""), segment_ids)
            children: List[Dict[str, Any]] = []
            if topic.get("background"):
                children.append(self.make_mindmap_node(
                    index, "背景：" + str(topic["background"]), segment_ids, len(children)))
            for point in topic.get("points", []):
                children.append(self.make_mindmap_node(index, point, segment_ids, len(children)))
            for item in topic.get("disagreements", []):
                children.append(self.make_mindmap_node(
                    index, "分歧：" + str(item), segment_ids, len(children)))
            if topic.get("conclusion"):
                children.append(self.make_mindmap_node(
                    index, "结论：" + str(topic["conclusion"]), segment_ids, len(children)))
            for action in topic.get("actions", []):
                text = str(action.get("text", ""))
                extras = [str(v) for v in (action.get("owner"), action.get("due")) if v]
                if extras:
                    text += "（" + " · ".join(extras) + "）"
                children.append(self.make_mindmap_node(index, text, segment_ids, len(children)))
            branch["children"] = children
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": str(plan.get("title", "会议要点"))}, "branches": branches}
