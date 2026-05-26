"""SALM backend — canary-qwen-2.5b (NeMo speechlm2.SALM, ASR via prompt).

Unlike `EncDecMultiTaskModel`, SALM has no `.transcribe()`. Use `.generate()`
with a chat-style prompt:

    prompts=[[{
        "role": "user",
        "content": f"Transcribe the following: {model.audio_locator_tag}",
        "audio": [audio_path],
    }]]

Returns decoded transcript via `model.tokenizer.ids_to_text(...)`. Plain text,
not chat-format JSON.
"""

from __future__ import annotations

import asyncio
import gc
import logging
import time
from typing import Any

from .base import TranscribeResult


_PROMPT_PREFIX = "Transcribe the following:"


class SalmBackend:
    def __init__(self, model_id: str, repo: str, device: str) -> None:
        self.model_id = model_id
        self.repo = repo
        self._device = device
        self._lock = asyncio.Lock()
        self._model: Any = None
        self._last_used: float | None = None
        self._log = logging.getLogger(f"asr_canary.salm.{model_id}")

    def loaded(self) -> bool:
        return self._model is not None

    def last_used_secs_ago(self) -> float | None:
        if self._last_used is None:
            return None
        return time.monotonic() - self._last_used

    async def get_model(self) -> Any:
        if self._model is not None:
            return self._model
        async with self._lock:
            if self._model is not None:
                return self._model
            self._log.info("loading SALM %s onto %s", self.repo, self._device)
            self._model = await asyncio.to_thread(self._load_sync)
            self._log.info("loaded SALM %s", self.repo)
            return self._model

    def _load_sync(self) -> Any:
        from nemo.collections.speechlm2.models import SALM

        model = SALM.from_pretrained(self.repo, map_location="cpu")
        model = model.to(self._device).eval()
        return model

    async def transcribe(
        self,
        audio_path: str,
        *,
        source_lang: str | None,
        target_lang: str | None,
        task: str,
        with_timestamps: bool = False,
    ) -> TranscribeResult:
        del source_lang, target_lang, task, with_timestamps  # SALM is text-only
        model = await self.get_model()
        async with self._lock:
            text = await asyncio.to_thread(self._generate_sync, model, audio_path)
            self._last_used = time.monotonic()
            return TranscribeResult(text=text, supports_timestamps=False)

    def _generate_sync(self, model: Any, audio_path: str) -> str:
        audio_tag = getattr(model, "audio_locator_tag", "<audio>")
        prompt = [
            [
                {
                    "role": "user",
                    "content": f"{_PROMPT_PREFIX} {audio_tag}",
                    "audio": [audio_path],
                }
            ]
        ]
        tokens = model.generate(prompts=prompt, max_new_tokens=512)
        ids = tokens[0].tolist() if hasattr(tokens[0], "tolist") else list(tokens[0])
        text = model.tokenizer.ids_to_text(ids)
        if not isinstance(text, str):
            text = str(text)
        return text.strip()

    async def unload(self) -> None:
        async with self._lock:
            if self._model is None:
                return
            self._log.info("unloading SALM %s", self.repo)
            self._model = None
            self._last_used = None
        gc.collect()
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except ImportError:
            pass
