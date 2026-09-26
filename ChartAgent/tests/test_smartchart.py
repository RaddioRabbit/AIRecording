import asyncio
import json
import os
import time
import unittest
from unittest.mock import patch

from pydantic import ValidationError

from agent import llm_client, nodes
from agent.graph import chart_agent
from agent.llm_client import LLMError
from fastapi.testclient import TestClient

from main import SmartChartGenerateRequest, SmartChartGenerateResponse, app, health_check


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


class SmartChartLLMClientTests(unittest.TestCase):
    def test_deadline_passed_raises_timeout_without_network_call(self):
        with patch.dict(os.environ, {"OPENAI_API_KEY": "", "OLLAMA_MODEL": "test-model"}):
            with patch("urllib.request.urlopen") as urlopen_mock:
                with self.assertRaises(LLMError) as context:
                    llm_client.call_llm("prompt", deadline=time.monotonic() - 1)
        self.assertEqual(context.exception.code, LLMError.TIMEOUT)
        urlopen_mock.assert_not_called()

    def test_attempt_timeout_respects_remaining_budget(self):
        self.assertEqual(llm_client._attempt_timeout(100.0, 60.0), 60.0)
        self.assertEqual(llm_client._attempt_timeout(30.0, 60.0), 30.0)
        with patch.dict(os.environ, {"CHART_LLM_SINGLE_TIMEOUT": "30"}):
            self.assertEqual(llm_client._single_timeout_cap(), 30.0)

    def test_ollama_single_timeout_is_capped_by_remaining_budget(self):
        captured = {}

        class FakeResponse:
            def read(self):
                return b'{"response": "ok"}'

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

        def fake_urlopen(req, timeout=None):
            captured["timeout"] = timeout
            return FakeResponse()

        with patch.dict(os.environ, {"OPENAI_API_KEY": "", "OLLAMA_MODEL": "test-model"}):
            with patch("urllib.request.urlopen", side_effect=fake_urlopen):
                result = llm_client.call_llm("prompt", deadline=time.monotonic() + 10)

        self.assertEqual(result, "ok")
        self.assertGreater(captured["timeout"], 0)
        self.assertLessEqual(captured["timeout"], 10.5)
        self.assertLess(captured["timeout"], 60)

    def _capture_openai_extra_body(self, env):
        """打桩 openai SDK，返回 create() 实际收到的 extra_body。"""
        captured = {}

        class FakeCompletions:
            def create(self, **kwargs):
                captured["extra_body"] = kwargs.get("extra_body")
                message = type("Message", (), {"content": "ok"})()
                choice = type("Choice", (), {"message": message})()
                return type("Response", (), {"choices": [choice]})()

        class FakeClient:
            def __init__(self, **kwargs):
                self.chat = type("Chat", (), {
                    "completions": FakeCompletions(),
                })()

        with patch.dict(os.environ, env, clear=False):
            if "CHART_LLM_THINKING" not in env:
                os.environ.pop("CHART_LLM_THINKING", None)
            with patch.object(llm_client.openai, "OpenAI", FakeClient):
                llm_client.call_llm("prompt", deadline=time.monotonic() + 10)
        return captured.get("extra_body")

    def test_deepseek_auto_disables_thinking(self):
        extra_body = self._capture_openai_extra_body({
            "OPENAI_API_KEY": "test-key",
            "OPENAI_BASE_URL": "https://api.deepseek.com/v1",
        })
        self.assertEqual(extra_body, {"thinking": {"type": "disabled"}})

    def test_openai_auto_keeps_thinking_untouched(self):
        extra_body = self._capture_openai_extra_body({
            "OPENAI_API_KEY": "test-key",
            "OPENAI_BASE_URL": "https://api.openai.com/v1",
        })
        self.assertIsNone(extra_body)

    def test_thinking_env_overrides_auto_detection(self):
        enabled = self._capture_openai_extra_body({
            "OPENAI_API_KEY": "test-key",
            "OPENAI_BASE_URL": "https://api.deepseek.com/v1",
            "CHART_LLM_THINKING": "enabled",
        })
        self.assertIsNone(enabled)
        disabled = self._capture_openai_extra_body({
            "OPENAI_API_KEY": "test-key",
            "OPENAI_BASE_URL": "https://api.openai.com/v1",
            "CHART_LLM_THINKING": "disabled",
        })
        self.assertEqual(disabled, {"thinking": {"type": "disabled"}})


class SmartChartSchemaV5Tests(unittest.TestCase):
    def test_request_accepts_force_content_type(self):
        payload = {
            "version": "5.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
            "forceContentType": "meeting",
        }
        request = SmartChartGenerateRequest.model_validate(payload)
        self.assertEqual(request.forceContentType, "meeting")

    def test_request_rejects_unknown_content_type(self):
        payload = {
            "version": "5.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
            "forceContentType": "podcast",
        }
        with self.assertRaises(ValidationError):
            SmartChartGenerateRequest.model_validate(payload)

    def test_request_rejects_v3_version(self):
        payload = {
            "version": "3.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
        }
        with self.assertRaises(ValidationError):
            SmartChartGenerateRequest.model_validate(payload)

    def test_request_rejects_extra_fields(self):
        payload = {
            "version": "5.0",
            "requestId": "r1",
            "recordingId": "rec1",
            "segments": [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "测试内容"}],
            "unexpected": 1,
        }
        with self.assertRaises(ValidationError):
            SmartChartGenerateRequest.model_validate(payload)

    def test_response_defaults_content_type_to_other(self):
        response = SmartChartGenerateResponse(
            requestId="r1",
            status="failed",
            chartType="highlights",
            chartTypeDisplayName="重点句子",
            title="生成失败",
            htmlFragment="<div></div>",
            plan={"chartType": "highlights", "title": "生成失败", "highlightSentences": []},
            errors=["x"],
        )
        self.assertEqual(response.contentType, "other")
        self.assertEqual(response.contentTypeDisplayName, "其他")


