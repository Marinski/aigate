"""
CUDA/CPU resource manager for LiteLLM proxy.

Enforces two things:
1. Mutual exclusion — only one CUDA job (and one CPU job) at a time via
   asyncio.Semaphore(1).  A chat completion on ollama-cuda blocks until
   an in-flight sdcpp-cuda image generation finishes, and vice-versa.
2. Competing-group unload — before the request proceeds, all other groups
   on the same hardware are told to free VRAM/RAM.

Groups (CUDA):
  cuda-llm          : local-ollama-cuda-* models
  cuda-img          : local-sdcpp-cuda-* (sd.cpp image generation)
  cuda-tts          : local-qwen3-cuda-tts
  cuda-stt-speaches : local-speaches-cuda-*
  cuda-stt-canary   : local-asr-canary-cuda-*
  cuda-stt-talkies  : local-talkies-cuda-*
  cuda-vllm     : local-vllm-cuda-*  (audio-LLMs: Qwen3-ASR / Voxtral / Granite-Speech)

Groups (CPU):
  cpu-llm           : local-ollama-cpu-* models   (unload frees RAM)
  cpu-img           : local-sdcpp-cpu-* (sd.cpp image generation)
  cpu-tts           : local-speaches-kokoro-tts
  cpu-stt-speaches  : local-speaches-whisper-*, local-speaches-parakeet-*
  cpu-stt-canary    : local-asr-canary-*
  cpu-stt-talkies   : local-talkies-*

The three CUDA STT services are split into separate groups so they evict each
other (all compete for the same VRAM). Within each service, the wrapper
handles its own intra-service eviction (only one model resident at a time).

Speaches unloading uses DELETE /api/ps/{model_id} which evicts the model
from memory but keeps it on disk — next request auto-reloads it.
"""

import asyncio
import logging
from typing import Optional

import httpx

from litellm.integrations.custom_logger import CustomLogger

logger = logging.getLogger("litellm.proxy")

# ---------------------------------------------------------------------------
# Model → group mapping
# ---------------------------------------------------------------------------

_CUDA_LLM_PREFIX = "local-ollama-cuda-"
_CPU_LLM_PREFIX = "local-ollama-cpu-"

_CUDA_IMG_PREFIX = "local-sdcpp-cuda-"
_CPU_IMG_PREFIX = "local-sdcpp-cpu-"

_CUDA_TTS = {"local-qwen3-cuda-tts"}
_CUDA_STT_SPEACHES = {
    "local-speaches-cuda-whisper-distil-large-v3",
    "local-speaches-cuda-whisper-large-v3-turbo",
    "local-speaches-cuda-parakeet-tdt-0.6b",
    "local-speaches-cuda-parakeet-tdt-0.6b-v3",
}
_CUDA_STT_CANARY = {
    "local-asr-canary-cuda-180m-flash",
    "local-asr-canary-cuda-1b-flash",
    "local-asr-canary-cuda-qwen-2.5b",
}
# vllm exposes each model under two aliases (-transcribe + -chat) — both
# map onto the same supervised vllm-serve subprocess, so they share one group.
_VLLM_CUDA_PREFIX = "local-vllm-cuda-"

# talkies — unified ASR (whisper + parakeet + canary). Both CPU and CUDA
# variants share `local-talkies-` prefix; CUDA adds `cuda-` infix.
_TALKIES_CUDA_PREFIX = "local-talkies-cuda-"
_TALKIES_CPU_PREFIX = "local-talkies-"

_CPU_TTS = {"local-speaches-kokoro-tts"}
_CPU_STT_SPEACHES = {
    "local-speaches-whisper-distil-large-v3",
    "local-speaches-whisper-large-v3-turbo",
    "local-speaches-parakeet-tdt-0.6b",
    "local-speaches-parakeet-tdt-0.6b-v3",
}
_CPU_STT_CANARY = {
    "local-asr-canary-180m-flash",
}

