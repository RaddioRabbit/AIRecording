import asyncio
import time
from types import SimpleNamespace

import numpy as np

from agent.embedding import DashScopeAdapter
from agent.store import StoredChunk


def test_missing_key_returns_none_and_never_calls_sdk(monkeypatch):
    monkeypatch.delenv("DASHSCOPE_API_KEY", raising=False)
    monkeypatch.delenv("EMBEDDING_API_KEY", raising=False)
    monkeypatch.delenv("RERANK_API_KEY", raising=False)
    adapter = DashScopeAdapter()

    assert asyncio.run(adapter.embed_query("上线负责人")) is None
    assert asyncio.run(adapter.embed_documents(["张伟负责上线"])) == [None]


def test_document_embeddings_use_document_type_batches_and_normalise(monkeypatch):
    calls = []

    class FakeEmbedding:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"embeddings": [{"embedding": [3.0, 4.0]} for _ in kwargs["input"]]}}

    adapter = DashScopeAdapter(api_key="test-key", text_embedding=FakeEmbedding)
    vectors = asyncio.run(adapter.embed_documents([f"document {index}" for index in range(26)]))

    assert [len(call["input"]) for call in calls] == [25, 1]
    assert all(call["text_type"] == "document" for call in calls)
    assert all(call["request_timeout"] == 10.0 for call in calls)
    assert all("timeout" not in call for call in calls)
    assert all(np.allclose(vector, [0.6, 0.8]) for vector in vectors)


def test_provider_failure_is_a_stable_none_result_without_response_logging():
    class BrokenEmbedding:
        @staticmethod
        def call(**kwargs):
            raise RuntimeError("provider response body must stay private")

    adapter = DashScopeAdapter(api_key="test-key", text_embedding=BrokenEmbedding)

    assert asyncio.run(adapter.embed_query("who owns launch")) is None


def test_rerank_uses_returned_indexes_and_returns_none_on_failure():
    chunks = [_chunk("a"), _chunk("b")]
    calls = []

    class FakeRerank:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            assert kwargs["top_n"] == 1
            return {"output": {"results": [{"index": 1}]}}

    adapter = DashScopeAdapter(api_key="test-key", text_rerank=FakeRerank)
    assert asyncio.run(adapter.rerank("owner", chunks, top_k=1)) == [chunks[1]]
    assert calls[0]["request_timeout"] == 10.0
    assert "timeout" not in calls[0]


def test_embedding_and_rerank_time_out_to_the_same_safe_fallback():
    class BlockingEmbedding:
        @staticmethod
        def call(**kwargs):
            time.sleep(0.05)

    class BlockingRerank:
        @staticmethod
        def call(**kwargs):
            time.sleep(0.05)

    adapter = DashScopeAdapter(
        api_key="test-key", text_embedding=BlockingEmbedding, text_rerank=BlockingRerank,
        timeout_seconds=0.001,
    )

    assert asyncio.run(adapter.embed_query("launch")) is None
    assert asyncio.run(adapter.rerank("launch", [_chunk("a")], top_k=1)) is None


def test_embed_passes_dimension_when_configured():
    calls = []

    class FakeEmbedding:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"embeddings": [{"embedding": [3.0, 4.0]} for _ in kwargs["input"]]}}

    adapter = DashScopeAdapter(api_key="test-key", embedding_dimension=1536, text_embedding=FakeEmbedding)
    vectors = asyncio.run(adapter.embed_documents(["张伟负责上线"]))

    assert calls[0]["dimension"] == 1536
    assert all(np.allclose(vector, [0.6, 0.8]) for vector in vectors)


def test_embed_omits_dimension_when_not_configured():
    calls = []

    class FakeEmbedding:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"embeddings": [{"embedding": [3.0, 4.0]} for _ in kwargs["input"]]}}

    adapter = DashScopeAdapter(api_key="test-key", text_embedding=FakeEmbedding)

    asyncio.run(adapter.embed_query("launch"))

    assert "dimension" not in calls[0]


def test_constructor_normalizes_non_positive_dimension_to_none():
    assert DashScopeAdapter(api_key="test-key", embedding_dimension=0).embedding_dimension is None
    assert DashScopeAdapter(api_key="test-key", embedding_dimension=-1).embedding_dimension is None
    assert DashScopeAdapter(api_key="test-key", embedding_dimension=1536).embedding_dimension == 1536


