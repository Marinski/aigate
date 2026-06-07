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


HOST: str = os.environ.get("VLLM_WRAP_HOST", "0.0.0.0")
PORT: int = _int_env("VLLM_WRAP_PORT", 8000)

# "cuda" or "cpu". When set, the supervisor passes `--device <DEVICE>` to
# every spawned vllm serve. Defaults to empty (let vllm pick / image default).
DEVICE: str = os.environ.get("VLLM_WRAP_DEVICE", "").strip().lower()

# Internal port the supervised `vllm serve` subprocess listens on (loopback).
SUBPROCESS_PORT: int = _int_env("VLLM_WRAP_SUBPROCESS_PORT", 18000)

MODELS_FILE: Path = Path(
    os.environ.get("VLLM_WRAP_MODELS_FILE", "/app/models.json")
).resolve()

DATA_DIR: Path = Path(
    os.environ.get("VLLM_WRAP_DATA_DIR", "/data")
).resolve()

# Models live under MODELS_DIR/<repo>, mirroring the HF repo path. The pull
# container populates this via `huggingface-cli download <repo> --local-dir
# <MODELS_DIR>/<repo>`, producing the flat HF repo structure (no blobs/
# snapshots dedup). Other services that bind-mount the same path can load
# the weights directly.
MODELS_DIR: Path = Path(
    os.environ.get("VLLM_WRAP_MODELS_DIR", str(DATA_DIR / "models"))
).resolve()

# Idle TTL: kill the subprocess if no requests for this many seconds.
# -1 disables the sweeper (process stays loaded until /unload or shutdown).
MODEL_IDLE_TIMEOUT_SECONDS: float = _float_env("VLLM_WRAP_MODEL_TTL", 600.0)
SWEEPER_INTERVAL_SECONDS: float = _float_env("VLLM_WRAP_SWEEPER_INTERVAL", 60.0)

# Subprocess boot: how long to wait for vllm serve's /health to return 200.
LOAD_TIMEOUT_SECONDS: float = _float_env("VLLM_WRAP_LOAD_TIMEOUT", 600.0)
# Per-request proxy timeout (long generations or large embedding batches).
REQUEST_TIMEOUT_SECONDS: float = _float_env("VLLM_WRAP_REQUEST_TIMEOUT", 300.0)

# Pre-warm the subprocess at startup with this model_id (optional).
PRELOAD: str = os.environ.get("VLLM_WRAP_PRELOAD", "").strip()

# Pre-download these HF repos into the cache at entrypoint time (comma-separated
# model_ids that resolve to repos via models.json).
PREFETCH: list[str] = _list_env("VLLM_WRAP_PREFETCH")


def load_registry() -> dict[str, dict]:
    """Read models.json and return {model_id: {repo, vllm_args, endpoints}}."""
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
        if "repo" not in entry or not isinstance(entry["repo"], str):
            raise ValueError(f"{MODELS_FILE}: model {model_id!r} missing string 'repo'")
        args = entry.get("vllm_args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ValueError(
                f"{MODELS_FILE}: model {model_id!r} 'vllm_args' must be a list of strings"
            )
        endpoints = entry.get("endpoints", ["chat"])
        if not isinstance(endpoints, list) or not endpoints:
            raise ValueError(
                f"{MODELS_FILE}: model {model_id!r} 'endpoints' must be a non-empty list"
            )
        allowed = ("chat", "completions", "embeddings")
        for ep in endpoints:
            if ep not in allowed:
                raise ValueError(
                    f"{MODELS_FILE}: model {model_id!r} endpoint {ep!r} must be "
                    f"one of {allowed}"
                )
    return models
