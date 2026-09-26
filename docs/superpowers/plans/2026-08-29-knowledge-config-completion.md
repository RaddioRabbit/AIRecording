# 知识库配置补全 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在设置界面"知识库"区补全 Embedding 模型/向量维度/Rerank 模型三项配置,保存后自动重启知识库服务,Python 端调 DashScope 时显式携带 dimension。

**Architecture:** 配置存 UserDefaults(非机密)→ `KnowledgeServiceManager.serviceEnvironment` 以环境变量(`EMBEDDING_MODEL` / `EMBEDDING_DIMENSION` / `RERANK_MODEL`)注入 Python 子进程 → `KnowledgeConfig.from_environment` 解析 → `DashScopeAdapter` 调 DashScope TextEmbedding 时传 `dimension`。维度只能从模型预设表下拉选择,自定义模型不传维度。

**Tech Stack:** Swift(SPM,macOS 13,SwiftUI + XCTest)/ Python(FastAPI,pytest)/ DashScope SDK。

**设计文档:** `docs/superpowers/specs/2026-08-29-knowledge-config-completion-design.md`

---

## 开始前必读(执行环境)

- 所有路径基于 worktree:`/Users/radiorabbit/Desktop/WorkPlace/AIRecording/.worktrees/recording-knowledge-rag`(下称 `<ROOT>`)。除特别说明,命令都在 `<ROOT>` 下执行。
- **git 可用性:** worktree 的 git 元数据在外接硬盘 `/Volumes/HP P900` 上。开始第一个任务前先跑 `cd <ROOT> && git status --short`;若报 `not a git repository`,**停下告知用户需要挂载该硬盘**,挂载后再继续(每个任务都要 commit,没有 git 走不下去)。
- Python 测试用 venv:`cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest tests/<file> -q`(若 venv 不存在,先 `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`)。
- Swift 测试:`cd <ROOT> && swift test --filter <TestClass>`。
- 提交信息沿用分支惯例(`feat(rag):` / `test(rag):` 前缀)。
- 本计划不改动:存储层 schema、检索算法、同步链路、聊天 UI、Keychain 密钥机制。

---

### Task 1: 核对 DashScope 官方文档中的模型名与维度取值

不写代码,只核实常量,避免预设表写错值。

**Files:** 无(产出是一份核对结论,影响 Task 4 的常量)

- [ ] **Step 1: 查官方文档**

用 WebSearch 搜索 `DashScope text-embedding-v4 dimension 参数 取值`,或 WebFetch 阿里云百炼文档(如 `https://help.aliyun.com/zh/model-studio/text-embedding-api-reference`),确认:

1. `text-embedding-v4` 的 `dimension` 参数合法取值集合与默认值;
2. `text-embedding-v3` 的 `dimension` 参数合法取值集合与默认值;
3. 两个模型是否仍在售;
4. rerank 模型 `gte-rerank-v2`、`gte-rerank` 是否仍在售。

- [ ] **Step 2: 对照下方"基准表",得出结论**

本计划的基准表(**已于 2026-08-29 按官方文档核对修正**):

| 模型 | 维度选项(第一个为默认) |
|---|---|
| `text-embedding-v4` | 1024 / 1536 / 2048 / 768 / 512 / 256 / 128 / 64 |
| `text-embedding-v3` | 1024 / 768 / 512 / 256 / 128 / 64 |
| rerank | `gte-rerank-v2`(默认)、`qwen3-rerank` |

核对结论(来源:阿里云百炼官方文档《通用文本向量同步 API》《向量与重排序模型总览》):v4 取值与默认 1024 与原表一致;**v3 不支持 1536**(1536/2048 仅限 v4),已从表中移除;`gte-rerank`(无版本号)已不在售,第二 rerank 预设改为在售且官方推荐的 `qwen3-rerank`,默认仍为 `gte-rerank-v2` 以保持与现有索引/参考项目(shudao-RAG)一致。任务 2-7 直接按修正后的值执行,无需再次核对。

---

### Task 2: Python 端配置类支持 `EMBEDDING_DIMENSION`

**Files:**
- Modify: `<ROOT>/KnowledgeAgent/agent/config.py`
- Test: `<ROOT>/KnowledgeAgent/tests/test_config.py`

- [ ] **Step 1: 写失败的测试**

在 `tests/test_config.py` 末尾追加三个测试,并修改现有两个测试(改动点见注释):

```python
def test_from_environment_parses_embedding_dimension(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("EMBEDDING_DIMENSION", "1536")

    config = KnowledgeConfig.from_environment()

    assert config.embedding_dimension == 1536


def test_from_environment_ignores_invalid_embedding_dimension(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")

    monkeypatch.setenv("EMBEDDING_DIMENSION", "abc")
    assert KnowledgeConfig.from_environment().embedding_dimension is None

    monkeypatch.setenv("EMBEDDING_DIMENSION", "0")
    assert KnowledgeConfig.from_environment().embedding_dimension is None

    monkeypatch.setenv("EMBEDDING_DIMENSION", "  ")
    assert KnowledgeConfig.from_environment().embedding_dimension is None

    monkeypatch.delenv("EMBEDDING_DIMENSION", raising=False)
    assert KnowledgeConfig.from_environment().embedding_dimension is None


def test_from_environment_prefers_environment_dimension_over_default(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("EMBEDDING_MODEL", "text-embedding-v3")
    monkeypatch.setenv("EMBEDDING_DIMENSION", "768")

    config = KnowledgeConfig.from_environment()

    assert config.embedding_model == "text-embedding-v3"
    assert config.embedding_dimension == 768
```