_ALL_CUDA_GROUPS = {
    "cuda-llm",
    "cuda-img",
    "cuda-tts",
    "cuda-stt-speaches",
    "cuda-stt-canary",
    "cuda-stt-talkies",
    "cuda-vllm",
}
_ALL_CPU_GROUPS = {
    "cpu-llm",
    "cpu-img",
    "cpu-tts",
    "cpu-stt-speaches",
    "cpu-stt-canary",
    "cpu-stt-talkies",
}


def _get_group(model: str) -> Optional[str]:
    if model.startswith(_CUDA_LLM_PREFIX):
        return "cuda-llm"
    if model.startswith(_CPU_LLM_PREFIX):
        return "cpu-llm"
    if model.startswith(_CUDA_IMG_PREFIX):
        return "cuda-img"
    if model.startswith(_CPU_IMG_PREFIX):
        return "cpu-img"
    if model in _CUDA_TTS:
        return "cuda-tts"
    if model in _CUDA_STT_SPEACHES:
        return "cuda-stt-speaches"
    if model in _CUDA_STT_CANARY:
        return "cuda-stt-canary"
    if model.startswith(_VLLM_CUDA_PREFIX):
        return "cuda-vllm"
    # talkies CUDA must be checked before CPU (longer prefix wins)
    if model.startswith(_TALKIES_CUDA_PREFIX):
        return "cuda-stt-talkies"
    if model.startswith(_TALKIES_CPU_PREFIX):
        return "cpu-stt-talkies"
    if model in _CPU_TTS:
        return "cpu-tts"
    if model in _CPU_STT_SPEACHES:
        return "cpu-stt-speaches"
    if model in _CPU_STT_CANARY:
        return "cpu-stt-canary"
    return None


# ---------------------------------------------------------------------------
# Unload actions per group
# ---------------------------------------------------------------------------


async def _unload_cuda_llm():
    """Tell ollama-cuda to unload all currently loaded models."""
    logger.warning("[resource_manager] unloading cuda-llm models")
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            r = await client.get("http://ollama-cuda:11434/api/ps")
            models = r.json().get("models", [])
            if not models:
                logger.warning("[resource_manager] cuda-llm: no models loaded")
                return
            for m in models:
                name = m["name"]
                logger.warning("[resource_manager] cuda-llm: unloading %s", name)
                await client.post(
                    "http://ollama-cuda:11434/api/generate",
                    json={"model": name, "keep_alive": 0, "stream": False},
                )
                logger.warning("[resource_manager] cuda-llm: unloaded %s", name)
        except Exception as e:
            logger.warning("[resource_manager] cuda-llm unload error: %s", e)


async def _unload_cpu_llm():
    """Tell ollama CPU to unload all currently loaded models."""
    logger.warning("[resource_manager] unloading cpu-llm models")
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            r = await client.get("http://ollama:11434/api/ps")
            models = r.json().get("models", [])
            if not models:
                logger.warning("[resource_manager] cpu-llm: no models loaded")
                return
            for m in models:
                name = m["name"]
                logger.warning("[resource_manager] cpu-llm: unloading %s", name)
                await client.post(
                    "http://ollama:11434/api/generate",
                    json={"model": name, "keep_alive": 0, "stream": False},
                )
                logger.warning("[resource_manager] cpu-llm: unloaded %s", name)
        except Exception as e:
            logger.warning("[resource_manager] cpu-llm unload error: %s", e)


async def _unload_cuda_img():
    """Tell sdcpp-cuda wrapper to unload the model context and free VRAM."""
    logger.warning("[resource_manager] unloading cuda-img (sdcpp-cuda)")
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            r = await client.post("http://sdcpp-cuda:7234/sdcpp/v1/unload")
            logger.warning(
                "[resource_manager] cuda-img unloaded, status=%s", r.status_code
            )
        except Exception as e:
            logger.warning("[resource_manager] cuda-img unload error: %s", e)


async def _unload_cpu_img():
    """Tell sdcpp wrapper to unload the model context and free RAM."""
    logger.warning("[resource_manager] unloading cpu-img (sdcpp)")
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            r = await client.post("http://sdcpp:7234/sdcpp/v1/unload")
            logger.warning(
                "[resource_manager] cpu-img unloaded, status=%s", r.status_code
            )
        except Exception as e:
            logger.warning("[resource_manager] cpu-img unload error: %s", e)


