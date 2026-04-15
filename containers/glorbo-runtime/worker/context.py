"""Reads task.md + agent.md + skills/*.md from the bind-mounted /company/ tree.

D-36: the filesystem is the source of truth on both sides of the container
boundary. Elixir writes markdown; Python reads the same markdown directly —
nothing is copied over the wire.

Always uses ``yaml.safe_load`` (T-2-26 mitigation). Never ``yaml.load``.
"""
import os
from pathlib import Path
from typing import List, Tuple

import yaml


def load_task_context(task_path: str, skills: List[str]) -> dict:
    task_p = Path(task_path)
    if not task_p.exists():
        raise FileNotFoundError(f"task file not found: {task_path}")

    task_meta, task_body = _split_frontmatter(task_p.read_text())
    agent_md = _find_agent_md(task_p)
    if agent_md is not None:
        agent_meta, agent_prompt = _split_frontmatter(agent_md.read_text())
    else:
        agent_meta, agent_prompt = {}, ""
    skill_blocks = _load_skills(task_p, skills)

    system = agent_prompt
    if skill_blocks:
        system = (system + "\n\n" if system else "") + "\n\n".join(skill_blocks)

    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": task_body},
    ]
    return {"task_meta": task_meta, "agent_meta": agent_meta, "messages": messages}


def _split_frontmatter(text: str) -> Tuple[dict, str]:
    """Split a ``---\\n<yaml>\\n---\\n<body>`` markdown file.

    Uses ``yaml.safe_load`` exclusively (T-2-26).
    """
    if text.startswith("---\n"):
        parts = text.split("---\n", 2)
        if len(parts) == 3:
            _, fm, body = parts
            return yaml.safe_load(fm) or {}, body
    return {}, text


def _find_agent_md(task_path: Path):
    # /company/agents/<name>/inbox/<task>.md → /company/agents/<name>/agent.md
    parts = task_path.parts
    if "agents" in parts:
        idx = parts.index("agents")
        agent_dir = Path(*parts[: idx + 2])
        candidate = agent_dir / "agent.md"
        if candidate.exists():
            return candidate
    return None


def _load_skills(task_path: Path, skills: List[str]) -> List[str]:
    # /company/skills/<name>.md
    parts = task_path.parts
    if "company" in parts:
        idx = parts.index("company")
        skills_dir = Path(*parts[: idx + 1]) / "skills"
        return [
            (skills_dir / f"{s}.md").read_text()
            for s in skills
            if (skills_dir / f"{s}.md").exists()
        ]
    return []
