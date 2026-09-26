# 知识库时间感知问答实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 知识库问答识别"最新/最近/最早"时间词,按录音日期锁定目标录音后检索或概括;每段证据标注录音标题与日期。

**Architecture:** 在 Python `KnowledgeAgent` 检索层前加规则式时间意图分支(路径 A 限定检索 / 路径 B 父块概括),证据渲染层补充 `documents` 表已有的 `title`/`recorded_at` 元数据;Swift 侧只递增版本门并在来源胶囊显示日期。无 schema 变更,无需重建索引。

**Tech Stack:** Python 3.14 + FastAPI + SQLite/FTS5 + NumPy(worktree 内 `.venv`);SwiftUI + XCTest。

**Spec:** `docs/superpowers/specs/2026-08-29-knowledge-temporal-retrieval-design.md`

**工作目录:** 本计划所有命令在知识库实现所在工作树执行:

```bash
cd /Users/radiorabbit/Desktop/WorkPlace/AIRecording/.worktrees/recording-knowledge-rag
```

分支 `codex/recording-knowledge-rag`。Python 测试命令统一为 `cd KnowledgeAgent && .venv/bin/python -m pytest ...`;Swift 测试为仓库根目录 `swift test`。

---

### Task 1: 时间意图识别模块 `temporal.py`

**Files:**
- Create: `KnowledgeAgent/agent/temporal.py`
- Test: `KnowledgeAgent/tests/test_temporal.py`

- [ ] **Step 1: 写失败测试**

创建 `KnowledgeAgent/tests/test_temporal.py`:

```python
from agent.temporal import detect_intent, is_generic_query, strip_intent


def test_detect_maps_specific_phrases_before_bare_words():
    assert detect_intent("最新一次会议说了什么") == ("最新一次", "desc", 1)
    assert detect_intent("最近几场都在聊什么") == ("最近几场", "desc", 3)
    assert detect_intent("最近一次提到预算") == ("最近一次", "desc", 3)


def test_detect_bare_words_and_directions():
    assert detect_intent("最新的音频内容是什么") == ("最新", "desc", 1)
    assert detect_intent("最近讲了什么") == ("最近", "desc", 3)
    assert detect_intent("最早的会议说了什么") == ("最早", "asc", 1)
    assert detect_intent("刚刚的会议") == ("刚刚", "desc", 1)
    assert detect_intent("上一场会议") == ("上一场", "desc", 1)


def test_detect_returns_none_without_temporal_words():
    assert detect_intent("预算是谁负责的") is None
    assert detect_intent("") is None


def test_strip_removes_matched_phrase():
    intent = detect_intent("最新的音频内容是什么")
    assert strip_intent("最新的音频内容是什么", intent) == "的音频内容是什么"


def test_generic_query_detection():
    assert is_generic_query("的音频内容是什么") is True
    assert is_generic_query("讲了什么") is True
    assert is_generic_query("") is True
    assert is_generic_query("的会议说了什么") is True
    assert is_generic_query("预算怎么定的") is False
    assert is_generic_query("的会议里预算怎么定的") is False
```

- [ ] **Step 2: 运行确认失败**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_temporal.py -v
```

预期:FAIL,`ModuleNotFoundError: No module named 'agent.temporal'`。

- [ ] **Step 3: 实现模块**

创建 `KnowledgeAgent/agent/temporal.py`:

```python
"""Rule-based temporal intent detection over the user's retrieval text."""

from __future__ import annotations

from dataclasses import dataclass


# Must stay aligned with EvidenceContextBuilder.max_parents (default 6).
BRIEFING_MAX_PARENTS = 6

_GENERIC_FILLERS = (
    "说了什么", "讲了什么", "音频内容", "内容", "音频", "录音", "会议", "什么", "讲了", "说了",
)
_PARTICLES = "的了吗呢吧是"
_PUNCTUATION = "，。？！、：；,.?!:;~～ \t\n"

# Ordered: specific phrases must precede their bare-word substrings.
_TRIGGERS: tuple[tuple[str, str, int], ...] = (
    ("最新一次", "desc", 1),
    ("最新一场", "desc", 1),
    ("最后一场", "desc", 1),
    ("上一场", "desc", 1),
    ("上一个", "desc", 1),
    ("刚刚", "desc", 1),
    ("最新", "desc", 1),
    ("最近一次", "desc", 3),
    ("最近一场", "desc", 3),
    ("最近几场", "desc", 3),
    ("近期", "desc", 3),
    ("这几天", "desc", 3),
    ("最近", "desc", 3),
    ("最早", "asc", 1),
    ("第一场", "asc", 1),
    ("第一次", "asc", 1),
    ("最开始", "asc", 1),
)


@dataclass(frozen=True)
class TemporalIntent:
    phrase: str
    order: str  # "desc" = newest first, "asc" = oldest first
    limit: int

    def __iter__(self):
        return iter((self.phrase, self.order, self.limit))


