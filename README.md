# AIRecording · macOS 会议录音与知识问答

> 基于 Swift Package Manager 的 macOS 本地会议录音应用。
> 录音 → 语音转写（Apple Speech 本地 / Fun-ASR 云端）→ LLM 会议纪要 → 智能图表 → 知识库自动沉淀 → RAG 问答（带来源引用）。
> 转写稿与纪要在生成后**自动**进入本地知识索引（哈希幂等同步，无需手动入库）；知识库不依赖独立向量数据库，以 **SQLite + FTS5 + NumPy 余弦检索**实现语义与关键词混合召回，经 rerank 重排后由 LLM 流式作答并附来源时间轴。

<p>
  <img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-13%2B-000000?logo=macos&logoColor=white">
  <img alt="SwiftUI" src="https://img.shields.io/badge/SwiftUI-原生-025E8C?logo=swift&logoColor=white">
  <img alt="Python" src="https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white">
  <img alt="FastAPI" src="https://img.shields.io/badge/FastAPI-0.115-009688?logo=fastapi&logoColor=white">
  <img alt="SQLite" src="https://img.shields.io/badge/SQLite-FTS5-003B57?logo=sqlite&logoColor=white">
  <img alt="LangGraph" src="https://img.shields.io/badge/LangGraph-状态机-1C3C3C">
</p>

---

## 目录

