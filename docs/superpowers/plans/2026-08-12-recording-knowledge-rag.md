# Recording Knowledge RAG Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local, automatically synchronized RAG knowledge base over every completed recording transcription and meeting summary, with persistent chat sessions and timestamped source links.

**Architecture:** A standalone local `KnowledgeAgent` owns SQLite/FTS5, embeddings, hybrid retrieval, reranking, evidence construction, and strict cited answers. Swift owns Core Data business entities, synchronization, service lifecycle, chat UI, and navigation back to recording segments. The service runs only on `127.0.0.1:8766`; release builds package it as a signed standalone executable so users do not install Python or Docker.

**Tech Stack:** Swift 5.9, SwiftUI, Core Data, Combine, Security/Keychain, Python 3.12, FastAPI, SQLite FTS5, NumPy, DashScope, OpenAI-compatible chat completions, XCTest, pytest.

---

## Scope and file map

This is one implementation plan because ingestion, retrieval, source identity, Swift persistence, and navigation share one API contract. Each task leaves a testable boundary and a commit.

### New Python files

- `KnowledgeAgent/main.py` — FastAPI entry point and service version.
- `KnowledgeAgent/requirements.txt` — locked runtime dependencies.
- `KnowledgeAgent/agent/config.py` — environment parsing and fixed RAG constants.
- `KnowledgeAgent/agent/schema.py` — strict request/response/SSE models.
- `KnowledgeAgent/agent/store.py` — SQLite schema, transactions, FTS5, vectors, jobs, backup/reset.
- `KnowledgeAgent/agent/chunker.py` — segment-aware generation/retrieval/summary chunking.
- `KnowledgeAgent/agent/embedding.py` — DashScope embedding and rerank adapter.
- `KnowledgeAgent/agent/ingestion.py` — hashes, idempotency, atomic replacement, deletion.
- `KnowledgeAgent/agent/retrieval.py` — vector/FTS/summary routing, RRF, rerank, parent mapping.
- `KnowledgeAgent/agent/context.py` — evidence budget and stable `S#` sources.
- `KnowledgeAgent/agent/answering.py` — strict prompt, citation validation, one repair, SSE deltas.
- `KnowledgeAgent/agent/observability.py` — redacted JSON-line logging.
- `KnowledgeAgent/tests/` — focused pytest suites for each module and API contract.

### New Swift files

- `AIRecording/Models/KnowledgeChatSession.swift`
- `AIRecording/Models/KnowledgeChatMessage.swift`
- `AIRecording/Models/KnowledgeSourceLink.swift`
- `AIRecording/Services/KnowledgeDTO.swift`
- `AIRecording/Services/KnowledgeClient.swift`
- `AIRecording/Services/KnowledgeServiceManager.swift`
- `AIRecording/Services/KnowledgeCredentialStore.swift`
- `AIRecording/Services/KnowledgeSyncCoordinator.swift`
- `AIRecording/Services/KnowledgeChatRepository.swift`
- `AIRecording/ViewModels/KnowledgeBaseViewModel.swift`
- `AIRecording/Views/KnowledgeBaseView.swift`
- `AIRecording/Views/KnowledgeSourceChipsView.swift`

### Existing files to modify

- `.gitignore`, `.env.example` — secret-safe local configuration.
- `Package.swift` — bundle KnowledgeAgent sources for development.
- `Scripts/build-app.sh` — build/copy/sign standalone KnowledgeAgent.
- `AIRecording/Services/PersistenceController.swift` — add three chat entities and relationships.
- `AIRecording/ViewModels/RecordingDetailViewModel.swift` — accept source segment/time highlighting.
- `AIRecording/Views/RecordingDetailView.swift` — scroll/highlight a cited segment.
- `AIRecording/Views/MainWindowView.swift` — add knowledge navigation and source jump routing.
- `AIRecording/ViewModels/SettingsViewModel.swift`, `AIRecording/Views/SettingsView.swift` — Keychain-backed DashScope configuration and index status actions.
- `AIRecording/App/AIRecordingApp.swift` — start synchronization after launch and stop service at termination.
- `AIRecording/App/MenuBarController.swift` — add a typed knowledge-source navigation notification.
- `AIRecording/Utilities/AppLogger.swift`, `AIRecording/Utilities/LogSanitizer.swift` — KnowledgeAgent log category and credential patterns.

## Task 1: Secret-safe configuration and KnowledgeAgent health skeleton

**Files:**
- Modify: `.gitignore`
- Create: `.env.example`
- Create: `KnowledgeAgent/requirements.txt`
- Create: `KnowledgeAgent/agent/__init__.py`
- Create: `KnowledgeAgent/agent/config.py`
- Create: `KnowledgeAgent/agent/schema.py`
- Create: `KnowledgeAgent/main.py`
- Create: `KnowledgeAgent/tests/test_config.py`
- Create: `KnowledgeAgent/tests/test_health.py`
- Modify: `Package.swift`

- [ ] **Step 1: Protect local secrets before reading or copying them**

Add exactly:

```gitignore
# Local model credentials
.env
.env.*
!.env.example
KnowledgeAgent/.venv/
```

Create `.env.example` without real values:

```dotenv
DASHSCOPE_API_KEY=
EMBEDDING_MODEL=text-embedding-v4
RERANK_MODEL=gte-rerank-v2
```

- [ ] **Step 2: Verify `.env` is ignored and not tracked**

Run:

```bash
touch .env
git check-ignore -v .env
git ls-files --error-unmatch .env
```

Expected: `git check-ignore` names the new rule; `git ls-files` exits non-zero because `.env` is not tracked. Remove the empty file before the next step if the reference key check fails.

- [ ] **Step 3: Copy only the DashScope key without printing its value**

Run this mechanical secret transfer only after Step 2 passes:

```bash
umask 077
/usr/bin/awk -F= '$1 == "DASHSCOPE_API_KEY" { print; found=1 } END { if (!found) exit 2 }' \
  /Users/radiorabbit/Desktop/WorkPlace/shudao-RAG/.env > .env
chmod 600 .env
sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' .env
```

Expected: the final command prints only `DASHSCOPE_API_KEY`. It must never print the value. Do not add `.env` to Git.

- [ ] **Step 4: Create the isolated KnowledgeAgent development environment**

Create `KnowledgeAgent/requirements.txt` first:

```text
fastapi==0.115.6
uvicorn[standard]==0.32.1
pydantic>=2.10,<3
numpy>=2.1,<3
dashscope>=1.20,<2
openai>=1.50,<2
httpx>=0.28,<1
pyinstaller>=6.11,<7
pytest>=8.3,<9
```

Then install it only in the repository-local virtual environment:

```bash
python3 -m venv KnowledgeAgent/.venv
KnowledgeAgent/.venv/bin/python -m pip install --upgrade pip
KnowledgeAgent/.venv/bin/python -m pip install -r KnowledgeAgent/requirements.txt
```

Expected: installation succeeds inside `KnowledgeAgent/.venv`; `git status --short` does not list the virtual environment.

- [ ] **Step 5: Write failing configuration and health tests**

```python
# KnowledgeAgent/tests/test_config.py
from agent.config import KnowledgeConfig


def test_config_uses_fixed_local_defaults(monkeypatch, tmp_path):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", str(tmp_path / "knowledge.sqlite"))
    monkeypatch.setenv("DASHSCOPE_API_KEY", "secret")
    config = KnowledgeConfig.from_environment()
    assert config.host == "127.0.0.1"
    assert config.port == 8766
    assert config.embedding_model == "text-embedding-v4"
    assert config.rerank_model == "gte-rerank-v2"
    assert config.retrieval_chunk_size == 250
    assert config.generation_chunk_size == 1500
    assert config.db_path.name == "knowledge.sqlite"
```

