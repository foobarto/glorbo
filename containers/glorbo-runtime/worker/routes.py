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


class RunResponse(BaseModel):
    ok: bool
    result: Optional[dict] = None
    error: Optional[str] = None


@router.post("/run", response_model=RunResponse)
async def run(req: RunRequest) -> RunResponse:
    try:
        ctx = load_task_context(req.task_path, req.skills)
    except FileNotFoundError as exc:
        return RunResponse(ok=False, error=str(exc))

    timeout = req.timeout_seconds or 300
    task = asyncio.create_task(
        run_task(ctx, req.provider, req.model, req.api_key, timeout)
    )
    _live_tasks[req.request_id] = task
    try:
        result = await asyncio.wait_for(task, timeout=timeout)
        return RunResponse(ok=True, result=result)
    except asyncio.TimeoutError:
        return RunResponse(ok=False, error="timeout")
    except asyncio.CancelledError:
        return RunResponse(ok=False, error="cancelled")
    except Exception as exc:  # noqa: BLE001 — surface any provider error
        return RunResponse(ok=False, error=str(exc))
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
