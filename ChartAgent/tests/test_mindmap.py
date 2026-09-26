"""MindMapDoc 规模守卫与思维导图渲染器测试（v5）。不涉及 LLM。"""
import unittest

from agent.mindmap import (
    MAX_BRANCHES,
    MAX_CHILDREN_PER_BRANCH,
    MindMapRenderer,
    guard_mindmap_doc,
    layout_mindmap,
)


def make_doc(branch_count=2, children_per_branch=2):
    branches = []
    for b in range(branch_count):
        children = [
            {"id": f"b{b}c{c}", "text": f"要点{b}-{c}", "segment_ids": [f"s{b}{c}"]}
            for c in range(children_per_branch)
        ]
        branches.append({"id": f"b{b}", "text": f"分支{b}", "segment_ids": [f"s{b}"], "children": children})
    return {"root": {"id": "root", "text": "测试主题"}, "branches": branches}


class MindMapGuardTests(unittest.TestCase):
    def test_caps_branches_at_eight(self):
        doc = guard_mindmap_doc(make_doc(branch_count=11, children_per_branch=0))
        self.assertEqual(len(doc["branches"]), MAX_BRANCHES)

    def test_caps_children_and_appends_overflow_note(self):
        doc = guard_mindmap_doc(make_doc(branch_count=1, children_per_branch=12))
        children = doc["branches"][0]["children"]
        self.assertEqual(len(children), MAX_CHILDREN_PER_BRANCH + 1)
        self.assertEqual(children[-1]["text"], "还有 2 项")
        self.assertEqual(children[-1]["id"], "b0c10")
        self.assertEqual(children[-1]["segment_ids"], [])

    def test_no_overflow_note_when_within_limit(self):
        doc = guard_mindmap_doc(make_doc(branch_count=1, children_per_branch=10))
        self.assertEqual(len(doc["branches"][0]["children"]), 10)

    def test_truncates_branch_and_child_text(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["text"] = "支" * 30
        doc["branches"][0]["children"][0]["text"] = "点" * 85
        guarded = guard_mindmap_doc(doc)
        self.assertEqual(guarded["branches"][0]["text"], "支" * 28 + "…")
        self.assertEqual(guarded["branches"][0]["children"][0]["text"], "点" * 80 + "…")

    def test_regenerates_sequential_child_ids(self):
        doc = make_doc(branch_count=1, children_per_branch=2)
        doc["branches"][0]["children"][0]["id"] = "weird"
        guarded = guard_mindmap_doc(doc)
        self.assertEqual([c["id"] for c in guarded["branches"][0]["children"]], ["b0c0", "b0c1"])


class MindMapRendererTests(unittest.TestCase):
    def test_minimal_doc_renders_with_segment_ids(self):
        html = MindMapRenderer().render(make_doc(), "darkCyberpunk", "测试主题")
        self.assertIn("<svg", html)
        self.assertIn('data-segment-ids="s0"', html)
        self.assertIn('data-segment-ids="s00"', html)
        self.assertIn("思维导图", html)
        self.assertIn("测试主题", html)

    def test_renders_empty_branches_doc(self):
        doc = {"root": {"id": "root", "text": "只有主题"}, "branches": []}
        html = MindMapRenderer().render(doc, "darkCyberpunk", "只有主题")
        self.assertIn("<svg", html)
        self.assertIn("只有主题", html)
        self.assertIn("data-segment-ids", html)

    def test_escapes_xss_in_all_text_fields(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["root"]["text"] = "<script>alert(1)</script>"
        doc["branches"][0]["text"] = "<img src=x onerror=alert(1)>"
        doc["branches"][0]["children"][0]["text"] = "<b>bold</b>"
        html = MindMapRenderer().render(doc, "darkCyberpunk", "t")
        self.assertNotIn("<script>", html)
        self.assertNotIn("<img src=x", html)
        self.assertNotIn("<b>bold</b>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_odd_branch_count_gives_right_side_one_more(self):
        layout = layout_mindmap(make_doc(branch_count=5, children_per_branch=1))
        sides = [node["side"] for node in layout["nodes"] if node["kind"] == "branch"]
        self.assertEqual(sides.count("right"), 3)
        self.assertEqual(sides.count("left"), 2)

    def test_even_branch_count_splits_evenly(self):
        layout = layout_mindmap(make_doc(branch_count=4, children_per_branch=0))
        sides = [node["side"] for node in layout["nodes"] if node["kind"] == "branch"]
        self.assertEqual(sides.count("right"), 2)
        self.assertEqual(sides.count("left"), 2)

    def test_viewbox_grows_with_content_and_width_fixed(self):
        small = layout_mindmap(make_doc(branch_count=1, children_per_branch=1))
        large = layout_mindmap(make_doc(branch_count=8, children_per_branch=6))
        self.assertGreater(large["height"], small["height"])
        self.assertEqual(large["width"], 1200.0)

    def test_empty_segment_ids_render_empty_attribute(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["children"][0]["segment_ids"] = []
        html = MindMapRenderer().render(doc, "darkCyberpunk", "t")
        self.assertIn('data-segment-ids=""', html)

    def test_child_text_wraps_up_to_six_lines(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["children"][0]["text"] = "点" * 80
        layout = layout_mindmap(doc)
        child = next(n for n in layout["nodes"] if n["kind"] == "child")
        self.assertEqual(child["side"], "right")
        self.assertEqual(len(child["lines"]), 5)  # 右列 19 字/行，80 字 → 5 行

        doc["branches"][0]["children"][0]["text"] = "点" * 200
        layout = layout_mindmap(doc)
        child = next(n for n in layout["nodes"] if n["kind"] == "child")
        self.assertEqual(child["side"], "right")
        self.assertEqual(len(child["lines"]), 6)  # 6 行封顶
        self.assertTrue(child["lines"][-1].endswith("…"))

    def test_left_child_text_wraps_at_fifteen_chars_per_line(self):
        doc = make_doc(branch_count=2, children_per_branch=1)  # 1 左 1 右，branches[0] 落左侧
        doc["branches"][0]["children"][0]["text"] = "点" * 80
        layout = layout_mindmap(doc)
        left_child = next(n for n in layout["nodes"] if n["kind"] == "child" and n["side"] == "left")
        self.assertEqual(len(left_child["lines"]), 6)  # 左列 15 字/行，80 字 → 6 行


from agent.skills import SKILLS
from agent.skills.base import BaseSkill


class MindMapNodeHelperTests(unittest.TestCase):
    def test_make_node_id_path_style(self):
        self.assertEqual(BaseSkill.make_node_id(0), "b0")
        self.assertEqual(BaseSkill.make_node_id(0, 2), "b0c2")
        self.assertEqual(BaseSkill.make_node_id(7, 5), "b7c5")

    def test_truncate_mindmap_text_limits(self):
        self.assertEqual(BaseSkill.truncate_mindmap_text("支" * 30, is_branch=True), "支" * 28 + "…")
        self.assertEqual(BaseSkill.truncate_mindmap_text("点" * 85, is_branch=False), "点" * 80 + "…")
        self.assertEqual(BaseSkill.truncate_mindmap_text("短文本", is_branch=True), "短文本")

    def test_make_mindmap_node_branch_has_children_list(self):
        node = SKILLS["meeting"].make_mindmap_node(1, "议题", ["s1"])
        self.assertEqual(node, {"id": "b1", "text": "议题", "segment_ids": ["s1"], "children": []})

    def test_make_mindmap_node_child_has_no_children_key(self):
        node = SKILLS["meeting"].make_mindmap_node(1, "要点", ["s2"], 0)
        self.assertEqual(node, {"id": "b1c0", "text": "要点", "segment_ids": ["s2"]})
        self.assertNotIn("children", node)

    def test_base_skill_to_mindmap_defaults_to_none(self):
        self.assertIsNone(SKILLS["other"].to_mindmap({"chartType": "highlights", "title": "x"}))


if __name__ == "__main__":
    unittest.main()