- [项目简介](#项目简介)
- [核心架构：三链路流水线](#核心架构三链路流水线)
- [功能特性](#功能特性)
- [技术栈](#技术栈)
- [项目结构](#项目结构)
- [快速开始](#快速开始)
- [环境变量与密钥](#环境变量与密钥)
- [开发指南](#开发指南)
- [本地服务 API 概览](#本地服务-api-概览)
- [核心使用流程](#核心使用流程)
- [故障排查 / FAQ](#故障排查--faq)
- [许可证](#许可证)

---

## 项目简介

AIRecording 把「一场会议」的生命周期拆分为三条相互衔接的流水线，全部数据落在本机：

- **录音与转写**：AVAudioEngine 采集 PCM 写入 CAF 文件，导入音频亦受支持；转写引擎可在 Apple Speech（免费、本地优先）与 Fun-ASR（阿里云端，长音频更稳）之间切换
- **纪要与图表**：转写完成后由 LLM（OpenAI 兼容协议，默认 DeepSeek）生成 Markdown 会议纪要，可导出 .docx；智能图表按内容类型（会议/对话/访谈/课程/备忘/演讲/其他七类）路由到专属 skill，生成可编辑思维导图并导出 PNG
- **知识库 RAG**：转写稿与纪要经 Core Data 保存事件自动沉淀进本地知识索引；提问时混合检索（向量 + BM25）→ rerank 重排 → LLM 流式作答，答案附带来源录音与时间轴，点击可跳回原始音频位置

价值主张：**知识沉淀零按钮**——用户只管录音、看纪要，索引、去重、覆盖、删除同步全部由事件驱动在后台完成；**检索栈零外部依赖**——不装向量数据库服务，SQLite 单文件即索引，删掉可随时全量重建。

---

## 核心架构：三链路流水线

主程序为 Swift（SPM 可执行目标），按需拉起两个本地 Python 子服务：ChartAgent（`127.0.0.1:8765`）与 KnowledgeAgent（`127.0.0.1:8766`），生命周期由 Swift 侧管理（含残留进程清理）。

### 录音 → 转写 → 纪要主链路

```text
┌────────────────────────┐
│  开始录音               │ AVAudioEngine 输入节点 tap，PCM → CAF 文件
│  (菜单栏一键 / 主窗口)   │ 实时波形（audioLevel 发布）
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  停止 → 自动转写         │ Apple Speech（本地，requiresOnDevice）
│                        │ 或 Fun-ASR（DashScope 云端，OSS 临时中转即传即删）
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  Core Data 落库         │ Recording / Transcription / TranscriptionSegment
│  （保存事件触发知识同步） │ 带时间轴的逐字稿持久化
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  会议纪要（手动/再生成）  │ LLM 生成 Markdown；重生成只更新纪要，
│                        │ 可导出 .docx
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  知识库自动沉淀 → 问答    │ 见下方知识库链路
└────────────────────────┘
```

### 知识库 RAG 链路（自动同步 + 混合检索）

```text
Core Data 保存通知（转写完成 / 纪要生成 / 软删除）
        ▼
KnowledgeSyncCoordinator（Swift actor）
  0.5s 防抖 · (contentHash, summaryHash) 幂等去重 · 失败 5/30/120s 退避重试
        ▼  PUT /knowledge/recordings/{id}
KnowledgeAgent（FastAPI :8766，按录音粒度加锁）
  ├─ 哈希三元组一致 → unchanged，零写入
  ├─ 仅纪要变化   → 只重嵌入纪要路由块，替换 summary_route（逐字稿向量不动）
  └─ 逐字稿变化   → 整文档版本替换（新 document 插入，旧版本事务性删除）
        ▼
双层分块：检索层 250 字 / 重叠 25 · 生成父块 1500 字 / 150 · 纪要 summary_route
        ▼
嵌入（DashScope text-embedding-v4 默认 1024 维，或 OpenAI 兼容端点）
  L2 归一化 float32 → chunks.embedding BLOB；失败降级 FTS 并入队后台补向量
        ▼
SQLite：documents / chunks / chunk_fts(FTS5) / sync_jobs / 版本与墓碑表
        ▼  POST /knowledge/query
问答：问题嵌入 + BM25 双路召回 → 混合 → rerank（gte-rerank-v2）
  → 时间过滤 → 上下文组装 → LLM 流式输出 → 来源引用（录音 + 时间轴跳转）
```

### 智能图表链路（内容类型路由）

```text
纪要 / 转写稿
        ▼  POST /chart/generate（ChartAgent :8765）
内容分类器（LLM 判定 + 启发式兜底）
  meeting · dialogue · interview · lecture · memo · speech · other
        ▼
七种专属 skill → 结构化图数据（节点 / 层级 / 关系）
        ▼
LangGraph 状态机编排 → 思维导图渲染（SwiftUI WebView 承载）
        ▼
大纲编辑 · 图表缩放 · PNG 导出
```

---

## 功能特性

### 录音与转写

| 能力 | 说明 |
|------|------|
| **系统音频/麦克风采集** | AVAudioEngine 输入 tap，CAF(PCM) 存储，实时波形可视化 |
| **双转写引擎** | Apple Speech（本地优先、免费）与 Fun-ASR（DashScope 云端）可切换 |
| **音频导入** | 已有音频文件导入后同样走转写 → 纪要 → 知识库全链路 |
| **播放器** | 波形 + 进度条 + 倍速 + 快进快退，转写段落与音频时间对齐 |
| **菜单栏常驻** | 左键一键录音，右键最近录音 / 设置 / 退出 |

### 纪要与图表

| 能力 | 说明 |
|------|------|
| **LLM 会议纪要** | OpenAI 兼容协议（默认 DeepSeek），Markdown 输出，支持再生成 |
| **Word 导出** | 一键导出 .docx（原生 DocxExportService，无第三方依赖） |
| **智能图表 v6** | 按内容类型路由七种 skill，思维导图 + 大纲编辑 + 缩放 + PNG 导出 |
| **LangGraph 编排** | 图表生成链路由状态机编排，节点级容错 |

### 知识库 RAG

| 能力 | 说明 |
|------|------|
| **零按钮沉淀** | Core Data 保存事件驱动，转写/纪要完成后自动入库 |
| **幂等与增量** | (逐字稿哈希, 纪要哈希, 版本) 三元组判定；纪要再生成只换纪要块 |
| **混合检索** | 向量余弦 + FTS5 BM25 双召回，gte-rerank 重排，时间范围过滤 |
| **来源引用** | 回答附来源录音与时间轴，点击跳回对应音频位置 |
| **软删除同步** | 录音软删除 → 知识库立墓碑，迟到旧数据不会复活 |
| **可重建** | 「重建知识库」删库 → 全量重扫重嵌入；换 embedding 模型/维度后的统一手段 |

### 数据与隐私

- 全部结构化数据在本机 Core Data（SQLite），音频在本机文件系统，知识索引为本机单文件 SQLite
- 云端交互仅限显式配置的引擎：云端转写（音频临时上传 OSS，转完即删）、LLM/嵌入/重排 API
- API Key 存 macOS 钥匙串或 UserDefaults；日志统一脱敏（凭据/正文不入日志）

---

## 技术栈

> Swift 侧**零第三方依赖**（无任何 SPM 包），Python 侧依赖如下表。

| 分类 | 选型 |
|------|------|
| **App 框架** | Swift 5.9 · SwiftUI（macOS 13+）· AppKit 菜单栏桥接 · Swift Concurrency (actor) |
| **构建** | Swift Package Manager（无 .xcodeproj），`Scripts/build-app.sh` 打 .app 包 |
| **音频** | AVAudioEngine（采集）· AVAudioPlayer（播放）· CAF/PCM |
| **本地转写** | Speech 框架 SFSpeechRecognizer（on-device 优先） |
| **结构化存储** | Core Data（程序化模型：Recording / Transcription / Segment / Chart* / KnowledgeChat*） |
| **知识服务** | Python 3.10+ · FastAPI · uvicorn · SQLite（FTS5 全文索引 + 向量 BLOB）· NumPy 余弦 |
| **嵌入/重排** | DashScope `text-embedding-v4`（默认 1024 维）/ `gte-rerank-v2`，或 OpenAI 兼容端点 |
| **图表服务** | Python · FastAPI · LangGraph 状态机 · Jinja2 模板 |
| **LLM** | OpenAI 兼容协议（纪要 / 知识问答 / 图表理解，默认 DeepSeek） |
| **测试** | XCTest（25 个测试文件）· pytest（KnowledgeAgent 16 + ChartAgent 10） |
| **日志** | 统一结构化 JSON 日志（凭据脱敏、5MiB×3 轮转）`~/Library/Logs/AIRecording/` |

---

## 项目结构

```
AIRecording/
├── Package.swift                       # SPM 定义（可执行目标 + KnowledgeAgentResources 资源包）
├── .env.example                        # 环境变量模板（仅开发调试模式读取）
│
├── AIRecording/                        # ── Swift 主程序 ──
│   ├── App/                            # @main 入口 + MenuBarController（菜单栏桥接）
│   ├── Views/                          # SwiftUI 视图（列表/详情/录音/知识库/设置/图表…）
│   ├── ViewModels/                     # @MainActor ObservableObject
│   ├── Services/                       # 单例服务层
│   │   ├── AudioRecordingService.swift #   采集 + CAF 写入 + 状态发布
│   │   ├── TranscriptionService.swift  #   Apple Speech / Fun-ASR 双引擎
│   │   ├── LLMService.swift            #   纪要生成（OpenAI 兼容）
│   │   ├── KnowledgeServiceManager.swift#  KnowledgeAgent 子进程生命周期 + 配置注入
│   │   ├── KnowledgeSyncCoordinator.swift# 事件驱动知识同步（防抖/幂等/重试）
│   │   ├── KnowledgeClient.swift       #   知识服务 HTTP/SSE 客户端
│   │   ├── KnowledgeCredentialStore.swift#  钥匙串读写
│   │   ├── ChartServiceManager.swift   #   ChartAgent 子进程生命周期
│   │   ├── DocxExportService.swift     #   纪要导出 .docx
│   │   └── PersistenceController.swift #   Core Data 栈（程序化模型）
│   ├── Models/                         # Core Data @NSManaged 模型
│   └── Utilities/                      # AppLogger / 日志轮转 / 脱敏
│
├── ChartAgent/                         # ── 图表 Python 服务（:8765）──
│   ├── main.py                         # FastAPI 入口（/chart/generate, /chart/render）
│   └── agent/
│       ├── classifier.py               #   内容类型分类（七类）
│       ├── graph.py                    #   LangGraph 状态机
│       ├── skills/                     #   meeting/dialogue/interview/lecture/memo/speech/other
│       ├── mindmap.py · nodes.py       #   思维导图构建与图节点
│       └── templates.py · llm_client.py· observability.py
│
├── KnowledgeAgent/                     # ── 知识库 Python 服务（:8766）──
│   ├── main.py                         # FastAPI 入口（7 个端点）
│   └── agent/
│       ├── store.py                    #   SQLite 持久层（chunks/FTS5/向量/任务队列/墓碑）
│       ├── ingestion.py                #   幂等入库编排（纪要只换/整档替换）
│       ├── chunker.py                  #   双层分块 + 纪要路由块
│       ├── embedding.py                #   DashScope / OpenAI 兼容嵌入 + 重排
│       ├── retrieval.py · context.py   #   混合检索与上下文组装
│       ├── temporal.py                 #   时间过滤
│       ├── answering.py                #   LLM 流式作答（SSE）
│       └── schema.py · config.py · observability.py
│
├── Tests/AIRecordingTests/             # XCTest（25 文件）
├── Scripts/build-app.sh                # Release 构建 + .app 打包（Info.plist/签名）
└── docs/                               # PRD / 技术方案 / 数据库与 API 设计 / 各功能设计文档
```

---

## 快速开始

### 环境要求

- **macOS** 13+
- **Xcode Command Line Tools**（Swift 5.9+）
- **Python** 3.10+（两个子服务；开发模式下需自备依赖）
- 按需的 API Key（见[环境变量与密钥](#环境变量与密钥)）：
  - 可选：DashScope / OpenAI 兼容 LLM Key（纪要、知识问答、图表）
  - 可选：DashScope Key（Fun-ASR 云端转写、嵌入/重排）
  - 不配任何 Key 也可运行：本地 Apple Speech 转写开箱可用

### 安装与运行（开发模式）

```bash
# 1. Python 子服务依赖
cd KnowledgeAgent
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cd ../ChartAgent
pip3 install -r requirements.txt        # 或用 conda 环境安装

# 2. 运行 Swift 主程序（首次编译需数分钟）
cd ..
swift run

# 或用 Xcode 打开
open Package.swift
```

主程序启动后会**自动拉起**两个 Python 子服务（开发模式优先使用 `KnowledgeAgent/.venv`，图表服务自动探测可用 python），无需手动运行 uvicorn。

### 打包 .app

```bash
swift build -c release
./Scripts/build-app.sh                  # 产出 /Applications/AIRecording.app（含签名）
```

### 首次运行授权

系统会请求**麦克风**与**语音识别**权限（Info.plist 已声明用途说明），在系统设置中允许即可。

---

## 环境变量与密钥

密钥有三条配置途径，优先级从高到低：**进程环境变量 → `KnowledgeAgent/.env`（仅 DEBUG 构建，便于本地调试）→ App 内设置界面（UserDefaults / 钥匙串）**。正式使用建议直接在 App 设置里填写，不落任何文件。

模板见根目录 `.env.example`：

```bash
DASHSCOPE_API_KEY=                     # DashScope（Fun-ASR 转写 / 嵌入 / 重排）
EMBEDDING_PROVIDER=dashscope           # dashscope | openai
EMBEDDING_MODEL=text-embedding-v4      # 嵌入模型
EMBEDDING_DIMENSION=1024               # 维度（须与模型实际输出一致）
EMBEDDING_API_KEY=                     # 为空则回落 DASHSCOPE_API_KEY
EMBEDDING_BASE_URL=                    # OpenAI 兼容端点（provider=openai 时）
RERANK_PROVIDER=dashscope
RERANK_MODEL=gte-rerank-v2
RERANK_API_KEY=
RERANK_BASE_URL=
```

LLM（纪要 / 知识问答作答）在 App 设置中配置 Base URL / API Key / 模型名（OpenAI 兼容协议，默认预设 DeepSeek）。

> **安全提示**：`EMBEDDING_API_KEY` 等密钥在 App 内保存于 macOS 钥匙串；`.env` 仅在 DEBUG 构建读取，**不要**把填好密钥的 `.env` 提交进仓库（已被 .gitignore 拦截）。

---

## 开发指南

### 测试

```bash
swift test                              # XCTest 全量（录音/转写/知识同步/图表/导出/日志）

cd KnowledgeAgent && .venv/bin/python -m pytest    # 知识服务 pytest（16 文件）
cd ../ChartAgent && python3 -m pytest              # 图表服务 pytest（10 文件）
```

### 日志排查

```bash
~/Library/Logs/AIRecording/app.log           # Swift 主程序（JSON 行式，含 correlationId）
~/Library/Logs/AIRecording/chart-agent.log   # ChartAgent 子进程
```

同一请求的 `correlationId` 贯穿 Swift 与 Python 两侧，可跨文件追踪。凭据与正文内容已脱敏，可放心查看。

### 数据位置

| 数据 | 路径 |
|------|------|
| Core Data 库 | `~/Library/Application Support/AIRecording/AIRecording.sqlite` |
| 音频文件 | `~/Library/Application Support/AIRecording/Recordings/`（可在设置中更改） |
| 知识索引 | `~/Library/Application Support/AIRecording/Knowledge/knowledge.sqlite`（可重建的派生数据） |
| 日志 | `~/Library/Logs/AIRecording/` |

### 手动验收

知识库功能的验收清单见 `docs/knowledge-rag/manual-acceptance.md`。

---

## 本地服务 API 概览

两个服务仅监听 `127.0.0.1`，由主程序管理生命周期，一般无需直接调用（调试除外）。

### KnowledgeAgent（:8766）

| 路由 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查（含降级状态） |
| `/knowledge/status` | GET | 索引统计（录音数 / 分块数 / 待补向量 / 失败任务） |
| `/knowledge/recordings/{id}` | PUT | 幂等入库/更新一条录音（逐字稿 + 纪要） |
| `/knowledge/recordings/{id}` | DELETE | 删除并立墓碑（防迟到数据复活） |
| `/knowledge/retry-failed` | POST | 重置失败任务为待重试 |
| `/knowledge/reset-index` | POST | 清空索引（备份后删库重建，独占维护门） |
| `/knowledge/query` | POST | 知识问答（SSE 流式，含来源引用） |

### ChartAgent（:8765）

| 路由 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/chart/generate` | POST | 从文本生成结构化图表（分类 → skill → 图数据） |
| `/chart/render` | POST | 渲染已有图数据 |

---

## 核心使用流程

1. **录音**：菜单栏左键或主窗口「新录音」，实时波形显示，支持系统音频/麦克风源选择
2. **停止即转写**：停止后自动触发所选引擎；逐字稿带时间轴与说话人段落
3. **生成纪要**：详情页一键生成 LLM 纪要；不满意可再生成（知识库同步只更新纪要部分，不重复计费嵌入）
4. **沉淀自动发生**：转写完成、纪要生成/再生成的同时，后台已把内容同步进知识索引
5. **知识问答**：知识库页提问，流式回答下方附来源录音与时间点，点击跳回原始音频对应位置
6. **生成图表**：基于纪要/转写生成思维导图，可编辑大纲、缩放、导出 PNG
7. **导出与回听**：纪要导出 .docx；历史录音随时回听（倍速/快进）

---

## 故障排查 / FAQ

<details>
<summary><b>Q1：swift build 在移动硬盘 / exFAT 卷上失败，报 CodeSign 错误？</b></summary>

exFAT 文件系统会为扩展属性生成 `._*` AppleDouble 文件，混入资源包后 codesign 拒签。把仓库移到 APFS 卷（如内置盘）再构建即可；`find .build -name "._*" -delete` 只能临时缓解（文件会再生）。

</details>

<details>
<summary><b>Q2：转写选 Apple Speech 还是 Fun-ASR？</b></summary>

Apple Speech 本地免费、隐私最好，适合短录音；Fun-ASR（需 DashScope Key）走云端，长音频与中文口音更稳。设置中随时切换，已有录音可在详情页手动重转。

</details>

<details>
<summary><b>Q3：更换嵌入模型或维度后，知识库检索变差 / 查不到旧内容？</b></summary>

新旧维度可安全共存（每个分块自带维度，查询只比对同维向量），但旧向量不会被新模型检索到。到「设置 → 知识库」点击**重建知识库**：清空索引 → 全量重扫 → 用新模型重新嵌入，之后自然统一。

</details>

<details>
<summary><b>Q4：Python 子服务没有起来 / 知识库状态异常？</b></summary>

主程序按需自动拉起子服务并做残留进程清理，一般无需干预。排查步骤：看 `~/Library/Logs/AIRecording/` 两侧日志（用 correlationId 串联）；确认开发模式依赖已安装（`KnowledgeAgent/.venv` 存在且依赖齐全）；设置页可查看服务健康状态并手动重启。重启 App 即加载最新 Python 代码。

</details>

<details>
<summary><b>Q5：知识问答没有向量召回，只有关键词结果？</b></summary>

嵌入 API 失败时服务自动降级为纯 FTS 检索，并在后台每 5 秒重试补齐向量。检查 EMBEDDING_API_KEY / DASHSCOPE_API_KEY 是否有效；「知识库状态」中 pending/failed 数量可观测补齐进度。

</details>

<details>
<summary><b>Q6：我的 API Key 会存在哪里、会不会进日志？</b></summary>

App 内填写的知识库密钥存 macOS 钥匙串，其余存 UserDefaults；日志层对凭据做强制脱敏（密钥、正文、完整路径不入日志）。仓库 `.gitignore` 已拦截 `.env*`（保留 `.env.example`），请勿绕过。

</details>

---

## 许可证

私有仓库，保留所有权利。如需开源，请先补充 LICENSE 文件并复查历史中不含敏感信息。
