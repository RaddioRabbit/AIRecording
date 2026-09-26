from pathlib import Path

from agent.config import KnowledgeConfig


def test_from_environment_uses_defaults(monkeypatch):
    database_path = Path("/tmp/knowledge.sqlite")
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", str(database_path))
    monkeypatch.delenv("PORT", raising=False)
    monkeypatch.delenv("EMBEDDING_MODEL", raising=False)
    monkeypatch.delenv("RERANK_MODEL", raising=False)
    monkeypatch.delenv("EMBEDDING_DIMENSION", raising=False)

    config = KnowledgeConfig.from_environment()

    assert config.db_path == database_path
    assert config.host == "127.0.0.1"
    assert config.port == 8766
    assert config.embedding_model == "text-embedding-v4"
    assert config.embedding_dimension is None
    assert config.rerank_model == "gte-rerank-v2"
    assert config.retrieval_chunk_size == 250
    assert config.retrieval_chunk_overlap == 25
    assert config.generation_chunk_size == 1500
    assert config.generation_chunk_overlap == 150
    assert config.rrf_k == 60
    assert config.index_version == 1


def test_from_environment_applies_supported_overrides(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("EMBEDDING_MODEL", "custom-embedding")
    monkeypatch.setenv("EMBEDDING_DIMENSION", "768")
    monkeypatch.setenv("RERANK_MODEL", "custom-reranker")

    config = KnowledgeConfig.from_environment()

    assert config.db_path == Path("/tmp/custom.sqlite")
    assert config.port == 9000
    assert config.embedding_model == "custom-embedding"
    assert config.embedding_dimension == 768
    assert config.rerank_model == "custom-reranker"


def test_from_environment_parses_embedding_dimension(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("EMBEDDING_DIMENSION", "1536")

    config = KnowledgeConfig.from_environment()

    assert config.embedding_dimension == 1536


def test_from_environment_ignores_invalid_embedding_dimension(monkeypatch, capsys):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")

    monkeypatch.setenv("EMBEDDING_DIMENSION", "abc")
    assert KnowledgeConfig.from_environment().embedding_dimension is None
    captured = capsys.readouterr()
    assert "EMBEDDING_DIMENSION_INVALID" in captured.out

    monkeypatch.setenv("EMBEDDING_DIMENSION", "0")
    assert KnowledgeConfig.from_environment().embedding_dimension is None
    captured = capsys.readouterr()
    assert "EMBEDDING_DIMENSION_INVALID" in captured.out

    monkeypatch.setenv("EMBEDDING_DIMENSION", "-1")
    assert KnowledgeConfig.from_environment().embedding_dimension is None
    captured = capsys.readouterr()
    assert "EMBEDDING_DIMENSION_INVALID" in captured.out

    monkeypatch.setenv("EMBEDDING_DIMENSION", "  ")
    assert KnowledgeConfig.from_environment().embedding_dimension is None
    captured = capsys.readouterr()
    assert "EMBEDDING_DIMENSION_INVALID" not in captured.out

    monkeypatch.delenv("EMBEDDING_DIMENSION", raising=False)
    assert KnowledgeConfig.from_environment().embedding_dimension is None
    captured = capsys.readouterr()
    assert "EMBEDDING_DIMENSION_INVALID" not in captured.out


def test_from_environment_prefers_environment_dimension_over_default(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("EMBEDDING_MODEL", "text-embedding-v3")
    monkeypatch.setenv("EMBEDDING_DIMENSION", "768")

    config = KnowledgeConfig.from_environment()

    assert config.embedding_model == "text-embedding-v3"
    assert config.embedding_dimension == 768


def test_from_environment_defaults_providers_to_dashscope(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.delenv("EMBEDDING_PROVIDER", raising=False)
    monkeypatch.delenv("RERANK_PROVIDER", raising=False)
    monkeypatch.delenv("EMBEDDING_BASE_URL", raising=False)
    monkeypatch.delenv("RERANK_BASE_URL", raising=False)

    config = KnowledgeConfig.from_environment()

    assert config.embedding_provider == "dashscope"
    assert config.rerank_provider == "dashscope"
    assert config.embedding_base_url is None
    assert config.rerank_base_url is None


def test_from_environment_parses_provider_values(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("EMBEDDING_PROVIDER", " OpenAI ")
    monkeypatch.setenv("RERANK_PROVIDER", " DashScope ")

    config = KnowledgeConfig.from_environment()

    assert config.embedding_provider == "openai"
    assert config.rerank_provider == "dashscope"


def test_from_environment_falls_back_on_invalid_provider(monkeypatch, capsys):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")

    monkeypatch.setenv("EMBEDDING_PROVIDER", "cohere")
    assert KnowledgeConfig.from_environment().embedding_provider == "dashscope"
    captured = capsys.readouterr()
    assert "EMBEDDING_PROVIDER_INVALID" in captured.out

    monkeypatch.setenv("RERANK_PROVIDER", "jina")
    assert KnowledgeConfig.from_environment().rerank_provider == "dashscope"
    captured = capsys.readouterr()
    assert "RERANK_PROVIDER_INVALID" in captured.out

    monkeypatch.setenv("EMBEDDING_PROVIDER", "  ")
    monkeypatch.setenv("RERANK_PROVIDER", "")
    config = KnowledgeConfig.from_environment()
    captured = capsys.readouterr()
    assert config.embedding_provider == "dashscope"
    assert config.rerank_provider == "dashscope"
    assert "PROVIDER_INVALID" not in captured.out


def test_from_environment_parses_base_urls(monkeypatch):
    monkeypatch.setenv("KNOWLEDGE_DB_PATH", "/tmp/custom.sqlite")
    monkeypatch.setenv("EMBEDDING_BASE_URL", " https://api.example.com/v1 ")
    monkeypatch.setenv("RERANK_BASE_URL", "   ")

    config = KnowledgeConfig.from_environment()

    assert config.embedding_base_url == "https://api.example.com/v1"
    assert config.rerank_base_url is None
