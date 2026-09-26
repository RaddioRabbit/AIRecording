"""Shared API schema base classes."""

from datetime import datetime
import math
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class EvidenceSource(StrictModel):
    sourceId: str
    recordingId: str
    segmentIds: list[str]
    startTime: float
    endTime: float
    speakerName: str | None = None
    title: str = ""
    recordedAt: str = ""


class BuiltEvidence(StrictModel):
    contextText: str
    sources: list[EvidenceSource]


class KnowledgeHistoryMessage(StrictModel):
    role: Literal["user", "assistant"]
    content: str


class KnowledgeQueryRequest(StrictModel):
    requestId: UUID
    sessionId: UUID
    query: str = Field(min_length=1)
    history: list[KnowledgeHistoryMessage] = Field(max_length=6)

    @model_validator(mode="after")
    def validate_query(self) -> "KnowledgeQueryRequest":
        if not self.query.strip():
            raise ValueError("query must not be blank")
        return self


class KnowledgeStatusResponse(StrictModel):
    documents: int
    chunks: int
    pendingJobs: int
    failedJobs: int
    degraded: bool


class KnowledgeOperationResponse(StrictModel):
    status: Literal["ok", "indexed", "unchanged", "degraded"]
    affected: int = Field(ge=0, default=0)


class KnowledgeStreamEvent(StrictModel):
    event: Literal["retrieval_started", "sources", "answer_delta", "answer_completed", "error"]
    requestId: str
    data: dict[str, Any]


class KnowledgeAnswer(StrictModel):
    content: str
    sources: list[EvidenceSource]


class TranscriptSegment(StrictModel):
    id: str
    sequence: int
    startTime: float
    endTime: float
    speakerId: str | None = None
    speakerName: str | None = None
    text: str = Field(min_length=1)

    @model_validator(mode="after")
    def validate_content_and_times(self) -> "TranscriptSegment":
        if not self.text.strip():
            raise ValueError("text must not be blank")
        if not all(math.isfinite(value) and value >= 0 for value in (self.startTime, self.endTime)):
            raise ValueError("times must be finite and nonnegative")
        if self.endTime < self.startTime:
            raise ValueError("endTime must not precede startTime")
        return self


class RecordingUpsertRequest(StrictModel):
    recordingId: str
    title: str
    recordedAt: datetime
    contentHash: str
    summaryHash: str
    indexVersion: int
    summaryMarkdown: str | None = None
    segments: list[TranscriptSegment] = Field(min_length=1)

    @model_validator(mode="after")
    def validate_recording_and_segments(self) -> "RecordingUpsertRequest":
        if self.recordedAt.tzinfo is None or self.recordedAt.utcoffset() is None:
            raise ValueError("recordedAt must include a timezone")
        ids = [segment.id for segment in self.segments]
        sequences = [segment.sequence for segment in self.segments]
        if len(ids) != len(set(ids)):
            raise ValueError("segment ids must be unique")
        if len(sequences) != len(set(sequences)):
            raise ValueError("segment sequences must be unique")
        return self


class RecordingUpsertResponse(StrictModel):
    status: Literal["indexed", "unchanged", "degraded"]
    generationChunks: int
    retrievalChunks: int
    summaryChunks: int
    embeddedChunks: int
