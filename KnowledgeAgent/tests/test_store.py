from datetime import datetime, timedelta, timezone

import numpy as np
import pytest

from agent.chunker import KnowledgeChunk
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore


def request(content_hash="content", summary_hash="summary", summary="# Summary"):
    return RecordingUpsertRequest(
        recordingId="rec-1", title="Meeting", recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc),
        contentHash=content_hash, summaryHash=summary_hash, indexVersion=1,
        summaryMarkdown=summary,
        segments=[TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="hello")],
    )


def chunks(label="old"):
    return (
        KnowledgeChunk("parent-" + label, "generation", "parent " + label, 0, None,
                       ("seg-1",), 0.0, 1.0, None, None),
        KnowledgeChunk("child-" + label, "retrieval", "child " + label, 0, "parent-" + label,
                       ("seg-1",), 0.0, 1.0, None, None),
        KnowledgeChunk("summary-" + label, "summary_route", "summary " + label, 0, None,
                       (), None, None, None, None),
    )


def test_store_creates_fts_for_retrieval_and_summary_only(tmp_path):
    store = KnowledgeStore(tmp_path / "nested" / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child-old": np.array([3.0, 4.0])})

    tables = {row[0] for row in store.connection.execute("SELECT name FROM sqlite_master")}
    indexed = store.connection.execute(
        "SELECT chunk_id FROM chunk_fts ORDER BY chunk_id"
    ).fetchall()

    assert "chunk_fts" in tables
    assert [row[0] for row in indexed] == ["child-old", "summary-old"]
    stored = {chunk.id: chunk for chunk in store.chunks_for_recording("rec-1")}
    assert stored["child-old"].embedding_dimension == 2
    assert np.allclose(np.frombuffer(stored["child-old"].embedding, dtype=np.float32), [0.6, 0.8])
    assert (tmp_path / "nested").stat().st_mode & 0o777 == 0o700
    assert (tmp_path / "nested" / "knowledge.sqlite").stat().st_mode & 0o777 == 0o600


def test_replace_rolls_back_and_keeps_old_enabled_rows(tmp_path, monkeypatch):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child-old": np.array([1.0])})

    original = store._insert_chunks

    def fail_after_insert(*args, **kwargs):
        original(*args, **kwargs)
        raise RuntimeError("inject failure")

    monkeypatch.setattr(store, "_insert_chunks", fail_after_insert)
    with pytest.raises(RuntimeError):
        store.replace_recording(request("new", "summary"), chunks("new"), {"child-new": np.array([1.0])})

    assert store.get_document_hashes("rec-1") == ("content", "summary", 1)
    assert {chunk.id for chunk in store.chunks_for_recording("rec-1")} == {
        "parent-old", "child-old", "summary-old"
    }


def test_delete_cascades_chunks_fts_and_jobs(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child-old": None})
    assert store.list_missing_embedding_chunks()

    store.delete_recording("rec-1")

    assert store.get_document_hashes("rec-1") is None
    assert store.chunks_for_recording("rec-1") == []
    assert store.connection.execute("SELECT count(*) FROM chunk_fts").fetchone()[0] == 0
    assert store.status().pending_jobs == 0


def test_delete_increments_a_durable_recording_version(tmp_path):
    path = tmp_path / "knowledge.sqlite"
    store = KnowledgeStore(path)

    assert store.recording_version("rec-1") == 0
    store.delete_recording("rec-1")

    assert KnowledgeStore(path).recording_version("rec-1") == 1


def test_delete_creates_a_durable_recording_tombstone(tmp_path):
    path = tmp_path / "knowledge.sqlite"
    store = KnowledgeStore(path)
    store.delete_recording("rec-1")

    assert KnowledgeStore(path).is_recording_deleted("rec-1") is True


def test_direct_document_delete_cascades_to_chunks(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child-old": np.array([1.0])})
    document_id = store._current_document_id("rec-1")

    store.connection.execute("DELETE FROM documents WHERE id = ?", (document_id,))
    store.connection.commit()

    assert store.chunks_for_recording("rec-1") == []


@pytest.mark.parametrize("vector", [np.array([]), np.array([0.0, 0.0]), np.array([np.nan]), np.array([np.inf])])
def test_invalid_embedding_is_stored_as_missing_and_enqueued(tmp_path, vector):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child-old": vector})

    child = next(chunk for chunk in store.chunks_for_recording("rec-1") if chunk.id == "child-old")
    assert child.embedding is None
    assert child.embedding_dimension is None
    assert [chunk.id for chunk in store.list_missing_embedding_chunks()] == ["child-old"]


def test_recorded_at_is_persisted_in_utc(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    request_with_offset = request().model_copy(
        update={"recordedAt": datetime(2026, 8, 12, 8, tzinfo=timezone(timedelta(hours=8)))}
    )
    store.replace_recording(request_with_offset, chunks(), {"child-old": np.array([1.0])})

    recorded_at = store.connection.execute("SELECT recorded_at FROM documents").fetchone()[0]
    assert recorded_at == "2026-08-12T00:00:00+00:00"


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


def test_documents_meta_returns_local_calendar_date(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    # 12:00 UTC 在 UTC±11 时区内的本地日历日期都是同一天,断言跨时区稳定。
    _dated_parents(store, "rec-a", datetime(2026, 8, 20, 12, 0, tzinfo=timezone.utc), 1)

    meta = store.documents_meta(("rec-a",))

    assert meta["rec-a"][1] == "2026-08-20"
