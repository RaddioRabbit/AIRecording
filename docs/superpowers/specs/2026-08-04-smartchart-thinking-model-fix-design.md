# 智能图表适配思考型模型(关闭思考)设计

日期:2026-08-04
状态:已实施(2026-08-04)
关联文档:`2026-07-17-smart-chart-timeout-design.md`(上一轮超时根治,已定 deepseek-v4-flash 为目标模型)

## 1. 问题与根因(已用日志 + 实测证实)

用户反馈:同样的会议录音,以前智能图表生成思维导图,现在生成的是"重点句子"列表(界面标签"会议 · 重点句子")。

以 requestId `EE9C76FE`(151 个片段,2 块)为例,`chart-agent.log` 时间线:

| 事件 | 结果 |
|---|---|
| `classify_content` | 分类正确:meeting,置信度 0.75 |
| `extract_chunk` chunk 0 | 失败:`LLMError` "模型调用超时"(TIMEOUT) |
| `extract_chunk` chunk 1 | 失败:`ValueError` "图表阶段执行失败" |
| `degrade_to_highlights` | reason=`extraction_empty` → 降级为重点句子 |
| `request_finished` | contentType=meeting,chartType=highlights |

**分类与路由逻辑没有任何代码变更**(git 历史确认),"思维导图变重点句子"不是路由回归,而是提取阶段 LLM 全部失败后的按设计降级。

两个直接故障的共同根因:**deepseek-v4-flash 是思考型(reasoning)模型**。

- 实测该模型响应带 `reasoning_content` 字段,回答前先输出大段推理;`max_tokens=10` 的小请求里 10 个 token 全部被推理耗尽,正文为空(`finish_reason=length`)。
- 故障一(超时):提取提示词含上万字会议记录,推理过程耗时超过单次调用上限 60s(`llm_client.py` `DEFAULT_SINGLE_TIMEOUT`),网络层超时。
- 故障二(解析失败):推理 token 吃光 `max_tokens=8192` 的输出额度,`message.content` 为空或 JSON 被截断,解析抛错。
- 上次能成功是概率性的:录音更短或那次推理较快。录音越长失败率越高。
- DeepSeek 已下架非思考模型(实测 `/v1/models` 只剩 `deepseek-v4-flash`、`deepseek-v4-pro`),"换不思考的模型"这条路不存在。

关键事实:DeepSeek API 支持按请求关闭思考——实测 `thinking: {"type": "disabled"}` 生效,同一模型秒回、无 `reasoning_content`。

## 2. 目标与非目标

目标:

- 图表流水线的所有 LLM 调用(分类、总览、提取)在 DeepSeek 上关闭思考模式,恢复秒级响应,思维导图稳定产出。
- 不影响其他服务商(OpenAI 及兼容端点)的既有行为。
- 留一个不依赖代码修改的开关,应对未来切换其他思考型服务商。

非目标:

- 不调整时间预算(60s 单次 / 105s 总预算在关闭思考后绰绰有余)。
- 不改动分类器、提示词、渲染、UI。
- 不改 Swift 侧;`LLMService.swift`(摘要等 AI 功能)不在本次范围。

## 3. 设计

### 3.1 核心改动:`ChartAgent/agent/llm_client.py`

`_call_openai` 在调用 `client.chat.completions.create` 时,按下面规则决定是否通过
`extra_body` 附带 `{"thinking": {"type": "disabled"}}`:

```python
def _thinking_disabled(base_url: str) -> bool:
    """CHART_LLM_THINKING=disabled|enabled|auto(默认 auto:仅 DeepSeek 关闭)。"""
    raw = os.environ.get("CHART_LLM_THINKING", "auto").strip().lower()
    if raw == "disabled":
        return True
    if raw == "enabled":
        return False
    return "deepseek" in base_url.lower()
```

- `auto`(默认):base_url 含 `deepseek` 时关闭思考;其他服务商不传该参数(避免
  OpenAI 等报"未知请求参数"错误)。
- `disabled` / `enabled`:强制覆盖,供未来切换其他思考型服务商或需要对比思考
  效果时使用。
- 无该环境变量时行为 = auto,现有部署零配置生效。
- `extra_body` 是 openai SDK 支持的官方扩展通道,不破坏类型检查。

为什么分类/总览/提取全部关闭思考:三个环节都是"读文本输出结构化 JSON"的抽取型
任务,深度推理对质量无实质提升,却是超时与截断的唯一来源。`call_llm` 是统一入口,
一处改动全覆盖。

### 3.2 时间预算:不动

关闭思考后实测同类调用为秒级,现有预算(`DEFAULT_SINGLE_TIMEOUT=60`、
`DEFAULT_TIME_BUDGET_SECONDS=105`、`ROUTE_RESERVED_SECONDS=25`)不变。

### 3.3 测试:`ChartAgent/tests/test_smartchart.py`

新增用例(mock `openai.OpenAI`,断言 `create` 收到的 `extra_body`):

1. base_url 为 DeepSeek、无环境变量 → 带 `thinking: disabled`。
2. base_url 为 OpenAI、无环境变量 → 不带 `extra_body`。
3. `CHART_LLM_THINKING=enabled` + DeepSeek → 不带;`CHART_LLM_THINKING=disabled` +
   OpenAI → 带(环境变量优先级高于自动判断)。

## 4. 验证

1. `cd ChartAgent && .venv/bin/python -m pytest tests/ -q` 全部通过(含新增用例)。
2. 用真实 DeepSeek key 对 `call_llm` 做一次真实调用:返回快、正文非空、无
   `reasoning_content`、JSON 可解析。
3. 用户在 app 中对之前失败的会议录音点"重新生成",确认恢复思维导图。

## 5. 风险与回退

- 风险:DeepSeek 未来变更 `thinking` 参数语义 → 有 `CHART_LLM_THINKING` 开关兜底;
  参数本身传错也只是被服务端忽略或报 400(走 `LLM_UNAVAILABLE` 日志,不会静默出
  错图)。
- 回退:设 `CHART_LLM_THINKING=enabled` 即恢复原行为,无需改代码。

## 6. 改动文件清单

- `ChartAgent/agent/llm_client.py` — `_thinking_disabled()` + `_call_openai` 附 `extra_body`
- `ChartAgent/tests/test_smartchart.py` — 3 个新用例
- `AGENTS.md` — 设计文档清单补本条
