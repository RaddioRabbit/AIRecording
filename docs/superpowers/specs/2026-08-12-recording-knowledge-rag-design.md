# 录音知识库 RAG 设计

**日期：** 2026-08-12

**状态：** 已获用户批准

**目标版本：** 本地单用户 MVP

**参考实现：** `/Users/radiorabbit/Desktop/WorkPlace/shudao-RAG`

## 1. 背景

AIRecording 已具备完整的录音、语音转写、AI 会议纪要、历史录音和本地持久化能力，但每条录音仍是孤立信息。用户希望把所有已完成的转写与会议纪要组织为一个全局知识库，能够跨会议提问，并从回答跳回具体录音和原始时间点。

参考项目 `shudao-RAG` 已验证以下机制：

- 大父块用于生成上下文、小子块用于精确检索的双层分块；
- DashScope 文本 embedding 与 rerank；
- 向量检索和 PostgreSQL FTS 并行召回，再用 RRF 融合；
- 检索子块映射回生成父块；
- 带来源的严格证据回答；
- embedding 或 rerank 不可用时的降级路径。

参考项目同时依赖 PostgreSQL/pgvector、Redis、MinIO、账号权限、文档解析和 Docker。这些能力不适合 AIRecording 的单机 macOS 产品定位，因此不能整体搬运。本设计只迁移 RAG 核心机制，并把数据与运行方式改为本机轻量实现。

## 2. 已确认的产品决策

1. 第一版知识库覆盖所有已完成转写的录音，不支持上传 PDF、Word 等外部资料。
2. 原始转写与会议纪要都参与检索，但原始转写是最终事实依据。
3. App 安装后不需要用户安装 Docker、Python、PostgreSQL、Redis 或 MinIO；首次使用云模型前仍需具备有效的模型密钥。
4. 最终问答复用当前 App 的 LLM 配置；DashScope 只负责 embedding 与 rerank。
5. 转写完成后自动入库；纪要生成或重新生成后自动更新；录音软删除后自动移除索引。
6. 主窗口侧边栏新增“知识库”入口，支持跨全部会议问答。
7. 问答记录按本地会话持久化，可新建、重命名和删除。
8. 证据不足时明确拒答，不允许模型使用常识补充未被知识库支持的事实。
9. 知识库页面使用两栏布局：左侧会话列表，右侧聊天；来源显示在每条回答下方。

## 3. 目标与非目标

### 3.1 目标

- 自动补建所有历史已完成转写的知识索引。
- 新转写与新纪要自动增量同步，内容未变化时不重复计算 embedding。
- 支持跨会议的自然语言问答和连续追问。
- 回答中的事实结论带可验证来源，可跳转到录音详情的原始时间点。
- KnowledgeAgent、DashScope 或 LLM 故障不影响录音、转写、纪要和历史记录。
- 索引可完全由 Core Data 中的现有数据重建。

### 3.2 非目标

- 外部文档上传与解析。
- 多用户、权限、云同步或团队共享。
- PostgreSQL、pgvector、Redis、MinIO、Docker。
- 图片、多模态检索、OCR 或表格问答。
- 用户可调的分块、Top-K、RRF 等技术参数。
- 对现有录音、转写或会议纪要流程做无关重构。

## 4. 方案选择

### 4.1 采用：轻量本地 KnowledgeAgent

新增独立的本地 Python 服务 `KnowledgeAgent`，使用 SQLite、FTS5、DashScope embedding/rerank 和本地向量相似度计算实现 RAG。Swift 负责业务事件、UI、聊天持久化、服务生命周期和录音定位。

该方案保留参考项目的高价值检索机制，同时满足无 Docker、单机本地、可重建和最小侵入要求。

### 4.2 未采用：整体搬运 shudao-RAG

整体搬运会引入数据库、对象存储、缓存、账号、文档摄入和部署系统，与当前产品范围冲突，运维成本过高。

### 4.3 未采用：纯 Swift 重写 RAG

纯 Swift 可以减少进程数量，但必须重新实现和验证参考项目已有的分块、融合、重排、父块映射和回答约束，开发风险更高。

## 5. 总体架构