对现有测试的修改:
- `test_from_environment_uses_defaults`:在 `monkeypatch.delenv("RERANK_MODEL", ...)` 之后加一行 `monkeypatch.delenv("EMBEDDING_DIMENSION", raising=False)`,并在断言区加 `assert config.embedding_dimension is None`。
- `test_from_environment_applies_supported_overrides`:加 `monkeypatch.setenv("EMBEDDING_DIMENSION", "768")` 与断言 `assert config.embedding_dimension == 768`。

- [ ] **Step 2: 运行确认失败**

```bash
cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest tests/test_config.py -q
```

预期:FAIL(`AttributeError: 'KnowledgeConfig' object has no attribute 'embedding_dimension'` 或构造报未知字段)。

- [ ] **Step 3: 实现 config.py**

将 `<ROOT>/KnowledgeAgent/agent/config.py` 整体替换为:

```python
"""Configuration for the local knowledge service."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from agent.observability import log_event


def _embedding_dimension_from_environment() -> int | None:
    raw = os.environ.get("EMBEDDING_DIMENSION", "").strip()
    if not raw:
        return None
    try:
        parsed = int(raw)
    except ValueError:
        parsed = 0
    if parsed <= 0:
        log_event("embedding_dimension_invalid", level="warning", error_code="EMBEDDING_DIMENSION_INVALID")
        return None
    return parsed


@dataclass(frozen=True)
class KnowledgeConfig:
    db_path: Path
    host: str = "127.0.0.1"
    port: int = 8766
    embedding_model: str = "text-embedding-v4"
    embedding_dimension: int | None = None
    rerank_model: str = "gte-rerank-v2"
    retrieval_chunk_size: int = 250
    retrieval_chunk_overlap: int = 25
    generation_chunk_size: int = 1500
    generation_chunk_overlap: int = 150
    rrf_k: int = 60
    index_version: int = 1

    @classmethod
    def from_environment(cls) -> "KnowledgeConfig":
        return cls(
            db_path=Path(os.environ["KNOWLEDGE_DB_PATH"]),
            port=int(os.environ.get("PORT", "8766")),
            embedding_model=os.environ.get("EMBEDDING_MODEL", "text-embedding-v4"),
            embedding_dimension=_embedding_dimension_from_environment(),
            rerank_model=os.environ.get("RERANK_MODEL", "gte-rerank-v2"),
        )
```

- [ ] **Step 4: 运行确认通过**

```bash
cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest tests/test_config.py -q
```

预期:全部 PASS(现有 2 个 + 新增 3 个)。

- [ ] **Step 5: 提交**

```bash
cd <ROOT> && git add KnowledgeAgent/agent/config.py KnowledgeAgent/tests/test_config.py && git commit -m "feat(rag): parse EMBEDDING_DIMENSION in knowledge agent config"
```

---

### Task 3: Python 端 embedding 调用携带 dimension + main.py 装配

**Files:**
- Modify: `<ROOT>/KnowledgeAgent/agent/embedding.py`
- Modify: `<ROOT>/KnowledgeAgent/agent/main.py:118-120`(DashScopeAdapter 构造处)
- Test: `<ROOT>/KnowledgeAgent/tests/test_embedding.py`
- Test: `<ROOT>/KnowledgeAgent/tests/test_api.py`

- [ ] **Step 1: 写失败的测试**

在 `tests/test_embedding.py` 末尾(`_chunk` 辅助函数之前)追加:

```python
def test_embed_passes_dimension_when_configured():
    calls = []

    class FakeEmbedding:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"embeddings": [{"embedding": [3.0, 4.0]} for _ in kwargs["input"]]}}

    adapter = DashScopeAdapter(api_key="test-key", embedding_dimension=1536, text_embedding=FakeEmbedding)
    vectors = asyncio.run(adapter.embed_documents(["张伟负责上线"]))

    assert calls[0]["dimension"] == 1536
    assert all(np.allclose(vector, [0.6, 0.8]) for vector in vectors)


def test_embed_omits_dimension_when_not_configured():
    calls = []

    class FakeEmbedding:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"embeddings": [{"embedding": [3.0, 4.0]} for _ in kwargs["input"]]}}

    adapter = DashScopeAdapter(api_key="test-key", text_embedding=FakeEmbedding)

    asyncio.run(adapter.embed_query("launch"))

    assert "dimension" not in calls[0]
```

在 `tests/test_api.py` 中:文件头部 import 区把 `from main import API_VERSION, SERVICE_VERSION, app` 改为(注意:monkeypatch 目标必须是真正持有 lifespan 的 `agent.main`,仓库根的 `main.py` 只是开发包装器,无 DashScopeAdapter 属性——此为执行期间发现的计划修正):