```python
# KnowledgeAgent/tests/test_health.py
from fastapi.testclient import TestClient
from main import API_VERSION, SERVICE_VERSION, app


def test_health_contract():
    response = TestClient(app).get("/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "apiVersion": API_VERSION,
        "serviceVersion": SERVICE_VERSION,
        "indexVersion": 1,
    }
```

- [ ] **Step 6: Run the tests to verify they fail**

Run:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_config.py KnowledgeAgent/tests/test_health.py -q
```

Expected: FAIL because `agent.config` and `main` do not exist.

- [ ] **Step 7: Implement the minimal service contract**

Use a frozen dataclass in `config.py` with these exact public names:

```python
@dataclass(frozen=True)
class KnowledgeConfig:
    db_path: Path
    host: str = "127.0.0.1"
    port: int = 8766
    embedding_model: str = "text-embedding-v4"
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
            rerank_model=os.environ.get("RERANK_MODEL", "gte-rerank-v2"),
        )
```

`main.py` must expose `API_VERSION = "1.0"`, `SERVICE_VERSION = "1.0.0"`, and return the tested health payload. `schema.py` begins with a shared strict model:

```python
class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")
```

Add `.copy("KnowledgeAgent")` to `Package.swift` resources and exclude `KnowledgeAgent/tests` from the executable target.

- [ ] **Step 8: Run focused tests and the Swift manifest check**

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_config.py KnowledgeAgent/tests/test_health.py -q
swift package dump-package >/dev/null
```

Expected: 2 Python tests PASS; Swift package manifest exits 0.

- [ ] **Step 9: Commit tracked files only**

```bash
git add .gitignore .env.example Package.swift KnowledgeAgent
git commit -m "feat(rag): add local knowledge service skeleton"
```

Before committing, run `git status --short` and verify `.env` is absent.

## Task 2: Segment-aware chunking and SQLite atomic ingestion

**Files:**
- Create: `KnowledgeAgent/agent/chunker.py`
- Create: `KnowledgeAgent/agent/store.py`
- Create: `KnowledgeAgent/agent/ingestion.py`
- Extend: `KnowledgeAgent/agent/schema.py`
- Create: `KnowledgeAgent/tests/test_chunker.py`
- Create: `KnowledgeAgent/tests/test_store.py`
- Create: `KnowledgeAgent/tests/test_ingestion.py`

- [ ] **Step 1: Define the strict ingestion DTOs and failing tests**

The schema must use these identities so Swift and Python remain consistent:

```python
class TranscriptSegment(StrictModel):
    id: str
    sequence: int
    startTime: float
    endTime: float
    speakerId: str | None = None
    speakerName: str | None = None
    text: str = Field(min_length=1)


class RecordingUpsertRequest(StrictModel):
    recordingId: str
    title: str
    recordedAt: datetime
    contentHash: str
    summaryHash: str
    indexVersion: int
    summaryMarkdown: str | None = None
    segments: list[TranscriptSegment] = Field(min_length=1)


class RecordingUpsertResponse(StrictModel):
    status: Literal["indexed", "unchanged", "degraded"]
    generationChunks: int
    retrievalChunks: int
    summaryChunks: int
    embeddedChunks: int
```

Write tests asserting:

```python
def test_dual_chunks_preserve_parent_substrings_and_times():
    chunks = SegmentChunker(retrieval_size=12, retrieval_overlap=2,
                            generation_size=30, generation_overlap=4).chunk(SEGMENTS)
    assert chunks.retrieval
    for child in chunks.retrieval:
        parent = next(item for item in chunks.generation if item.id == child.parent_id)
        assert child.content in parent.content
        assert parent.start_time <= child.start_time <= child.end_time <= parent.end_time
        assert child.segment_ids


def test_summary_chunks_are_route_only():
    routes = chunk_summary("# 决策\n张伟负责上线。")
    assert routes[0].role == "summary_route"
    assert routes[0].segment_ids == []
```

Store tests must assert FTS5 exists, foreign keys cascade, and `replace_recording()` leaves old enabled rows intact when the transaction raises before commit.

- [ ] **Step 2: Run tests to verify failure**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_chunker.py KnowledgeAgent/tests/test_store.py \
  KnowledgeAgent/tests/test_ingestion.py -q
```

Expected: FAIL on missing `SegmentChunker`, `KnowledgeStore`, and `RecordingIngestionService`.

- [ ] **Step 3: Implement the focused chunk data types and algorithm**

Use these public types:

```python
@dataclass(frozen=True)
class KnowledgeChunk:
    id: str
    role: Literal["generation", "retrieval", "summary_route"]
    content: str
    chunk_index: int
    parent_id: str | None
    segment_ids: tuple[str, ...]
    start_time: float | None
    end_time: float | None
    speaker_id: str | None
    speaker_name: str | None


@dataclass(frozen=True)
class DualChunks:
    generation: tuple[KnowledgeChunk, ...]
    retrieval: tuple[KnowledgeChunk, ...]
```

Port the reference project’s boundary priority `\n\n`, `[。；？！]\s*`, `\n`, `[、，]\s*`. Build parents first, then children inside each parent. Map character ranges back to every intersecting segment; IDs are deterministic SHA-256 hashes of recordingId, role, parent index, and chunk index.

- [ ] **Step 4: Implement the SQLite schema and transaction API**

`KnowledgeStore.initialize()` creates `documents`, `chunks`, `chunk_fts`, and `sync_jobs`. Use WAL and foreign keys. Expose:

```python
class KnowledgeStore:
    def get_document_hashes(self, recording_id: str) -> tuple[str, str, int] | None:
        return self._fetch_document_hashes(recording_id)
    def replace_recording(self, request: RecordingUpsertRequest,
                          chunks: Sequence[KnowledgeChunk],
                          embeddings: Mapping[str, np.ndarray | None]) -> None:
        self._replace_recording_transaction(request, chunks, embeddings)
    def delete_recording(self, recording_id: str) -> None:
        self._delete_recording_transaction(recording_id)
    def list_missing_embedding_chunks(self, limit: int = 100) -> list[StoredChunk]:
        return self._fetch_missing_embedding_chunks(limit)
    def status(self) -> StoreStatus:
        return self._fetch_store_status()
```

Within `replace_recording`, insert a new generation marker, all chunks, and FTS rows in one transaction; only then delete the old document version. Store normalized vectors with `np.asarray(vector, dtype=np.float32).tobytes()` and store the dimension separately.

- [ ] **Step 5: Implement idempotent ingestion without real model calls**

Define an injectable protocol and result:

```python
class DocumentEmbedder(Protocol):
    async def embed_documents(self, texts: list[str]) -> list[np.ndarray | None]:
        raise NotImplementedError


class RecordingIngestionService:
    async def upsert(self, request: RecordingUpsertRequest) -> RecordingUpsertResponse:
        return await self._upsert_recording(request)
    def delete(self, recording_id: str) -> None:
        self.store.delete_recording(recording_id)
