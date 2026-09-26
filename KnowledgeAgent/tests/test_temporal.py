from agent.temporal import detect_intent, is_generic_query, strip_intent


def test_detect_maps_specific_phrases_before_bare_words():
    assert detect_intent("最新一次会议说了什么") == ("最新一次", "desc", 1)
    assert detect_intent("最近几场都在聊什么") == ("最近几场", "desc", 3)
    assert detect_intent("最近一次提到预算") == ("最近一次", "desc", 3)


def test_detect_bare_words_and_directions():
    assert detect_intent("最新的音频内容是什么") == ("最新", "desc", 1)
    assert detect_intent("最近讲了什么") == ("最近", "desc", 3)
    assert detect_intent("最早的会议说了什么") == ("最早", "asc", 1)
    assert detect_intent("刚刚的会议") == ("刚刚", "desc", 1)
    assert detect_intent("上一场会议") == ("上一场", "desc", 1)


def test_detect_returns_none_without_temporal_words():
    assert detect_intent("预算是谁负责的") is None
    assert detect_intent("") is None


def test_strip_removes_matched_phrase():
    intent = detect_intent("最新的音频内容是什么")
    assert strip_intent("最新的音频内容是什么", intent) == "的音频内容是什么"


def test_generic_query_detection():
    assert is_generic_query("的音频内容是什么") is True
    assert is_generic_query("讲了什么") is True
    assert is_generic_query("") is True
    assert is_generic_query("的会议说了什么") is True
    assert is_generic_query("预算怎么定的") is False
    assert is_generic_query("的会议里预算怎么定的") is False
