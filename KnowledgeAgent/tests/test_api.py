import json
import threading
import uuid
from datetime import datetime, timezone

from fastapi.testclient import TestClient
import numpy as np
import pytest

from agent.chunker import KnowledgeChunk, SegmentChunker
from agent.context import BuiltEvidence, EvidenceSource
from agent.embedding import DashScopeAdapter
from agent.ingestion import RecordingIngestionService
from agent.retrieval import RetrievalResult
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore
import agent.main as main_module
from main import API_VERSION, SERVICE_VERSION, app


QUERY = {
    "requestId": "a2d5ba79-7518-4f7c-9b73-f109304e9e29",
    "sessionId": "b252d20e-903a-4f78-b4ee-c2eb930dfd8f",
    "query": "谁负责上线？", "history": [],
}


class FakeIngestion:
    def __init__(self):
        self.upserts = []
        self.deleted = []

    async def upsert(self, payload):
        self.upserts.append(payload)
        from agent.schema import RecordingUpsertResponse
        return RecordingUpsertResponse(
            status="indexed", generationChunks=1, retrievalChunks=1, summaryChunks=0, embeddedChunks=1
        )

    def delete(self, recording_id):
        self.deleted.append(recording_id)

    def retry_failed(self):
        return 2

    async def retry_missing_embeddings(self):
        return 3


class FakeRetriever:
    async def retrieve(self, query, history_text=""):
        return RetrievalResult(chunks=(), routed_recording_ids=(), strategy="fts_only", reranked=False)


class FakeContextBuilder:
    def build(self, chunks):
        return BuiltEvidence(
            contextText="[S1] 原始转写", sources=[EvidenceSource(
                sourceId="S1", recordingId="rec-1", segmentIds=["seg-1"], startTime=0, endTime=1
            )],
        )


class FakeAnswer:
    async def answer(self, query, evidence, history):
        from agent.schema import KnowledgeAnswer
        return KnowledgeAnswer(content="张伟负责上线。[S1]", sources=evidence.sources)


@pytest.fixture
def client_with_fakes(tmp_path):
    app.state.store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    app.state.ingestion_service = FakeIngestion()
    app.state.retriever = FakeRetriever()
    app.state.context_builder = FakeContextBuilder()
    app.state.answer_service = FakeAnswer()
    with TestClient(app) as client:
        yield client


def recording_payload(recording_id="rec-1"):
    return {
        "recordingId": recording_id, "title": "会议", "recordedAt": "2026-08-12T00:00:00Z",
        "contentHash": "content", "summaryHash": "summary", "indexVersion": 1,
        "segments": [{"id": "seg-1", "sequence": 1, "startTime": 0, "endTime": 1, "text": "张伟负责"}],
    }


def parse_sse(lines):
    events = []
    event = None
    for line in lines:
        if not line:
            if event is not None:
                events.append(event)
            event = None
        elif line.startswith("event: "):
            event = {"event": line[7:]}
        elif line.startswith("data: ") and event is not None:
            event["data"] = json.loads(line[6:])
    if event is not None:
        events.append(event)
    return events


def test_query_sse_contract(client_with_fakes):
    with client_with_fakes.stream("POST", "/knowledge/query", json=QUERY) as response:
        events = parse_sse(response.iter_lines())

    assert response.headers["content-type"].startswith("text/event-stream")
    assert [event["event"] for event in events] == [
        "retrieval_started", "sources", "answer_delta", "answer_completed"
    ]
    assert events[-1]["data"]["data"]["content"] == "张伟负责上线。[S1]"
    assert all(event["data"]["requestId"] == QUERY["requestId"] for event in events)


def test_status_upsert_delete_and_retry_are_stable_and_idempotent(client_with_fakes):
    assert client_with_fakes.get("/knowledge/status").json() == {
        "documents": 0, "chunks": 0, "pendingJobs": 0, "failedJobs": 0, "degraded": False,
    }
    first = client_with_fakes.put("/knowledge/recordings/rec-1", json=recording_payload())
    second = client_with_fakes.put("/knowledge/recordings/rec-1", json=recording_payload())

    assert first.status_code == second.status_code == 200
    assert client_with_fakes.delete("/knowledge/recordings/rec-1").json() == {"status": "ok", "affected": 1}
    assert client_with_fakes.delete("/knowledge/recordings/rec-1").status_code == 200
    assert client_with_fakes.post("/knowledge/retry-failed").json() == {"status": "ok", "affected": 3}


