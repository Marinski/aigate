"""FastAPI app — OpenAI-compatible /v1/audio/transcriptions + resource-mgmt API.

Endpoints (mirror the speaches surface where possible so the LiteLLM resource
manager can drive both with the same client code):

  GET    /healthz                          unauthenticated liveness
  GET    /v1/models                        list configured model_ids
  GET    /api/ps                           list currently loaded model_ids
  DELETE /api/ps/{model_id}                evict one model from VRAM/RAM
  POST   /unload                           evict all loaded models
  POST   /v1/audio/transcriptions          OpenAI-compatible transcription

The DELETE /api/ps/{model_id} path accepts URL-encoded model_ids so the LiteLLM
resource manager's existing `model_id.replace("/", "%2F")` call works against
both speaches and this service.
"""

from __future__ import annotations

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import unquote

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

from . import config
from .audio import AudioConversionError, to_wav_16k_mono
from .logging import configure as configure_logging
from .models import build_backends
from .models.base import TranscribeResult


_VERBOSE_FORMATS = {"verbose_json", "srt", "vtt"}


log = logging.getLogger("asr_canary.server")


def _resolve_device(req: str) -> str:
    if req != "auto":
        return req
    try:
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    except ImportError:
        return "cpu"


REGISTRY = config.load_registry()
DEVICE = _resolve_device(config.DEVICE)
BACKENDS = build_backends(REGISTRY, DEVICE)


async def _idle_sweeper() -> None:
    """Unload backends idle longer than ASR_CANARY_MODEL_TTL."""
    while True:
        try:
            await asyncio.sleep(config.SWEEPER_INTERVAL_SECONDS)
            ttl = config.MODEL_IDLE_TIMEOUT_SECONDS
            if ttl <= 0:
                continue
            for model_id, backend in BACKENDS.items():
                if not backend.loaded():
                    continue
                last = backend.last_used_secs_ago()
                if last is None:
                    continue
                if last < ttl:
                    continue
                log.info(
                    "idle sweeper: unloading %s (idle %.1fs >= %.1fs)",
                    model_id,
                    last,
                    ttl,
                )
                try:
                    await backend.unload()
                except Exception:  # noqa: BLE001
                    log.exception("idle sweeper: unload %s failed", model_id)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("idle sweeper iteration failed")


_sweeper_task: asyncio.Task[None] | None = None


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    log.info(
        "asr-canary starting: device=%s models=%s ttl=%.0fs",
        DEVICE,
        list(BACKENDS.keys()),
        config.MODEL_IDLE_TIMEOUT_SECONDS,
    )

    for model_id in config.PRELOAD:
        if model_id not in BACKENDS:
            log.warning("preload: unknown model %s — skipping", model_id)
            continue
        log.info("preload: %s", model_id)
        try:
            await BACKENDS[model_id].get_model()
        except Exception:  # noqa: BLE001
            log.exception("preload %s failed", model_id)

    global _sweeper_task
    _sweeper_task = asyncio.create_task(_idle_sweeper(), name="asr-canary-sweeper")
    try:
        yield
    finally:
        if _sweeper_task is not None:
            _sweeper_task.cancel()
            try:
                await _sweeper_task
            except (asyncio.CancelledError, Exception):
                pass


app = FastAPI(
    title="asr-canary",
    description=(
        "NeMo Canary ASR wrapper — OpenAI-compatible /v1/audio/transcriptions "
        "over canary-180m-flash, canary-1b-flash, canary-qwen-2.5b. "
        "Lazy-loads models on first request, idle-unloads after ASR_CANARY_MODEL_TTL."
    ),
    lifespan=_lifespan,
)


@app.get("/healthz")
def healthz() -> dict[str, Any]:
    return {"ok": True, "device": DEVICE, "models": list(BACKENDS.keys())}


