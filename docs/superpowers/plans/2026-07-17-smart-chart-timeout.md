# 智能图表超时根治 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **本会话规则：** 任何 `git commit` 之前必须得到用户明确确认。未获确认时，执行者跳过所有 commit 步骤，保留工作区改动。

**Goal:** 消除智能图表端点的截止竞态，让长录音在 105s 预算内产出真图表，兜底降级结果必定送达；默认模型切换为 deepseek-v4-flash。

**Architecture:** 后端 FastAPI（`ChartAgent/main.py`）把图内部 deadline 提前到 `wait_for` 之前 2s；`nodes.py` 加大分块（5000→12000）与提取并发（2→4）；Swift 三处默认模型改为 deepseek-v4-flash，并迁移已存储的 UserDefaults。

**Tech Stack:** Python 3（FastAPI、langgraph、pytest、fastapi.testclient）、Swift（SwiftPM、XCTest）。

**依据：** `docs/superpowers/specs/2026-07-17-smart-chart-timeout-design.md`

**基线（已验证）：** `cd ChartAgent && /opt/anaconda3/bin/python3 -m pytest tests/test_smartchart.py -q` → 35 passed。

---

### Task 1: 竞态回归测试（先失败）

**Files:**
- Modify: `ChartAgent/tests/test_smartchart.py`

- [ ] **Step 1: 扩展 main 导入**

文件头部第 16 行附近，把：

```python
from main import SmartChartGenerateRequest, health_check
```

改为：

```python
from fastapi.testclient import TestClient

from main import SmartChartGenerateRequest, app, health_check
```

- [ ] **Step 2: 在文件末尾追加竞态回归测试**

```python
class SmartChartEndpointRaceTests(unittest.TestCase):
    """回归：路由 LLM 在最后一刻超时时，端点必须送达降级结果，而不是 TIMEOUT。

    fake LLM 每次都把拿到的剩余预算耗尽才超时。修复前：图内部 deadline 与
    wait_for 只差 0.5s，路由降级结果来不及渲染返回，响应是 errorCode=TIMEOUT；
    修复后：内部 deadline 提前 2s，降级重点句子在 wait_for 之前送达。
    """

    def test_last_second_route_timeout_returns_degraded_highlights(self):
        source = segment(
            "s1",
            "我们确认本季度收入增长了25%，这是必须保留的关键结论，下一步由市场部跟进落实。",
        )
        payload = {
            "requestId": "race-request",
            "recordingId": "race-recording",
            "segments": [source],
            "summaryMarkdown": "",
        }

        def fake_llm(prompt, temperature=0.3, deadline=None):
            # 模拟慢模型：每次都把拿到的剩余预算耗尽才超时。
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining > 0:
                    time.sleep(remaining)
            raise LLMError(LLMError.TIMEOUT, "provider timeout")

        with patch.dict(os.environ, {"CHART_TIME_BUDGET_SECONDS": "10"}), \
                patch.object(nodes, "ROUTE_RESERVED_SECONDS", 5.0), \
                patch.object(nodes, "call_llm", side_effect=fake_llm):
            client = TestClient(app)
            response = client.post("/chart/generate", json=payload)

        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["status"], "success")
        self.assertEqual(body["chartType"], "highlights")
        self.assertIsNone(body.get("errorCode"))
        self.assertTrue(body["plan"]["highlightSentences"])
```

- [ ] **Step 3: 运行新测试，确认失败**

Run: `cd ChartAgent && /opt/anaconda3/bin/python3 -m pytest tests/test_smartchart.py::SmartChartEndpointRaceTests -q`
Expected: FAIL — `body["status"]` 实际为 `"failed"`，`errorCode` 为 `"TIMEOUT"`（约 9.5s 后返回）。这就是用户看到的 bug。

- [ ] **Step 4: Commit（需用户确认后执行）**

```bash
git add ChartAgent/tests/test_smartchart.py
git commit -m "test: 新增图表端点最后一刻超时的竞态回归测试"
```

---

### Task 2: 消除截止竞态（`ChartAgent/main.py`）

**Files:**
- Modify: `ChartAgent/main.py:13-16`（常量区）、`58-93`（端点函数）

- [ ] **Step 1: 新增余量常量**

