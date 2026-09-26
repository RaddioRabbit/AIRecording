"""Cross-process contract coverage for the sanitized two-recording fixture."""

from __future__ import annotations

import json
import asyncio
from datetime import datetime
from pathlib import Path

import numpy as np

from agent.answering import REFUSAL_TEXT, StrictAnswerService
from agent.chunker import SegmentChunker
from agent.context import EvidenceContextBuilder
from agent.ingestion import RecordingIngestionService, content_hash, summary_hash
from agent.retrieval import HybridRetriever
from agent.schema import RecordingUpsertRequest, TranscriptSegment
from agent.store import KnowledgeStore


FIXTURE = Path(__file__).parent / "fixtures" / "two_recordings.json"


def test_shared_two_recordings_fixture_is_available():
    payload = json.loads(FIXTURE.read_text(encoding="utf-8"))

    assert len(payload["recordings"]) == 2
    assert payload["query"] == "最终由谁负责上线协调？"
    assert len(payload["unrelatedQueries"]) >= 2
    assert payload["expectedAnswerAfterDeletion"]


class FakeAdapter:
    def __init__(self, supported_query):
        self.supported_query = supported_query

    async def embed_documents(self, texts):
        return [self._document_vector(text) for text in texts]

    async def embed_query(self, text):
        return np.array([1.0, 1.0], dtype=np.float32) if text == self.supported_query else None

    async def rerank(self, query, chunks, top_k):
        return list(chunks)[:top_k]

    @staticmethod
    def _document_vector(text):
        if "本次发布" in text:
            return np.array([1.0, 0.0], dtype=np.float32)
        if "确认" in text or "继续" in text:
            return np.array([0.0, 1.0], dtype=np.float32)
        return None


class FixtureLLM:
    def __init__(self, answer, expected_records):
        self.answer = answer
        self.expected_records = expected_records

    async def complete_stream(self, messages):
        evidence = messages[-1]["content"]
        for index, recording in enumerate(self.expected_records, start=1):
            assert f"[S{index}]" in evidence
            assert f"recording_id: {recording['recordingId']}" in evidence
            for segment in recording["segments"]:
                assert segment["id"] in evidence
        yield self.answer


class RAGHarness:
    def __init__(self, tmp_path, fixture):
        self.fixture = fixture
        self.store = KnowledgeStore(tmp_path / "knowledge.sqlite")
        self.adapter = FakeAdapter(fixture["query"])
        self.ingestion = RecordingIngestionService(self.store, self.adapter, SegmentChunker())

    async def ingest_fixture(self):
        for recording in self.fixture["recordings"]:
            segments = [TranscriptSegment(**segment) for segment in recording["segments"]]
            request = RecordingUpsertRequest(
                recordingId=recording["recordingId"], title=recording["title"],
                recordedAt=datetime.fromisoformat(recording["recordedAt"].replace("Z", "+00:00")),
                contentHash=content_hash(segments), summaryHash=summary_hash(recording["summaryMarkdown"]),
                indexVersion=1, summaryMarkdown=recording["summaryMarkdown"], segments=segments,
            )
            await self.ingestion.upsert(request)

    async def query(self, query):
        retrieval = await HybridRetriever(self.store, self.adapter, self.adapter).retrieve(query)
        evidence = EvidenceContextBuilder(self.store).build(retrieval.chunks)
        present_recording_ids = {source.recordingId for source in evidence.sources}
        all_records = self.fixture["recordings"]
        remaining_record = all_records[1]
        if present_recording_ids == {recording["recordingId"] for recording in all_records}:
            answer, expected_records = self.fixture["expectedAnswer"], all_records
        elif present_recording_ids == {remaining_record["recordingId"]}:
            answer, expected_records = self.fixture["expectedAnswerAfterDeletion"], [remaining_record]
        else:
            answer, expected_records = REFUSAL_TEXT, []
        return await StrictAnswerService(FixtureLLM(answer, expected_records)).answer(query, evidence, [])

    def close(self):
        self.store.close()


def test_two_recordings_answer_has_clickable_raw_sources_and_survives_deletion(tmp_path):
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    harness = RAGHarness(tmp_path, fixture)
    try:
        asyncio.run(harness.ingest_fixture())
        answer = asyncio.run(harness.query(fixture["query"]))

        assert answer.content == fixture["expectedAnswer"]
        assert {source.recordingId for source in answer.sources} == {
            recording["recordingId"] for recording in fixture["recordings"]
        }
        assert all(source.segmentIds and source.startTime >= 0 for source in answer.sources)

        harness.ingestion.delete(fixture["recordings"][0]["recordingId"])
        remaining = asyncio.run(harness.query(fixture["query"]))
        assert remaining.content == fixture["expectedAnswerAfterDeletion"]
        assert {source.recordingId for source in remaining.sources} == {fixture["recordings"][1]["recordingId"]}
    finally:
        harness.close()


def test_unrelated_questions_refuse_without_evidence(tmp_path):
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    harness = RAGHarness(tmp_path, fixture)
    try:
        asyncio.run(harness.ingest_fixture())
        for query in fixture["unrelatedQueries"]:
            answer = asyncio.run(harness.query(query))
            assert answer.content == REFUSAL_TEXT
            assert answer.sources == []
    finally:
        harness.close()
