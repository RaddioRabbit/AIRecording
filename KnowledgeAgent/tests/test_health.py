from fastapi.testclient import TestClient

import main
from main import API_VERSION, SERVICE_VERSION, app


def test_health_returns_exact_service_metadata():
    response = TestClient(app).get("/health")

    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "apiVersion": API_VERSION,
        "serviceVersion": SERVICE_VERSION,
        "indexVersion": 1,
    }


def test_entry_point_exposes_service_versions():
    assert API_VERSION == "1.0"
    assert SERVICE_VERSION == "1.1.0"


def test_entry_point_uses_port_environment(monkeypatch):
    calls = []
    monkeypatch.setenv("PORT", "18766")
    monkeypatch.setattr(main.uvicorn, "run", lambda *args, **kwargs: calls.append((args, kwargs)))
    monkeypatch.setattr(main, "__name__", "__main__")

    # Execute only the small launcher branch, without starting a socket server.
    exec(compile(open(main.__file__, encoding="utf-8").read(), main.__file__, "exec"), main.__dict__)

    assert calls == [((app,), {"host": "127.0.0.1", "port": 18766})]
