# ChartAgent

AIRecording 的智能图表服务（v5）：六种内容类型（会议/访谈/讲座/对话/演讲/随手记）统一渲染为思维导图，`other` 走重点句子兜底。使用 FastAPI、LangGraph、Pydantic 和 Jinja2。

## 工作方式

1. 内容分类器（1 次 LLM 调用）把录音判定为七种内容类型之一；置信度不足或失败归"其他"。
2. 六种类型由 `agent/skills/` 下的专属 skill 分块并行提取 → 合并 → 溯源校验 → 一次修复，随后由 `to_mindmap(plan)` 归一化为统一的 MindMapDoc（root → branches → children），`agent/mindmap.py` 的 MindMapRenderer 确定性渲染为 HTML + 内联 SVG（无 JavaScript）。
3. 响应同时携带 `mindMap` 结构数据；App 端大纲编辑后调 `POST /chart/render`（纯渲染、无 LLM、10s 预算）刷新预览。
4. 任何环节失败都沿"类型内兜底 → 重点句子"降级，保证任何录音都有输出；请求带 `forceContentType` 时跳过分类器。

## 安装

需要 Python 3 和以下依赖：

```bash
cd ChartAgent
python3 -m pip install -r requirements.txt
```

应用会依次查找 `CHART_AGENT_PYTHON`、随包 Python，以及常见 Python 安装位置，并验证运行环境包含所需依赖。

## LLM 配置

OpenAI 兼容接口：

```bash
export OPENAI_API_KEY="your-key"
export OPENAI_BASE_URL="https://api.openai.com/v1"
export LLM_MODEL="gpt-4o-mini"
```

或使用本地 Ollama：

```bash
export OLLAMA_MODEL="llama3"
```

Swift 启动服务时会继承这些环境变量。

## 启动和健康检查

```bash
PYTHONPATH=. python3 main.py
curl http://127.0.0.1:8765/health
```

健康响应中的 `apiVersion` 必须为 `4.0`，`serviceVersion` 为 `4.0.0`。

## 测试

```bash
PYTHONPATH=. python3 -m unittest discover -s tests -v
```
