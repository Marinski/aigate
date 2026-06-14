"""Network safety helpers shared between server.py and per-model handlers.

Right now: SSRF guard that refuses to dial private / loopback / link-local
addresses from inside the wrapper. The wrapper sits on aigate-internal and
can hostname-resolve every neighbour service; a caller authenticated to
LiteLLM should not be able to pivot through the vision image_url path to
probe internal infrastructure.
"""

from __future__ import annotations

import ipaddress
import os
import socket

_ALLOW_PRIVATE_FETCH = (
    os.environ.get("LLAMACPP_WRAP_ALLOW_PRIVATE_IMAGE_URLS", "").lower()
    in ("1", "true", "yes")
)


def allow_private_fetch() -> bool:
    """Return True when SSRF guard is disabled (dev/local mode).

    Read at module import time; if the env var is flipped after the
    wrapper boots, the change doesn't take effect until the wrapper
    restarts. Intentional — we don't want a request-time env mutation
    to relax sandboxing on a running service.
    """
    return _ALLOW_PRIVATE_FETCH


def is_blocked_host(host: str) -> tuple[bool, str]:
    """Return (blocked, reason). True means refuse to dial.

    Resolves every address the hostname maps to (not just the first) so a
    DNS that returns multiple A records can't smuggle a private destination
    past a per-record check.
    """
    try:
        infos = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        return True, f"DNS resolution failed for {host!r}: {exc}"
    seen: list[str] = []
    for info in infos:
        sockaddr = info[4]
        raw = sockaddr[0] if sockaddr else ""
        addr = str(raw) if raw else ""
        if not addr or addr in seen:
            continue
        seen.append(addr)
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            return True, f"unparseable address {addr!r} for host {host!r}"
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_multicast
            or ip.is_reserved
            or ip.is_unspecified
        ):
            return True, (
                f"refusing to fetch URL with host {host!r} → {addr} "
                f"(private / loopback / link-local / reserved range)"
            )
    return False, ""
