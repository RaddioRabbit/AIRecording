"""DashScope embedding and reranking adapter with local-safe fallbacks."""

from __future__ import annotations

import asyncio
import os
from typing import Any, Protocol

import numpy as np

from agent.store import StoredChunk


class EmbeddingRerankAdapter(Protocol):
    async def embed_query(self, text: str) -> np.ndarray | None: ...
    async def embed_documents(self, texts: list[str]) -> list[np.ndarray | None]: ...
    async def rerank(self, query: str, chunks: list[StoredChunk], top_k: int) -> list[StoredChunk] | None: ...


class DashScopeAdapter:
    """Small boundary around the DashScope SDK.

    An absent key is deliberately a normal condition: callers can continue with
    FTS retrieval and synchronise missing vector jobs later.
    """

    def __init__(self, *, api_key: str | None = None, embedding_model: str | None = None,
                 embedding_dimension: int | None = None, rerank_model: str | None = None,
                 text_embedding: Any | None = None,
                 text_rerank: Any | None = None, timeout_seconds: float = 10.0,
                 embedding_provider: str | None = None, rerank_provider: str | None = None,
                 embedding_base_url: str | None = None, rerank_base_url: str | None = None,
                 openai_embeddings: Any | None = None, rerank_http: Any | None = None) -> None:
        self._api_key = api_key
        self.embedding_model = embedding_model or os.getenv("EMBEDDING_MODEL", "text-embedding-v4")
        self.embedding_dimension = embedding_dimension if (embedding_dimension or 0) > 0 else None
        self.rerank_model = rerank_model or os.getenv("RERANK_MODEL", "gte-rerank-v2")
        self.embedding_provider = self._resolved_provider(embedding_provider, "EMBEDDING_PROVIDER")
        self.rerank_provider = self._resolved_provider(rerank_provider, "RERANK_PROVIDER")
        self.embedding_base_url = embedding_base_url if embedding_base_url is not None else _optional_env("EMBEDDING_BASE_URL")
        self.rerank_base_url = rerank_base_url if rerank_base_url is not None else _optional_env("RERANK_BASE_URL")
        self._text_embedding = text_embedding
        self._text_rerank = text_rerank
        self._openai_embeddings = openai_embeddings
        self._rerank_http = rerank_http
        self.timeout_seconds = max(0.001, timeout_seconds)

    @staticmethod
    def _resolved_provider(value: str | None, variable: str) -> str:
        raw = value if value is not None else os.getenv(variable, "dashscope")
        return "openai" if (raw or "").strip().lower() == "openai" else "dashscope"

    def _embedding_key(self) -> str | None:
        if self.embedding_provider == "openai":
            return os.getenv("EMBEDDING_API_KEY") or None
        # The per-service key is authoritative; DASHSCOPE_API_KEY stays only as a
        # legacy fallback so re-saved keys take effect without touching the old account.
        return os.getenv("EMBEDDING_API_KEY") or self._api_key or os.getenv("DASHSCOPE_API_KEY") or None

    def _rerank_key(self) -> str | None:
        if self.rerank_provider == "openai":
            return os.getenv("RERANK_API_KEY") or None
        return os.getenv("RERANK_API_KEY") or self._api_key or os.getenv("DASHSCOPE_API_KEY") or None

    async def embed_query(self, text: str) -> np.ndarray | None:
        key = self._embedding_key()
        if not key or not text.strip():
            return None
        vectors = await self._embed([text], "query", key)
        return vectors[0] if vectors else None

    async def embed_documents(self, texts: list[str]) -> list[np.ndarray | None]:
        if not texts:
            return []
        key = self._embedding_key()
        if not key:
            return [None] * len(texts)
        result: list[np.ndarray | None] = []
        for start in range(0, len(texts), 25):
            result.extend(await self._embed(texts[start:start + 25], "document", key))
        return result

    async def _embed(self, texts: list[str], text_type: str, key: str) -> list[np.ndarray | None]:
        if self.embedding_provider == "openai":
            return await self._embed_openai(texts, key)
        kwargs: dict[str, Any] = {
            "model": self.embedding_model,
            "input": texts,
            "api_key": key,
            "text_type": text_type,
            "request_timeout": self.timeout_seconds,
        }
        if self.embedding_dimension is not None:
            kwargs["dimension"] = self.embedding_dimension
        try:
            response = await asyncio.wait_for(
                asyncio.to_thread(self._embedding_client().call, **kwargs),
                timeout=self.timeout_seconds,
            )
            raw = _field(_field(response, "output"), "embeddings")
            if not isinstance(raw, list) or len(raw) != len(texts):
                return [None] * len(texts)
            return [_normalised_vector(_field(item, "embedding")) for item in raw]
        except Exception:
            # Provider failures must have a deterministic, private fallback.
            return [None] * len(texts)

    async def _embed_openai(self, texts: list[str], key: str | None) -> list[np.ndarray | None]:
        kwargs: dict[str, Any] = {"model": self.embedding_model, "input": texts}
        if self.embedding_dimension is not None:
            kwargs["dimensions"] = self.embedding_dimension
        embeddings = self._openai_embeddings
        owns_client = embeddings is None
        if owns_client:
            from openai import AsyncOpenAI
            client = AsyncOpenAI(api_key=key, base_url=self.embedding_base_url or None)
            embeddings = client.embeddings
        try:
            response = await asyncio.wait_for(embeddings.create(**kwargs), timeout=self.timeout_seconds)
            raw = _field(response, "data")
            if not isinstance(raw, list) or len(raw) != len(texts):
                return [None] * len(texts)
            if sorted(_field(item, "index") for item in raw) != list(range(len(texts))):
                # A mis-indexed batch would silently corrupt stored vectors.
                return [None] * len(texts)
            aligned = sorted(raw, key=lambda item: _field(item, "index"))
            return [_normalised_vector(_field(item, "embedding")) for item in aligned]
        except Exception:
            # Provider failures must have a deterministic, private fallback.
            return [None] * len(texts)
        finally:
            if owns_client:
                await client.close()

    async def rerank(self, query: str, chunks: list[StoredChunk], top_k: int) -> list[StoredChunk] | None:
        key = self._rerank_key()
        if not key or not chunks or top_k <= 0:
            return None
        if self.rerank_provider == "openai":
            return await self._rerank_openai(query, chunks, top_k, key)
        try:
            response = await asyncio.wait_for(
                asyncio.to_thread(
                    self._rerank_client().call,
                    model=self.rerank_model,
                    query=query,
                    documents=[chunk.content for chunk in chunks],
                    top_n=min(top_k, len(chunks)),
                    return_documents=False,
                    api_key=key,
                    request_timeout=self.timeout_seconds,
                ),
                timeout=self.timeout_seconds,
            )
            return _ranked_chunks(_field(_field(response, "output"), "results"), chunks, top_k)
        except Exception:
            return None

    async def _rerank_openai(self, query: str, chunks: list[StoredChunk], top_k: int,
                             key: str | None) -> list[StoredChunk] | None:
        base_url = self.rerank_base_url
        if not base_url:
            return None
        url = base_url.rstrip("/") + "/rerank"
        payload: dict[str, Any] = {
            "model": self.rerank_model,
            "query": query,
            "documents": [chunk.content for chunk in chunks],
            "top_n": min(top_k, len(chunks)),
        }
        client = self._rerank_http
        owns_client = client is None
        if owns_client:
            import httpx
            client = httpx.AsyncClient(
                timeout=self.timeout_seconds, headers={"Authorization": f"Bearer {key}"},
            )
        try:
            response = await asyncio.wait_for(client.post(url, json=payload), timeout=self.timeout_seconds)
            response.raise_for_status()
            return _ranked_chunks(_field(response.json(), "results"), chunks, top_k)
        except Exception:
            return None
        finally:
            if owns_client:
                await client.aclose()

    def _embedding_client(self) -> Any:
        if self._text_embedding is not None:
            return self._text_embedding
        from dashscope import TextEmbedding
        return TextEmbedding

    def _rerank_client(self) -> Any:
        if self._text_rerank is not None:
            return self._text_rerank
        from dashscope import TextReRank
        return TextReRank


def _optional_env(variable: str) -> str | None:
    return os.environ.get(variable, "").strip() or None


def _field(value: Any, name: str) -> Any:
    if isinstance(value, dict):
        return value.get(name)
    return getattr(value, name, None)


def _ranked_chunks(results: Any, chunks: list[StoredChunk], top_k: int) -> list[StoredChunk] | None:
    if not isinstance(results, list):
        return None
    ranked: list[StoredChunk] = []
    seen: set[int] = set()
    for result in results:
        index = _field(result, "index")
        if not isinstance(index, int) or index in seen or not 0 <= index < len(chunks):
            continue
        seen.add(index)
        ranked.append(chunks[index])
        if len(ranked) == top_k:
            break
    return ranked or None


def _normalised_vector(value: Any) -> np.ndarray | None:
    try:
        vector = np.asarray(value, dtype=np.float32).reshape(-1)
    except (TypeError, ValueError):
        return None
    if vector.size == 0 or not np.isfinite(vector).all():
        return None
    norm = float(np.linalg.norm(vector))
    if not np.isfinite(norm) or norm == 0:
        return None
    return vector / norm