def detect_intent(text: str) -> TemporalIntent | None:
    if not text:
        return None
    for phrase, order, limit in _TRIGGERS:
        if phrase in text:
            return TemporalIntent(phrase=phrase, order=order, limit=limit)
    return None


def strip_intent(text: str, intent: TemporalIntent) -> str:
    return text.replace(intent.phrase, "")


def is_generic_query(core: str) -> bool:
    """True when removing fillers/particles leaves no real content words."""
    remainder = core
    for filler in _GENERIC_FILLERS:
        remainder = remainder.replace(filler, "")
    remainder = "".join(
        char for char in remainder if char not in _PARTICLES and char not in _PUNCTUATION
    )
    return len(remainder) < 2
```

说明:`TemporalIntent.__iter__` 让元组比较 `(phrase, order, limit) == intent` 成立,测试无需构造实例。

- [ ] **Step 4: 运行确认通过**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_temporal.py -v
```

预期:5 passed。

- [ ] **Step 5: 提交**

```bash
git add KnowledgeAgent/agent/temporal.py KnowledgeAgent/tests/test_temporal.py
git commit -m "feat(rag): add temporal intent detection rules"
```

---

### Task 2: store 层三个查询方法

**Files:**
- Modify: `KnowledgeAgent/agent/store.py`(`generation_parents` 方法之后,`_stored_chunk` 之前插入)
- Test: `KnowledgeAgent/tests/test_store.py`(文件末尾追加)

- [ ] **Step 1: 写失败测试**

在 `KnowledgeAgent/tests/test_store.py` 末尾追加(如该文件已有同名的 `_request` 助手,复用它并只新增带日期参数的版本;避免重定义——先检查文件头):

```python
from datetime import datetime, timezone

from agent.schema import RecordingUpsertRequest, TranscriptSegment


def _dated_request(recording_id, recorded_at, title="会议录音"):
    return RecordingUpsertRequest(
        recordingId=recording_id, title=title, recordedAt=recorded_at,
        contentHash=recording_id, summaryHash=recording_id, indexVersion=1,
        summaryMarkdown="纪要",
        segments=[TranscriptSegment(
            id=f"{recording_id}-segment", sequence=1, startTime=0, endTime=1, text="正文内容",
        )],
    )


def _dated_parents(store, recording_id, recorded_at, count):
    from agent.chunker import KnowledgeChunk

    chunks = tuple(
        KnowledgeChunk(f"{recording_id}-parent-{index}", "generation", f"父块内容 {index}", index,
                       None, (), 0, 1, None, None)
        for index in range(count)
    )
    store.replace_recording(_dated_request(recording_id, recorded_at), chunks, {})
    return chunks


def test_recording_ids_by_recency_orders_and_limits(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    _dated_parents(store, "rec-a", datetime(2026, 8, 1, tzinfo=timezone.utc), 1)
    _dated_parents(store, "rec-b", datetime(2026, 8, 20, tzinfo=timezone.utc), 1)
    _dated_parents(store, "rec-c", datetime(2026, 8, 10, tzinfo=timezone.utc), 1)

    assert store.recording_ids_by_recency("desc", 3) == ("rec-b", "rec-c", "rec-a")
    assert store.recording_ids_by_recency("asc", 3) == ("rec-a", "rec-c", "rec-b")
    assert store.recording_ids_by_recency("desc", 1) == ("rec-b",)
    assert store.recording_ids_by_recency("desc", 0) == ()
    assert store.recording_ids_by_recency("sideways", 3) == ()


def test_recording_ids_by_recency_breaks_same_day_ties_by_insertion(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    same_day = datetime(2026, 8, 20, 9, 0, tzinfo=timezone.utc)
    _dated_parents(store, "rec-first", same_day, 1)
    _dated_parents(store, "rec-second", same_day, 1)

    assert store.recording_ids_by_recency("desc", 2) == ("rec-second", "rec-first")


def test_sample_generation_parents_evenly_covers_and_caps(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    _dated_parents(store, "rec-a", datetime(2026, 8, 20, tzinfo=timezone.utc), 20)

    sampled = store.sample_generation_parents(("rec-a",), 3)

    assert [chunk.chunk_index for chunk in sampled] == [0, 6, 13]
    assert all(chunk.role == "generation" for chunk in sampled)


def test_sample_generation_parents_returns_all_when_few(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    _dated_parents(store, "rec-a", datetime(2026, 8, 20, tzinfo=timezone.utc), 2)

    sampled = store.sample_generation_parents(("rec-a",), 6)

    assert [chunk.chunk_index for chunk in sampled] == [0, 1]
    assert store.sample_generation_parents((), 6) == []
    assert store.sample_generation_parents(("rec-a",), 0) == []


def test_documents_meta_returns_title_and_iso_date(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    _dated_parents(store, "rec-a", datetime(2026, 8, 20, tzinfo=timezone.utc), 1)
    _dated_parents(store, "rec-b", datetime(2026, 8, 1, tzinfo=timezone.utc), 1)

    meta = store.documents_meta(("rec-a", "rec-b", "rec-missing"))

    assert meta["rec-a"][0] == "会议录音"
    assert meta["rec-a"][1] == "2026-08-20"
    assert meta["rec-b"][1] == "2026-08-01"
    assert "rec-missing" not in meta
    assert store.documents_meta(()) == {}
```

