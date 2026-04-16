"""Unified LLM dispatch via litellm (D-40).

This module NEVER calls provider-native SDKs. The point of D-40 is a single
error taxonomy and a single ``{provider}/{model}`` model-string convention.
If a future provider requires a feature litellm cannot express, add it to
litellm upstream rather than branching here — otherwise the Router's retry
and budget logic (Phase 3) would need N error-handling paths instead of one.

API keys arrive per-request (D-37) and are passed directly to
``litellm.completion(api_key=...)`` so they never touch the environment or
the company directory. They live in request-scope memory only.
"""
import asyncio
from typing import Optional

import litellm


# WR-11: litellm provider-string prefixes we must NOT re-prefix. Anything
# else with a slash (e.g. Ollama's "hf.co/user/model" HuggingFace-hosted
# tags) still needs the `{provider}/` prefix so litellm routes correctly.
_KNOWN_PROVIDER_PREFIXES = (
    "openrouter/",
    "together_ai/",
    "bedrock/",
    "anthropic/",
    "openai/",
    "ollama/",
    "gemini/",
    "vertex_ai/",
    "groq/",
    "mistral/",
)


async def run_task(
    ctx: dict,
    provider: str,
    model: str,
    api_key: Optional[str],
    timeout_seconds: int,
) -> dict:
    # litellm provider-string convention: "{provider}/{model}" unless the
    # caller already supplied a known-provider-slashed form.
    if any(model.startswith(p) for p in _KNOWN_PROVIDER_PREFIXES):
        model_str = model
    else:
        model_str = f"{provider}/{model}"
    kwargs = {
        "model": model_str,
        "messages": ctx["messages"],
        "timeout": timeout_seconds,
    }
    if api_key:
        kwargs["api_key"] = api_key  # D-37: per-request only, never env var.

    # litellm.completion is synchronous; run it in the default executor so it
    # doesn't block the uvicorn event loop.
    loop = asyncio.get_running_loop()
    response = await loop.run_in_executor(
        None, lambda: litellm.completion(**kwargs)
    )
    return {
        "completion": response["choices"][0]["message"]["content"],
        "usage": response.get("usage", {}),
        "model": response.get("model", model_str),
        # Internal-use: routes.py pops this before serializing RunResponse.
        # litellm.completion_cost needs the original response object.
        "_response_obj": response,
    }