async def _unload_cuda_tts():
    """Tell qwen3-cuda-tts to release VRAM."""
    logger.warning("[resource_manager] unloading cuda-tts (qwen3-cuda-tts)")
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            r = await client.post("http://qwen3-cuda-tts:8000/unload")
            logger.warning(
                "[resource_manager] cuda-tts unloaded, status=%s", r.status_code
            )
        except Exception as e:
            logger.warning("[resource_manager] cuda-tts unload error: %s", e)


_SPEACHES_CUDA_URL = "http://speaches-cuda:8000"
_SPEACHES_CPU_URL = "http://speaches:8000"

# HuggingFace model IDs loaded by each speaches instance
_SPEACHES_CUDA_STT_MODELS = [
    "Systran/faster-distil-whisper-large-v3",
    "deepdml/faster-whisper-large-v3-turbo-ct2",
    "istupakov/parakeet-tdt-0.6b-v2-onnx",
    "istupakov/parakeet-tdt-0.6b-v3-onnx",
]
_SPEACHES_CPU_TTS_MODELS = [
    "speaches-ai/Kokoro-82M-v1.0-ONNX-int8",
]
_SPEACHES_CPU_STT_MODELS = [
    "Systran/faster-distil-whisper-large-v3",
    "deepdml/faster-whisper-large-v3-turbo-ct2",
    "istupakov/parakeet-tdt-0.6b-v2-onnx",
    "istupakov/parakeet-tdt-0.6b-v3-onnx",
]

# asr-canary uses local slugs (the model_id in its registry), not HF repo IDs
_ASR_CANARY_CUDA_URL = "http://asr-canary-cuda:8000"
_ASR_CANARY_CPU_URL = "http://asr-canary:8000"
_ASR_CANARY_CUDA_STT_MODELS = [
    "canary-180m-flash",
    "canary-1b-flash",
    "canary-qwen-2.5b",
]
_ASR_CANARY_CPU_STT_MODELS = [
    "canary-180m-flash",
]

# vllm — single supervised vllm-serve subprocess; DELETE /api/ps/{model_id}
# kills it and frees VRAM. We send DELETE for every registered model_id; only
# the one currently loaded returns 200, the rest return 404 (no-op).
_VLLM_CUDA_URL = "http://vllm-cuda:8000"
_VLLM_CUDA_MODELS = [
    "qwen3-asr-1.7b",
    "voxtral-mini-3b",
]

# talkies — unified ASR; DELETE /api/ps/{model_id} per model. CUDA has the
# full set, CPU a subset (whisper variants + canary-180m-flash only).
_TALKIES_CUDA_URL = "http://talkies-cuda:8000"
_TALKIES_CPU_URL = "http://talkies:8000"
_TALKIES_CUDA_MODELS = [
    "whisper-large-v3",
    "whisper-large-v3-turbo",
    "distil-whisper-large-v3",
    "parakeet-tdt-0.6b-v3",
    "canary-180m-flash",
    "canary-1b-flash",
    "canary-qwen-2.5b",
]
_TALKIES_CPU_MODELS = [
    "whisper-large-v3",
    "whisper-large-v3-turbo",
    "distil-whisper-large-v3",
    "canary-180m-flash",
]


async def _unload_speaches_models(base_url: str, group: str, model_ids: list) -> None:
    """Unload models from a speaches-style instance in parallel via DELETE
    /api/ps/{model_id}. Sequential calls compounded the pre-transcribe
    latency badly (one slow service blocked every subsequent unload); fan
    them out so the whole group's eviction is bounded by the slowest single
    response, not the sum.
    """
    async with httpx.AsyncClient(timeout=10.0) as client:
        async def _one(model_id: str) -> None:
            encoded = model_id.replace("/", "%2F")
            try:
                r = await client.delete(f"{base_url}/api/ps/{encoded}")
                if r.status_code == 200:
                    logger.warning(
                        "[resource_manager] %s: unloaded %s", group, model_id
                    )
                elif r.status_code == 404:
                    logger.warning(
                        "[resource_manager] %s: %s not loaded, skipping",
                        group,
                        model_id,
                    )
                else:
                    logger.warning(
                        "[resource_manager] %s: unload %s status=%s",
                        group,
                        model_id,
                        r.status_code,
                    )
            except Exception as e:
                logger.warning(
                    "[resource_manager] %s: unload error for %s: %s", group, model_id, e
                )

        await asyncio.gather(*(_one(mid) for mid in model_ids), return_exceptions=True)