@app.get("/v1/models")
def list_models() -> dict[str, Any]:
    return {
        "object": "list",
        "data": [
            {"id": mid, "object": "model", "owned_by": "asr-canary"}
            for mid in BACKENDS.keys()
        ],
    }


@app.get("/api/ps")
def list_loaded() -> dict[str, Any]:
    return {
        "models": [
            {
                "id": mid,
                "repo": BACKENDS[mid].repo,
                "loaded": BACKENDS[mid].loaded(),
                "idle_seconds": BACKENDS[mid].last_used_secs_ago(),
            }
            for mid in BACKENDS.keys()
            if BACKENDS[mid].loaded()
        ]
    }


@app.delete("/api/ps/{model_id:path}")
async def unload_one(model_id: str) -> JSONResponse:
    decoded = unquote(model_id)
    backend = BACKENDS.get(decoded)
    if backend is None:
        return JSONResponse(
            {"detail": f"unknown model {decoded!r}"}, status_code=404
        )
    if not backend.loaded():
        return JSONResponse({"detail": "not loaded"}, status_code=404)
    await backend.unload()
    return JSONResponse({"unloaded": decoded}, status_code=200)


@app.post("/unload")
async def unload_all() -> dict[str, Any]:
    unloaded = []
    for model_id, backend in BACKENDS.items():
        if not backend.loaded():
            continue
        try:
            await backend.unload()
            unloaded.append(model_id)
        except Exception:  # noqa: BLE001
            log.exception("unload %s failed", model_id)
    return {"unloaded": unloaded}


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(...),
    language: str | None = Form(default=None),
    response_format: str = Form(default="json"),
    prompt: str | None = Form(default=None),
    temperature: float | None = Form(default=None),
    timestamp_granularities: list[str] = Form(
        default=[], alias="timestamp_granularities[]"
    ),
) -> Any:
    del prompt, temperature  # accepted for OpenAI compatibility, not used

    backend = BACKENDS.get(model)
    if backend is None:
        raise HTTPException(
            status_code=404,
            detail=f"unknown model {model!r}; configured: {list(BACKENDS.keys())}",
        )

    # Evict sibling backends — all asr-canary models compete for the same
    # GPU/RAM, so loading a new one while another is resident risks OOM.
    # Ollama does this implicitly; we do it explicitly per request.
    siblings = [
        (mid, b) for mid, b in BACKENDS.items() if mid != model and b.loaded()
    ]
    if siblings:
        log.info(
            "evicting %d sibling backend(s) before loading %s: %s",
            len(siblings),
            model,
            [mid for mid, _ in siblings],
        )
        await asyncio.gather(
            *(b.unload() for _, b in siblings), return_exceptions=True
        )

    raw = await file.read()
    if len(raw) > config.MAX_UPLOAD_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"upload too large ({len(raw)} bytes > {config.MAX_UPLOAD_BYTES})",
        )

    original_name = file.filename or "audio"

    try:
        wav_path = await asyncio.to_thread(to_wav_16k_mono, raw, original_name)
        duration = await asyncio.to_thread(_wav_duration_seconds, wav_path)
    except AudioConversionError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    entry = REGISTRY[model]
    source_lang = language or entry.get("default_source_lang")
    target_lang = entry.get("default_target_lang", source_lang)
    task = entry.get("default_task", "asr")

    fmt = (response_format or "json").lower()
    # Timestamps are needed for verbose_json (always) and srt/vtt (built from
    # segments). Cheaper formats (text/json) skip the timestamp pass.
    needs_timestamps = fmt in _VERBOSE_FORMATS

    try:
        result = await backend.transcribe(
            wav_path,
            source_lang=source_lang,
            target_lang=target_lang,
            task=task,
            with_timestamps=needs_timestamps,
        )
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass

    if duration is not None and result.duration is None:
        result.duration = duration
    if result.language is None:
        result.language = source_lang

    if fmt in ("text", "txt"):
        return PlainTextResponse(result.text)
    if fmt == "verbose_json":
        return _verbose_json_response(result, task=task, granularities=timestamp_granularities)
    if fmt == "srt":
        return PlainTextResponse(
            _segments_to_srt(_segments_for_subtitles(result)),
            media_type="application/x-subrip",
        )
    if fmt == "vtt":
        return PlainTextResponse(
            _segments_to_vtt(_segments_for_subtitles(result)),
            media_type="text/vtt",
        )
    return {"text": result.text}


