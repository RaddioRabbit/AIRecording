# 智能图表"图表生成超时"根治设计

日期：2026-07-17
状态：待用户审阅
关联文档：`docs/debug/smart-chart/2026-07-17-smart-chart-timeout-fix-plan.md`、`2026-07-17-smart-chart-timeout-review-fixes-plan.md`（前两轮修复，已合入工作区）

## 1. 问题与根因（已用日志证实）

长录音点击"生成图表"总是显示"图表生成超时"。以 2026-07-17 13:41 的请求
（requestId `93DE7872`，326 个转录片段，总预算 105s）为例，日志时间线：

| 相对时间 | 事件 |
|---|---|
| +0s | 收到请求，切成 10 个块（每块 5000 字符） |
| +50.4s | 块 1 成功（deepseek-v4-pro，单次 50s） |
| +53.8s | 块 0 失败（JSONDecodeError，返回内容无效） |
| +80.2s | 块 2、3 超时（各只分到 ~26s）；块 4~9 直接跳过（提取预算耗尽，为路由预留 25s） |
| +104.5s | **端点外层 `asyncio.wait_for` 跳闸，返回"图表生成超时"** |
| +105.3s | 图线程其实完成了"路由超时 → 降级重点句子 → 渲染成功"，但响应早已发出，结果被丢弃 |

三层根因：

1. **截止竞态（决定用户看到什么）**：图内部 deadline = 请求开始 + 105s，而端点
   `wait_for` 在 +104.5s 触发。路由阶段的 LLM 超时最晚可到 +105s，比 `wait_for` 晚
   0.5s。于是上一轮设计的"超时后降级为重点句子"永远来不及送达，用户只看到
   "图表生成超时"。
2. **预算结构性不足（决定能否出真图表）**：326 片段 → 10 块，并发 2，单次 LLM
   调用 23~54s。提取阶段吃光全部预算，路由阶段只剩 ~25s，必然超时。
3. **模型配置**：当前后端进程带着 `LLM_MODEL=deepseek-v4-pro`（启动时的环境），
   响应慢；用户说明 deepseek-chat 即将下架，目标模型定为 **deepseek-v4-flash**。
   另：UserDefaults 生效域为 `AIRecording`（`com.airecording.app` 域为空），后端
   进程的环境变量在启动时固化，改配置后必须重启后端进程才生效。

## 2. 目标与非目标

目标：

- 任何录音点击"生成图表"，要么得到真图表，要么得到可点击定位的"重点句子"
  降级结果；不再把"图表生成超时"作为常态结果展示。
- 长录音（300+ 片段）配合 deepseek-v4-flash 能在预算内跑出真图表。
- 默认模型从 deepseek-chat 切换为 deepseek-v4-flash。

非目标：

- 不改动图表渲染模板、验证规则、UI 布局。
- 不引入流式/异步任务架构（仍然一次性请求-响应）。
- 不处理 `python -m http.server 8765`（PID 31024）以外的系统环境问题。

## 3. 设计

### 3.1 消除截止竞态（`ChartAgent/main.py`）

新增常量 `GRAPH_COMPLETION_MARGIN_SECONDS = 2.0`，含义：图内部所有 LLM 调用必须在
端点 `wait_for` 跳闸前至少 2s 结束，给"降级 + 渲染 + 序列化响应"留出确定的时间。

```python
graph_timeout = _graph_timeout_seconds(budget_seconds)      # 现状：budget - 0.5，给 wait_for 用
work_deadline = started + graph_timeout - GRAPH_COMPLETION_MARGIN_SECONDS
state["deadline"] = work_deadline                            # 原先是 started + budget_seconds
```

效果：路由阶段最迟在 work_deadline（约 +102.5s）拿到 LLMError.TIMEOUT → 走
`_degrade_route_to_highlights`（纯本地逻辑，毫秒级）→ 渲染（实测 1~14ms）→
+103s 内返回降级成功响应，早于 wait_for 的 +104.5s。竞态结构性消除。

`wait_for` 保留不动：它是图完全失控时的最后保险，此时仍返回 TIMEOUT（合理）。

### 3.2 预算再平衡（`ChartAgent/agent/nodes.py`）

- `CHUNK_CHARACTER_BUDGET = 5000` → `12000`：同样 326 片段从 10 块降为约 5 块，
  LLM 调用次数减半。
- `EXTRACTION_CONCURRENCY = 2` → `4`：5 块只需 2 波（原先 5 波）。DeepSeek API
  承受 4 并发无压力。`_extraction_concurrency()` 的环境变量钳制随常量自动变为 4。
