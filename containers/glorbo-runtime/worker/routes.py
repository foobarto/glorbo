"""HTTP routes — ``POST /run`` and ``POST /cancel`` (D-36, D-42).

``/run``:
  * Load task context from the bind-mounted filesystem (D-36: Python reads
    markdown directly — the filesystem is the source of truth on both sides
    of the container boundary).
  * Dispatch via ``worker.dispatch.run_task`` which goes through litellm
    (D-40 — the unified provider layer).
  * Enforce per-request timeout with ``asyncio.wait_for``.
  * Track the live task so ``/cancel`` can abort it.

``/cancel`` (D-42):
  * Look up the live task by ``request_id`` and call ``task.cancel()``.
  * Returns ``cancelled=False`` when no matching live task exists.
"""
import asyncio
from typing import Dict, List, Optional

from fastapi import APIRouter
from pydantic import BaseModel

from worker.context import load_task_context
from worker.dispatch import run_task
from worker.usage import write_usage_report

router = APIRouter()

# Track in-flight tasks so /cancel can abort them. Keyed by request_id; the
# /run handler pops the entry in its ``finally`` block so dead requests don't
# accumulate (D-42 cleanup).
_live_tasks: Dict[str, asyncio.Task] = {}


class RunRequest(BaseModel):
    task_path: str
    provider: str
    model: str
    api_key: Optional[str] = None
    skills: List[str] = []
    timeout_seconds: Optional[int] = 300
    request_id: str
    # Phase 3 additions (additive — preserves Phase 2 D-36 stability invariant)
    skills_resolved: List[str] = []  # D-34: full markdown bodies for injection
    agent_slug: str  # Required: identifies the agent for usage report path
    outbox_root: str = "/company"  # Bind-mount root; tests override


class RunResponse(BaseModel):
    ok: bool
    result: Optional[dict] = None
    error: Optional[str] = None


def _scrub(text: str, api_key: Optional[str]) -> str:
    """CR-07: strip the request's api_key from any error text before it
    escapes the worker. litellm's provider shims have historically echoed
    request kwargs into exception messages; D-37 says keys live in
    request-scope memory only and must never be logged or audited.
    """
    if api_key and api_key in text:
        return text.replace(api_key, "[REDACTED]")
    return text


@router.post("/run", response_model=RunResponse)
async def run(req: RunRequest) -> RunResponse:
    # CR-05: reject duplicate request_id up-front so two concurrent /run
    # calls with the same id can't clobber each other's _live_tasks entry.
    if req.request_id in _live_tasks:
        return RunResponse(ok=False, error="duplicate request_id")

    try:
        ctx = load_task_context(req.task_path, req.skills, req.skills_resolved)
    except FileNotFoundError as exc:
        return RunResponse(ok=False, error=str(exc))

    timeout = req.timeout_seconds or 300
    task = asyncio.ensure_future(
        run_task(ctx, req.provider, req.model, req.api_key, timeout)
    )
    _live_tasks[req.request_id] = task
    try:
        # CR-05: shield the task from wait_for's own cancel on timeout so
        # /cancel can distinguish "timed out" from "cancelled by caller".
        result = await asyncio.wait_for(asyncio.shield(task), timeout=timeout)
        # D-24: write usage report AFTER success only (not on failure paths)
        try:
            _response_obj = result.pop("_response_obj", None)
            if _response_obj is not None:
                task_id = req.task_path.rsplit("/", 1)[-1].removesuffix(".md")
                write_usage_report(
                    outbox_root=req.outbox_root,
                    agent_slug=req.agent_slug,
                    request_id=req.request_id,
                    task_id=task_id,
                    provider=req.provider,
                    model=req.model,
                    response=_response_obj,
                )
        except Exception:  # noqa: BLE001 — usage write failure must not fail the run
            pass
        return RunResponse(ok=True, result=result)
    except asyncio.TimeoutError:
        task.cancel()
        return RunResponse(ok=False, error="timeout")
    except asyncio.CancelledError:
        return RunResponse(ok=False, error="cancelled")
    except Exception as exc:  # noqa: BLE001 — surface any provider error
        return RunResponse(ok=False, error=_scrub(str(exc), req.api_key))
    finally:
        _live_tasks.pop(req.request_id, None)


class CancelRequest(BaseModel):
    request_id: str


@router.post("/cancel")
async def cancel(req: CancelRequest) -> dict:
    task = _live_tasks.get(req.request_id)
    if task and not task.done():
        task.cancel()
        return {"ok": True, "cancelled": True}
    return {"ok": True, "cancelled": False, "reason": "no_live_task"}
