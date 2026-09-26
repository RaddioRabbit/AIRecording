"""v4 端到端流水线测试：类型路由、强制类型、降级链、渲染校验、HTTP 契约。LLM 全部打桩。"""
import json
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from agent import nodes
from agent.graph import chart_agent
from agent.llm_client import LLMError
from main import app


def seg(segment_id, text, start, speaker="发言人"):
    return {"id": segment_id, "speaker": speaker, "startTime": start, "endTime": start + 5.0, "text": text}


def base_state(segments, **overrides):
    state = {
        "request_id": "request-1",
        "recording_id": "recording-1",
        "segments": segments,
        "summary_markdown": "",
        "preferences": {"styleTheme": "darkCyberpunk"},
        "force_content_type": None,
        "chunk_plans": [],
        "plan": None,
        "html_fragment": None,
        "render_config": None,
        "validation_result": None,
        "retry_count": 0,
        "error_message": None,
        "error_code": None,
        "status": "success",
    }
    state.update(overrides)
    return state


def classify_response(content_type, confidence=0.9):
    return json.dumps({"content_type": content_type, "confidence": confidence, "reason": "test"}, ensure_ascii=False)


def router_fake(extraction_marker, extraction_plan, classify_type):
    def fake(prompt, temperature=0.3, deadline=None):
        if "内容分类器" in prompt:
            return classify_response(classify_type)
        if "总览撰写器" in prompt:
            return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
        if extraction_marker and extraction_marker in prompt:
            return json.dumps(extraction_plan, ensure_ascii=False)
        raise AssertionError(f"未预期的提示词: {prompt[:100]}")
    return fake


MEETING_SEGMENTS = [
    seg("s1", "我们今天讨论私有化部署的议题，结论就是当天完成部署", 0.0, "甲"),
    seg("s2", "李老师今天提供一台可外网访问的电脑，然后接入知识库问答", 5.0, "乙"),
    seg("s3", "好的，那我这边配合做好后续推进", 10.0, "甲"),
]
MEETING_PLAN = {
    "chartType": "decision_board",
    "title": "私有化部署讨论会",
    "topics": [
        {"title": "私有化部署", "conclusion": "当天完成部署",
         "actions": [{"text": "提供一台可外网访问的电脑", "owner": "李老师", "due": "今天"}],
         "segmentIds": ["s1", "s2"]}
    ],
}

INTERVIEW_SEGMENTS = [
    seg("s1", "你为什么坚持私有化部署？", 0.0, "采访者"),
    seg("s2", "数据不能出内网，这是红线，云上大模型再便宜也不用", 5.0, "被访者"),
    seg("s3", "那未来会扩展吗？", 10.0, "采访者"),
    seg("s4", "先做个小范围试点，稳定后再推广", 15.0, "被访者"),
]
INTERVIEW_PLAN = {
    "chartType": "qa_cards",
    "title": "部署访谈",
    "qas": [
        {"question": "为什么坚持私有化部署？", "answerPoints": ["数据安全是底线，不接受云端方案"],
         "quote": "数据不能出内网，这是红线", "tags": ["数据安全"], "segmentIds": ["s2"]},
        {"question": "未来会扩展吗？", "answerPoints": ["先小范围试点，稳定后再推广"],
         "quote": "先做个小范围试点", "tags": ["扩展"], "segmentIds": ["s4"]},
    ],
}

LECTURE_SEGMENTS = [
    seg("s1", "今天我们讲 Transformer，先讲注意力机制", 0.0, "讲师"),
    seg("s2", "注意力机制的核心是 QKV 计算和多头注意力", 5.0, "讲师"),
    seg("s3", "第二个概念是位置编码，正弦编码用 sin 和 cos", 10.0, "讲师"),
]
LECTURE_PLAN = {
    "chartType": "knowledge_tree",
    "title": "Transformer 精讲",
    "topic": "Transformer",
    "chapters": [
        {"title": "注意力机制", "concepts": [{"name": "QKV 计算", "segmentIds": ["s2"]}], "segmentIds": ["s2"]},
        {"title": "位置编码", "concepts": [{"name": "正弦编码", "segmentIds": ["s3"]}], "segmentIds": ["s3"]},
    ],
}