async def _unload_cuda_stt_speaches():
    """Unload CUDA STT models from speaches-cuda to free VRAM."""
    logger.warning("[resource_manager] unloading cuda-stt-speaches models")
    await _unload_speaches_models(
        _SPEACHES_CUDA_URL, "cuda-stt-speaches", _SPEACHES_CUDA_STT_MODELS
    )


async def _unload_cuda_stt_canary():
    """Unload CUDA STT models from asr-canary-cuda to free VRAM."""
    logger.warning("[resource_manager] unloading cuda-stt-canary models")
    await _unload_speaches_models(
        _ASR_CANARY_CUDA_URL, "cuda-stt-canary", _ASR_CANARY_CUDA_STT_MODELS
    )


async def _unload_vllm_cuda():
    """Kill the supervised vllm-serve subprocess (frees the entire model VRAM)."""
    logger.warning("[resource_manager] unloading cuda-vllm subprocess")
    await _unload_speaches_models(
        _VLLM_CUDA_URL, "cuda-vllm", _VLLM_CUDA_MODELS
    )


async def _unload_cuda_stt_talkies():
    """Unload CUDA STT models from talkies-cuda to free VRAM."""
    logger.warning("[resource_manager] unloading cuda-stt-talkies models")
    await _unload_speaches_models(
        _TALKIES_CUDA_URL, "cuda-stt-talkies", _TALKIES_CUDA_MODELS
    )


async def _unload_cpu_stt_talkies():
    """Unload CPU STT models from talkies to free RAM."""
    logger.warning("[resource_manager] unloading cpu-stt-talkies models")
    await _unload_speaches_models(
        _TALKIES_CPU_URL, "cpu-stt-talkies", _TALKIES_CPU_MODELS
    )


async def _unload_cpu_tts():
    """Unload CPU TTS models from speaches to free RAM."""
    logger.warning("[resource_manager] unloading cpu-tts models")
    await _unload_speaches_models(
        _SPEACHES_CPU_URL, "cpu-tts", _SPEACHES_CPU_TTS_MODELS
    )


async def _unload_cpu_stt_speaches():
    """Unload CPU STT models from speaches to free RAM."""
    logger.warning("[resource_manager] unloading cpu-stt-speaches models")
    await _unload_speaches_models(
        _SPEACHES_CPU_URL, "cpu-stt-speaches", _SPEACHES_CPU_STT_MODELS
    )


async def _unload_cpu_stt_canary():
    """Unload CPU STT models from asr-canary to free RAM."""
    logger.warning("[resource_manager] unloading cpu-stt-canary models")
    await _unload_speaches_models(
        _ASR_CANARY_CPU_URL, "cpu-stt-canary", _ASR_CANARY_CPU_STT_MODELS
    )


_UNLOAD_FNS = {
    "cuda-llm": _unload_cuda_llm,
    "cuda-img": _unload_cuda_img,
    "cuda-tts": _unload_cuda_tts,
    "cuda-stt-speaches": _unload_cuda_stt_speaches,
    "cuda-stt-canary": _unload_cuda_stt_canary,
    "cuda-stt-talkies": _unload_cuda_stt_talkies,
    "cuda-vllm": _unload_vllm_cuda,
    "cpu-llm": _unload_cpu_llm,
    "cpu-img": _unload_cpu_img,
    "cpu-tts": _unload_cpu_tts,
    "cpu-stt-speaches": _unload_cpu_stt_speaches,
    "cpu-stt-canary": _unload_cpu_stt_canary,
    "cpu-stt-talkies": _unload_cpu_stt_talkies,
}