```

If all hashes and index version match, return `unchanged`. If only `summaryHash` changes, reuse stored retrieval embeddings and replace only summary_route rows. If any embedding is `None`, persist FTS rows, return `degraded`, and enqueue a missing-embedding job.

- [ ] **Step 6: Run focused tests**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_chunker.py KnowledgeAgent/tests/test_store.py \
  KnowledgeAgent/tests/test_ingestion.py -q
```

Expected: PASS, including unchanged, summary-only, degraded, rollback, and delete cases.

- [ ] **Step 7: Commit**

```bash
git add KnowledgeAgent/agent KnowledgeAgent/tests
git commit -m "feat(rag): add atomic transcript indexing"
```

## Task 3: DashScope adapters and hybrid retrieval

**Files:**
- Create: `KnowledgeAgent/agent/embedding.py`
- Create: `KnowledgeAgent/agent/retrieval.py`
- Extend: `KnowledgeAgent/agent/store.py`
- Create: `KnowledgeAgent/tests/test_embedding.py`
- Create: `KnowledgeAgent/tests/test_retrieval.py`

- [ ] **Step 1: Write failing adapter and retrieval tests with fakes**

Cover these exact outcomes:

```python
async def test_missing_key_returns_none_and_never_calls_sdk(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    adapter = DashScopeAdapter()
    assert await adapter.embed_query("上线负责人") is None
    assert await adapter.embed_documents(["张伟负责上线"]) == [None]


async def test_summary_route_never_becomes_evidence(store_with_chunks):
    result = await HybridRetriever(store_with_chunks, FakeEmbedding(), FakeReranker()).retrieve(
        "谁负责上线"
    )
    assert result.chunks
    assert all(chunk.role == "retrieval" for chunk in result.chunks)
    assert "recording-from-summary-route" in result.routed_recording_ids


def test_rrf_is_rank_based_and_deduplicates():
    fused = reciprocal_rank_fusion([["a", "b"], ["b", "c"]], k=60)
    assert fused[0].item_id == "b"
    assert len({item.item_id for item in fused}) == 3
```

Also test FTS-only behavior, vector-only behavior, rerank failure fallback, route top three recording IDs, 40-candidate caps, and 10 final retrieval chunks.

- [ ] **Step 2: Run tests to verify failure**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_embedding.py KnowledgeAgent/tests/test_retrieval.py -q
```

Expected: FAIL because adapters and retriever do not exist.

- [ ] **Step 3: Implement DashScope behind a narrow interface**

```python
class EmbeddingRerankAdapter(Protocol):
    async def embed_query(self, text: str) -> np.ndarray | None:
        raise NotImplementedError
    async def embed_documents(self, texts: list[str]) -> list[np.ndarray | None]:
        raise NotImplementedError
    async def rerank(self, query: str, chunks: list[StoredChunk], top_k: int) -> list[StoredChunk]:
        raise NotImplementedError
```

`DashScopeAdapter` uses query/document text types, batches 25 documents, normalizes every valid vector, and returns `None` for missing keys or stable provider failures. Do not log provider response bodies.

- [ ] **Step 4: Add store search primitives**

Implement exact return type `SearchHit(chunk: StoredChunk, score: float)` and methods:

```python
def search_fts(self, query: str, roles: tuple[str, ...], limit: int,
               recording_ids: tuple[str, ...] = ()) -> list[SearchHit]:
    return self._search_fts_rows(query, roles, limit, recording_ids)
def search_vector(self, vector: np.ndarray, roles: tuple[str, ...], limit: int,
                  recording_ids: tuple[str, ...] = ()) -> list[SearchHit]:
    return self._search_vector_rows(vector, roles, limit, recording_ids)
def generation_parents(self, parent_ids: Sequence[str]) -> dict[str, StoredChunk]:
    return self._fetch_generation_parents(parent_ids)
```

FTS uses parameter binding and `bm25(chunk_fts)`. Vector search rejects rows whose stored dimension differs from the query and uses one NumPy matrix multiplication over normalized float32 rows.

- [ ] **Step 5: Implement the four-route retriever**

`HybridRetriever.retrieve(query)` must:

1. request one query embedding;
2. retrieve 40 raw vector and 40 raw FTS children;
3. retrieve summary_route vector and FTS hits and keep three recording IDs;
4. retrieve constrained raw children from those recordings;
5. fuse only raw child lists with `reciprocal_rank_fusion([raw_vector_hits, raw_fts_hits, routed_vector_hits, routed_fts_hits], k=60)`;
6. pass the top 30 to rerank when available;
7. return at most 10 retrieval chunks plus `strategy`, `reranked`, and routed IDs.

The orchestration shape is:

```python
async def retrieve(self, query: str) -> RetrievalResult:
    vector = await self.adapter.embed_query(query)
    raw_vector_hits = self.store.search_vector(vector, ("retrieval",), 40) if vector is not None else []
    raw_fts_hits = self.store.search_fts(query, ("retrieval",), 40)
    route_hits = self._summary_route_hits(query, vector, limit=3)
    routed_ids = tuple(hit.chunk.recording_id for hit in route_hits)
    routed_vector_hits = self.store.search_vector(vector, ("retrieval",), 40, routed_ids) if vector is not None else []
    routed_fts_hits = self.store.search_fts(query, ("retrieval",), 40, routed_ids)
    fused = reciprocal_rank_fusion(
        [raw_vector_hits, raw_fts_hits, routed_vector_hits, routed_fts_hits], k=60
    )[:30]
    ranked = await self._rerank_or_fallback(query, fused, top_k=10)
    return RetrievalResult(chunks=ranked, routed_recording_ids=routed_ids,
                           strategy=self._strategy(vector, raw_fts_hits),
                           reranked=self._last_rerank_succeeded)
```

- [ ] **Step 6: Run tests**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_embedding.py KnowledgeAgent/tests/test_retrieval.py -q
```

Expected: PASS for hybrid, FTS-only, rerank fallback, summary routing, caps, and exclusion rules.

- [ ] **Step 7: Commit**

```bash
git add KnowledgeAgent/agent KnowledgeAgent/tests
git commit -m "feat(rag): add hybrid recording retrieval"
```

## Task 4: Evidence context, strict citations, and streaming answers

**Files:**
- Create: `KnowledgeAgent/agent/context.py`
- Create: `KnowledgeAgent/agent/answering.py`
- Create: `KnowledgeAgent/tests/test_context.py`
- Create: `KnowledgeAgent/tests/test_answering.py`

- [ ] **Step 1: Write failing evidence and answer tests**

```python
def test_context_maps_children_to_unique_parents_with_stable_sources(store):
    built = EvidenceContextBuilder(store, max_parents=6, max_chars=12_000).build(CHILD_HITS)
    assert [source.sourceId for source in built.sources] == ["S1", "S2"]
    assert built.sources[0].recordingId == "rec-1"
    assert built.sources[0].segmentIds == ["seg-1", "seg-2"]
    assert built.sources[0].startTime == 12.5
    assert len(built.contextText) <= 12_000


async def test_invalid_citation_repairs_once_then_refuses():
    llm = FakeLLM(["负责人是张伟。[S99]", "负责人是张伟。"])
    result = await StrictAnswerService(llm).answer("谁负责？", EVIDENCE, [])
    assert llm.call_count == 2
    assert result.content == "知识库中没有足够依据。"
    assert result.sources == EVIDENCE.sources


def test_every_non_heading_answer_paragraph_requires_a_valid_source():
    assert validate_citations("## 结论\n张伟负责。[S1]\n\n时间是周五。", {"S1"}) is False
```