### 5.1 Swift 层

#### KnowledgeBaseView / KnowledgeBaseViewModel

- 展示会话列表、消息、流式生成状态和内联来源。
- 创建、重命名、删除会话。
- 发送问题、取消生成、失败重试。
- 点击来源后打开对应录音详情，并跳转到 `startTime`。

#### KnowledgeSyncCoordinator

- 监听转写完成、纪要更新和录音软删除。
- App 首次启用知识库时扫描历史已完成转写。
- 计算 `contentHash`、`summaryHash` 和 `indexVersion`，只提交发生变化的数据。
- 管理补建进度、失败数量和重试。
- 不在主录音或转写流程中等待 RAG 同步完成。

#### KnowledgeClient

- 封装 KnowledgeAgent 的健康检查、入库、删除、查询、状态和索引重置接口。
- 解析流式回答事件和结构化来源。
- 将 Python 稳定错误码映射为用户可读状态。

#### KnowledgeServiceManager

- 启动和停止独立 KnowledgeAgent 进程。
- 使用服务版本和 API 版本校验，拒绝复用旧进程或外部进程。
- 复用 `ChartServiceManager` 已验证的本地进程、健康检查、环境变量注入和日志捕获模式，但不与图表服务共享业务模块或数据库。
- Release App 必须携带可用的 Python 运行时和 KnowledgeAgent 锁定依赖，不能要求最终用户运行 `pip install`；开发构建可复用仓库配置的 Python 环境。

### 5.2 KnowledgeAgent 层

KnowledgeAgent 按职责拆分为以下独立模块：

- `ingestion`：规范化录音数据、双层分块、内容哈希与原子替换；
- `store`：SQLite schema、事务、FTS5 和向量读写；
- `embedding`：DashScope 文档/查询 embedding 与批处理；
- `retrieval`：向量、FTS5、会议纪要路由、RRF 和录音级加权；
- `reranking`：DashScope rerank 与失败降级；
- `context`：子块到父块映射、去重、上下文预算和来源构建；
- `answering`：调用现有 LLM 配置、严格证据提示、引用校验和流式事件；
- `api`：本机 HTTP 契约、健康检查和稳定错误码；
- `observability`：结构化、安全、无正文日志。

KnowledgeAgent 不直接读取 Core Data，不扫描录音目录，也不拥有业务实体。Swift 通过明确 API 提交需要索引的数据。

### 5.3 数据所有权

- Core Data 是录音、转写、会议纪要、聊天和来源链接的业务真相来源。
- `knowledge.sqlite` 是可重建的派生索引，不是业务真相来源。
- 音频文件不复制到知识库目录。
- KnowledgeAgent 只监听 `127.0.0.1`，不暴露局域网或公网端口。

## 6. 本地数据模型

### 6.1 Core Data 新实体

#### KnowledgeChatSession

- `id: UUID`
- `title: String`
- `createdAt: Date`
- `updatedAt: Date`
- 与 `KnowledgeChatMessage` 一对多、级联删除。

#### KnowledgeChatMessage

- `id: UUID`
- `sessionId: UUID`
- `role: Int16`，取值为 user/assistant。
- `content: String`
- `status: Int16`，取值为 pending/completed/failed/cancelled。
- `errorCode: String?`
- `createdAt: Date`
- 与 `KnowledgeSourceLink` 一对多、级联删除。

流式生成期间正文只保存在内存。收到成功完成事件后才保存完整 assistant 消息；失败或取消时保存状态和错误码，不保存半截回答。

#### KnowledgeSourceLink

- `id: UUID`
- `messageId: UUID`
- `recordingId: UUID`
- `segmentId: UUID?`
- `startTime: Double`
- `endTime: Double`
- `sourceOrder: Int32`

来源不永久复制原始转写正文。页面根据 `recordingId`/`segmentId` 动态加载来源预览。录音已删除时，历史回答仍保留，但来源显示“录音已删除”。

### 6.2 knowledge.sqlite

#### documents

每条 Recording 对应一条记录：

- `recording_id`，主键；
- `content_hash`、`summary_hash`、`index_version`；
- `recorded_at`、`title`；
- `sync_status`、`last_error_code`、`updated_at`。