```python
import agent.main as main_module
from main import API_VERSION, SERVICE_VERSION, app

from agent.embedding import DashScopeAdapter
```

并在文件末尾追加:

```python
def test_lifespan_wires_embedding_dimension_into_adapter(monkeypatch, tmp_path):
    created = []

    class RecordingAdapter(DashScopeAdapter):
        def __init__(self, **kwargs):
            created.append(kwargs)
            super().__init__(**kwargs)

    monkeypatch.setattr(main_module, "DashScopeAdapter", RecordingAdapter)
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", str(tmp_path / "knowledge.sqlite"))
    monkeypatch.setenv("EMBEDDING_DIMENSION", "1536")

    with TestClient(app):
        pass

    assert created and created[0]["embedding_dimension"] == 1536
```

- [ ] **Step 2: 运行确认失败**

```bash
cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest tests/test_embedding.py tests/test_api.py -q
```

预期:新增用例 FAIL(`TypeError: ... unexpected keyword argument 'embedding_dimension'` 等)。

- [ ] **Step 3: 实现 embedding.py**

在 `<ROOT>/KnowledgeAgent/agent/embedding.py` 中做两处修改。

第一处:`DashScopeAdapter.__init__`(当前 27-35 行)替换为:

```python
    def __init__(self, *, api_key: str | None = None, embedding_model: str | None = None,
                 embedding_dimension: int | None = None, rerank_model: str | None = None,
                 text_embedding: Any | None = None,
                 text_rerank: Any | None = None, timeout_seconds: float = 10.0) -> None:
        self._api_key = api_key
        self.embedding_model = embedding_model or os.getenv("EMBEDDING_MODEL", "text-embedding-v4")
        self.embedding_dimension = embedding_dimension if (embedding_dimension or 0) > 0 else None
        self.rerank_model = rerank_model or os.getenv("RERANK_MODEL", "gte-rerank-v2")
        self._text_embedding = text_embedding
        self._text_rerank = text_rerank
        self.timeout_seconds = max(0.001, timeout_seconds)
```

第二处:`_embed`(当前 58-77 行)整体替换为:

```python
    async def _embed(self, texts: list[str], text_type: str, key: str) -> list[np.ndarray | None]:
        kwargs: dict[str, Any] = {
            "model": self.embedding_model,
            "input": texts,
            "api_key": key,
            "text_type": text_type,
            "request_timeout": self.timeout_seconds,
        }
        if self.embedding_dimension is not None:
            kwargs["dimension"] = self.embedding_dimension
        try:
            response = await asyncio.wait_for(
                asyncio.to_thread(self._embedding_client().call, **kwargs),
                timeout=self.timeout_seconds,
            )
            raw = _field(_field(response, "output"), "embeddings")
            if not isinstance(raw, list) or len(raw) != len(texts):
                return [None] * len(texts)
            return [_normalised_vector(_field(item, "embedding")) for item in raw]
        except Exception:
            # Provider failures must have a deterministic, private fallback.
            return [None] * len(texts)
```

- [ ] **Step 4: 实现 main.py 装配**

`<ROOT>/KnowledgeAgent/agent/main.py` 118-120 行,把

```python
        adapter = DashScopeAdapter(
            embedding_model=config.embedding_model, rerank_model=config.rerank_model
        )
```

替换为:

```python
        adapter = DashScopeAdapter(
            embedding_model=config.embedding_model,
            embedding_dimension=config.embedding_dimension,
            rerank_model=config.rerank_model,
        )
```

- [ ] **Step 5: 运行确认通过**

```bash
cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest tests/test_embedding.py tests/test_api.py -q
```

预期:全部 PASS。再跑一次全量回归:

```bash
cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest -q
```

预期:全部 PASS。

- [ ] **Step 6: 提交**

```bash
cd <ROOT> && git add KnowledgeAgent/agent/embedding.py KnowledgeAgent/agent/main.py KnowledgeAgent/tests/test_embedding.py KnowledgeAgent/tests/test_api.py && git commit -m "feat(rag): pass embedding dimension through adapter wiring"
```

---

### Task 4: Swift 侧模型预设目录 KnowledgeModelCatalog

**Files:**
- Create: `<ROOT>/AIRecording/Services/KnowledgeModelCatalog.swift`
- Test: Create `<ROOT>/Tests/AIRecordingTests/KnowledgeModelCatalogTests.swift`

- [ ] **Step 1: 写失败的测试**

创建 `<ROOT>/Tests/AIRecordingTests/KnowledgeModelCatalogTests.swift`:

```swift
import XCTest
@testable import AIRecording

final class KnowledgeModelCatalogTests: XCTestCase {
    func testEmbeddingPresetsExposeDimensionOptionsWithDefaultFirst() {
        XCTAssertEqual(
            KnowledgeModelCatalog.embeddingModelNames.first,
            KnowledgeModelCatalog.defaultEmbeddingModel
        )
        XCTAssertEqual(
            KnowledgeModelCatalog.dimensions(for: "text-embedding-v4")?.first,
            1024
        )
        XCTAssertEqual(
            KnowledgeModelCatalog.dimensions(for: "text-embedding-v3")?.first,
            1024
        )
    }

    func testUnknownModelHasNoPresetDimensions() {
        XCTAssertNil(KnowledgeModelCatalog.dimensions(for: "my-own-model"))
        XCTAssertNil(KnowledgeModelCatalog.dimensions(for: KnowledgeModelCatalog.customSentinel))
    }

    func testRerankPresetsContainDefaultFirst() {
        XCTAssertEqual(
            KnowledgeModelCatalog.rerankModelNames.first,
            KnowledgeModelCatalog.defaultRerankModel
        )
    }
}
```

