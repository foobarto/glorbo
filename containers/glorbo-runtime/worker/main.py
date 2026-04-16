"""FastAPI app factory for the Glorbo agent worker.

Bound by uvicorn over a Unix domain socket at ``/run/agent.sock``. The socket
is host-bind-mounted from ``~/.glorbo/runtime/sockets/<company>/<agent>.sock``
(D-34). Elixir's ``Glorbo.Container.WorkerClient`` is the sole client.

``docs_url`` and ``redoc_url`` are disabled — the worker has no human-facing
HTML; FastAPI's /docs would only widen surface on a socket an agent process
can also read inside the container.
"""
import litellm
from fastapi import FastAPI

from worker.routes import router

# CR-07: belt-and-braces — litellm defaults are quiet but explicit is safer.
# Keeps request kwargs (including api_key) out of the verbose debug output
# that older versions occasionally emitted on exception.
litellm.suppress_debug_info = True
litellm.set_verbose = False

# IN-14: disable /openapi.json too; the HTML UIs are off (docs_url/redoc_url)
# but the OpenAPI JSON would still enumerate routes for an agent process
# sharing the socket inside the container.
app = FastAPI(
    title="glorbo-agent-worker",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
app.include_router(router)
