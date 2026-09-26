# 智能图表“图表生成超时”修复计划

## 1. 结论

当前故障发生在图表生成请求阶段，不是图表已经返回后 WebView 渲染失败。

**根因假设（高置信度）**：客户端对 `/chart/generate` 设置了固定 120 秒超时，但后端会执行多次串行 LLM 调用，且没有统一的端到端时间预算。转录越长，分块越多，请求越容易超过 120 秒。客户端先结束等待并显示“图表生成超时”，后端线程仍继续执行，稍后才返回 200，因此用户始终看不到这次迟到的图表。

具体卡在哪个 LLM 阶段目前无法从现有日志精确确认，因为后端只记录 Uvicorn 访问结果，没有请求 ID、开始时间、阶段耗时、模型供应商和异常详情。修复时必须先补齐这些日志，再用同一条真实录音复现一次确认。

## 2. 已查到的后端日志

日志文件：`~/Library/Logs/AIRecording/chart-agent.log`

检查时间：2026-07-17。文件约 54 KB、949 行，创建于 2026-07-14 13:45，最后修改于 2026-07-17 09:36。

日志中的关键现象：

- `/health` 持续返回 `200 OK`，说明 ChartAgent 进程和 FastAPI 事件循环当时仍然存活。
- 只找到 3 条 `/chart/generate` 访问结果，3 条最终都是 `200 OK`，没有 500、Traceback 或显式 LLM 超时。
- 前两条生成结果出现前，日志中穿插了大量约 10 秒一次的健康检查。结合客户端 120 秒超时，可以解释“客户端已经提示超时，但后端稍后仍记录 200”。
- 当前服务已经停止，检查 `http://127.0.0.1:8765/health` 时无法连接，因此本次没有直接重放用户的真实请求。

日志样例：

```text
INFO:     127.0.0.1:57386 - "GET /health HTTP/1.1" 200 OK
...中间持续出现健康检查...
INFO:     127.0.0.1:57386 - "POST /chart/generate HTTP/1.1" 200 OK

INFO:     127.0.0.1:57572 - "GET /health HTTP/1.1" 200 OK
...中间持续出现健康检查...
INFO:     127.0.0.1:57572 - "POST /chart/generate HTTP/1.1" 200 OK
```

### 日志自身的问题

`ChartServiceManager.startService()` 使用 `FileHandle(forWritingTo:)` 打开已有文件，但没有显式移动到文件末尾，也没有轮转策略。服务重启后可能从文件头覆盖旧内容并保留旧尾部，因此不能把当前 949 行全部视为严格连续的一次运行记录。

即使不考虑覆盖问题，Uvicorn 默认访问日志也只在请求结束后写一行。它不能回答请求何时开始、卡在哪个阶段、总共调用了几次 LLM。

## 3. 代码证据

### 客户端只有 120 秒等待时间

- `AIRecording/Services/HTTPChartSkill.swift:12`：`timeout = 120`。
- `AIRecording/Services/HTTPChartSkill.swift:38`：该值设置到 `/chart/generate` 请求。
- `AIRecording/Services/HTTPChartSkill.swift:50-51`：URLSession 超时直接映射为 `.timeout`。
- `AIRecording/Services/ChartSkill.swift:58`：用户看到“图表生成超时”。

### 后端一次生成可能调用多次 LLM

- `ChartAgent/agent/nodes.py:29`：每块字符预算为 5000。
- `ChartAgent/agent/nodes.py:71-75`：所有分块逐块、串行调用 LLM 做候选提取。
- `ChartAgent/agent/nodes.py:252-293`：候选提取结束后再调用一次 LLM 选图并生成 ChartPlan。
- `ChartAgent/agent/nodes.py:302-305`：计划校验失败时再调用一次 LLM 纠错。

因此一次请求的 LLM 调用数是：

```text
分块数 + 1 次路由 + 最多 1 次纠错
```

例如 3 个分块至少调用 4 次，失败纠错时调用 5 次。目前这些调用串行累加。

### 后端没有统一总时限

- `ChartAgent/agent/llm_client.py:23-31`：OpenAI 兼容接口没有设置显式超时，也没有为本请求设置剩余时间预算。
- `ChartAgent/agent/llm_client.py:45`：Ollama 的 120 秒只是单次调用超时，不是整个图表请求的总超时。
- `ChartAgent/main.py:41`：同步图通过 `asyncio.to_thread` 执行。这样健康检查仍能响应，但客户端断开并不会自动停止后台线程中的 LLM 流程。

## 4. 修复目标与验收标准

