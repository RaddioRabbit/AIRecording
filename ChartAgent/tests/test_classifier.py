import json
import unittest
from unittest.mock import patch

from agent import classifier
from agent.llm_client import LLMError


def make_segments(count=3, speakers=("甲", "乙")):
    return [
        {
            "id": f"s{i}",
            "speaker": speakers[i % len(speakers)],
            "startTime": float(i * 5),
            "endTime": float(i * 5 + 5),
            "text": f"第{i}段内容，讨论部署方案与分工安排。",
        }
        for i in range(count)
    ]


class ClassifyContentTests(unittest.TestCase):
    def test_returns_classified_type_when_confident(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "meeting", "confidence": 0.9, "reason": "有议题和分工"}, ensure_ascii=False
        )):
            content_type, confidence, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "meeting")
        self.assertAlmostEqual(confidence, 0.9)
        self.assertEqual(reason, "有议题和分工")

    def test_low_confidence_falls_back_to_other(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "meeting", "confidence": 0.5, "reason": "不确定"}
        )):
            content_type, _, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")
        self.assertTrue(reason.startswith("low_confidence"))

    def test_confidence_exactly_at_threshold_is_accepted(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "lecture", "confidence": 0.6, "reason": "ok"}
        )):
            content_type, _, _ = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "lecture")

    def test_out_of_range_confidence_clamped(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "meeting", "confidence": 99, "reason": "x"}
        )):
            content_type, confidence, _ = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual((content_type, confidence), ("meeting", 1.0))

    def test_llm_failure_returns_other(self):
        with patch.object(classifier, "call_llm", side_effect=LLMError(LLMError.TIMEOUT, "超时")):
            content_type, confidence, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual((content_type, confidence), ("other", 0.0))
        self.assertTrue(reason.startswith("classify_failed"))

    def test_invalid_json_returns_other(self):
        with patch.object(classifier, "call_llm", return_value="不是 JSON"):
            content_type, _, _ = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")

    def test_unknown_type_returns_other(self):
        with patch.object(classifier, "call_llm", return_value=json.dumps(
            {"content_type": "podcast", "confidence": 0.99, "reason": "x"}
        )):
            content_type, _, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")
        self.assertTrue(reason.startswith("unknown_type"))

    def test_prompt_contains_metadata_and_samples(self):
        captured = {}

        def fake_llm(prompt, temperature=0.3, deadline=None):
            captured["prompt"] = prompt
            return json.dumps({"content_type": "other", "confidence": 0.1, "reason": "x"})

        long_text = "开" * 2500 + "中" * 2000 + "尾" * 1500
        with patch.object(classifier, "call_llm", side_effect=fake_llm):
            classifier.classify_content(make_segments(count=4, speakers=("甲", "乙", "丙")), long_text)
        prompt = captured["prompt"]
        self.assertIn("内容分类器", prompt)
        self.assertIn("说话人数 3", prompt)
        self.assertIn("片段数 4", prompt)
        self.assertIn("【开头】", prompt)
        self.assertIn("【中间】", prompt)
        self.assertIn("【结尾】", prompt)

    def test_short_text_not_split_into_middle_tail(self):
        captured = {}

        def fake_llm(prompt, temperature=0.3, deadline=None):
            captured["prompt"] = prompt
            return json.dumps({"content_type": "memo", "confidence": 0.9, "reason": "短"})

        with patch.object(classifier, "call_llm", side_effect=fake_llm):
            classifier.classify_content(make_segments(count=1, speakers=("甲",)), "很短的转写")
        self.assertNotIn("【中间】", captured["prompt"])

    def test_nan_confidence_falls_back_to_other(self):
        with patch.object(classifier, "call_llm", return_value='{"content_type": "meeting", "confidence": NaN, "reason": "x"}'):
            content_type, _, reason = classifier.classify_content(make_segments(), "转写文本")
        self.assertEqual(content_type, "other")
        self.assertTrue(reason.startswith("low_confidence"))

    def test_malformed_segments_never_raise(self):
        bad_segments = [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": "abc", "text": "内容"}]
        with patch.object(classifier, "call_llm", return_value='{"content_type": "meeting", "confidence": 0.9}'):
            content_type, confidence, reason = classifier.classify_content(bad_segments, "转写文本")
        self.assertEqual((content_type, confidence), ("other", 0.0))
        self.assertTrue(reason.startswith("classify_failed"))

    def test_prompt_contains_total_char_count(self):
        captured = {}

        def fake_llm(prompt, temperature=0.3, deadline=None):
            captured["prompt"] = prompt
            return json.dumps({"content_type": "memo", "confidence": 0.9, "reason": "x"})

        with patch.object(classifier, "call_llm", side_effect=fake_llm):
            classifier.classify_content(make_segments(count=1, speakers=("甲",)), "很短的转写")
        self.assertIn("总字符数", captured["prompt"])


if __name__ == "__main__":
    unittest.main()
