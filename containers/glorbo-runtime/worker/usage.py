"""Usage report writer (D-24, D-25).

Writes ``outbox/usage/<request_id>.json`` AFTER the result file is written.
The report contains only allow-listed keys (T-03-03 mitigation — no message
content, no api_key, no free-form serialization of the response object).

Cost source: ``litellm.completion_cost`` (D-25). Ollama returns 0.0 because
the model isn't in litellm's cost DB — safe per D-25 ("Ollama reports
cost_usd: 0.0"). None is coerced to 0.0 (Pitfall A2).
"""
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Callable


def write_usage_report(
    outbox_root: str,
    agent_slug: str,
    request_id: str,
    task_id: str,
    provider: str,
    model: str,
    response,
    cost_fn: Optional[Callable] = None,
) -> None:
    """Write a usage report JSON to the agent's outbox/usage/ directory.

    Args:
        outbox_root: Root path for the company directory (e.g. /company).
        agent_slug: Agent identifier (e.g. "engineer").
        request_id: Unique request identifier (used as filename).
        task_id: Task identifier.
        provider: LLM provider name.
        model: Model identifier.
        response: The litellm response object (or compatible dict/mock).
        cost_fn: Cost function (defaults to litellm.completion_cost).
    """
    if cost_fn is None:
        from litellm import completion_cost
        cost_fn = completion_cost

    # Extract token usage from response
    usage = getattr(response, "usage", None)
    if usage is not None:
        prompt_tokens = getattr(usage, "prompt_tokens", 0) or 0
        completion_tokens = getattr(usage, "completion_tokens", 0) or 0
        total_tokens = getattr(usage, "total_tokens", 0) or 0
    else:
        prompt_tokens = 0
        completion_tokens = 0
        total_tokens = 0

    # Compute cost — coerce None to 0.0 (Pitfall A2)
    try:
        cost_usd = cost_fn(completion_response=response) or 0.0
    except Exception:
        cost_usd = 0.0

    cost_usd_cents = int(round(cost_usd * 100))

    # T-03-03: allow-list keyed schema only — no free-form serialization
    report = {
        "task_id": task_id,
        "request_id": request_id,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "provider": provider,
        "model": model,
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": total_tokens,
        "cost_usd": cost_usd,
        "cost_usd_cents": cost_usd_cents,
    }

    usage_dir = Path(outbox_root) / "agents" / agent_slug / "outbox" / "usage"
    usage_dir.mkdir(parents=True, exist_ok=True)
    (usage_dir / f"{request_id}.json").write_text(json.dumps(report))
