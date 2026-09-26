import io
import json
import logging
import unittest

from agent.observability import (
    LOGGER_NAME,
    log_event,
    recording_hash,
    safe_error_fields,
)


def _capture_events(func):
    """Runs func() with the chart_agent logger redirected into a buffer and
    returns the emitted records as parsed dicts."""
    logger = logging.getLogger(LOGGER_NAME)
    old_handlers = logger.handlers[:]
    old_level = logger.level
    buffer = io.StringIO()
    handler = logging.StreamHandler(buffer)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.handlers = [handler]
    logger.setLevel(logging.DEBUG)
    try:
        func()
    finally:
        logger.handlers = old_handlers
        logger.setLevel(old_level)
    return [json.loads(line) for line in buffer.getvalue().splitlines() if line.strip()]


class LogEventStructureTests(unittest.TestCase):
    def test_common_fields_present(self):
        records = _capture_events(lambda: log_event(
            "INFO", "request_received", "req-1", "rec-9", segmentCount=3))

        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["process"], "chart-agent")
        self.assertEqual(record["category"], "chart")
        self.assertEqual(record["event"], "request_received")
        self.assertEqual(record["level"], "info")
        self.assertEqual(record["correlationId"], "req-1")
        self.assertEqual(record["segmentCount"], 3)
        # UTC ISO 8601 with milliseconds and a Z suffix.
        self.assertTrue(record["ts"].endswith("Z"))
        self.assertIn(".", record["ts"])

    def test_all_five_levels_supported_case_insensitive(self):
        records = _capture_events(lambda: [
            log_event(level, "stage") for level in
            ["DEBUG", "info", "Warning", "ERROR", "critical"]])

        self.assertEqual(
            [r["level"] for r in records],
            ["debug", "info", "warning", "error", "critical"])

    def test_unknown_level_falls_back_to_info(self):
        records = _capture_events(lambda: log_event("verbose", "stage"))
        self.assertEqual(records[0]["level"], "info")

    def test_recording_id_only_logged_as_hash(self):
        raw_id = "550e8400-e29b-41d4-a716-446655440000"
        records = _capture_events(lambda: log_event("INFO", "stage", "req-1", raw_id))

        self.assertEqual(records[0]["recording"], recording_hash(raw_id))
        self.assertNotIn(raw_id, json.dumps(records[0]))

    def test_optional_fields_omitted_when_absent(self):
        records = _capture_events(lambda: log_event("INFO", "stage"))

        record = records[0]
        self.assertNotIn("correlationId", record)
        self.assertNotIn("recording", record)

    def test_correlation_id_stable_across_stages(self):
        def emit():
            for stage in ["prepare_transcript", "extract_structured", "render"]:
                log_event("INFO", stage, "req-constant", "rec-1")

        records = _capture_events(emit)
        self.assertEqual({r["correlationId"] for r in records}, {"req-constant"})


class SafeErrorFieldsTests(unittest.TestCase):
    def test_no_raw_exception_text(self):
        class FakeError(Exception):
            code = "TIMEOUT"

        fields = safe_error_fields(FakeError("sk-secret transcript body"))
        self.assertEqual(fields["errorType"], "FakeError")
        self.assertEqual(fields["errorCode"], "TIMEOUT")
        self.assertEqual(fields["message"], "模型调用超时")
        self.assertNotIn("sk-secret", json.dumps(fields, ensure_ascii=False))


class MessageRedactionTests(unittest.TestCase):
    def test_credentials_redacted(self):
        records = _capture_events(lambda: log_event(
            "ERROR", "stage",
            message="failed with Bearer abc.def.ghi and key=sk-1234567890abcdef"))

        message = records[0]["message"]
        self.assertNotIn("abc.def.ghi", message)
        self.assertNotIn("sk-1234567890abcdef", message)
        self.assertIn("[REDACTED]", message)

    def test_presigned_url_signature_redacted(self):
        records = _capture_events(lambda: log_event(
            "WARNING", "stage",
            message="upload https://oss.example.com/bucket/file.wav?OSSAccessKeyId=LTAI4G&Signature=abc123&Expires=9999 failed"))

        message = records[0]["message"]
        self.assertNotIn("abc123", message)
        self.assertNotIn("LTAI4G", message)

    def test_message_truncated_to_200_chars(self):
        records = _capture_events(lambda: log_event("INFO", "stage", message="x" * 500))
        self.assertEqual(len(records[0]["message"]), 200)


if __name__ == "__main__":
    unittest.main()
