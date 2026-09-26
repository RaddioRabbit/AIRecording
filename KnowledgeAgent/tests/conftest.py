import time

import pytest


@pytest.fixture(autouse=True)
def _pinned_timezone(monkeypatch):
    """Keep local-date conversions deterministic on every dev machine."""
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    yield
    time.tzset()