Also test source order, exact parent truncation, fixed refusal text, six-message history cap, and that history is absent from the evidence section.

- [ ] **Step 2: Run tests to verify failure**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_context.py KnowledgeAgent/tests/test_answering.py -q
```

Expected: FAIL because context and answer services do not exist.

- [ ] **Step 3: Implement evidence DTOs and builder**

```python
class EvidenceSource(StrictModel):
    sourceId: str
    recordingId: str
    segmentIds: list[str]
    startTime: float
    endTime: float
    speakerName: str | None = None


class BuiltEvidence(StrictModel):
    contextText: str
    sources: list[EvidenceSource]
```

Assign source IDs from `S1` through `Sn` after parent deduplication. Include each parent’s raw text and matched-child locations. Never include summary_route content. Stop before adding a parent that would exceed 12,000 characters.

- [ ] **Step 4: Implement the LLM adapter and strict prompt**

Define `ChatCompletionClient.complete_stream(messages) -> AsyncIterator[str]` and an OpenAI-compatible implementation using `OPENAI_BASE_URL`, `OPENAI_API_KEY`, and `LLM_MODEL`.

The system prompt must state, in Chinese, all five rules from design §8.5. Format evidence in a dedicated `<evidence>` block and history in a separate `<conversation_context>` block. The repair prompt must identify only citation-format failure; it must not add new evidence.

```python
SYSTEM_PROMPT = """你是录音知识库问答助手。
只能依据 <evidence> 中的原始转写回答；会议纪要和对话历史不是事实来源。
每个事实性段落必须引用至少一个有效来源编号，例如 [S1]。
证据不足时只回答：知识库中没有足够依据。
不得用常识补充人物、数字、日期、责任人、决策或因果关系。"""

messages = [
    {"role": "system", "content": SYSTEM_PROMPT},
    {"role": "user", "content": f"<conversation_context>{history_text}</conversation_context>\n"
                                f"<evidence>{evidence.contextText}</evidence>\n"
                                f"<question>{question}</question>"},
]
```

- [ ] **Step 5: Implement citation validation and buffering semantics**

Buffer the provider stream inside `StrictAnswerService` until citation validation passes. Emit deltas to the API layer only from the validated final text. This intentionally trades token-by-token immediacy for the requirement that Swift never displays or saves an invalid cited answer.

Validation rules:

```python
SOURCE_PATTERN = re.compile(r"\[(S\d+)\]")
EXEMPT_PARAGRAPHS = {"知识库中没有足够依据。"}
```

Markdown headings and empty paragraphs are exempt. Every other paragraph must contain at least one ID from the supplied source set. One invalid result triggers one repair; a second invalid result returns the fixed refusal.

- [ ] **Step 6: Run focused tests**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_context.py KnowledgeAgent/tests/test_answering.py -q
```

Expected: PASS, with exactly two LLM calls in the repair failure test.

- [ ] **Step 7: Commit**

```bash
git add KnowledgeAgent/agent KnowledgeAgent/tests
git commit -m "feat(rag): add grounded cited answers"
```

## Task 5: Knowledge API, safe logging, retry, reset, and recovery

**Files:**
- Extend: `KnowledgeAgent/main.py`
- Extend: `KnowledgeAgent/agent/schema.py`
- Create: `KnowledgeAgent/agent/observability.py`
- Extend: `KnowledgeAgent/agent/store.py`
- Create: `KnowledgeAgent/tests/test_api.py`
- Create: `KnowledgeAgent/tests/test_observability.py`
- Create: `KnowledgeAgent/tests/test_recovery.py`

- [ ] **Step 1: Write failing endpoint and privacy tests**

Test exact endpoints and SSE sequence:

```python
def test_query_sse_contract(client_with_fakes):
    with client_with_fakes.stream("POST", "/knowledge/query", json=QUERY) as response:
        events = parse_sse(response.iter_lines())
    assert [event["event"] for event in events] == [
        "retrieval_started", "sources", "answer_delta", "answer_completed"
    ]
    assert events[-1]["data"]["content"] == "张伟负责上线。[S1]"


def test_logs_never_contain_user_text_or_credentials(capsys):
    log_event("query_failed", correlation_id="req-1", error_code="LLM_TIMEOUT",
              metadata={"apiKey": "sk-secret", "query": "谁负责上线"})
    output = capsys.readouterr().out
    assert "sk-secret" not in output
    assert "谁负责上线" not in output
    assert "LLM_TIMEOUT" in output
```

Also test strict unknown-field rejection, idempotent PUT, DELETE, status counts, retry-failed, reset-index, service version, and malformed empty segment rejection.

- [ ] **Step 2: Run tests to verify failure**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest \
  KnowledgeAgent/tests/test_api.py KnowledgeAgent/tests/test_observability.py \
  KnowledgeAgent/tests/test_recovery.py -q
```

Expected: FAIL on missing endpoints and logging/recovery APIs.

- [ ] **Step 3: Implement endpoint wiring with dependency factories**

Expose factory functions so tests replace services without real APIs:

```python
class KnowledgeHistoryMessage(StrictModel):
    role: Literal["user", "assistant"]
    content: str


class KnowledgeQueryRequest(StrictModel):
    requestId: str
    sessionId: str
    query: str = Field(min_length=1)
    history: list[KnowledgeHistoryMessage] = Field(max_length=6)


class KnowledgeStatusResponse(StrictModel):
    documents: int
    chunks: int
    pendingJobs: int
    failedJobs: int
    degraded: bool


def get_ingestion_service() -> RecordingIngestionService:
    return app.state.ingestion_service
def get_retriever() -> HybridRetriever:
    return app.state.retriever
def get_answer_service() -> StrictAnswerService:
    return app.state.answer_service
```

Implement `GET /knowledge/status`, `PUT/DELETE /knowledge/recordings/{id}`, `POST /knowledge/query`, `POST /knowledge/retry-failed`, and `POST /knowledge/reset-index`. Validate path recordingId equals body recordingId. Map stable errors to HTTP status without returning exception bodies.

- [ ] **Step 4: Implement safe SSE events**

Use this envelope for every event:

```python
class KnowledgeStreamEvent(StrictModel):
    event: Literal["retrieval_started", "sources", "answer_delta", "answer_completed", "error"]
    requestId: str
    data: dict[str, Any]
```

Set `media_type="text/event-stream"`, emit JSON in `data:`, and stop downstream work when `await request.is_disconnected()` is true at retrieval/LLM boundaries.

- [ ] **Step 5: Implement retry and backup behavior**

`sync_jobs` tracks only internal missing-embedding work, with retry timestamps 5, 30, and 120 seconds after provider failure. Source upsert/transport retries remain Swift-owned because Swift can safely re-read Core Data without duplicating transcript payloads in a job table. `reset_index()` performs `PRAGMA wal_checkpoint(TRUNCATE)`, uses `sqlite3.Connection.backup()` to `knowledge.sqlite.backup`, builds a fresh schema, and restores backup on failure. Only fixed files inside the configured Knowledge directory may be touched.

```python
def backup_database(connection: sqlite3.Connection, backup_path: Path) -> None:
    connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    with sqlite3.connect(backup_path) as destination:
        connection.backup(destination)