- [ ] **Step 2: 运行确认失败**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_store.py -v -k "recency or sample_generation or documents_meta"
```

预期:FAIL,`AttributeError: 'KnowledgeStore' object has no attribute 'recording_ids_by_recency'`。

- [ ] **Step 3: 实现 store 方法**

在 `KnowledgeAgent/agent/store.py` 的 `generation_parents`/`_fetch_generation_parents` 之后、`_stored_chunk` 之前插入:

```python
    @_serialized
    def recording_ids_by_recency(self, order: str, limit: int) -> tuple[str, ...]:
        """Recording ids by calendar date; recorded_at is UTC ISO text so lexical order is chronological."""
        if limit <= 0 or order not in ("asc", "desc"):
            return ()
        direction = "DESC" if order == "desc" else "ASC"
        rows = self.connection.execute(
            f"SELECT recording_id FROM documents "
            f"ORDER BY recorded_at {direction}, created_at {direction}, rowid {direction} LIMIT ?",
            (limit,),
        ).fetchall()
        return tuple(dict.fromkeys(str(row["recording_id"]) for row in rows))

    @_serialized
    def sample_generation_parents(self, recording_ids: tuple[str, ...],
                                  per_recording: int) -> list[StoredChunk]:
        """Evenly sample generation parents per recording; the first chunk is always included."""
        if not recording_ids or per_recording <= 0:
            return []
        sampled: list[StoredChunk] = []
        for recording_id in recording_ids:
            rows = self.connection.execute(
                "SELECT * FROM chunks WHERE recording_id = ? AND role = 'generation' AND enabled = 1 "
                "ORDER BY chunk_index ASC, id ASC", (recording_id,),
            ).fetchall()
            total = len(rows)
            if total == 0:
                continue
            if total <= per_recording:
                indices = range(total)
            else:
                step = total / per_recording
                indices = sorted({min(total - 1, int(index * step)) for index in range(per_recording)})
            sampled.extend(self._stored_chunk(rows[index]) for index in indices)
        return sampled

    @_serialized
    def documents_meta(self, recording_ids: tuple[str, ...]) -> dict[str, tuple[str, str]]:
        """Latest title and calendar date (YYYY-MM-DD) per recording id."""
        if not recording_ids:
            return {}
        placeholders = ",".join("?" for _ in recording_ids)
        rows = self.connection.execute(
            f"SELECT recording_id, title, recorded_at FROM documents "
            f"WHERE recording_id IN ({placeholders}) ORDER BY created_at DESC, rowid DESC",
            tuple(recording_ids),
        ).fetchall()
        meta: dict[str, tuple[str, str]] = {}
        for row in rows:
            meta.setdefault(str(row["recording_id"]), (str(row["title"]), str(row["recorded_at"])[:10]))
        return meta
```

- [ ] **Step 4: 运行确认通过**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_store.py -v
```

预期:全部 PASS(含原有用例)。

- [ ] **Step 5: 提交**

```bash
git add KnowledgeAgent/agent/store.py KnowledgeAgent/tests/test_store.py
git commit -m "feat(rag): add recency, parent sampling and document meta queries"
```

---

### Task 3: 检索层时间分支

**Files:**
- Modify: `KnowledgeAgent/agent/retrieval.py`
- Test: `KnowledgeAgent/tests/test_retrieval.py`(末尾追加)

- [ ] **Step 1: 写失败测试**

在 `KnowledgeAgent/tests/test_retrieval.py` 末尾追加:

