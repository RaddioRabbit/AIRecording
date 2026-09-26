import asyncio
import time
from datetime import datetime, timezone

import numpy as np
import pytest

from agent.chunker import SegmentChunker
from agent.ingestion import RecordingIngestionService, content_hash, summary_hash
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore


class FakeEmbedder:
    def __init__(self, result):
        self.result = result
        self.calls = []

    async def embed_documents(self, texts):
        self.calls.append(texts)
        return [self.result[index] if index < len(self.result) else self.result[-1] for index in range(len(texts))]


class BlockingEmbedder:
    def __init__(self):
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.calls = []

    async def embed_documents(self, texts):
        self.calls.append(texts)
        if len(self.calls) == 1:
            self.started.set()
            await self.release.wait()
        return [np.array([1.0, 0.0])]


def make_request(content="content-a", summary="summary-a", markdown="# Decision\nAlice owns launch"):
    return RecordingUpsertRequest(
        recordingId="rec-1", title="Meeting", recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc),
        contentHash=content, summaryHash=summary, indexVersion=1, summaryMarkdown=markdown,
        segments=[
            TranscriptSegment(id="seg-2", sequence=2, startTime=1, endTime=2, text="Next action is review."),
            TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="Alice owns launch."),
        ],
    )


def test_unchanged_skips_chunking_embeddings_and_returns_zero_counts(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    embedder = FakeEmbedder([np.array([1.0, 0.0])])
    service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))
    request = make_request()
    asyncio.run(service.upsert(request))
    result = asyncio.run(service.upsert(request))

    assert result.status == "unchanged"
    assert result.generationChunks == result.retrievalChunks == result.summaryChunks == result.embeddedChunks == 0
    assert len(embedder.calls) == 1


def test_summary_only_update_embeds_only_new_route_without_reembedding_raw_chunks(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    embedder = FakeEmbedder([np.array([1.0, 0.0])])
    service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))
    asyncio.run(service.upsert(make_request()))
    retrieval_before = {
        chunk.id: (chunk.content, chunk.parent_id, chunk.embedding, chunk.embedding_dimension)
        for chunk in store.chunks_for_recording("rec-1")
        if chunk.role == "retrieval"
    }

    result = asyncio.run(service.upsert(make_request(summary="summary-b", markdown="# Updated\nBob owns review")))

    assert result.status == "indexed"
    assert result.summaryChunks == 2
    assert result.embeddedChunks == 0
    assert len(embedder.calls) == 2
    assert embedder.calls[-1] == ["# Updated", "Bob owns review"]
    retrieval_after = {
        chunk.id: (chunk.content, chunk.parent_id, chunk.embedding, chunk.embedding_dimension)
        for chunk in store.chunks_for_recording("rec-1")
        if chunk.role == "retrieval"
    }
    assert retrieval_after == retrieval_before
    routes = [chunk.content for chunk in store.chunks_for_recording("rec-1") if chunk.role == "summary_route"]
    assert routes == ["# Updated", "Bob owns review"]
    assert all(
        chunk.embedding is not None
        for chunk in store.chunks_for_recording("rec-1")
        if chunk.role == "summary_route"
    )


def test_summary_only_missing_route_vectors_degrade_and_enqueue_retry(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    embedder = FakeEmbedder([np.array([1.0, 0.0])])
    service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))
    asyncio.run(service.upsert(make_request()))
    raw_before = [
        (chunk.id, chunk.content, chunk.parent_id, chunk.embedding)
        for chunk in store.chunks_for_recording("rec-1")
        if chunk.role == "retrieval"
    ]
    embedder.result = [None]

    result = asyncio.run(service.upsert(make_request(summary="summary-b", markdown="# Updated\nBob owns review")))

    assert result.status == "degraded"
    assert result.embeddedChunks == 0
    assert store.status().pending_jobs == 2
    assert [
        (chunk.id, chunk.content, chunk.parent_id, chunk.embedding)
        for chunk in store.chunks_for_recording("rec-1")
        if chunk.role == "retrieval"
    ] == raw_before


def test_full_index_embedded_count_excludes_summary_route_vectors(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    embedder = FakeEmbedder([np.array([1.0, 0.0])])
    service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))

    result = asyncio.run(service.upsert(make_request()))

    assert result.embeddedChunks == result.retrievalChunks == 1
    assert all(
        chunk.embedding is not None
        for chunk in store.chunks_for_recording("rec-1")
        if chunk.role == "summary_route"
    )


def test_missing_embeddings_persist_chunks_enqueue_job_and_degrade(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    embedder = FakeEmbedder([None])
    service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))

    result = asyncio.run(service.upsert(make_request()))

    assert result.status == "degraded"
    assert result.embeddedChunks == 0
    assert store.list_missing_embedding_chunks()
    assert store.status().pending_jobs == 3


