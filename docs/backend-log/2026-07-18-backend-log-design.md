# AIRecording 统一后台日志机制设计

**日期：** 2026-07-18

**状态：** 已通过设计评审

**范围：** Swift 主程序与 Python `ChartAgent` 后台服务

## 1. 背景

项目当前存在两套不一致的日志方式：

- Swift 生产代码中散落着大量 `print(...)`，日志没有统一格式、等级、隐私规则或持久化位置。
- Python `ChartAgent` 已通过 `observability.py` 输出 JSON Lines，并由 `ChartServiceManager` 重定向到 `~/Library/Logs/AIRecording/chart-agent.log`。该文件已有启动时轮转逻辑，但缺少 Swift 侧统一入口，也不能保证长时间运行时及时轮转。

本设计建立一套统一规范、分文件写入的后台日志机制。它用于开发和故障排查，不增加面向用户的日志界面。

## 2. 目标

1. Swift 与 Python 日志统一使用结构化 JSON Lines。
2. 所有运行时日志集中保存在 macOS 标准用户日志目录 `~/Library/Logs/AIRecording/`。
3. Swift 与 Python 分别写入独立文件，避免跨进程文件竞争。
4. 每个模块采用 5 MiB（`5 * 1024 * 1024` 字节）、共 3 份文件的轮转策略。
5. 使用同一个关联 ID 串联 Swift 请求与 Python 后台处理过程。
6. 默认不记录密钥、录音正文、提示词、模型原始响应等敏感信息。
7. 日志创建、写入或轮转失败不得影响录音、转录、图表生成等核心业务。

## 3. 非目标

本次不实现以下能力：

- App 内日志查看器。
- 设置页中的“打开日志目录”或“导出诊断包”。
- 日志上传、远程收集或崩溃报告平台接入。
- 按天归档、压缩归档或用户可配置的保留策略。
- 修改历史设计文档、测试夹具或与日志无关的业务代码。

## 4. 已选方案

采用“统一规范、分文件记录”：

```text
~/Library/Logs/AIRecording/
├── app.log
├── app.1.log
├── app.2.log
├── chart-agent.log
├── chart-agent.1.log
└── chart-agent.2.log
```

- Swift 主程序只写 `app.log`。
- Python 后台输出只写 `chart-agent.log`。
- 两边遵守相同的字段、等级、隐私和轮转规则。
- 两个进程不直接写同一个文件；跨模块排查依赖 `correlationId`。

未选择单文件合并方案，因为 Swift 与 Python 同时写入和轮转同一文件会引入跨进程竞争。未选择 Swift 仅使用 macOS Unified Logging 的方案，因为它不能满足日志集中保存在专用目录中的目标。

## 5. 架构

### 5.1 Swift 日志组件

#### `AppLogger`

Swift 生产代码的唯一日志入口，职责是：

- 接收日志等级、分类、事件名、关联 ID、安全消息和结构化字段。
- 将原始录音 ID 转为 12 位 SHA-256 哈希。
- 调用敏感信息过滤器。
- 将写入任务异步交给 `FileLogWriter`，不阻塞主线程或音频实时线程。
- 文件日志不可用时，降级到 macOS Unified Logging。

业务代码不直接操作目录、文件句柄或轮转逻辑。

#### `FileLogWriter`

进程内唯一文件写入器，职责是：

- 使用内部串行队列维护写入顺序和文件句柄。
- 创建日志目录和目标文件。
- 将每条记录编码为单行 JSON，追加换行符后写入。
- 在追加前检查预计文件大小，并在需要时调用 `LogRotator`。
- 在应用结束或写入器释放时关闭文件句柄。

Swift 调用方只负责提交日志事件，不等待磁盘写入完成。单个写入失败不会向业务调用方抛出错误。

#### `LogRotator`

同时服务于 `app.log` 和 `chart-agent.log`，只负责已知目标文件的轮转：

1. 删除最旧的 `.2.log`。
2. 将 `.1.log` 移动为 `.2.log`。
3. 将当前 `.log` 移动为 `.1.log`。
4. 创建新的当前日志文件并重新打开句柄。

轮转操作只在对应 `FileLogWriter` 的串行队列中执行。

#### `LogSanitizer`

集中执行字段白名单、消息截断和二次脱敏。日志调用方不能绕过该组件直接写文件。

### 5.2 Python 后台日志组件

`ChartAgent/agent/observability.py` 继续作为 Python 业务代码的唯一结构化日志入口：

- `log_event(...)` 输出单行 JSON 到标准输出。
- 日志字段改为与 Swift 公共结构一致。
- 现有录音 ID 哈希和安全错误字段能力保留。
- Python 业务代码不得直接打印请求正文、响应正文或异常原文。

`ChartServiceManager` 使用独立的标准输出和标准错误管道启动 Python 进程，并持续异步读取两个管道：

- 已是有效公共日志结构的 JSON 行，经过 Swift 侧二次脱敏后写入 `chart-agent.log`。
- 普通 `stdout` 行包装成 `process_output` 事件。
- 普通 `stderr` 行包装成 `process_error` 事件。
- 即使文件写入失败，两个管道仍继续排空，避免 Python 因管道缓冲区填满而阻塞。