DIALOGUE_SEGMENTS = [
    seg("s1", "预算这块确实有点紧张，大家想想办法", 0.0, "甲"),
    seg("s2", "预算我来协调，那进度呢？", 10.0, "乙"),
    seg("s3", "进度下周继续推，不急", 20.0, "甲"),
    seg("s4", "行，那就这么定", 30.0, "乙"),
]
DIALOGUE_PLAN = {
    "chartType": "topic_swimlane",
    "title": "项目讨论",
    "speakers": ["甲", "乙"],
    "blocks": [
        {"speaker": "甲", "topic": "预算", "summary": None, "start": 0.0, "end": 10.0, "segmentIds": ["s1"]},
        {"speaker": "乙", "topic": "预算协调", "summary": None, "start": 10.0, "end": 20.0, "segmentIds": ["s2"]},
        {"speaker": "甲", "topic": "进度", "summary": None, "start": 20.0, "end": 30.0, "segmentIds": ["s3"]},
    ],
}

SPEECH_SEGMENTS = [
    seg("s1", "三年前我经历了一件改变我的事", 0.0, "演讲者"),
    seg("s2", "你会发现现状比想象中更糟糕", 30.0, "演讲者"),
    seg("s3", "所以我说，改变从今晚开始，就在你我手中", 60.0, "演讲者"),
    seg("s4", "每个人都可以迈出第一步", 90.0, "演讲者"),
]
SPEECH_PLAN = {
    "chartType": "narrative_arc",
    "title": "改变",
    "stages": [
        {"stage": "opening", "label": "故事", "summary": None, "quote": None, "segmentIds": ["s1"]},
        {"stage": "buildup", "label": "现状", "summary": None, "quote": None, "segmentIds": ["s2"]},
        {"stage": "climax", "label": "顿悟", "summary": None, "quote": "改变从今晚开始", "segmentIds": ["s3"]},
        {"stage": "closing", "label": "行动", "summary": None, "quote": None, "segmentIds": ["s4"]},
    ],
}

MEMO_PLAN = {
    "chartType": "idea_card",
    "title": "随手记要点",
    "coreIdea": "图表要按内容类型路由",
    "coreSegmentIds": ["s1"],
    "points": [{"text": "分类器要能给其他兜底", "segmentIds": ["s1"]}],
}


