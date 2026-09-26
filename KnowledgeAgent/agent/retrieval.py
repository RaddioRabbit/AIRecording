"""Hybrid retrieval over original transcript children only."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Protocol, Sequence

import numpy as np

from agent.store import KnowledgeStore, SearchHit, StoredChunk
from agent.temporal import BRIEFING_MAX_PARENTS, TemporalIntent, detect_intent, is_generic_query, strip_intent


class QueryEmbedder(Protocol):
    async def embed_query(self, text: str) -> np.ndarray | None: ...


class ChunkReranker(Protocol):
    async def rerank(self, query: str, chunks: list[StoredChunk], top_k: int) -> list[StoredChunk] | None: ...


@dataclass(frozen=True)
class FusedHit:
    item_id: str
    score: float
    chunk: StoredChunk | None = None


@dataclass(frozen=True)
class RetrievalResult:
    chunks: tuple[StoredChunk, ...]
    routed_recording_ids: tuple[str, ...]
    strategy: str
    reranked: bool
    briefing: bool = False


def reciprocal_rank_fusion(rankings: Sequence[Sequence[SearchHit | str]], k: int = 60) -> list[FusedHit]:
    """Fuse rankings by ordinal position, never by incomparable provider scores."""
    scored: dict[str, tuple[float, StoredChunk | None]] = {}
    for ranking in rankings:
        for rank, item in enumerate(ranking, start=1):
            if isinstance(item, SearchHit):
                item_id, chunk = item.chunk.id, item.chunk
            else:
                item_id, chunk = item, None
            previous_score, previous_chunk = scored.get(item_id, (0.0, chunk))
            scored[item_id] = (previous_score + 1.0 / (k + rank), previous_chunk or chunk)
    return [
        FusedHit(item_id, score, chunk)
        for item_id, (score, chunk) in sorted(scored.items(), key=lambda pair: (-pair[1][0], pair[0]))
    ]


class HybridRetriever:
    def __init__(self, store: KnowledgeStore, adapter: QueryEmbedder,
                 reranker: ChunkReranker | None = None) -> None:
        self.store = store
        self.adapter = adapter
        self.reranker = reranker

    async def retrieve(self, query: str, history_text: str = "") -> RetrievalResult:
        """Temporal intent is detected on the current question only; the last user
        history message expands content search for pronoun understanding (never for
        temporal detection, so a temporal history turn cannot hijack a neutral query)."""
        intent = detect_intent(query)
        if intent is not None:
            return await self._retrieve_temporal(query, intent)
        retrieval_text = f"{query}\n{history_text}" if history_text else query
        return await self._retrieve_content(retrieval_text)

    async def _retrieve_temporal(self, query: str, intent: TemporalIntent) -> RetrievalResult:
        targets = self.store.recording_ids_by_recency(intent.order, intent.limit)
        if not targets:
            return await self._retrieve_content(query)
        core = strip_intent(query, intent)
        if is_generic_query(core):
            per_recording = max(1, math.ceil(BRIEFING_MAX_PARENTS / len(targets)))
            parents = self.store.sample_generation_parents(targets, per_recording)
            return RetrievalResult(
                chunks=tuple(parents),
                routed_recording_ids=targets,
                strategy="temporal_briefing",
                reranked=False,
                briefing=True,
            )
        vector = await self.adapter.embed_query(core)
        raw_vector_hits = (
            self.store.search_vector(vector, ("retrieval",), 40, targets) if vector is not None else []
        )
        raw_fts_hits = self.store.search_fts(core, ("retrieval",), 40, targets)
        fused = reciprocal_rank_fusion([raw_vector_hits, raw_fts_hits], k=60)[:30]
        ranked, reranked = await self._rerank_or_fallback(core, fused, top_k=10)
        return RetrievalResult(
            chunks=tuple(ranked),
            routed_recording_ids=targets,
            strategy=self._strategy(raw_vector_hits, raw_fts_hits, (), ()),
            reranked=reranked,
        )

    async def _retrieve_content(self, query: str) -> RetrievalResult:
        vector = await self.adapter.embed_query(query)
        raw_vector_hits = self.store.search_vector(vector, ("retrieval",), 40) if vector is not None else []
        raw_fts_hits = self.store.search_fts(query, ("retrieval",), 40)
        route_hits = self._summary_route_hits(query, vector, limit=3)
        routed_ids = tuple(hit.chunk.recording_id for hit in route_hits)
        routed_vector_hits = (
            self.store.search_vector(vector, ("retrieval",), 40, routed_ids)
            if vector is not None and routed_ids else []
        )
        routed_fts_hits = self.store.search_fts(query, ("retrieval",), 40, routed_ids) if routed_ids else []
        fused = reciprocal_rank_fusion(
            [raw_vector_hits, raw_fts_hits, routed_vector_hits, routed_fts_hits], k=60
        )[:30]
        ranked, reranked = await self._rerank_or_fallback(query, fused, top_k=10)
        return RetrievalResult(
            chunks=tuple(ranked),
            routed_recording_ids=routed_ids,
            strategy=self._strategy(raw_vector_hits, raw_fts_hits, routed_vector_hits, routed_fts_hits),
            reranked=reranked,
        )

    def _summary_route_hits(self, query: str, vector: np.ndarray | None, limit: int) -> list[SearchHit]:
        vector_hits = self.store.search_vector(vector, ("summary_route",), 40) if vector is not None else []
        fts_hits = self.store.search_fts(query, ("summary_route",), 40)
        fused = reciprocal_rank_fusion([vector_hits, fts_hits], k=60)
        routed: list[SearchHit] = []
        seen_recordings: set[str] = set()
        for hit in fused:
            if hit.chunk is None or hit.chunk.recording_id in seen_recordings:
                continue
            seen_recordings.add(hit.chunk.recording_id)
            routed.append(SearchHit(hit.chunk, hit.score))
            if len(routed) == limit:
                break
        return routed

    async def _rerank_or_fallback(self, query: str, fused: Sequence[FusedHit], top_k: int) -> tuple[list[StoredChunk], bool]:
        candidates = [hit.chunk for hit in fused if hit.chunk is not None and hit.chunk.role == "retrieval"]
        fallback = candidates[:top_k]
        if self.reranker is None or not candidates:
            return fallback, False
        try:
            returned = await self.reranker.rerank(query, candidates, top_k)
        except Exception:
            return fallback, False
        if not returned:
            return fallback, False
        candidate_ids = {chunk.id for chunk in candidates}
        ranked: list[StoredChunk] = []
        seen: set[str] = set()
        for chunk in returned:
            if chunk.id not in candidate_ids or chunk.id in seen or chunk.role != "retrieval":
                continue
            seen.add(chunk.id)
            ranked.append(chunk)
            if len(ranked) == top_k:
                break
        if not ranked:
            return fallback, False
        return ranked, True

    @staticmethod
    def _strategy(raw_vector: Sequence[SearchHit], raw_fts: Sequence[SearchHit],
                  routed_vector: Sequence[SearchHit], routed_fts: Sequence[SearchHit]) -> str:
        has_vector = bool(raw_vector or routed_vector)
        has_fts = bool(raw_fts or routed_fts)
        if has_vector and has_fts:
            return "hybrid"
        if has_vector:
            return "vector_only"
        if has_fts:
            return "fts_only"
        return "empty"
