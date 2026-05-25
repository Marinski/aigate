"""Backend protocol — uniform load/transcribe/unload surface per executor type."""

from __future__ import annotations

from typing import Protocol


class Backend(Protocol):
    """Per-model handle.

    Backends are instantiated lazily on first request — `get_model()` populates
    the underlying NeMo object; later calls return the cached instance until
    `unload()` is called (manually or by the idle sweeper).
    """

    model_id: str
    repo: str

    async def get_model(self) -> object: ...

    async def transcribe(
        self,
        audio_path: str,
        *,
        source_lang: str | None,
        target_lang: str | None,
        task: str,
    ) -> str: ...

    async def unload(self) -> None: ...

    def loaded(self) -> bool: ...

    def last_used_secs_ago(self) -> float | None: ...
