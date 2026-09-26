"""Privacy-preserving JSON line logging for the local knowledge service."""

from __future__ import annotations

import hashlib
import json
import sys
from datetime import UTC, datetime
from typing import Any, Mapping


ALLOWED_METADATA = {"model", "candidateCount", "sourceCount", "statusCode"}
REDACTED_KEYS = {
    "apiKey", "authorization", "query", "question", "transcript", "summary", "answer", "prompt",
    "title", "speaker", "speakerName", "segment", "segmentText", "content",
}
_SENSITIVE_KEYS = {"".join(character for character in key.lower() if character.isalnum()) for key in REDACTED_KEYS}
_SENSITIVE_KEYS |= {"token", "secret", "password"}


def recording_hash(recording_id: str) -> str:
    return hashlib.sha256(recording_id.encode("utf-8")).hexdigest()[:12]


def _safe_metadata(metadata: Mapping[str, Any] | None) -> dict[str, Any]:
    safe: dict[str, Any] = {}
    for key, value in (metadata or {}).items():
        lowered = "".join(character for character in key.lower() if character.isalnum())
        if lowered in _SENSITIVE_KEYS:
            # Deliberately omit private fields rather than preserving a user value.
            continue
        if key in ALLOWED_METADATA and isinstance(value, (str, int, float, bool)):
            safe[key] = value
    return safe


def log_event(event: str, *, level: str = "info", correlation_id: str | None = None,
              recording_id: str | None = None, error_code: str | None = None,
              duration_ms: int | float | None = None, metadata: Mapping[str, Any] | None = None) -> None:
    """Emit only canonical, scalar operational data; never user supplied text."""
    payload: dict[str, Any] = {
        "ts": datetime.now(UTC).isoformat(),
        "level": level,
        "process": "knowledge-agent",
        "event": event,
        "correlationId": correlation_id,
        "errorCode": error_code,
        "durationMs": duration_ms,
        "metadata": _safe_metadata(metadata),
    }
    if recording_id:
        payload["recording"] = recording_hash(recording_id)
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")), file=sys.stdout, flush=True)
