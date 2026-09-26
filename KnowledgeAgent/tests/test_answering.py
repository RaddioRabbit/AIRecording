import asyncio

from agent.answering import (
    OpenAICompatibleChatCompletionClient,
    REFUSAL_TEXT,
    StrictAnswerService,
    validate_citations,
)
from agent.context import BuiltEvidence, EvidenceSource
from agent.schema import KnowledgeHistoryMessage


class FakeLLM:
    def __init__(self, replies: list[str]) -> None:
        self.replies = replies
        self.call_count = 0
        self.messages: list[list[dict[str, str]]] = []

    async def complete_stream(self, messages):
        self.messages.append(messages)
        reply = self.replies[self.call_count]
        self.call_count += 1
        yield reply[:4]
        yield reply[4:]


EVIDENCE = BuiltEvidence(
    contextText="[S1]\n原始转写：张伟负责。\n",
    sources=[EvidenceSource(sourceId="S1", recordingId="rec-1", segmentIds=["seg-1"], startTime=1.0, endTime=2.0)],
)


def test_every_non_heading_answer_paragraph_requires_a_valid_source():
    assert validate_citations("## 结论\n张伟负责。[S1]\n\n时间是周五。", {"S1"}) is False
    assert validate_citations("## 结论\n\n张伟负责。[S1]", {"S1"}) is True
    assert validate_citations(REFUSAL_TEXT, {"S1"}) is True
    assert validate_citations("#张伟负责。", {"S1"}) is False
    assert validate_citations("####### 张伟负责。", {"S1"}) is False
    assert validate_citations(" \n\t", {"S1"}) is False


def test_invalid_citation_repairs_once_then_refuses():
    llm = FakeLLM(["负责人是张伟。[S99]", "负责人是张伟。"])

    result = asyncio.run(StrictAnswerService(llm).answer("谁负责？", EVIDENCE, []))

    assert llm.call_count == 2
    assert result.content == REFUSAL_TEXT
    assert result.sources == EVIDENCE.sources
    assert "引用格式" in llm.messages[1][-1]["content"]
    assert "<evidence>" not in llm.messages[1][-1]["content"]


def test_history_is_capped_and_kept_outside_evidence():
    history = [KnowledgeHistoryMessage(role="user", content=f"previous-{index}") for index in range(8)]
    llm = FakeLLM(["张伟负责。[S1]"])

    result = asyncio.run(StrictAnswerService(llm).answer("谁负责？", EVIDENCE, history))

    assert result.content == "张伟负责。[S1]"
    prompt = llm.messages[0][1]["content"]
    history_block, evidence_and_question = prompt.split("</conversation_context>", maxsplit=1)
    assert "previous-1" not in history_block
    assert "previous-2" in history_block
    assert "previous-7" in history_block
    assert "previous-7" not in evidence_and_question.split("</evidence>", maxsplit=1)[0]


def test_no_sources_refuses_without_calling_llm():
    llm = FakeLLM(["不应被调用。[S1]"])
    empty_evidence = BuiltEvidence(contextText="", sources=[])

    result = asyncio.run(StrictAnswerService(llm).answer("没有依据的问题", empty_evidence, []))

    assert result.content == REFUSAL_TEXT
    assert llm.call_count == 0


def test_blank_provider_answer_repairs_once_then_refuses():
    llm = FakeLLM(["   ", "\n\t"])

    result = asyncio.run(StrictAnswerService(llm).answer("谁负责？", EVIDENCE, []))

    assert llm.call_count == 2
    assert result.content == REFUSAL_TEXT


def test_valid_answer_is_exposed_only_after_one_buffered_completion():
    llm = FakeLLM(["张伟负责。[S1]"])

    result = asyncio.run(StrictAnswerService(llm).answer("谁负责？", EVIDENCE, []))

    assert result.content == "张伟负责。[S1]"
    assert llm.call_count == 1


def test_openai_compatible_client_yields_only_nonempty_text_deltas():
    class Delta:
        def __init__(self, content):
            self.content = content

    class Choice:
        def __init__(self, content):
            self.delta = Delta(content)

    class Event:
        def __init__(self, content):
            self.choices = [] if content is None else [Choice(content)]

    class Completions:
        async def create(self, **kwargs):
            async def events():
                for content in ("答案", "", None, "。[S1]"):
                    yield Event(content)
            return events()

    class Client:
        class Chat:
            completions = Completions()
        chat = Chat()

    async def collect():
        client = OpenAICompatibleChatCompletionClient(api_key="secret", model="model", client=Client())
        return [delta async for delta in client.complete_stream([{"role": "user", "content": "问题"}])]

    assert asyncio.run(collect()) == ["答案", "。[S1]"]


def test_system_prompt_requires_date_grounding():
    from agent.answering import SYSTEM_PROMPT

    assert "录制日期" in SYSTEM_PROMPT
    assert "不得推测" in SYSTEM_PROMPT