def _wav_duration_seconds(wav_path: str) -> float | None:
    """Return duration of a 16-bit mono PCM WAV in seconds."""
    import wave

    try:
        with wave.open(wav_path, "rb") as wf:
            frames = wf.getnframes()
            rate = wf.getframerate()
            if not rate:
                return None
            return frames / float(rate)
    except (OSError, wave.Error):
        return None


def _verbose_json_response(
    result: TranscribeResult,
    *,
    task: str,
    granularities: list[str],
) -> dict[str, Any]:
    """Build OpenAI-shaped verbose_json. Whisper-only fields are null-filled
    so clients reading e.g. segment.avg_logprob don't crash.

    Note on granularities: OpenAI defaults to `segment` only, with `word`
    opt-in via `timestamp_granularities[]=word`. The LiteLLM proxy collapses
    repeated form fields to a single value (last wins), so a client asking
    for both via LiteLLM arrives here as `['word']`. To avoid that footgun
    we always emit both — it's free for us since the backend computes both
    in the same pass, and clients that only read one are unaffected.
    """
    del granularities  # always emit both; see docstring

    segments_out: list[dict] = []
    for seg in result.segments:
        segments_out.append(
            {
                "id": seg.get("id", 0),
                "seek": 0,
                "start": seg["start"],
                "end": seg["end"],
                "text": seg.get("text", ""),
                "tokens": [],
                "temperature": 0.0,
                "avg_logprob": None,
                "compression_ratio": None,
                "no_speech_prob": None,
            }
        )

    return {
        "task": "translate" if task == "ast" else "transcribe",
        "language": result.language or "en",
        "duration": result.duration if result.duration is not None else 0.0,
        "text": result.text,
        "segments": segments_out,
        "words": list(result.words),
    }


def _segments_for_subtitles(result: TranscribeResult) -> list[dict]:
    if result.segments:
        return result.segments
    # Fallback: one segment spanning the full audio duration.
    end = result.duration if result.duration is not None else 0.0
    return [{"id": 0, "start": 0.0, "end": end, "text": result.text}]


def _format_srt_timestamp(seconds: float) -> str:
    total_ms = int(round(seconds * 1000))
    hours, rem = divmod(total_ms, 3_600_000)
    minutes, rem = divmod(rem, 60_000)
    secs, ms = divmod(rem, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{ms:03d}"


def _format_vtt_timestamp(seconds: float) -> str:
    return _format_srt_timestamp(seconds).replace(",", ".")


def _segments_to_srt(segments: list[dict]) -> str:
    lines: list[str] = []
    for idx, seg in enumerate(segments, start=1):
        lines.append(str(idx))
        lines.append(
            f"{_format_srt_timestamp(seg['start'])} --> {_format_srt_timestamp(seg['end'])}"
        )
        lines.append(str(seg.get("text", "")).strip())
        lines.append("")
    return "\n".join(lines)


def _segments_to_vtt(segments: list[dict]) -> str:
    lines: list[str] = ["WEBVTT", ""]
    for seg in segments:
        lines.append(
            f"{_format_vtt_timestamp(seg['start'])} --> {_format_vtt_timestamp(seg['end'])}"
        )
        lines.append(str(seg.get("text", "")).strip())
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    configure_logging()
    import uvicorn

    log.info("asr-canary: starting on %s:%d", config.HOST, config.PORT)
    uvicorn.run(app, host=config.HOST, port=config.PORT, log_config=None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