class PipelineTypeRoutingTests(unittest.TestCase):
    """七种类型各跑一遍完整流水线，六种类型统一断言 chartType == "mind_map"，other 走 highlights。"""

    def run_pipeline(self, marker, plan, classify_type, segments):
        with patch.object(nodes, "call_llm", side_effect=router_fake(marker, plan, classify_type)):
            return chart_agent.invoke(base_state(segments))

    def test_meeting_routes_to_mind_map(self):
        result = self.run_pipeline('"decision_board"', MEETING_PLAN, "meeting", MEETING_SEGMENTS)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["content_type"], "meeting")
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn("私有化部署", result["html_fragment"])

    def test_interview_routes_to_mind_map(self):
        result = self.run_pipeline('"qa_cards"', INTERVIEW_PLAN, "interview", INTERVIEW_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn("数据不能出内网，这是红线", result["html_fragment"])

    def test_lecture_routes_to_mind_map(self):
        result = self.run_pipeline('"knowledge_tree"', LECTURE_PLAN, "lecture", LECTURE_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn("<svg", result["html_fragment"])
        self.assertIn("注意力机制", result["html_fragment"])

    def test_dialogue_routes_to_mind_map(self):
        result = self.run_pipeline('"topic_swimlane"', DIALOGUE_PLAN, "dialogue", DIALOGUE_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn("<svg", result["html_fragment"])

    def test_speech_routes_to_mind_map(self):
        result = self.run_pipeline('"narrative_arc"', SPEECH_PLAN, "speech", SPEECH_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn("改变从今晚开始", result["html_fragment"])

    def test_memo_routes_to_mind_map(self):
        result = self.run_pipeline('"idea_card"', MEMO_PLAN, "memo", MEETING_SEGMENTS)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn("图表要按内容类型路由", result["html_fragment"])

    def test_other_uses_deterministic_highlights_without_extraction_llm(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("other")
            raise AssertionError("other 类型不应再调用提取 LLM")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")

    def test_meeting_chart_contains_overview_and_rich_sections(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了私有化部署的排期与分工"}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError(f"未预期的提示词: {prompt[:100]}")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        html = result["html_fragment"]
        self.assertIn('<div class="sc-overview">', html)
        self.assertIn("会议确认了私有化部署的排期与分工", html)
        self.assertEqual(html.count("<div"), html.count("</div>"))
        self.assertIn('data-segment-ids="s1,s2"', html)

    def test_degraded_highlights_keep_overview(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了私有化部署的排期与分工"}, ensure_ascii=False)
            raise LLMError(LLMError.TIMEOUT, "提取超时")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertIn('<div class="sc-overview">', result["html_fragment"])  # 降级也保留总览条


class PipelineForceTypeTests(unittest.TestCase):
    def test_forced_content_type_skips_classifier(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                raise AssertionError("强制类型时不应调用分类器")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
            if '"idea_card"' in prompt:
                return json.dumps(MEMO_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS, force_content_type="memo"))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["content_type"], "memo")
        self.assertEqual(result["plan"]["chartType"], "mind_map")

    def test_low_confidence_falls_back_to_other(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting", 0.4)
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
            raise AssertionError("低置信度应归 other，不应再调用提取")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["content_type"], "other")
        self.assertEqual(result["plan"]["chartType"], "highlights")

    def test_classifier_llm_failure_falls_back_to_other(self):
        def fake(prompt, temperature=0.3, deadline=None):
            raise LLMError(LLMError.TIMEOUT, "超时")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["content_type"], "other")
        self.assertEqual(result["plan"]["chartType"], "highlights")


class PipelineDegradationTests(unittest.TestCase):
    def test_all_chunk_extraction_failures_degrade_to_highlights(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            raise LLMError(LLMError.TIMEOUT, "提取超时")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertTrue(result["validation_result"]["degraded"])

    def test_invalid_plan_repaired_once_then_highlights(self):
        calls = {"repair": 0}

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
            if "未通过校验" in prompt:
                calls["repair"] += 1
                return json.dumps({"chartType": "decision_board", "title": "x", "topics": []}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps({
                    "chartType": "decision_board", "title": "x",
                    "topics": [{"title": "部署 100 台", "conclusion": None,
                                "actions": [{"text": "3 天内搞定 100 台电脑", "owner": None, "due": None}],
                                "segmentIds": ["s1"]}],
                }, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(calls["repair"], 1)  # 修复只调用一次
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")

    def test_short_transcript_fails_terminally(self):
        result = chart_agent.invoke(base_state([seg("s1", "嗯", 0.0)]))
        self.assertEqual(result["status"], "failed")

    def test_render_fragment_balanced_and_traceable(self):
        with patch.object(nodes, "call_llm", side_effect=router_fake('"decision_board"', MEETING_PLAN, "meeting")):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        html = result["html_fragment"]
        self.assertEqual(html.count("<div"), html.count("</div>"))
        self.assertIn('data-segment-ids="s1,s2"', html)


class PipelineEndpointTests(unittest.TestCase):
    def test_response_contains_v5_mind_map_fields(self):
        payload = {"version": "5.0", "requestId": "r1", "recordingId": "rec1", "segments": MEETING_SEGMENTS}
        with patch.object(nodes, "call_llm", side_effect=router_fake('"decision_board"', MEETING_PLAN, "meeting")):
            response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["contentType"], "meeting")
        self.assertEqual(body["contentTypeDisplayName"], "会议")
        self.assertEqual(body["chartType"], "mind_map")
        self.assertEqual(body["chartTypeDisplayName"], "思维导图")
        self.assertIsNotNone(body["mindMap"])
        self.assertEqual(body["mindMap"]["root"]["text"], "私有化部署讨论会")

    def test_endpoint_passes_force_content_type(self):
        payload = {"version": "5.0", "requestId": "r1", "recordingId": "rec1",
                   "segments": MEETING_SEGMENTS, "forceContentType": "memo"}
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                raise AssertionError("强制类型时不应调用分类器")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "测试总览"}, ensure_ascii=False)
            if '"idea_card"' in prompt:
                return json.dumps(MEMO_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with patch.object(nodes, "call_llm", side_effect=fake):
            response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.json()["contentType"], "memo")


if __name__ == "__main__":
    unittest.main()
