"""Tests for worker/routes.py — /run endpoint extensions (D-34, D-36)."""
import json
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from fastapi.testclient import TestClient


def test_run_request_default_skills_resolved():
    """Test 1: RunRequest parses with skills_resolved == [] by default."""
    from worker.routes import RunRequest

    req = RunRequest(
        task_path="t",
        provider="ollama",
        model="x",
        request_id="r1",
        agent_slug="ceo",
    )
    assert req.skills_resolved == []


def test_run_request_with_skills_resolved():
    """Test 2: RunRequest parses with skills_resolved populated."""
    from worker.routes import RunRequest

    req = RunRequest(
        task_path="t",
        provider="ollama",
        model="x",
        request_id="r2",
        agent_slug="ceo",
        skills_resolved=["# skill1\nbody1", "# skill2\nbody2"],
    )
    assert req.skills_resolved == ["# skill1\nbody1", "# skill2\nbody2"]


def test_run_request_without_skills_resolved_still_works():
    """Test 10: Phase 2 D-36 backward compat — no skills_resolved field still works."""
    from worker.routes import RunRequest

    req = RunRequest(
        task_path="t",
        provider="p",
        model="m",
        request_id="r",
        agent_slug="a",
    )
    assert req.skills_resolved == []
    assert req.outbox_root == "/company"


def test_run_request_agent_slug_required():
    """agent_slug is required — omitting it should raise validation error."""
    from pydantic import ValidationError

    from worker.routes import RunRequest

    with pytest.raises(ValidationError):
        RunRequest(
            task_path="t",
            provider="p",
            model="m",
            request_id="r",
        )


def test_load_task_context_with_skills_resolved(tmp_path):
    """Test 3: skills_resolved injects into system prompt."""
    from worker.context import load_task_context

    # Create a minimal task file
    agent_dir = tmp_path / "company" / "agents" / "eng"
    agent_dir.mkdir(parents=True)
    (agent_dir / "agent.md").write_text("---\nrole: engineer\n---\nYou are an engineer.")

    task_dir = agent_dir / "inbox"
    task_dir.mkdir()
    task_file = task_dir / "task-01.md"
    task_file.write_text("---\ntitle: test\n---\nDo the thing.")

    ctx = load_task_context(str(task_file), skills=[], skills_resolved=["FOO BAR"])
    system_msg = ctx["messages"][0]
    assert system_msg["role"] == "system"
    assert "FOO BAR" in system_msg["content"]


def test_load_task_context_empty_skills_resolved(tmp_path):
    """Test 4: Empty skills_resolved does NOT add Skills header."""
    from worker.context import load_task_context

    agent_dir = tmp_path / "company" / "agents" / "eng"
    agent_dir.mkdir(parents=True)
    (agent_dir / "agent.md").write_text("---\nrole: engineer\n---\nYou are an engineer.")

    task_dir = agent_dir / "inbox"
    task_dir.mkdir()
    task_file = task_dir / "task-01.md"
    task_file.write_text("---\ntitle: test\n---\nDo the thing.")

    ctx = load_task_context(str(task_file), skills=[], skills_resolved=[])
    system_msg = ctx["messages"][0]
    assert "Skills:" not in system_msg["content"]
    assert "You have access to the following skills" not in system_msg["content"]