`ChartServiceManager` 不再把打开的文件句柄直接赋给 `Process.standardOutput` 和 `Process.standardError`；它通过日志写入器获得运行期间轮转能力。

### 5.3 数据流

```text
Swift 业务代码
  → AppLogger
  → LogSanitizer
  → JSON 编码
  → FileLogWriter(app)
  → app.log

Python observability.py / stdout / stderr
  → Process 管道
  → ChartServiceManager 持续读取
  → 格式规范化与 LogSanitizer
  → FileLogWriter(chartAgent)
  → chart-agent.log
```

## 6. 公共日志结构

每条日志是一行完整 JSON。字段名使用 lower camel case。

### 6.1 必填字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `ts` | String | UTC ISO 8601 时间，包含毫秒 |
| `level` | String | `debug`、`info`、`warning`、`error`、`critical` |
| `process` | String | `app` 或 `chart-agent` |
| `category` | String | 稳定的功能分类，如 `recording`、`transcription`、`chart`、`persistence`、`process` |
| `event` | String | 稳定、机器可读的事件名，如 `transcription_started` |

### 6.2 可选字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `correlationId` | String | 串联同一次跨模块操作的 UUID |
| `recording` | String | 原始录音 ID 的 12 位 SHA-256 哈希 |
| `message` | String | 经过审核和脱敏的简短说明，最长 200 个字符 |
| `durationMs` | Number | 操作耗时，单位毫秒 |
| `errorCode` | String | 稳定错误码，不使用完整异常文本 |
| `metadata` | Object | 通过白名单检查的非敏感标量字段 |

示例：

```json
{"ts":"2026-07-18T10:30:25.123Z","level":"info","process":"app","category":"transcription","event":"transcription_started","correlationId":"7AA1E39B-148B-4C11-B5B9-C10DF50BCA91","recording":"a91463c8d72b","message":"开始转录"}
```

### 6.3 日志等级

| 等级 | 使用场景 | Release 默认写入 |
|---|---|---|
| `debug` | 开发调试细节 | 否 |
| `info` | 正常流程的重要节点 | 是 |
| `warning` | 操作降级、可重试异常或非致命问题 | 是 |
| `error` | 单次操作失败 | 是 |
| `critical` | 服务无法启动、持久化不可用等严重故障 | 是 |

Debug 构建写入全部五个等级；Release 构建从 `info` 开始写入。本次不增加用户可配置的日志等级。

## 7. 关联 ID

- 每个跨模块操作在 Swift 入口创建或复用一个 UUID 字符串作为 `correlationId`。
- 图表生成沿用请求中的 `requestId` 值，但序列化到日志时统一使用字段名 `correlationId`。
- Python 收到请求后，在该请求的所有阶段事件中透传相同值。
- 不涉及 Python 的 Swift 本地流程也可使用 `correlationId` 串联开始、重试和结束事件。
- 没有关联操作的生命周期日志可以省略该字段，不生成无意义的 ID。

## 8. 文件生命周期与轮转

### 8.1 创建

- 首次产生日志时创建 `~/Library/Logs/AIRecording/`。
- 目录权限设为 `0700`，日志文件权限设为 `0600`；初始化时发现权限更宽则主动收紧。
- 已存在的正确目录和日志文件直接复用，不清空当前内容。
- 新内容始终追加，应用重启不得覆盖旧日志。

### 8.2 轮转

- 每个当前日志文件上限为 5 MiB，即 `5 * 1024 * 1024` 字节。
- 写入器在每次追加前计算“当前大小 + 下一条记录大小”。超过上限时先轮转，再写入新文件。
- 每个模块最多保留当前文件、`.1.log` 和 `.2.log` 三份，总占用约 15 MiB。
- `app.log` 与 `chart-agent.log` 独立计算和轮转。
- 启动时也执行一次大小检查，以兼容升级前已经超过上限的日志。

### 8.3 清理边界

轮转器只能操作以下明确文件名：

- `app.log`、`app.1.log`、`app.2.log`
- `chart-agent.log`、`chart-agent.1.log`、`chart-agent.2.log`

不得递归扫描日志目录，也不得删除其他文件。

## 9. 隐私与安全

### 9.1 禁止记录

- API Key、Bearer Token、Authorization Header。
- OSS 或其他服务的完整预签名 URL、签名参数。
- 录音标题、转写正文、摘要正文、提示词、模型原始响应。
- 网络请求和响应的完整 Body。
- 音频或用户文件的完整路径、用户目录名称。
- 未经审核的 `Error.localizedDescription`、异常堆栈或原始异常文本。

### 9.2 允许记录

- 稳定错误类型、错误码和人工定义的安全说明。
- HTTP 状态码、耗时、重试次数。
- 文件扩展名、文件大小、采样率、声道数量。
- 请求 ID、哈希后的录音 ID。
- 转录片段数、图表类型等不包含正文的统计和枚举值。

