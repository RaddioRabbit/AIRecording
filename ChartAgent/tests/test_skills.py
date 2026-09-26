import unittest

from agent.templates import BASE_TEMPLATE, DARK_CSS, render_highlights


def highlights_plan():
    return {
        "chartType": "highlights",
        "title": "重点句子",
        "highlightSentences": [
            {
                "segmentId": "s1",
                "text": "我们决定下周完成部署",
                "speaker": "甲",
                "startTime": 0.0,
                "endTime": 5.0,
                "tag": "关键判断",
            }
        ],
        "truncatedCount": 0,
    }


class RenderFoundationTests(unittest.TestCase):
    def test_render_highlights_outputs_segment_ids(self):
        html = render_highlights(highlights_plan(), "darkCyberpunk", "重点句子")
        self.assertIn('data-segment-ids="s1"', html)
        self.assertIn("我们决定下周完成部署", html)
        self.assertIn("重点句子", html)

    def test_render_highlights_escapes_xss(self):
        plan = highlights_plan()
        plan["highlightSentences"][0]["text"] = "<script>alert(1)</script>"
        html = render_highlights(plan, "darkCyberpunk", "重点句子")
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)

    def test_base_template_is_public(self):
        self.assertIn("smartchart-container", BASE_TEMPLATE)
        self.assertIn("{% block chart_content %}", BASE_TEMPLATE)

    def test_base_template_renders_overview_when_present(self):
        plan = highlights_plan()
        plan["overview"] = "本次录音讨论了私有化部署的排期与分工。"
        html = render_highlights(plan, "darkCyberpunk", "重点句子")
        self.assertIn("sc-overview", html)
        self.assertIn("本次录音讨论了私有化部署的排期与分工。", html)

    def test_base_template_omits_overview_when_absent(self):
        html = render_highlights(highlights_plan(), "darkCyberpunk", "重点句子")
        # 注意：CSS 中恒有 ".sc-overview" 类定义，这里必须断言 HTML 元素不存在
        self.assertNotIn('<div class="sc-overview">', html)

    def test_overview_css_class_exists(self):
        self.assertIn(".sc-overview", DARK_CSS)


from agent.skills import SKILLS, skill_for_chart_type