RETRY_DELAYS_SECONDS = (5, 30, 120)
```

- [ ] **Step 6: Implement safe observability**

Allow only scalar metadata keys from an explicit whitelist. Hash recording IDs to 12 hex characters. Replace secret/query/transcript/summary/answer keys with `"[REDACTED]"`. Emit one JSON object per line with `ts`, `level`, `process="knowledge-agent"`, `event`, `correlationId`, `errorCode`, `durationMs`, and safe metadata.

```python
ALLOWED_METADATA = {"model", "candidateCount", "sourceCount", "statusCode", "result"}
REDACTED_KEYS = {"apiKey", "authorization", "query", "transcript", "summary", "answer", "prompt"}

safe_metadata = {
    key: value for key, value in metadata.items()
    if key in ALLOWED_METADATA and isinstance(value, (str, int, float, bool))
}
```

- [ ] **Step 7: Run all KnowledgeAgent tests**

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest KnowledgeAgent/tests -q
```

Expected: all tests PASS; no real network calls.

- [ ] **Step 8: Commit**

```bash
git add KnowledgeAgent
git commit -m "feat(rag): expose resilient knowledge API"
```

## Task 6: Swift DTOs, client, credentials, and service lifecycle

**Files:**
- Create: `AIRecording/Services/KnowledgeDTO.swift`
- Create: `AIRecording/Services/KnowledgeCredentialStore.swift`
- Create: `AIRecording/Services/KnowledgeClient.swift`
- Create: `AIRecording/Services/KnowledgeServiceManager.swift`
- Modify: `AIRecording/Utilities/LogSanitizer.swift`
- Create: `Tests/AIRecordingTests/KnowledgeDTOTests.swift`
- Create: `Tests/AIRecordingTests/KnowledgeClientTests.swift`
- Create: `Tests/AIRecordingTests/KnowledgeServiceManagerTests.swift`

- [ ] **Step 1: Write failing DTO and environment tests**

Use the Python contract’s camelCase names directly:

```swift
func testRecordingRequestDropsBlankSegments() throws {
    let request = KnowledgeRecordingRequest.make(recording: recordingWithBlankSegment)
    XCTAssertEqual(request.segments.map(\.text), ["张伟负责上线"])
    XCTAssertEqual(request.indexVersion, 1)
}

func testServiceEnvironmentUsesOnlyWhitelistedSecrets() {
    let environment = KnowledgeServiceManager.serviceEnvironment(
        parent: ["UNRELATED_SECRET": "no"],
        dashScopeKey: "dash",
        llm: .init(baseURL: "https://api.deepseek.com/v1", apiKey: "llm", model: "deepseek-chat"),
        databasePath: "/tmp/knowledge.sqlite",
        port: 8766
    )
    XCTAssertNil(environment["UNRELATED_SECRET"])
    XCTAssertEqual(environment["DASHSCOPE_API_KEY"], "dash")
    XCTAssertEqual(environment["OPENAI_API_KEY"], "llm")
}
```

Client tests use a custom `URLProtocol` to feed health JSON and SSE split across arbitrary byte boundaries; assert event order, UTF-8 correctness, cancellation, and stable error mapping.

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --filter 'Knowledge(DTO|Client|ServiceManager)Tests'
```

Expected: FAIL because the new Swift types do not exist.

- [ ] **Step 3: Implement contract DTOs**

Define `KnowledgeRecordingRequest`, `KnowledgeSegmentDTO`, `KnowledgeStatusDTO`, `KnowledgeSourceDTO`, `KnowledgeQueryRequest`, `KnowledgeStreamEvent`, and `KnowledgeHealthDTO` as `Codable`, `Sendable`, and `Equatable` where possible. `KnowledgeQueryRequest` includes `requestId`, `sessionId`, `query`, and at most six completed history messages.

```swift
struct KnowledgeSourceDTO: Codable, Sendable, Equatable {
    let sourceId: String
    let recordingId: UUID
    let segmentIds: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speakerName: String?
}

struct KnowledgeQueryRequest: Codable, Sendable, Equatable {
    let requestId: UUID
    let sessionId: UUID
    let query: String
    let history: [KnowledgeHistoryMessageDTO]
}
```

- [ ] **Step 4: Implement Keychain and development env resolution**

```swift
protocol KnowledgeCredentialLoading: Sendable {
    func dashScopeAPIKey() -> String
}

struct KnowledgeCredentialStore: KnowledgeCredentialLoading {
    static let service = "com.airecording.knowledge"
    func saveDashScopeAPIKey(_ value: String) throws
    func dashScopeAPIKey() -> String
}
```

Use Security framework generic-password items. `KnowledgeServiceManager` resolves process environment first, local project `.env` only in debug/source runs, then Keychain. The dotenv parser reads only `DASHSCOPE_API_KEY`, `EMBEDDING_MODEL`, and `RERANK_MODEL` and never logs values.

- [ ] **Step 5: Implement the streaming client**

```swift
protocol KnowledgeClientProtocol: Sendable {
    func health() async throws -> KnowledgeHealthDTO
    func status() async throws -> KnowledgeStatusDTO
    func upsert(_ request: KnowledgeRecordingRequest) async throws -> KnowledgeUpsertResponse
    func delete(recordingId: UUID) async throws
    func query(_ request: KnowledgeQueryRequest) -> AsyncThrowingStream<KnowledgeStreamEvent, Error>
    func retryFailed() async throws
    func resetIndex() async throws
}
```

Use `URLSession.bytes(for:)` and a line buffer that handles split UTF-8/SSE frames. Cancel the URLSession task when the stream continuation terminates.

- [ ] **Step 6: Implement service lifecycle and stale-process eviction**

Use port 8766 and expected service version `1.0.0`. In source builds execute configured `KNOWLEDGE_AGENT_PYTHON` with bundled `main.py`; in release prefer the bundled `knowledge-agent` executable. Only reuse a live process spawned by this manager instance. Capture stdout/stderr through `SubprocessLogCapture` and ingest them with process category `knowledge-agent`.

```swift
nonisolated static let expectedServiceVersion = "1.0.0"
private let servicePort = 8766

private func launchConfiguration() throws -> (executable: URL, arguments: [String]) {
    if let binary = Bundle.module.url(forResource: "knowledge-agent", withExtension: nil) {
        return (binary, [])
    }
    guard let python = resolvedDevelopmentPython(),
          let main = Bundle.module.url(forResource: "main", withExtension: "py",
                                       subdirectory: "KnowledgeAgent") else {
        throw KnowledgeServiceError.runtimeUnavailable
    }
    return (python, [main.path])
}
```

- [ ] **Step 7: Run focused and regression tests**

```bash
swift test --filter 'Knowledge(DTO|Client|ServiceManager)Tests'
swift test --filter SmartChartTests
```

Expected: new tests PASS; existing ChartAgent environment/process tests remain PASS.

- [ ] **Step 8: Commit**

```bash
git add AIRecording/Services AIRecording/Utilities/LogSanitizer.swift Tests/AIRecordingTests
git commit -m "feat(rag): add Swift knowledge service client"
```

## Task 7: Core Data chat models and automatic synchronization

**Files:**
- Create: `AIRecording/Models/KnowledgeChatSession.swift`
- Create: `AIRecording/Models/KnowledgeChatMessage.swift`
- Create: `AIRecording/Models/KnowledgeSourceLink.swift`
- Modify: `AIRecording/Services/PersistenceController.swift`
- Create: `AIRecording/Services/KnowledgeChatRepository.swift`
- Create: `AIRecording/Services/KnowledgeSyncCoordinator.swift`
- Modify: `AIRecording/App/AIRecordingApp.swift`
- Create: `Tests/AIRecordingTests/KnowledgePersistenceTests.swift`
- Create: `Tests/AIRecordingTests/KnowledgeSyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing persistence relationship tests**

