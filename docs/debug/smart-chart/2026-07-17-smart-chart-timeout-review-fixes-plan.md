# SmartChart 超时复审问题修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `smartchart-timeout-fix.diff` 复审发现的剩余问题，确保 ChartAgent 在 105 秒后端预算内返回图表、可靠的重点句子降级结果或结构化超时，同时避免旧请求污染 UI 和敏感内容进入日志。

**Architecture:** 保留客户端 120 秒、后端 105 秒的双层时间预算。FastAPI 端点增加真正的外层截止机制，分块提取只使用扣除路由预留后的子预算，路由超时时由本地、可追溯的原文重点句子继续渲染；Swift 的 HTTP 边界负责清洗请求和校验响应身份，ViewModel 只负责生命周期与界面状态。

**Tech Stack:** Python 3、FastAPI、asyncio、LangGraph、Pydantic、unittest、Swift 6、Swift Concurrency、URLSession、XCTest、Swift Package Manager。

---

## 1. 实施边界与成功标准

本计划只处理本次代码复审确认的问题，不继续扩张 SmartChart v3 的视觉模板、协议字段、Core Data 或录音功能。

完成后必须满足：

1. 即使 `chart_agent.invoke` 内部出现不遵守 deadline 的同步阻塞，HTTP 端点也能在配置预算内返回结构化 `TIMEOUT`。
2. 分块提取最多并发 2，并且不能消耗预留给全局路由的 25 秒。
3. 路由阶段因为剩余预算不足或 `LLMError.TIMEOUT` 失败时，只要转录中存在可靠原文，就返回可点击定位的 `highlights`，不再把同一个“图表生成超时”直接显示给用户。
4. 日志中保留 `requestId`、阶段、错误类型和错误码，但不记录异常中夹带的转录正文、Prompt、Bearer token 或 API Key。
5. Swift 发送前过滤空白片段；后端响应 `requestId` 不匹配时抛出 `invalidResponse`，不会留下无限 loading。
6. 详情页离开时取消图表任务、失效旧 token，并结束 loading。
7. Python、SmartChart Swift 测试和 Swift 全量测试全部通过；用原来必现超时的真实长录音完成一次端到端验收。

## 2. 文件结构与职责

**修改：**

- `ChartAgent/main.py`：端点级硬截止、统一失败响应。
- `ChartAgent/agent/nodes.py`：提取子 deadline、并发上限、路由超时降级。
- `ChartAgent/agent/observability.py`：安全错误字段和凭据兜底脱敏。
- `ChartAgent/tests/test_smartchart.py`：后端超时、预留预算、降级和日志回归测试。
- `AIRecording/Services/HTTPChartSkill.swift`：空白片段过滤、响应 requestId 校验。
- `AIRecording/ViewModels/RecordingDetailViewModel.swift`：图表任务生命周期清理。
- `Tests/AIRecordingTests/SmartChartTests.swift`：Swift 传输边界和 cleanup 回归测试。

**保持不变：**

- `AIRecording/Services/ChartSkill.swift` 的成功响应协议和客户端 120 秒超时。
- `ChartAgent/agent/schema.py` 的 `TranscriptSegment.text` 非空约束；空白数据应在 Swift 传输边界被清洗，而不是放宽后端契约。
- 所有图表模板、WebView、录音和转录存储代码。

## 3. 开始前保护现有改动

- [ ] **Step 1: 确认当前工作区和 diff 范围**

Run:

```bash
git status --short
git diff --stat
git diff -- smartchart-timeout-fix.diff
```

Expected: 能识别用户已有的未提交文件；后续不得覆盖或格式化无关改动。