```python
def _temporal_request(recording_id, recorded_at):
    return RecordingUpsertRequest(
        recordingId=recording_id, title=f"{recording_id} 周会", recordedAt=recorded_at,
        contentHash=recording_id, summaryHash=recording_id, indexVersion=1,
        summaryMarkdown="例会纪要",
        segments=[TranscriptSegment(
            id=f"{recording_id}-segment", sequence=1, startTime=0, endTime=1, text="launch",
        )],
    )


def _budget_store(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    for recording_id, recorded_at, keyword in (
        ("rec-old", datetime(2026, 8, 1, tzinfo=timezone.utc), "预算分配"),
        ("rec-new", datetime(2026, 8, 20, tzinfo=timezone.utc), "预算调整"),
    ):
        parent = KnowledgeChunk(f"{recording_id}-parent", "generation", "纪要正文", 0, None, (), 0, 1, None, None)
        child = KnowledgeChunk(f"{recording_id}-child", "retrieval", keyword, 0, parent.id, (), 0, 1, None, None)
        route = KnowledgeChunk(f"{recording_id}-route", "summary_route", "例会纪要", 0, None, (), None, None, None, None)
        store.replace_recording(
            _temporal_request(recording_id, recorded_at), (parent, child, route),
            {child.id: np.array([1.0, 0.0])},
        )
    return store


def test_temporal_intent_restricted_search_only_targets_latest(tmp_path):
    store = _budget_store(tmp_path)
    fts_calls = []
    fts_search = store.search_fts

    def record_fts(query, roles, limit, recording_ids=()):
        fts_calls.append(recording_ids)
        return fts_search(query, roles, limit, recording_ids)

    store.search_fts = record_fts
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("最新一场预算怎么定的"))

    assert fts_calls and all(ids == ("rec-new",) for ids in fts_calls)
    assert result.chunks
    assert {chunk.recording_id for chunk in result.chunks} == {"rec-new"}
    assert result.briefing is False


def test_temporal_briefing_samples_parents_without_rerank(tmp_path):
    store = _budget_store(tmp_path)
    reranker = FakeReranker()
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), reranker).retrieve("最新的音频内容是什么"))

    assert result.briefing is True
    assert result.strategy == "temporal_briefing"
    assert result.reranked is False
    assert reranker.calls == []
    assert result.chunks
    assert {chunk.recording_id for chunk in result.chunks} == {"rec-new"}
    assert all(chunk.role == "generation" for chunk in result.chunks)


def test_temporal_briefing_spreads_across_recent_three(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    for index, recording_id in enumerate(("rec-1", "rec-2", "rec-3", "rec-4")):
        recorded_at = datetime(2026, 8, index + 1, tzinfo=timezone.utc)
        parents = tuple(
            KnowledgeChunk(f"{recording_id}-parent-{child}", "generation", f"内容 {child}", child,
                           None, (), 0, 1, None, None)
            for child in range(2)
        )
        store.replace_recording(_temporal_request(recording_id, recorded_at), parents, {})

    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("最近讲了什么"))

    assert result.briefing is True
    covered = {chunk.recording_id for chunk in result.chunks}
    assert covered == {"rec-2", "rec-3", "rec-4"}
    assert len(result.chunks) == 6


def test_temporal_earliest_targets_oldest_recording(tmp_path):
    store = _budget_store(tmp_path)
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("最早的会议讲了什么"))

    assert result.briefing is True
    assert {chunk.recording_id for chunk in result.chunks} == {"rec-old"}


def test_temporal_intent_on_empty_store_falls_back(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("最新的内容是什么"))

    assert result.briefing is False
    assert result.chunks == ()
    assert result.strategy == "empty"


def test_temporal_restricted_search_without_evidence_stays_empty(tmp_path):
    store = _budget_store(tmp_path)
    # 向量桩返回 None,模拟 embedding 降级;FTS 也无匹配,目标内应为空证据。
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(None), None).retrieve("最新一场季度财报数据"))

    assert result.chunks == ()
    assert result.briefing is False


def test_non_temporal_query_keeps_existing_behavior(tmp_path):
    store = _budget_store(tmp_path)
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("预算分配"))

    assert result.briefing is False
    assert result.chunks
    # 两场录音的检索子块向量都命中,纪要路由不命中——走普通路径时 routed 应为空。
    assert {chunk.recording_id for chunk in result.chunks} == {"rec-old", "rec-new"}
    assert result.routed_recording_ids == ()
```

- [ ] **Step 2: 运行确认失败**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_retrieval.py -v -k temporal
```

预期:FAIL,`ImportError: cannot import name ...` 或 `TypeError: RetrievalResult got unexpected keyword 'briefing'`。

- [ ] **Step 3: 实现检索分支**

修改 `KnowledgeAgent/agent/retrieval.py`:

3a. 导入与 `RetrievalResult`(替换现有 dataclass 定义并新增导入):

```python
import math

from agent.temporal import BRIEFING_MAX_PARENTS, TemporalIntent, detect_intent, is_generic_query, strip_intent
```

```python
@dataclass(frozen=True)
class RetrievalResult:
    chunks: tuple[StoredChunk, ...]
    routed_recording_ids: tuple[str, ...]
    strategy: str
    reranked: bool
    briefing: bool = False
```

3b. 现有 `retrieve` 方法改名 `retrieve` → `_retrieve_content`(方法体逐字保留),新增公共入口与时间分支:

```python
    async def retrieve(self, query: str) -> RetrievalResult:
        intent = detect_intent(query)
        if intent is not None:
            return await self._retrieve_temporal(query, intent)
        return await self._retrieve_content(query)

    async def _retrieve_temporal(self, query: str, intent: TemporalIntent) -> RetrievalResult:
        targets = self.store.recording_ids_by_recency(intent.order, intent.limit)
        if not targets:
            return await self._retrieve_content(query)
        core = strip_intent(query, intent)
        if is_generic_query(core):
            per_recording = max(1, math.ceil(BRIEFING_MAX_PARENTS / len(targets)))
            parents = self.store.sample_generation_parents(targets, per_recording)
            return RetrievalResult(
                chunks=tuple(parents),
                routed_recording_ids=targets,
                strategy="temporal_briefing",
                reranked=False,
                briefing=True,
            )
        vector = await self.adapter.embed_query(core)
        raw_vector_hits = (
            self.store.search_vector(vector, ("retrieval",), 40, targets) if vector is not None else []
        )
        raw_fts_hits = self.store.search_fts(core, ("retrieval",), 40, targets)
        fused = reciprocal_rank_fusion([raw_vector_hits, raw_fts_hits], k=60)[:30]
        ranked, reranked = await self._rerank_or_fallback(core, fused, top_k=10)
        return RetrievalResult(
            chunks=tuple(ranked),
            routed_recording_ids=targets,
            strategy=self._strategy(raw_vector_hits, raw_fts_hits, (), ()),
            reranked=reranked,
        )