class SmartChartHealthTests(unittest.TestCase):
    def test_health_reports_v5(self):
        result = asyncio.run(health_check())
        self.assertEqual(result["apiVersion"], "5.0")
        self.assertEqual(result["serviceVersion"], "5.0.0")


class SmartChartTimeBudgetTests(unittest.TestCase):
    def test_extraction_deadline_respects_route_reserve(self):
        deadline = time.monotonic() + 100
        self.assertAlmostEqual(nodes._extraction_deadline(deadline), deadline - nodes.ROUTE_RESERVED_SECONDS, places=2)

    def test_extraction_concurrency_env_clamped(self):
        with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "99"}):
            self.assertEqual(nodes._extraction_concurrency(), 4)
        with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "0"}):
            self.assertEqual(nodes._extraction_concurrency(), 1)

    def test_classify_deadline_capped_at_ten_seconds(self):
        captured = {}

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                captured["deadline"] = deadline
                return classify_response("meeting")
            raise LLMError(LLMError.TIMEOUT, "后续调用不关心")

        far_future = time.monotonic() + 100.0
        with patch.object(nodes, "call_llm", side_effect=fake):
            chart_agent.invoke(base_state(MEETING_SEGMENTS, deadline=far_future))
        self.assertIn("deadline", captured)
        self.assertLessEqual(captured["deadline"], time.monotonic() + 10.0)

    def test_low_budget_skips_repair_llm(self):
        bad_plan = {
            "chartType": "decision_board", "title": "x",
            "topics": [{"title": "部署 100 台", "conclusion": None,
                        "actions": [{"text": "3 天内搞定 100 台电脑", "owner": None, "due": None}],
                        "segmentIds": ["s1"]}],
        }

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if "未通过校验" in prompt:
                raise AssertionError("低预算不应调用修复 LLM")
            if '"decision_board"' in prompt:
                return json.dumps(bad_plan, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        state = base_state(MEETING_SEGMENTS, deadline=time.monotonic() + 5)
        with patch.object(nodes, "ROUTE_RESERVED_SECONDS", 1.0):
            with patch.object(nodes, "call_llm", side_effect=fake):
                result = chart_agent.invoke(state)
        self.assertEqual(result["status"], "success")
        self.assertEqual(result["plan"]["chartType"], "highlights")  # 修复被跳过 → 兜底


class SmartChartEndpointTimeoutTests(unittest.TestCase):
    def test_non_cooperative_graph_cut_off_returns_timeout(self):
        payload = {"version": "5.0", "requestId": "r1", "recordingId": "rec1", "segments": MEETING_SEGMENTS}
        with patch.dict(os.environ, {"CHART_TIME_BUDGET_SECONDS": "3"}):
            with patch("main.chart_agent.invoke", side_effect=lambda state: time.sleep(10)):
                response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "failed")
        self.assertEqual(body["errorCode"], "TIMEOUT")


class SmartChartEndpointRaceTests(unittest.TestCase):
    def test_last_second_extraction_timeout_still_returns_degraded_highlights(self):
        payload = {"version": "5.0", "requestId": "r1", "recordingId": "rec1", "segments": MEETING_SEGMENTS}

        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if deadline is not None:
                time.sleep(max(0.0, deadline - time.monotonic() - 0.2))
            raise LLMError(LLMError.TIMEOUT, "最后一刻超时")

        with patch.dict(os.environ, {"CHART_TIME_BUDGET_SECONDS": "6"}):
            with patch.object(nodes, "ROUTE_RESERVED_SECONDS", 1.0):
                with patch.object(nodes, "call_llm", side_effect=fake):
                    response = TestClient(app).post("/chart/generate", json=payload)
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "success")  # 竞态下也必须返回降级结果而非 TIMEOUT
        self.assertEqual(body["chartType"], "highlights")


class SmartChartLoggingTests(unittest.TestCase):
    def test_pipeline_logs_stages_without_transcript_or_secrets(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return classify_response("meeting")
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with self.assertLogs("chart_agent", level="INFO") as captured:
            with patch.object(nodes, "call_llm", side_effect=fake):
                chart_agent.invoke(base_state(MEETING_SEGMENTS))
        output = "\n".join(captured.output)
        for stage in ("classify_content", "extract_structured", "render"):
            self.assertIn(stage, output)
        self.assertNotIn("李老师今天提供", output)  # 转写原文不得入日志
        self.assertNotIn("Bearer", output)
        self.assertNotIn("sk-", output)

    def test_classify_reason_not_logged(self):
        def fake(prompt, temperature=0.3, deadline=None):
            if "内容分类器" in prompt:
                return json.dumps({"content_type": "meeting", "confidence": 0.9,
                                   "reason": "李老师今天提供电脑"}, ensure_ascii=False)
            if '"decision_board"' in prompt:
                return json.dumps(MEETING_PLAN, ensure_ascii=False)
            raise AssertionError("未预期的提示词")

        with self.assertLogs("chart_agent", level="INFO") as captured:
            with patch.object(nodes, "call_llm", side_effect=fake):
                chart_agent.invoke(base_state(MEETING_SEGMENTS))
        output = "\n".join(captured.output)
        self.assertNotIn("李老师今天提供电脑", output)


if __name__ == "__main__":
    unittest.main()