标题只用于本机来源展示和检索，属于本机业务数据，不进入日志。

#### chunks

- `id`、`recording_id`、`parent_id`；
- `role`：retrieval/generation/summary_route；
- `content`；
- `start_time`、`end_time`；
- `segment_ids`；
- `speaker_id`、`speaker_name`；
- `chunk_index`；
- `embedding`，紧凑二进制向量；
- `is_enabled`。

`summary_route` 只参与录音级路由，不可直接进入最终证据上下文。

向量以归一化 `Float32` 二进制保存。第一版不引入 ANN 服务或 SQLite 二进制扩展；查询时使用 KnowledgeAgent 随 App 携带的 NumPy 对候选矩阵执行批量余弦相似度计算。

#### chunk_fts

FTS5 虚拟表，只索引启用的 retrieval 与 summary_route 文本。generation 父块不直接参与检索。

#### sync_jobs

保存 recordingId、目标哈希、状态、尝试次数和稳定错误码，用于崩溃恢复和自动重试。成功任务在短期内清理，失败任务保留到成功或源录音删除。

### 6.3 文件位置与权限

索引位于 App 的 Application Support 目录下，例如：

`~/Library/Application Support/AIRecording/Knowledge/knowledge.sqlite`

目录权限为 `0700`，文件权限为 `0600`。SQLite 使用 WAL 模式，轮换或重建只允许操作 Knowledge 子目录内的固定文件名。

## 7. 入库数据流

### 7.1 触发条件

- 首次进入或启用知识库：扫描全部未软删除、转写状态为 completed 的录音。
- 新转写完成：后台提交该录音。
- 纪要首次生成或重新生成：后台更新该录音。
- 录音软删除：删除对应 documents、chunks、FTS 和向量。
- 索引版本变化：后台逐条重建。

### 7.2 哈希与幂等

- `contentHash` 基于按 sequence 排序后的 segmentId、startTime、endTime、speakerId 和 text 计算。
- `summaryHash` 基于清理代码围栏后的会议纪要正文计算；无纪要使用稳定空值。
- `indexVersion` 在分块算法、embedding 模型或向量维度变化时递增。
- 三者均未变化时，KnowledgeAgent 返回 unchanged，不调用 embedding。
- 仅 summaryHash 变化时，只替换 summary_route，不重复生成原始转写 embedding。

### 7.3 双层分块

第一版采用参考项目已验证的字符级语义边界分块：

- retrieval 子块：目标 250 字，重叠 25 字；
- generation 父块：目标 1500 字，重叠 150 字；
- 优先在段落、句号、分号、问号、感叹号和换行处切分；
- 子块必须是父块原文的连续子串，并保存 `parent_id`；
- 时间范围由子块或父块覆盖的首末 segment 决定；
- speaker 与 segmentId 映射必须保留。

父块不计算 embedding。retrieval 子块批量调用 DashScope `text-embedding-v4`，文档请求使用 document 类型，查询请求使用 query 类型。向量维度随模型响应记录，并由 `indexVersion` 防止混用。

### 7.4 会议纪要路由

会议纪要按 Markdown 标题和段落切为 summary_route 记录，包含 recordingId，但不指向原始 segment。它只用于判断“哪些会议可能相关”。

如果 summary_route 命中，检索器会在相应 recordingId 范围内追加一次原始 retrieval 子块检索。只有原始转写子块及其 generation 父块可以进入最终证据包。

### 7.5 原子替换

单条录音重新索引时，KnowledgeAgent 在事务内写入新版本记录。新片段、FTS 与向量全部成功后才切换启用版本并删除旧版本。任何阶段失败都回滚并保留上一份可用索引。

## 8. 检索与回答数据流

### 8.1 连续追问输入

检索文本由当前问题和同会话上一条用户问题组成；没有上一条时只使用当前问题。最终回答 LLM 最多接收最近 6 条已完成消息，但历史消息不能成为事实来源，只用于理解指代和对话意图。

### 8.2 并行候选召回

对同一个检索文本执行：

