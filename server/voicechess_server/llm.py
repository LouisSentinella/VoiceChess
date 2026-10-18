"""One streaming chat client for every backend.

Hosted (OpenRouter) and local (llama.cpp / Ollama) servers all speak the OpenAI
chat-completions protocol, so a backend is just a base URL, a model and an
optional key. Backends are tried in order until one starts streaming.
"""

from __future__ import annotations

import json
import logging
import os
from collections.abc import AsyncIterator
from dataclasses import dataclass, field

import httpx

log = logging.getLogger("voicechess.llm")

OPENROUTER_URL = "https://openrouter.ai/api/v1"
DEFAULT_OPENROUTER_MODEL = "anthropic/claude-haiku-5.5"
DEFAULT_LOCAL_URL = "http://127.0.0.1:8081/v1"


class LlmError(Exception):
    """No backend could answer (or the stream broke after it started)."""


@dataclass(frozen=True)
class Backend:
    name: str
    base_url: str
    model: str
    api_key: str | None = None
    extra_body: dict = field(default_factory=dict)
    connect_timeout: float = 3.0
    read_timeout: float = 30.0


def backends_from_env(env: dict[str, str] | None = None) -> list[Backend]:
    """`VOICECHESS_LLM` is an ordered, comma-separated list of `openrouter` and `local`.

    Unset means: openrouter first when OPENROUTER_API_KEY exists, then local.
    """
    env = dict(os.environ) if env is None else env
    key = env.get("OPENROUTER_API_KEY")
    wanted = [w.strip() for w in env.get("VOICECHESS_LLM", "").split(",") if w.strip()]
    if not wanted:
        wanted = (["openrouter"] if key else []) + ["local"]

    out = []
    for name in wanted:
        if name == "openrouter":
            if not key:
                log.warning("VOICECHESS_LLM lists openrouter but OPENROUTER_API_KEY is not set; skipping it")
                continue
            out.append(
                Backend(
                    "openrouter",
                    OPENROUTER_URL,
                    env.get("VOICECHESS_LLM_MODEL", DEFAULT_OPENROUTER_MODEL),
                    key,
                    # Short spoken answers: no hidden reasoning tokens before the first word.
                    extra_body={"reasoning": {"enabled": False}},
                )
            )
        elif name == "local":
            out.append(
                Backend(
                    "local",
                    env.get("VOICECHESS_LOCAL_LLM_URL", DEFAULT_LOCAL_URL),
                    env.get("VOICECHESS_LOCAL_LLM_MODEL", "local"),
                    read_timeout=60.0,
                )
            )
        else:
            raise ValueError(f"Unknown VOICECHESS_LLM backend {name!r}; use openrouter and/or local.")
    return out


class LlmClient:
    def __init__(self, backends: list[Backend], http: httpx.AsyncClient | None = None):
        self.backends = backends
        self._http = http or httpx.AsyncClient()

    async def close(self) -> None:
        await self._http.aclose()

    async def stream(self, messages: list[dict], max_tokens: int = 260) -> AsyncIterator[str]:
        """Yield text chunks. Falls back to the next backend only before the first token."""
        failures: list[str] = []
        for backend in self.backends:
            started = False
            try:
                async for chunk in self._stream_one(backend, messages, max_tokens):
                    started = True
                    yield chunk
                return
            except (httpx.HTTPError, LlmError) as e:
                if started:
                    raise LlmError(f"{backend.name} stream broke: {e}") from e
                log.warning("LLM backend %s failed: %s", backend.name, e)
                failures.append(f"{backend.name}: {e}")
        raise LlmError("; ".join(failures) or "No language model is configured.")

    async def _stream_one(self, b: Backend, messages: list[dict], max_tokens: int) -> AsyncIterator[str]:
        body = {
            "model": b.model,
            "messages": messages,
            "stream": True,
            "max_tokens": max_tokens,
            "temperature": 0.3,
            **b.extra_body,
        }
        headers = {"Authorization": f"Bearer {b.api_key}"} if b.api_key else {}
        timeout = httpx.Timeout(b.read_timeout, connect=b.connect_timeout)
        url = f"{b.base_url}/chat/completions"
        for attempt in (1, 2):
            async with self._http.stream("POST", url, json=body, headers=headers, timeout=timeout) as r:
                if r.status_code != 200:
                    detail = (await r.aread()).decode(errors="replace")[:200]
                    # Some models cannot run without reasoning; accept their default instead of failing.
                    if attempt == 1 and r.status_code == 400 and "reasoning" in detail.lower() and "reasoning" in body:
                        log.warning("%s needs reasoning on; retrying without the reasoning override", b.model)
                        body = {k: v for k, v in body.items() if k != "reasoning"}
                        continue
                    raise LlmError(f"HTTP {r.status_code} {detail}")
                async for line in r.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        return
                    try:
                        delta = json.loads(data)["choices"][0].get("delta", {})
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue
                    if text := delta.get("content"):
                        yield text
                return