```swift
func testDeletingSessionCascadesMessagesAndSources() throws {
    let persistence = PersistenceController(inMemory: true)
    let repository = KnowledgeChatRepository(context: persistence.container.viewContext)
    let session = try repository.createSession(title: "项目复盘")
    let message = try repository.appendAssistant(
        content: "张伟负责。[S1]", status: .completed, session: session,
        sources: [.fixture(recordingId: recording.id!, segmentId: segment.id!)]
    )
    XCTAssertEqual(message.sources?.count, 1)
    try repository.deleteSession(session)
    XCTAssertEqual(try repository.fetchSessions(), [])
    XCTAssertEqual(try repository.fetchAllSources(), [])
}
```

Also test pending/completed/failed/cancelled values, source order, no quote snapshot field, and lightweight migration opening an existing store.

- [ ] **Step 2: Write failing synchronization tests**

Use a fake `KnowledgeClientProtocol` and deterministic clock. These tests cover Swift-owned source submission retries; Python-owned missing-embedding retries remain in Task 5. Assert:

```swift
func testInitialScanIndexesOnlyCompletedNonDeletedRecordings() async throws
func testSummaryChangeUpsertsSameRecordingWithoutDuplicateQueueEntry() async throws
func testSoftDeleteRemovesRecordingFromIndex() async throws
func testThreeRetriesUseFiveThirtyAndOneTwentySecondDelays() async throws
func testSyncFailureNeverChangesTranscriptionStatus() async throws
```

- [ ] **Step 3: Run tests to verify failure**

```bash
swift test --filter 'Knowledge(Persistence|SyncCoordinator)Tests'
```

Expected: FAIL because entities, repository, and coordinator do not exist.

- [ ] **Step 4: Add programmatic Core Data entities**

Add three `NSManagedObject` subclasses with typed computed enums. In `PersistenceController.model`, define session→messages and message→sources as cascade relationships with inverses. Source stores only IDs, times, and order. Use model default values so automatic lightweight migration can add entities without destroying the existing store.

```swift
let sessionToMessages = NSRelationshipDescription()
sessionToMessages.name = "messages"
sessionToMessages.destinationEntity = knowledgeMessage
sessionToMessages.minCount = 0
sessionToMessages.maxCount = 0
sessionToMessages.deleteRule = .cascadeDeleteRule
sessionToMessages.isOptional = true

let messageToSources = NSRelationshipDescription()
messageToSources.name = "sources"
messageToSources.destinationEntity = knowledgeSource
messageToSources.minCount = 0
messageToSources.maxCount = 0
messageToSources.deleteRule = .cascadeDeleteRule
messageToSources.isOptional = true
```

- [ ] **Step 5: Implement repository boundaries**

```swift
@MainActor
final class KnowledgeChatRepository {
    func fetchSessions() throws -> [KnowledgeChatSession]
    func createSession(title: String) throws -> KnowledgeChatSession
    func renameSession(_ session: KnowledgeChatSession, title: String) throws
    func deleteSession(_ session: KnowledgeChatSession) throws
    func appendUser(content: String, session: KnowledgeChatSession) throws -> KnowledgeChatMessage
    func appendAssistant(content: String, status: KnowledgeMessageStatus,
                         session: KnowledgeChatSession,
                         sources: [KnowledgeSourceDTO]) throws -> KnowledgeChatMessage
}
```

Never save partial streamed assistant text. Failed/cancelled messages save empty content plus `errorCode`.

- [ ] **Step 6: Implement the coordinator as a non-blocking actor**

```swift
actor KnowledgeSyncCoordinator {
    static let shared = KnowledgeSyncCoordinator()
    func start() async
    func scanHistoricalRecordings() async
    func recordingDidChange(objectID: NSManagedObjectID) async
    func retryFailed() async
    func stop()
}
```

Fetch Core Data snapshots on a background context, convert them to Sendable DTOs, then call the service. Observe `NSManagedObjectContextObjectsDidChange` and debounce/deduplicate by recording object ID. Never mutate `Recording` or `Transcription` status. Schedule retries at 5, 30, and 120 seconds and cancel them on stop or source deletion.

- [ ] **Step 7: Start synchronization from app lifecycle**

Create the coordinator in `AppDelegate.applicationDidFinishLaunching`, launch `start()` in a Task, and stop both coordinator and KnowledgeServiceManager in `applicationWillTerminate`.

```swift
func applicationDidFinishLaunching(_ notification: Notification) {
    menuBarController = MenuBarController()
    NSApp.setActivationPolicy(.regular)
    Task { await KnowledgeSyncCoordinator.shared.start() }
}

func applicationWillTerminate(_ notification: Notification) {
    Task { await KnowledgeSyncCoordinator.shared.stop() }
    KnowledgeServiceManager.shared.stopService()
}
```

- [ ] **Step 8: Run focused and full persistence tests**

```bash
swift test --filter 'Knowledge(Persistence|SyncCoordinator)Tests'
swift test --filter TranscriptionInvariantTests
```

Expected: PASS; transcription invariants remain unchanged.

- [ ] **Step 9: Commit**

```bash
git add AIRecording/Models AIRecording/Services/PersistenceController.swift \
  AIRecording/Services/KnowledgeChatRepository.swift \
  AIRecording/Services/KnowledgeSyncCoordinator.swift AIRecording/App/AIRecordingApp.swift \
  Tests/AIRecordingTests
git commit -m "feat(rag): persist chats and sync recordings"
```

## Task 8: Knowledge chat ViewModel and two-column UI

**Files:**
- Create: `AIRecording/ViewModels/KnowledgeBaseViewModel.swift`
- Create: `AIRecording/Views/KnowledgeBaseView.swift`
- Create: `AIRecording/Views/KnowledgeSourceChipsView.swift`
- Modify: `AIRecording/Views/MainWindowView.swift`
- Create: `Tests/AIRecordingTests/KnowledgeBaseViewModelTests.swift`

- [ ] **Step 1: Write failing ViewModel state tests**

```swift
@MainActor
func testCompletedStreamPersistsOneAssistantMessageAndOrderedSources() async throws {
    let client = FakeKnowledgeClient(events: [
        .sources([.fixture(sourceId: "S1")]),
        .answerDelta("张伟负责上线。[S1]"),
        .answerCompleted(content: "张伟负责上线。[S1]", sourceIds: ["S1"])
    ])
    let viewModel = makeViewModel(client: client)
    await viewModel.send("谁负责上线？")
    XCTAssertEqual(viewModel.messages.filter { $0.role == .assistant }.count, 1)
    XCTAssertEqual(viewModel.messages.last?.sources.first?.sourceOrder, 0)
}

@MainActor
func testLateEventsFromCancelledRequestCannotOverwriteNewRequest() async throws

@MainActor
func testFailurePersistsNoPartialAssistantContentAndCanRetry() async throws
```

Also test session create/rename/delete, six-message history cap, empty question guard, and index-degraded banner.

- [ ] **Step 2: Run tests to verify failure**

```bash
swift test --filter KnowledgeBaseViewModelTests
```

Expected: FAIL because `KnowledgeBaseViewModel` does not exist.

- [ ] **Step 3: Implement the ViewModel**