```

注意:目标内检索跳过 summary 路由(spec §5);`_summary_route_hits`、`_rerank_or_fallback`、`_strategy` 保持原样不动。

- [ ] **Step 4: 运行确认通过(含回归)**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_retrieval.py tests/test_temporal.py -v
```

预期:全部 PASS——特别确认原有用例(`test_summary_route_never_becomes_evidence` 等)不受改名影响。

- [ ] **Step 5: 提交**

```bash
git add KnowledgeAgent/agent/retrieval.py KnowledgeAgent/tests/test_retrieval.py
git commit -m "feat(rag): route temporal queries to date-scoped retrieval"
```

---

### Task 4: 证据元数据(title/recordedAt)

**Files:**
- Modify: `KnowledgeAgent/agent/schema.py:15-21`(`EvidenceSource`)
- Modify: `KnowledgeAgent/agent/context.py`(整体重构 `build` 并新增 `build_direct`)
- Test: `KnowledgeAgent/tests/test_context.py`(末尾追加)

- [ ] **Step 1: 写失败测试**

在 `KnowledgeAgent/tests/test_context.py` 末尾追加(沿用该文件已有的 store/chunk 构造方式;若无现成助手,补齐与下面一致的助手):

```python
from datetime import datetime, timezone

from agent.chunker import KnowledgeChunk
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore


def _meta_store(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    request = RecordingUpsertRequest(
        recordingId="rec-1", title="八月产品周会",
        recordedAt=datetime(2026, 8, 20, tzinfo=timezone.utc),
        contentHash="rec-1", summaryHash="rec-1", indexVersion=1, summaryMarkdown="纪要",
        segments=[TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="正文")],
    )
    parent = KnowledgeChunk("rec-1-parent", "generation", "会议正文", 0, None, (), 0, 1, None, None)
    child = KnowledgeChunk("rec-1-child", "retrieval", "预算调整", 0, parent.id, (), 0, 1, None, None)
    store.replace_recording(request, (parent, child), {})
    return store


def test_build_renders_title_and_recorded_date(tmp_path):
    store = _meta_store(tmp_path)
    chunks = store.chunks_for_recording("rec-1")
    child = next(chunk for chunk in chunks if chunk.role == "retrieval")

    evidence = EvidenceContextBuilder(store).build([child])

    assert "title: 八月产品周会" in evidence.contextText
    assert "recorded_at: 2026-08-20" in evidence.contextText
    assert evidence.sources[0].title == "八月产品周会"
    assert evidence.sources[0].recordedAt == "2026-08-20"


def test_build_direct_maps_parents_with_meta_in_order(tmp_path):
    store = _meta_store(tmp_path)
    parents = [chunk for chunk in store.chunks_for_recording("rec-1") if chunk.role == "generation"]

    builder = EvidenceContextBuilder(store, max_parents=2)
    evidence = builder.build_direct(parents * 2)

    assert [source.sourceId for source in evidence.sources] == ["S1", "S2"]
    assert all(source.title == "八月产品周会" for source in evidence.sources)
    assert all(source.recordedAt == "2026-08-20" for source in evidence.sources)
    assert "title: 八月产品周会" in evidence.contextText
```

(若文件缺少 `EvidenceContextBuilder` 导入,补 `from agent.context import EvidenceContextBuilder`。)

- [ ] **Step 2: 运行确认失败**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_context.py -v
```

预期:FAIL——`EvidenceSource` 无 `title` 属性(pydantic `extra="forbid"` 下传入会报错)、无 `build_direct`。

- [ ] **Step 3: 扩展 schema**

`KnowledgeAgent/agent/schema.py` 的 `EvidenceSource` 改为:

```python
class EvidenceSource(StrictModel):
    sourceId: str
    recordingId: str
    segmentIds: list[str]
    startTime: float
    endTime: float
    speakerName: str | None = None
    title: str = ""
    recordedAt: str = ""
