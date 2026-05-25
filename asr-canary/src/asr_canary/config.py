"""Env-driven config — parsed at import time, fail-fast on bad input."""

from __future__ import annotations

import json
import os
from pathlib import Path


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if raw == "":
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ValueError(f"{name}={raw!r} is not an integer") from exc


def _float_env(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if raw == "":
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ValueError(f"{name}={raw!r} is not a number") from exc


def _list_env(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [s.strip() for s in raw.split(",") if s.strip()]


HOST: str = os.environ.get("ASR_CANARY_HOST", "0.0.0.0")
PORT: int = _int_env("ASR_CANARY_PORT", 8000)

DEVICE: str = os.environ.get("ASR_CANARY_DEVICE", "auto").strip() or "auto"
if DEVICE not in ("auto", "cpu", "cuda") and not DEVICE.startswith("cuda:"):
    raise ValueError(
        f"ASR_CANARY_DEVICE={DEVICE!r} must be 'auto', 'cpu', 'cuda', or 'cuda:N'"
    )

MODELS_FILE: Path = Path(
    os.environ.get("ASR_CANARY_MODELS_FILE", "/app/models.json")
).resolve()

DATA_DIR: Path = Path(
    os.environ.get("ASR_CANARY_DATA_DIR", "/data")
).resolve()

MODEL_IDLE_TIMEOUT_SECONDS: float = _float_env("ASR_CANARY_MODEL_TTL", 600.0)
SWEEPER_INTERVAL_SECONDS: float = _float_env("ASR_CANARY_SWEEPER_INTERVAL", 60.0)
LOAD_TIMEOUT_SECONDS: float = _float_env("ASR_CANARY_LOAD_TIMEOUT", 300.0)

MAX_UPLOAD_BYTES: int = _int_env("ASR_CANARY_MAX_UPLOAD_BYTES", 100 * 1024 * 1024)

PRELOAD: list[str] = _list_env("ASR_CANARY_PRELOAD")
PREFETCH: list[str] = _list_env("ASR_CANARY_PREFETCH")


def load_registry() -> dict[str, dict]:
    """Read models.json and return {model_id: {repo, executor, language?, ...}}."""
    if not MODELS_FILE.exists():
        raise FileNotFoundError(f"models.json not found at {MODELS_FILE}")
    with MODELS_FILE.open("r", encoding="utf-8") as fh:
        raw = json.load(fh)
    if not isinstance(raw, dict) or "models" not in raw:
        raise ValueError(f"{MODELS_FILE}: expected top-level object with 'models' key")
    models = raw["models"]
    if not isinstance(models, dict) or not models:
        raise ValueError(f"{MODELS_FILE}: 'models' must be a non-empty object")
    for model_id, entry in models.items():
        if not isinstance(entry, dict):
            raise ValueError(f"{MODELS_FILE}: model {model_id!r} entry must be an object")
        if "repo" not in entry:
            raise ValueError(f"{MODELS_FILE}: model {model_id!r} missing 'repo'")
        executor = entry.get("executor", "multitask")
        if executor not in ("multitask", "salm"):
            raise ValueError(
                f"{MODELS_FILE}: model {model_id!r} executor={executor!r} must be 'multitask' or 'salm'"
            )
    return models
