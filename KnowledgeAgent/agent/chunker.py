"""Deterministic, segment-aware transcript chunking."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from typing import Literal, Sequence

from agent.schema import TranscriptSegment


ChunkRole = Literal["generation", "retrieval", "summary_route"]
_BOUNDARIES = (re.compile(r"\n\n"), re.compile(r"[。；？！]\s*"), re.compile(r"\n"), re.compile(r"[、，]\s*"))


@dataclass(frozen=True)
class KnowledgeChunk:
    id: str
    role: ChunkRole
    content: str
    chunk_index: int
    parent_id: str | None
    segment_ids: tuple[str, ...]
    start_time: float | None
    end_time: float | None
    speaker_id: str | None
    speaker_name: str | None


@dataclass(frozen=True)
class DualChunks:
    generation: tuple[KnowledgeChunk, ...]
    retrieval: tuple[KnowledgeChunk, ...]


@dataclass(frozen=True)
class _SourceRange:
    start: int
    end: int
    segment: TranscriptSegment


def _chunk_id(recording_id: str, role: ChunkRole, parent_index: int, chunk_index: int) -> str:
    raw = f"{recording_id}\x1f{role}\x1f{parent_index}\x1f{chunk_index}".encode()
    return hashlib.sha256(raw).hexdigest()


def _split_ranges(text: str, size: int, overlap: int) -> list[tuple[int, int]]:
    if not text:
        return []
    ranges: list[tuple[int, int]] = []
    start = 0
    while start < len(text):
        target = min(len(text), start + size)
        end = target
        if target < len(text):
            for pattern in _BOUNDARIES:
                matches = list(pattern.finditer(text, start, target))
                if matches:
                    end = matches[-1].end()
                    break
        if end <= start:
            end = min(len(text), start + size)
        ranges.append((start, end))
        if end == len(text):
            break
        next_start = max(start + 1, end - overlap)
        while next_start < len(text) and text[next_start].isspace():
            next_start += 1
        start = next_start
    return ranges


def _mapped_metadata(source_ranges: Sequence[_SourceRange], start: int, end: int) -> tuple[
    tuple[str, ...], float | None, float | None, str | None, str | None
]:
    mapped = [source.segment for source in source_ranges if source.start < end and source.end > start]
    if not mapped:
        return (), None, None, None, None
    ids = tuple(segment.id for segment in mapped)
    speaker_identity = {(segment.speakerId, segment.speakerName) for segment in mapped}
    speaker_id, speaker_name = _common_speaker_identity(speaker_identity)
    return (
        ids,
        min(segment.startTime for segment in mapped),
        max(segment.endTime for segment in mapped),
        speaker_id,
        speaker_name,
    )


def _common_speaker_identity(identities: set[tuple[str | None, str | None]]) -> tuple[str | None, str | None]:
    if len(identities) != 1:
        return None, None
    speaker_id, speaker_name = next(iter(identities))
    return (speaker_id, speaker_name) if speaker_id or speaker_name else (None, None)


class SegmentChunker:
    def __init__(self, retrieval_size: int = 250, retrieval_overlap: int = 25,
                 generation_size: int = 1500, generation_overlap: int = 150) -> None:
        self.retrieval_size = retrieval_size
        self.retrieval_overlap = retrieval_overlap
        self.generation_size = generation_size
        self.generation_overlap = generation_overlap

    def chunk(self, segments: Sequence[TranscriptSegment], recording_id: str) -> DualChunks:
        text_parts: list[str] = []
        source_ranges: list[_SourceRange] = []
        position = 0
        for segment in sorted(segments, key=lambda item: item.sequence):
            if not segment.text.strip():
                continue
            if text_parts:
                text_parts.append("\n")
                position += 1
            text_parts.append(segment.text)
            source_ranges.append(_SourceRange(position, position + len(segment.text), segment))
            position += len(segment.text)
        text = "".join(text_parts)
        parents: list[KnowledgeChunk] = []
        children: list[KnowledgeChunk] = []
        for parent_index, (start, end) in enumerate(_split_ranges(text, self.generation_size, self.generation_overlap)):
            metadata = _mapped_metadata(source_ranges, start, end)
            parent_id = _chunk_id(recording_id, "generation", parent_index, 0)
            parents.append(KnowledgeChunk(parent_id, "generation", text[start:end], parent_index, None, *metadata))
            parent_text = text[start:end]
            for child_index, (child_start, child_end) in enumerate(
                _split_ranges(parent_text, self.retrieval_size, self.retrieval_overlap)
            ):
                children.append(KnowledgeChunk(
                    _chunk_id(recording_id, "retrieval", parent_index, child_index), "retrieval",
                    parent_text[child_start:child_end], child_index, parent_id,
                    *_mapped_metadata(source_ranges, start + child_start, start + child_end),
                ))
        return DualChunks(tuple(parents), tuple(children))


def chunk_summary(markdown: str | None, recording_id: str) -> tuple[KnowledgeChunk, ...]:
    if not markdown or not markdown.strip():
        return ()
    blocks: list[str] = []
    paragraph: list[str] = []
    for line in markdown.splitlines():
        if re.match(r"^\s{0,3}#{1,6}\s+", line):
            if paragraph:
                blocks.append("\n".join(paragraph).strip())
                paragraph = []
            blocks.append(line.strip())
        elif line.strip():
            paragraph.append(line)
        elif paragraph:
            blocks.append("\n".join(paragraph).strip())
            paragraph = []
    if paragraph:
        blocks.append("\n".join(paragraph).strip())
    return tuple(
        KnowledgeChunk(_chunk_id(recording_id, "summary_route", 0, index), "summary_route", block,
                       index, None, (), None, None, None, None)
        for index, block in enumerate(blocks)
    )
