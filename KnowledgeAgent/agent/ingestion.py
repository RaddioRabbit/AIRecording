"""Idempotent recording ingestion orchestration."""

from __future__ import annotations

import hashlib
import json
import re
import asyncio
import time
from typing import Protocol

import numpy as np

from agent.chunker import KnowledgeChunk, SegmentChunker, chunk_summary
from agent.schema import RecordingUpsertRequest, RecordingUpsertResponse, TranscriptSegment
from agent.store import KnowledgeStore


class DocumentEmbedder(Protocol):
    async def embed_documents(self, texts: list[str]) -> list[np.ndarray | None]: ...


def content_hash(segments: list[TranscriptSegment]) -> str:
    payload = [
        {"id": segment.id, "sequence": segment.sequence, "startTime": segment.startTime,
         "endTime": segment.endTime, "speakerId": segment.speakerId, "text": segment.text}
        for segment in sorted(segments, key=lambda item: item.sequence)
    ]
    return hashlib.sha256(json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()


def _normalise_summary(markdown: str | None) -> str:
    text = (markdown or "").strip()
    match = re.fullmatch(r"```(?:markdown|md)?\s*\n?(.*?)\n?```", text, flags=re.DOTALL | re.IGNORECASE)
    return match.group(1).strip() if match else text


def summary_hash(markdown: str | None) -> str:
    return hashlib.sha256(_normalise_summary(markdown).encode()).hexdigest()


class RecordingIngestionService:
    def __init__(self, store: KnowledgeStore, embedder: DocumentEmbedder, chunker: SegmentChunker) -> None:
        self.store = store
        self.embedder = embedder
        self.chunker = chunker
        self._recording_locks: dict[str, asyncio.Lock] = {}

    async def upsert(self, request: RecordingUpsertRequest) -> RecordingUpsertResponse:
        lock = self._lock_for(request.recordingId)
        async with lock:
            return await self._upsert(request)

    def _lock_for(self, recording_id: str) -> asyncio.Lock:
        return self._recording_locks.setdefault(recording_id, asyncio.Lock())

    async def _upsert(self, request: RecordingUpsertRequest) -> RecordingUpsertResponse:
        if self.store.is_recording_deleted(request.recordingId):
            return RecordingUpsertResponse(
                status="unchanged", generationChunks=0, retrievalChunks=0, summaryChunks=0, embeddedChunks=0
            )
        recording_version = self.store.recording_version(request.recordingId)
        current = self.store.get_document_hashes(request.recordingId)
        if current == (request.contentHash, request.summaryHash, request.indexVersion):
            return RecordingUpsertResponse(
                status="unchanged", generationChunks=0, retrievalChunks=0, summaryChunks=0, embeddedChunks=0
            )

        summary = chunk_summary(_normalise_summary(request.summaryMarkdown), request.recordingId)
        if current and current[0] == request.contentHash and current[2] == request.indexVersion:
            summary_embeddings = await self.embedder.embed_documents([chunk.content for chunk in summary])
            if self.store.recording_version(request.recordingId) != recording_version or self.store.is_recording_deleted(
                request.recordingId
            ):
                return RecordingUpsertResponse(
                    status="unchanged", generationChunks=0, retrievalChunks=0, summaryChunks=0, embeddedChunks=0
                )
            summary_vectors = {
                chunk.id: summary_embeddings[index] if index < len(summary_embeddings) else None
                for index, chunk in enumerate(summary)
            }
            self.store.replace_summary(request, summary, summary_vectors)
            indexed_chunks = [
                chunk for chunk in self.store.chunks_for_recording(request.recordingId)
                if chunk.role in ("retrieval", "summary_route")
            ]
            degraded = any(chunk.embedding is None for chunk in indexed_chunks)
            return RecordingUpsertResponse(
                status="degraded" if degraded else "indexed", generationChunks=0, retrievalChunks=0,
                summaryChunks=len(summary), embeddedChunks=0,
            )

        dual = self.chunker.chunk(request.segments, request.recordingId)
        retrieval = dual.retrieval
        indexable = (*retrieval, *summary)
        returned = await self.embedder.embed_documents([chunk.content for chunk in indexable])
        if self.store.recording_version(request.recordingId) != recording_version:
            return RecordingUpsertResponse(
                status="unchanged", generationChunks=0, retrievalChunks=0, summaryChunks=0, embeddedChunks=0
            )
        embeddings = {chunk.id: returned[index] if index < len(returned) else None for index, chunk in enumerate(indexable)}
        self.store.replace_recording(request, (*dual.generation, *retrieval, *summary), embeddings)
        persisted_indexable = [
            chunk for chunk in self.store.chunks_for_recording(request.recordingId)
            if chunk.role in ("retrieval", "summary_route")
        ]
        embedded = sum(chunk.embedding is not None for chunk in persisted_indexable)
        return RecordingUpsertResponse(
            status="indexed" if embedded == len(persisted_indexable) else "degraded",
            generationChunks=len(dual.generation), retrievalChunks=len(retrieval), summaryChunks=len(summary),
            embeddedChunks=sum(
                chunk.embedding is not None for chunk in persisted_indexable if chunk.role == "retrieval"
            ),
        )

    def delete(self, recording_id: str) -> None:
        self.store.delete_recording(recording_id)

    def retry_failed(self) -> int:
        """Make exhausted provider jobs eligible for the next local retry pass."""
        return self.store.retry_failed_jobs()

    async def retry_missing_embeddings(self, limit: int = 100) -> int:
        """Retry only provider vector work; source records remain Swift-owned."""
        chunks = self.store.claim_due_embedding_chunks(limit=limit, now=time.time())
        if not chunks:
            return 0
        try:
            vectors = await self.embedder.embed_documents([chunk.content for chunk in chunks])
        except asyncio.CancelledError:
            for chunk in chunks:
                self.store.release_embedding_claim(chunk.recording_id, chunk.id, chunk.lease_id or "")
            raise
        except Exception:
            vectors = [None] * len(chunks)
        completed = 0
        for index, chunk in enumerate(chunks):
            vector = vectors[index] if index < len(vectors) else None
            if vector is not None and self.store.complete_embedding(
                chunk.recording_id, chunk.id, vector, chunk.lease_id
            ):
                completed += 1
            else:
                self.store.mark_claimed_embedding_failure(
                    chunk.recording_id, chunk.id, chunk.lease_id or "", "EMBEDDING_UNAVAILABLE", time.time()
                )
        return completed
