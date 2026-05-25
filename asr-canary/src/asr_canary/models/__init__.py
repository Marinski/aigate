"""Backend factory — build backends keyed by model_id from the registry."""

from __future__ import annotations

from typing import Any

from .multitask import MultitaskBackend
from .salm import SalmBackend


def build_backends(registry: dict[str, dict], device: str) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for model_id, entry in registry.items():
        executor = entry.get("executor", "multitask")
        repo = entry["repo"]
        if executor == "salm":
            out[model_id] = SalmBackend(model_id=model_id, repo=repo, device=device)
        else:
            out[model_id] = MultitaskBackend(model_id=model_id, repo=repo, device=device)
    return out