- [ ] **Step 2: 建立实施基线**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest discover -s ChartAgent/tests -v
swift test --filter SmartChartTests
```

Expected: 当前基线为 Python 30 个测试通过、SmartChart Swift 11 个测试通过。如果数量因用户后续修改发生变化，以“全部通过且记录准确数量”为准。

---

### Task 1: 给 FastAPI 端点增加真正的硬截止

**Files:**

- Modify: `ChartAgent/main.py:14-96`
- Test: `ChartAgent/tests/test_smartchart.py:654-680`

- [ ] **Step 1: 用真实进入图执行器的慢任务替换当前无效测试**

把 `SmartChartEndpointTimeoutTests` 中现有测试替换为以下测试。耗时必须在协程内部测量，因为 `asyncio.run` 关闭事件循环时会等待默认线程池清理，而生产中的 Uvicorn 事件循环不会为这个响应执行 shutdown。

```python
class SmartChartEndpointTimeoutTests(unittest.TestCase):
    def test_endpoint_cuts_off_non_cooperative_graph_within_budget(self):
        from main import chart_generate_endpoint

        request = SmartChartGenerateRequest(
            requestId="request-timeout",
            recordingId="recording-timeout",
            segments=[segment("s1")],
        )
        graph_started = threading.Event()

        def slow_graph(_state):
            graph_started.set()
            time.sleep(0.30)
            return {"status": "success"}

        async def invoke_and_measure():
            started = time.monotonic()
            response = await chart_generate_endpoint(request)
            return response, time.monotonic() - started

        with patch.dict(os.environ, {"CHART_TIME_BUDGET_SECONDS": "0.10"}):
            with patch("main.chart_agent.invoke", side_effect=slow_graph):
                response, elapsed = asyncio.run(invoke_and_measure())

        self.assertTrue(graph_started.is_set(), "测试必须真正进入图执行器")
        self.assertEqual(response.status, "failed")
        self.assertEqual(response.errorCode, "TIMEOUT")
        self.assertLess(elapsed, 0.15)
```

- [ ] **Step 2: 运行测试并确认它能复现问题**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartEndpointTimeoutTests.test_endpoint_cuts_off_non_cooperative_graph_within_budget -v
```

Expected: FAIL；当前代码会等待约 0.30 秒，`elapsed < 0.15` 不成立。

- [ ] **Step 3: 提取统一失败响应并给图执行器加外层 timeout**

在 `ChartAgent/main.py` 中加入响应预留，并使用统一 helper，避免超时分支和普通失败分支生成不同协议：

```python
ENDPOINT_RESPONSE_RESERVE_SECONDS = 0.5


def _graph_timeout_seconds(budget_seconds: float) -> float:
    reserve = min(ENDPOINT_RESPONSE_RESERVE_SECONDS, budget_seconds / 2)
    return max(0.01, budget_seconds - reserve)


def _failed_response(request_id: str, message: str, error_code: str | None = None):
    return SmartChartGenerateResponse(
        requestId=request_id,
        status="failed",
        chartType="highlights",
        chartTypeDisplayName="重点句子",
        title="生成失败",
        htmlFragment=_error_html(message),
        plan=ChartPlan(
            visualizationKind="highlights",
            title="生成失败",
            routingConfidence=0.0,
            highlightSentences=[],
        ),
        errors=[message],
        errorCode=error_code,
    )
```

将图执行改为：

```python
try:
    result_state = await asyncio.wait_for(
        asyncio.to_thread(chart_agent.invoke, state),
        timeout=_graph_timeout_seconds(budget_seconds),
    )
except asyncio.TimeoutError:
    log_event(
        "WARNING", "request_finished", request.requestId, request.recordingId,
        result="failed", errorCode="TIMEOUT", durationMs=_duration_ms(started),
        message="图表生成达到后端时间预算",
    )
    return _failed_response(request.requestId, "图表生成超时", "TIMEOUT")
except Exception as error:
    # Task 4 会把这里的任意异常文本替换为安全错误字段。
    log_event(
        "ERROR", "request_finished", request.requestId, request.recordingId,
        result="error", errorType=type(error).__name__,
        durationMs=_duration_ms(started), message="图表服务内部错误",
    )
    raise HTTPException(status_code=500, detail="图表服务内部错误") from error
```

普通 `result_state.status == "failed"` 分支也调用 `_failed_response(request.requestId, message, error_code)`。

- [ ] **Step 4: 运行定向测试**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartEndpointTimeoutTests -v
```

Expected: PASS；慢图确实启动，但端点在 0.15 秒内返回 `TIMEOUT`。

- [ ] **Step 5: 提交该独立修复**

```bash
git add ChartAgent/main.py ChartAgent/tests/test_smartchart.py
git diff --cached --check
git commit -m "fix: enforce smart chart endpoint deadline"
```

Expected: 提交只包含端点硬截止和对应测试，不包含 `*.diff` 文件。

---

### Task 2: 强制保留路由预算并把并发上限锁定为 2

**Files:**

- Modify: `ChartAgent/agent/nodes.py:35-145`
- Test: `ChartAgent/tests/test_smartchart.py:481-581`

- [ ] **Step 1: 写环境变量并发上限测试**

在 `SmartChartTimeBudgetTests` 中增加：

```python
def test_extraction_concurrency_environment_is_clamped_to_two(self):
    with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "99"}):
        self.assertEqual(nodes._extraction_concurrency(), 2)
    with patch.dict(os.environ, {"CHART_EXTRACTION_CONCURRENCY": "1"}):
        self.assertEqual(nodes._extraction_concurrency(), 1)