```

- [ ] **Step 4: 重构 context.py**

`KnowledgeAgent/agent/context.py` 整体替换 `build`,新增 `build_direct` 与共享 `_build_from_pairs`,`_render_parent` 增加两行(其余不动):

```python
    def build(self, child_hits: Sequence[StoredChunk]) -> BuiltEvidence:
        """Map ranked retrieval children to their first-seen generation parents.

        A parent is all-or-nothing: leaving it out is safer than weakening a
        source marker by truncating it.  Summary chunks are deliberately
        ignored even if a caller accidentally provides one.
        """
        children_by_parent: dict[str, list[StoredChunk]] = {}
        for child in child_hits:
            if child.role != "retrieval" or child.parent_id is None:
                continue
            children = children_by_parent.setdefault(child.parent_id, [])
            if all(existing.id != child.id for existing in children):
                children.append(child)

        parents = self.store.generation_parents(tuple(children_by_parent))
        ordered = [
            (parents[parent_id], children)
            for parent_id, children in children_by_parent.items()
            if parents.get(parent_id) is not None and parents[parent_id].role == "generation"
        ]
        return self._build_from_pairs(ordered)

    def build_direct(self, parents: Sequence[StoredChunk]) -> BuiltEvidence:
        """Temporal briefing path: parents become evidence in the given order."""
        return self._build_from_pairs([(parent, ()) for parent in parents])

    def _build_from_pairs(
        self, pairs: Sequence[tuple[StoredChunk, Sequence[StoredChunk]]]
    ) -> BuiltEvidence:
        metas = self.store.documents_meta(tuple({parent.recording_id for parent, _ in pairs}))
        context_parts: list[str] = []
        sources: list[EvidenceSource] = []
        total_chars = 0
        for parent, children in pairs:
            if len(sources) == self.max_parents:
                break
            title, recorded_at = metas.get(parent.recording_id, ("", ""))
            source = EvidenceSource(
                sourceId=f"S{len(sources) + 1}",
                recordingId=parent.recording_id,
                segmentIds=list(parent.segment_ids),
                startTime=0.0 if parent.start_time is None else parent.start_time,
                endTime=0.0 if parent.end_time is None else parent.end_time,
                speakerName=parent.speaker_name,
                title=title,
                recordedAt=recorded_at,
            )
            block = self._render_parent(source, parent, children)
            if total_chars + len(block) > self.max_chars:
                break
            context_parts.append(block)
            sources.append(source)
            total_chars += len(block)
        return BuiltEvidence(contextText="".join(context_parts), sources=sources)
```

`_render_parent` 的返回块头部改为(在 `recording_id:` 之后插入两行):

```python
        return (
            f"[{source.sourceId}]\n"
            f"recording_id: {source.recordingId}\n"
            f"title: {source.title}\n"
            f"recorded_at: {source.recordedAt}\n"
            f"segment_ids: {','.join(source.segmentIds)}\n"
            f"time: {source.startTime}-{source.endTime}\n"
            f"speaker: {speaker}\n"
            f"matched_children:\n{child_locations}\n\n"
            f"{parent.content}\n\n"
        )
```

- [ ] **Step 5: 运行确认通过**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_context.py -v
```

预期:全部 PASS。若 `test_end_to_end.py` 有断言证据文本逐字内容的用例,此时会失败——把期望字符串补上 `title:`/`recorded_at:` 两行后重跑(只改期望值,不改断言逻辑)。

- [ ] **Step 6: 提交**

```bash
git add KnowledgeAgent/agent/schema.py KnowledgeAgent/agent/context.py KnowledgeAgent/tests/test_context.py KnowledgeAgent/tests/test_end_to_end.py
git commit -m "feat(rag): expose recording title and date in evidence sources"
```

---

### Task 5: 提示词、装配与 SSE 分发

**Files:**
- Modify: `KnowledgeAgent/agent/answering.py:17-21`(`SYSTEM_PROMPT`)
- Modify: `KnowledgeAgent/agent/main.py:34-35`(`SERVICE_VERSION`)与 `/knowledge/query` 端点
- Test: `KnowledgeAgent/tests/test_answering.py`、`KnowledgeAgent/tests/test_api.py`(末尾追加)

- [ ] **Step 1: 写失败测试**

`tests/test_answering.py` 末尾追加:

```python
def test_system_prompt_requires_date_grounding():
    from agent.answering import SYSTEM_PROMPT

    assert "录制日期" in SYSTEM_PROMPT
    assert "不得推测" in SYSTEM_PROMPT
```

`tests/test_api.py` 末尾追加(沿用文件内 `client_with_fakes` fixture 风格,新增两个专用 fixture):

