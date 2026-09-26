"""Build bounded, source-addressable evidence from transcript retrieval hits."""

from __future__ import annotations

from collections.abc import Sequence

from agent.schema import BuiltEvidence, EvidenceSource
from agent.store import KnowledgeStore, StoredChunk


class EvidenceContextBuilder:
    def __init__(self, store: KnowledgeStore, max_parents: int = 6, max_chars: int = 12_000) -> None:
        self.store = store
        self.max_parents = max(0, max_parents)
        self.max_chars = max(0, max_chars)

    def build(self, child_hits: Sequence[StoredChunk]) -> BuiltEvidence:
        """Map ranked retrieval children to their first-seen generation parents.

        A parent is all-or-nothing: leaving it out is safer than weakening a
        source marker by truncating it.  Summary chunks are deliberately
        ignored even if a caller accidentally provides one.
        """
        children_by_parent: dict[str, list[StoredChunk]] = {}
        for child in child_hits:
            if child.role != "retrieval" or child.parent_id is None:
                continue
            children = children_by_parent.setdefault(child.parent_id, [])
            if all(existing.id != child.id for existing in children):
                children.append(child)

        parents = self.store.generation_parents(tuple(children_by_parent))
        ordered = [
            (parents[parent_id], children)
            for parent_id, children in children_by_parent.items()
            if parents.get(parent_id) is not None and parents[parent_id].role == "generation"
        ]
        return self._build_from_pairs(ordered)

    def build_direct(self, parents: Sequence[StoredChunk]) -> BuiltEvidence:
        """Temporal briefing path: parents become evidence in the given order."""
        return self._build_from_pairs([(parent, ()) for parent in parents])

    def _build_from_pairs(
        self, pairs: Sequence[tuple[StoredChunk, Sequence[StoredChunk]]]
    ) -> BuiltEvidence:
        metas = self.store.documents_meta(tuple({parent.recording_id for parent, _ in pairs}))
        context_parts: list[str] = []
        sources: list[EvidenceSource] = []
        total_chars = 0
        for parent, children in pairs:
            if len(sources) == self.max_parents:
                break
            title, recorded_at = metas.get(parent.recording_id, ("", ""))
            source = EvidenceSource(
                sourceId=f"S{len(sources) + 1}",
                recordingId=parent.recording_id,
                segmentIds=list(parent.segment_ids),
                startTime=0.0 if parent.start_time is None else parent.start_time,
                endTime=0.0 if parent.end_time is None else parent.end_time,
                speakerName=parent.speaker_name,
                title=title,
                recordedAt=recorded_at,
            )
            block = self._render_parent(source, parent, children)
            if total_chars + len(block) > self.max_chars:
                break
            context_parts.append(block)
            sources.append(source)
            total_chars += len(block)
        return BuiltEvidence(contextText="".join(context_parts), sources=sources)

    @staticmethod
    def _render_parent(source: EvidenceSource, parent: StoredChunk, children: Sequence[StoredChunk]) -> str:
        child_locations = "\n".join(
            "- {id} | segments: {segments} | time: {start}-{end}".format(
                id=child.id,
                segments=",".join(child.segment_ids),
                start="" if child.start_time is None else child.start_time,
                end="" if child.end_time is None else child.end_time,
            )
            for child in children
        )
        speaker = source.speakerName or ""
        return (
            f"[{source.sourceId}]\n"
            f"recording_id: {source.recordingId}\n"
            f"title: {source.title}\n"
            f"recorded_at: {source.recordedAt}\n"
            f"segment_ids: {','.join(source.segmentIds)}\n"
            f"time: {source.startTime}-{source.endTime}\n"
            f"speaker: {speaker}\n"
            f"matched_children:\n{child_locations}\n\n"
            f"{parent.content}\n\n"
        )