```

- [ ] **Step 2: 写提取 deadline 扣除路由预留的测试**

继续增加：

```python
def test_chunk_calls_receive_deadline_before_route_reserve(self):
    state = self.full_state(self.three_chunk_segments())
    state["deadline"] = time.monotonic() + 30.0
    request_deadline = state["deadline"]
    captured_deadlines = []

    def fake_extract(index, chunk, chunk_count, deadline, request_id, recording_id):
        captured_deadlines.append(deadline)
        return index, [], None

    with patch.object(nodes, "_extract_chunk_candidates", side_effect=fake_extract):
        result = nodes.extract_candidates(state)

    self.assertEqual(result["status"], "success")
    self.assertTrue(captured_deadlines)
    expected_latest = request_deadline - nodes.ROUTE_RESERVED_SECONDS
    self.assertTrue(all(value <= expected_latest + 0.05 for value in captured_deadlines))
```

- [ ] **Step 3: 运行测试并确认两个缺陷都被捕获**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartTimeBudgetTests.test_extraction_concurrency_environment_is_clamped_to_two tests.test_smartchart.SmartChartTimeBudgetTests.test_chunk_calls_receive_deadline_before_route_reserve -v
```

Expected: FAIL；环境变量 99 当前得到 99，chunk 当前收到整个请求的 deadline。

- [ ] **Step 4: 实现并发 clamp 和独立 extraction deadline**

在 `nodes.py` 中修改并发解析，并增加 helper：

```python
def _extraction_concurrency() -> int:
    raw = os.environ.get("CHART_EXTRACTION_CONCURRENCY", "")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return EXTRACTION_CONCURRENCY
    return min(EXTRACTION_CONCURRENCY, max(1, value))


def _extraction_deadline(request_deadline: Optional[float]) -> Optional[float]:
    if request_deadline is None:
        return None
    return request_deadline - ROUTE_RESERVED_SECONDS
```

在 `extract_candidates` 计算一次子 deadline，只把它传给 chunk：

```python
deadline = state.get("deadline")
extraction_deadline = _extraction_deadline(deadline)

for wave_start in range(0, chunk_count, concurrency):
    if (
        extraction_deadline is not None
        and extraction_deadline - time.monotonic() < MIN_REMAINING_SECONDS
    ):
        log_event(
            "WARNING", "extract_chunk", request_id, recording_id,
            chunkIndex=wave_start, chunkCount=chunk_count,
            result="skipped_low_budget",
            message="提取预算已用尽，保留路由阶段预算",
        )
        break

    wave = [
        (index, chunks[index])
        for index in range(wave_start, min(wave_start + concurrency, chunk_count))
    ]
    with ThreadPoolExecutor(
        max_workers=concurrency,
        thread_name_prefix="chart-extract",
    ) as executor:
        futures = [
            executor.submit(
                _extract_chunk_candidates,
                index,
                chunk,
                chunk_count,
                extraction_deadline,
                request_id,
                recording_id,
            )
            for index, chunk in wave
        ]
```

保留当前按 chunk index 排序合并的代码，不修改候选内容协议。

- [ ] **Step 5: 运行整个时间预算测试类**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartTimeBudgetTests -v
```

Expected: PASS；最大并发仍为 2、三块仍以原顺序合并、提取 deadline 至少早于总 deadline 25 秒。

- [ ] **Step 6: 提交该独立修复**

```bash
git add ChartAgent/agent/nodes.py ChartAgent/tests/test_smartchart.py
git diff --cached --check
git commit -m "fix: reserve routing time in chart extraction"
```

---

### Task 3: 路由超时时降级为有来源的重点句子

**Files:**

- Modify: `ChartAgent/agent/nodes.py:357-479`
- Test: `ChartAgent/tests/test_smartchart.py:481-653`

- [ ] **Step 1: 写路由调用超时的降级测试**

在 `SmartChartTimeBudgetTests` 中增加：

```python
def test_route_timeout_degrades_to_source_backed_highlights(self):
    source = segment(
        "s1",
        "我们确认本周必须完成上线前验证，这是当前最重要的结论。",
    )
    state = self.full_state([source])
    state["segment_map"] = {"s1": source}
    state["merged_candidates"] = []

    with patch.object(
        nodes,
        "_llm_route_and_plan",
        side_effect=LLMError(LLMError.TIMEOUT, "provider timeout"),
    ):
        routed = nodes.route_and_plan(state)

    validated = nodes.validate_plan(routed)
    self.assertEqual(validated["status"], "success")
    self.assertEqual(validated["plan"]["visualizationKind"], "highlights")
    self.assertEqual(
        validated["plan"]["highlightSentences"][0]["segmentId"],
        "s1",
    )
    self.assertTrue(validated["validation_result"]["degraded"])