def test_openai_embedding_sends_dimensions_and_aligns_by_index(monkeypatch):
    monkeypatch.setenv("EMBEDDING_API_KEY", "openai-key")
    monkeypatch.delenv("EMBEDDING_PROVIDER", raising=False)
    calls = []
    close_calls = []

    class FakeOpenAIEmbeddings:
        async def create(self, **kwargs):
            calls.append(kwargs)
            return SimpleNamespace(data=[
                SimpleNamespace(index=1, embedding=[3.0, 4.0]),
                SimpleNamespace(index=0, embedding=[0.0, 2.0]),
            ])

        async def close(self):
            close_calls.append(True)

    adapter = DashScopeAdapter(
        embedding_provider="openai", embedding_model="text-embedding-3-small",
        embedding_base_url="https://api.example.com/v1", embedding_dimension=1536,
        openai_embeddings=FakeOpenAIEmbeddings(),
    )
    vectors = asyncio.run(adapter.embed_documents(["a", "b"]))

    assert calls[0] == {"model": "text-embedding-3-small", "input": ["a", "b"], "dimensions": 1536}
    assert np.allclose(vectors[0], [0.0, 1.0])
    assert np.allclose(vectors[1], [0.6, 0.8])
    assert close_calls == []


def test_openai_embedding_omits_dimensions_when_not_configured(monkeypatch):
    monkeypatch.setenv("EMBEDDING_API_KEY", "openai-key")
    calls = []

    class FakeOpenAIEmbeddings:
        async def create(self, **kwargs):
            calls.append(kwargs)
            return SimpleNamespace(data=[SimpleNamespace(index=0, embedding=[1.0])])

    adapter = DashScopeAdapter(embedding_provider="openai", openai_embeddings=FakeOpenAIEmbeddings())

    asyncio.run(adapter.embed_query("launch"))

    assert "dimensions" not in calls[0]
    assert calls[0]["input"] == ["launch"]


def test_openai_embedding_without_key_degrades_without_calling_client(monkeypatch):
    monkeypatch.delenv("EMBEDDING_API_KEY", raising=False)
    created = []

    class FakeOpenAIEmbeddings:
        async def create(self, **kwargs):
            created.append(kwargs)
            return SimpleNamespace(data=[])

    adapter = DashScopeAdapter(embedding_provider="openai", openai_embeddings=FakeOpenAIEmbeddings())

    assert asyncio.run(adapter.embed_query("hello")) is None
    assert asyncio.run(adapter.embed_documents(["a", "b"])) == [None, None]
    assert created == []


def test_openai_embedding_mismatched_data_degrades_to_none(monkeypatch):
    monkeypatch.setenv("EMBEDDING_API_KEY", "openai-key")

    class FakeOpenAIEmbeddings:
        async def create(self, **kwargs):
            return SimpleNamespace(data=[SimpleNamespace(index=0, embedding=[1.0])])

    adapter = DashScopeAdapter(embedding_provider="openai", openai_embeddings=FakeOpenAIEmbeddings())

    assert asyncio.run(adapter.embed_documents(["a", "b"])) == [None, None]


def test_openai_embedding_rejects_malformed_indexes(monkeypatch):
    monkeypatch.setenv("EMBEDDING_API_KEY", "openai-key")

    class FakeOpenAIEmbeddings:
        async def create(self, **kwargs):
            return SimpleNamespace(data=[
                SimpleNamespace(index=0, embedding=[1.0]),
                SimpleNamespace(index=0, embedding=[1.0]),
                SimpleNamespace(index=1, embedding=[1.0]),
            ])

    adapter = DashScopeAdapter(embedding_provider="openai", openai_embeddings=FakeOpenAIEmbeddings())

    assert asyncio.run(adapter.embed_documents(["a", "b", "c"])) == [None, None, None]


def test_openai_embedding_constructed_client_is_closed_after_use(monkeypatch):
    monkeypatch.setenv("EMBEDDING_API_KEY", "openai-key")
    created_kwargs = {}
    closed = []

    class FakeAsyncOpenAI:
        def __init__(self, **kwargs):
            created_kwargs.update(kwargs)
            self.embeddings = self

        async def create(self, **kwargs):
            return SimpleNamespace(data=[SimpleNamespace(index=0, embedding=[3.0, 4.0])])

        async def close(self):
            closed.append(True)

    monkeypatch.setattr("openai.AsyncOpenAI", FakeAsyncOpenAI)

    adapter = DashScopeAdapter(
        embedding_provider="openai", embedding_model="text-embedding-3-small",
        embedding_base_url="https://api.example.com/v1", embedding_dimension=1536,
    )
    vector = asyncio.run(adapter.embed_query("launch"))

    assert created_kwargs == {"api_key": "openai-key", "base_url": "https://api.example.com/v1"}
    assert np.allclose(vector, [0.6, 0.8])
    assert closed == [True]


def test_openai_embedding_provider_is_read_from_environment(monkeypatch):
    monkeypatch.setenv("EMBEDDING_PROVIDER", "openai")
    monkeypatch.delenv("EMBEDDING_API_KEY", raising=False)

    adapter = DashScopeAdapter()

    assert adapter.embedding_provider == "openai"
    assert asyncio.run(adapter.embed_query("hello")) is None