- `ROUTE_RESERVED_SECONDS = 25.0` 不变：配合 3.1，路由始终有确定预算。

预期时序（deepseek-v4-flash 按 5~15s/次估算）：提取 2 波 ≈ 20~30s，路由 ≈ 10s，
总计 30~40s < 102.5s，裕量充足。即使模型偶发变慢，3.1 保证用户拿到降级结果而非报错。

### 3.3 默认模型切换为 deepseek-v4-flash

代码默认值（3 处）：

- `AIRecording/ViewModels/SettingsViewModel.swift:96` `?? "deepseek-chat"` → `?? "deepseek-v4-flash"`
- `AIRecording/Services/LLMService.swift:80` 同上
- `AIRecording/Services/ChartServiceManager.swift:145` 同上

已存储的用户配置（会覆盖代码默认值，必须迁移）：

- `defaults write AIRecording llm.model deepseek-v4-flash`
- `defaults write com.airecording.app llm.model deepseek-v4-flash`（保险起见两个域都写）

`ChartAgent/agent/llm_client.py` 的 `gpt-4o-mini` 默认值不动：那是 OpenAI 官方路径
的缺省，Swift 侧总会传 LLM_MODEL，走不到这里。

### 3.4 运维步骤（实现末尾执行）

1. 结束后端进程 PID 67998（App 心跳会自动用新配置重新拉起）。
2. 结束残留进程 `python -m http.server 8765`（PID 31024，7月15日遗留）。
3. 用 `Scripts/build-app.sh` 重新构建并安装 .app（会写入 /Applications，
   执行前需用户确认）。
4. 端到端验证：对 326 片段的录音点"生成图表"，确认出现真图表或重点句子，
   且日志中 `request_finished` 的 result 为 success。

## 4. 错误处理

- 路由 LLM 超时/预算不足 → 降级重点句子（现有逻辑，修完竞态后真正生效）。
- 连重点句子都组不出来（极端短/无意义转录）→ 返回 failed +
  "图表生成超时，且没有可用的重点句子"，诚实报错（现有逻辑不变）。
- 图完全失控（死循环等）→ 端点 `wait_for` 返回 TIMEOUT（现有逻辑不变）。

## 5. 测试

### Python（`ChartAgent/tests/test_smartchart.py`）

- **新增回归测试（竞态）**：fake LLM 每次调用都阻塞到 deadline 才超时，通过
  FastAPI TestClient 请求 `/chart/generate`，断言响应 `status == "success"`、
  `chartType == "highlights"`、无 `errorCode`。（修复前该场景返回 TIMEOUT。）
- **夹具更新**：`three_chunk_segments` 等注释与构造基于 5000 字符预算（每段
  ~3.3KB 恰好 3 块）。预算改为 12000 后需把每段加大到 ~5KB，保持"恰好 3 块"
  的测试前提不变，涉及：
  `test_three_chunk_transcript_calls_llm_once_per_chunk_plus_route`、
  `test_chunk_extraction_is_limited_to_two_concurrent_calls`、
  `test_chunk_results_merge_in_original_chunk_order`、
  `test_chunk_calls_receive_deadline_before_route_reserve`。
- **钳制测试更新**：`test_extraction_concurrency_environment_is_clamped_to_two`
  改为断言钳制到 4。

### Swift（`Tests/AIRecordingTests/SmartChartTests.swift`）

- 检查并更新对 `deepseek-chat` 默认值的断言（如有）。
- 现有 TIMEOUT → ChartSkillError.timeout 映射测试保持不变（端点兜底路径仍在）。

### 验证命令

- `cd ChartAgent && python3 -m pytest tests/ -q`
- `swift build && swift test`
- 3.4 的端到端验证。

## 6. 影响面

| 文件 | 改动 |
|---|---|
| `ChartAgent/main.py` | 新增余量常量，deadline 计算 |
| `ChartAgent/agent/nodes.py` | 两个常量调大 |
| `ChartAgent/tests/test_smartchart.py` | 新增竞态回归测试 + 夹具/钳制更新 |
| `AIRecording/ViewModels/SettingsViewModel.swift` | 默认模型 |
| `AIRecording/Services/LLMService.swift` | 默认模型 |
| `AIRecording/Services/ChartServiceManager.swift` | 默认模型 |
| `Tests/AIRecordingTests/SmartChartTests.swift` | 视断言情况更新 |

另注意：工作区已有未提交的前两轮修复改动，本次实现只动上表文件，不夹带其他变更。
