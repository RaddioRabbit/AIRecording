"""全局总览（v5）：采样、解析、节点行为（正常/异常/截断）、端到端渲染。LLM 全部打桩。"""
import json
import unittest
from unittest.mock import patch

from agent import nodes
from agent.graph import chart_agent
from agent.overview import MAX_OVERVIEW_CHARS, build_overview_prompt, parse_overview

from tests.test_pipeline import MEETING_PLAN, MEETING_SEGMENTS, base_state, classify_response


class OverviewPromptTests(unittest.TestCase):
    def test_prompt_contains_samples_and_type(self):
        text = "\n".join(f"[s{i}] 甲: 内容{i}" for i in range(200))
        prompt = build_overview_prompt(text, "会议")
        self.assertIn("会议", prompt)
        self.assertIn("【开头】", prompt)
        self.assertIn("【中间】", prompt)
        self.assertIn("【结尾】", prompt)
        self.assertIn("总览撰写器", prompt)

    def test_prompt_sampling_budget(self):
        text = "x" * 20000
        prompt = build_overview_prompt(text, "会议")
        # 头 3000 + 中 2000 + 尾 2000，加上模板文字，总长度有界
        self.assertLess(len(prompt), 8000)


class OverviewParseTests(unittest.TestCase):
    def test_parse_normal_json(self):
        self.assertEqual(parse_overview('{"overview":"讨论了部署安排"}'), "讨论了部署安排")

    def test_parse_truncates_at_100_chars(self):
        long_text = "总" * 150
        result = parse_overview(json.dumps({"overview": long_text}))
        self.assertEqual(len(result), MAX_OVERVIEW_CHARS)

    def test_parse_bad_json_returns_none(self):
        self.assertIsNone(parse_overview("不是 JSON"))

    def test_parse_missing_field_returns_none(self):
        self.assertIsNone(parse_overview('{"foo":"bar"}'))


class OverviewNodeTests(unittest.TestCase):
    def test_node_stores_overview_on_success(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了部署排期"}, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        state = base_state(MEETING_SEGMENTS, content_type="meeting")
        nodes.prepare_transcript(state)
        with patch.object(nodes, "call_llm", side_effect=fake):
            state = nodes.generate_overview(state)
        self.assertEqual(state["overview"], "会议确认了部署排期")
        self.assertEqual(state["status"], "success")

    def test_node_llm_failure_yields_none_and_continues(self):
        def fake(prompt, temperature=0.3, deadline=None):
            from agent.llm_client import LLMError
            raise LLMError(LLMError.TIMEOUT, "超时")

        state = base_state(MEETING_SEGMENTS, content_type="meeting")
        nodes.prepare_transcript(state)
        with patch.object(nodes, "call_llm", side_effect=fake):
            state = nodes.generate_overview(state)
        self.assertIsNone(state["overview"])
        self.assertEqual(state["status"], "success")

    def test_node_bad_json_yields_none_and_continues(self):
        def fake(prompt, temperature=0.3, deadline=None):
            return "这不是 JSON"

        state = base_state(MEETING_SEGMENTS, content_type="meeting")
        nodes.prepare_transcript(state)
        with patch.object(nodes, "call_llm", side_effect=fake):
            state = nodes.generate_overview(state)
        self.assertIsNone(state["overview"])
        self.assertEqual(state["status"], "success")


class OverviewEndToEndTests(unittest.TestCase):
    def test_pipeline_renders_overview_bar(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                return json.dumps({"overview": "会议确认了部署排期与分工"}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError(f"未预期的提示词: {prompt[:100]}")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertIn('<div class="sc-overview">', result["html_fragment"])
        self.assertIn("会议确认了部署排期与分工", result["html_fragment"])
        self.assertEqual(result["plan"]["overview"], "会议确认了部署排期与分工")

    def test_pipeline_without_overview_still_renders(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "总览撰写器" in prompt:
                from agent.llm_client import LLMError
                raise LLMError(LLMError.TIMEOUT, "超时")
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError(f"未预期的提示词: {prompt[:100]}")

        with patch.object(nodes, "call_llm", side_effect=fake):
            result = chart_agent.invoke(base_state(MEETING_SEGMENTS))
        self.assertEqual(result["status"], "success")
        self.assertNotIn('<div class="sc-overview">', result["html_fragment"])
        self.assertIn("私有化部署", result["html_fragment"])


if __name__ == "__main__":
    unittest.main()