def test_openai_rerank_posts_rerank_endpoint_and_selects_by_index(monkeypatch):
    monkeypatch.setenv("RERANK_API_KEY", "rerank-key")
    chunks = [_chunk("a"), _chunk("b"), _chunk("c")]
    requests = []

    class FakeResponse:
        def raise_for_status(self):
            pass

        def json(self):
            return {"results": [{"index": 2, "relevance_score": 0.9}, {"index": 0, "relevance_score": 0.5}]}

    class FakeHttp:
        async def post(self, url, json=None):
            requests.append((url, json))
            return FakeResponse()

    adapter = DashScopeAdapter(
        rerank_provider="openai", rerank_model="bge-reranker-v2-m3",
        rerank_base_url="https://api.example.com/v1/", rerank_http=FakeHttp(),
    )
    ranked = asyncio.run(adapter.rerank("owner", chunks, top_k=2))

    url, payload = requests[0]
    assert url == "https://api.example.com/v1/rerank"
    assert payload["model"] == "bge-reranker-v2-m3"
    assert payload["query"] == "owner"
    assert payload["documents"] == ["a", "b", "c"]
    assert payload["top_n"] == 2
    assert ranked == [chunks[2], chunks[0]]


def test_openai_rerank_created_client_sends_bearer_header_and_closes(monkeypatch):
    monkeypatch.setenv("RERANK_API_KEY", "rerank-key")
    created = {}
    closed = []

    class FakeResponse:
        def raise_for_status(self):
            pass

        def json(self):
            return {"results": [{"index": 0}]}

    class FakeAsyncClient:
        def __init__(self, **kwargs):
            created.update(kwargs)

        async def post(self, url, json=None):
            return FakeResponse()

        async def aclose(self):
            closed.append(True)

    monkeypatch.setattr("httpx.AsyncClient", FakeAsyncClient)

    adapter = DashScopeAdapter(rerank_provider="openai", rerank_base_url="https://api.example.com/v1")
    ranked = asyncio.run(adapter.rerank("q", [_chunk("a")], top_k=1))

    assert created["headers"] == {"Authorization": "Bearer rerank-key"}
    assert created["timeout"] == 10.0
    assert ranked == [_chunk("a")]
    assert closed == [True]


def test_openai_rerank_without_base_url_returns_none(monkeypatch):
    monkeypatch.setenv("RERANK_API_KEY", "rerank-key")
    posts = []

    class FakeHttp:
        async def post(self, url, json=None):
            posts.append((url, json))

    adapter = DashScopeAdapter(rerank_provider="openai", rerank_http=FakeHttp())

    assert asyncio.run(adapter.rerank("q", [_chunk("a")], top_k=1)) is None
    assert posts == []


def test_openai_rerank_without_key_returns_none(monkeypatch):
    monkeypatch.delenv("RERANK_API_KEY", raising=False)
    posts = []

    class FakeHttp:
        async def post(self, url, json=None):
            posts.append((url, json))

    adapter = DashScopeAdapter(
        rerank_provider="openai", rerank_base_url="https://api.example.com/v1", rerank_http=FakeHttp(),
    )

    assert asyncio.run(adapter.rerank("q", [_chunk("a")], top_k=1)) is None
    assert posts == []


def test_dashscope_embedding_prefers_service_key_over_legacy(monkeypatch):
    monkeypatch.setenv("EMBEDDING_API_KEY", "new-embedding-key")
    monkeypatch.setenv("DASHSCOPE_API_KEY", "legacy-key")
    calls = []

    class FakeEmbedding:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"embeddings": [{"embedding": [3.0, 4.0]} for _ in kwargs["input"]]}}

    adapter = DashScopeAdapter(api_key="constructor-key", text_embedding=FakeEmbedding)

    asyncio.run(adapter.embed_query("launch"))

    assert calls[0]["api_key"] == "new-embedding-key"

    monkeypatch.delenv("EMBEDDING_API_KEY", raising=False)
    asyncio.run(adapter.embed_query("launch"))

    assert calls[1]["api_key"] == "constructor-key"


def test_dashscope_rerank_prefers_service_key_over_legacy(monkeypatch):
    monkeypatch.setenv("RERANK_API_KEY", "new-rerank-key")
    monkeypatch.setenv("DASHSCOPE_API_KEY", "legacy-key")
    calls = []

    class FakeRerank:
        @staticmethod
        def call(**kwargs):
            calls.append(kwargs)
            return {"output": {"results": [{"index": 0}]}}

    adapter = DashScopeAdapter(api_key="constructor-key", text_rerank=FakeRerank)

    asyncio.run(adapter.rerank("owner", [_chunk("a")], top_k=1))

    assert calls[0]["api_key"] == "new-rerank-key"

    monkeypatch.delenv("RERANK_API_KEY", raising=False)
    asyncio.run(adapter.rerank("owner", [_chunk("a")], top_k=1))

    assert calls[1]["api_key"] == "constructor-key"


def _chunk(chunk_id: str) -> StoredChunk:
    return StoredChunk(chunk_id, "rec-1", "retrieval", chunk_id, 0, None, (), None, None,
                       None, None, True, None, None)
