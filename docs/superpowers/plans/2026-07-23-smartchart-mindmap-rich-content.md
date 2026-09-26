# 智能图表 v6（思维导图丰富化 + 图表缩放）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让思维导图「喂饱」三级结构（映射不丢字段、上限放宽），并给图表加缩放能力（触控板捏合 / ⌘+滚轮 / 工具条按钮）。

**Architecture:** 后端 ChartAgent 改提取提示词、`to_mindmap()` 映射、`mindmap.py` 守卫与布局参数；App 端只加缩放（`ChartWebView` + ViewModel），导图结构/编辑/持久化不动。设计文档：`docs/superpowers/specs/2026-07-23-smartchart-mindmap-rich-content-design.md`。

**Tech Stack:** Python 3.14（ChartAgent，unittest，无 pytest）、Swift 5.9 / SwiftUI / WKWebView（SPM，XCTest）。

**通用命令：**

```bash
# 后端全部测试（无 pytest，用 unittest）
cd ChartAgent && .venv/bin/python -m unittest discover -s tests -v
# App 构建与测试（仓库根目录）
swift build
swift test
```

**任务依赖：** Task 1（守卫参数）必须先做，Task 2-7 的映射依赖新的文字上限；Task 8 回归测试在 2-7 之后；Task 9-10 独立。

---

### Task 1: 渲染层守卫与布局参数放宽

**Files:**
- Modify: `ChartAgent/agent/mindmap.py:16-19`（守卫常量）、`:143`、`:204`（行数上限）
- Test: `ChartAgent/tests/test_mindmap.py`

- [ ] **Step 1: 先改测试（应失败）**

`ChartAgent/tests/test_mindmap.py` 中修改三处现有测试，并新增一个行数测试：

`test_caps_children_and_appends_overflow_note`（29-35 行）改为：

```python
    def test_caps_children_and_appends_overflow_note(self):
        doc = guard_mindmap_doc(make_doc(branch_count=1, children_per_branch=12))
        children = doc["branches"][0]["children"]
        self.assertEqual(len(children), MAX_CHILDREN_PER_BRANCH + 1)
        self.assertEqual(children[-1]["text"], "还有 2 项")
        self.assertEqual(children[-1]["id"], "b0c10")
        self.assertEqual(children[-1]["segment_ids"], [])
```

`test_no_overflow_note_when_within_limit`（37-39 行）改为：

```python
    def test_no_overflow_note_when_within_limit(self):
        doc = guard_mindmap_doc(make_doc(branch_count=1, children_per_branch=10))
        self.assertEqual(len(doc["branches"][0]["children"]), 10)
```

`test_truncates_branch_and_child_text`（41-47 行）改为：

```python
    def test_truncates_branch_and_child_text(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["text"] = "支" * 30
        doc["branches"][0]["children"][0]["text"] = "点" * 85
        guarded = guard_mindmap_doc(doc)
        self.assertEqual(guarded["branches"][0]["text"], "支" * 28 + "…")
        self.assertEqual(guarded["branches"][0]["children"][0]["text"], "点" * 80 + "…")
```

`MindMapNodeHelperTests.test_truncate_mindmap_text_limits`（118-121 行）改为：

```python
    def test_truncate_mindmap_text_limits(self):
        self.assertEqual(BaseSkill.truncate_mindmap_text("支" * 30, is_branch=True), "支" * 28 + "…")
        self.assertEqual(BaseSkill.truncate_mindmap_text("点" * 85, is_branch=False), "点" * 80 + "…")
        self.assertEqual(BaseSkill.truncate_mindmap_text("短文本", is_branch=True), "短文本")
```

在 `MindMapRendererTests` 末尾（`test_empty_segment_ids_render_empty_attribute` 之后）新增：

```python
    def test_child_text_wraps_up_to_six_lines(self):
        doc = make_doc(branch_count=1, children_per_branch=1)
        doc["branches"][0]["children"][0]["text"] = "点" * 80
        layout = layout_mindmap(doc)
        child = next(n for n in layout["nodes"] if n["kind"] == "child")
        self.assertEqual(len(child["lines"]), 5)  # 右列 19 字/行，80 字 → 5 行

        doc["branches"][0]["children"][0]["text"] = "点" * 200
        layout = layout_mindmap(doc)
        child = next(n for n in layout["nodes"] if n["kind"] == "child")
        self.assertEqual(len(child["lines"]), 6)  # 6 行封顶
        self.assertTrue(child["lines"][-1].endswith("…"))
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_mindmap -v`
Expected: 上述改动/新增测试 FAIL（旧上限 6/40/20、3 行）。

