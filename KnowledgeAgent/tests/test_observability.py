import json

from agent.observability import log_event, recording_hash


def test_logs_never_contain_user_text_or_credentials(capsys):
    log_event("query_failed", correlation_id="req-1", recording_id="rec-1", error_code="LLM_TIMEOUT",
              metadata={"apiKey": "sk-secret", "query": "谁负责上线", "candidateCount": 3})

    output = capsys.readouterr().out
    payload = json.loads(output)
    assert "sk-secret" not in output
    assert "谁负责上线" not in output
    assert payload["errorCode"] == "LLM_TIMEOUT"
    assert payload["process"] == "knowledge-agent"
    assert payload["recording"] == recording_hash("rec-1")
    assert len(payload["recording"]) == 12
    assert payload["metadata"] == {"candidateCount": 3}


def test_logs_keep_only_whitelisted_scalar_metadata(capsys):
    log_event("retrieval", metadata={"model": "embedding-v4", "sourceCount": 2, "nested": {"no": True}})
    payload = json.loads(capsys.readouterr().out)

    assert payload["metadata"] == {"model": "embedding-v4", "sourceCount": 2}


def test_logs_omit_fixture_question_answer_and_source_text(capsys):
    private_values = {
        "query": "最终由谁负责上线协调？",
        "answer": "最终由张伟负责上线协调，后续会议已确认。",
        "title": "产品发布协调会",
        "speakerName": "张伟",
        "segmentText": "本次发布由张伟负责上线协调。",
        "apiKey": "dashscope-fixture-secret",
        "authorization": "Bearer openai-fixture-secret",
    }
    log_event("fixture_privacy", metadata={**private_values, "result": private_values["answer"]})

    output = capsys.readouterr().out
    assert all(value not in output for value in private_values.values())
    assert json.loads(output)["metadata"] == {}