(若 Task 1 修正了基准表,同步修正本测试中的模型名/维度断言。)

- [ ] **Step 2: 运行确认失败**

```bash
cd <ROOT> && swift test --filter KnowledgeModelCatalogTests
```

预期:编译失败(`cannot find 'KnowledgeModelCatalog' in scope`)。

- [ ] **Step 3: 实现 catalog**

创建 `<ROOT>/AIRecording/Services/KnowledgeModelCatalog.swift`:

```swift
import Foundation

/// 预设的 DashScope 检索模型目录:维度选项只能从这里选,自定义模型不传维度。
enum KnowledgeModelCatalog {
    static let customSentinel = "__custom__"

    static let defaultEmbeddingModel = "text-embedding-v4"
    static let defaultRerankModel = "gte-rerank-v2"

    static let embeddingModelNames = ["text-embedding-v4", "text-embedding-v3"]

    /// 每个预设模型的合法维度,第一个元素是该模型的默认维度。
    /// 取值已于 2026-08-29 按阿里云百炼官方文档核对(1536/2048 仅 v4 支持)。
    static let embeddingDimensionsByModel: [String: [Int]] = [
        "text-embedding-v4": [1024, 1536, 2048, 768, 512, 256, 128, 64],
        "text-embedding-v3": [1024, 768, 512, 256, 128, 64],
    ]

    static let rerankModelNames = ["gte-rerank-v2", "qwen3-rerank"]

    static func dimensions(for model: String) -> [Int]? {
        embeddingDimensionsByModel[model]
    }
}
```

(若 Task 1 修正了基准表,以修正后的值替换上表。)

- [ ] **Step 4: 运行确认通过**

```bash
cd <ROOT> && swift test --filter KnowledgeModelCatalogTests
```

预期:3 个用例 PASS。

- [ ] **Step 5: 提交**

```bash
cd <ROOT> && git add AIRecording/Services/KnowledgeModelCatalog.swift Tests/AIRecordingTests/KnowledgeModelCatalogTests.swift && git commit -m "feat(rag): add knowledge model catalog presets"
```

---

### Task 5: Swift 侧 KnowledgeServiceManager 传参与重启

**Files:**
- Modify: `<ROOT>/AIRecording/Services/KnowledgeServiceManager.swift`(serviceEnvironment、developmentDotenvValues、resolvedConfiguration、startService、新增 restartService、KnowledgeAgentConfiguration)
- Test: `<ROOT>/Tests/AIRecordingTests/KnowledgeServiceManagerTests.swift`

- [ ] **Step 1: 写失败的测试**

在 `<ROOT>/Tests/AIRecordingTests/KnowledgeServiceManagerTests.swift` 中:

1. 追加两个 `serviceEnvironment` 用例(放在 `testServiceEnvironmentUsesOnlyWhitelistedSecrets` 之后):

```swift
    func testServiceEnvironmentInjectsModelOverridesIncludingDimension() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: [:],
            dashScopeKey: "dash",
            llm: .init(baseURL: "https://api.deepseek.com/v1", apiKey: "llm", model: "deepseek-chat"),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766,
            embeddingModel: "text-embedding-v4",
            embeddingDimension: 1536,
            rerankModel: "gte-rerank-v2"
        )

        XCTAssertEqual(environment["EMBEDDING_MODEL"], "text-embedding-v4")
        XCTAssertEqual(environment["EMBEDDING_DIMENSION"], "1536")
        XCTAssertEqual(environment["RERANK_MODEL"], "gte-rerank-v2")
    }

    func testServiceEnvironmentOmitsEmptyModelOverridesAndDimension() {
        let environment = KnowledgeServiceManager.serviceEnvironment(
            parent: [:],
            dashScopeKey: "",
            llm: .init(baseURL: "", apiKey: "", model: ""),
            databasePath: "/tmp/knowledge.sqlite",
            port: 8766
        )

        XCTAssertNil(environment["EMBEDDING_MODEL"])
        XCTAssertNil(environment["EMBEDDING_DIMENSION"])
        XCTAssertNil(environment["RERANK_MODEL"])
    }
```

2. 修改 `testDotenvParserOnlyAcceptsKnowledgeKeys`:写入内容改为

```swift
        try "DASHSCOPE_API_KEY=dash\nUNRELATED=no\nEMBEDDING_MODEL=embed\nEMBEDDING_DIMENSION=1536\n".write(to: url, atomically: true, encoding: .utf8)
```

并在断言区加:

```swift
        XCTAssertEqual(values["EMBEDDING_DIMENSION"], "1536")
```

3. 追加重启守卫用例(放在文件末尾的测试类大括号内):