# ---------------------------------------------------------------------------
# Hardware semaphores — one CUDA job, one CPU job at a time
# ---------------------------------------------------------------------------

_cuda_sem = asyncio.Semaphore(1)
_cpu_sem = asyncio.Semaphore(1)

_METADATA_KEY = "_resource_manager_holds_sem"

# Contextvar tracks the held-semaphore for the current request task. Survives
# the trip from pre_call_hook → handler → log_success_event, including paths
# where LiteLLM's standard-logging chain dies mid-flight (e.g. trying to
# pydantic-serialize a Response subclass) and never invokes the release hook.
# Both the raw-text response patch AND the standard log_success_event read
# this and use sentinel-clearing so we never double-release.
import contextvars  # noqa: E402

_held_hw: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    "resource_manager_held_hw", default=None
)


def _get_sem(group: str) -> Optional[asyncio.Semaphore]:
    if group in _ALL_CUDA_GROUPS:
        return _cuda_sem
    if group in _ALL_CPU_GROUPS:
        return _cpu_sem
    return None


# ---------------------------------------------------------------------------
# LiteLLM CustomLogger
# ---------------------------------------------------------------------------


class ResourceManager(CustomLogger):
    """
    Enforces single-job-per-hardware via semaphore, then unloads competing
    resource groups before routing. Failures are logged but never block.
    """

    async def async_pre_call_hook(
        self, user_api_key_dict, cache, data, call_type
    ):  # noqa: ARG002
        model: str = data.get("model", "")
        group = _get_group(model)

        logger.warning(
            "[resource_manager] pre_call: model=%s call_type=%s group=%s",
            model,
            call_type,
            group,
        )

        # Inference paths have no business being killed by some 10-minute
        # default. CPU transcriptions can take hours; long-context LLM
        # completions can take many minutes. Override LiteLLM's hardcoded
        # 600s default whenever the client didn't explicitly pass one.
        if data.get("timeout") in (None, 600, 600.0):
            data["timeout"] = 86400

        if group is None:
            return data

        sem = _get_sem(group)
        if sem is not None:
            hw = "CUDA" if group in _ALL_CUDA_GROUPS else "CPU"
            logger.warning(
                "[resource_manager] acquiring %s semaphore for group=%s", hw, group
            )
            await sem.acquire()
            logger.warning(
                "[resource_manager] acquired %s semaphore for group=%s", hw, group
            )
            data.setdefault("metadata", {})[_METADATA_KEY] = hw
            _held_hw.set(hw)

        if group in _ALL_CUDA_GROUPS:
            competing = _ALL_CUDA_GROUPS - {group}
        else:
            competing = _ALL_CPU_GROUPS - {group}

        logger.warning(
            "[resource_manager] group=%s unloading competing: %s", group, competing
        )

        results = await asyncio.gather(
            *[_UNLOAD_FNS[g]() for g in competing],
            return_exceptions=True,
        )

        for g, result in zip(competing, results):
            if isinstance(result, Exception):
                logger.warning(
                    "[resource_manager] unload error group=%s: %s", g, result
                )

        logger.warning("[resource_manager] done for model=%s", model)
        return data

    async def async_log_success_event(
        self, kwargs, response_obj, start_time, end_time
    ):  # noqa: ARG002
        self._release_sem(kwargs)

    async def async_log_failure_event(
        self, kwargs, response_obj, start_time, end_time
    ):  # noqa: ARG002
        self._release_sem(kwargs)

    @staticmethod
    def _release_sem(kwargs):
        # Prefer the contextvar (set in pre_call_hook on the same async task)
        # over kwargs.litellm_params.metadata — LiteLLM doesn't always
        # propagate user-set data.metadata into kwargs.litellm_params.metadata,
        # but the contextvar follows the task naturally.
        hw = _held_hw.get()
        if hw is None:
            hw = (kwargs.get("litellm_params") or {}).get("metadata", {}).get(_METADATA_KEY)
        if hw is None:
            return
        sem = _cuda_sem if hw == "CUDA" else _cpu_sem
        # Clear contextvar BEFORE release so a concurrent path can't see the
        # same hw and double-release.
        _held_hw.set(None)
        try:
            sem.release()
            logger.warning("[resource_manager] released %s semaphore", hw)
        except ValueError:
            # Already released (e.g. raw-text path beat us to it). No-op.
            pass


