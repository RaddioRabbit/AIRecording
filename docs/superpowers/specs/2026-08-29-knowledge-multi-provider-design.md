# 知识库检索服务多供应商配置(去重 API Key + OpenAI 兼容)设计

- 日期:2026-08-29
- 状态:方向已获用户确认(三项选择题均选推荐项)
- 关联:`2026-08-29-knowledge-config-completion-design.md`(上一轮:模型/维度/Rerank 下拉)、`2026-08-12-recording-knowledge-rag-design.md`(RAG 主设计)

## 1. 问题与根因(investigate 结论)

| 现象 | 根因 |
|---|---|
| 设置里"两个 DashScope API Key" | `SettingsView.swift` 知识库区先有一行"DashScope API Key"显示已存值(打码),紧接一个占位文字完全相同的输入框 + 独立保存按钮,无"当前值/新值"标识,看起来像重复配置(SettingsView.swift:118-135)。另 Fun-ASR 弹窗还有第三个阿里云 Key(转录用,独立功能)。 |
| 只能配 DashScope 的 Key | 整链路写死:Swift 只注入 `DASHSCOPE_API_KEY`;Python `embedding.py` 只走 dashscope SDK。 |
| Rerank 不能配别家 | `KnowledgeModelCatalog.rerankModelNames` 只有 DashScope 模型;rerank 只走 `dashscope.TextReRank`。 |

关键有利条件:`openai` SDK 已在 `requirements.txt`(回答链路 `answering.py:28-57` 已有 OpenAI 兼容客户端先例);Jina/硅基流动/Cohere 等 rerank 均用同一 `{base}/rerank` 标准形状。

## 2. 决策记录(用户确认)

1. 供应商范围:**DashScope + OpenAI 兼容接口**(可填 base url)两种,不逐家 bespoke 适配。
2. Rerank:**独立配置**(自己的供应商/Key/Base URL/模型),不跟 Embedding 绑定。
3. Fun-ASR 转录的阿里云 Key:**不动**,保持独立。

## 3. 目标 / 非目标

**目标:** 知识库区不再出现重复的 Key 配置;Embedding 与 Rerank 均可在"阿里云百炼"与"OpenAI 兼容接口"间选择;OpenAI 兼容时可配 Base URL + API Key + 模型名;老配置(不设任何新项)行为与升级前完全一致。

**非目标:** 不动 Fun-ASR 密钥;不做逐厂商 bespoke 适配;不做"关闭 rerank"开关;不做配置与库内数据不一致的动态检测。

## 4. 配置模型

### 4.1 UserDefaults(非机密)

| 键 | 取值 | 默认(缺省=升级前行为) |
|---|---|---|
| `knowledge.embeddingProvider` | `dashscope` \| `openai` | `dashscope` |
| `knowledge.embeddingBaseURL` | String | 空(dashscope 不需要) |
| `knowledge.rerankProvider` | `dashscope` \| `openai` | `dashscope` |
| `knowledge.rerankBaseURL` | String | 空 |
| `knowledge.embeddingModel` / `knowledge.embeddingDimension` / `knowledge.rerankModel` | (沿用) | 沿用 |

维度语义按供应商区分:DashScope → 必须在预设表内(沿用现有守卫);OpenAI 兼容 → 0=自动(不传 dimensions),>0 直接透传。

### 4.2 Keychain(机密,按服务分账户)

- 同一 service `com.airecording.knowledge` 下新增账户:`embedding-api-key`、`rerank-api-key`。
- 旧账户 `dashscope-api-key` 保留为**只读回退**:新账户为空时读取旧值(注入环境变量与界面显示),用户下次保存新 Key 时写入新账户。不做破坏性迁移。旧账户回退仅对 dashscope 供应商生效;openai 供应商只认新账户专属 Key。

### 4.3 环境变量契约(Swift → Python)