- [ ] **Step 3: 改 mindmap.py 参数**

`ChartAgent/agent/mindmap.py` 16-19 行改为：

```python
MAX_BRANCHES = 8
MAX_CHILDREN_PER_BRANCH = 10
MAX_BRANCH_TEXT_LENGTH = 28
MAX_CHILD_TEXT_LENGTH = 80
```

两处要点换行行数上限 3 → 6：

`block_height` 内（143 行附近）：

```python
        total = BRANCH_HEIGHT + sum(
            _child_height(_wrap_text(str(c.get("text", "")), chars, 6)) + CHILD_GAP for c in children
        )
```

`lay_branch` 内（204 行附近）：

```python
            child_lines = _wrap_text(str(child.get("text", "")), chars, 6)
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_mindmap -v`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add ChartAgent/agent/mindmap.py ChartAgent/tests/test_mindmap.py
git commit -m "feat(chart): 思维导图守卫放宽至10要点/80字/28字分支标题，要点最多6行"
```

---

### Task 2: meeting skill 丰富化

**Files:**
- Modify: `ChartAgent/agent/skills/meeting.py:11-14`（常量）、`:16-29`（提示词）、`:77`（normalize 截断）、`:198-217`（to_mindmap）
- Test: `ChartAgent/tests/test_skills.py`

- [ ] **Step 1: 加失败的映射测试**

在 `ChartAgent/tests/test_skills.py` 末尾追加（文件顶部若无 `from agent.skills import SKILLS` 则加上）：

```python
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
```

（若该文件用的是 pytest 风格则保持函数式写法；test 文件均为 unittest，参照同文件其他类的写法。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: 新测试 FAIL（当前 to_mindmap 不映射背景/要点/分歧）。

- [ ] **Step 3: 改常量与提示词**

`meeting.py` 11-14 行：

```python
MAX_TOPICS = 8
MAX_ACTIONS_PER_TOPIC = 6
MAX_POINTS_PER_TOPIC = 6
MAX_DISAGREEMENTS_PER_TOPIC = 3
```

`_PROMPT`（16-29 行）替换为：

```python
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
```

`normalize` 中要点截断（77 行）：`p[:50]` → `p[:60]`。

- [ ] **Step 4: 改 to_mindmap（198-217 行整体替换）**

```python
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
```

- [ ] **Step 5: 跑测试并修复旧断言**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills tests.test_mindmap_pipeline -v`
Expected: 新测试 PASS。若 test_skills.py 中有引用旧上限（4 条要点 / 2 条分歧 / 50 字）的旧断言失败，把断言里的旧值替换为新值（要点 6、分歧 3、要点截断 60 字），不得改实现去迁就旧断言。

- [ ] **Step 6: Commit**

```bash
git add ChartAgent/agent/skills/meeting.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): meeting 导图映射补全背景/要点/分歧，要点上限2-6条60字"
```

---

### Task 3: lecture skill 丰富化

**Files:**
- Modify: `ChartAgent/agent/skills/lecture.py:13`（常量）、`:15-24`（提示词）、`:81`（normalize 截断）、`:191-207`（to_mindmap）
- Test: `ChartAgent/tests/test_skills.py`

- [ ] **Step 1: 加失败的映射测试**

`ChartAgent/tests/test_skills.py` 追加：

```python
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: FAIL（当前 to_mindmap 只映射 concepts，不映射 points）。

- [ ] **Step 3: 改常量、提示词、normalize**

13 行：`MAX_POINTS_PER_CHAPTER = 3` → `MAX_POINTS_PER_CHAPTER = 5`。

`_PROMPT` 第 2 条改为：

```
2. chapters：章节列表，每章 title ≤16字；points 为该章的讲解要点（2-5 条，每条 ≤60字，忠于原文）；concepts 为该章的概念要点，name ≤16字，note 为该概念的一句话解释（≤40字，原文没有解释时为 null）。
```

`_PROMPT` 末尾「4. 只提取原文明确讲到的知识内容，禁止补充原文没有的知识。」之后追加一行：

```
5. 覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
```

`normalize`（81 行）：`p[:50]` → `p[:60]`。

- [ ] **Step 4: 改 to_mindmap 的 children 构造（195-202 行）**

```python
            children: List[Dict[str, Any]] = []
            for point in chapter.get("points", []):
                children.append(self.make_mindmap_node(
                    index, point, chapter.get("segmentIds", []), len(children)))
            for concept in chapter.get("concepts", []):
                text = str(concept.get("name", ""))
                if concept.get("note"):
                    text += "：" + str(concept["note"])
                children.append(self.make_mindmap_node(
                    index, text, concept.get("segmentIds", []), len(children)))
