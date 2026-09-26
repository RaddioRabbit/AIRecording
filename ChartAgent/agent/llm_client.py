import json
import os
import socket
import time
from typing import Optional, Tuple
from urllib import error as urlerror
from urllib import request as urlrequest

try:
    import openai
    HAS_OPENAI = True
except ImportError:
    HAS_OPENAI = False


class LLMError(Exception):
    """LLM failure with a machine-readable code for the API response."""

    TIMEOUT = "TIMEOUT"
    LLM_UNAVAILABLE = "LLM_UNAVAILABLE"
    INVALID_LLM_RESPONSE = "INVALID_LLM_RESPONSE"

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


DEFAULT_SINGLE_TIMEOUT = 60.0
MIN_REMAINING_SECONDS = 2.0
MAX_ATTEMPTS = 2


def _single_timeout_cap() -> float:
    raw = os.environ.get("CHART_LLM_SINGLE_TIMEOUT", "")
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return DEFAULT_SINGLE_TIMEOUT
    return value if value > 0 else DEFAULT_SINGLE_TIMEOUT


def _remaining_seconds(deadline: Optional[float]) -> float:
    if deadline is None:
        return float("inf")
    return deadline - time.monotonic()


def _attempt_timeout(remaining: float, cap: float) -> float:
    """Per-attempt network timeout: never exceed the cap or the remaining budget."""
    return min(cap, remaining)


def current_provider() -> Tuple[str, str]:
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if api_key and HAS_OPENAI:
        return "openai", os.environ.get("LLM_MODEL", "gpt-4o-mini")
    return "ollama", os.environ.get("OLLAMA_MODEL", "llama3")


def call_llm(prompt: str, temperature: float = 0.3, deadline: Optional[float] = None) -> str:
    """
    优先使用 OpenAI API，若未配置则 fallback 到 Ollama 本地模型。

    deadline 是整个图表请求的 monotonic 截止时间；每次真实网络调用前都会
    重新检查剩余预算，单次调用超时为 min(单次上限, 剩余预算)。
    """
    api_key = os.environ.get("OPENAI_API_KEY", "")
    base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1")

    if api_key and HAS_OPENAI:
        return _call_openai(prompt, api_key, base_url, temperature, deadline)

    return _call_ollama(prompt, temperature, deadline)


def _check_budget(deadline: Optional[float]) -> float:
    remaining = _remaining_seconds(deadline)
    if remaining < MIN_REMAINING_SECONDS:
        raise LLMError(LLMError.TIMEOUT, "剩余时间预算不足，已跳过 LLM 调用")
    return remaining


def _thinking_disabled(base_url: str) -> bool:
    """是否按请求关闭思考模式（reasoning）。

    CHART_LLM_THINKING=disabled|enabled|auto（默认 auto：仅 DeepSeek 关闭）。
    思考型模型的推理会吃光 max_tokens 并拖过单次超时，导致提取阶段超时或
    返回空正文；分类/总览/提取都是结构化抽取任务，不需要推理。
    """
    raw = os.environ.get("CHART_LLM_THINKING", "auto").strip().lower()
    if raw == "disabled":
        return True
    if raw == "enabled":
        return False
    return "deepseek" in base_url.lower()


def _call_openai(prompt: str, api_key: str, base_url: str, temperature: float, deadline: Optional[float]) -> str:
    model = os.environ.get("LLM_MODEL", "gpt-4o-mini")
    cap = _single_timeout_cap()
    last_timeout_error: Optional[BaseException] = None
    for _attempt in range(MAX_ATTEMPTS):
        remaining = _check_budget(deadline)
        try:
            client = openai.OpenAI(
                api_key=api_key,
                base_url=base_url,
                timeout=_attempt_timeout(remaining, cap),
                max_retries=0,
            )
            extra_body = {"thinking": {"type": "disabled"}} if _thinking_disabled(base_url) else None
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": prompt}],
                temperature=temperature,
                max_tokens=8192,
                extra_body=extra_body,
            )
            return response.choices[0].message.content or ""
        except openai.APITimeoutError as error:
            last_timeout_error = error
            continue
        except openai.OpenAIError as error:
            raise LLMError(LLMError.LLM_UNAVAILABLE, f"OpenAI 请求失败：{error}") from error
    raise LLMError(LLMError.TIMEOUT, "LLM 请求在时间预算内多次超时") from last_timeout_error


def _call_ollama(prompt: str, temperature: float, deadline: Optional[float]) -> str:
    remaining = _check_budget(deadline)
    req = urlrequest.Request(
        "http://127.0.0.1:11434/api/generate",
        data=json.dumps({
            "model": os.environ.get("OLLAMA_MODEL", "llama3"),
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": temperature},
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urlrequest.urlopen(req, timeout=_attempt_timeout(remaining, _single_timeout_cap())) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("response", "")
    except (socket.timeout, TimeoutError) as error:
        raise LLMError(LLMError.TIMEOUT, "Ollama 请求超时") from error
    except urlerror.URLError as error:
        reason = getattr(error, "reason", None)
        if isinstance(reason, (socket.timeout, TimeoutError)):
            raise LLMError(LLMError.TIMEOUT, "Ollama 请求超时") from error
        raise LLMError(LLMError.LLM_UNAVAILABLE, f"Ollama 请求失败：{error}") from error
