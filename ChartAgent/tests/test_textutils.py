import unittest

from agent.textutils import (
    filter_known_segment_ids,
    is_highlight_sentence,
    normalize_text,
    numbers_have_evidence,
    parse_llm_json,
    source_text,
    tag_highlight,
    text_has_evidence,
)


class NormalizeTests(unittest.TestCase):
    def test_normalize_strips_punctuation_and_case(self):
        self.assertEqual(normalize_text(" 你好，World! "), "你好world")
        self.assertEqual(normalize_text(None), "")


class ParseJsonTests(unittest.TestCase):
    def test_parses_fenced_json(self):
        self.assertEqual(parse_llm_json("```json\n{\"a\": 1}\n```"), {"a": 1})

    def test_rejects_empty_and_non_dict(self):
        with self.assertRaises(ValueError):
            parse_llm_json("")
        with self.assertRaises(ValueError):
            parse_llm_json("[1, 2]")


class HighlightRuleTests(unittest.TestCase):
    def test_highlight_needs_marker_or_number(self):
        self.assertTrue(is_highlight_sentence("下个月必须完成私有化部署的验收工作"))
        self.assertTrue(is_highlight_sentence("这个方案可以支持 5 到 6 个人并发使用"))
        self.assertFalse(is_highlight_sentence("好的"))
        self.assertFalse(is_highlight_sentence("今天天气还行吧"))

    def test_tag_highlight_rules(self):
        self.assertEqual(tag_highlight("这个风险很大，可能延期"), "风险")
        self.assertEqual(tag_highlight("我们决定采用方案 B"), "关键判断")
        self.assertEqual(tag_highlight("并发数是 6 人"), "重要数据")
        self.assertEqual(tag_highlight("李老师负责下周完成"), "行动承诺")
        self.assertEqual(tag_highlight("因为成本太高所以放弃"), "因果依据")
        self.assertEqual(tag_highlight("这是一个普通的陈述句子用于测试"), "关键要点")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.segment_map = {
            "s1": {"id": "s1", "text": "我们决定下周完成部署，预算是 5 万元"},
            "s2": {"id": "s2", "text": "好的"},
        }

    def test_text_evidence(self):
        self.assertTrue(text_has_evidence("下周完成部署", ["s1"], self.segment_map))
        self.assertFalse(text_has_evidence("下个月完成部署", ["s1"], self.segment_map))

    def test_numbers_evidence(self):
        self.assertTrue(numbers_have_evidence("预算是 5 万元", ["s1"], self.segment_map))
        self.assertFalse(numbers_have_evidence("预算是 8 万元", ["s1"], self.segment_map))
        self.assertTrue(numbers_have_evidence("没有数字", ["s1"], self.segment_map))

    def test_numbers_evidence_rejects_substring_false_positive(self):
        segment_map = {"s1": {"id": "s1", "text": "预算是 15 万元"}}
        self.assertFalse(numbers_have_evidence("预算是 5 万元", ["s1"], segment_map))
        self.assertTrue(numbers_have_evidence("预算是 15 万元", ["s1"], segment_map))

    def test_filter_known_segment_ids_dedupes_and_drops_unknown(self):
        self.assertEqual(filter_known_segment_ids(["s1", "x9", "s1", "s2"], self.segment_map), ["s1", "s2"])

    def test_source_text_joins_in_order(self):
        self.assertEqual(source_text(["s2", "s1"], self.segment_map), "好的 我们决定下周完成部署，预算是 5 万元")


if __name__ == "__main__":
    unittest.main()
