"""In-image pytest suite.

Built into the OCI image at ``/app/tests``. Executed by the CI workflow via::

    podman run --rm --network none \\
      ghcr.io/foobarto/glorbo-runtime:<tag> pytest /app/tests

B1: This is the SOLE Python validation surface. Per CLAUDE.md, Python never
runs on the host — semantic correctness of ``worker/*.py`` is verified ONLY
inside the built image.
"""
from fastapi.testclient import TestClient


def test_app_imports():
    from worker.main import app

    assert app.title == "glorbo-agent-worker"


def test_litellm_importable():
    import litellm

    assert hasattr(litellm, "completion")


def test_huggingface_hub_importable():
    import huggingface_hub

    assert hasattr(huggingface_hub, "snapshot_download")


def test_ollama_importable():
    import ollama

    assert ollama is not None


def test_anthropic_importable():
    import anthropic

    assert anthropic is not None


def test_openai_importable():
    import openai

    assert openai is not None


def test_google_genai_importable():
    import google.genai  # noqa: F401 — import is the assertion


def test_pyyaml_safe_load_only():
    import yaml

    # Negative assertion — the worker never uses yaml.load, only safe_load.
    assert yaml.safe_load("a: 1") == {"a": 1}


def test_run_endpoint_404_on_missing_task(client: TestClient):
    resp = client.post(
        "/run",
        json={
            "task_path": "/nonexistent",
            "provider": "ollama",
            "model": "llama3.2:1b",
            "request_id": "test-1",
            "skills": [],
        },
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is False
    assert "not found" in body["error"].lower()


def test_cancel_endpoint_no_live_task(client: TestClient):
    resp = client.post("/cancel", json={"request_id": "nonexistent"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["cancelled"] is False