```

- [ ] **Step 2: 写“路由前预算已经不足”的降级测试**

```python
def test_low_route_budget_skips_llm_and_degrades_to_highlights(self):
    source = segment("s1", "当前最大的风险是交付时间不足，需要立刻确认负责人。")
    state = self.full_state([source])
    state["segment_map"] = {"s1": source}
    state["merged_candidates"] = []
    state["deadline"] = time.monotonic() + 0.5

    with patch.object(nodes, "_llm_route_and_plan") as route_mock:
        routed = nodes.route_and_plan(state)

    route_mock.assert_not_called()
    validated = nodes.validate_plan(routed)
    self.assertEqual(validated["status"], "success")
    self.assertEqual(validated["plan"]["visualizationKind"], "highlights")
```

- [ ] **Step 3: 运行测试并确认当前代码直接失败**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartTimeBudgetTests.test_route_timeout_degrades_to_source_backed_highlights tests.test_smartchart.SmartChartTimeBudgetTests.test_low_route_budget_skips_llm_and_degrades_to_highlights -v
```

Expected: FAIL；当前 `route_and_plan` 把两种情况都设置为 `status == "failed"`。

- [ ] **Step 4: 增加单一、确定性的路由降级 helper**

在 `route_and_plan` 前增加：

```python
def _degrade_route_to_highlights(
    state: Dict[str, Any],
    reason: str,
) -> Dict[str, Any]:
    fallback = _fallback_highlights_plan(
        state.get("segments", []),
        state.get("merged_candidates", []),
    )
    if not fallback.get("highlightSentences"):
        return _fail(
            state,
            "图表生成超时，且没有可用的重点句子",
            error_code=LLMError.TIMEOUT,
        )
    state["plan"] = fallback
    state["validation_result"] = {
        "passed": False,
        "degraded": True,
        "reason": reason,
    }
    state["status"] = "success"
    return state
```

- [ ] **Step 5: 只对 TIMEOUT 路径使用降级，保留配置错误的可见性**

修改 `route_and_plan`：

```python
if _remaining_budget(state) < MIN_REMAINING_SECONDS:
    log_event(
        "WARNING", "route_and_plan", request_id, recording_id,
        result="degraded", errorCode=LLMError.TIMEOUT,
        message="路由预算不足，使用重点句子降级",
    )
    return _degrade_route_to_highlights(state, "route_budget_exhausted")

try:
    state["plan"] = _llm_route_and_plan(
        state.get("segments", []),
        state.get("merged_candidates", []),
        deadline=state.get("deadline"),
    )
except LLMError as error:
    if error.code == LLMError.TIMEOUT:
        log_event(
            "WARNING", "route_and_plan", request_id, recording_id,
            durationMs=_elapsed_ms(started), provider=provider, model=model,
            result="degraded", errorCode=error.code,
            message="路由调用超时，使用重点句子降级",
        )
        return _degrade_route_to_highlights(state, "route_timeout")
    log_event(
        "ERROR", "route_and_plan", request_id, recording_id,
        durationMs=_elapsed_ms(started), provider=provider, model=model,
        result="failed", errorType=type(error).__name__,
        errorCode=error.code, message="模型路由失败",
    )
    return _fail(
        state,
        "LLM 图表路由失败",
        error_code=error.code,
    )
```

`LLM_UNAVAILABLE` 等配置或供应商错误仍返回失败，不能伪装成一次成功的内容路由。

- [ ] **Step 6: 在正常校验通过时保留 degraded 标记**

修改 `validate_plan` 的成功结尾：

```python
previous_validation = state.get("validation_result") or {}
state["plan"] = normalized
state["validation_result"] = {"passed": True}
if previous_validation.get("degraded"):
    state["validation_result"].update({
        "degraded": True,
        "reason": previous_validation.get("reason"),
    })
return state
```