def other_segments():
    return [
        {"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "嗯，好的"},
        {"id": "s2", "speaker": "甲", "startTime": 5.0, "endTime": 10.0, "text": "我们决定下周完成私有化部署的验收"},
        {"id": "s3", "speaker": "乙", "startTime": 10.0, "endTime": 15.0, "text": "今天天气不错"},
        {"id": "s4", "speaker": "乙", "startTime": 15.0, "endTime": 20.0, "text": "记得提醒我买周五的车票啊"},
    ]


class OtherSkillTests(unittest.TestCase):
    def test_registry_contains_other(self):
        self.assertIs(SKILLS["other"], skill_for_chart_type("highlights"))
        self.assertFalse(SKILLS["other"].uses_llm_extraction)

    def test_extract_deterministic_picks_highlight_sentences(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        self.assertEqual(plan["chartType"], "highlights")
        texts = [s["text"] for s in plan["highlightSentences"]]
        self.assertIn("我们决定下周完成私有化部署的验收", texts)
        self.assertIn("记得提醒我买周五的车票啊", texts)
        self.assertNotIn("嗯，好的", texts)
        self.assertNotIn("今天天气不错", texts)
        # 按时间排序
        starts = [s["startTime"] for s in plan["highlightSentences"]]
        self.assertEqual(starts, sorted(starts))

    def test_extract_deterministic_falls_back_to_any_long_segment(self):
        segments = [{"id": "s1", "speaker": "", "startTime": 0.0, "endTime": 5.0, "text": "随便聊聊今天发生的事情"}]
        plan = SKILLS["other"].extract_deterministic(segments)
        self.assertEqual(len(plan["highlightSentences"]), 1)
        self.assertEqual(plan["highlightSentences"][0]["tag"], "关键要点")

    def test_extract_deterministic_caps_at_12_with_truncated_count(self):
        segments = [
            {"id": f"s{i}", "speaker": "", "startTime": float(i * 5), "endTime": float(i * 5 + 5),
             "text": f"这是第 {i} 条必须关注的重要内容"}
            for i in range(15)
        ]
        plan = SKILLS["other"].extract_deterministic(segments)
        self.assertEqual(len(plan["highlightSentences"]), 12)
        self.assertEqual(plan["truncatedCount"], 3)

    def test_render_shows_truncate_note_when_capped(self):
        segments = [
            {"id": f"s{i}", "speaker": "", "startTime": float(i * 5), "endTime": float(i * 5 + 5),
             "text": f"这是第 {i} 条必须关注的重要内容"}
            for i in range(15)
        ]
        plan = SKILLS["other"].extract_deterministic(segments)
        html = SKILLS["other"].render(plan, "darkCyberpunk", "重点句子")
        self.assertIn("还有 3 条重点句子未展示", html)

    def test_validate_rejects_forged_segment(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        plan["highlightSentences"][0]["segmentId"] = "forged"
        segment_map = {s["id"]: s for s in other_segments()}
        self.assertTrue(SKILLS["other"].validate(plan, segment_map))

    def test_validate_passes_own_output(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        segment_map = {s["id"]: s for s in other_segments()}
        self.assertEqual(SKILLS["other"].validate(plan, segment_map), [])

    def test_validate_passes_highlight_starting_at_zero(self):
        segments = [{"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0, "text": "我们决定下周完成私有化部署的验收"}]
        plan = SKILLS["other"].extract_deterministic(segments)
        segment_map = {s["id"]: s for s in segments}
        self.assertEqual(SKILLS["other"].validate(plan, segment_map), [])

    def test_render_contains_segment_ids(self):
        plan = SKILLS["other"].extract_deterministic(other_segments())
        html = SKILLS["other"].render(plan, "darkCyberpunk", "重点句子")
        self.assertIn("data-segment-ids", html)


from agent.skills.memo import MemoSkill


def memo_raw():
    return {
        "chartType": "idea_card",
        "title": "图表改造想法",
        "coreIdea": "把图表生成按内容类型路由",
        "coreSegmentIds": ["s1"],
        "points": [
            {"text": "分类器要能给其他兜底", "segmentIds": ["s1"]},
            {"text": "参考 supersonic 的规则树", "segmentIds": ["s2", "ghost"]},
        ],
    }


def memo_source_segments():
    return [
        {"id": "s1", "speaker": "", "startTime": 0.0, "endTime": 5.0, "text": "分类器要能给其他兜底，这个很重要"},
        {"id": "s2", "speaker": "", "startTime": 5.0, "endTime": 10.0, "text": "参考 supersonic 的规则树来做"},
    ]


class MemoSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = MemoSkill()
        self.segment_map = {s["id"]: s for s in memo_source_segments()}

    def test_normalize_drops_unknown_segment_ids(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        self.assertEqual(plan["chartType"], "idea_card")
        self.assertEqual(plan["points"][1]["segmentIds"], ["s2"])
        self.assertEqual(plan["coreSegmentIds"], ["s1"])

    def test_normalize_falls_back_core_ids_to_first_segment(self):
        raw = memo_raw()
        raw["coreSegmentIds"] = ["ghost"]
        raw["points"] = []
        plan = self.skill.normalize(raw, memo_source_segments())
        self.assertEqual(plan["coreSegmentIds"], ["s1"])

    def test_normalize_rejects_bad_shape(self):
        with self.assertRaises(ValueError):
            self.skill.normalize({"chartType": "idea_card"}, memo_source_segments())

    def test_merge_dedupes_and_truncates_at_8(self):
        plans = [
            {"chartType": "idea_card", "title": "t", "coreIdea": "c", "coreSegmentIds": ["s1"],
             "points": [{"text": f"要点{i}", "segmentIds": ["s1"]} for i in range(6)], "truncatedCount": 0},
            {"chartType": "idea_card", "title": "t", "coreIdea": "c", "coreSegmentIds": ["s2"],
             "points": [{"text": "要点0", "segmentIds": ["s2"]}] + [{"text": f"要点新{i}", "segmentIds": ["s2"]} for i in range(5)],
             "truncatedCount": 0},
        ]
        merged = self.skill.merge(plans)
        self.assertEqual(len(merged["points"]), 8)
        self.assertEqual(merged["truncatedCount"], 3)  # 11 去重后 10 条 - 8
        self.assertEqual(merged["coreSegmentIds"], ["s1"])

    def test_validate_entry_condition(self):
        self.assertTrue(self.skill.validate({"chartType": "idea_card", "title": "t", "coreIdea": "", "coreSegmentIds": ["s1"], "points": []}, self.segment_map))

    def test_validate_rejects_fabricated_numbers(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["points"][0]["text"] = "下周三前完成 80% 的改造"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_fallback_drops_invalid_points_keeps_core(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["points"][0]["segmentIds"] = ["ghost"]
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(len(salvaged["points"]), 1)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"idea_card"', self.skill.extraction_prompt(memo_source_segments()))

    def test_validate_rejects_fabricated_core_idea_numbers(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["coreIdea"] = "3 天内完成 80% 的改造"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("核心想法" in e and "数字" in e for e in errors))

    def test_fallback_returns_none_when_core_numbers_fabricated(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["coreIdea"] = "3 天内完成 80% 的改造"
        self.assertIsNone(self.skill.fallback(plan, self.segment_map))

    def test_fallback_resets_truncated_count(self):
        plan = self.skill.normalize(memo_raw(), memo_source_segments())
        plan["truncatedCount"] = 5
        plan["points"][0]["segmentIds"] = ["ghost"]
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["truncatedCount"], 0)

    def test_normalize_keeps_point_detail(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "兜底规则在分类失败时接管"
        plan = self.skill.normalize(raw, memo_source_segments())
        self.assertEqual(plan["points"][0]["detail"], "兜底规则在分类失败时接管")

    def test_normalize_truncates_core_idea_and_detail(self):
        raw = memo_raw()
        raw["coreIdea"] = "核" * 50
        raw["points"][0]["text"] = "要" * 50
        raw["points"][0]["detail"] = "详" * 70
        plan = self.skill.normalize(raw, memo_source_segments())
        self.assertEqual(len(plan["coreIdea"]), 40)
        self.assertEqual(len(plan["points"][0]["text"]), 28)
        self.assertEqual(len(plan["points"][0]["detail"]), 60)

    def test_validate_rejects_fabricated_detail_numbers(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "预计节省 30% 成本"
        plan = self.skill.normalize(raw, memo_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("说明" in e and "数字" in e for e in errors))

    def test_fallback_strips_fabricated_detail_keeps_point(self):
        raw = memo_raw()
        raw["points"][0]["detail"] = "预计节省 30% 成本"
        plan = self.skill.normalize(raw, memo_source_segments())
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertIsNone(salvaged["points"][0]["detail"])

    def test_to_mindmap_maps_core_idea_and_points_as_branches(self):
        plan = {
            "chartType": "idea_card", "title": "随手记要点",
            "coreIdea": "图表要按内容类型路由", "coreSegmentIds": ["s1"],
            "points": [
                {"text": "分类器要能给其他兜底", "detail": "否则白屏", "segmentIds": ["s1"]},
                {"text": "渲染统一成思维导图", "detail": None, "segmentIds": ["s2"]},
            ],
        }
        doc = SKILLS["memo"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "图表要按内容类型路由"})
        self.assertEqual([b["id"] for b in doc["branches"]], ["b0", "b1"])
        self.assertEqual(doc["branches"][0]["text"], "分类器要能给其他兜底")
        self.assertEqual(doc["branches"][0]["segment_ids"], ["s1"])
        self.assertEqual(doc["branches"][0]["children"][0]["text"], "否则白屏")
        self.assertEqual(doc["branches"][0]["children"][0]["id"], "b0c0")
        self.assertEqual(doc["branches"][0]["children"][0]["segment_ids"], ["s1"])
        self.assertEqual(doc["branches"][1]["text"], "渲染统一成思维导图")
        self.assertEqual(doc["branches"][1]["children"], [])

    def test_to_mindmap_returns_none_without_core_idea(self):
        self.assertIsNone(SKILLS["memo"].to_mindmap(
            {"chartType": "idea_card", "title": "x", "coreIdea": "", "points": []}))

    def test_to_mindmap_returns_none_without_points(self):
        # 只有 coreIdea 时分支数为 0，交给调用方降级 highlights（设计 §7.3）
        self.assertIsNone(SKILLS["memo"].to_mindmap(
            {"chartType": "idea_card", "title": "x", "coreIdea": "只有核心想法", "points": []}))


from agent.skills.meeting import MeetingSkill


def meeting_raw():
    return {
        "chartType": "decision_board",
        "title": "DeepSeek 部署讨论会",
        "topics": [
            {
                "title": "私有化部署方案",
                "conclusion": "当天完成部署并接入知识库问答",
                "actions": [
                    {"text": "提供可外网访问的电脑", "owner": "李老师", "due": "今天"},
                    {"text": "调研语音卡技术参数", "owner": None, "due": None},
                ],
                "segmentIds": ["s1", "s2"],
            },
            {"title": "幽灵议题", "conclusion": None, "actions": [], "segmentIds": ["ghost"]},
        ],
    }


def meeting_source_segments():
    return [
        {"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 5.0,
         "text": "私有化部署方案今天定一下，结论就是当天完成部署并接入知识库问答"},
        {"id": "s2", "speaker": "乙", "startTime": 5.0, "endTime": 10.0,
         "text": "李老师今天提供可外网访问的电脑，另外还要调研语音卡技术参数"},
    ]


class MeetingSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = MeetingSkill()
        self.segment_map = {s["id"]: s for s in meeting_source_segments()}

    def test_normalize_drops_topic_with_only_unknown_ids(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        self.assertEqual(len(plan["topics"]), 1)
        self.assertEqual(plan["topics"][0]["title"], "私有化部署方案")

    def test_validate_passes_legit_plan(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_at_least_one_topic(self):
        plan = {"chartType": "decision_board", "title": "t", "topics": [], "truncatedCount": 0}
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_action_numbers(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["topics"][0]["actions"][0]["text"] = "3 天内提供 5 台电脑"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_merge_caps_topics_at_8(self):
        big = {"chartType": "decision_board", "title": "t", "truncatedCount": 0, "topics": [
            {"title": f"议题{i}", "conclusion": None, "actions": [], "segmentIds": ["s1"]} for i in range(10)
        ]}
        merged = self.skill.merge([big])
        self.assertEqual(len(merged["topics"]), 8)
        self.assertEqual(merged["truncatedCount"], 2)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"decision_board"', self.skill.extraction_prompt(meeting_source_segments()))

    def test_merge_same_topic_dedupes_actions_and_unions_ids(self):
        plans = [
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "conclusion": None,
                         "actions": [{"text": "提供电脑", "owner": None, "due": None}],
                         "segmentIds": ["s1"]}]},
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "conclusion": None,
                         "actions": [{"text": "提供电脑", "owner": None, "due": None},
                                     {"text": "提供电脑", "owner": None, "due": None},
                                     {"text": "调研参数", "owner": None, "due": None}],
                         "segmentIds": ["s2"]}]},
        ]
        merged = self.skill.merge(plans)
        self.assertEqual(len(merged["topics"]), 1)
        actions = merged["topics"][0]["actions"]
        self.assertEqual([a["text"] for a in actions], ["提供电脑", "调研参数"])
        self.assertEqual(merged["topics"][0]["segmentIds"], ["s1", "s2"])

    def test_validate_rejects_fabricated_due_numbers(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["topics"][0]["actions"][0]["due"] = "3 天后"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("时间数字" in e for e in errors))

    def test_fallback_strips_fabricated_due_keeps_action(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["topics"][0]["actions"][0]["due"] = "3 天后"
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        action = salvaged["topics"][0]["actions"][0]
        self.assertEqual(action["text"], "提供可外网访问的电脑")
        self.assertIsNone(action["due"])

    def test_fallback_resets_truncated_count(self):
        plan = self.skill.normalize(meeting_raw(), meeting_source_segments())
        plan["truncatedCount"] = 4
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["truncatedCount"], 0)

    def test_normalize_keeps_rich_fields(self):
        raw = meeting_raw()
        raw["topics"][0]["background"] = "甲方要求数据不出内网"
        raw["topics"][0]["points"] = ["演示了知识库问答系统", "确认语义模糊匹配可用"]
        raw["topics"][0]["disagreements"] = ["部署时间未达成一致"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        topic = plan["topics"][0]
        self.assertEqual(topic["background"], "甲方要求数据不出内网")
        self.assertEqual(topic["points"], ["演示了知识库问答系统", "确认语义模糊匹配可用"])
        self.assertEqual(topic["disagreements"], ["部署时间未达成一致"])

    def test_normalize_truncates_rich_fields(self):
        raw = meeting_raw()
        raw["topics"][0]["background"] = "背" * 80
        raw["topics"][0]["points"] = ["点" * 80] * 8
        raw["topics"][0]["disagreements"] = ["歧"] * 5
        plan = self.skill.normalize(raw, meeting_source_segments())
        topic = plan["topics"][0]
        self.assertEqual(len(topic["background"]), 60)
        self.assertEqual(len(topic["points"]), 6)
        self.assertTrue(all(len(p) == 60 for p in topic["points"]))
        self.assertEqual(len(topic["disagreements"]), 3)

    def test_validate_rejects_fabricated_point_numbers(self):
        raw = meeting_raw()
        raw["topics"][0]["points"] = ["预算砍了 30%"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("要点" in e and "数字" in e for e in errors))

    def test_merge_same_topic_unions_points_and_disagreements(self):
        plans = [
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "background": None, "points": ["要点甲"], "disagreements": [],
                         "conclusion": None, "actions": [], "segmentIds": ["s1"]}]},
            {"chartType": "decision_board", "title": "t", "truncatedCount": 0,
             "topics": [{"title": "部署", "background": "背景乙", "points": ["要点甲", "要点乙"],
                         "disagreements": ["分歧丙"], "conclusion": "结论乙", "actions": [], "segmentIds": ["s2"]}]},
        ]
        merged = self.skill.merge(plans)
        topic = merged["topics"][0]
        self.assertEqual(topic["points"], ["要点甲", "要点乙"])
        self.assertEqual(topic["disagreements"], ["分歧丙"])
        self.assertEqual(topic["background"], "背景乙")
        self.assertEqual(topic["conclusion"], "结论乙")

    def test_fallback_filters_fabricated_points(self):
        raw = meeting_raw()
        raw["topics"][0]["points"] = ["预算砍了 30%"]
        plan = self.skill.normalize(raw, meeting_source_segments())
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["topics"][0]["points"], [])

    def test_to_mindmap_maps_topics_conclusions_actions(self):
        plan = {
            "chartType": "decision_board",
            "title": "私有化部署讨论会",
            "topics": [
                {"title": "私有化部署", "conclusion": "当天完成部署",
                 "actions": [{"text": "提供一台可外网访问的电脑", "owner": "李老师", "due": "今天"}],
                 "segmentIds": ["s1", "s2"]},
            ],
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "私有化部署讨论会"})
        self.assertEqual(len(doc["branches"]), 1)
        branch = doc["branches"][0]
        self.assertEqual(branch["id"], "b0")
        self.assertEqual(branch["text"], "私有化部署")
        self.assertEqual(branch["segment_ids"], ["s1", "s2"])
        self.assertEqual([c["id"] for c in branch["children"]], ["b0c0", "b0c1"])
        texts = [c["text"] for c in branch["children"]]
        self.assertIn("结论：当天完成部署", texts)
        self.assertIn("提供一台可外网访问的电脑（李老师 · 今天）", texts)

    def test_to_mindmap_topic_without_conclusion_and_actions_has_no_children(self):
        plan = {
            "chartType": "decision_board", "title": "t",
            "topics": [{"title": "待定议题", "conclusion": None, "actions": [], "segmentIds": ["s1"]}],
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        self.assertEqual(doc["branches"][0]["children"], [])

    def test_to_mindmap_returns_none_without_topics(self):
        self.assertIsNone(SKILLS["meeting"].to_mindmap({"chartType": "decision_board", "title": "x", "topics": []}))

    def test_to_mindmap_truncates_long_branch_text(self):
        plan = {
            "chartType": "decision_board", "title": "t",
            "topics": [{"title": "这是一个远远超过二十八个字符限制的会议议题标题文字内容需要截断", "conclusion": None,
                        "actions": [], "segmentIds": ["s1"]}],
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        self.assertEqual(len(doc["branches"][0]["text"]), 29)
        self.assertTrue(doc["branches"][0]["text"].endswith("…"))


from agent.skills.interview import InterviewSkill


def interview_raw():
    return {
        "chartType": "qa_cards",
        "title": "私有化部署访谈",
        "qas": [
            {
                "question": "为什么坚持私有化部署？",
                "answerPoints": ["数据安全是底线，不接受云端方案"],
                "quote": "数据不能出内网，这是红线",
                "tags": ["数据安全"],
                "segmentIds": ["s2"],
            },
            {
                "question": "未来会扩展吗？",
                "answerPoints": ["先小范围试点，稳定后再推广"],
                "quote": "先做 5-6 人的盒子试点",
                "tags": ["扩展", "试点"],
                "segmentIds": ["s4"],
            },
        ],
    }


def interview_source_segments():
    return [
        {"id": "s1", "speaker": "采访者", "startTime": 0.0, "endTime": 5.0, "text": "为什么坚持私有化部署？"},
        {"id": "s2", "speaker": "被访者", "startTime": 5.0, "endTime": 10.0, "text": "数据不能出内网，这是红线，云上大模型再便宜也不用"},
        {"id": "s3", "speaker": "采访者", "startTime": 10.0, "endTime": 15.0, "text": "未来会扩展吗？"},
        {"id": "s4", "speaker": "被访者", "startTime": 15.0, "endTime": 20.0, "text": "先做 5-6 人的盒子试点，稳定后再推广"},
    ]


class InterviewSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = InterviewSkill()
        self.segment_map = {s["id"]: s for s in interview_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_normalize_truncates_answer_points(self):
        raw = interview_raw()
        raw["qas"][0]["answerPoints"] = ["点" * 80] * 7  # → 截到 5 条，每条 70 字
        plan = self.skill.normalize(raw, interview_source_segments())
        self.assertEqual(len(plan["qas"][0]["answerPoints"]), 5)
        self.assertTrue(all(len(p) == 70 for p in plan["qas"][0]["answerPoints"]))

    def test_validate_requires_verbatim_quote(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["quote"] = "数据绝对不能出内网哦"  # 非原文逐字
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e for e in errors))

    def test_validate_requires_two_qa_pairs(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"] = plan["qas"][:1]
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_merge_caps_at_10(self):
        big = {"chartType": "qa_cards", "title": "t", "truncatedCount": 0, "qas": [
            {"question": f"问题{i}？", "answerPoints": ["数据不能出内网，这是红线"], "quote": None,
             "tags": [], "segmentIds": ["s2"]}
            for i in range(12)
        ]}
        merged = self.skill.merge([big])
        self.assertEqual(len(merged["qas"]), 10)
        self.assertEqual(merged["truncatedCount"], 2)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"qa_cards"', self.skill.extraction_prompt(interview_source_segments()))

    def test_fallback_resets_truncated_count(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["truncatedCount"] = 3
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["truncatedCount"], 0)

    def test_validate_rejects_numeric_distortion_in_quote(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][1]["quote"] = "先做 56 人的盒子试点"  # 5-6 → 56 数字扭曲
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e or "数字" in e for e in errors))

    def test_fallback_drops_question_with_fabricated_numbers(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["question"] = "未来会扩展到 99 人吗？"
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNone(salvaged)  # 只剩 1 个问答 → 不满足进入条件

    def test_fallback_rebuilds_filtered_segment_ids(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["segmentIds"] = ["s2", "forged"]
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNotNone(salvaged)
        self.assertEqual(salvaged["qas"][0]["segmentIds"], ["s2"])

    def test_validate_rejects_fabricated_answer_point_numbers(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["answerPoints"] = ["预算砍了 30%"]
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("要点" in e and "数字" in e for e in errors))

    def test_validate_requires_answer_points(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["answerPoints"] = []
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("回答要点" in e for e in errors))

    def test_fallback_drops_qa_when_all_points_fabricated(self):
        plan = self.skill.normalize(interview_raw(), interview_source_segments())
        plan["qas"][0]["answerPoints"] = ["预算砍了 30%"]
        plan["qas"][0]["quote"] = None
        salvaged = self.skill.fallback(plan, self.segment_map)
        self.assertIsNone(salvaged)  # 只剩 1 个问答 → 不满足进入条件

    def test_merge_same_question_unions_points(self):
        plans = [
            {"chartType": "qa_cards", "title": "t", "truncatedCount": 0, "qas": [
                {"question": "为什么私有化？", "answerPoints": ["要点甲"], "quote": None, "tags": [], "segmentIds": ["s2"]}]},
            {"chartType": "qa_cards", "title": "t", "truncatedCount": 0, "qas": [
                {"question": "为什么私有化？", "answerPoints": ["要点甲", "要点乙"], "quote": "原句", "tags": [], "segmentIds": ["s4"]}]},
        ]
        merged = self.skill.merge(plans)
        self.assertEqual(len(merged["qas"]), 1)
        self.assertEqual(merged["qas"][0]["answerPoints"], ["要点甲", "要点乙"])
        self.assertEqual(merged["qas"][0]["quote"], "原句")
        self.assertEqual(merged["qas"][0]["segmentIds"], ["s2", "s4"])

    def test_to_mindmap_maps_qas_answers_quotes_tags(self):
        plan = {
            "chartType": "qa_cards", "title": "部署访谈",
            "qas": [
                {"question": "为什么坚持私有化部署？", "answerPoints": ["数据安全是底线"],
                 "quote": "数据不能出内网，这是红线", "tags": ["数据安全"], "segmentIds": ["s2"]},
                {"question": "未来会扩展吗？", "answerPoints": ["先小范围试点"],
                 "quote": None, "tags": [], "segmentIds": ["s4"]},
            ],
        }
        doc = SKILLS["interview"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "部署访谈"})
        self.assertEqual([b["text"] for b in doc["branches"]], ["为什么坚持私有化部署？", "未来会扩展吗？"])
        first_children = doc["branches"][0]["children"]
        self.assertEqual([c["id"] for c in first_children], ["b0c0", "b0c1", "b0c2"])
        texts = [c["text"] for c in first_children]
        self.assertIn("数据安全是底线", texts)
        self.assertIn("“数据不能出内网，这是红线”", texts)
        self.assertIn("#数据安全", texts)
        self.assertEqual(doc["branches"][1]["children"][0]["text"], "先小范围试点")

    def test_to_mindmap_returns_none_without_qas(self):
        self.assertIsNone(SKILLS["interview"].to_mindmap({"chartType": "qa_cards", "title": "x", "qas": []}))

    def test_to_mindmap_caps_branches_at_eight(self):
        plan = {
            "chartType": "qa_cards", "title": "t",
            "qas": [{"question": f"问题{i}", "answerPoints": [], "quote": None, "tags": [],
                     "segmentIds": [f"s{i}"]} for i in range(10)],
        }
        doc = SKILLS["interview"].to_mindmap(plan)
        self.assertEqual(len(doc["branches"]), 8)


from agent.skills.lecture import LectureSkill


def lecture_raw():
    return {
        "chartType": "knowledge_tree",
        "title": "Transformer 原理精讲",
        "topic": "Transformer 原理",
        "chapters": [
            {
                "title": "注意力机制",
                "concepts": [
                    {"name": "QKV 计算", "segmentIds": ["s1"]},
                    {"name": "多头注意力", "segmentIds": ["s1"]},
                ],
                "segmentIds": ["s1"],
            },
            {
                "title": "位置编码",
                "concepts": [{"name": "正弦编码", "segmentIds": ["s2"]}],
                "segmentIds": ["s2"],
            },
        ],
    }


def lecture_source_segments():
    return [
        {"id": "s1", "speaker": "讲师", "startTime": 0.0, "endTime": 30.0,
         "text": "先讲注意力机制，核心是 QKV 计算，也就是查询键值三路投影，还有多头注意力"},
        {"id": "s2", "speaker": "讲师", "startTime": 30.0, "endTime": 60.0,
         "text": "第二个概念是位置编码，正弦编码用 sin 和 cos 表示位置"},
    ]


class LectureSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = LectureSkill()
        self.segment_map = {s["id"]: s for s in lecture_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_entry_condition(self):
        # 只有一章一概念 → 不满足进入条件
        raw = lecture_raw()
        raw["chapters"] = [raw["chapters"][1]]
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_concept_numbers(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        plan["chapters"][0]["concepts"][0]["name"] = "3 层注意力机制"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("数字" in e for e in errors))

    def test_merge_caps_chapters_at_8(self):
        big = {"chartType": "knowledge_tree", "title": "t", "topic": "t", "truncatedCount": 0, "chapters": [
            {"title": f"章{i}", "concepts": [{"name": f"概念{i}", "note": None, "segmentIds": ["s1"]}], "segmentIds": ["s1"]}
            for i in range(10)
        ]}
        merged = self.skill.merge([big])
        self.assertEqual(len(merged["chapters"]), 8)
        self.assertEqual(merged["truncatedCount"], 2)

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"knowledge_tree"', self.skill.extraction_prompt(lecture_source_segments()))

    def test_normalize_counts_dropped_concepts_in_truncated_count(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"] = raw["chapters"][0]["concepts"] + [
            {"name": f"额外概念{i}", "segmentIds": ["s1"]} for i in range(5)
        ]  # 2 + 5 = 7 个概念，超出上限 6 → 丢弃 1
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["chapters"][0]["concepts"]), 6)
        self.assertEqual(plan["truncatedCount"], 1)

    def test_normalize_truncates_overlong_strings(self):
        raw = lecture_raw()
        raw["topic"] = "这是一个非常非常非常长的讲座主题名称"  # 17 字 → 截到 16
        raw["chapters"][0]["title"] = "这是一个非常非常非常非常长的章节标题"  # 18 字 → 截到 16
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["topic"]), 16)
        self.assertEqual(len(plan["chapters"][0]["title"]), 16)

    def test_normalize_keeps_concept_note_and_chapter_points(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "查询键值三路投影"
        raw["chapters"][0]["points"] = ["注意力机制是 Transformer 的核心"]
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(plan["chapters"][0]["concepts"][0]["note"], "查询键值三路投影")
        self.assertEqual(plan["chapters"][0]["points"], ["注意力机制是 Transformer 的核心"])

    def test_normalize_truncates_note_and_points(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "注" * 50
        raw["chapters"][0]["points"] = ["点"] * 6
        plan = self.skill.normalize(raw, lecture_source_segments())
        self.assertEqual(len(plan["chapters"][0]["concepts"][0]["note"]), 40)
        self.assertEqual(len(plan["chapters"][0]["points"]), 5)

    def test_validate_rejects_fabricated_note_numbers(self):
        raw = lecture_raw()
        raw["chapters"][0]["concepts"][0]["note"] = "分为 3 层结构"
        plan = self.skill.normalize(raw, lecture_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("解释" in e and "数字" in e for e in errors))

    def test_merge_same_chapter_unions_points_and_concepts(self):
        plans = [
            {"chartType": "knowledge_tree", "title": "t", "topic": "t", "truncatedCount": 0,
             "chapters": [{"title": "注意力", "points": ["要点甲"],
                           "concepts": [{"name": "QKV", "note": None, "segmentIds": ["s1"]}], "segmentIds": ["s1"]}]},
            {"chartType": "knowledge_tree", "title": "t", "topic": "t", "truncatedCount": 0,
             "chapters": [{"title": "注意力", "points": ["要点甲", "要点乙"],
                           "concepts": [{"name": "QKV", "note": "三路投影", "segmentIds": ["s1"]},
                                        {"name": "多头", "note": None, "segmentIds": ["s1"]}], "segmentIds": ["s1"]}]},
        ]
        merged = self.skill.merge(plans)
        chapter = merged["chapters"][0]
        self.assertEqual(chapter["points"], ["要点甲", "要点乙"])
        self.assertEqual([c["name"] for c in chapter["concepts"]], ["QKV", "多头"])
        self.assertEqual(chapter["concepts"][0]["note"], "三路投影")

    def test_validate_rejects_fabricated_topic_numbers(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        plan["topic"] = "2024 年 Transformer 原理"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("主题" in e for e in errors))

    def test_fallback_returns_none_when_topic_numbers_fabricated(self):
        plan = self.skill.normalize(lecture_raw(), lecture_source_segments())
        plan["topic"] = "2024 年 Transformer 原理"
        self.assertIsNone(self.skill.fallback(plan, self.segment_map))

    def test_to_mindmap_maps_chapters_and_concepts(self):
        plan = {
            "chartType": "knowledge_tree", "title": "Transformer 精讲", "topic": "Transformer",
            "chapters": [
                {"title": "注意力机制", "points": ["核心讲解"],
                 "concepts": [{"name": "QKV 计算", "note": "查询键值", "segmentIds": ["s2"]}],
                 "segmentIds": ["s2"]},
                {"title": "位置编码", "points": [],
                 "concepts": [{"name": "正弦编码", "note": None, "segmentIds": ["s3"]}],
                 "segmentIds": ["s3"]},
            ],
        }
        doc = SKILLS["lecture"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "Transformer"})
        self.assertEqual([b["id"] for b in doc["branches"]], ["b0", "b1"])
        self.assertEqual(doc["branches"][0]["text"], "注意力机制")
        self.assertEqual(doc["branches"][0]["segment_ids"], ["s2"])
        child = doc["branches"][0]["children"][0]
        self.assertEqual(child["id"], "b0c0")
        self.assertEqual(child["text"], "核心讲解")
        self.assertEqual(child["segment_ids"], ["s2"])
        concept_child = doc["branches"][0]["children"][1]
        self.assertEqual(concept_child["id"], "b0c1")
        self.assertEqual(concept_child["text"], "QKV 计算：查询键值")
        self.assertEqual(concept_child["segment_ids"], ["s2"])
        self.assertEqual(doc["branches"][1]["children"][0]["text"], "正弦编码")

    def test_to_mindmap_uses_title_when_topic_missing(self):
        plan = {"chartType": "knowledge_tree", "title": "备用标题", "topic": "",
                "chapters": [{"title": "章", "points": [], "concepts": [], "segmentIds": ["s1"]}]}
        doc = SKILLS["lecture"].to_mindmap(plan)
        self.assertEqual(doc["root"]["text"], "备用标题")

    def test_to_mindmap_returns_none_without_chapters(self):
        self.assertIsNone(SKILLS["lecture"].to_mindmap(
            {"chartType": "knowledge_tree", "title": "x", "topic": "x", "chapters": []}))


from agent.skills.dialogue import DialogueSkill


def dialogue_raw():
    return {
        "chartType": "topic_swimlane",
        "title": "方案讨论",
        "speakers": ["甲", "乙"],
        "blocks": [
            {"speaker": "甲", "topic": "预算", "summary": "预算有限", "start": 0.0, "end": 10.0, "segmentIds": ["s1"]},
            {"speaker": "乙", "topic": "预算回应", "summary": None, "start": 10.0, "end": 20.0, "segmentIds": ["s2"]},
            {"speaker": "甲", "topic": "进度", "summary": "下周推进", "start": 20.0, "end": 30.0, "segmentIds": ["s3"]},
        ],
    }


def dialogue_source_segments():
    return [
        {"id": "s1", "speaker": "甲", "startTime": 0.0, "endTime": 10.0, "text": "预算确实有限，要省着点用"},
        {"id": "s2", "speaker": "乙", "startTime": 10.0, "endTime": 20.0, "text": "预算这边我来想办法协调"},
        {"id": "s3", "speaker": "甲", "startTime": 20.0, "endTime": 30.0, "text": "那进度我们下周继续推进"},
    ]


class DialogueSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = DialogueSkill()
        self.segment_map = {s["id"]: s for s in dialogue_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_two_speakers_and_three_blocks(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"] = plan["blocks"][:2]
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_block_time_outside_source(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"][0]["start"] = 99.0
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_summary_numbers(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"][0]["summary"] = "预算砍了 30%"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("摘要" in e and "数字" in e for e in errors))

    def test_normalize_keeps_key_points_and_long_summary(self):
        raw = dialogue_raw()
        raw["blocks"][0]["summary"] = "预算确实有限，需要省着点用，各项开支都要重新评估"
        raw["blocks"][0]["keyPoints"] = ["各项开支重新评估"]
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(plan["blocks"][0]["summary"], "预算确实有限，需要省着点用，各项开支都要重新评估")
        self.assertEqual(plan["blocks"][0]["keyPoints"], ["各项开支重新评估"])

    def test_normalize_truncates_rich_fields(self):
        raw = dialogue_raw()
        raw["blocks"][0]["topic"] = "这是一个非常非常长的话题名称"  # 15 字 → 截到 14
        raw["blocks"][0]["summary"] = "摘" * 70
        raw["blocks"][0]["keyPoints"] = ["点" * 60] * 6
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(len(plan["blocks"][0]["topic"]), 14)
        self.assertEqual(len(plan["blocks"][0]["summary"]), 60)
        self.assertEqual(len(plan["blocks"][0]["keyPoints"]), 4)
        self.assertTrue(all(len(p) == 50 for p in plan["blocks"][0]["keyPoints"]))

    def test_validate_rejects_fabricated_key_point_numbers(self):
        raw = dialogue_raw()
        raw["blocks"][0]["keyPoints"] = ["预算砍了 30%"]
        plan = self.skill.normalize(raw, dialogue_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("信息点" in e and "数字" in e for e in errors))

    def test_normalize_merges_overflow_speakers_into_others(self):
        raw = dialogue_raw()
        raw["speakers"] = ["甲", "乙", "丙", "丁", "戊"]
        raw["blocks"].append({"speaker": "戊", "topic": "补充", "summary": None, "start": 30.0, "end": 40.0, "segmentIds": ["s3"]})
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(len(plan["speakers"]), 4)
        self.assertIn("其他人", plan["speakers"])
        self.assertEqual(plan["blocks"][-1]["speaker"], "其他人")

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"topic_swimlane"', self.skill.extraction_prompt(dialogue_source_segments()))

    def test_validate_handles_mixed_known_unknown_segment_ids(self):
        plan = self.skill.normalize(dialogue_raw(), dialogue_source_segments())
        plan["blocks"][0]["segmentIds"] = ["s1", "bogus"]
        errors = self.skill.validate(plan, self.segment_map)  # 不应抛 KeyError
        self.assertIsInstance(errors, list)

    def test_normalize_counts_dropped_blocks_in_truncated_count(self):
        raw = dialogue_raw()
        raw["blocks"].append({"speaker": "甲", "topic": "幽灵", "summary": None, "start": 40.0, "end": 50.0, "segmentIds": ["ghost"]})
        plan = self.skill.normalize(raw, dialogue_source_segments())
        self.assertEqual(plan["truncatedCount"], 1)

    def test_to_mindmap_maps_blocks_with_speaker_time_meta(self):
        plan = {
            "chartType": "topic_swimlane", "title": "项目讨论", "speakers": ["甲", "乙"],
            "blocks": [
                {"speaker": "甲", "topic": "预算", "summary": "预算紧张要想办法", "keyPoints": ["控制开支"],
                 "start": 0.0, "end": 10.0, "segmentIds": ["s1"]},
                {"speaker": "乙", "topic": "进度", "summary": None, "keyPoints": [],
                 "start": 65.0, "end": 90.0, "segmentIds": ["s2"]},
            ],
        }
        doc = SKILLS["dialogue"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "项目讨论"})
        self.assertEqual([b["text"] for b in doc["branches"]], ["预算", "进度"])
        first_texts = [c["text"] for c in doc["branches"][0]["children"]]
        self.assertIn("预算紧张要想办法", first_texts)
        self.assertIn("控制开支", first_texts)
        self.assertIn("甲 · 00:00-00:10", first_texts)
        second_texts = [c["text"] for c in doc["branches"][1]["children"]]
        self.assertEqual(second_texts, ["乙 · 01:05-01:30"])

    def test_to_mindmap_returns_none_without_blocks(self):
        self.assertIsNone(SKILLS["dialogue"].to_mindmap(
            {"chartType": "topic_swimlane", "title": "x", "speakers": [], "blocks": []}))

    def test_to_mindmap_caps_branches_at_eight(self):
        plan = {
            "chartType": "topic_swimlane", "title": "t", "speakers": ["甲"],
            "blocks": [{"speaker": "甲", "topic": f"话题{i}", "summary": None, "keyPoints": [],
                        "start": float(i * 10), "end": float(i * 10 + 5), "segmentIds": [f"s{i}"]}
                       for i in range(12)],
        }
        doc = SKILLS["dialogue"].to_mindmap(plan)
        self.assertEqual(len(doc["branches"]), 8)


from agent.skills.speech import SpeechSkill


def speech_raw():
    return {
        "chartType": "narrative_arc",
        "title": "改变的力量",
        "stages": [
            {"stage": "opening", "label": "一个故事", "summary": "从个人经历讲起", "quote": None, "segmentIds": ["s1"]},
            {"stage": "buildup", "label": "问题浮现", "summary": "现状有多糟", "quote": None, "segmentIds": ["s2"]},
            {"stage": "climax", "label": "顿悟时刻", "summary": "答案就在眼前", "quote": "改变从今晚开始", "segmentIds": ["s3"]},
            {"stage": "closing", "label": "呼吁行动", "summary": "每个人都可以", "quote": None, "segmentIds": ["s4"]},
        ],
    }


def speech_source_segments():
    return [
        {"id": "s1", "speaker": "演讲者", "startTime": 0.0, "endTime": 30.0, "text": "三年前我经历了一件改变我的事"},
        {"id": "s2", "speaker": "演讲者", "startTime": 30.0, "endTime": 60.0, "text": "你会发现现状比我们想象的更糟糕"},
        {"id": "s3", "speaker": "演讲者", "startTime": 60.0, "endTime": 90.0, "text": "所以我说，改变从今晚开始，就在你我手中"},
        {"id": "s4", "speaker": "演讲者", "startTime": 90.0, "endTime": 120.0, "text": "每个人都可以迈出第一步"},
    ]


class SpeechSkillTests(unittest.TestCase):
    def setUp(self):
        self.skill = SpeechSkill()
        self.segment_map = {s["id"]: s for s in speech_source_segments()}

    def test_normalize_and_validate_pass(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        self.assertEqual(self.skill.validate(plan, self.segment_map), [])

    def test_validate_requires_climax_with_verbatim_quote(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"][2]["quote"] = "改变从明天开始"  # 非原文
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e for e in errors))

    def test_validate_requires_three_stages_including_climax(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"] = [s for s in plan["stages"] if s["stage"] != "climax"]
        self.assertTrue(self.skill.validate(plan, self.segment_map))

    def test_validate_rejects_fabricated_summary_numbers(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"][0]["summary"] = "3 年前亏损 500 万"
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("摘要" in e and "数字" in e for e in errors))

    def test_validate_rejects_numeric_distortion_in_climax_quote(self):
        plan = self.skill.normalize(speech_raw(), speech_source_segments())
        plan["stages"][2]["quote"] = "改变从今晚 8 点开始"  # 原文无数字 8
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("逐字" in e or "数字" in e for e in errors))

    def test_extraction_prompt_contains_schema_marker(self):
        self.assertIn('"narrative_arc"', self.skill.extraction_prompt(speech_source_segments()))

    def test_normalize_truncates_label_summary_quote(self):
        raw = speech_raw()
        raw["stages"][0]["label"] = "这是一个非常非常长的小标题"  # 13 字 → 不截断；再验证超长的
        raw["stages"][1]["label"] = "这是一个特别特别特别长的小标题啊"  # 16 字 → 截到 14
        raw["stages"][0]["summary"] = "摘" * 70  # → 截到 60
        raw["stages"][2]["quote"] = "改变从今晚开始" + "句" * 40  # → 截到 40
        raw["stages"][0]["points"] = ["点" * 70] * 7  # → 截到 5 条，每条 60 字
        plan = self.skill.normalize(raw, speech_source_segments())
        self.assertEqual(len(plan["stages"][1]["label"]), 14)
        self.assertEqual(len(plan["stages"][0]["summary"]), 60)
        self.assertEqual(len(plan["stages"][2]["quote"]), 40)
        self.assertEqual(len(plan["stages"][0]["points"]), 5)
        self.assertTrue(all(len(p) == 60 for p in plan["stages"][0]["points"]))

    def test_normalize_keeps_stage_points(self):
        raw = speech_raw()
        raw["stages"][2]["points"] = ["演讲者分享了自己的转折经历", "现场反响热烈"]
        plan = self.skill.normalize(raw, speech_source_segments())
        self.assertEqual(plan["stages"][2]["points"], ["演讲者分享了自己的转折经历", "现场反响热烈"])

    def test_validate_rejects_fabricated_point_numbers(self):
        raw = speech_raw()
        raw["stages"][0]["points"] = ["现场观众 500 人"]
        plan = self.skill.normalize(raw, speech_source_segments())
        errors = self.skill.validate(plan, self.segment_map)
        self.assertTrue(any("要点" in e and "数字" in e for e in errors))

    def test_merge_same_stage_unions_points(self):
        plans = [
            {"chartType": "narrative_arc", "title": "t", "truncatedCount": 0, "stages": [
                {"stage": "climax", "label": "顿悟", "summary": None, "quote": "改变从今晚开始",
                 "points": ["要点甲"], "segmentIds": ["s3"]}]},
            {"chartType": "narrative_arc", "title": "t", "truncatedCount": 0, "stages": [
                {"stage": "climax", "label": "顿悟", "summary": None, "quote": None,
                 "points": ["要点甲", "要点乙"], "segmentIds": ["s4"]}]},
        ]
        merged = self.skill.merge(plans)
        stage = merged["stages"][0]
        self.assertEqual(stage["points"], ["要点甲", "要点乙"])
        self.assertEqual(stage["quote"], "改变从今晚开始")
        self.assertEqual(stage["segmentIds"], ["s3", "s4"])

    def test_to_mindmap_maps_stages_summary_points_quote(self):
        plan = {
            "chartType": "narrative_arc", "title": "改变",
            "stages": [
                {"stage": "opening", "label": "故事", "summary": "三年前的转折", "points": [],
                 "quote": None, "segmentIds": ["s1"]},
                {"stage": "climax", "label": "顿悟", "summary": None, "points": ["现状可改变"],
                 "quote": "改变从今晚开始", "segmentIds": ["s3"]},
            ],
        }
        doc = SKILLS["speech"].to_mindmap(plan)
        self.assertEqual(doc["root"], {"id": "root", "text": "改变"})
        self.assertEqual([b["text"] for b in doc["branches"]], ["故事", "顿悟"])
        self.assertEqual([c["text"] for c in doc["branches"][0]["children"]], ["三年前的转折"])
        climax_texts = [c["text"] for c in doc["branches"][1]["children"]]
        self.assertEqual(climax_texts, ["现状可改变", "“改变从今晚开始”"])
        self.assertEqual(doc["branches"][1]["children"][0]["segment_ids"], ["s3"])

    def test_to_mindmap_returns_none_without_stages(self):
        self.assertIsNone(SKILLS["speech"].to_mindmap(
            {"chartType": "narrative_arc", "title": "x", "stages": []}))


class MeetingMindmapRichnessTests(unittest.TestCase):
    def test_to_mindmap_keeps_background_points_disagreements(self):
        plan = {
            "chartType": "decision_board", "title": "私有化部署讨论会",
            "topics": [{
                "title": "私有化部署",
                "background": "客户要求数据不出内网",
                "points": ["后端需支持离线模型加载", "运维需要一键部署脚本"],
                "disagreements": ["排期是否延到 Q3 未定"],
                "conclusion": "先做网关层改造",
                "actions": [{"text": "输出部署清单", "owner": "张三", "due": "周五前"}],
                "segmentIds": ["s1", "s2"],
            }],
            "truncatedCount": 0,
        }
        doc = SKILLS["meeting"].to_mindmap(plan)
        texts = [c["text"] for c in doc["branches"][0]["children"]]
        self.assertTrue(any(t.startswith("背景：客户要求数据不出内网") for t in texts))
        self.assertTrue(any(t == "后端需支持离线模型加载" for t in texts))
        self.assertTrue(any(t.startswith("分歧：排期是否延到 Q3 未定") for t in texts))
        self.assertTrue(any(t.startswith("结论：先做网关层改造") for t in texts))
        self.assertTrue(any("输出部署清单（张三 · 周五前）" in t for t in texts))
        # 顺序：背景 → 要点 → 分歧 → 结论 → 行动项
        self.assertEqual(texts[0], "背景：客户要求数据不出内网")


class LectureMindmapRichnessTests(unittest.TestCase):
    def test_to_mindmap_maps_points_before_concepts(self):
        plan = {
            "chartType": "knowledge_tree", "title": "编译原理", "topic": "编译原理",
            "chapters": [{
                "title": "词法分析",
                "points": ["有限自动机是词法分析的核心模型", "正则表达式描述词法规则"],
                "concepts": [{"name": "DFA", "note": "确定性有限自动机", "segmentIds": ["s1"]}],
                "segmentIds": ["s1", "s2"],
            }],
            "truncatedCount": 0,
        }
        doc = SKILLS["lecture"].to_mindmap(plan)
        texts = [c["text"] for c in doc["branches"][0]["children"]]
        self.assertEqual(texts[0], "有限自动机是词法分析的核心模型")
        self.assertEqual(texts[1], "正则表达式描述词法规则")
        self.assertEqual(texts[2], "DFA：确定性有限自动机")


class MemoMindmapRichnessTests(unittest.TestCase):
    def test_detail_becomes_child_not_branch_suffix(self):
        plan = {
            "chartType": "idea_card", "title": "随手记要点",
            "coreIdea": "做一个语音复盘工具", "coreSegmentIds": ["s1"],
            "points": [
                {"text": "先做单机版", "detail": "不依赖云端，保护隐私", "segmentIds": ["s1"]},
                {"text": "没有说明的要点", "detail": None, "segmentIds": ["s2"]},
            ],
            "truncatedCount": 0,
        }
        doc = SKILLS["memo"].to_mindmap(plan)
        self.assertEqual(doc["branches"][0]["text"], "先做单机版")
        self.assertEqual(doc["branches"][0]["children"][0]["text"], "不依赖云端，保护隐私")
        self.assertEqual(doc["branches"][0]["children"][0]["id"], "b0c0")
        self.assertEqual(doc["branches"][0]["children"][0]["segment_ids"], ["s1"])
        self.assertEqual(doc["branches"][1]["children"], [])


if __name__ == "__main__":
    unittest.main()