把第 13–16 行：

```python
API_VERSION = "3.0"
SERVICE_VERSION = "3.0.0"
DEFAULT_TIME_BUDGET_SECONDS = 105.0
ENDPOINT_RESPONSE_RESERVE_SECONDS = 0.5
```

改为：

```python
API_VERSION = "3.0"
SERVICE_VERSION = "3.0.0"
DEFAULT_TIME_BUDGET_SECONDS = 105.0
ENDPOINT_RESPONSE_RESERVE_SECONDS = 0.5
# 图内部 deadline 与端点 wait_for 之间的余量：保证最后一刻的 LLM 超时
# 仍有时间走降级、渲染并序列化响应，不会被 wait_for 抢先截断。
GRAPH_COMPLETION_MARGIN_SECONDS = 2.0
```

- [ ] **Step 2: 端点使用提前的工作 deadline**

端点函数开头（原第 60–61 行附近）：

```python
    budget_seconds = _time_budget_seconds()
    started = time.monotonic()
```

改为：

```python
    budget_seconds = _time_budget_seconds()
    started = time.monotonic()
    graph_timeout = _graph_timeout_seconds(budget_seconds)
    work_deadline = started + graph_timeout - GRAPH_COMPLETION_MARGIN_SECONDS
```

state 字典中（原第 81 行）：

```python
        "deadline": started + budget_seconds,
```

改为：

```python
        "deadline": work_deadline,
```

`wait_for` 调用（原第 90–93 行）：

```python
        result_state = await asyncio.wait_for(
            asyncio.to_thread(chart_agent.invoke, state),
            timeout=_graph_timeout_seconds(budget_seconds),
        )
```

改为（仅换成已算好的变量，行为不变）：

```python
        result_state = await asyncio.wait_for(
            asyncio.to_thread(chart_agent.invoke, state),
            timeout=graph_timeout,
        )
```

- [ ] **Step 3: 运行竞态测试，确认通过**

Run: `cd ChartAgent && /opt/anaconda3/bin/python3 -m pytest tests/test_smartchart.py::SmartChartEndpointRaceTests -q`
Expected: PASS（约 8s，降级重点句子在 wait_for 之前返回）。

- [ ] **Step 4: 全量回归**

Run: `cd ChartAgent && /opt/anaconda3/bin/python3 -m pytest tests/test_smartchart.py -q`
Expected: 36 passed。

- [ ] **Step 5: Commit（需用户确认后执行）**

```bash
git add ChartAgent/main.py ChartAgent/tests/test_smartchart.py
git commit -m "fix: 图内部 deadline 提前 2s，消除与端点 wait_for 的截止竞态"
```

---

### Task 3: 预算再平衡（`ChartAgent/agent/nodes.py` + 测试更新）

**Files:**
- Modify: `ChartAgent/agent/nodes.py:34-35`
- Test: `ChartAgent/tests/test_smartchart.py:482-485, 535-559, 582-586`

- [ ] **Step 1: 更新三块夹具以适配 12000 字符预算**

`SmartChartTimeBudgetTests.three_chunk_segments`（第 482–485 行）：

```python
    def three_chunk_segments(self):
        # Each segment's JSON form is ~3.3 KB, so the 5000-character budget
        # produces exactly three chunks.
        return [segment(f"s{i}", f"第{i}段" + "重要内容" * 800, i * 5.0) for i in range(3)]
```

改为：

```python
    def three_chunk_segments(self):
        # Each segment's JSON form is ~6.5 KB, so the 12000-character budget
        # produces exactly three chunks.
        return [segment(f"s{i}", f"第{i}段" + "重要内容" * 1600, i * 5.0) for i in range(3)]

    def five_chunk_segments(self):
        # Same ~6.5 KB segments: five chunks under the 12000-character budget.
        return [segment(f"s{i}", f"第{i}段" + "重要内容" * 1600, i * 5.0) for i in range(5)]
```

- [ ] **Step 2: 并发上限测试改为 4 并发 / 5 块**

`test_chunk_extraction_is_limited_to_two_concurrent_calls`（第 535–559 行）整体替换为：