- [ ] **Step 7: 运行路由和渲染回归测试**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartTimeBudgetTests tests.test_smartchart.SmartChartRuntimeTests -v
```

Expected: PASS；路由超时返回来源为 `s1` 的 highlights，其他图表渲染行为不变。

- [ ] **Step 8: 提交该独立修复**

```bash
git add ChartAgent/agent/nodes.py ChartAgent/tests/test_smartchart.py
git diff --cached --check
git commit -m "fix: degrade timed out chart routing to highlights"
```

---

### Task 4: 禁止异常正文和凭据进入结构化日志

**Files:**

- Modify: `ChartAgent/agent/observability.py:16-72`
- Modify: `ChartAgent/agent/nodes.py:160-180,370-385,448-460,670-679`
- Modify: `ChartAgent/main.py:66-79`
- Test: `ChartAgent/tests/test_smartchart.py:682-730`

- [ ] **Step 1: 写失败路径隐私测试**

在 `SmartChartLoggingTests` 中增加：

```python
def test_failure_log_does_not_emit_exception_body_or_credentials(self):
    secret_transcript = "绝密转录正文-XYZ-987"
    secret_key = "sk-sensitive-test-key"
    source = segment("s1", "这是可以安全参与降级的公开测试句子，长度足够。")
    state = {
        "request_id": "request-private-error",
        "recording_id": "recording-private-error",
        "segments": [source],
        "segment_map": {"s1": source},
        "merged_candidates": [],
        "status": "success",
        "deadline": time.monotonic() + 30,
    }
    unsafe_error = LLMError(
        LLMError.LLM_UNAVAILABLE,
        f"Bearer {secret_key}; prompt contained {secret_transcript}",
    )

    with patch.object(nodes, "_llm_route_and_plan", side_effect=unsafe_error):
        with self.assertLogs("chart_agent", level="ERROR") as captured:
            result = nodes.route_and_plan(state)

    output = "\n".join(captured.output)
    self.assertEqual(result["status"], "failed")
    self.assertIn("LLM_UNAVAILABLE", output)
    self.assertNotIn(secret_key, output)
    self.assertNotIn(secret_transcript, output)
    self.assertNotIn("Bearer", output)
```

- [ ] **Step 2: 运行测试并确认原始异常会泄露**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartLoggingTests.test_failure_log_does_not_emit_exception_body_or_credentials -v
```

Expected: FAIL；当前 `message=str(error)` 会把两个秘密写入日志。

- [ ] **Step 3: 增加安全错误字段 helper 和凭据兜底脱敏**

在 `observability.py` 增加：

```python
import re

_SAFE_ERROR_MESSAGES = {
    "TIMEOUT": "模型调用超时",
    "LLM_UNAVAILABLE": "模型服务不可用",
    "INVALID_LLM_RESPONSE": "模型响应格式无效",
}
_CREDENTIAL_PATTERNS = (
    re.compile(r"(?i)bearer\s+[^\s,;]+"),
    re.compile(r"\bsk-[A-Za-z0-9_-]+\b"),
    re.compile(r"(?i)(api[_-]?key[=:]\s*)[^\s,;]+"),
)


def safe_error_fields(error: BaseException) -> dict[str, Any]:
    code = getattr(error, "code", None)
    fields: dict[str, Any] = {
        "errorType": type(error).__name__,
        "message": _SAFE_ERROR_MESSAGES.get(code, "图表阶段执行失败"),
    }
    if code:
        fields["errorCode"] = code
    return fields


def _redact_message(value: Any) -> str:
    result = str(value)
    for pattern in _CREDENTIAL_PATTERNS:
        result = pattern.sub("[REDACTED]", result)
    return result[:_MESSAGE_MAX_LENGTH]
```

并把 `log_event` 中的 message 处理改为：

```python
if key == "message":
    value = _redact_message(value)
```

`_redact_message` 只是凭据兜底；防止完整转录泄露的核心规则仍然是异常日志只能使用 `safe_error_fields(error)`，不能把 `str(error)` 传给 logger。

- [ ] **Step 4: 替换所有动态异常日志**

在 `nodes.py` 和 `main.py` 导入：

```python
from agent.observability import log_event, safe_error_fields
```

包内导入保持相对路径：

```python
from .observability import log_event, safe_error_fields
```

把所有以下形态：

```python
errorType=type(error).__name__,
errorCode=getattr(error, "code", None),
message=str(error),
```

替换为：

```python
**safe_error_fields(error),
```

替换后执行：

```bash
rg -n 'message=str\(error\)|message=f.*error' ChartAgent/main.py ChartAgent/agent
```

Expected: 无匹配。