1. retrieval 子块向量检索；
2. retrieval 子块 FTS5 检索；
3. summary_route 向量与 FTS5 路由；
4. 对路由命中的前 3 条录音执行受 recordingId 限制的原始子块检索。

各路初始候选默认最多 40 条。summary_route 结果本身不得进入证据列表。

### 8.3 RRF 与 rerank

- 使用 RRF 合并各路原始子块排名，`k=60`。
- 同一子块去重；summary 命中的录音只获得路由加权，不自动成为证据。
- RRF 前 30 条交给 DashScope `gte-rerank-v2`。
- rerank 最多保留 10 条原始子块。
- rerank 不可用或超时时，直接使用 RRF 排名。

这些参数是第一版内部常量，不进入用户设置。后续只能依据真实录音基准测试独立调整。

### 8.4 父块回填与上下文预算

- 将命中的 retrieval 子块映射回 generation 父块。
- 同一父块只保留一次，并附带命中子块列表和分数。
- 父块按最相关子块顺序排序。
- 最多保留 6 个父块；总证据正文上限为 12,000 字，超出时按排名截断完整父块，不截断单个来源标记。
- 每个证据分配稳定来源 ID，例如 `S1`、`S2`，包含 recordingId、segmentIds、起止时间和 speaker。

### 8.5 严格证据回答

回答提示必须包含以下规则：

- 只能使用证据包中的原始转写；
- 对话历史与会议纪要不能作为事实来源；
- 每个事实性结论必须使用 `[S#]` 标记来源；
- 证据不足时直接说明“知识库中没有足够依据”；
- 不得用常识补全人物、数字、日期、责任人、决策或因果关系。

服务端只接受证据包中存在的来源 ID。除标题、纯过渡语和固定拒答语外，每个回答段落至少包含一个有效 `[S#]`；任一段缺少标记或引用不存在的来源 ID，均使用同一证据纠正一次。第二次仍无效则返回“知识库中没有足够依据”，并保留检索到的来源供用户人工查看。

### 8.6 流式响应

查询接口使用 SSE，事件顺序为：

1. `retrieval_started`
2. `sources`，返回本轮有效来源元数据；
3. 多个 `answer_delta`；
4. `answer_completed`，返回完整正文与最终来源顺序；或
5. `error`，返回稳定错误码和可重试标记。

Swift 只在 `answer_completed` 后持久化完整 assistant 消息。取消请求时停止 UI 更新并保存 cancelled 状态；服务端在可取消边界停止后续模型调用。

## 9. 本机 API 契约

第一版 KnowledgeAgent 提供：

- `GET /health`：服务状态、API 版本、服务版本、索引版本；
- `GET /knowledge/status`：文档数、片段数、待同步数、失败数、是否降级；
- `PUT /knowledge/recordings/{recordingId}`：幂等新增或更新一条录音；
- `DELETE /knowledge/recordings/{recordingId}`：删除一条录音索引；
- `POST /knowledge/query`：SSE 问答；
- `POST /knowledge/retry-failed`：重试失败同步；
- `POST /knowledge/reset-index`：只重置派生索引，随后由 Swift 重新提交源数据。

请求与响应使用严格 schema，拒绝未知字段。转写片段 text 为空时由 Swift 提交边界过滤，不放宽后端契约。

## 10. UI 设计

### 10.1 导航

`SidebarItem` 新增“知识库”，位于“录音列表”和“设置”之间。菜单栏不新增独立问答弹窗。

### 10.2 两栏知识库页面

左栏：

- “新建对话”按钮；
- 会话标题、最后更新时间；
- 重命名与删除菜单；
- 当前会话高亮。

右栏：

- 消息滚动区；
- 用户问题与 Markdown 回答；
- 每条回答下方的来源胶囊；
- 点击来源先展开短预览，再提供“跳到录音”操作；
- 输入框、发送/停止按钮和生成状态。

### 10.3 来源跳转

点击来源后：

1. 通过 recordingId 打开 RecordingDetailView；
2. 通过 segmentId 优先定位对应转写段；
3. segmentId 不存在时回退到 startTime；
4. 自动滚动、高亮该段，并把播放器 seek 到 startTime；
5. 录音已删除时禁用跳转，显示“录音已删除”。