def test_initial_embedding_failure_starts_first_backoff_attempt(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    service = RecordingIngestionService(store, FakeEmbedder([None]), SegmentChunker(retrieval_size=100))
    before = time.time()

    asyncio.run(service.upsert(make_request()))

    rows = store.connection.execute(
        "SELECT attempts, error_code, next_retry_at FROM sync_jobs ORDER BY id"
    ).fetchall()
    assert rows
    assert all(row["attempts"] == 1 and row["error_code"] == "EMBEDDING_UNAVAILABLE" for row in rows)
    assert all(before + 5 <= row["next_retry_at"] <= time.time() + 5 for row in rows)
    assert store.claim_due_embedding_chunks(now=before) == []


def test_concurrent_retry_passes_claim_each_embedding_once(tmp_path):
    class SlowEmbedder:
        def __init__(self):
            self.calls = 0

        async def embed_documents(self, texts):
            self.calls += 1
            await asyncio.sleep(0.02)
            return [np.array([1.0, 0.0]) for _ in texts]

    async def run():
        store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        # Use the normal ingestion path to create real missing-vector jobs.
        initial = RecordingIngestionService(store, FakeEmbedder([None]), SegmentChunker(retrieval_size=100))
        await initial.upsert(make_request())
        store.connection.execute("UPDATE sync_jobs SET next_retry_at = 0")
        store.connection.commit()
        embedder = SlowEmbedder()
        service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))

        first, second = await asyncio.gather(service.retry_missing_embeddings(), service.retry_missing_embeddings())

        assert sorted((first, second)) == [0, 3]
        assert embedder.calls == 1
        assert store.status().pending_jobs == 0

    asyncio.run(run())


def test_cancelled_retry_releases_only_its_claims_for_immediate_restart(tmp_path):
    class BlockingEmbedder:
        def __init__(self):
            self.started = asyncio.Event()

        async def embed_documents(self, texts):
            self.started.set()
            await asyncio.Event().wait()

    class SuccessfulEmbedder:
        async def embed_documents(self, texts):
            return [np.array([1.0, 0.0]) for _ in texts]

    async def run():
        store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        initial = RecordingIngestionService(store, FakeEmbedder([None]), SegmentChunker(retrieval_size=100))
        await initial.upsert(make_request())
        store.connection.execute("UPDATE sync_jobs SET next_retry_at = 0")
        store.connection.commit()

        blocking = BlockingEmbedder()
        interrupted = RecordingIngestionService(store, blocking, SegmentChunker(retrieval_size=100))
        task = asyncio.create_task(interrupted.retry_missing_embeddings())
        await blocking.started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        resumed = RecordingIngestionService(store, SuccessfulEmbedder(), SegmentChunker(retrieval_size=100))
        assert await resumed.retry_missing_embeddings() == 3
        assert store.status().pending_jobs == 0

    asyncio.run(run())


def test_delete_delegates_to_store(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    service = RecordingIngestionService(store, FakeEmbedder([np.array([1.0])]), SegmentChunker())
    asyncio.run(service.upsert(make_request()))

    service.delete("rec-1")

    assert store.get_document_hashes("rec-1") is None


def test_hash_helpers_sort_segments_and_strip_outer_markdown_code_fence():
    request = make_request()
    reordered = request.model_copy(update={"segments": list(reversed(request.segments))})

    assert content_hash(request.segments) == content_hash(reordered.segments)
    assert summary_hash("```markdown\n# Decision\nAlice owns launch\n```") == summary_hash(
        "# Decision\nAlice owns launch"
    )


def test_later_concurrent_upsert_cannot_be_replaced_by_stale_embedding_result(tmp_path):
    async def run_race():
        store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        embedder = BlockingEmbedder()
        service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))
        v1 = make_request(content="content-v1", summary="summary-v1")
        v2 = make_request(content="content-v2", summary="summary-v2")

        first = asyncio.create_task(service.upsert(v1))
        await embedder.started.wait()
        second = asyncio.create_task(service.upsert(v2))
        await asyncio.sleep(0)
        embedder.release.set()
        await asyncio.gather(first, second)

        assert store.get_document_hashes("rec-1") == ("content-v2", "summary-v2", 1)

    asyncio.run(run_race())


def test_sync_delete_prevents_inflight_upsert_from_restoring_recording(tmp_path):
    async def run_race():
        store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        embedder = BlockingEmbedder()
        service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))

        upsert = asyncio.create_task(service.upsert(make_request()))
        await embedder.started.wait()
        service.delete("rec-1")
        embedder.release.set()
        await upsert

        assert store.get_document_hashes("rec-1") is None

    asyncio.run(run_race())


def test_delete_blocks_a_stale_upsert_that_was_queued_before_embedding_completed(tmp_path):
    async def run_race():
        store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        embedder = BlockingEmbedder()
        service = RecordingIngestionService(store, embedder, SegmentChunker(retrieval_size=100))

        first = asyncio.create_task(service.upsert(make_request(content="content-v1", summary="summary-v1")))
        await embedder.started.wait()
        service.delete("rec-1")
        queued = asyncio.create_task(service.upsert(make_request(content="content-v2", summary="summary-v2")))
        embedder.release.set()
        await asyncio.gather(first, queued)

        assert store.get_document_hashes("rec-1") is None

    asyncio.run(run_race())


@pytest.mark.parametrize("vector", [np.array([]), np.array([0.0]), np.array([np.nan]), np.array([np.inf])])
def test_invalid_provider_embeddings_report_degraded_and_queue_retry(tmp_path, vector):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    service = RecordingIngestionService(store, FakeEmbedder([vector]), SegmentChunker(retrieval_size=100))

    result = asyncio.run(service.upsert(make_request()))

    assert result.status == "degraded"
    assert result.embeddedChunks == 0
    assert store.list_missing_embedding_chunks()