1. 同一条当前必现超时的录音，点击“生成图表”后能在客户端 120 秒时限内得到一张图表或“重点句子”降级结果。
2. 后端必须在 105 秒内返回成功或结构化失败，给网络传输和客户端解码预留 15 秒，不再让客户端先超时。
3. 任意单次 LLM 调用不能占满整个客户端 120 秒；超时和重试必须受剩余总预算约束。
4. 长录音不能因为分块数增加而无限串行等待。分块提取使用小规模限并发，并有明确并发上限。
5. 日志能用同一个 `requestId` 串起请求开始、分块数、每阶段耗时、供应商、结果和总耗时；不得记录 API Key、完整 Prompt 或完整转录。
6. 客户端超时后，后端不能继续无边界占用模型和 CPU；最迟在后端预算到期时终止后续阶段。
7. Python 与 Swift 的现有 SmartChart 测试全部通过，并新增超时、降级和日志回归测试。

## 5. 最小修复方案

### 步骤 1：先补可观测性并复现一次

修改范围：

- `ChartAgent/main.py`
- `ChartAgent/agent/nodes.py`
- `ChartAgent/agent/llm_client.py`
- `AIRecording/Services/ChartServiceManager.swift`

实施内容：

1. 后端增加统一 logger，日志格式至少包含：时间、级别、`requestId`、`recordingId` 哈希、阶段、分块序号/总数、耗时毫秒、供应商、模型、结果、错误类型。
2. 在 `request_received`、`prepare_transcript`、每个 `extract_chunk`、`route_and_plan`、`repair_plan`、`render`、`request_finished` 写阶段日志。
3. 不写 API Key、完整转录、完整 Prompt、LLM 原始响应。错误正文限制长度并去除敏感信息。
4. 修正 `chart-agent.log` 打开方式为真正追加；增加简单轮转，例如单文件 5 MB、保留 3 份，防止无限增长。
5. 用当前必现的录音重试一次，记录真实的分块数、慢阶段、模型调用次数和总耗时。

验证：

- 每次按钮点击只产生一个 `request_received` 和一个 `request_finished`。
- 所有阶段都能按 `requestId` 检索。
- 重启服务后旧日志不被覆盖，且新日志从文件尾继续写入。

### 步骤 2：建立一个端到端时间预算

修改范围：

- `ChartAgent/agent/llm_client.py`
- `ChartAgent/agent/nodes.py`
- `ChartAgent/main.py`
- `ChartAgent/agent/schema.py`

实施内容：

1. 为一次生成建立 105 秒 deadline，并把“剩余秒数”传入每个 LLM 调用。
2. OpenAI 兼容客户端设置显式请求超时和受控重试；禁止 SDK 隐式重试把总耗时推过 deadline。
3. Ollama 单次超时改为 `min(配置的单次上限, 剩余预算)`，不再固定每次都允许等待 120 秒。
4. 每个节点开始前检查剩余预算。预算不足时跳过新的 LLM 调用。
5. 后端返回可识别的错误码，例如 `TIMEOUT`、`LLM_UNAVAILABLE`、`INVALID_LLM_RESPONSE`，并保留用户可读错误信息。

验证：

- 使用极小测试预算和模拟慢 LLM，接口在预算到期后可预测地返回，不依赖真实等待 105 秒。
- 日志中的总耗时不超过测试预算加允许误差。

### 步骤 3：压缩长录音的实际耗时

修改范围：

- `ChartAgent/agent/nodes.py`
- `ChartAgent/agent/llm_client.py`

实施内容：

1. 保留现有 5000 字分块和本地规则提取，不改变图表内容协议。
2. 把分块 LLM 提取从完全串行改为限并发，默认并发数 2；结果仍按原始分块顺序合并，保证输出稳定。
3. 并发任务共用同一个总 deadline。任一任务失败时记录对应块，不允许无上限重试。
4. 至少预留一段预算给全局路由；如果分块提取消耗过多，停止未开始的块并使用已完成结果加本地规则候选。
5. 若进入计划纠错时剩余预算不足，跳过第二次 LLM 纠错，直接走现有的确定性 `highlights` 降级路径。

验证：

- 3 个模拟慢分块的总耗时接近两批调用，而不是三个调用耗时之和。
- 实际并发数从不超过 2。
- 不同完成顺序下，合并结果顺序和来源片段仍然稳定。
- 超时情况下仍返回可点击、可追溯来源的重点句子卡片。

### 步骤 4：客户端正确处理后端超时与迟到响应

修改范围：

