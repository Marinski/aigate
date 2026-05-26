"""EncDecMultiTaskModel backend — canary-180m-flash and canary-1b-flash.

Both load via `ASRModel.from_pretrained(repo)` and expose `.transcribe(audio=...)`.
The 180m model is English-only; the 1b model accepts EN/DE/FR/ES.
"""

from __future__ import annotations

import asyncio
import gc
import logging
import os
import time
from pathlib import Path
from typing import Any

from .base import TranscribeResult


def _resolve_local_nemo(repo: str) -> str | None:
    hf_home = os.environ.get("HF_HOME", "")
    if not hf_home:
        return None
    repo_dir = Path(hf_home) / "hub" / f"models--{repo.replace('/', '--')}"
    ref_file = repo_dir / "refs" / "main"
    if not ref_file.is_file():
        return None
    snapshot = ref_file.read_text().strip()
    snapshot_dir = repo_dir / "snapshots" / snapshot
    if not snapshot_dir.is_dir():
        return None
    for entry in snapshot_dir.iterdir():
        if entry.is_file() and entry.suffix == ".nemo":
            return str(entry)
    return None


class MultitaskBackend:
    def __init__(self, model_id: str, repo: str, device: str) -> None:
        self.model_id = model_id
        self.repo = repo
        self._device = device
        self._lock = asyncio.Lock()
        self._model: Any = None
        self._last_used: float | None = None
        self._log = logging.getLogger(f"asr_canary.multitask.{model_id}")

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
            self._log.info("loading %s onto %s", self.repo, self._device)
            self._model = await asyncio.to_thread(self._load_sync)
            self._log.info("loaded %s", self.repo)
            return self._model

    def _load_sync(self) -> Any:
        from nemo.collections.asr.models import ASRModel, EncDecMultiTaskModel

        nemo_path = _resolve_local_nemo(self.repo)
        if nemo_path is not None:
            self._log.info("loading %s from local cache: %s", self.repo, nemo_path)
            model = EncDecMultiTaskModel.restore_from(nemo_path, map_location="cpu")
        else:
            model = ASRModel.from_pretrained(self.repo, map_location="cpu")
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
        model = await self.get_model()
        async with self._lock:
            result = await asyncio.to_thread(
                self._transcribe_sync,
                model,
                audio_path,
                source_lang,
                target_lang,
                task,
                with_timestamps,
            )
            self._last_used = time.monotonic()
            return result

    def _transcribe_sync(
        self,
        model: Any,
        audio_path: str,
        source_lang: str | None,
        target_lang: str | None,
        task: str,
        with_timestamps: bool,
    ) -> TranscribeResult:
        kwargs: dict[str, Any] = {
            "audio": [audio_path],
            "batch_size": 1,
            "task": task,
            "pnc": "yes",
        }
        if source_lang:
            kwargs["source_lang"] = source_lang
        if target_lang:
            kwargs["target_lang"] = target_lang
        if with_timestamps:
            kwargs["timestamps"] = True

        results = model.transcribe(**kwargs)
        if not results:
            return TranscribeResult(text="", supports_timestamps=True)
        first = results[0]

        if isinstance(first, str):
            return TranscribeResult(text=first, supports_timestamps=True)

        text_attr = getattr(first, "text", None)
        text = text_attr if isinstance(text_attr, str) else str(first)

        segments: list[dict] = []
        words: list[dict] = []
        if with_timestamps:
            ts = getattr(first, "timestamp", None)
            if isinstance(ts, dict):
                segments = _segments_from_nemo(ts.get("segment", []))
                words = _words_from_nemo(ts.get("word", []))
                self._log.debug(
                    "timestamps: %d segments, %d words", len(segments), len(words)
                )

        return TranscribeResult(
            text=text,
            segments=segments,
            words=words,
            language=source_lang,
            supports_timestamps=True,
        )

    async def unload(self) -> None:
        async with self._lock:
            if self._model is None:
                return
            self._log.info("unloading %s", self.repo)
            self._model = None
            self._last_used = None
        gc.collect()
        try:
            import torch

            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except ImportError:
            pass


def _coerce_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _segments_from_nemo(raw: Any) -> list[dict]:
    if not isinstance(raw, list):
        return []
    out: list[dict] = []
    for idx, item in enumerate(raw):
        if not isinstance(item, dict):
            continue
        text = item.get("segment") or item.get("text") or ""
        start = _coerce_float(item.get("start"))
        end = _coerce_float(item.get("end"))
        if start is None or end is None:
            continue
        out.append(
            {
                "id": idx,
                "start": start,
                "end": end,
                "text": str(text).strip(),
            }
        )
    return out


def _words_from_nemo(raw: Any) -> list[dict]:
    if not isinstance(raw, list):
        return []
    out: list[dict] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        word = item.get("word") or item.get("text") or ""
        start = _coerce_float(item.get("start"))
        end = _coerce_float(item.get("end"))
        if start is None or end is None:
            continue
        out.append(
            {
                "word": str(word).strip(),
                "start": start,
                "end": end,
            }
        )
    return out