def test_retry_endpoint_requeues_and_completes_missing_embedding(client_with_fakes):
    class Embedder:
        async def embed_documents(self, texts):
            return [np.array([1.0, 0.0]) for _ in texts]

    store = app.state.store
    request = RecordingUpsertRequest(
        recordingId="rec-1", title="Meeting", recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc),
        contentHash="content", summaryHash="summary", indexVersion=1,
        segments=[TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="张伟负责")],
    )
    chunks = (
        KnowledgeChunk("parent", "generation", "张伟负责", 0, None, ("seg-1",), 0, 1, None, None),
        KnowledgeChunk("child", "retrieval", "张伟负责", 0, "parent", ("seg-1",), 0, 1, None, None),
    )
    store.replace_recording(request, chunks, {"child": None})
    for _ in range(3):
        store.mark_embedding_failure("rec-1", "child", "UNAVAILABLE", 0)
    app.state.ingestion_service = RecordingIngestionService(store, Embedder(), SegmentChunker())

    response = client_with_fakes.post("/knowledge/retry-failed")

    assert response.json() == {"status": "ok", "affected": 1}
    assert store.status().pending_jobs == store.status().failed_jobs == 0
    child = next(chunk for chunk in store.chunks_for_recording("rec-1") if chunk.id == "child")
    assert child.embedding is not None


def test_api_rejects_unknown_fields_mismatched_path_and_blank_segments(client_with_fakes):
    payload = recording_payload()
    payload["unexpected"] = "no"
    rejected = client_with_fakes.put("/knowledge/recordings/rec-1", json=payload)
    assert rejected.json() == {"detail": "INVALID_REQUEST"}
    assert client_with_fakes.put("/knowledge/recordings/other", json=recording_payload()).json() == {
        "detail": "RECORDING_ID_MISMATCH"
    }
    blank = recording_payload()
    blank["segments"][0]["text"] = "  "
    assert client_with_fakes.put("/knowledge/recordings/rec-1", json=blank).json() == {"detail": "INVALID_REQUEST"}


def test_validation_never_reflects_secret_shaped_request_or_transcript(client_with_fakes, capsys):
    submitted_secret = "sk-secret-request-and-transcript"
    payload = {**QUERY, "requestId": submitted_secret, "query": submitted_secret}

    response = client_with_fakes.post("/knowledge/query", json=payload)

    assert response.json() == {"detail": "INVALID_REQUEST"}
    assert submitted_secret not in response.text
    assert submitted_secret not in capsys.readouterr().out


def test_reset_waits_for_active_upsert(client_with_fakes, monkeypatch):
    started = threading.Event()
    release = threading.Event()
    reset_started = threading.Event()

    class BlockingIngestion(FakeIngestion):
        async def upsert(self, payload):
            started.set()
            await __import__("asyncio").to_thread(release.wait)
            return await super().upsert(payload)

    app.state.ingestion_service = BlockingIngestion()
    original_reset = app.state.store.reset_index

    def record_reset():
        reset_started.set()
        original_reset()

    monkeypatch.setattr(app.state.store, "reset_index", record_reset)
    upsert_thread = threading.Thread(
        target=lambda: client_with_fakes.put("/knowledge/recordings/rec-1", json=recording_payload())
    )
    reset_thread = threading.Thread(target=lambda: client_with_fakes.post("/knowledge/reset-index"))
    upsert_thread.start()
    assert started.wait(timeout=2)
    reset_thread.start()
    assert not reset_started.wait(timeout=0.1)
    release.set()
    upsert_thread.join(timeout=2)
    reset_thread.join(timeout=2)
    assert not upsert_thread.is_alive()
    assert not reset_thread.is_alive()
    assert reset_started.is_set()


def test_reset_index_and_service_version(client_with_fakes):
    assert client_with_fakes.post("/knowledge/reset-index").json() == {"status": "ok", "affected": 0}
    assert app.state.store.backup_path.exists()
    assert app.state.store.path.stat().st_mode & 0o777 == 0o600
    assert client_with_fakes.get("/health").json() == {
        "status": "ok", "apiVersion": API_VERSION, "serviceVersion": SERVICE_VERSION, "indexVersion": 1,
    }


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


class RecordingRetriever:
    def __init__(self):
        self.calls = []

    async def retrieve(self, query, history_text=""):
        self.calls.append((query, history_text))
        return RetrievalResult(chunks=(), routed_recording_ids=(), strategy="fts_only", reranked=False)


class BriefingRetriever:
    async def retrieve(self, query, history_text=""):
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
