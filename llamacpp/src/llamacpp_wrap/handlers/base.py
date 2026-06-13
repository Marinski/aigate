"""Handler protocol — implemented by per-model orchestration modules."""

from __future__ import annotations

from typing import Any, Awaitable, Callable, Protocol

from fastapi import Request
from fastapi.responses import Response


# The `forward` callable a Handler receives takes a fully-resolved payload
# (image URLs already data:-encoded, any non-llama-server fields stripped)
# and returns the upstream Response. The handler is free to call it 0..N
# times during a single client request.
Forward = Callable[[dict[str, Any]], Awaitable[Response]]


class Handler(Protocol):
    async def handle(
        self,
        *,
        request: Request,
        payload: dict[str, Any],
        forward: Forward,
    ) -> Response | None:
        """Run per-model orchestration for one client request.

        Args:
            request: the inbound FastAPI Request (for header passthrough).
            payload: the parsed OpenAI chat completions body. Handlers may
                mutate it freely — the wrapper does not re-use the
                pre-handler payload after calling .handle().
            forward: callable that sends a single completion to
                `llama-server` and returns its Response. Handlers use this
                to run the actual model call(s). For multi-page / multi-
                chunk inputs the handler builds one payload per chunk and
                calls forward per chunk, then stitches.

        Returns:
            Response: handler owns the round-trip; the wrapper returns
                this directly to the client.
            None: handler declined (the input doesn't match anything this
                handler knows how to orchestrate). The wrapper falls
                through to its default one-shot proxy path with the
                unmodified payload.
        """
        ...