```python
class RecordingRetriever:
    def __init__(self):
        self.calls = []

    async def retrieve(self, query, history_text=""):
        self.calls.append((query, history_text))
        from agent.retrieval import RetrievalResult
        return RetrievalResult(chunks=(), routed_recording_ids=(), strategy="fts_only", reranked=False)


class BriefingRetriever:
    async def retrieve(self, query, history_text=""):
        from agent.retrieval import RetrievalResult
        from agent.store import StoredChunk
        parent = StoredChunk(
            id="p1", recording_id="rec-1", role="generation", content="正文", chunk_index=0,
            parent_id=None, segment_ids=(), start_time=0.0, end_time=1.0, speaker_id=None,
            speaker_name=None, enabled=True, embedding=None, embedding_dimension=None,
        )
        return RetrievalResult(chunks=(parent,), routed_recording_ids=("rec-1",),
                               strategy="temporal_briefing", reranked=False, briefing=True)


class DirectBuilder:
    def __init__(self):
        self.calls = []

    def build(self, chunks):
        raise AssertionError("briefing retrieval must not use build()")

    def build_direct(self, chunks):
        self.calls.append(list(chunks))
        from agent.schema import BuiltEvidence, EvidenceSource
        return BuiltEvidence(contextText="[S1] 概括", sources=[EvidenceSource(
            sourceId="S1", recordingId="rec-1", segmentIds=[], startTime=0, endTime=1,
            title="标题", recordedAt="2026-08-29",
        )])


def test_query_passes_current_question_and_last_user_history_to_retriever(client_with_fakes):
    retriever = RecordingRetriever()
    app.state.retriever = retriever
    payload = {
        "requestId": str(uuid.uuid4()), "sessionId": str(uuid.uuid4()),
        "query": "它说了什么",
        "history": [{"role": "user", "content": "最新的会议讲了什么"}],
    }
    response = client_with_fakes.post("/knowledge/query", json=payload)

    assert response.status_code == 200
    assert retriever.calls == [("它说了什么", "最新的会议讲了什么")]


def test_briefing_retrieval_uses_direct_evidence_builder(client_with_fakes):
    app.state.retriever = BriefingRetriever()
    builder = DirectBuilder()
    app.state.context_builder = builder
    payload = {
        "requestId": str(uuid.uuid4()), "sessionId": str(uuid.uuid4()),
        "query": "最新的音频内容是什么", "history": [],
    }
    response = client_with_fakes.post("/knowledge/query", json=payload)

    assert response.status_code == 200
    assert len(builder.calls) == 1
    assert '"temporal_briefing"' in response.text
```

(若 `test_api.py` 未导入 `uuid`/`app`,在文件头补 `import uuid`。)

- [ ] **Step 2: 运行确认失败**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/test_answering.py tests/test_api.py -v -k "date_grounding or fuses_last_user or briefing_retrieval"
```

预期:FAIL。

- [ ] **Step 3: 修改提示词**

`KnowledgeAgent/agent/answering.py` 的 `SYSTEM_PROMPT` 改为:

```python
SYSTEM_PROMPT = """你是录音知识库问答助手。
只能依据 <evidence> 中的原始转写回答；会议纪要和对话历史不是事实来源。
每个事实性段落必须引用至少一个有效来源编号，例如 [S1]。
证据不足时只回答：知识库中没有足够依据。
每条来源标注了录音标题与录制日期；涉及最新、最近、最早或时间先后的问题，必须依据来源标注的日期回答，不得推测证据中未出现的日期。
不得用常识补充人物、数字、日期、责任人、决策或因果关系。"""
```

- [ ] **Step 4: 修改 main.py 装配**

4a. 版本号(`main.py:35`):

```python
SERVICE_VERSION = "1.1.0"
```

4b. `/knowledge/query` 端点中,替换检索调用与证据构建两段。

**实施修正(2026-08-29,代码审查后生效):时间词只在当前问题上检测,历史消息绝不参与时间词匹配(防止历史中的"最新"劫持非时间追问);上一条用户问题作为 `history_text` 参数传入 `retrieve`,仅在无时间词时拼进内容检索文本。** `HybridRetriever.retrieve` 签名相应变为 `retrieve(self, query: str, history_text: str = "")`,相关测试替身同步更新:

```python
                yield _event("retrieval_started", request_id, {})
                if await request.is_disconnected():
                    return
                history_text = ""
                for message in reversed(payload.history):
                    if message.role == "user" and message.content.strip():
                        history_text = message.content.strip()
                        break
                retrieval = await get_retriever().retrieve(payload.query, history_text)
                if await request.is_disconnected():
                    return
                builder = get_context_builder()
                evidence = (
                    builder.build_direct(retrieval.chunks)
                    if retrieval.briefing
                    else builder.build(retrieval.chunks)
                )
```

(`sources` 事件及后续逻辑不变;`EvidenceSource` 新字段经 `model_dump(mode="json")` 自动进入事件。)

- [ ] **Step 5: 运行全量 Python 测试**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/ -v
```

预期:全部 PASS。`test_api.py` 中既有 `FakeContextBuilder` 只有 `build`,因 `briefing` 默认 False 不会触发 `build_direct`,无需改动;若有其他用例失败,按失败信息修复(只允许改测试期望或假对象,不允许改产品代码语义)。

- [ ] **Step 6: 提交**

```bash
git add KnowledgeAgent/agent/answering.py KnowledgeAgent/agent/main.py KnowledgeAgent/tests/test_answering.py KnowledgeAgent/tests/test_api.py
git commit -m "feat(rag): ground temporal answers with dated evidence and fused retrieval text"
```

---

### Task 6: Swift 版本门与来源胶囊日期

