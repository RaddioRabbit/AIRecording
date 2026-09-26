# 知识库配置补全(Embedding 模型 / 维度 / Rerank 模型)设计

- 日期:2026-08-29
- 状态:已获用户批准
- 关联:`docs/superpowers/specs/2026-08-12-recording-knowledge-rag-design.md`(本文件更新其 §11"配置迁移"的结论)

## 1. 背景与动机

`recording-knowledge-rag` 分支已完成知识库 RAG 端到端实现(33 个提交):录音转写内容与会议纪要自动入库(SQLite + FTS5 + NumPy 余弦相似度)、知识库问答 UI、来源引用跳转均已可用。

但配置不完善:设置界面"知识库"区只有 DashScope API Key 一项;`EMBEDDING_MODEL` / `RERANK_MODEL` 仅有代码默认值,只能靠环境变量或开发用 `.env` 覆盖;embedding 维度完全不可配置(模型返回多长就存多长)。用户要求参考 shudao-RAG(`chat-history-word-export` worktree)的配置机制,补全知识库相关配置。

### 决策记录(与用户逐项确认)

| 议题 | 结论 | 理由 |
|---|---|---|
| 存储方案 | **保留 SQLite,不迁移 pgvector** | 用户在了解权衡后(pgvector 为系统级独立数据库服务,需先安装并保持运行;SQLite 随 App 走、零依赖、开箱即用)选择 SQLite。个人录音知识库量级下检索性能足够。 |
| MinerU | **不引入** | MinerU 在 shudao-RAG 中的唯一作用是解析 PDF/Word 文档;本项目入库的是语音转写纯文本,用不到。用户确认无导入文档需求。 |
| 配置粒度 | **方案 B:模型预设下拉 + 维度联动 + 重建提示** | 覆盖用户列出的全部缺口(Embedding 模型输入、维度、Rerank 模型),同时防呆;不搬运 shudao 的分块/Top-K/阈值等内部参数(保持"不进用户设置"的原设计)。 |

## 2. 目标

1. 设置界面"知识库"区新增三项配置:Embedding 模型、向量维度、Rerank 模型。
2. 配置保存后立即生效(自动重启知识库后台服务,环境变量传递)。
3. Python 端调用 DashScope embedding 时显式携带 `dimension` 参数,入库与查询向量长度与配置一致。
4. 更换 Embedding 模型/维度后,用户可一键"重建知识库"(复用现有按钮)。

## 3. 非目标

- 不迁移 pgvector / 不引入 PostgreSQL、Docker、MinerU。
- 不将分块大小、Top-K、RRF 系数等检索内部参数暴露为用户设置(维持原设计)。
- 不做"配置与库内数据不一致"的动态检测(静态提示足够)。
- 不改存储层 schema、检索算法、同步链路、聊天 UI。

## 4. 配置项定义

### 4.1 UserDefaults 键(非机密,遵循现有 `llm.*` 命名风格)

| 键 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `knowledge.embeddingModel` | String | `text-embedding-v4` | 预设之外的值=自定义模型名 |
| `knowledge.embeddingDimension` | Int | 未设置(不存键) | 未设置时不注入环境变量,由模型 API 默认维度决定(v4 即 1024);仅在模型为预设项时生效;自定义模型时不设置该值 |
| `knowledge.rerankModel` | String | `gte-rerank-v2` | 同上 |

默认维度 1024 与当前已入库数据的实际向量长度一致(text-embedding-v4 未传 dimension 时的 API 默认值),**老用户升级后无需重建索引**。

### 4.2 模型预设表(仅 Swift 侧,UI 用;Python 不重复维护)

| 模型 | 可选维度 | 默认维度 |
|---|---|---|
| `text-embedding-v4` | 1024 / 1536 / 2048 / 768 / 512 / 256 / 128 / 64 | 1024 |
| `text-embedding-v3` | 1024 / 768 / 512 / 256 / 128 / 64 | 1024 |
| 自定义 | (维度控件隐藏,不传 dimension) | — |

Rerank 预设:`gte-rerank-v2`(默认)、`qwen3-rerank`、自定义。

预设表已于 2026-08-29 按官方文档核对:1536/2048 仅 v4 支持;`gte-rerank`(无版本号)已不在售,由在售的 `qwen3-rerank` 替换为第二预设;默认维度 1024 与老索引向量长度一致。

## 5. UI 设计(SettingsView"知识库"区)

在 DashScope API Key 行下方新增"检索模型"内容,自上而下:

1. Embedding 模型:`Picker`,选项 = 预设表 + "自定义";选"自定义"时显示 `TextField` 输入模型名。
2. 向量维度:`Picker`,选项 = 所选模型的维度列表;模型为"自定义"时隐藏本行。
3. Rerank 模型:`Picker`,选项 = 预设 + "自定义";同上显示 `TextField`。
4. 固定说明(caption,secondary 色):"更改向量模型或维度后,请点击『重建知识库』使已有内容用新模型重新入库。"

保存即写 UserDefaults(与密钥不同,这三项非机密,不进 Keychain)。

## 6. 生效机制

```
SettingsView 保存
  → UserDefaults 写入三项
  → KnowledgeServiceManager 重启服务(若在运行:stop + ensureRunning)
  → 子进程环境变量:EMBEDDING_MODEL / EMBEDDING_DIMENSION / RERANK_MODEL
  → Python KnowledgeConfig.from_environment 读取
```

- `KnowledgeServiceManager.serviceEnvironment` 已预留 `embeddingModel` / `rerankModel` 参数(KnowledgeServiceManager.swift:89-101),补 `EMBEDDING_DIMENSION` 与调用方传值。
- `developmentDotenvValues` 允许键集合(KnowledgeServiceManager.swift:110)增加 `EMBEDDING_DIMENSION`;`.env.example` 同步四行:`DASHSCOPE_API_KEY` / `EMBEDDING_MODEL` / `EMBEDDING_DIMENSION` / `RERANK_MODEL`。
- 解析优先级不变:进程环境变量 →(仅 DEBUG)KnowledgeAgent/.env → App 设置。App 启动服务时始终注入显式值,因此 App 场景下 UserDefaults 即最终来源;`.env` 仅供脱离 App 单独调试 Python 服务。
- 重启瞬间若有进行中的问答 SSE 流会中断,UI 已有错误+重试处理;同步任务有 5/30/120 秒自动重试,不丢数据。

## 7. Python 端改动(KnowledgeAgent)

- `agent/config.py`:`KnowledgeConfig` 新增 `embedding_dimension: int | None = None`;`from_environment` 读 `EMBEDDING_DIMENSION`,缺失或空白时静默按 `None` 处理;非法值(非数字或非正整数)记一条警告(仅错误码)并按 `None` 处理。
- `agent/embedding.py`:查询与文档两条 embedding 路径,当 `embedding_dimension` 非 `None` 时向 DashScope `TextEmbedding.call` 传 `dimension` 参数;`None` 时不传(行为与现状一致)。
- 存储层不改:chunks 表本就记录 `embedding_dimension` 并在检索时按查询向量维度过滤,历史混维度数据不会引发错误;重建后自然统一。
- Rerank、检索、问答链路不改。

## 8. 测试策略

- Swift 单测(XCTest):`serviceEnvironment` 注入包含新三项的各分支(有值/缺省/空串);UserDefaults 读写与默认值回退。
- Python 单测(pytest):`EMBEDDING_DIMENSION` 解析(有效/无效/未配置);embedding 调用参数断言(mock dashscope SDK,查询与文档路径均携带 dimension;`None` 时不携带)。
- 手工验收:
  1. 修改 Embedding 模型并保存 → 服务自动重启,`/health` 正常,提问可用;
  2. 修改维度 → 点击"重建知识库" → 重建后 chunks 的 `embedding_dimension` 与新配置一致,检索正常;
  3. 自定义模型 → 维度控件隐藏,API 调用不携带 dimension;
  4. 移除 DashScope API Key → 向量与 rerank 均降级,纯 FTS 检索仍可用(回归原有降级行为)。

## 9. 文件改动清单

| 文件 | 改动 |
|---|---|
| `AIRecording/Views/SettingsView.swift` | 知识库区新增"检索模型"UI(§5) |
| `AIRecording/ViewModels/SettingsViewModel.swift` | 三个配置项读写 + 预设表 |
| `AIRecording/Services/KnowledgeServiceManager.swift` | 传值 + `EMBEDDING_DIMENSION` 注入 + dotenv 允许键 + 重启钩子 |
| `KnowledgeAgent/agent/config.py` | `embedding_dimension` 字段与解析 |
| `KnowledgeAgent/agent/embedding.py` | 两条路径携带 dimension |
| `.env.example` | 增补 `EMBEDDING_DIMENSION` |
| 两侧测试文件 | §8 用例 |

## 10. 与原设计文档的关系

`2026-08-12-recording-knowledge-rag-design.md` §11"配置迁移"原结论:仅迁移 `DASHSCOPE_API_KEY` 入 App 设置,`EMBEDDING_MODEL` / `RERANK_MODEL` 留在 `.env.example`。本设计将其更新为:三项非机密模型配置进入 App 设置界面,密钥仍走 Keychain;其余"不迁移"项(VLLM_*、数据库、Redis、MinIO、JWT、MinerU、DashVector 等)维持不变。
