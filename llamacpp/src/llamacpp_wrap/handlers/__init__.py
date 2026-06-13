"""Per-model orchestration handler registry.

Most models do not need a handler — `llamacpp_wrap.server._handle_json_request`
parses the request, ensures the model is loaded, rewrites any http(s)://
image URLs to data URLs, and proxies the call to `llama-server`. One-shot.

Some models need richer orchestration that doesn't fit the one-shot shape:
multi-call loops, modality-specific pre-processing (PDF rasterization,
audio chunking + transcript stitching, document-tiling for huge pages),
or response post-processing (cell-grid assembly from row/column bboxes).
The handler mechanism gives those models a per-request hook before the
default proxy path runs.

A model opts in by setting `"handler": "<name>"` in its `models.{cpu,cuda}
.json` entry. The wrapper looks up `<name>` here. Unknown names fail at
startup via the validation in `llamacpp_wrap.config`.
"""

from __future__ import annotations

from .base import Handler
from .surya import SuryaHandler


_REGISTRY: dict[str, Handler] = {
    "surya": SuryaHandler(),
}


def get(name: str | None) -> Handler | None:
    """Resolve a handler name to its registered instance.

    Returns None when name is None / missing, signalling the caller to fall
    through to the default proxy path.
    """
    if not name:
        return None
    if name not in _REGISTRY:
        raise KeyError(
            f"unknown handler {name!r}; registered: {list(_REGISTRY)}"
        )
    return _REGISTRY[name]


__all__ = ["Handler", "get"]