**Files:**
- Modify: `AIRecording/Services/KnowledgeServiceManager.swift:18`
- Modify: `AIRecording/Views/KnowledgeSourceChipsView.swift`
- Test: `Tests/AIRecordingTests/KnowledgeSourceChipFormatterTests.swift`(新建)

- [ ] **Step 1: 写失败测试**

新建 `Tests/AIRecordingTests/KnowledgeSourceChipFormatterTests.swift`:

```swift
import XCTest
@testable import AIRecording

final class KnowledgeSourceChipFormatterTests: XCTestCase {
    func testDateTextFormatsLocalCalendarDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 29
        components.hour = 12
        let date = Calendar.current.date(from: components)

        XCTAssertEqual(KnowledgeSourceChipFormatter.dateText(date), "2026/08/29")
    }

    func testDateTextIsEmptyForNilDate() {
        XCTAssertEqual(KnowledgeSourceChipFormatter.dateText(nil), "")
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
swift test --filter KnowledgeSourceChipFormatterTests 2>&1 | tail -5
```

预期:FAIL,找不到 `KnowledgeSourceChipFormatter`。

- [ ] **Step 3: 实现格式化器与视图改动**

3a. 在 `AIRecording/Views/KnowledgeSourceChipsView.swift` 的 `KnowledgeSourceNavigation` 定义之后新增:

```swift
enum KnowledgeSourceChipFormatter {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        return dateFormatter.string(from: date)
    }
}
```

3b. `KnowledgeSourceChip` 中新增状态并在标题中拼接。`@State private var title = "录音"` 之后加:

```swift
    @State private var dateText = ""
```

按钮文案改为:

```swift
                Text("[\(source.sourceId ?? "S?")] \(title)\(dateSuffix) · \(Formatters.formatDuration(source.startTime))")
```

并在 struct 内加计算属性:

```swift
    private var dateSuffix: String {
        dateText.isEmpty ? "" : " · \(dateText)"
    }
```

`loadRecordingTitle()` 成功分支 `title = recording.displayTitle` 之后加:

```swift
        dateText = KnowledgeSourceChipFormatter.dateText(recording.createdAt)
```

录音不存在分支(`guard let recording ... else`)内加:

```swift
            dateText = ""
```

- [ ] **Step 4: 递增版本门**

`AIRecording/Services/KnowledgeServiceManager.swift:18` 改为:

```swift
    nonisolated static let expectedServiceVersion = "1.1.0"
```

- [ ] **Step 5: 运行 Swift 测试并修复版本钉住**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -10
```

预期:若 `KnowledgeBaseViewModelTests.swift`(4 处)与 `KnowledgeClientTests.swift`(成功路径假 health)有硬编码 `serviceVersion: "1.0.0"` 的用例失败,把这些字面量改为 `KnowledgeServiceManager.expectedServiceVersion`(只改成功路径;若存在"拒绝旧版本"的负向用例,保留其字面量)。改完重跑至全绿。

- [ ] **Step 6: 运行格式化器测试并提交**

```bash
swift test --filter KnowledgeSourceChipFormatterTests 2>&1 | tail -3
git add AIRecording/Services/KnowledgeServiceManager.swift AIRecording/Views/KnowledgeSourceChipsView.swift Tests/AIRecordingTests/KnowledgeSourceChipFormatterTests.swift Tests/AIRecordingTests/KnowledgeBaseViewModelTests.swift Tests/AIRecordingTests/KnowledgeClientTests.swift
git commit -m "feat(rag): show recording dates on source chips and bump service gate"
```

---

### Task 7: 全量回归与手工验收

**Files:** 无新改动;只验证。

- [ ] **Step 1: Python 全量**

```bash
cd KnowledgeAgent && .venv/bin/python -m pytest tests/ -q
```

预期:全部 PASS,无 skip 异常。

- [ ] **Step 2: Swift 全量**

```bash
cd .. && swift test 2>&1 | tail -5
```

预期:全部 PASS。

- [ ] **Step 3: 手工端到端验收(真实 Key,由用户配合)**

```bash
swift run
```

按顺序验收(spec §8):

1. 知识库问"最新的音频内容是什么" → 回答的是日期最新一场录音的内容,来源胶囊显示"标题 · yyyy/MM/dd";
2. 问"最近讲了什么" → 回答覆盖最近 3 场;
3. 问"最早的会议说了什么" → 返回最早一场;
4. 问普通问题(如"预算是谁负责的") → 行为与改造前一致;
5. 设置页移除语义服务 Key 后再问"最新的音频内容是什么" → 仍可回答(路径 B 不依赖向量);
6. 同一天录两场,问"最新" → 取创建时间较晚的那场。

任何一条不满足,回到对应 Task 修复后重跑本步骤。

- [ ] **Step 4: 清理与状态确认**

```bash
git status --short && git log --oneline -8
```

预期:工作树干净,六个 feat/test 提交按序存在。临时产物(pytest 缓存等)已在 `.gitignore` 内,不额外删除。