```

- [ ] **Step 5: 跑测试并修复旧断言**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: PASS。旧断言涉及 3 条/50 字上限的，替换为新值（5 条 / 60 字）。

- [ ] **Step 6: Commit**

```bash
git add ChartAgent/agent/skills/lecture.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): lecture 导图补映射章节要点，要点上限2-5条60字"
```

---

### Task 4: dialogue skill 丰富化

**Files:**
- Modify: `ChartAgent/agent/skills/dialogue.py:14`（常量）、`:17-24`（提示词）、`:81`（normalize 截断）
- Test: `ChartAgent/tests/test_skills.py`

说明：dialogue 的 `to_mindmap` 已映射 摘要+全部信息点+说话人时间（186-206 行），无需改。

- [ ] **Step 1: 改常量与提示词**

14 行：`MAX_KEY_POINTS_PER_BLOCK = 2` → `MAX_KEY_POINTS_PER_BLOCK = 4`。

`_PROMPT` 第 2 条中 `keyPoints（该话题的关键信息点，0-2 条，每条 ≤40字，必须来自原文明确表述）` 改为 `keyPoints（该话题的关键信息点，1-4 条，每条 ≤50字，必须来自原文明确表述）`。

`_PROMPT` 在「只输出严格 JSON」之前追加一行要求（保持编号连续，加为最后一条）：

```
覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
```

`normalize`（81 行）：`p[:40]` → `p[:50]`。

- [ ] **Step 2: 跑测试并修复旧断言**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: PASS。旧断言涉及 2 条/40 字上限的，替换为新值（4 条 / 50 字）。

- [ ] **Step 3: Commit**

```bash
git add ChartAgent/agent/skills/dialogue.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): dialogue 信息点上限提至1-4条50字"
```

---

### Task 5: speech skill 丰富化

**Files:**
- Modify: `ChartAgent/agent/skills/speech.py:21`（常量）、`:11-18`（提示词）、`:70`（normalize 截断）
- Test: `ChartAgent/tests/test_skills.py`

说明：speech 的 `to_mindmap` 已映射 摘要+要点+金句，无需改。

- [ ] **Step 1: 改常量与提示词**

21 行：`MAX_POINTS_PER_STAGE = 3` → `MAX_POINTS_PER_STAGE = 5`。

`_PROMPT` 第 1 条中 `points（该段要点，0-3 条，每条 ≤50字，忠于原文）` 改为 `points（该段要点，1-5 条，每条 ≤60字，忠于原文）`。

`_PROMPT` 在「只输出严格 JSON」之前追加一行：

```
覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
```

`normalize`（70 行）：`p[:50]` → `p[:60]`。

- [ ] **Step 2: 跑测试并修复旧断言**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: PASS。旧断言涉及 3 条/50 字上限的，替换为新值（5 条 / 60 字）。

- [ ] **Step 3: Commit**

```bash
git add ChartAgent/agent/skills/speech.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): speech 每段要点上限提至1-5条60字"
```

---

### Task 6: interview skill 丰富化

**Files:**
- Modify: `ChartAgent/agent/skills/interview.py:14`（常量）、`:16-23`（提示词）、`:62`（normalize 截断）
- Test: `ChartAgent/tests/test_skills.py`

说明：interview 的 `to_mindmap` 已映射 要点+金句+标签，无需改。

- [ ] **Step 1: 改常量与提示词**

14 行：`MAX_ANSWER_POINTS = 3` → `MAX_ANSWER_POINTS = 5`。

`_PROMPT` 第 1 条中 `answerPoints（被访者的回答要点，1-3 条，每条 ≤60字，可提炼转述但必须忠于原文）` 改为 `answerPoints（被访者的回答要点，2-5 条，每条 ≤70字，可提炼转述但必须忠于原文）`。

`_PROMPT` 在「只输出严格 JSON」之前追加一行：

```
覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
```

`normalize`（62 行）：`p[:60]` → `p[:70]`。

- [ ] **Step 2: 跑测试并修复旧断言**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: PASS。旧断言涉及 3 条/60 字上限的，替换为新值（5 条 / 70 字）。

- [ ] **Step 3: Commit**

```bash
git add ChartAgent/agent/skills/interview.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): interview 回答要点上限提至2-5条70字"
```

---

### Task 7: memo skill 丰富化（detail 从分支标题解放为子要点）

**Files:**
- Modify: `ChartAgent/agent/skills/memo.py:18-26`（提示词）、`:63`（normalize 截断）、`:146-158`（to_mindmap）
- Test: `ChartAgent/tests/test_skills.py`

背景：memo 的 plan schema 已有 `detail` 字段，但当前 `to_mindmap` 把 `text：detail` 拼进分支标题，被 28 字分支上限截断，这就是「随手记只有一级信息」的根因。

- [ ] **Step 1: 加失败的映射测试**

`ChartAgent/tests/test_skills.py` 追加：

```python
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
        self.assertEqual(doc["branches"][1]["children"], [])
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills -v`
Expected: FAIL（当前 detail 拼进分支 text，children 为空）。

- [ ] **Step 3: 改提示词与 normalize**

`_PROMPT` 第 3 条中 `text（要点，不超过 40 字）` 改为 `text（要点，不超过 28 字）`（分支标题上限 28 字，避免生成即被截断）；同条末尾的纪律保持。在「禁止编造原文没有的内容」一行后追加：

```
覆盖原文所有关键信息，宁多勿漏；每条要点必须言之有物，带具体事实、数字、人名、结论，禁止空话。
```

`normalize`（63 行）：`"text": point.text[:40]` → `"text": point.text[:28]`。

- [ ] **Step 4: 改 to_mindmap（146-158 行整体替换）**

```python
    def to_mindmap(self, plan: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        core_idea = str(plan.get("coreIdea", "")).strip()
        if not core_idea:
            return None
        branches = []
        for index, point in enumerate(plan.get("points", [])[:MAX_BRANCHES]):
            branch = self.make_mindmap_node(index, point.get("text", ""), point.get("segmentIds", []))
            if point.get("detail"):
                branch["children"] = [
                    self.make_mindmap_node(index, point["detail"], point.get("segmentIds", []), 0)
                ]
            branches.append(branch)
        if not branches:
            return None
        return {"root": {"id": "root", "text": core_idea}, "branches": branches}
```

- [ ] **Step 5: 跑测试并修复旧断言**

Run: `cd ChartAgent && .venv/bin/python -m unittest tests.test_skills tests.test_mindmap_pipeline -v`
Expected: PASS。旧断言涉及要点 40 字或「text：detail 拼接」的，替换为新行为（28 字 / detail 为子要点）。

- [ ] **Step 6: Commit**

```bash
git add ChartAgent/agent/skills/memo.py ChartAgent/tests/test_skills.py
git commit -m "feat(chart): memo 要点说明从分支标题解放为子要点，要点标题限28字"
```

---

### Task 8: 丰富度回归测试（流水线级）

**Files:**
- Test: `ChartAgent/tests/test_mindmap_pipeline.py`

- [ ] **Step 1: 加回归测试**

`ChartAgent/tests/test_mindmap_pipeline.py` 中 `MindmapNormalizeNodeTests` 类内追加：

```python
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
```

- [ ] **Step 2: 跑后端全量测试**

Run: `cd ChartAgent && .venv/bin/python -m unittest discover -s tests -v`
Expected: 全部 PASS。

- [ ] **Step 3: Commit**

```bash
git add ChartAgent/tests/test_mindmap_pipeline.py
git commit -m "test(chart): 导图丰富度流水线回归测试（全字段映射+要点数下限）"
```

---

### Task 9: App 端图表缩放（捏合 / ⌘+滚轮 / 按钮）

**Files:**
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`（缩放状态 + 导出复位）
- Modify: `AIRecording/Views/ChartWebView.swift`（zoomLevel 参数、allowsMagnification、⌘+滚轮监听）
- Modify: `AIRecording/Views/RecordingDetailView.swift:446-479`（头部缩放按钮、传参）
- Test: `Tests/AIRecordingTests/ChartZoomTests.swift`（新建）

- [ ] **Step 1: 先写失败的测试**

新建 `Tests/AIRecordingTests/ChartZoomTests.swift`：

```swift
import CoreData
import XCTest
@testable import AIRecording

@MainActor
final class ChartZoomTests: XCTestCase {
    private func makeViewModel() -> RecordingDetailViewModel {
        let controller = PersistenceController(inMemory: true)
        let recording = Recording(context: controller.container.viewContext)
        recording.id = UUID()
        return RecordingDetailViewModel(objectID: recording.objectID)
    }

    func testClampChartZoomBounds() {
        XCTAssertEqual(RecordingDetailViewModel.clampChartZoom(0.1), 0.5)
        XCTAssertEqual(RecordingDetailViewModel.clampChartZoom(9.9), 3.0)
        XCTAssertEqual(RecordingDetailViewModel.clampChartZoom(1.2), 1.2)
    }

    func testZoomInOutStepAndClamp() {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.chartZoom, 1.0)
        viewModel.zoomInChart()
        XCTAssertEqual(viewModel.chartZoom, 1.25)
        viewModel.zoomOutChart()
        viewModel.zoomOutChart()
        XCTAssertEqual(viewModel.chartZoom, 0.75)
        for _ in 0..<10 { viewModel.zoomOutChart() }
        XCTAssertEqual(viewModel.chartZoom, 0.5)
        for _ in 0..<20 { viewModel.zoomInChart() }
        XCTAssertEqual(viewModel.chartZoom, 3.0)
    }

    func testResetChartZoom() {
        let viewModel = makeViewModel()
        viewModel.zoomInChart()
        viewModel.resetChartZoom()
        XCTAssertEqual(viewModel.chartZoom, 1.0)
    }

    func testSetChartZoomClamps() {
        let viewModel = makeViewModel()
        viewModel.setChartZoom(4.2)
        XCTAssertEqual(viewModel.chartZoom, 3.0)
        viewModel.setChartZoom(0.05)
        XCTAssertEqual(viewModel.chartZoom, 0.5)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `swift test --filter ChartZoomTests`
Expected: 编译错误（`clampChartZoom` 等不存在）。

- [ ] **Step 3: ViewModel 加缩放状态**

`AIRecording/ViewModels/RecordingDetailViewModel.swift` 在 `// MARK: - Mind Map Editing (v5)` 之前插入：

```swift
    // MARK: - Chart Zoom (v6)

    static let chartZoomRange: ClosedRange<Double> = 0.5...3.0
    static let chartZoomStep: Double = 0.25

    @Published var chartZoom: Double = 1.0

    static func clampChartZoom(_ value: Double) -> Double {
        min(chartZoomRange.upperBound, max(chartZoomRange.lowerBound, value))
    }

    /// 以 WebView 当前实际缩放为基准步进（触控板捏合直接改 WebView，按钮以它为准自愈）。
    func zoomInChart() { chartZoom = Self.clampChartZoom(currentChartMagnification() + Self.chartZoomStep) }
    func zoomOutChart() { chartZoom = Self.clampChartZoom(currentChartMagnification() - Self.chartZoomStep) }
    func resetChartZoom() { chartZoom = 1.0 }

    /// ⌘+滚轮直接改了 WebView 后回写，保持百分比显示一致。
    func setChartZoom(_ value: Double) { chartZoom = Self.clampChartZoom(value) }

    private func currentChartMagnification() -> Double {
        ChartWebView.currentWebView?.magnification ?? chartZoom
    }
```

- [ ] **Step 4: 导出 PNG 前复位缩放**

同文件 `exportMindMapPNG()` 中，`guard await flushPendingMindMapRender() else { return }` 之后、`do {` 之前插入：

```swift
        // 快照不受用户缩放影响：临时归 1.0，导完恢复。
        let previousMagnification = webView.magnification
        webView.magnification = 1.0
        defer { webView.magnification = previousMagnification }
```

（放在 flush 之后：flush 触发的重渲染会走 updateNSView 重新应用 chartZoom，提前复位会被覆盖。）

- [ ] **Step 5: ChartWebView 支持缩放**

`AIRecording/Views/ChartWebView.swift` 顶部结构体改为：

```swift
struct ChartWebView: NSViewRepresentable {
    let htmlContent: String
    var zoomLevel: Double = 1.0
    var onZoomChanged: ((Double) -> Void)?
    var onSegmentTap: (([String]) -> Void)?
```

`makeNSView` 中 `webView.navigationDelegate = context.coordinator` 之后、`return webView` 之前插入：

```swift
        webView.allowsMagnification = true
        context.coordinator.scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak webView, weak coordinator = context.coordinator] event in
            guard let webView, event.window === webView.window,
                  event.modifierFlags.contains(.command) else { return event }
            let locationInView = webView.convert(event.locationInWindow, from: nil)
            guard webView.bounds.contains(locationInView) else { return event }
            let delta: Double = event.scrollingDeltaY > 0 ? 0.1 : -0.1
            let newValue = RecordingDetailViewModel.clampChartZoom(webView.magnification + delta)
            webView.setMagnification(newValue, centeredAt: locationInView)
            coordinator?.onZoomChanged?(newValue)
            return nil
        }
```

`updateNSView` 开头改为：

```swift
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onSegmentTap = onSegmentTap
        context.coordinator.onZoomChanged = onZoomChanged
        if abs(webView.magnification - zoomLevel) > 0.001 {
            webView.magnification = zoomLevel
        }
```

`dismantleNSView` 中 `webView.stopLoading()` 之后插入：

```swift
        if let monitor = coordinator.scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.scrollWheelMonitor = nil
        }
```

`Coordinator` 类中 `var loadedHTML: String?` 之后插入：

```swift
        var onZoomChanged: ((Double) -> Void)?
        var scrollWheelMonitor: Any?
```

- [ ] **Step 6: 头部工具条加缩放按钮 + 传参**

`AIRecording/Views/RecordingDetailView.swift` 的 `chartPanelView` 中，`ChartWebView(` 调用改为：

```swift
                ChartWebView(
                    htmlContent: viewModel.chartHtmlFragment ?? "",
                    zoomLevel: viewModel.chartZoom,
                    onZoomChanged: { viewModel.setChartZoom($0) },
                    onSegmentTap: { segmentIds in
                        viewModel.seekToEarliestSegment(segmentIds)
                    }
                )
```

头部 `HStack(spacing: 8)` 内（446-479 行），`Button("导出 PNG")` 之前插入：

```swift
                    Button {
                        viewModel.zoomOutChart()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        viewModel.resetChartZoom()
                    } label: {
                        Text(viewModel.chartZoom, format: .percent.precision(.fractionLength(0)))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        viewModel.zoomInChart()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
```

- [ ] **Step 7: 跑测试**

Run: `swift build && swift test`
Expected: 构建成功，全部测试 PASS（含新 ChartZoomTests 4 个）。

- [ ] **Step 8: 人工验证（执行者跑 App 目测）**

构建运行 App，打开一条有图表的录音：触控板捏合可缩放；⌘+滚轮以鼠标为中心缩放；按钮步进 0.25、点百分比复位；导出 PNG 为完整尺寸原图。此步无法自动化，标记 DONE_WITH_CONCERNS 时须注明是否已目测。

- [ ] **Step 9: Commit**

```bash
git add AIRecording/ViewModels/RecordingDetailViewModel.swift AIRecording/Views/ChartWebView.swift AIRecording/Views/RecordingDetailView.swift Tests/AIRecordingTests/ChartZoomTests.swift
git commit -m "feat(chart): 图表缩放（触控板捏合/⌘滚轮/工具条按钮），导出PNG自动复位缩放"
```

---

### Task 10: 更新 AGENTS.md 设计文档清单

**Files:**
- Modify: `AGENTS.md`（Design docs 一节）

- [ ] **Step 1: 追加 v6 条目**

`AGENTS.md` 的 `## Design docs` 列表末尾（v5 条目之后）追加：

```markdown
- `docs/superpowers/specs/2026-07-23-smartchart-mindmap-rich-content-design.md` — 智能图表 v6（导图内容丰富化 + 图表缩放，实施计划见 `docs/superpowers/plans/2026-07-23-smartchart-mindmap-rich-content.md`）
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: AGENTS.md 设计文档清单补 v6 条目"
```

---

## 收尾检查

- [ ] `cd ChartAgent && .venv/bin/python -m unittest discover -s tests -v` 全绿
- [ ] `swift build && swift test` 全绿
- [ ] 生成耗时观测：生成一张图，确认耗时上升在 20%-40% 预期内（日志 `chart` category 有 durationMs）
