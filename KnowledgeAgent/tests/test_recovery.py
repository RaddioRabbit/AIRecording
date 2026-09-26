from datetime import datetime, timezone

import numpy as np
import pytest

from agent.chunker import KnowledgeChunk
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore, RETRY_DELAYS_SECONDS


def request():
    return RecordingUpsertRequest(
        recordingId="rec-1", title="Meeting", recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc),
        contentHash="content", summaryHash="summary", indexVersion=1,
        segments=[TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="hello")],
    )


def chunks():
    return (KnowledgeChunk("parent", "generation", "parent", 0, None, ("seg-1",), 0, 1, None, None),
            KnowledgeChunk("child", "retrieval", "child", 0, "parent", ("seg-1",), 0, 1, None, None))


def test_embedding_failures_use_fixed_backoff_and_only_missing_jobs(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child": None})
    now = 100.0
    store.connection.execute("UPDATE sync_jobs SET attempts = 0, next_retry_at = NULL")
    store.connection.commit()
    assert store.mark_embedding_failure("rec-1", "child", "UNAVAILABLE", now) == 1
    row = store.connection.execute("SELECT status, next_retry_at FROM sync_jobs").fetchone()
    assert tuple(row) == ("pending", now + RETRY_DELAYS_SECONDS[0])
    store.mark_embedding_failure("rec-1", "child", "UNAVAILABLE", now)
    store.mark_embedding_failure("rec-1", "child", "UNAVAILABLE", now)
    row = store.connection.execute("SELECT attempts, status, next_retry_at FROM sync_jobs").fetchone()
    assert tuple(row) == (3, "pending", now + RETRY_DELAYS_SECONDS[2])
    store.mark_embedding_failure("rec-1", "child", "UNAVAILABLE", now)
    row = store.connection.execute("SELECT attempts, status, next_retry_at FROM sync_jobs").fetchone()
    assert tuple(row) == (4, "failed", now + RETRY_DELAYS_SECONDS[2])
    assert store.retry_failed_jobs() == 1
    assert store.status().failed_jobs == 0


def test_expired_lease_is_recovered_for_a_new_single_claim(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child": None})
    store.connection.execute("UPDATE sync_jobs SET next_retry_at = 0")
    store.connection.commit()

    first = store.claim_due_embedding_chunks(now=10, lease_seconds=5)
    second = store.claim_due_embedding_chunks(now=16, lease_seconds=5)

    assert len(first) == len(second) == 1
    assert first[0].lease_id != second[0].lease_id


def test_reset_index_keeps_backup_and_restores_it_if_fresh_schema_fails(tmp_path, monkeypatch):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    store.replace_recording(request(), chunks(), {"child": np.array([1.0])})
    original_initialize = store.initialize
    calls = 0

    def fails_once():
        nonlocal calls
        calls += 1
        if calls == 1:
            raise RuntimeError("fresh schema failure")
        original_initialize()

    monkeypatch.setattr(store, "initialize", fails_once)
    with pytest.raises(RuntimeError, match="fresh schema failure"):
        store.reset_index()

    assert store.backup_path.exists()
    assert store.get_document_hashes("rec-1") == ("content", "summary", 1)
    assert store.path.stat().st_mode & 0o777 == 0o600