# ---------------------------------------------------------------------------
# LiteLLM transcription patches — make all internal STT services return
# proper OpenAI-shaped responses regardless of requested format.
#
# By default LiteLLM:
#   1. Rewrites response_format=text|json → verbose_json on the REQUEST side
#      ("ensures 'duration' is received - used for cost calculation"). This
#      breaks speaches' parakeet executor (refuses verbose_json) AND clobbers
#      the client's choice of `text` vs `json`.
#   2. Wraps raw-text RESPONSES (srt/vtt/text) into a JSON envelope
#      `{"text": "<raw body>", "usage": null}` instead of passing them
#      through as the correct Content-Type body the OpenAI HTTP API
#      specifies (text/plain, application/x-subrip, text/vtt).
#
# Both behaviours are wrong for our internal STT services (talkies,
# asr-canary, speaches) — all of them implement the full OpenAI shape
# natively. The patches below:
#   - skip request rewrite for `local-talkies-*`, `local-asr-canary-*`,
#     `local-speaches-*` so client format passes through to the backend
#   - intercept the response and, when format is text/srt/vtt, return a
#     FastAPI PlainTextResponse with the proper media_type so the client
#     sees raw body bytes instead of a JSON envelope
# ---------------------------------------------------------------------------

# Substring match against the *backend* model name (i.e. after the
# `openai/` prefix is stripped — e.g. `whisper-large-v3`, `canary-180m-flash`,
# `parakeet-tdt-0.6b-v3`). All talkies/asr-canary/speaches models match.
_NATIVE_FORMAT_SUBSTRINGS = (
    "parakeet",
    "whisper",
    "canary",
    "distil-whisper",
)

_RAW_TEXT_FORMATS = {
    "text": "text/plain; charset=utf-8",
    "srt": "application/x-subrip; charset=utf-8",
    "vtt": "text/vtt; charset=utf-8",
}


def _is_native_format_model(model: str | None) -> bool:
    model_lc = (model or "").lower()
    return any(s in model_lc for s in _NATIVE_FORMAT_SUBSTRINGS)


def _patch_whisper_transformation_request() -> None:
    try:
        from litellm.llms.openai.transcriptions.whisper_transformation import (
            OpenAIWhisperAudioTranscriptionConfig,
        )
        from litellm.llms.base_llm.audio_transcription.transformation import (
            AudioTranscriptionRequestData,
        )
    except Exception as e:  # noqa: BLE001
        logger.warning(
            "[resource_manager] whisper_transformation request-patch skipped (import failed): %s",
            e,
        )
        return

    _orig = OpenAIWhisperAudioTranscriptionConfig.transform_audio_transcription_request

    def _patched(self, model, audio_file, optional_params, litellm_params):
        if _is_native_format_model(model):
            data = {"model": model, "file": audio_file, **optional_params}
            return AudioTranscriptionRequestData(data=data)
        return _orig(self, model, audio_file, optional_params, litellm_params)

    OpenAIWhisperAudioTranscriptionConfig.transform_audio_transcription_request = _patched
    logger.warning(
        "[resource_manager] patched OpenAIWhisperAudioTranscriptionConfig: skip "
        "verbose_json rewrite for models matching %s",
        _NATIVE_FORMAT_SUBSTRINGS,
    )


