"""Grounded answer generation with citation validation before exposure."""

from __future__ import annotations

import html
import os
import re
from collections.abc import AsyncIterator, Mapping, Sequence
from typing import Any, Protocol

from agent.schema import BuiltEvidence, KnowledgeAnswer, KnowledgeHistoryMessage


REFUSAL_TEXT = "知识库中没有足够依据。"
SOURCE_PATTERN = re.compile(r"\[(S\d+)\]")
ATX_HEADING_PATTERN = re.compile(r"^\s{0,3}#{1,6}(?:\s|$)")
SYSTEM_PROMPT = """你是录音知识库问答助手。
只能依据 <evidence> 中的原始转写回答；会议纪要和对话历史不是事实来源。
每个事实性段落必须引用至少一个有效来源编号，例如 [S1]。
证据不足时只回答：知识库中没有足够依据。
每条来源标注了录音标题与录制日期；涉及最新、最近、最早或时间先后的问题，必须依据来源标注的日期回答，不得推测证据中未出现的日期。
不得用常识补充人物、数字、日期、责任人、决策或因果关系。"""


class ChatCompletionClient(Protocol):
    def complete_stream(self, messages: list[dict[str, str]]) -> AsyncIterator[str]: ...


class OpenAICompatibleChatCompletionClient:
    """Minimal OpenAI-compatible streaming boundary; credentials never enter logs."""

    def __init__(self, *, base_url: str | None = None, api_key: str | None = None,
                 model: str | None = None, client: Any | None = None) -> None:
        self.base_url = base_url if base_url is not None else os.getenv("OPENAI_BASE_URL")
        self.api_key = api_key if api_key is not None else os.getenv("OPENAI_API_KEY")
        self.model = model if model is not None else os.getenv("LLM_MODEL")
        self._client = client

    async def complete_stream(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        if not self.api_key or not self.model:
            raise RuntimeError("llm_configuration_missing")
        client = self._client
        owns_client = client is None
        if client is None:
            from openai import AsyncOpenAI
            client = AsyncOpenAI(api_key=self.api_key, base_url=self.base_url or None)
        try:
            stream = await client.chat.completions.create(model=self.model, messages=messages, stream=True)
            async for event in stream:
                choices = getattr(event, "choices", ())
                if not choices:
                    continue
                content = getattr(getattr(choices[0], "delta", None), "content", None)
                if isinstance(content, str) and content:
                    yield content
        finally:
            if owns_client:
                await client.close()


def validate_citations(content: str, source_ids: set[str]) -> bool:
    """Require a valid evidence source in every non-heading, non-empty paragraph."""
    if not content.strip():
        return False
    if content.strip() == REFUSAL_TEXT:
        return True
    for paragraph in re.split(r"\n\s*\n", content):
        lines = [line for line in paragraph.splitlines() if not ATX_HEADING_PATTERN.match(line)]
        body = "\n".join(lines).strip()
        if not body:
            continue
        citations = SOURCE_PATTERN.findall(body)
        if not citations or any(source_id not in source_ids for source_id in citations):
            return False
    return True


class StrictAnswerService:
    def __init__(self, llm: ChatCompletionClient) -> None:
        self.llm = llm

    async def answer(self, question: str, evidence: BuiltEvidence,
                     history: Sequence[KnowledgeHistoryMessage | Mapping[str, str]]) -> KnowledgeAnswer:
        if not question.strip() or not evidence.sources:
            return KnowledgeAnswer(content=REFUSAL_TEXT, sources=evidence.sources)

        messages = self._answer_messages(question, evidence, history)
        first = await self._buffer_completion(messages)
        source_ids = {source.sourceId for source in evidence.sources}
        if validate_citations(first, source_ids):
            return KnowledgeAnswer(content=first, sources=evidence.sources)

        repaired = await self._buffer_completion(self._repair_messages(messages, first))
        if validate_citations(repaired, source_ids):
            return KnowledgeAnswer(content=repaired, sources=evidence.sources)
        return KnowledgeAnswer(content=REFUSAL_TEXT, sources=evidence.sources)

    async def _buffer_completion(self, messages: list[dict[str, str]]) -> str:
        parts: list[str] = []
        async for delta in self.llm.complete_stream(messages):
            if isinstance(delta, str):
                parts.append(delta)
        return "".join(parts).strip()

    @staticmethod
    def _answer_messages(question: str, evidence: BuiltEvidence,
                         history: Sequence[KnowledgeHistoryMessage | Mapping[str, str]]) -> list[dict[str, str]]:
        history_text = StrictAnswerService._history_text(history[-6:])
        user_content = (
            f"<conversation_context>{html.escape(history_text)}</conversation_context>\n"
            f"<evidence>{html.escape(evidence.contextText)}</evidence>\n"
            f"<question>{html.escape(question)}</question>"
        )
        return [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user_content}]

    @staticmethod
    def _history_text(history: Sequence[KnowledgeHistoryMessage | Mapping[str, str]]) -> str:
        parts: list[str] = []
        for message in history:
            if isinstance(message, Mapping):
                role = message.get("role", "")
                content = message.get("content", "")
            else:
                role, content = message.role, message.content
            if role in {"user", "assistant"} and isinstance(content, str):
                parts.append(f"{role}: {content}")
        return "\n".join(parts)

    @staticmethod
    def _repair_messages(messages: list[dict[str, str]], invalid_answer: str) -> list[dict[str, str]]:
        return [
            *messages,
            {"role": "assistant", "content": invalid_answer},
            {"role": "user", "content": "上一条回答未满足引用格式要求。请仅修复引用格式：每个非标题、非空段落都必须至少包含一个现有来源编号 [S#]；不得添加任何新证据或事实。"},
        ]