- [ ] **Step 5: 运行全部日志测试**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest tests.test_smartchart.SmartChartLoggingTests -v
```

Expected: PASS；成功路径仍有完整阶段，失败路径保留 `LLM_UNAVAILABLE`，但没有秘密正文。

- [ ] **Step 6: 提交日志修复**

```bash
git add ChartAgent/agent/observability.py ChartAgent/agent/nodes.py ChartAgent/main.py ChartAgent/tests/test_smartchart.py
git diff --cached --check
git commit -m "fix: sanitize smart chart failure logs"
```

---

### Task 5: 在 Swift HTTP 边界清洗片段并校验 response requestId

**Files:**

- Modify: `AIRecording/Services/HTTPChartSkill.swift:20-78`
- Test: `Tests/AIRecordingTests/SmartChartTests.swift:1-330`

- [ ] **Step 1: 写 response requestId 不匹配测试**

在 `SmartChartTests` 中增加：

```swift
func testMismatchedResponseRequestIDThrowsInvalidResponse() async throws {
    let service = makeService { request in
        if request.url?.path == "/health" {
            return Self.response(
                url: request.url!,
                json: #"{"status":"ok","apiVersion":"3.0","serviceVersion":"3.0.0","llmConfigured":true}"#
            )
        }
        return Self.response(
            url: request.url!,
            json: Self.successResponseJSON(requestId: "different-request")
        )
    }
    let request = Self.makeRequest(
        requestId: "expected-request",
        texts: ["这是一个长度足够的有效转录片段，用来校验响应身份。"]
    )

    do {
        _ = try await service.generate(request: request)
        XCTFail("Expected invalidResponse")
    } catch let error as ChartSkillError {
        XCTAssertEqual(error, .invalidResponse)
    }
}
```

- [ ] **Step 2: 写混合空白片段的传输测试**

```swift
func testGenerateFiltersBlankSegmentsBeforeSending() async throws {
    let service = makeService { request in
        if request.url?.path == "/health" {
            return Self.response(
                url: request.url!,
                json: #"{"status":"ok","apiVersion":"3.0","serviceVersion":"3.0.0","llmConfigured":true}"#
            )
        }
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(SmartChartGenerateRequest.self, from: body)
        XCTAssertEqual(decoded.segments.map(\.text), ["有效转录内容"])
        return Self.response(
            url: request.url!,
            json: Self.successResponseJSON(requestId: decoded.requestId)
        )
    }

    let request = Self.makeRequest(
        requestId: "request-filter",
        texts: ["   ", "  有效转录内容  "]
    )
    _ = try await service.generate(request: request)
}

func testGenerateRejectsAllBlankSegmentsBeforeHealthCheck() async throws {
    let service = makeService { _ in
        XCTFail("全空白请求不应访问服务")
        throw URLError(.badServerResponse)
    }
    let request = Self.makeRequest(
        requestId: "request-empty",
        texts: [" ", "\n"]
    )

    do {
        _ = try await service.generate(request: request)
        XCTFail("Expected contentTooShort")
    } catch let error as ChartSkillError {
        XCTAssertEqual(error, .contentTooShort)
    }
}
```

在测试类内增加固定 helper；成功 JSON 使用一条有来源的 highlight，确保完全符合 v3 Schema：

```swift
private static func makeRequest(requestId: String, texts: [String]) -> SmartChartGenerateRequest {
    SmartChartGenerateRequest(
        requestId: requestId,
        recordingId: "recording-1",
        segments: texts.enumerated().map { index, text in
            TranscriptSegmentDTO(
                id: "segment-\(index)",
                speaker: "发言人",
                startTime: Double(index * 5),
                endTime: Double(index * 5 + 5),
                text: text
            )
        }
    )
}

