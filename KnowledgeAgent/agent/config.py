"""Configuration for the local knowledge service."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from agent.observability import log_event


_KNOWN_PROVIDERS = ("dashscope", "openai")


def _provider_from_environment(variable: str, invalid_event: str, invalid_code: str) -> str:
    raw = os.environ.get(variable, "").strip().lower()
    if not raw:
        return "dashscope"
    if raw not in _KNOWN_PROVIDERS:
        log_event(invalid_event, level="warning", error_code=invalid_code)
        return "dashscope"
    return raw


def _base_url_from_environment(variable: str) -> str | None:
    return os.environ.get(variable, "").strip() or None


def _embedding_dimension_from_environment() -> int | None:
    raw = os.environ.get("EMBEDDING_DIMENSION", "").strip()
    if not raw:
        return None
    try:
        parsed = int(raw)
    except ValueError:
        parsed = 0
    if parsed <= 0:
        log_event("embedding_dimension_invalid", level="warning", error_code="EMBEDDING_DIMENSION_INVALID")
        return None
    return parsed


@dataclass(frozen=True)
class KnowledgeConfig:
    db_path: Path
    host: str = "127.0.0.1"
    port: int = 8766
    embedding_model: str = "text-embedding-v4"
    embedding_dimension: int | None = None
    embedding_provider: str = "dashscope"
    embedding_base_url: str | None = None
    rerank_model: str = "gte-rerank-v2"
    rerank_provider: str = "dashscope"
    rerank_base_url: str | None = None
    retrieval_chunk_size: int = 250
    retrieval_chunk_overlap: int = 25
    generation_chunk_size: int = 1500
    generation_chunk_overlap: int = 150
    rrf_k: int = 60
    index_version: int = 1

    @classmethod
    def from_environment(cls) -> "KnowledgeConfig":
        return cls(
            db_path=Path(os.environ["KNOWLEDGE_DB_PATH"]),
            port=int(os.environ.get("PORT", "8766")),
            embedding_model=os.environ.get("EMBEDDING_MODEL", "text-embedding-v4"),
            embedding_dimension=_embedding_dimension_from_environment(),
            embedding_provider=_provider_from_environment(
                "EMBEDDING_PROVIDER", "embedding_provider_invalid", "EMBEDDING_PROVIDER_INVALID",
            ),
            embedding_base_url=_base_url_from_environment("EMBEDDING_BASE_URL"),
            rerank_model=os.environ.get("RERANK_MODEL", "gte-rerank-v2"),
            rerank_provider=_provider_from_environment(
                "RERANK_PROVIDER", "rerank_provider_invalid", "RERANK_PROVIDER_INVALID",
            ),
            rerank_base_url=_base_url_from_environment("RERANK_BASE_URL"),
        )
