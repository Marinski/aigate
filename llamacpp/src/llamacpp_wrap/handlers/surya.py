"""Surya OCR 2 — per-request orchestration for PDF input.

llama-server only accepts images. Surya OCR 2's promised UX is "OCR a
document"; for any document worth OCR'ing, that document is a PDF. This
handler closes the gap by detecting PDF input in the OpenAI chat
completions payload, rasterizing each page server-side, looping the
chat completion per page, and stitching the per-page responses back
into one final response keyed by Surya's prompt mode.

Detection — a content item is treated as a PDF when:
  - its `image_url.url` is a `data:application/pdf;base64,...` URL, OR
  - its `image_url.url` is an `http(s)://` URL whose fetched body comes
    back with `Content-Type: application/pdf` (or any `application/pdf*`
    variant).

DPI rescale — caller controls page rasterization DPI via the
`dpi_rescale_to` OpenAI extras field (top-level body, set via
`extra_body=` on official SDK clients):

  - `-1`            render at the page's native DPI (no rescale).
  - `N` (default 96) render at `min(N, native_dpi)`. Only downscales.

`native_dpi` is the max DPI of any raster image embedded on that page
(probed via `pdfimages -list`). For purely-vector pages (no embedded
raster, e.g. text-only PDFs created by LaTeX / Word / Google Docs)
`native_dpi` falls back to 96, so the default render is 96 DPI and
`-1` also resolves to 96 — both safe + fast.

Prompt-mode detection — Surya's behaviour switches on the trained-time
prompt string. The handler matches the user's text content against the
4 known prompts to decide how to stitch per-page responses:

  - Block OCR ("OCR this block image to HTML.") — single-image only;
    fail with 400 when given a PDF.
  - Full-page OCR — concat HTML per page, each wrapped in
    `<div data-page="N">...</div>`.
  - Layout detection — concat JSON arrays, each entry gains a `"page"`
    field.
  - Table recognition — same as layout.
  - Anything else — pass through as plaintext concat with page
    separators, since we can't safely assume a parseable structure.

Failure isolation — one page erroring (model decode failure, malformed
JSON response, etc.) does NOT abort the request. The stitcher records
the per-page failure in a top-level `page_errors` field on the
returned response so the client can decide whether to retry.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import httpx
from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse, Response

from .base import Forward


log = logging.getLogger("llamacpp_wrap.handlers.surya")


# Bounds — same shape as the wrapper's general URL fetch limits.
_PDF_FETCH_MAX_BYTES = 64 * 1024 * 1024
_PDF_FETCH_TIMEOUT_SECONDS = 60.0

# Per-page render fallback when a PDF has no embedded raster (pure vector
# / text-only). Also serves as the default ceiling for the `-1` "use
# native DPI" path on those pages.
_VECTOR_FALLBACK_DPI = 96
# Safety cap so a hostile or mistuned `dpi_rescale_to` value (or a wild
# native DPI on a scan) doesn't blow up the encoder.
_DPI_HARD_CAP = 600

# Verbatim Surya training-time prompts (from datalab-to/surya:surya/
# inference/prompts.py). Block OCR has a single canonical string; the
# other modes are matched on prefix substrings since the trailing detail
# of each prompt occasionally varies in the wild.
_PROMPT_BLOCK = "OCR this block image to HTML."
_PROMPT_PAGE_PREFIX = "OCR this image to HTML"
_PROMPT_LAYOUT_PREFIX = "Output the layout of this image as JSON"
_PROMPT_TABLE_PREFIX = "Output the table rows then columns as JSON"


class SuryaHandler:
    """See module docstring."""

    async def handle(
        self,
        *,
        request: Request,
        payload: dict[str, Any],
        forward: Forward,
    ) -> Response | None:
        del request  # not needed; payload + forward are sufficient

        # Pull and strip the dpi knob before forwarding — it's a wrapper
        # extension, not part of llama-server's accepted body.
        dpi_rescale_to = self._pop_dpi_rescale_to(payload)

        # Locate every PDF reference in the payload. Each `_PdfRef`
        # records where (which message + content index) the PDF lives so
        # we can replace it with a per-page rasterized image when we
        # loop. Multiple PDFs in one request is allowed but unusual —
        # we handle each independently and concatenate page outputs.
        pdf_refs = await self._collect_pdfs(payload)
        if not pdf_refs:
            return None  # nothing PDF-shaped → fall through to default proxy.

        # Detect Surya prompt mode from the user's text content; reject
        # block mode (single-image only).
        mode = self._detect_mode(payload)
        if mode == "block":
            raise HTTPException(
                status_code=400,
                detail=(
                    "Surya block OCR is single-image only; PDFs must use "
                    "full-page OCR, layout, or table-recognition mode. "
                    "Crop the relevant block client-side and resubmit "
                    "with the block OCR prompt + a single image_url."
                ),
            )

        # Rasterize every PDF to per-page PNGs in a single tmpdir, then
        # build one OCR call per page in order. For multiple PDFs the
        # pages are concatenated (PDF #1 page 1..M, then PDF #2 page
        # 1..N, etc.).
        with tempfile.TemporaryDirectory(prefix="llamacpp-surya-") as tmp:
            tmp_path = Path(tmp)
            pages = []
            for ref in pdf_refs:
                rasterized = await asyncio.to_thread(
                    self._rasterize_pdf,
                    ref.bytes_,
                    dpi_rescale_to,
                    tmp_path,
                )
                for page_idx, png_path in enumerate(rasterized, start=1):
                    pages.append(_Page(
                        ref=ref,
                        page_number=page_idx,
                        png_path=png_path,
                    ))

            log.info(
                "surya: %d PDF(s) → %d page(s) at dpi_rescale_to=%s; mode=%s",
                len(pdf_refs),
                len(pages),
                dpi_rescale_to,
                mode,
            )

            results: list[dict[str, Any]] = []
            for global_idx, page in enumerate(pages, start=1):
                per_page_payload = self._build_page_payload(
                    payload=payload,
                    ref=page.ref,
                    png_path=page.png_path,
                )
                start = time.monotonic()
                try:
                    resp = await forward(per_page_payload)
                except Exception as exc:  # noqa: BLE001
                    log.warning(
                        "surya: page %d (PDF byte#%d → page %d) forward error: %s",
                        global_idx,
                        page.ref.index,
                        page.page_number,
                        exc,
                    )
                    results.append({"page": global_idx, "error": str(exc)})
                    continue
                elapsed_ms = int((time.monotonic() - start) * 1000)
                parsed = self._parse_forward_response(resp)
                if "error" in parsed:
                    log.warning(
                        "surya: page %d returned non-200 / unparseable response: %s",
                        global_idx,
                        parsed["error"][:200],
                    )
                results.append({
                    "page": global_idx,
                    "elapsed_ms": elapsed_ms,
                    **parsed,
                })

        stitched = self._stitch(mode=mode, results=results)
        return JSONResponse(content=stitched, status_code=200)

    # ── content discovery + dpi knob ──────────────────────────────────────

    @staticmethod
    def _pop_dpi_rescale_to(payload: dict[str, Any]) -> int:
        raw = payload.pop("dpi_rescale_to", 96)
        if raw is None:
            return 96
        if isinstance(raw, bool):
            raise HTTPException(
                status_code=400,
                detail="dpi_rescale_to must be -1 or a positive integer",
            )
        try:
            value = int(raw)
        except (TypeError, ValueError) as exc:
            raise HTTPException(
                status_code=400,
                detail=f"dpi_rescale_to={raw!r} is not an integer",
            ) from exc
        if value == -1:
            return -1
        if value <= 0:
            raise HTTPException(
                status_code=400,
                detail="dpi_rescale_to must be -1 or a positive integer",
            )
        if value > _DPI_HARD_CAP:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"dpi_rescale_to={value} exceeds the safety cap "
                    f"({_DPI_HARD_CAP}); rasterizing at that DPI would "
                    f"produce an impractically large image"
                ),
            )
        return value

    async def _collect_pdfs(
        self,
        payload: dict[str, Any],
    ) -> list["_PdfRef"]:
        refs: list[_PdfRef] = []
        messages = payload.get("messages")
        if not isinstance(messages, list):
            return refs
        async with httpx.AsyncClient() as client:
            for msg_idx, msg in enumerate(messages):
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                for item_idx, item in enumerate(content):
                    if not isinstance(item, dict):
                        continue
                    if item.get("type") != "image_url":
                        continue
                    iu = item.get("image_url")
                    if not isinstance(iu, dict):
                        continue
                    url = iu.get("url")
                    if not isinstance(url, str):
                        continue
                    pdf_bytes = await self._maybe_pdf_bytes(url, client)
                    if pdf_bytes is None:
                        continue
                    refs.append(_PdfRef(
                        index=len(refs),
                        msg_idx=msg_idx,
                        item_idx=item_idx,
                        bytes_=pdf_bytes,
                    ))
        return refs

    async def _maybe_pdf_bytes(
        self,
        url: str,
        client: httpx.AsyncClient,
    ) -> bytes | None:
        # data:application/pdf;base64,...
        if url.startswith("data:"):
            head, _, body = url.partition(",")
            if not body:
                return None
            mime_part = head[len("data:"):]
            mime = mime_part.split(";", 1)[0].strip().lower()
            if not mime.startswith("application/pdf"):
                return None
            if ";base64" not in head.lower():
                # Non-base64 data URLs for PDFs are vanishingly rare;
                # surface a 400 so the client knows what to fix.
                raise HTTPException(
                    status_code=400,
                    detail="application/pdf data URLs must be base64-encoded",
                )
            try:
                return base64.b64decode(body, validate=True)
            except (binascii.Error, ValueError) as exc:
                raise HTTPException(
                    status_code=400,
                    detail=f"PDF data URL base64 decode failed: {exc}",
                ) from exc
        if url.startswith("http://") or url.startswith("https://"):
            try:
                r = await client.get(
                    url,
                    timeout=_PDF_FETCH_TIMEOUT_SECONDS,
                    follow_redirects=True,
                )
            except httpx.HTTPError as exc:
                raise HTTPException(
                    status_code=400,
                    detail=f"could not fetch image_url {url!r}: {exc}",
                ) from exc
            if r.status_code != 200:
                raise HTTPException(
                    status_code=400,
                    detail=f"image_url {url!r} returned HTTP {r.status_code}",
                )
            ct = (r.headers.get("content-type") or "").split(";", 1)[0].strip().lower()
            # Trust an explicit application/pdf Content-Type. If the
            # remote omitted Content-Type but the URL ends in .pdf,
            # accept that too — common with public docs.
            if ct.startswith("application/pdf") or url.lower().split("?", 1)[0].endswith(".pdf"):
                data = r.content
                if len(data) > _PDF_FETCH_MAX_BYTES:
                    raise HTTPException(
                        status_code=413,
                        detail=(
                            f"PDF at {url!r} is {len(data)} bytes; max is "
                            f"{_PDF_FETCH_MAX_BYTES}"
                        ),
                    )
                return data
            return None
        return None

    # ── prompt-mode detection ─────────────────────────────────────────────

    def _detect_mode(self, payload: dict[str, Any]) -> str:
        text = self._collect_text_content(payload)
        # Block prompt is a single short canonical string — check it first
        # so a longer prompt that happens to contain "OCR this block" but
        # also continues into a layout / page prompt routes correctly.
        if _PROMPT_BLOCK in text:
            return "block"
        if _PROMPT_PAGE_PREFIX in text:
            return "page"
        if _PROMPT_LAYOUT_PREFIX in text:
            return "layout"
        if _PROMPT_TABLE_PREFIX in text:
            return "table"
        return "unknown"

    @staticmethod
    def _collect_text_content(payload: dict[str, Any]) -> str:
        chunks: list[str] = []
        for msg in payload.get("messages") or []:
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if isinstance(content, str):
                chunks.append(content)
                continue
            if not isinstance(content, list):
                continue
            for item in content:
                if isinstance(item, dict) and item.get("type") == "text":
                    t = item.get("text")
                    if isinstance(t, str):
                        chunks.append(t)
        return "\n".join(chunks)

    # ── PDF rasterization ─────────────────────────────────────────────────

    def _rasterize_pdf(
        self,
        pdf_bytes: bytes,
        dpi_rescale_to: int,
        tmp: Path,
    ) -> list[Path]:
        # Write input PDF to a stable tmp path; pdftoppm reads from disk.
        slug = f"pdf-{id(pdf_bytes):x}"
        pdf_path = tmp / f"{slug}.pdf"
        pdf_path.write_bytes(pdf_bytes)
        page_count = self._pdfinfo_page_count(pdf_path)
        per_page_native = self._pdfimages_native_dpi_per_page(
            pdf_path, page_count
        )
        out_dir = tmp / f"{slug}-pages"
        out_dir.mkdir(exist_ok=True)
        png_paths: list[Path] = []
        for page in range(1, page_count + 1):
            native = per_page_native.get(page, _VECTOR_FALLBACK_DPI)
            if dpi_rescale_to == -1:
                chosen = native
            else:
                chosen = min(dpi_rescale_to, native)
            # Clamp on the way out — defensive against pathological
            # `pdfimages` outputs (e.g. embedded SVG-render claiming
            # several-thousand DPI).
            chosen = max(1, min(chosen, _DPI_HARD_CAP))
            prefix = out_dir / f"p{page:04d}"
            subprocess.run(
                [
                    "pdftoppm",
                    "-png",
                    "-r", str(chosen),
                    "-f", str(page),
                    "-l", str(page),
                    str(pdf_path),
                    str(prefix),
                ],
                check=True,
                capture_output=True,
            )
            # pdftoppm writes <prefix>-<page-number>.png; on single-page
            # ranges the suffix is `-1.png` (relative to -f/-l, not the
            # absolute page number).
            produced = sorted(out_dir.glob(f"p{page:04d}-*.png"))
            if not produced:
                raise HTTPException(
                    status_code=500,
                    detail=f"pdftoppm produced no output for page {page}",
                )
            png_paths.append(produced[0])
        return png_paths

    @staticmethod
    def _pdfinfo_page_count(pdf_path: Path) -> int:
        out = subprocess.run(
            ["pdfinfo", str(pdf_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        for line in out.stdout.splitlines():
            if line.startswith("Pages:"):
                try:
                    return int(line.split(":", 1)[1].strip())
                except ValueError:
                    pass
        raise HTTPException(
            status_code=400, detail="could not read PDF page count"
        )

    @staticmethod
    def _pdfimages_native_dpi_per_page(
        pdf_path: Path,
        page_count: int,
    ) -> dict[int, int]:
        # pdfimages -list output (one row per embedded image):
        #   page num  type   width height color comp bpc enc interp obj id x-dpi y-dpi size ratio
        #     1    0   image   2480  3508  rgb     3   8 jpeg yes      9  0   300   300  482K 1.9%
        # Header + separator before the data. We pick the max(x-dpi,
        # y-dpi) per row and reduce to max per page.
        try:
            out = subprocess.run(
                ["pdfimages", "-list", str(pdf_path)],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            log.warning("pdfimages -list failed: %s", exc.stderr[:200])
            return {p: _VECTOR_FALLBACK_DPI for p in range(1, page_count + 1)}
        per_page: dict[int, int] = {}
        for line in out.stdout.splitlines():
            fields = line.split()
            if len(fields) < 14:
                continue
            try:
                page_num = int(fields[0])
                x_dpi = int(float(fields[12]))
                y_dpi = int(float(fields[13]))
            except ValueError:
                continue
            dpi = max(x_dpi, y_dpi)
            if dpi <= 0:
                continue
            prev = per_page.get(page_num, 0)
            if dpi > prev:
                per_page[page_num] = dpi
        # Fill in vector-only pages with the safe default.
        for page in range(1, page_count + 1):
            per_page.setdefault(page, _VECTOR_FALLBACK_DPI)
        return per_page

    # ── per-page payload construction + response parsing ──────────────────

    @staticmethod
    def _build_page_payload(
        *,
        payload: dict[str, Any],
        ref: "_PdfRef",
        png_path: Path,
    ) -> dict[str, Any]:
        # Deep-ish copy: replace just the messages structure (the only
        # bit we mutate). Everything else (model, max_tokens, sampling
        # knobs) is shared across page calls.
        png_b64 = base64.b64encode(png_path.read_bytes()).decode("ascii")
        data_url = f"data:image/png;base64,{png_b64}"
        messages = [dict(m) if isinstance(m, dict) else m
                    for m in (payload.get("messages") or [])]
        for m_idx, msg in enumerate(messages):
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            new_content = []
            for c_idx, item in enumerate(content):
                if (m_idx == ref.msg_idx and c_idx == ref.item_idx
                        and isinstance(item, dict)
                        and item.get("type") == "image_url"):
                    new_content.append({
                        "type": "image_url",
                        "image_url": {"url": data_url},
                    })
                    continue
                # Drop any OTHER PDFs from this per-page payload — they
                # belong to later iterations of the outer loop.
                if isinstance(item, dict) and item.get("type") == "image_url":
                    iu = item.get("image_url") or {}
                    url = iu.get("url") if isinstance(iu, dict) else None
                    if isinstance(url, str) and (
                        url.startswith("data:application/pdf")
                        or url.lower().split("?", 1)[0].endswith(".pdf")
                    ):
                        continue
                new_content.append(item)
            messages[m_idx] = {**msg, "content": new_content}
        new_payload = dict(payload)
        new_payload["messages"] = messages
        # Streaming was nonsense for OCR; if the client set it, we still
        # disable it for per-page calls so the stitcher gets a clean
        # JSON body to merge.
        new_payload["stream"] = False
        return new_payload

    @staticmethod
    def _parse_forward_response(resp: Response) -> dict[str, Any]:
        # forward() always returns a fastapi.Response. The body lives in
        # .body for non-streamed responses (which is what we ask for).
        try:
            raw = bytes(resp.body) if resp.body is not None else b""
        except AttributeError:
            return {"error": "forward returned a non-buffer response"}
        if resp.status_code != 200:
            return {
                "error": f"HTTP {resp.status_code}",
                "body": raw[:400].decode("utf-8", errors="replace"),
            }
        try:
            envelope = json.loads(raw)
        except json.JSONDecodeError as exc:
            return {"error": f"JSON decode failed: {exc}"}
        try:
            content = envelope["choices"][0]["message"]["content"]
        except (KeyError, IndexError, TypeError):
            return {"error": "response has no choices[0].message.content"}
        if not isinstance(content, str):
            return {"error": "content is not a string"}
        return {"content": content, "raw_envelope": envelope}

    # ── stitching ─────────────────────────────────────────────────────────

    def _stitch(
        self,
        *,
        mode: str,
        results: list[dict[str, Any]],
    ) -> dict[str, Any]:
        page_errors: list[dict[str, Any]] = []
        ok_pages: list[dict[str, Any]] = []
        for entry in results:
            if "error" in entry and "content" not in entry:
                page_errors.append({
                    "page": entry["page"],
                    "error": entry["error"],
                })
                continue
            ok_pages.append(entry)

        if mode == "page":
            stitched_content = self._stitch_page_html(ok_pages)
        elif mode in ("layout", "table"):
            stitched_content = self._stitch_json_array(ok_pages)
        else:
            stitched_content = self._stitch_plain(ok_pages)

        out: dict[str, Any] = {
            "object": "chat.completion",
            "model": (ok_pages[0]["raw_envelope"].get("model")
                      if ok_pages else None),
            "choices": [{
                "index": 0,
                "finish_reason": "stop",
                "message": {
                    "role": "assistant",
                    "content": stitched_content,
                },
            }],
            "usage": self._merge_usage(ok_pages),
            "x_surya_pages": len(results),
            "x_surya_mode": mode,
        }
        if page_errors:
            out["page_errors"] = page_errors
        return out

    @staticmethod
    def _stitch_page_html(ok_pages: list[dict[str, Any]]) -> str:
        chunks = []
        for entry in ok_pages:
            page_num = entry["page"]
            inner = entry["content"]
            chunks.append(f'<div data-page="{page_num}">\n{inner}\n</div>')
        return "\n".join(chunks)

    @staticmethod
    def _stitch_json_array(ok_pages: list[dict[str, Any]]) -> str:
        merged: list[dict[str, Any]] = []
        for entry in ok_pages:
            page_num = entry["page"]
            text = entry["content"]
            # Defensive JSON parse — Surya occasionally emits stray
            # whitespace / BOM before the array. Match the first bracket
            # span.
            m = re.search(r"\[.*\]", text, re.DOTALL)
            if not m:
                merged.append({
                    "page": page_num,
                    "error": "no JSON array in response",
                    "raw": text[:200],
                })
                continue
            try:
                arr = json.loads(m.group(0))
            except json.JSONDecodeError:
                merged.append({
                    "page": page_num,
                    "error": "JSON array failed to parse",
                    "raw": text[:200],
                })
                continue
            if not isinstance(arr, list):
                merged.append({
                    "page": page_num,
                    "error": "top-level JSON is not an array",
                    "raw": text[:200],
                })
                continue
            for elt in arr:
                if isinstance(elt, dict):
                    merged.append({**elt, "page": page_num})
                else:
                    merged.append({"page": page_num, "value": elt})
        return json.dumps(merged, ensure_ascii=False)

    @staticmethod
    def _stitch_plain(ok_pages: list[dict[str, Any]]) -> str:
        return "\n".join(
            f"<!-- page {entry['page']} -->\n{entry['content']}"
            for entry in ok_pages
        )

    @staticmethod
    def _merge_usage(ok_pages: list[dict[str, Any]]) -> dict[str, int]:
        prompt = completion = total = 0
        for entry in ok_pages:
            usage = entry["raw_envelope"].get("usage") or {}
            prompt += int(usage.get("prompt_tokens") or 0)
            completion += int(usage.get("completion_tokens") or 0)
            total += int(usage.get("total_tokens") or 0)
        return {
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": total,
        }


# ── internal dataclasses-ish records ──────────────────────────────────────


class _PdfRef:
    __slots__ = ("index", "msg_idx", "item_idx", "bytes_")

    def __init__(self, index: int, msg_idx: int, item_idx: int, bytes_: bytes):
        self.index = index
        self.msg_idx = msg_idx
        self.item_idx = item_idx
        self.bytes_ = bytes_


class _Page:
    __slots__ = ("ref", "page_number", "png_path")

    def __init__(self, ref: _PdfRef, page_number: int, png_path: Path):
        self.ref = ref
        self.page_number = page_number
        self.png_path = png_path


def _ensure_poppler_present() -> None:
    """Best-effort module-load probe so an operator missing poppler-utils
    learns about it at boot rather than at first PDF request."""
    for binary in ("pdftoppm", "pdfimages", "pdfinfo"):
        if shutil.which(binary) is None:
            log.warning(
                "surya handler loaded but %s is not on PATH — PDF requests "
                "will 500 until poppler-utils is installed in the image",
                binary,
            )
            break


_ensure_poppler_present()