- `AIRecording/Services/ChartSkill.swift`
- `AIRecording/Services/HTTPChartSkill.swift`
- `AIRecording/ViewModels/RecordingDetailViewModel.swift`

实施内容：

1. 客户端继续保留 120 秒硬上限；不采用“无限加长超时”的掩盖方案。
2. 解码后端结构化错误码，把后端 `TIMEOUT` 和 URLSession `.timedOut` 统一映射到可重试的图表超时错误。
3. 请求失败或取消时按 `requestId` 结束当前 UI 状态，防止旧请求的迟到结果覆盖用户后来发起的新请求。
4. 用户再次点击生成时取消客户端旧 Task；后端依靠 105 秒 deadline 和单次 LLM 超时停止后续工作。

验证：

- 后端主动超时时，UI 在 120 秒之前结束加载并显示可重试提示。
- 连续点击重新生成时，只展示最新请求的结果。
- 成功返回后仍能正常显示图表并点击定位到录音片段。

### 步骤 5：补回归测试

Python 测试：`ChartAgent/tests/test_smartchart.py`

- 单块、三块和需要纠错三种路径的 LLM 调用次数。
- 限并发最多为 2，并保持确定性合并顺序。
- OpenAI/Ollama 单次超时服从剩余总预算。
- 预算不足时跳过纠错并降级为 highlights。
- 接口返回结构化 `TIMEOUT`，且总耗时受控。
- 日志包含 requestId 和阶段耗时，不包含 Prompt、转录正文或密钥。

Swift 测试：`Tests/AIRecordingTests/SmartChartTests.swift`

- 后端 `TIMEOUT` 响应映射正确。
- URLSession `.timedOut` 映射正确。
- 旧 requestId 的迟到响应不能覆盖最新结果。
- 日志文件采用追加方式，服务重启不覆盖旧日志。

验证命令：

```bash
PYTHONPATH=ChartAgent /opt/anaconda3/bin/python3 -m unittest discover -s ChartAgent/tests -v
/opt/anaconda3/bin/python3 -m py_compile ChartAgent/main.py ChartAgent/agent/*.py
swift test --filter SmartChartTests
swift test
```

### 步骤 6：真实场景验收

准备三条录音：短转录（1 块）、中等转录（3 块）、当前必现超时的长转录。

每条录音验证：

1. 点击一次“生成图表”。
2. 记录 UI 完成时间、后端总耗时、分块数、模型调用数、最终图表类型。
3. 确认 UI 不出现客户端 120 秒超时。
4. 确认图表或重点句子卡片能显示。
5. 点击图中元素，确认可以定位到正确录音时间。
6. 对长录音再点一次“重新生成”，确认前一请求不会覆盖后一请求。

## 6. 不采用的方案

### 只把客户端超时从 120 秒调大

不采用。后端调用数会随分块数增长，且单次调用本身也可能长时间等待。把客户端改成 5 分钟只会让用户等得更久，不能建立可预测的完成时间，也不能阻止客户端放弃后的后台消耗。

### 只在 FastAPI 外层使用 `asyncio.wait_for(asyncio.to_thread(...))`

不作为唯一修复。它可以让 HTTP 提前返回，但不能可靠停止已经在线程中执行的同步 LLM 请求。必须同时给每次 LLM 调用设置硬超时，并在节点之间检查剩余预算。

### 重写整个 ChartAgent 或修改图表渲染器

不采用。现有证据表明故障发生在生成请求未及时返回，当前不需要重构模板、WebView、数据库或录音页面布局。

## 7. 风险与回滚

- **并发导致供应商限流**：并发默认只设为 2，并允许通过服务内部常量降为 1；不要先引入用户可见配置。
- **严格预算降低复杂图表成功率**：预算不足时返回可追溯的 highlights，比客户端直接超时且什么都不显示更符合产品目标。
- **日志泄露录音内容**：只记录计数、阶段、耗时和错误类型；加入自动测试阻止 Prompt、转录正文和密钥进入日志。
- **协议兼容风险**：新增错误码应保持现有成功响应字段不变；客户端先兼容“无错误码”的旧响应。

回滚时可以分别关闭分块并发并恢复串行，但应保留端到端 deadline、单次 LLM 超时和日志改进；这三项是防止再次出现无限等待的安全底线。

## 8. 预计改动边界

应只涉及 SmartChart 请求、ChartAgent 调用预算、服务日志和对应测试。不要顺手修改 AI 纪要、转录、图表视觉模板、Core Data 或其他页面。

当前工作区中 SmartChart 相关文件已有未提交修改。实施修复前必须先确认这些修改的所有权和预期，不覆盖或重排无关改动。