```python
    def test_chunk_extraction_is_limited_to_four_concurrent_calls(self):
        segments = self.five_chunk_segments()
        lock = threading.Lock()
        active = 0
        max_active = 0

        def fake_llm(prompt, temperature=0.3, deadline=None):
            nonlocal active, max_active
            with lock:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.2)
            with lock:
                active -= 1
            return json.dumps({"candidates": []}, ensure_ascii=False)

        state = self.full_state(segments)
        started = time.monotonic()
        with patch.object(nodes, "call_llm", side_effect=fake_llm):
            nodes.extract_candidates(state)
        elapsed = time.monotonic() - started

        self.assertLessEqual(max_active, 4)
        # Two waves of 0.2s must beat five serial calls (1.0s).
        self.assertLess(elapsed, 0.8)
```

- [ ] **Step 3: 钳制测试改为钳到 4**

`test_extraction_concurrency_environment_is_clamped_to_two`（第 582–586 行）替换为：

```python
    def test_extraction_concurrency_environment_is_clamped_to_four(self):
        with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "99"}):
            self.assertEqual(nodes._extraction_concurrency(), 4)
        with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "1"}):
            self.assertEqual(nodes._extraction_concurrency(), 1)
```

- [ ] **Step 4: 运行测试，确认钳制测试失败**

Run: `cd ChartAgent && /opt/anaconda3/bin/python3 -m pytest tests/test_smartchart.py -q`
Expected: 仅 `test_extraction_concurrency_environment_is_clamped_to_four` FAIL（常量仍是 2），其余通过。

> **执行补记（已发生）：** 常量调大后另有两个连带调整——
> ① `SmartChartRoutingTests.test_long_transcript_is_extracted_in_multiple_segment_chunks`（第 211 行）
> 的夹具从 `"重要内容" * 220` 改为 `* 800`，否则 12 段在新预算下只剩 1 块；
> ② 该测试末句断言 `assertIn("第11段", calls[-1])` 在并发提取下不稳定（calls 按完成顺序记录），
> 改为 `assertTrue(any("第11段" in call for call in calls))`。

- [ ] **Step 5: 调大两个常量**

`ChartAgent/agent/nodes.py` 第 34–35 行：

```python
CHUNK_CHARACTER_BUDGET = 5000
EXTRACTION_CONCURRENCY = 2
```

改为：

```python
CHUNK_CHARACTER_BUDGET = 12000
EXTRACTION_CONCURRENCY = 4
```

- [ ] **Step 6: 全量回归**

Run: `cd ChartAgent && /opt/anaconda3/bin/python3 -m pytest tests/test_smartchart.py -q`
Expected: 36 passed。

- [ ] **Step 7: Commit（需用户确认后执行）**

```bash
git add ChartAgent/agent/nodes.py ChartAgent/tests/test_smartchart.py
git commit -m "perf: 分块 5000→12000、提取并发 2→4，长录音可在预算内完成"
```

---

### Task 4: 默认模型切换为 deepseek-v4-flash（Swift 三处）

**Files:**
- Modify: `AIRecording/ViewModels/SettingsViewModel.swift:96`
- Modify: `AIRecording/Services/LLMService.swift:80`
- Modify: `AIRecording/Services/ChartServiceManager.swift:145`

- [ ] **Step 1: SettingsViewModel 默认值**

`AIRecording/ViewModels/SettingsViewModel.swift:96`：

```swift
        llmModel = defaults.string(forKey: llmModelKey) ?? "deepseek-chat"
```

改为：

```swift
        llmModel = defaults.string(forKey: llmModelKey) ?? "deepseek-v4-flash"
```

- [ ] **Step 2: LLMService 默认值**

`AIRecording/Services/LLMService.swift:80`：

```swift
        defaults.string(forKey: "llm.model") ?? "deepseek-chat"
```

改为：

```swift
        defaults.string(forKey: "llm.model") ?? "deepseek-v4-flash"
```

- [ ] **Step 3: ChartServiceManager 默认值**

`AIRecording/Services/ChartServiceManager.swift:145`：

```swift
            "LLM_MODEL": defaults.string(forKey: "llm.model") ?? "deepseek-chat",
```

改为：

```swift
            "LLM_MODEL": defaults.string(forKey: "llm.model") ?? "deepseek-v4-flash",
```

