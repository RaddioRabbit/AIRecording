"""POST /chart/render 契约测试（v5）：纯渲染、零 LLM 调用、extra="forbid"、10s 预算常量。"""
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

import main
from agent import nodes
from main import app


def mindmap_payload(**overrides):
    payload = {
        "version": "5.0",
        "requestId": "render-1",
        "recordingId": "rec-1",
        "theme": "darkCyberpunk",
        "mindMap": {
            "root": {"id": "root", "text": "周会纪要"},
            "branches": [
                {"id": "b0", "text": "议题一", "segment_ids": ["s1"],
                 "children": [{"id": "b0c0", "text": "结论：当天完成", "segment_ids": ["s1"]}]}
            ],
        },
    }
    payload.update(overrides)
    return payload


class ChartRenderEndpointTests(unittest.TestCase):
    def _post(self, payload):
        def forbidden_llm(*args, **kwargs):
            raise AssertionError("/chart/render 不得调用 LLM")

        with patch.object(nodes, "call_llm", side_effect=forbidden_llm):
            return TestClient(app).post("/chart/render", json=payload)

    def test_valid_mindmap_roundtrip(self):
        response = self._post(mindmap_payload())
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["version"], "5.0")
        self.assertEqual(body["requestId"], "render-1")
        self.assertEqual(body["status"], "success")
        self.assertIn("周会纪要", body["htmlFragment"])
        self.assertIn('data-segment-ids="s1"', body["htmlFragment"])
        self.assertIsNone(body["errorCode"])

    def test_extra_field_rejected_422(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"][0]["bogus"] = 1
        self.assertEqual(self._post(payload).status_code, 422)

    def test_root_with_segment_ids_rejected_422(self):
        payload = mindmap_payload()
        payload["mindMap"]["root"]["segment_ids"] = ["s1"]
        self.assertEqual(self._post(payload).status_code, 422)

    def test_missing_mindmap_rejected_422(self):
        payload = mindmap_payload()
        del payload["mindMap"]
        self.assertEqual(self._post(payload).status_code, 422)

    def test_wrong_version_rejected_422(self):
        self.assertEqual(self._post(mindmap_payload(version="4.0")).status_code, 422)

    def test_empty_text_rejected_422(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"][0]["text"] = ""
        self.assertEqual(self._post(payload).status_code, 422)

    def test_empty_branches_render_root_only(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"] = []
        body = self._post(payload).json()
        self.assertEqual(body["status"], "success")
        self.assertIn("周会纪要", body["htmlFragment"])

    def test_arbitrary_segment_ids_pass_format_only_check(self):
        payload = mindmap_payload()
        payload["mindMap"]["branches"][0]["segment_ids"] = ["forged-id-9"]
        body = self._post(payload).json()
        self.assertEqual(body["status"], "success")
        self.assertIn('data-segment-ids="forged-id-9"', body["htmlFragment"])

    def test_xss_text_escaped(self):
        payload = mindmap_payload()
        payload["mindMap"]["root"]["text"] = "<script>alert(1)</script>"
        body = self._post(payload).json()
        self.assertNotIn("<script>", body["htmlFragment"])
        self.assertIn("&lt;script&gt;", body["htmlFragment"])

    def test_top_level_extra_field_rejected_422(self):
        payload = mindmap_payload()
        payload["surprise"] = True
        self.assertEqual(self._post(payload).status_code, 422)

    def test_render_budget_is_ten_seconds(self):
        self.assertEqual(main.RENDER_ENDPOINT_BUDGET_SECONDS, 10.0)


class ChartRenderFailureTests(unittest.TestCase):
    def test_renderer_exception_returns_structured_error(self):
        with patch.object(main.MindMapRenderer, "render", side_effect=RuntimeError("boom")):
            response = TestClient(app).post("/chart/render", json=mindmap_payload())
        body = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(body["status"], "failed")
        self.assertEqual(body["errorCode"], "RENDER_FAILED")
        self.assertEqual(body["htmlFragment"], "")


class GenerateEndpointV5Tests(unittest.TestCase):
    def test_health_reports_v5(self):
        body = TestClient(app).get("/health").json()
        self.assertEqual(body["apiVersion"], "5.0")
        self.assertEqual(body["serviceVersion"], "5.0.0")


if __name__ == "__main__":
    unittest.main()