### 10.4 状态与管理

知识库空状态说明会自动索引完成的转写。首次补建显示已完成/总数和失败数。设置页新增知识库状态区，显示索引数量、降级状态、重试失败任务和重建索引操作；不展示 embedding 分数或技术参数。

## 11. 配置与密钥迁移

### 11.1 允许迁移的参考项目配置

实施阶段只从参考项目 `.env` 迁移以下秘密值：

- `DASHSCOPE_API_KEY`

以下为非秘密模型配置，可在当前项目 `.env.example` 中给出默认值，不需要复制秘密值：

- `EMBEDDING_MODEL=text-embedding-v4`
- `RERANK_MODEL=gte-rerank-v2`

不迁移 `VLLM_*`、数据库、Redis、MinIO、JWT、MinerU、DashVector、多模态或道路检测配置。

### 11.2 安全顺序

实际复制任何秘密值前必须：

1. 在当前项目 `.gitignore` 中加入 `.env` 与 `.env.*`，但保留 `!.env.example`；
2. 确认 `.env` 未被 Git 跟踪；
3. 只把 `DASHSCOPE_API_KEY` 写入当前项目本地 `.env`；
4. 创建不含真实值的 `.env.example`；
5. 用只输出变量名、不输出变量值的检查验证配置。

`.env` 仅用于当前开发机器，不打入 App Bundle。KnowledgeServiceManager 按“进程环境变量 → 本地开发 `.env` → App 设置”的顺序解析 DashScope 配置，并只向 KnowledgeAgent 子进程注入所需变量。发行版由设置页提供 DashScope Key，使用 macOS Keychain 保存，界面只显示掩码。现有 LLM 密钥的存储方式不在本功能中重构。

最终回答继续复用现有 `llm.baseURL`、`llm.apiKey`、`llm.model`，由 KnowledgeServiceManager 以 `OPENAI_BASE_URL`、`OPENAI_API_KEY`、`LLM_MODEL` 注入子进程，不复制参考项目的 VLLM 配置。

## 12. 故障处理与降级

### 12.1 DashScope 密钥缺失或 embedding 失败

- 已有或新问题均可使用 FTS5 关键词检索。
- 跳过查询向量、向量召回和 rerank。
- UI 显示“语义检索暂不可用”，提供前往设置和重试同步。
- 录音同步仍保存 FTS5 片段，并标记 embedding degraded，配置恢复后补算缺失向量。

### 12.2 rerank 失败

- 使用 RRF 排名继续构建证据和回答。
- 不向用户显示阻断错误。
- 日志记录稳定错误码、模型名、候选数和耗时，不记录查询或片段正文。

### 12.3 LLM 失败或超时

- 不保存半截回答。
- 保存 failed 消息状态和稳定错误码。
- 保留用户问题与来源列表，支持原地重试。

### 12.4 KnowledgeAgent 不可用

- 使用健康检查、API/服务版本校验和旧进程清理自动恢复。
- UI 显示“知识库服务正在恢复”。
- 录音、转写、会议纪要、播放和历史聊天继续可用。

### 12.5 单条录音同步失败

- 回滚该次事务，保留上一份可用索引。
- sync_jobs 记录稳定错误码，并在首次失败后的 5 秒、30 秒和 120 秒各自动重试一次。
- 三次自动重试仍失败后，等待用户点击重试或源内容再次变化。

### 12.6 索引损坏或版本升级

- 停止查询，执行 WAL checkpoint，并使用 SQLite backup API 生成固定备份文件 `knowledge.sqlite.backup`；不得只移动主数据库而遗漏 WAL 内容。
- 创建新索引后由 Swift 逐条重新提交 Core Data 源数据。
- 成功后删除备份；失败时恢复备份并报告明确错误。
- 重建可取消，聊天数据不受影响。

## 13. 隐私与日志