private static func successResponseJSON(requestId: String) -> String {
    #"""
    {
      "version":"3.0",
      "requestId":"\#(requestId)",
      "status":"success",
      "chartType":"highlights",
      "chartTypeDisplayName":"重点句子",
      "title":"重点句子",
      "htmlFragment":"<div data-segment-ids='segment-0'>重点句子</div>",
      "plan":{
        "visualizationKind":"highlights",
        "title":"重点句子",
        "routingConfidence":0.8,
        "items":[],
        "relations":[],
        "series":[],
        "highlightSentences":[{
          "segmentId":"segment-0",
          "text":"有效转录内容",
          "speaker":"发言人",
          "startTime":0,
          "endTime":5,
          "tag":"关键判断"
        }]
      },
      "errors":[]
    }
    """#
}
```

- [ ] **Step 3: 运行 Swift 定向测试并确认失败**

Run:

```bash
swift test --filter SmartChartTests/testMismatchedResponseRequestIDThrowsInvalidResponse
swift test --filter SmartChartTests/testGenerateFiltersBlankSegmentsBeforeSending
swift test --filter SmartChartTests/testGenerateRejectsAllBlankSegmentsBeforeHealthCheck
```

Expected: FAIL；当前 requestId 不匹配仍被返回，空白片段仍被原样编码或触发网络请求。

- [ ] **Step 4: 在联网前构造清洗后的请求**

在 `HTTPChartSkill.generate` 开头、`checkAvailability` 之前加入：

```swift
let cleanedSegments = request.segments.compactMap { segment -> TranscriptSegmentDTO? in
    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return TranscriptSegmentDTO(
        id: segment.id,
        speaker: segment.speaker,
        startTime: segment.startTime,
        endTime: segment.endTime,
        text: text
    )
}
guard !cleanedSegments.isEmpty else {
    throw ChartSkillError.contentTooShort
}
let transportRequest = SmartChartGenerateRequest(
    requestId: request.requestId,
    recordingId: request.recordingId,
    segments: cleanedSegments,
    summaryMarkdown: request.summaryMarkdown
)
```

把编码对象从 `request` 改为：

```swift
urlRequest.httpBody = try JSONEncoder().encode(transportRequest)
```

- [ ] **Step 5: 解码后立即校验响应身份**

在 `result.status` 判断之前加入：

```swift
guard result.requestId == request.requestId else {
    throw ChartSkillError.invalidResponse
}
```

这样 ViewModel 的统一 catch 会结束 loading；不在 ViewModel 中静默忽略错误响应。

- [ ] **Step 6: 运行全部 SmartChart Swift 测试**

Run:

```bash
swift test --filter SmartChartTests
```

Expected: PASS；测试数量至少比基线增加 3。

- [ ] **Step 7: 提交 Swift 传输边界修复**

```bash
git add AIRecording/Services/HTTPChartSkill.swift Tests/AIRecordingTests/SmartChartTests.swift
git diff --cached --check
git commit -m "fix: validate smart chart transport boundaries"
```

---

### Task 6: 页面离开时完整取消图表任务

**Files:**

- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift:300-352,438-443`
- Test: `Tests/AIRecordingTests/SmartChartTests.swift`

- [ ] **Step 1: 写 cleanup 可观察状态测试**

在测试文件顶部增加 `import CoreData`，并在 `SmartChartTests` 中增加：

```swift
@MainActor
func testCleanupEndsChartLoadingState() {
    let controller = PersistenceController(inMemory: true)
    let recording = Recording(context: controller.container.viewContext)
    recording.id = UUID()
    let viewModel = RecordingDetailViewModel(objectID: recording.objectID)
    viewModel.isGeneratingChart = true

    viewModel.cleanup()

    XCTAssertFalse(viewModel.isGeneratingChart)
}
```

- [ ] **Step 2: 运行测试并确认当前 cleanup 没有结束 loading**

Run:

```bash
swift test --filter SmartChartTests/testCleanupEndsChartLoadingState
```

Expected: FAIL；当前 `cleanup()` 不修改 `isGeneratingChart`。

- [ ] **Step 3: 在 cleanup 中取消任务并失效所有旧响应**

修改 `cleanup()`：

```swift
func cleanup() {
    chartTask?.cancel()
    chartTask = nil
    chartGate.invalidate()
    isGeneratingChart = false

    playerService.stop()
    stopWaveformTimer()
    cancellables.removeAll()
}
```

- [ ] **Step 4: 收口 generateChart 的完成路径**

Task 5 已在 HTTP 层验证 requestId，因此成功路径不再静默 `return`。修改生成任务：

```swift
chartTask = Task {
    do {
        let response = try await HTTPChartSkill.shared.generate(request: request)
        guard chartGate.isCurrent(token), !Task.isCancelled else { return }
        chartResult = response
        isGeneratingChart = false
        chartTask = nil
    } catch is CancellationError {
        guard chartGate.isCurrent(token) else { return }
        isGeneratingChart = false
        chartTask = nil
    } catch {
        guard chartGate.isCurrent(token), !Task.isCancelled else { return }
        chartError = (error as? ChartSkillError)?.localizedDescription
            ?? error.localizedDescription
        isGeneratingChart = false
        chartTask = nil
    }
}
```

关键约束：旧任务因为新请求而取消时，其 token 已经失效，不能把新请求的 loading 清掉；页面 cleanup 则直接把 loading 设为 false。

- [ ] **Step 5: 运行 ViewModel 与 gate 测试**

Run:

```bash
swift test --filter SmartChartTests/testCleanupEndsChartLoadingState
swift test --filter SmartChartTests/testChartRequestGateInvalidatesPreviousTokens
```

Expected: PASS；cleanup 结束 loading，旧 token 仍不能覆盖新请求。

- [ ] **Step 6: 提交生命周期修复**

```bash
git add AIRecording/ViewModels/RecordingDetailViewModel.swift Tests/AIRecordingTests/SmartChartTests.swift
git diff --cached --check
git commit -m "fix: cancel chart generation on detail cleanup"
```

---

### Task 7: 全量回归与真实录音验收

**Files:**

- Verify: `ChartAgent/main.py`
- Verify: `ChartAgent/agent/nodes.py`
- Verify: `ChartAgent/agent/observability.py`
- Verify: `AIRecording/Services/HTTPChartSkill.swift`
- Verify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`
- Verify: `ChartAgent/tests/test_smartchart.py`
- Verify: `Tests/AIRecordingTests/SmartChartTests.swift`

- [ ] **Step 1: 检查 Python 语法和完整测试**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m py_compile ChartAgent/main.py ChartAgent/agent/graph.py ChartAgent/agent/llm_client.py ChartAgent/agent/nodes.py ChartAgent/agent/observability.py ChartAgent/agent/schema.py
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest discover -s ChartAgent/tests -v
```

Expected: 无语法错误；Python 测试全部 PASS，新增测试确实进入慢图、路由超时和敏感异常路径。

- [ ] **Step 2: 运行 Swift 定向和全量测试**

Run:

```bash
swift test --filter SmartChartTests
swift test
```

Expected: SmartChart 测试和项目全部测试 PASS，无新增 warning。

- [ ] **Step 3: 检查没有敏感错误日志调用和并发越界**

Run:

```bash
rg -n 'message=str\(error\)|message=f.*error' ChartAgent/main.py ChartAgent/agent
CHART_EXTRACTION_CONCURRENCY=99 PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -c 'from agent.nodes import _extraction_concurrency; assert _extraction_concurrency() == 2'
```

Expected: 第一条命令无匹配；第二条命令退出码为 0。

- [ ] **Step 4: 用三种长度的真实录音验收**

准备短录音（1 个 chunk）、中等录音（约 3 个 chunk）以及原来必现超时的长录音。每条执行：

1. 打开录音详情，点击一次“生成图表”。
2. 用 `requestId` 在 `~/Library/Logs/AIRecording/chart-agent.log` 中定位本次请求。
3. 记录分块数、提取耗时、路由耗时和总耗时。
4. 确认 120 秒内出现正式图表或“重点句子”，而不是一直 loading。
5. 点击图表元素或重点句子，确认跳转到正确的转录时间。
6. 在生成过程中离开详情页，确认 loading 消失；重新进入后没有迟到结果覆盖当前页面。

Expected:

- 短、中录音正常返回图表。
- 原长录音在 120 秒内返回图表或有来源的重点句子。
- 后端 `request_finished.durationMs` 不超过 105000 毫秒；允许外层硬截止路径出现少量调度误差，但必须早于客户端 120 秒。
- 日志不包含完整转录、Prompt 或 API Key。

- [ ] **Step 5: 检查最终 diff 的手术式边界**

Run:

```bash
git diff --check
git diff --stat
git status --short
```

Expected: 实现只触及本计划列出的 7 个文件；不提交 `smartchart-timeout-fix.diff`、`smartchart-changes.diff`、`__pycache__`、`._*` 或其他用户文件。

## 4. 不纳入本次补丁的事项

以下是复审中发现、但不应和超时补丁混在一起的工程改进：

- `ChartServiceManager.findPythonPath()` 在 `@MainActor` 同步探测 Python，首次启动可能短暂阻塞界面。
- 日志轮转只在服务启动时执行；长期不重启的进程仍需要独立的运行时轮转设计。
- v2 残留服务占用 8765 端口时，v3 健康检查和自动拉起可能无法自恢复。
- SwiftPM 复制 `ChartAgent/agent` 目录时可能把本地 `__pycache__` 或 AppleDouble 文件带进资源包。

这些问题不改变本次 105/120 秒超时链路。为避免再次形成四千多行的混合 diff，应在本计划验收通过后分别建小计划处理。

## 5. 回滚策略

- 若限并发引发供应商限流，可把环境变量降到 1；代码上限 2 和路由预留不能回滚。
- 若正式图表成功率因预算变严而下降，保留确定性 highlights 降级，不能通过增加客户端等待时间掩盖问题。
- 若外层 timeout 暴露底层 SDK 不响应 deadline，保留端点硬截止，同时单独修对应 provider 的可中断调用；不能删除外层保护。
- 若 Swift 生命周期修改出现回归，可回滚 Task 状态收口，但必须保留 HTTP response requestId 校验和 cleanup 的 gate invalidation。