```swift
@MainActor
final class KnowledgeBaseViewModel: ObservableObject {
    @Published private(set) var sessions: [KnowledgeChatSession] = []
    @Published var selectedSessionID: NSManagedObjectID?
    @Published private(set) var messages: [KnowledgeChatMessage] = []
    @Published var draft = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var displayedAnswer = ""
    @Published private(set) var pendingSources: [KnowledgeSourceDTO] = []
    @Published private(set) var knowledgeStatus: KnowledgeStatusDTO?
    @Published var errorMessage: String?

    func load() async
    func createSession()
    func renameSelectedSession(to title: String)
    func deleteSelectedSession()
    func send(_ question: String) async
    func cancelGeneration()
    func retryLastQuestion() async
}
```

Use a request UUID gate like the existing chart request gate so stale events cannot modify state. Persist the user message immediately; persist the assistant only after `answerCompleted`.

- [ ] **Step 4: Implement the selected two-column page**

`KnowledgeBaseView` uses an `HStack`: a 220–260 point session sidebar and flexible chat column. The left column has “新建对话”, selection, rename/delete context menu, and timestamps. The chat column has Markdown messages, progress/error/empty states, source chips under each assistant message, and a bottom composer with Send/Stop.

```swift
struct KnowledgeBaseView: View {
    @StateObject private var viewModel = KnowledgeBaseViewModel()

    var body: some View {
        HStack(spacing: 0) {
            KnowledgeSessionList(viewModel: viewModel)
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
            Divider()
            KnowledgeConversationView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await viewModel.load() }
    }
}
```

Define `KnowledgeSessionList` and `KnowledgeConversationView` as private focused subviews in the same `KnowledgeBaseView.swift` file; they receive the existing ViewModel and own no persistence or network logic.

`KnowledgeSourceChipsView` displays `[S#] 录音标题 · mm:ss`; selecting a chip expands a short dynamically loaded transcript preview plus “跳到录音”. Do not show similarity or embedding values.

- [ ] **Step 5: Add the sidebar navigation entry**

Extend:

```swift
enum SidebarItem: Hashable {
    case recordings
    case knowledge
    case settings
}
```

Place `Label("知识库", systemImage: "books.vertical")` between recordings and settings. Render `KnowledgeBaseView` for `.knowledge`.

- [ ] **Step 6: Run ViewModel tests and build**

```bash
swift test --filter KnowledgeBaseViewModelTests
swift build
```

Expected: tests PASS and application builds with exhaustive navigation switch.

- [ ] **Step 7: Commit**

```bash
git add AIRecording/ViewModels/KnowledgeBaseViewModel.swift AIRecording/Views \
  AIRecording/Views/MainWindowView.swift Tests/AIRecordingTests/KnowledgeBaseViewModelTests.swift
git commit -m "feat(rag): add knowledge chat interface"
```

## Task 9: Source navigation, settings, and index controls

**Files:**
- Modify: `AIRecording/App/MenuBarController.swift`
- Modify: `AIRecording/Views/MainWindowView.swift`
- Modify: `AIRecording/ViewModels/RecordingDetailViewModel.swift`
- Modify: `AIRecording/Views/RecordingDetailView.swift`
- Modify: `AIRecording/ViewModels/SettingsViewModel.swift`
- Modify: `AIRecording/Views/SettingsView.swift`
- Create: `Tests/AIRecordingTests/KnowledgeSourceNavigationTests.swift`
- Create: `Tests/AIRecordingTests/KnowledgeSettingsTests.swift`

- [ ] **Step 1: Write failing navigation tests**

Define a Sendable payload:

```swift
struct KnowledgeSourceNavigation: Sendable, Equatable {
    let recordingObjectURI: URL
    let segmentId: UUID?
    let startTime: TimeInterval
}
```

Tests assert segment-first and time fallback behavior:

```swift
func testHighlightUsesSegmentIDWhenPresent() {
    let target = RecordingDetailViewModel.resolveSourceTarget(
        segmentID: segment.id!, startTime: 99, segments: [segment]
    )
    XCTAssertEqual(target.segmentID, segment.id)
    XCTAssertEqual(target.seekTime, segment.startTime)
}

func testMissingSegmentFallsBackToSourceStartTime() {
    let target = RecordingDetailViewModel.resolveSourceTarget(
        segmentID: UUID(), startTime: 42, segments: []
    )
    XCTAssertNil(target.segmentID)
    XCTAssertEqual(target.seekTime, 42)
}
```

- [ ] **Step 2: Write failing settings tests**

Test masked key display, save/delete through an injected credential store, retry-failed, reset confirmation calling the client once, and that no key enters UserDefaults.

- [ ] **Step 3: Run tests to verify failure**

```bash
swift test --filter 'Knowledge(SourceNavigation|Settings)Tests'
```

Expected: FAIL on missing navigation resolver and settings properties.

- [ ] **Step 4: Implement typed source navigation**

Add `.openKnowledgeSource` notification. `KnowledgeBaseViewModel` resolves recordingId to a non-deleted Core Data object and posts `KnowledgeSourceNavigation`. `MainWindowView` switches to recordings, sets the object ID, and forwards source target state into `RecordingDetailView`.

```swift
NotificationCenter.default.post(
    name: .openKnowledgeSource,
    object: KnowledgeSourceNavigation(
        recordingObjectURI: recording.objectID.uriRepresentation(),
        segmentId: source.segmentId,
        startTime: source.startTime
    )
)
```

`RecordingDetailViewModel` exposes `highlightedSegmentId` and seeks the player. `RecordingDetailView` uses `ScrollViewReader` with stable segment IDs, scrolls to the target, and visually highlights it. If recording is deleted, disable the chip action and show “录音已删除”.

- [ ] **Step 5: Implement Keychain-backed settings and index status**

Extend `SettingsViewModel` with masked DashScope key, knowledge document/chunk/failed counts, `saveKnowledgeKey`, `retryFailedKnowledgeSync`, and `resetKnowledgeIndex`. `retryFailedKnowledgeSync` must call both `KnowledgeSyncCoordinator.retryFailed()` for source resubmission and `KnowledgeClient.retryFailed()` for missing embeddings. Do not store the DashScope key in UserDefaults. `SettingsView` adds a “知识库” section with a secure field, status text, retry button, and destructive-confirmation alert for rebuild.

```swift
func retryFailedKnowledgeSync() async {
    await KnowledgeSyncCoordinator.shared.retryFailed()
    try? await knowledgeClient.retryFailed()
    await loadKnowledgeStatus()
}

func saveKnowledgeKey(_ value: String) throws {
    try credentialStore.saveDashScopeAPIKey(value)
    knowledgeAPIKeyMasked = value.isEmpty ? "未配置" : "••••••••"
}
```

- [ ] **Step 6: Run focused tests and build**

```bash
swift test --filter 'Knowledge(SourceNavigation|Settings)Tests'
swift build
```

Expected: tests PASS; source payload types satisfy StrictConcurrency.

- [ ] **Step 7: Commit**

```bash
git add AIRecording/App/MenuBarController.swift AIRecording/Views/MainWindowView.swift \
  AIRecording/ViewModels/RecordingDetailViewModel.swift AIRecording/Views/RecordingDetailView.swift \
  AIRecording/ViewModels/SettingsViewModel.swift AIRecording/Views/SettingsView.swift \
  Tests/AIRecordingTests
git commit -m "feat(rag): connect sources and knowledge settings"
```