```swift
    @MainActor
    func testRestartServiceWithoutRunningProcessMakesNoStartAttempt() async {
        var launchAttempts = 0
        let manager = KnowledgeServiceManager(onProcessLaunchAttempt: { launchAttempts += 1 })

        await manager.restartService()

        XCTAssertEqual(launchAttempts, 0)
        XCTAssertFalse(manager.isRunning)
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
cd <ROOT> && swift test --filter KnowledgeServiceManagerTests
```

预期:编译失败(无 `embeddingDimension:` 参数、无 `restartService()`)。

- [ ] **Step 3: 实现 KnowledgeServiceManager.swift**

五处修改:

(a) `serviceEnvironment`(83-106 行)替换为:

```swift
    nonisolated static func serviceEnvironment(
        parent: [String: String],
        dashScopeKey: String,
        llm: KnowledgeLLMConfiguration,
        databasePath: String,
        port: Int,
        embeddingModel: String? = nil,
        embeddingDimension: Int? = nil,
        rerankModel: String? = nil
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for key in ["PATH", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let value = parent[key], !value.isEmpty { environment[key] = value }
        }
        if !dashScopeKey.isEmpty { environment["DASHSCOPE_API_KEY"] = dashScopeKey }
        if !llm.apiKey.isEmpty { environment["OPENAI_API_KEY"] = llm.apiKey }
        if !llm.baseURL.isEmpty { environment["OPENAI_BASE_URL"] = llm.baseURL }
        if !llm.model.isEmpty { environment["LLM_MODEL"] = llm.model }
        if let embeddingModel, !embeddingModel.isEmpty { environment["EMBEDDING_MODEL"] = embeddingModel }
        if let embeddingDimension, embeddingDimension > 0 { environment["EMBEDDING_DIMENSION"] = String(embeddingDimension) }
        if let rerankModel, !rerankModel.isEmpty { environment["RERANK_MODEL"] = rerankModel }
        environment["KNOWLEDGE_DB_PATH"] = databasePath
        environment["PORT"] = String(port)
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }
```

(b) `developmentDotenvValues` 中允许键集合(110 行)改为:

```swift
        let allowed = Set(["DASHSCOPE_API_KEY", "EMBEDDING_MODEL", "EMBEDDING_DIMENSION", "RERANK_MODEL"])
```

(c) 在 `stopService()`(185-192 行)之后新增方法:

```swift
    func restartService() async {
        guard process != nil || isRunning else { return }
        lifecycleGeneration &+= 1
        startupGate.invalidate()
        process?.terminate()
        process = nil
        isRunning = false
        _ = await ensureServiceRunning()
    }
```

(d) `startService()` 中 `process.environment = Self.serviceEnvironment(...)` 调用(210-218 行)补一行参数,变为:

```swift
        process.environment = Self.serviceEnvironment(
            parent: ProcessInfo.processInfo.environment,
            dashScopeKey: configuration.dashScopeKey,
            llm: configuration.llm,
            databasePath: dbURL.path,
            port: servicePort,
            embeddingModel: configuration.embeddingModel,
            embeddingDimension: configuration.embeddingDimension,
            rerankModel: configuration.rerankModel
        )
```

(e) `resolvedConfiguration()`(263-287 行)与文件底部的 `KnowledgeAgentConfiguration`(314-319 行)分别替换为:

```swift
    private func resolvedConfiguration() -> KnowledgeAgentConfiguration {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let dotenv = Self.developmentDotenvValues(
            at: Self.developmentProjectRootURL.appendingPathComponent("KnowledgeAgent/.env")
        )
        #else
        let dotenv: [String: String] = [:]
        #endif
        let key = Self.resolveDashScopeAPIKey(
            environment: environment,
            dotenv: dotenv,
            keychainValue: credentialStore.dashScopeAPIKey()
        )
        let embeddingModel = environment["EMBEDDING_MODEL"].nilIfEmpty
            ?? dotenv["EMBEDDING_MODEL"].nilIfEmpty
            ?? UserDefaults.standard.string(forKey: "knowledge.embeddingModel").nilIfEmpty
        let rerankModel = environment["RERANK_MODEL"].nilIfEmpty
            ?? dotenv["RERANK_MODEL"].nilIfEmpty
            ?? UserDefaults.standard.string(forKey: "knowledge.rerankModel").nilIfEmpty
        let embeddingDimension: Int?
        if let raw = environment["EMBEDDING_DIMENSION"].nilIfEmpty ?? dotenv["EMBEDDING_DIMENSION"].nilIfEmpty {
            embeddingDimension = Int(raw)
        } else if let model = embeddingModel,
                  let options = KnowledgeModelCatalog.dimensions(for: model),
                  let saved = UserDefaults.standard.object(forKey: "knowledge.embeddingDimension") as? Int,
                  options.contains(saved) {
            embeddingDimension = saved
        } else {
            embeddingDimension = nil
        }
        return KnowledgeAgentConfiguration(
            dashScopeKey: key,
            embeddingModel: embeddingModel,
            embeddingDimension: embeddingDimension,
            rerankModel: rerankModel,
            llm: KnowledgeLLMConfiguration(
                baseURL: UserDefaults.standard.string(forKey: "llm.baseURL") ?? "https://api.deepseek.com/v1",
                apiKey: UserDefaults.standard.string(forKey: "llm.apiKey") ?? "",
                model: UserDefaults.standard.string(forKey: "llm.model") ?? "deepseek-v4-flash"
            )
        )
    }
```