| 变量 | 说明 |
|---|---|
| `EMBEDDING_PROVIDER` / `RERANK_PROVIDER` | `dashscope`(缺省) \| `openai` |
| `EMBEDDING_API_KEY` / `RERANK_API_KEY` | 各服务自己的 Key(Swift 从 Keychain 注入) |
| `EMBEDDING_BASE_URL` / `RERANK_BASE_URL` | 仅 `openai` 供应商需要 |
| `EMBEDDING_MODEL` / `EMBEDDING_DIMENSION` / `RERANK_MODEL` | 沿用 |
| `DASHSCOPE_API_KEY` | 保留为旧版兼容回退:仅当对应服务的专属 Key 未设置时使用(解析顺序:`EMBEDDING_API_KEY`/`RERANK_API_KEY` → `DASHSCOPE_API_KEY`) |

`OPENAI_API_KEY` / `OPENAI_BASE_URL` 继续专用于回答 LLM,与 embedding/rerank 无关,命名不冲突。

## 5. UI 设计

**知识库区(SettingsView 主界面):** 删除"DashScope API Key"状态行、SecureField 输入框、"保存知识库密钥"按钮(3.1 去重)。保留:Embedding/Rerank/维度展示行(Embedding/Rerank 行显示"供应商 · 模型")、"配置检索服务"按钮(原"配置检索模型"更名)、重建提示、统计、重试/重建按钮。

**配置检索服务弹窗(KnowledgeModelConfigSheet 扩展):** 上下两组——

- **Embedding 服务:** 供应商 Picker(阿里云百炼 / OpenAI 兼容接口)→ API Key SecureField(占位显示"已保存 ••••"或"未配置";留空=不修改)+ Base URL TextField(仅 OpenAI 兼容时显示)+ 模型(DashScope→预设 Picker+自定义;OpenAI 兼容→自由文本)+ 维度(DashScope→预设 Picker;OpenAI 兼容→自动/512/1024/1536/2048/3072 Picker)。
- **Rerank 服务:** 同构(供应商/Key/Base URL/模型;无维度)。
- 保存:写 UserDefaults + 非空 Key 写 Keychain → 重启服务(沿用 isSaving 防连点)。Key 留空 = 保持现有值(明确文案提示)。

## 6. Python 端

- `config.py`:新增 `embedding_provider` / `rerank_provider`(缺省 `dashscope`,非法值警告+回退)、`embedding_base_url` / `rerank_base_url` 字段;provider 与 base_url 从环境变量解析。
- `embedding.py`:`DashScopeAdapter` 增加供应商分发。Embedding `openai` 路径:`AsyncOpenAI(api_key, base_url).embeddings.create(model, input, dimensions=?)`(按 `data[].index` 对齐,归一化与失败降级契约不变);Rerank `openai` 路径:httpx `POST {base}/rerank`,body `{model, query, documents, top_n}`,解析 `results[].index`(与 DashScope 同形状)。dashscope 路径与 Key 解析优先级不变。所有 provider 失败一律静默 `[None]`/`None` 降级,不记用户文本。
- `main.py`:装配处传入 provider/base_url。

## 7. 测试策略

- Python:新环境变量解析(合法/非法/缺省);openai embedding 路径(注入假客户端,断言 model/input/dimensions 缺省行为);openai rerank 路径(注入假 httpx 客户端,断言 URL/body/解析);供应商回退与向后兼容(无新环境变量 = 现行为)。
- Swift:Keychain 多账户读写 + 旧账户回退;`serviceEnvironment`/`resolvedConfiguration` 按 provider 注入各分支;ViewModel 保存流(provider/baseURL/Key 留空保持);界面仅 SwiftUI 无单测,靠 VM 测试 + build。
- 手工验收:DashScope 老配置升级不动照样用;切 OpenAI 兼容(如硅基流动)填 base url+key+模型后入库与问答正常;知识库区无重复 Key 字样。

## 8. 文件改动清单

`KnowledgeAgent/agent/config.py`、`embedding.py`、`main.py`、`.env.example` + 各自测试;`AIRecording/Services/KnowledgeCredentialStore.swift`、`KnowledgeServiceManager.swift`、`ViewModels/SettingsViewModel.swift`、`Views/SettingsView.swift` + 相关测试。
