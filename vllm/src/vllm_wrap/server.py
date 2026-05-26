"""FastAPI app — OpenAI-compatible /v1/audio/transcriptions + /v1/chat/completions.

Endpoints (mirror the speaches / asr-canary surface so the LiteLLM resource
manager can drive all three with the same DELETE /api/ps/{model_id} call):

  GET    /healthz                          unauthenticated liveness
  GET    /v1/models                        list configured model_ids
  GET    /api/ps                           list currently loaded model_ids (0 or 1)
  DELETE /api/ps/{model_id}                kill the subprocess if model is loaded
  POST   /unload                           kill the subprocess unconditionally
  POST   /v1/audio/transcriptions          proxied to vllm serve
  POST   /v1/chat/completions              proxied to vllm serve (stream-capable)

Only one `vllm serve` subprocess is alive at a time — vLLM holds the whole
model in VRAM and switching means restart. The supervisor enforces this.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import unquote

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

from . import config
from .logging import configure as configure_logging
from .supervisor import Supervisor, SupervisorError


log = logging.getLogger("vllm_wrap.server")


REGISTRY = config.load_registry()
SUPERVISOR = Supervisor(REGISTRY)


async def _idle_sweeper() -> None:
    """Kill the subprocess if idle longer than VLLM_WRAP_MODEL_TTL."""
    while True:
        try:
            await asyncio.sleep(config.SWEEPER_INTERVAL_SECONDS)
            ttl = config.MODEL_IDLE_TIMEOUT_SECONDS
            if ttl <= 0:
                continue
            current = SUPERVISOR.loaded()
            if current is None:
                continue
            last = SUPERVISOR.last_used_secs_ago()
            if last is None or last < ttl:
                continue
            log.info(
                "idle sweeper: unloading %s (idle %.1fs >= %.1fs)",
                current,
                last,
                ttl,
            )
            try:
                await SUPERVISOR.unload()
            except Exception:  # noqa: BLE001
                log.exception("idle sweeper: unload failed")
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("idle sweeper iteration failed")


_sweeper_task: asyncio.Task[None] | None = None


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    log.info(
        "vllm starting: models=%s ttl=%.0fs subprocess_port=%d",
        list(REGISTRY.keys()),
        config.MODEL_IDLE_TIMEOUT_SECONDS,
        config.SUBPROCESS_PORT,
    )

    if config.PRELOAD:
        if config.PRELOAD in REGISTRY:
            log.info("preload: %s", config.PRELOAD)
            try:
                await SUPERVISOR.ensure(config.PRELOAD)
            except Exception:  # noqa: BLE001
                log.exception("preload %s failed", config.PRELOAD)
        else:
            log.warning("preload: unknown model %s — skipping", config.PRELOAD)

    global _sweeper_task
    _sweeper_task = asyncio.create_task(_idle_sweeper(), name="vllm-sweeper")
    try:
        yield
    finally:
        if _sweeper_task is not None:
            _sweeper_task.cancel()
            try:
                await _sweeper_task
            except (asyncio.CancelledError, Exception):
                pass
        try:
            await SUPERVISOR.unload()
        except Exception:  # noqa: BLE001
            log.exception("shutdown unload failed")


app = FastAPI(
    title="vllm",
    description=(
        "vLLM audio-LLM wrapper — supervises a single `vllm serve` subprocess "
        "and proxies OpenAI-compat /v1/audio/transcriptions + /v1/chat/completions. "
        "Lazy spawn on first request; idle-kill after VLLM_WRAP_MODEL_TTL."
    ),
    lifespan=_lifespan,
)


# ── liveness + introspection ──────────────────────────────────────────────


@app.get("/healthz")
def healthz() -> dict[str, Any]:
    return {
        "ok": True,
        "models": list(REGISTRY.keys()),
        "loaded": SUPERVISOR.loaded(),
    }


@app.get("/v1/models")
def list_models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {"id": mid, "object": "model", "owned_by": "vllm"}
            for mid in REGISTRY.keys()
        ],
    }


@app.get("/api/ps")
def list_loaded() -> dict[str, Any]:
    loaded = SUPERVISOR.loaded()
    if loaded is None:
        return {"models": []}
    return {
        "models": [
            {
                "id": loaded,
                "repo": REGISTRY[loaded]["repo"],
                "loaded": True,
                "idle_seconds": SUPERVISOR.last_used_secs_ago(),
            }
        ]
    }


@app.delete("/api/ps/{model_id:path}")
async def unload_one(model_id: str) -> JSONResponse:
    decoded = unquote(model_id)
    if decoded not in REGISTRY:
        return JSONResponse(
            {"detail": f"unknown model {decoded!r}"}, status_code=404
        )
    if SUPERVISOR.loaded() != decoded:
        return JSONResponse({"detail": "not loaded"}, status_code=404)
    await SUPERVISOR.unload()
    return JSONResponse({"unloaded": decoded}, status_code=200)


@app.post("/unload")
async def unload_all() -> dict[str, Any]:
    killed = await SUPERVISOR.unload()
    return {"unloaded": [killed] if killed else []}


# ── proxied OpenAI endpoints ──────────────────────────────────────────────


# Extracts `model` from a multipart form by splitting the body on the
# boundary delimiter (from the Content-Type header) and locating the part
# whose Content-Disposition has name="model". Avoids re-encoding the body
# AND avoids false positives from binary content matching `name="model"`.
_BOUNDARY_RE = re.compile(r'boundary=(?:"([^"]+)"|([^\s;]+))', re.IGNORECASE)
_PART_NAME_RE = re.compile(rb'Content-Disposition:[^\r\n]*name="([^"]+)"', re.IGNORECASE)


def _rewrite_multipart_field(
    body: bytes, content_type: str, field_name: str, new_value: bytes
) -> bytes:
    """Replace the value of a named multipart form field. No-op if absent.

    LiteLLM forces response_format=verbose_json on the transcriptions endpoint,
    but several vllm audio models (Qwen3-ASR) only support json/text. We
    normalize verbose_json -> json before forwarding to the subprocess.
    """
    bm = _BOUNDARY_RE.search(content_type)
    if not bm:
        return body
    boundary = (bm.group(1) or bm.group(2)).encode("ascii", errors="replace")
    delimiter = b"--" + boundary
    parts = body.split(delimiter)
    target = field_name.encode("ascii")
    for i, part in enumerate(parts):
        stripped = part.lstrip(b"\r\n")
        leading = part[: len(part) - len(stripped)]
        header_end = stripped.find(b"\r\n\r\n")
        if header_end < 0:
            continue
        headers = stripped[:header_end]
        name_match = _PART_NAME_RE.search(headers)
        if not name_match or name_match.group(1) != target:
            continue
        value_start = header_end + 4
        value_blob = stripped[value_start:]
        if value_blob.endswith(b"\r\n"):
            trailer = b"\r\n"
            value = value_blob[:-2]
        elif value_blob.endswith(b"\n"):
            trailer = b"\n"
            value = value_blob[:-1]
        else:
            trailer = b""
            value = value_blob
        if value.strip() == new_value:
            return body
        parts[i] = leading + headers + b"\r\n\r\n" + new_value + trailer
        return delimiter.join(parts)
    return body


def _extract_model_from_multipart(body: bytes, content_type: str) -> str | None:
    bm = _BOUNDARY_RE.search(content_type)
    if not bm:
        return None
    boundary = (bm.group(1) or bm.group(2)).encode("ascii", errors="replace")
    delimiter = b"--" + boundary
    parts = body.split(delimiter)
    for part in parts:
        # strip leading CRLF after the boundary
        stripped = part.lstrip(b"\r\n")
        # each part is: headers CRLF CRLF body CRLF
        header_end = stripped.find(b"\r\n\r\n")
        if header_end < 0:
            continue
        headers = stripped[:header_end]
        name_match = _PART_NAME_RE.search(headers)
        if not name_match or name_match.group(1) != b"model":
            continue
        value = stripped[header_end + 4 :]
        # trim trailing CRLF that precedes the next boundary
        if value.endswith(b"\r\n"):
            value = value[:-2]
        elif value.endswith(b"\n"):
            value = value[:-1]
        return value.decode("utf-8", errors="replace").strip()
    return None


@app.post("/v1/chat/completions")
async def chat_completions(request: Request) -> Response:
    body = await request.body()
    try:
        payload = json.loads(body)
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=f"invalid JSON: {exc}") from exc

    model_id = payload.get("model")
    if not isinstance(model_id, str) or not model_id:
        raise HTTPException(status_code=400, detail="missing 'model' field")

    entry = REGISTRY.get(model_id)
    if entry is None:
        raise HTTPException(
            status_code=404,
            detail=f"unknown model {model_id!r}; configured: {list(REGISTRY.keys())}",
        )
    if "chat" not in entry.get("endpoints", []):
        raise HTTPException(
            status_code=400,
            detail=f"model {model_id!r} does not support /v1/chat/completions",
        )

    try:
        await SUPERVISOR.ensure(model_id)
    except SupervisorError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    is_stream = bool(payload.get("stream"))
    return await _do_proxy(
        request,
        path="/v1/chat/completions",
        body=body,
        content_type="application/json",
        is_stream=is_stream,
    )


@app.post("/v1/audio/transcriptions")
async def transcriptions(request: Request) -> Response:
    body = await request.body()
    content_type = request.headers.get("content-type", "")
    if "multipart/form-data" not in content_type:
        raise HTTPException(
            status_code=415,
            detail=f"expected multipart/form-data, got {content_type!r}",
        )

    model_id = _extract_model_from_multipart(body, content_type)
    if not model_id:
        raise HTTPException(
            status_code=400, detail="missing 'model' form field"
        )

    entry = REGISTRY.get(model_id)
    if entry is None:
        raise HTTPException(
            status_code=404,
            detail=f"unknown model {model_id!r}; configured: {list(REGISTRY.keys())}",
        )
    if "transcriptions" not in entry.get("endpoints", []):
        raise HTTPException(
            status_code=400,
            detail=f"model {model_id!r} does not support /v1/audio/transcriptions",
        )

    try:
        await SUPERVISOR.ensure(model_id)
    except SupervisorError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    body = _rewrite_multipart_field(body, content_type, "response_format", b"json")

    return await _do_proxy(
        request,
        path="/v1/audio/transcriptions",
        body=body,
        content_type=content_type,
        is_stream=False,
    )


async def _do_proxy(
    request: Request,
    *,
    path: str,
    body: bytes,
    content_type: str,
    is_stream: bool,
) -> Response:
    upstream = f"http://127.0.0.1:{config.SUBPROCESS_PORT}{path}"
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length", "connection")
    }
    headers["content-type"] = content_type

    timeout = httpx.Timeout(config.REQUEST_TIMEOUT_SECONDS, connect=10.0)

    lease = SUPERVISOR.lease()
    lease.__enter__()

    if is_stream:
        client = httpx.AsyncClient(timeout=timeout)
        try:
            upstream_req = client.build_request(
                "POST", upstream, content=body, headers=headers
            )
            upstream_resp = await client.send(upstream_req, stream=True)
        except Exception:
            lease.__exit__(None, None, None)
            await client.aclose()
            raise

        async def _iter():
            try:
                async for chunk in upstream_resp.aiter_raw():
                    yield chunk
            finally:
                await upstream_resp.aclose()
                await client.aclose()
                lease.__exit__(None, None, None)

        return StreamingResponse(
            _iter(),
            status_code=upstream_resp.status_code,
            media_type=upstream_resp.headers.get("content-type"),
        )

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(upstream, content=body, headers=headers)
        return Response(
            content=r.content,
            status_code=r.status_code,
            media_type=r.headers.get("content-type"),
        )
    finally:
        lease.__exit__(None, None, None)


def main() -> int:
    configure_logging()
    import uvicorn

    log.info("vllm: starting on %s:%d", config.HOST, config.PORT)
    uvicorn.run(app, host=config.HOST, port=config.PORT, log_config=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