```swift
private struct KnowledgeAgentConfiguration {
    let dashScopeKey: String
    let embeddingModel: String?
    let embeddingDimension: Int?
    let rerankModel: String?
    let llm: KnowledgeLLMConfiguration
}
```

注意:UserDefaults 维度档只在"生效模型是预设模型且维度在该模型合法列表内"时采用——这是"自定义模型不传维度"防呆的最终防线。

- [ ] **Step 4: 运行确认通过**

```bash
cd <ROOT> && swift test --filter KnowledgeServiceManagerTests
```

预期:全部 PASS(含原有用例,`testStopPermanentlyRejectsFutureStartRequests` 等不受影响)。

- [ ] **Step 5: 提交**

```bash
cd <ROOT> && git add AIRecording/Services/KnowledgeServiceManager.swift Tests/AIRecordingTests/KnowledgeServiceManagerTests.swift && git commit -m "feat(rag): inject model overrides and add service restart"
```

---

### Task 6: Swift 侧设置界面与 ViewModel

**Files:**
- Modify: `<ROOT>/AIRecording/ViewModels/SettingsViewModel.swift`
- Modify: `<ROOT>/AIRecording/Views/SettingsView.swift`
- Test: `<ROOT>/Tests/AIRecordingTests/KnowledgeSettingsTests.swift`

- [ ] **Step 1: 写失败的测试**

在 `<ROOT>/Tests/AIRecordingTests/KnowledgeSettingsTests.swift` 中:

1. 测试类属性区(第 10 行 `retryCounter` 之后)加:

```swift
    private var restartCounter: SettingsRestartCounter!
```

`setUp()` 中 `retryCounter = SettingsRetryCounter()` 之后加 `restartCounter = SettingsRestartCounter()`;`tearDown()` 中同步置 nil。

2. `makeViewModel()`(114-121 行)替换为:

```swift
    private func makeViewModel() -> SettingsViewModel {
        SettingsViewModel(
            defaults: defaults,
            credentialStore: credentialStore,
            knowledgeClient: client,
            retryKnowledgeSync: { [retryCounter] in await retryCounter?.increment() },
            restartKnowledgeService: { [restartCounter] in await restartCounter?.increment() }
        )
    }
```

3. 追加三个测试:

```swift
    func testSaveKnowledgeModelSettingsPersistsValuesAndRestartsService() async {
        let viewModel = makeViewModel()

        await viewModel.saveKnowledgeModelSettings(
            embeddingModel: "text-embedding-v4",
            embeddingDimension: 1536,
            rerankModel: "gte-rerank-v2"
        )

        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingModel"), "text-embedding-v4")
        XCTAssertEqual(defaults.integer(forKey: "knowledge.embeddingDimension"), 1536)
        XCTAssertEqual(defaults.string(forKey: "knowledge.rerankModel"), "gte-rerank-v2")
        XCTAssertEqual(viewModel.knowledgeEmbeddingModel, "text-embedding-v4")
        XCTAssertEqual(viewModel.knowledgeEmbeddingDimension, 1536)
        XCTAssertEqual(viewModel.knowledgeRerankModel, "gte-rerank-v2")
        XCTAssertEqual(await restartCounter.value, 1)
    }

    func testSaveCustomModelClearsStoredDimension() async {
        let viewModel = makeViewModel()

        await viewModel.saveKnowledgeModelSettings(
            embeddingModel: "custom-embedding",
            embeddingDimension: nil,
            rerankModel: "custom-reranker"
        )

        XCTAssertEqual(defaults.string(forKey: "knowledge.embeddingModel"), "custom-embedding")
        XCTAssertNil(defaults.object(forKey: "knowledge.embeddingDimension"))
        XCTAssertEqual(viewModel.knowledgeEmbeddingDimension, 0)
        XCTAssertEqual(await restartCounter.value, 1)
    }

    func testLoadSettingsSeedsKnowledgeModelDefaultsWhenUnset() {
        let viewModel = makeViewModel()

        viewModel.loadSettings()

        XCTAssertEqual(viewModel.knowledgeEmbeddingModel, KnowledgeModelCatalog.defaultEmbeddingModel)
        XCTAssertEqual(viewModel.knowledgeEmbeddingDimension, 0)
        XCTAssertEqual(viewModel.knowledgeRerankModel, KnowledgeModelCatalog.defaultRerankModel)
    }
```

- [ ] **Step 2: 运行确认失败**

```bash
cd <ROOT> && swift test --filter KnowledgeSettingsTests
```

预期:编译失败(无 `restartKnowledgeService:` 参数、无 `saveKnowledgeModelSettings`)。

- [ ] **Step 3: 实现 SettingsViewModel**

在 `<ROOT>/AIRecording/ViewModels/SettingsViewModel.swift` 中:

(a) 第 33 行 `knowledgeStatusError` 之后追加发布属性:

```swift
    @Published var knowledgeEmbeddingModel = KnowledgeModelCatalog.defaultEmbeddingModel
    @Published var knowledgeEmbeddingDimension = 0
    @Published var knowledgeRerankModel = KnowledgeModelCatalog.defaultRerankModel
```

(b) 第 94 行 `ossEndpointKey` 之后追加键常量:

```swift
    private let knowledgeEmbeddingModelKey = "knowledge.embeddingModel"
    private let knowledgeEmbeddingDimensionKey = "knowledge.embeddingDimension"
    private let knowledgeRerankModelKey = "knowledge.rerankModel"
```

(c) 存储属性区(第 74 行 `retryKnowledgeSync` 之后)加:

```swift
    private let restartKnowledgeService: @Sendable () async -> Void
```

(d) `init` 参数列表在 `retryKnowledgeSync` 之后加默认参数,并存储:

```swift
        restartKnowledgeService: @escaping @Sendable () async -> Void = {
            await KnowledgeServiceManager.shared.restartService()
        }
```

init 体内 `self.retryKnowledgeSync = retryKnowledgeSync` 之后加 `self.restartKnowledgeService = restartKnowledgeService`。

(e) `loadSettings()` 末尾(`knowledgeAPIKeyMasked = ...` 一行之后)追加:

```swift
        knowledgeEmbeddingModel = defaults.string(forKey: knowledgeEmbeddingModelKey)
            ?? KnowledgeModelCatalog.defaultEmbeddingModel
        knowledgeEmbeddingDimension = defaults.integer(forKey: knowledgeEmbeddingDimensionKey)
        knowledgeRerankModel = defaults.string(forKey: knowledgeRerankModelKey)
            ?? KnowledgeModelCatalog.defaultRerankModel
```

(f) `saveKnowledgeKey` 方法之后新增:

```swift
    func saveKnowledgeModelSettings(embeddingModel: String, embeddingDimension: Int?, rerankModel: String) async {
        defaults.set(embeddingModel, forKey: knowledgeEmbeddingModelKey)
        defaults.set(rerankModel, forKey: knowledgeRerankModelKey)
        if let embeddingDimension {
            defaults.set(embeddingDimension, forKey: knowledgeEmbeddingDimensionKey)
        } else {
            defaults.removeObject(forKey: knowledgeEmbeddingDimensionKey)
        }
        knowledgeEmbeddingModel = embeddingModel
        knowledgeEmbeddingDimension = embeddingDimension ?? 0
        knowledgeRerankModel = rerankModel
        await restartKnowledgeService()
    }
```

- [ ] **Step 4: 实现 SettingsView**

在 `<ROOT>/AIRecording/Views/SettingsView.swift` 中:

(a) "知识库" Section 内、`Button("保存知识库密钥")` 代码块之后、"已索引 …" 之前插入:

```swift
                HStack {
                    Text("Embedding 模型")
                    Spacer()
                    Text(viewModel.knowledgeEmbeddingModel)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("向量维度")
                    Spacer()
                    Text(viewModel.knowledgeEmbeddingDimension > 0 ? "\(viewModel.knowledgeEmbeddingDimension)" : "自动")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Rerank 模型")
                    Spacer()
                    Text(viewModel.knowledgeRerankModel)
                        .foregroundStyle(.secondary)
                }

                Button("配置检索模型") {
                    showKnowledgeModelConfig = true
                }

                Text("更改向量模型或维度后，请点击「重建知识库」使已有内容用新模型重新入库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

(b) `@State` 区(205 行附近)加:

```swift
    @State private var showKnowledgeModelConfig = false
```

(c) `.sheet(isPresented: $showFunASRConfig) { ... }` 之后加:

```swift
        .sheet(isPresented: $showKnowledgeModelConfig) {
            KnowledgeModelConfigSheet(viewModel: viewModel)
        }
