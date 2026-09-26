import asyncio
from datetime import datetime, timezone

import numpy as np

from agent.chunker import KnowledgeChunk
from agent.retrieval import HybridRetriever, reciprocal_rank_fusion
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore


class FakeEmbedding:
    def __init__(self, vector=np.array([1.0, 0.0])):
        self.vector = vector
        self.queries = []

    async def embed_query(self, query):
        self.queries.append(query)
        return self.vector


class FakeReranker:
    def __init__(self, result=None, fails=False):
        self.result = result
        self.fails = fails
        self.calls = []

    async def rerank(self, query, chunks, top_k):
        self.calls.append((query, chunks, top_k))
        if self.fails:
            raise RuntimeError("unavailable")
        return list(chunks if self.result is None else self.result)


def _request(recording_id):
    return RecordingUpsertRequest(
        recordingId=recording_id, title=recording_id,
        recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc), contentHash=recording_id,
        summaryHash=recording_id, indexVersion=1, summaryMarkdown="summary",
        segments=[TranscriptSegment(id=f"{recording_id}-segment", sequence=1, startTime=0, endTime=1, text="launch")],
    )


def _chunks(recording_id, count=1, summary="launch owner"):
    parent = KnowledgeChunk(f"{recording_id}-parent", "generation", "parent", 0, None, (), 0, 1, None, None)
    children = [
        KnowledgeChunk(f"{recording_id}-child-{index}", "retrieval", f"launch item {index}", index,
                       parent.id, (), 0, 1, None, None)
        for index in range(count)
    ]
    route = KnowledgeChunk(f"{recording_id}-route", "summary_route", summary, 0, None, (), None, None, None, None)
    return (parent, *children, route)


def _store(tmp_path, recordings=("rec-1",), child_count=1):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    for recording_id in recordings:
        chunks = _chunks(recording_id, child_count, "launch owner")
        embeddings = {chunk.id: np.array([1.0, 0.0]) for chunk in chunks if chunk.role == "retrieval"}
        store.replace_recording(_request(recording_id), chunks, embeddings)
    return store


def test_summary_route_never_becomes_evidence(tmp_path):
    store = _store(tmp_path)
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), FakeReranker()).retrieve("launch"))

    assert result.chunks
    assert all(chunk.role == "retrieval" for chunk in result.chunks)
    assert "rec-1" in result.routed_recording_ids


def test_semantic_summary_route_scopes_raw_evidence_when_fts_has_no_match(tmp_path, monkeypatch):
    store = _store(tmp_path)
    route = next(chunk for chunk in store.chunks_for_recording("rec-1") if chunk.role == "summary_route")
    store.connection.execute(
        "UPDATE chunks SET embedding = ?, embedding_dimension = ? WHERE id = ?",
        (np.array([1.0, 0.0], dtype=np.float32).tobytes(), 2, route.id),
    )
    store.connection.commit()
    search_vector = store.search_vector

    def summary_then_constrained_raw(vector, roles, limit, recording_ids=()):
        if roles == ("retrieval",) and not recording_ids:
            return []
        return search_vector(vector, roles, limit, recording_ids)

    monkeypatch.setattr(store, "search_vector", summary_then_constrained_raw)

    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("unmatched"))

    assert store.search_fts("unmatched", ("retrieval", "summary_route"), 40) == []
    assert result.routed_recording_ids == ("rec-1",)
    assert result.chunks
    assert all(chunk.role == "retrieval" for chunk in result.chunks)


def test_rrf_is_rank_based_and_deduplicates():
    fused = reciprocal_rank_fusion([["a", "b"], ["b", "c"]], k=60)

    assert fused[0].item_id == "b"
    assert len({item.item_id for item in fused}) == 3


def test_fts_only_and_vector_only_strategies(tmp_path):
    store = _store(tmp_path)
    fts_only = asyncio.run(HybridRetriever(store, FakeEmbedding(None), None).retrieve("launch"))
    vector_only = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("unmatched"))

    assert fts_only.strategy == "fts_only"
    assert fts_only.reranked is False
    assert vector_only.strategy == "vector_only"


def test_rerank_failure_falls_back_to_rrf_order(tmp_path):
    store = _store(tmp_path, child_count=2)
    reranker = FakeReranker(fails=True)
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), reranker).retrieve("launch"))

    assert result.reranked is False
    assert len(result.chunks) == 2


def test_route_uses_top_three_recordings_and_retrieval_caps(tmp_path, monkeypatch):
    store = _store(tmp_path, recordings=("rec-1", "rec-2", "rec-3", "rec-4"), child_count=45)
    calls = []
    vector_search = store.search_vector
    fts_search = store.search_fts

    def record_vector(*args, **kwargs):
        calls.append(("vector", args[2], args[3] if len(args) > 3 else ()))
        return vector_search(*args, **kwargs)

    def record_fts(*args, **kwargs):
        calls.append(("fts", args[2], args[3] if len(args) > 3 else ()))
        return fts_search(*args, **kwargs)

    monkeypatch.setattr(store, "search_vector", record_vector)
    monkeypatch.setattr(store, "search_fts", record_fts)
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("launch"))

    assert len(result.routed_recording_ids) == 3
    assert all(limit in (3, 40) for _, limit, _ in calls)
    assert any(recording_ids for _, _, recording_ids in calls)
    assert len(result.chunks) == 10


def test_store_search_excludes_mismatched_vector_dimensions_and_respects_roles(tmp_path):
    store = _store(tmp_path)

    assert store.search_vector(np.array([1.0, 0.0, 0.0]), ("retrieval",), 40) == []
    assert store.search_fts("launch", ("summary_route",), 40)[0].chunk.role == "summary_route"


def test_overlapping_retrievals_keep_their_own_rerank_status(tmp_path):
    class QueryReranker:
        async def rerank(self, query, chunks, top_k):
            if query == "fails":
                await asyncio.sleep(0)
                raise RuntimeError("unavailable")
            await asyncio.sleep(0.01)
            return chunks

    async def run():
        retriever = HybridRetriever(_store(tmp_path), FakeEmbedding(), QueryReranker())
        success, failure = await asyncio.gather(retriever.retrieve("launch"), retriever.retrieve("fails"))
        assert success.reranked is True
        assert failure.reranked is False

    asyncio.run(run())


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


def test_history_expansion_extends_content_search_but_not_temporal_detection(tmp_path):
    store = _budget_store(tmp_path)
    fts_calls = []
    fts_search = store.search_fts

    def record_fts(query, roles, limit, recording_ids=()):
        fts_calls.append(recording_ids)
        return fts_search(query, roles, limit, recording_ids)

    store.search_fts = record_fts
    embedding = FakeEmbedding()
    result = asyncio.run(
        HybridRetriever(store, embedding, None).retrieve("预算是谁负责的", "最新的会议讲了什么")
    )

    assert result.briefing is False
    assert embedding.queries == ["预算是谁负责的\n最新的会议讲了什么"]
    assert fts_calls and all(ids == () for ids in fts_calls)


def test_temporal_query_with_history_still_briefs_latest(tmp_path):
    store = _budget_store(tmp_path)
    result = asyncio.run(HybridRetriever(store, FakeEmbedding(), None).retrieve("最新的会议讲了什么", "再来一遍"))

    assert result.briefing is True
