"""Logging setup — plain stdout, level via env."""

from __future__ import annotations

import logging
import os
import sys


def configure() -> None:
    level_name = os.environ.get("VLLM_WRAP_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    fmt = "%(asctime)s %(levelname)s %(name)s: %(message)s"
    logging.basicConfig(level=level, format=fmt, stream=sys.stdout, force=True)