### 9.3 双层保护

1. 日志 API 只接收约定好的结构化字段，业务调用点不传原始对象或请求体。
2. `LogSanitizer` 在落盘前再次遮盖密钥、Bearer Token、Authorization 值、URL 签名等常见敏感模式，并截断 `message`。

迁移现有 `print(...)` 时，包含 HTTP 原始响应、转录内容、文件完整路径或异常原文的输出必须改为安全的状态码、计数、错误类型和稳定错误码，不能原样搬入新日志。

## 10. 故障处理

日志系统遵循“可观测性失败不影响业务”的原则：

- 目录创建、文件打开、编码或写入失败时，不向录音、转录或图表业务抛出错误。
- Swift 文件日志失败时，使用独立的 macOS Unified Logging logger 记录一次降级事件，避免递归进入 `AppLogger`。
- 轮转失败时保留当前文件并尝试继续追加；本次运行不重复刷同一种内部错误。
- Python 管道读取与文件写入解耦。文件写入失败时仍继续读取和丢弃已脱敏的后台输出，防止子进程阻塞。
- 单条 Python 输出不是合法 JSON 时，将其作为经过脱敏和截断的 `process_output` 或 `process_error` 消息处理，不让解析错误中断读取循环。
- 后台进程退出时先排空管道中的剩余数据，再关闭对应日志句柄。

## 11. 迁移范围

本次实现应完成以下迁移：

1. 新增 Swift 统一日志组件及其测试。
2. 将 `AIRecording/` 生产代码中的现有 `print(...)` 全部替换为 `AppLogger` 调用。
3. 改造 `ChartServiceManager` 的 Python 输出捕获，使运行期间可以轮转。
4. 对齐 Python `observability.py` 的字段名、等级和隐私规则。
5. 保留当前 `chart-agent.log` 文件名和已有内容，升级后无须迁移用户历史日志。

不改动测试中的临时输出、历史文档中的示例代码或第三方框架内部日志。

## 12. 测试设计

### 12.1 Swift 单元测试

- 首次写入自动创建目录和文件，后续启动采用追加方式。
- 目录权限为 `0700`，文件权限为 `0600`。
- 多任务并发提交日志后，每行都是完整、可解析的 JSON。
- 五个日志等级正确编码，Release 过滤规则可独立测试。
- 写入前超过 5 MiB 时立即轮转。
- 连续多次轮转后只保留当前文件和两份历史文件，顺序正确。
- `app.log` 和 `chart-agent.log` 的轮转互不影响。
- 敏感样本经二次过滤后不包含密钥、Token、签名 URL、正文或完整路径。
- 不可写目录、失效文件句柄和轮转失败不会使调用方失败。
- 非 JSON 子进程输出被包装为合法结构化日志。

所有文件测试使用独立临时目录，并在测试成功或失败后清理测试创建的文件。

### 12.2 Python 单元测试

- `log_event(...)` 输出公共字段结构和五级日志值。
- 原始录音 ID 只输出哈希。
- 安全错误字段不输出异常原文。
- `message` 中的密钥、Bearer Token 和签名信息被遮盖并限制长度。
- `correlationId` 在一次请求的各阶段保持不变。

### 12.3 集成验证

1. 启动 App，确认日志目录自动创建。
2. 执行一次本地录音和转录，确认 `app.log` 包含开始、结束或安全失败事件。
3. 执行一次图表生成，确认两个日志文件中出现相同 `correlationId`。
4. 让测试配置产生超过 5 MiB 的日志，确认运行过程中完成轮转。
5. 搜索日志文件，确认测试使用的密钥、正文和完整文件路径没有落盘。
6. 让日志目标不可写，确认核心业务仍能执行且 Swift 降级到 Unified Logging。

## 13. 验收标准

- `swift test` 全部通过。
- `ChartAgent` 的 Python 日志测试全部通过。
- `AIRecording/` 生产代码中不存在绕过统一日志入口的 `print(...)`。
- `ChartAgent/` 生产代码中不存在绕过 `log_event(...)` 的直接 `print(...)`。
- 实际运行后，`app.log` 与 `chart-agent.log` 均位于 `~/Library/Logs/AIRecording/`。
- 每个模块最多保留 3 份日志文件，正常情况下总占用约 15 MiB。
- 所有新日志均为一行一个 JSON 对象；普通 Python 输出也会被包装为该结构。
- 同一次图表请求可通过 `correlationId` 在两个文件中完整串联。
- 禁止记录的信息不会出现在测试生成的日志中。
- 日志系统发生故障时，录音、转录、导入和图表生成不会因日志错误而失败。

## 14. 实施约束

- 只修改实现本设计所必需的日志代码和调用点，不进行无关重构。
- 复用现有 `ChartServiceManager` 轮转测试所表达的 5 MiB、3 份文件语义。
- 新组件遵循项目现有 Foundation、Swift Concurrency 和 XCTest 技术栈，不引入第三方依赖。
- 实施前应另行编写详细实现计划；本文件不包含代码实施步骤。
