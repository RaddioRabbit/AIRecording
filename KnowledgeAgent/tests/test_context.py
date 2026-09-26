from datetime import datetime, timezone

from agent.chunker import KnowledgeChunk
from agent.context import EvidenceContextBuilder
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore


def _request(recording_id: str) -> RecordingUpsertRequest:
    return RecordingUpsertRequest(
        recordingId=recording_id,
        title=recording_id,
        recordedAt=datetime(2026, 8, 12, tzinfo=timezone.utc),
        contentHash="content",
        summaryHash="summary",
        indexVersion=1,
        segments=[TranscriptSegment(id="seg-1", sequence=1, startTime=12.5, endTime=24.0, text="原始转写")],
    )


def _chunks(recording_id: str) -> tuple[KnowledgeChunk, ...]:
    parent_one = KnowledgeChunk(
        "parent-1", "generation", "父块一：张伟负责发布。", 0, None,
        ("seg-1", "seg-2"), 12.5, 42.0, "speaker-1", "张伟",
    )
    parent_two = KnowledgeChunk(
        "parent-2", "generation", "父块二：周五验收。", 1, None,
        ("seg-3",), 50.0, 60.0, None, None,
    )
    return (
        parent_one,
        KnowledgeChunk("child-1", "retrieval", "张伟负责", 0, parent_one.id, ("seg-1",), 12.5, 20.0, "speaker-1", "张伟"),
        KnowledgeChunk("child-2", "retrieval", "发布", 1, parent_one.id, ("seg-2",), 21.0, 42.0, "speaker-1", "张伟"),
        parent_two,
        KnowledgeChunk("child-3", "retrieval", "周五验收", 0, parent_two.id, ("seg-3",), 50.0, 60.0, None, None),
        KnowledgeChunk("route", "summary_route", "纪要仅用于路由", 0, None, (), None, None, None, None),
    )


def _store(tmp_path: object) -> tuple[KnowledgeStore, tuple[KnowledgeChunk, ...]]:
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    chunks = _chunks("rec-1")
    store.replace_recording(_request("rec-1"), chunks, {})
    return store, chunks


def test_context_maps_children_to_unique_parents_with_stable_sources(tmp_path):
    store, chunks = _store(tmp_path)

    built = EvidenceContextBuilder(store, max_parents=6, max_chars=12_000).build(
        [chunks[2], chunks[1], chunks[4], chunks[5]]
    )

    assert [source.sourceId for source in built.sources] == ["S1", "S2"]
    assert built.sources[0].recordingId == "rec-1"
    assert built.sources[0].segmentIds == ["seg-1", "seg-2"]
    assert built.sources[0].startTime == 12.5
    assert built.sources[0].speakerName == "张伟"
    assert "matched_children" in built.contextText
    assert "纪要仅用于路由" not in built.contextText
    assert len(built.contextText) <= 12_000


def test_context_keeps_child_rank_order_and_stops_before_parent_overflow(tmp_path):
    store, chunks = _store(tmp_path)
    first_parent_size = len("[S1]\nrecording_id: rec-1\nsegment_ids: seg-1,seg-2\ntime: 12.5-42.0\nspeaker: 张伟\nmatched_children:\n- child-1 | segments: seg-1 | time: 12.5-20.0\n\n父块一：张伟负责发布。\n\n")

    built = EvidenceContextBuilder(store, max_parents=1, max_chars=first_parent_size - 1).build([chunks[1], chunks[4]])

    assert built.sources == []
    assert built.contextText == ""


def _meta_store(tmp_path):
    store = KnowledgeStore(tmp_path / "knowledge.sqlite")
    request = RecordingUpsertRequest(
        recordingId="rec-1", title="八月产品周会",
        recordedAt=datetime(2026, 8, 20, 12, 0, tzinfo=timezone.utc),
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