- Swift 生产日志继续统一使用 `AppLogger`。
- Python 生产日志必须通过 KnowledgeAgent 自己的结构化日志入口，并由 Swift 捕获、清洗和轮转。
- 日志允许：请求 ID、阶段、耗时、数量、模型名、HTTP 状态、稳定错误码、哈希后的 recordingId。
- 日志禁止：API Key、问题正文、转写、纪要、回答、提示词、来源引用原文、录音标题、说话人姓名、完整文件路径、原始异常正文。
- 查询与索引事件使用 correlationId 跨 Swift/Python 关联。
- `knowledge.sqlite`、WAL、备份和日志文件均使用本机私有权限。

## 14. 测试策略

### 14.1 Python 单元测试

- 中文和英文语义边界分块、重叠与父子关系；
- segmentId、speaker、start/endTime 的继承与边界；
- contentHash、summaryHash 和 indexVersion 幂等；
- 仅纪要变化不重算原文 embedding；
- FTS5、向量检索、summary 路由、RRF 和去重；
- rerank 成功、失败和超时降级；
- summary_route 永不进入证据包；
- 子块映射到父块、上下文预算与来源顺序；
- 无效引用纠正一次后拒答；
- 原子替换、删除、重试和索引恢复；
- 日志不泄露密钥或用户正文。

### 14.2 Swift 单元测试

- 历史扫描条件与软删除过滤；
- 转写完成、纪要更新、录音删除的同步事件；
- 哈希稳定性与 unchanged 跳过；
- KnowledgeAgent 环境变量白名单和密钥优先级；
- SSE 事件解析、取消、失败和重试；
- 会话、消息和来源 Core Data 关系；
- 来源录音存在、片段缺失和录音已删除三种跳转状态；
- ViewModel 的生成状态不会被旧请求迟到响应覆盖。

### 14.3 契约与端到端测试

- Swift DTO 与 FastAPI schema 双向兼容；
- 首次启用自动补建历史录音；
- 新转写完成后无需人工操作即可检索；
- 纪要重生成后路由结果更新且原文 embedding 调用次数不变；
- 跨两次会议的问题返回正确答案和至少一个有效来源；
- 连续追问能使用上一条用户问题理解指代；
- 点击来源打开正确录音并定位时间点；
- 无依据问题返回固定拒答语义；
- DashScope 关闭时 FTS5 降级仍可回答关键词问题；
- 杀死 KnowledgeAgent 后自动恢复且不影响录音主流程；
- App 重启后聊天和索引仍存在；
- 删除录音后无法检索其内容，历史来源标记失效。

测试不得调用真实付费 API。DashScope 与 LLM 全部使用桩；另提供明确的手工真实配置验收步骤。

## 15. 验收标准

1. 历史与新增的已完成转写均能自动入库，未变化内容不会重复 embedding。
2. 用户能在独立知识库页面创建、重命名、删除并恢复本地聊天会话。
3. 跨会议问题能够返回基于原始转写的回答。
4. 每条事实性回答至少包含一个有效来源；来源能跳到正确录音和时间点。
5. 没有足够证据时明确说明知识库无依据，不补充外部常识。
6. 纪要能够改善相关会议召回，但绝不作为最终原话证据。
7. DashScope 或 rerank 失败时有可预测降级；LLM 或 KnowledgeAgent 失败时不损坏录音、索引或聊天。
8. 录音删除后，其内容从 FTS、向量与路由索引中全部移除。
9. 项目不需要 Docker、PostgreSQL、Redis 或 MinIO。
10. Git、App Bundle 和日志中不存在真实密钥或用户正文。

## 16. 实施边界与顺序

本设计适合一个实施计划，但必须按以下独立边界分阶段完成：

1. 配置安全与 KnowledgeAgent 最小进程骨架；
2. SQLite schema、双层分块和幂等入库；
3. FTS5、向量、summary 路由、RRF、rerank 和证据包；
4. 严格证据回答与 SSE 契约；
5. Swift 同步协调器、Core Data 聊天实体和客户端；
6. 知识库两栏页面与来源跳转；
7. 历史补建、删除、重试、恢复、日志与端到端验证。

详细任务拆分、测试先行步骤和具体文件清单由后续 writing-plans 阶段生成。本设计批准本身不授权在当前阶段复制密钥或修改生产代码。
