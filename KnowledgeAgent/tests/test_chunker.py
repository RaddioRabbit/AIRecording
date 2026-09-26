from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from agent.chunker import SegmentChunker, chunk_summary
from agent.schema import RecordingUpsertRequest, TranscriptSegment


SEGMENTS = [
    TranscriptSegment(
        id="seg-2", sequence=2, startTime=2.0, endTime=4.0,
        speakerId="speaker-a", speakerName="Alice", text="第二段，继续讨论上线计划。",
    ),
    TranscriptSegment(
        id="seg-1", sequence=1, startTime=0.0, endTime=2.0,
        speakerId="speaker-a", speakerName="Alice", text="第一段。先确认负责人。",
    ),
]


def test_strict_ingestion_dtos_reject_unknown_and_empty_values():
    with pytest.raises(ValidationError):
        TranscriptSegment(
            id="seg", sequence=0, startTime=0, endTime=1, text="", extra="nope"
        )

    with pytest.raises(ValidationError):
        RecordingUpsertRequest(
            recordingId="rec", title="title", recordedAt=datetime.now(timezone.utc),
            contentHash="content", summaryHash="summary", indexVersion=1, segments=[],
        )


@pytest.mark.parametrize(
    "segment",
    [
        {"id": "seg", "sequence": 1, "startTime": 0, "endTime": 1, "text": "   "},
        {"id": "seg", "sequence": 1, "startTime": -1, "endTime": 1, "text": "text"},
        {"id": "seg", "sequence": 1, "startTime": 2, "endTime": 1, "text": "text"},
        {"id": "seg", "sequence": 1, "startTime": float("nan"), "endTime": 1, "text": "text"},
    ],
)
def test_transcript_segment_rejects_invalid_text_and_times(segment):
    with pytest.raises(ValidationError):
        TranscriptSegment(**segment)


def test_recording_request_rejects_naive_time_and_duplicate_segment_identity():
    segment = TranscriptSegment(id="seg-1", sequence=1, startTime=0, endTime=1, text="text")
    kwargs = dict(
        recordingId="rec", title="title", contentHash="content", summaryHash="summary", indexVersion=1,
    )

    with pytest.raises(ValidationError):
        RecordingUpsertRequest(recordedAt=datetime(2026, 8, 12), segments=[segment], **kwargs)
    with pytest.raises(ValidationError):
        RecordingUpsertRequest(
            recordedAt=datetime.now(timezone.utc),
            **kwargs,
            segments=[segment, segment.model_copy(update={"id": "seg-2"})],
        )
    with pytest.raises(ValidationError):
        RecordingUpsertRequest(
            recordedAt=datetime.now(timezone.utc),
            **kwargs,
            segments=[segment, segment.model_copy(update={"sequence": 2})],
        )


def test_recording_request_rejects_duplicate_sequences_in_either_input_order():
    first = TranscriptSegment(id="first", sequence=1, startTime=0, endTime=1, text="first")
    second = TranscriptSegment(id="second", sequence=1, startTime=1, endTime=2, text="second")
    base = dict(
        recordingId="rec", title="title", recordedAt=datetime.now(timezone.utc),
        contentHash="content", summaryHash="summary", indexVersion=1,
    )

    for segments in ([first, second], [second, first]):
        with pytest.raises(ValidationError):
            RecordingUpsertRequest(**base, segments=segments)


def test_dual_chunks_preserve_parent_substrings_times_and_segments():
    chunks = SegmentChunker(
        retrieval_size=12, retrieval_overlap=2, generation_size=30, generation_overlap=4
    ).chunk(SEGMENTS, recording_id="rec-1")

    assert chunks.generation
    assert chunks.retrieval
    assert [item.segment_ids for item in chunks.generation][0][0] == "seg-1"
    for child in chunks.retrieval:
        parent = next(item for item in chunks.generation if item.id == child.parent_id)
        assert child.content in parent.content
        assert parent.start_time <= child.start_time <= child.end_time <= parent.end_time
        assert child.segment_ids
        assert child.speaker_id == "speaker-a"
        assert child.speaker_name == "Alice"


def test_mixed_speaker_ids_clear_the_entire_speaker_identity():
    segments = [
        TranscriptSegment(
            id="seg-a", sequence=1, startTime=0, endTime=1,
            speakerId="a", speakerName="Same", text="First segment.",
        ),
        TranscriptSegment(
            id="seg-b", sequence=2, startTime=1, endTime=2,
            speakerId="b", speakerName="Same", text="Second segment.",
        ),
    ]

    chunk = SegmentChunker(generation_size=100, retrieval_size=100).chunk(
        segments, recording_id="rec-1"
    ).generation[0]

    assert chunk.speaker_id is None
    assert chunk.speaker_name is None


@pytest.mark.parametrize(
    ("speaker_id", "speaker_name"),
    [("speaker-a", None), (None, "Alice")],
)
def test_homogeneous_partial_speaker_identity_is_retained(speaker_id, speaker_name):
    segments = [
        TranscriptSegment(
            id="seg-a", sequence=1, startTime=0, endTime=1,
            speakerId=speaker_id, speakerName=speaker_name, text="First segment.",
        ),
        TranscriptSegment(
            id="seg-b", sequence=2, startTime=1, endTime=2,
            speakerId=speaker_id, speakerName=speaker_name, text="Second segment.",
        ),
    ]

    chunk = SegmentChunker(generation_size=100, retrieval_size=100).chunk(
        segments, recording_id="rec-1"
    ).generation[0]

    assert (chunk.speaker_id, chunk.speaker_name) == (speaker_id, speaker_name)


def test_summary_chunks_are_route_only_and_have_no_source_mapping():
    routes = chunk_summary("# 决策\n张伟负责上线。\n\n下一步安排。", recording_id="rec-1")

    assert routes
    assert {route.role for route in routes} == {"summary_route"}
    assert all(route.segment_ids == () for route in routes)
    assert all(route.start_time is None and route.end_time is None for route in routes)
    assert all(route.parent_id is None for route in routes)


def test_summary_chunks_split_heading_from_its_following_paragraph():
    routes = chunk_summary("# Heading\nparagraph", recording_id="rec-1")

    assert [route.content for route in routes] == ["# Heading", "paragraph"]
    assert all(route.role == "summary_route" for route in routes)
    assert all(route.segment_ids == () for route in routes)
    assert all(route.start_time is None and route.end_time is None for route in routes)
