"""Structured JSON-lines logging for the chart agent.

The Swift side drains this process's stdout and writes each line into
chart-agent.log, so every event is emitted as one JSON object per line on
stdout and follows the shared log structure documented in
docs/backend-log/2026-07-18-backend-log-design.md: ``ts`` (UTC ISO 8601 with
milliseconds), ``level`` (debug/info/warning/error/critical), ``process``
(``chart-agent``), ``category``, ``event``, plus optional ``correlationId``,
``recording`` (12-char sha256 of the raw recording id), ``message``,
``durationMs``, ``errorCode`` and ``metadata``.

Privacy rules: never log API keys, full prompts, full transcripts, or raw LLM
responses. Messages are redacted and truncated to 200 characters.
"""

import hashlib
import json
import logging
import re
import sys
from datetime import datetime, timezone
from typing import Any, Optional

LOGGER_NAME = "chart_agent"
PROCESS_NAME = "chart-agent"

_MESSAGE_MAX_LENGTH = 200

_LEVELS = {
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warning": logging.WARNING,
    "error": logging.ERROR,
    "critical": logging.CRITICAL,
}

# Static messages keyed by machine-readable error code. Exception logs must use
# safe_error_fields() so raw exception text (which can carry transcript bodies,
# prompts, or credentials) never reaches the log stream.
_SAFE_ERROR_MESSAGES = {
    "TIMEOUT": "模型调用超时",
    "LLM_UNAVAILABLE": "模型服务不可用",
    "INVALID_LLM_RESPONSE": "模型响应格式无效",
}
_CREDENTIAL_PATTERNS = (
    re.compile(r"(?i)bearer\s+[^\s,;]+"),
    re.compile(r"\bsk-[A-Za-z0-9_-]+\b"),
    re.compile(r"(?i)(api[_-]?key[=:]\s*)[^\s,;]+"),
    re.compile(r"(?i)(x-amz-signature|ossaccesskeyid|signature|security-token|expires)=[^\s&]+"),
    re.compile(r"(?i)(authorization[=:]\s*)[^\s,;]+"),
)

_logger = logging.getLogger(LOGGER_NAME)


def _ensure_configured() -> None:
    if _logger.handlers:
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    _logger.addHandler(handler)
    _logger.setLevel(logging.DEBUG)
    _logger.propagate = False


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def recording_hash(recording_id: Optional[str]) -> str:
    """sha256 prefix of the recording id; the raw id is never logged."""
    if not recording_id:
        return ""
    return hashlib.sha256(str(recording_id).encode("utf-8")).hexdigest()[:12]


def safe_error_fields(error: BaseException) -> dict[str, Any]:
    """Log-safe description of an exception: type, code, and a static message."""
    code = getattr(error, "code", None)
    fields: dict[str, Any] = {
        "errorType": type(error).__name__,
        "message": _SAFE_ERROR_MESSAGES.get(code, "图表阶段执行失败"),
    }
    if code:
        fields["errorCode"] = code
    return fields


def _redact_message(value: Any) -> str:
    result = str(value)
    for pattern in _CREDENTIAL_PATTERNS:
        result = pattern.sub("[REDACTED]", result)
    return result[:_MESSAGE_MAX_LENGTH]


def _normalize_level(level: str) -> str:
    normalized = str(level).lower()
    return normalized if normalized in _LEVELS else "info"


def log_event(
    level: str,
    event: str,
    correlation_id: Optional[str] = None,
    recording_id: Optional[str] = None,
    category: str = "chart",
    **fields: Any,
) -> None:
    """Emit one structured log line in the shared JSON format.

    ``correlation_id`` is the request id the Swift side created for this
    operation; it must stay constant across every stage of one request.
    """
    _ensure_configured()
    normalized_level = _normalize_level(level)
    record: dict[str, Any] = {
        "ts": _timestamp(),
        "level": normalized_level,
        "process": PROCESS_NAME,
        "category": category,
        "event": event,
    }
    if correlation_id:
        record["correlationId"] = str(correlation_id)
    hashed_recording = recording_hash(recording_id)
    if hashed_recording:
        record["recording"] = hashed_recording
    for key, value in fields.items():
        if value is None:
            continue
        if key == "message":
            value = _redact_message(value)
        record[key] = value
    _logger.log(_LEVELS[normalized_level], json.dumps(record, ensure_ascii=False))