```

(d) 文件末尾(`FunASRConfigSheet` 之后)追加整个 sheet 视图:

```swift
struct KnowledgeModelConfigSheet: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var embeddingSelection: String = KnowledgeModelCatalog.defaultEmbeddingModel
    @State private var customEmbeddingModel: String = ""
    @State private var embeddingDimension: Int = 1024
    @State private var rerankSelection: String = KnowledgeModelCatalog.defaultRerankModel
    @State private var customRerankModel: String = ""

    private var isCustomEmbeddingModel: Bool {
        embeddingSelection == KnowledgeModelCatalog.customSentinel
    }

    private var isCustomRerankModel: Bool {
        rerankSelection == KnowledgeModelCatalog.customSentinel
    }

    private var canSave: Bool {
        let embedding = isCustomEmbeddingModel ? customEmbeddingModel : embeddingSelection
        let rerank = isCustomRerankModel ? customRerankModel : rerankSelection
        return !embedding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !rerank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("知识库检索模型")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                Picker("Embedding 模型", selection: $embeddingSelection) {
                    ForEach(KnowledgeModelCatalog.embeddingModelNames, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Text("自定义…").tag(KnowledgeModelCatalog.customSentinel)
                }

                if isCustomEmbeddingModel {
                    TextField("模型名称", text: $customEmbeddingModel)
                        .textFieldStyle(.roundedBorder)
                } else if let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection) {
                    Picker("向量维度", selection: $embeddingDimension) {
                        ForEach(options, id: \.self) { dimension in
                            Text("\(dimension)").tag(dimension)
                        }
                    }
                }

                Picker("Rerank 模型", selection: $rerankSelection) {
                    ForEach(KnowledgeModelCatalog.rerankModelNames, id: \.self) { model in
                        Text(model).tag(model)
                    }
                    Text("自定义…").tag(KnowledgeModelCatalog.customSentinel)
                }

                if isCustomRerankModel {
                    TextField("模型名称", text: $customRerankModel)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 420)

            Text("更改向量模型或维度后，请点击「重建知识库」使已有内容用新模型重新入库。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    let embedding = isCustomEmbeddingModel
                        ? customEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        : embeddingSelection
                    let dimension: Int? = isCustomEmbeddingModel ? nil : embeddingDimension
                    let rerank = isCustomRerankModel
                        ? customRerankModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        : rerankSelection
                    Task {
                        await viewModel.saveKnowledgeModelSettings(
                            embeddingModel: embedding,
                            embeddingDimension: dimension,
                            rerankModel: rerank
                        )
                        dismiss()
                    }
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 480, height: 380)
        .onChange(of: embeddingSelection) { newValue in
            guard newValue != KnowledgeModelCatalog.customSentinel,
                  let options = KnowledgeModelCatalog.dimensions(for: newValue),
                  !options.contains(embeddingDimension) else { return }
            embeddingDimension = options[0]
        }
        .onAppear {
            if KnowledgeModelCatalog.dimensions(for: viewModel.knowledgeEmbeddingModel) != nil {
                embeddingSelection = viewModel.knowledgeEmbeddingModel
            } else {
                embeddingSelection = KnowledgeModelCatalog.customSentinel
                customEmbeddingModel = viewModel.knowledgeEmbeddingModel
            }
            if let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection),
               options.contains(viewModel.knowledgeEmbeddingDimension) {
                embeddingDimension = viewModel.knowledgeEmbeddingDimension
            } else if let options = KnowledgeModelCatalog.dimensions(for: embeddingSelection) {
                embeddingDimension = options[0]
            }
            if KnowledgeModelCatalog.rerankModelNames.contains(viewModel.knowledgeRerankModel) {
                rerankSelection = viewModel.knowledgeRerankModel
            } else {
                rerankSelection = KnowledgeModelCatalog.customSentinel
                customRerankModel = viewModel.knowledgeRerankModel
            }
        }
    }
}
```

- [ ] **Step 5: 运行确认通过 + 全量回归**

```bash
cd <ROOT> && swift test --filter KnowledgeSettingsTests
cd <ROOT> && swift test
```

预期:全部 PASS。

- [ ] **Step 6: 提交**

```bash
cd <ROOT> && git add AIRecording/ViewModels/SettingsViewModel.swift AIRecording/Views/SettingsView.swift Tests/AIRecordingTests/KnowledgeSettingsTests.swift && git commit -m "feat(rag): expose embedding model, dimension and rerank settings"
```

---

### Task 7: .env.example 与最终回归

**Files:**
- Modify: `<ROOT>/.env.example`

- [ ] **Step 1: 更新 .env.example**

将 `<ROOT>/.env.example` 整体替换为:

```
DASHSCOPE_API_KEY=
EMBEDDING_MODEL=text-embedding-v4
EMBEDDING_DIMENSION=1024
RERANK_MODEL=gte-rerank-v2
```

- [ ] **Step 2: 双侧全量回归**

```bash
cd <ROOT>/KnowledgeAgent && .venv/bin/python -m pytest -q
cd <ROOT> && swift test
```

预期:两侧全部 PASS。

- [ ] **Step 3: 提交**

```bash
cd <ROOT> && git add .env.example && git commit -m "chore(rag): document EMBEDDING_DIMENSION in env example"
```

- [ ] **Step 4: 手工验收(需要真实 DashScope Key,可与用户一起做)**

1. `swift run` 启动 App → 设置 → 知识库 → "配置检索模型" → 确认默认 text-embedding-v4 / 1024 / gte-rerank-v2,保存 → 服务自动重启,`~/Library/Logs/AIRecording/` 无异常。
2. 把维度改为 1536 → 保存 → 点"重建知识库" → 等同步完成后,`sqlite3 ~/Library/Application\ Support/AIRecording/Knowledge/knowledge.sqlite "SELECT DISTINCT embedding_dimension FROM chunks;"` 应只剩 1536。
3. 选"自定义…"填一个不存在的模型名 → 维度行隐藏 → 保存 → 提问仍可用(API 报错时自动降级 FTS,符合设计)。
4. 清空 DashScope API Key → 重启 App → 知识库提问走纯文字检索(回归原降级行为)。

---

## 完成定义

- [ ] Task 1-7 全部勾选,两侧测试全绿;
- [ ] 设置界面可见并可通过"配置检索模型"修改三项配置,保存后服务自动重启;
- [ ] Python 端日志(无异常错误码)与 `~/Library/Logs/AIRecording/chart-agent.log`/`app.log` 无新增敏感信息泄露(仅错误码);
- [ ] 手工验收 4 步通过(或与用户约定豁免)。