说明：`Tests/AIRecordingTests/SmartChartTests.swift:100,105` 里的 `"deepseek-chat"` 是
`serviceEnvironment` 透传测试的**入参**，不断言代码默认值，无需修改（已核实）。

- [ ] **Step 4: 构建并跑 Swift 测试**

Run: `swift build && swift test`
Expected: 构建成功，全部测试通过。

- [ ] **Step 5: Commit（需用户确认后执行）**

```bash
git add AIRecording/ViewModels/SettingsViewModel.swift AIRecording/Services/LLMService.swift AIRecording/Services/ChartServiceManager.swift
git commit -m "chore: 默认 LLM 模型切换为 deepseek-v4-flash（deepseek-chat 即将下架）"
```

---

### Task 5: 配置迁移与运行环境收尾

**Files:** 无代码改动（运维步骤）

- [ ] **Step 1: 迁移已存储的用户模型配置（两个域都写，保险）**

```bash
defaults write AIRecording llm.model deepseek-v4-flash
defaults write com.airecording.app llm.model deepseek-v4-flash
defaults read AIRecording llm.model
defaults read com.airecording.app llm.model
```

Expected: 两条 read 都输出 `deepseek-v4-flash`。

- [ ] **Step 2: 清理残留的 http.server 进程**

```bash
ps -p 31024 -o pid,command=
```

确认仍是 `python -m http.server 8765` 后：

```bash
kill 31024
```

若 PID 已变化，用 `lsof -nP -iTCP:8765 -sTCP:LISTEN` 重新定位。

- [ ] **Step 3: 重启图表后端，让新模型生效**

后端环境变量在启动时固化，必须重启：

```bash
pkill -f "AIRecording_AIRecording.bundle/main.py"
sleep 12
curl -s -m 5 http://127.0.0.1:8765/health
```

Expected: App 心跳（10s 周期）自动用新配置拉起后端，health 返回 `{"status":"ok",...,"llmConfigured":true}`。

- [ ] **Step 4: 检查点 —— 重新构建安装 App（需用户确认）**

`Scripts/build-app.sh` 会写入 `/Applications`，执行前必须征得用户同意：

```bash
bash Scripts/build-app.sh
```

- [ ] **Step 5: 端到端验证（用户操作）**

用户在 App 中对 326 段的录音点击"生成图表"：
- 预期约 30~40s 出现真图表；即使模型偶发变慢，也应看到"重点句子"而非"图表生成超时"。
- 日志佐证：`tail -f ~/Library/Logs/AIRecording/chart-agent.log` 中 `request_finished` 的 `result` 为 `success`。

- [ ] **Step 6: 总提交（需用户确认后执行）**

用户确认后，把 spec、plan 与全部代码改动一并提交（注意工作区还有前两轮修复的未提交改动，**不要**夹带，只 add 本计划涉及的文件）：

```bash
git add docs/superpowers/specs/2026-07-17-smart-chart-timeout-design.md \
        docs/superpowers/plans/2026-07-17-smart-chart-timeout.md \
        ChartAgent/main.py ChartAgent/agent/nodes.py ChartAgent/tests/test_smartchart.py \
        AIRecording/ViewModels/SettingsViewModel.swift AIRecording/Services/LLMService.swift \
        AIRecording/Services/ChartServiceManager.swift
git commit -m "fix: 根治智能图表超时——消除截止竞态、再平衡时间预算、默认模型换 deepseek-v4-flash"
```

---

## Self-Review 记录

- **Spec 覆盖：** 3.1 竞态 → Task 1+2；3.2 预算 → Task 3；3.3 模型默认值 + 存储迁移 → Task 4 + Task 5 Step 1；3.4 运维 → Task 5；第 5 节测试 → Task 1/3/4；验证命令 → 各 Task。无遗漏。
- **占位符扫描：** 无 TBD/TODO；所有代码步骤含完整代码。
- **类型一致：** `GRAPH_COMPLETION_MARGIN_SECONDS`、`work_deadline`、`graph_timeout`、`five_chunk_segments`、`test_extraction_concurrency_environment_is_clamped_to_four`、`test_chunk_extraction_is_limited_to_four_concurrent_calls` 前后引用一致；测试总数基线 35 → 加 1 竞态测试 = 36，改名测试不增减。