class _RawTextTranscription:
    """Sentinel that satisfies both LiteLLM's `isinstance(_, TranscriptionResponse)`
    type check and FastAPI's `isinstance(_, Response)` short-circuit.

    LiteLLM's `litellm.main.atranscription` hard-asserts the upstream call
    returns a TranscriptionResponse. FastAPI returns Response subclasses as
    raw HTTP bodies (bypassing JSON serialization). A class that is BOTH
    lets us pass through raw SRT/VTT/text bodies end-to-end without
    rewriting LiteLLM's router or proxy layer.

    Built lazily at first use so the imports happen inside the proxy process.
    """

    _cls = None

    @classmethod
    def make(cls, raw_text: str, media_type: str):
        if cls._cls is None:
            from litellm.types.utils import TranscriptionResponse
            from starlette.responses import PlainTextResponse

            class _Hybrid(PlainTextResponse, TranscriptionResponse):
                def __init__(self, raw_text: str, media_type: str):  # noqa: D401
                    PlainTextResponse.__init__(
                        self, content=raw_text, media_type=media_type
                    )
                    # LiteLLM's success logger pokes at pydantic internals
                    # (__pydantic_extra__, __pydantic_fields_set__, etc.)
                    # when constructing the standard_logging_payload. Without
                    # these, the success-call hook chain blows up with an
                    # AttributeError and never releases the semaphore.
                    object.__setattr__(self, "text", raw_text)
                    object.__setattr__(self, "usage", None)
                    object.__setattr__(self, "_hidden_params", {})
                    object.__setattr__(self, "__pydantic_extra__", {})
                    object.__setattr__(self, "__pydantic_fields_set__", set())
                    object.__setattr__(self, "__pydantic_private__", None)

                def __setattr__(self, name, value):
                    # Bypass pydantic validation (LiteLLM mutates ._hidden_params)
                    object.__setattr__(self, name, value)

            cls._cls = _Hybrid
        return cls._cls(raw_text, media_type)


def _patch_handler_for_raw_text_response() -> None:
    """Make async_audio_transcriptions return a hybrid PlainTextResponse /
    TranscriptionResponse for raw-text formats (text/srt/vtt). The hybrid
    passes LiteLLM's internal isinstance check AND, because it is also a
    starlette Response, gets returned as a raw HTTP body by FastAPI with
    the proper media_type — no JSON wrapping.
    """
    try:
        from litellm.llms.openai.transcriptions.handler import OpenAIAudioTranscription
    except Exception as e:  # noqa: BLE001
        logger.warning(
            "[resource_manager] handler raw-text patch skipped (import failed): %s",
            e,
        )
        return

    _orig_async = OpenAIAudioTranscription.async_audio_transcriptions

    async def _patched_async(self, audio_file, data, model_response, timeout, *args, **kwargs):
        result = await _orig_async(
            self, audio_file, data, model_response, timeout, *args, **kwargs
        )

        fmt = (data.get("response_format") or "").lower()
        media_type = _RAW_TEXT_FORMATS.get(fmt)
        if media_type is None:
            return result

        if not _is_native_format_model(data.get("model")):
            return result

        raw = getattr(result, "text", None)
        if not isinstance(raw, str):
            return result

        # FastAPI returns Response subclasses straight through without
        # invoking LiteLLM's post-call logging hooks reliably (the standard
        # logging payload chokes on non-pydantic responses anyway). Release
        # the semaphore manually via the contextvar; clearing the var first
        # prevents the standard hook from double-releasing if it does fire.
        hw = _held_hw.get()
        if hw is not None:
            _held_hw.set(None)
            sem = _cuda_sem if hw == "CUDA" else _cpu_sem
            try:
                sem.release()
                logger.warning(
                    "[resource_manager] released %s semaphore (raw-text path)", hw
                )
            except ValueError:
                pass
        # Also drop the metadata marker for belt-and-suspenders.
        meta = data.get("metadata") or {}
        meta.pop(_METADATA_KEY, None)

        return _RawTextTranscription.make(raw, media_type)

    OpenAIAudioTranscription.async_audio_transcriptions = _patched_async
    logger.warning(
        "[resource_manager] patched OpenAIAudioTranscription.async_audio_transcriptions: "
        "return hybrid Response/TranscriptionResponse for text/srt/vtt on native-format models"
    )


_patch_whisper_transformation_request()
_patch_handler_for_raw_text_response()


# LiteLLM proxy loads this when config references the module
proxy_handler_instance = ResourceManager()