## Task 10: Release packaging, integration fixtures, privacy audit, and full verification

**Files:**
- Modify: `Scripts/build-app.sh`
- Modify: `AIRecording/Utilities/AppLogger.swift`
- Modify: `AIRecording/Utilities/LogSanitizer.swift`
- Create: `KnowledgeAgent/knowledge-agent.spec`
- Create: `KnowledgeAgent/tests/fixtures/two_recordings.json`
- Create: `KnowledgeAgent/tests/test_end_to_end.py`
- Create: `Tests/AIRecordingTests/KnowledgeContractFixtureTests.swift`
- Create: `docs/knowledge-rag/manual-acceptance.md`

- [ ] **Step 1: Add a shared two-recording contract fixture**

The fixture must contain one meeting where 张伟 is assigned release coordination at a known segment/time, one later meeting confirming the assignment, and one unrelated question with no evidence. It contains no real user data. Python and Swift both decode the same JSON.

- [ ] **Step 2: Write failing end-to-end tests**

Python test:

```python
async def test_two_recordings_answer_has_clickable_raw_sources(rag_harness):
    await rag_harness.ingest_fixture("two_recordings.json")
    answer = await rag_harness.query("最终由谁负责上线协调？")
    assert "张伟" in answer.content
    assert answer.sources
    assert all(source.segmentIds for source in answer.sources)
    assert all(source.startTime >= 0 for source in answer.sources)


async def test_unrelated_question_refuses(rag_harness):
    answer = await rag_harness.query("公司的年度营收是多少？")
    assert answer.content == "知识库中没有足够依据。"
```

Swift fixture test decodes the same response and verifies the source constructs a valid navigation payload.

- [ ] **Step 3: Run tests to verify missing harness/packaging failures**

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest KnowledgeAgent/tests/test_end_to_end.py -q
swift test --filter KnowledgeContractFixtureTests
```

Expected: FAIL until the fixture harness and bundle lookup exist.

- [ ] **Step 4: Package KnowledgeAgent as a standalone executable**

Create a PyInstaller spec with entry point `KnowledgeAgent/main.py`, include the `agent` package, and collect DashScope/OpenAI metadata. Update `Scripts/build-app.sh` to:

1. create an isolated build output under `.build/knowledge-agent`;
2. run `KnowledgeAgent/.venv/bin/python -m PyInstaller --clean --noconfirm KnowledgeAgent/knowledge-agent.spec`;
3. copy the resulting `knowledge-agent` into `Contents/Resources/KnowledgeAgent/`;
4. mark it executable before signing;
5. verify `knowledge-agent` launches, `/health` reports version `1.0.0`, then terminate it;
6. rely on the existing final deep codesign so the nested executable is signed.

Never copy `.env` into the app bundle.

- [ ] **Step 5: Finish privacy logging integration**

Add a `knowledge-agent` process/category path to AppLogger ingestion. Extend sanitizer credential patterns for `DASHSCOPE_API_KEY`, `OPENAI_API_KEY`, bearer tokens, and query-like fields. Add regression tests asserting raw fixture questions, answers, titles, speaker names, segment text, and both fake secrets never appear in captured Swift or Python logs.

- [ ] **Step 6: Implement and run the shared fixture harness**

Use fake embedding/rerank/LLM adapters with deterministic vectors and answers. Do not call paid APIs. Ensure the Python response’s recordingId/segmentIds/times decode in Swift without custom field renaming.

```bash
PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest KnowledgeAgent/tests/test_end_to_end.py -q
swift test --filter KnowledgeContractFixtureTests
```

Expected: PASS for cross-meeting answer, refusal, deletion, and contract identity.

- [ ] **Step 7: Write manual real-configuration acceptance steps**

`docs/knowledge-rag/manual-acceptance.md` must state:

1. confirm `.env` is ignored and contains only the allowed key name;
2. launch the app and wait for historical indexing progress;
3. ask one question whose answer spans two known recordings;
4. verify every factual paragraph has source chips;
5. click a source and confirm player/highlight time;
6. remove DashScope key and verify FTS-only degraded banner/query;
7. restore key and retry missing embeddings;
8. soft-delete a recording and verify it disappears from results;
9. kill KnowledgeAgent and verify automatic recovery without recording disruption;
10. inspect logs with only secret names/patterns, never secret values or user text.

- [ ] **Step 8: Run complete automated verification**

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=KnowledgeAgent KnowledgeAgent/.venv/bin/python -m pytest KnowledgeAgent/tests -q
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=ChartAgent python3 -m pytest ChartAgent/tests -q
swift test
swift build -c release
git diff --check
```

Expected: all Python and Swift tests PASS; release build succeeds; diff check is clean.

- [ ] **Step 9: Run secret and scope audits**

```bash
git check-ignore -q .env
git ls-files | rg '(^|/)\.env$' && exit 1 || true
rg -n 'DASHSCOPE_API_KEY\s*=\s*[^[:space:]]+' --glob '!.env' --glob '!*.example' .
rg -n 'PostgreSQL|pgvector|Redis|MinIO|Docker' KnowledgeAgent AIRecording/Services/Knowledge* AIRecording/Views/Knowledge*
```

Expected: `.env` ignored and untracked; no committed secret assignment; the final search has no production dependency references (test/design documentation exclusions are acceptable).

- [ ] **Step 10: Commit final integration**

```bash
git add Scripts/build-app.sh AIRecording/Utilities KnowledgeAgent \
  Tests/AIRecordingTests docs/knowledge-rag/manual-acceptance.md
git commit -m "test(rag): verify packaged recording knowledge base"
```

## Final completion checklist

- [ ] Every task’s focused tests pass immediately before its commit.
- [ ] `git status --short` contains no accidental `.env`, visual-companion, build, log, SQLite, WAL, backup, or user recording files.
- [ ] Existing user changes present before implementation remain untouched and uncommitted unless the user separately authorizes them.
- [ ] The only imported reference secret is `DASHSCOPE_API_KEY`; it exists only in ignored local `.env` or Keychain.
- [ ] The complete verification commands in Task 10 pass with fresh output.
- [ ] Manual real-configuration acceptance is performed only after automated tests pass and without printing secrets or user transcript content.

## Plan self-review result

- Spec §§1–4 (scope and architecture): Tasks 1 and 6 establish the isolated local service, configuration boundary, and release runtime.
- Spec §§6–7 (data and ingestion): Tasks 2 and 7 implement SQLite/Core Data ownership, double-layer chunks, hashes, atomic replacement, automatic scan, update, and deletion.
- Spec §8 (retrieval and answer): Tasks 3–5 implement four-route retrieval, RRF, rerank fallback, parent evidence, strict citations, refusal, repair, and SSE.
- Spec §§9–10 (API and UI): Tasks 5, 6, 8, and 9 implement the strict contract, two-column chat, persistent sessions, inline sources, and timestamp navigation.
- Spec §§11–13 (keys, failures, privacy): Tasks 1, 5–7, 9, and 10 implement the single-key import, Keychain, FTS degradation, retries, backup/recovery, process restart, and redacted logs.
- Spec §§14–15 (tests and acceptance): Every task is TDD-scoped; Task 10 adds shared end-to-end fixtures, packaging, full regression, audits, and manual real-configuration acceptance.
- No spec requirement is deferred to an unspecified later task, and no external document upload, multi-user service, PostgreSQL, Redis, MinIO, Docker, or unrelated refactor is introduced.
