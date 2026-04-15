"""FastAPI app factory for the Glorbo agent worker.

Bound by uvicorn over a Unix domain socket at ``/run/agent.sock``. The socket
is host-bind-mounted from ``~/.glorbo/runtime/sockets/<company>/<agent>.sock``
(D-34). Elixir's ``Glorbo.Container.WorkerClient`` is the sole client.

``docs_url`` and ``redoc_url`` are disabled — the worker has no human-facing
HTML; FastAPI's /docs would only widen surface on a socket an agent process
can also read inside the container.
"""
from fastapi import FastAPI

from worker.routes import router

app = FastAPI(title="glorbo-agent-worker", docs_url=None, redoc_url=None)
app.include_router(router)
