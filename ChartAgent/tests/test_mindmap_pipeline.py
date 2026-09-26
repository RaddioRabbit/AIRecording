"""v5 流水线思维导图改造测试：mindmap_normalize 节点、渲染分发、降级链。LLM 全部打桩。"""
import json
import unittest
from unittest.mock import patch

from agent import nodes
from agent.graph import chart_agent

from tests.test_pipeline import (
    MEETING_PLAN,
    MEETING_SEGMENTS,
    base_state,
    classify_response,
    router_fake,
)


class MindmapNormalizeNodeTests(unittest.TestCase):
    def test_meeting_plan_normalized_to_mind_map(self):
        state = base_state(MEETING_SEGMENTS, content_type="meeting", plan=dict(MEETING_PLAN))
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        doc = result["plan"]["mindMap"]
        self.assertEqual(doc["root"], {"id": "root", "text": "私有化部署讨论会"})
        self.assertEqual(doc["branches"][0]["id"], "b0")
        self.assertEqual(doc["branches"][0]["text"], "私有化部署")
        self.assertEqual(doc["branches"][0]["segment_ids"], ["s1", "s2"])

    def test_highlights_plan_passes_through_untouched(self):
        highlights_plan = {
            "chartType": "highlights", "title": "重点句子",
            "highlightSentences": [{"segmentId": "s1", "text": "重点", "speaker": "甲",
                                    "startTime": 0.0, "endTime": 5.0, "tag": "关键判断"}],
            "truncatedCount": 0,
        }
        state = base_state(MEETING_SEGMENTS, content_type="other", plan=highlights_plan)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertNotIn("mindMap", result["plan"])

    def test_empty_branches_degrades_to_highlights(self):
        plan = {"chartType": "idea_card", "title": "随手记要点",
                "coreIdea": "只有想法没有要点", "coreSegmentIds": ["s1"], "points": []}
        state = base_state(MEETING_SEGMENTS, content_type="memo", plan=plan)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertTrue(result["validation_result"]["degraded"])
        self.assertEqual(result["validation_result"]["reason"], "mindmap_empty")

    def test_failed_state_passes_through(self):
        state = base_state(MEETING_SEGMENTS, status="failed", plan=None)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["status"], "failed")
        self.assertIsNone(result["plan"])

    def test_missing_plan_degrades_to_highlights(self):
        state = base_state(MEETING_SEGMENTS, content_type="meeting", plan=None)
        result = nodes.mindmap_normalize_node(state)
        self.assertEqual(result["plan"]["chartType"], "highlights")

    def test_rich_meeting_plan_maps_all_fields_and_min_three_children(self):
        rich_plan = {
            "chartType": "decision_board", "title": "私有化部署讨论会",
            "topics": [{
                "title": "私有化部署",
                "background": "客户要求数据不出内网",
                "points": ["后端需支持离线模型加载", "前端要做权限分级", "运维需要一键部署脚本"],
                "disagreements": ["排期是否延到 Q3 未定"],
                "conclusion": "先做网关层改造",
                "actions": [{"text": "输出部署清单", "owner": "张三", "due": "周五前"}],
                "segmentIds": ["s1", "s2"],
            }],
            "truncatedCount": 0,
        }
        state = base_state(MEETING_SEGMENTS, content_type="meeting", plan=rich_plan)
        result = nodes.mindmap_normalize_node(state)
        doc = result["plan"]["mindMap"]
        children = doc["branches"][0]["children"]
        texts = [c["text"] for c in children]
        self.assertGreaterEqual(len(children), 3)
        self.assertTrue(any(t.startswith("背景：") for t in texts))
        self.assertTrue(any(t.startswith("分歧：") for t in texts))
        self.assertTrue(any(t.startswith("结论：") for t in texts))
        self.assertTrue(any("运维需要一键部署脚本" in t for t in texts))


class AssertRenderFragmentTests(unittest.TestCase):
    def test_accepts_balanced_traceable_fragment(self):
        nodes._assert_render_fragment('<div data-segment-ids="s1">ok</div>')

    def test_rejects_empty(self):
        with self.assertRaises(ValueError):
            nodes._assert_render_fragment("   ")

    def test_rejects_missing_segment_ids(self):
        with self.assertRaises(ValueError):
            nodes._assert_render_fragment("<div>ok</div>")

    def test_rejects_unbalanced_divs(self):
        with self.assertRaises(ValueError):
            nodes._assert_render_fragment('<div data-segment-ids="s1"><div>ok</div>')


