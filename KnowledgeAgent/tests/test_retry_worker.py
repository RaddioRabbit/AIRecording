import asyncio
from types import SimpleNamespace

import numpy as np

from agent.chunker import KnowledgeChunk, SegmentChunker
from agent.ingestion import RecordingIngestionService
from agent.main import MaintenanceGate, _retry_worker
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore
from datetime import datetime, timezone


def test_worker_retries_due_embedding_job_without_endpoint(tmp_path, monkeypatch):
    class Embedder:
        def __init__(self):
            self.called = asyncio.Event()

        async def embed_documents(self, texts):
            self.called.set()
            return [np.array([1.0]) for _ in texts]

    async def run():
        store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        request = RecordingUpsertRequest(
            recordingId="rec-1", title="Meeting", recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc),
            contentHash="content", summaryHash="summary", indexVersion=1,
            segments=[TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="hello")],
        )
        chunks = (
            KnowledgeChunk("parent", "generation", "hello", 0, None, ("seg-1",), 0, 1, None, None),
            KnowledgeChunk("child", "retrieval", "hello", 0, "parent", ("seg-1",), 0, 1, None, None),
        )
        store.replace_recording(request, chunks, {"child": None})
        store.connection.execute("UPDATE sync_jobs SET next_retry_at = 0")
        store.connection.commit()
        embedder = Embedder()
        application = SimpleNamespace(state=SimpleNamespace(
            maintenance_gate=MaintenanceGate(),
            ingestion_service=RecordingIngestionService(store, embedder, SegmentChunker()),
        ))
        stop = asyncio.Event()
        worker = asyncio.create_task(_retry_worker(application, stop))
        await asyncio.wait_for(embedder.called.wait(), timeout=1)
        stop.set()
        await asyncio.wait_for(worker, timeout=1)
        assert store.status().pending_jobs == 0

    monkeypatch.setattr("agent.main.RETRY_INTERVAL_SECONDS", 0.01)
    asyncio.run(run())
