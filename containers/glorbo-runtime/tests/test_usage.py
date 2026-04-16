"""Tests for worker/usage.py — usage report writer (D-24, D-25)."""
import json
from pathlib import Path
from unittest.mock import MagicMock

import pytest


def test_write_usage_report_creates_file(tmp_path):
    """Test 5: write_usage_report creates the JSON file with all required keys."""
    from worker.usage import write_usage_report

    response = MagicMock()
    response.get = lambda key, default=None: {
        "usage": MagicMock(
            prompt_tokens=100,
            completion_tokens=50,
            total_tokens=150,
        ),
    }.get(key, default)
    response.usage = MagicMock(
        prompt_tokens=100,
        completion_tokens=50,
        total_tokens=150,
    )

    def fake_cost(**kwargs):
        return 0.0125

    write_usage_report(
        outbox_root=str(tmp_path),
        agent_slug="engineer",
        request_id="req-001",
        task_id="task-001",
        provider="anthropic",
        model="claude-3-5-sonnet-20241022",
        response=response,
        cost_fn=fake_cost,
    )

    usage_file = (
        tmp_path / "agents" / "engineer" / "outbox" / "usage" / "req-001.json"
    )
    assert usage_file.exists()

    data = json.loads(usage_file.read_text())
    assert data["task_id"] == "task-001"
    assert data["request_id"] == "req-001"
    assert data["provider"] == "anthropic"
    assert data["model"] == "claude-3-5-sonnet-20241022"
    assert data["prompt_tokens"] == 100
    assert data["completion_tokens"] == 50
    assert data["total_tokens"] == 150
    assert data["cost_usd"] == 0.0125
    assert data["cost_usd_cents"] == 1
    assert "timestamp" in data


def test_write_usage_report_none_cost_coercion(tmp_path):
    """Test 6: When cost_fn returns None, cost_usd is 0.0 (Pitfall A2)."""
    from worker.usage import write_usage_report

    response = MagicMock()
    response.usage = MagicMock(
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
    )

    def fake_cost(**kwargs):
        return None

    write_usage_report(
        outbox_root=str(tmp_path),
        agent_slug="ceo",
        request_id="req-002",
        task_id="task-002",
        provider="ollama",
        model="llama3.2:1b",
        response=response,
        cost_fn=fake_cost,
    )

    usage_file = tmp_path / "agents" / "ceo" / "outbox" / "usage" / "req-002.json"
    data = json.loads(usage_file.read_text())
    assert data["cost_usd"] == 0.0
    assert data["cost_usd_cents"] == 0


def test_write_usage_report_tiny_cost(tmp_path):
    """Test 7: cost_usd 0.000045 rounds to 0 cents."""
    from worker.usage import write_usage_report

    response = MagicMock()
    response.usage = MagicMock(
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
    )

    def fake_cost(**kwargs):
        return 0.000045

    write_usage_report(
        outbox_root=str(tmp_path),
        agent_slug="eng",
        request_id="req-003",
        task_id="task-003",
        provider="openai",
        model="gpt-4",
        response=response,
        cost_fn=fake_cost,
    )

    usage_file = tmp_path / "agents" / "eng" / "outbox" / "usage" / "req-003.json"
    data = json.loads(usage_file.read_text())
    assert data["cost_usd"] == 0.000045
    assert data["cost_usd_cents"] == 0


def test_write_usage_report_125_cents(tmp_path):
    """Test 8: cost_usd 0.0125 rounds to 1 cent."""
    from worker.usage import write_usage_report

    response = MagicMock()
    response.usage = MagicMock(
        prompt_tokens=1000,
        completion_tokens=500,
        total_tokens=1500,
    )

    def fake_cost(**kwargs):
        return 0.0125

    write_usage_report(
        outbox_root=str(tmp_path),
        agent_slug="eng",
        request_id="req-004",
        task_id="task-004",
        provider="anthropic",
        model="claude-3-5-sonnet",
        response=response,
        cost_fn=fake_cost,
    )

    usage_file = tmp_path / "agents" / "eng" / "outbox" / "usage" / "req-004.json"
    data = json.loads(usage_file.read_text())
    assert data["cost_usd"] == 0.0125
    assert data["cost_usd_cents"] == 1