class MindMapRenderDispatchTests(unittest.TestCase):
    def test_pipeline_meeting_renders_mind_map_svg(self):
        with patch.object(nodes, "call_llm", side_effect=router_fake('"decision_board"', MEETING_PLAN, "meeting")):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        html = result["html_fragment"]
        self.assertIn("<svg", html)
        self.assertIn("私有化部署讨论会", html)
        self.assertIn('data-segment-ids="s1,s2"', html)
        self.assertEqual(html.count("<div"), html.count("</div>"))

    def test_pipeline_degraded_highlights_still_uses_highlights_renderer(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("other")
            raise AssertionError("other 类型不应调用提取 LLM")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["plan"]["chartType"], "highlights")
        self.assertNotIn("mindMap", result["plan"])
        self.assertNotIn("<svg", result["html_fragment"])

    def test_mind_map_render_keeps_overview_bar(self):
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
        self.assertEqual(result["plan"]["chartType"], "mind_map")
        self.assertIn('<div class="sc-overview">', result["html_fragment"])
        self.assertIn("会议确认了私有化部署的排期与分工", result["html_fragment"])


from pydantic import ValidationError

from agent.schema import (
    MindMapDoc,
    SmartChartGenerateResponse,
    SmartChartRenderRequest,
)


class SchemaV5ContractTests(unittest.TestCase):
    def test_generate_response_accepts_mindmap(self):
        response = SmartChartGenerateResponse(
            requestId="r1", status="success", contentType="meeting", contentTypeDisplayName="会议",
            chartType="mind_map", chartTypeDisplayName="思维导图", title="t", htmlFragment="<div/>",
            mindMap={"root": {"id": "root", "text": "主题"},
                     "branches": [{"id": "b0", "text": "分支", "segment_ids": ["s1"], "children": []}]},
            plan={},
        )
        self.assertEqual(response.version, "5.0")
        self.assertEqual(response.mindMap.branches[0].segment_ids, ["s1"])

    def test_generate_response_mindmap_defaults_none(self):
        response = SmartChartGenerateResponse(
            requestId="r1", status="success", chartType="highlights",
            chartTypeDisplayName="重点句子", title="t", htmlFragment="<div/>", plan={},
        )
        self.assertIsNone(response.mindMap)

    def test_generate_response_overview_round_trips(self):
        response = SmartChartGenerateResponse(
            requestId="r1", status="success", chartType="mind_map",
            chartTypeDisplayName="思维导图", title="t", htmlFragment="<div/>",
            overview="会议确认了私有化部署的排期与分工", plan={},
        )
        self.assertEqual(response.overview, "会议确认了私有化部署的排期与分工")

    def test_generate_response_overview_defaults_none(self):
        response = SmartChartGenerateResponse(
            requestId="r1", status="success", chartType="highlights",
            chartTypeDisplayName="重点句子", title="t", htmlFragment="<div/>", plan={},
        )
        self.assertIsNone(response.overview)

    def test_mindmap_doc_rejects_extra_fields(self):
        with self.assertRaises(ValidationError):
            MindMapDoc.model_validate({
                "root": {"id": "root", "text": "t"},
                "branches": [{"id": "b0", "text": "b", "segment_ids": [], "children": [], "bogus": 1}],
            })

    def test_mindmap_doc_rejects_empty_text(self):
        with self.assertRaises(ValidationError):
            MindMapDoc.model_validate({
                "root": {"id": "root", "text": ""},
                "branches": [],
            })

    def test_render_request_contract(self):
        request = SmartChartRenderRequest.model_validate({
            "version": "5.0", "requestId": "r1", "recordingId": "rec1", "theme": "darkCyberpunk",
            "mindMap": {"root": {"id": "root", "text": "t"}, "branches": []},
        })
        self.assertEqual(request.theme, "darkCyberpunk")

    def test_render_request_rejects_v4_version(self):
        with self.assertRaises(ValidationError):
            SmartChartRenderRequest.model_validate({
                "version": "4.0", "requestId": "r1", "recordingId": "rec1",
                "mindMap": {"root": {"id": "root", "text": "t"}, "branches": []},
            })

    def test_render_request_overview_round_trips(self):
        request = SmartChartRenderRequest.model_validate({
            "version": "5.0", "requestId": "r1", "recordingId": "rec1",
            "mindMap": {"root": {"id": "root", "text": "t"}, "branches": []},
            "overview": "会议确认了私有化部署的排期与分工",
        })
        self.assertEqual(request.overview, "会议确认了私有化部署的排期与分工")
        self.assertIsNone(SmartChartRenderRequest.model_validate({
            "version": "5.0", "requestId": "r1", "recordingId": "rec1",
            "mindMap": {"root": {"id": "root", "text": "t"}, "branches": []},
        }).overview)


if __name__ == "__main__":
    unittest.main()
