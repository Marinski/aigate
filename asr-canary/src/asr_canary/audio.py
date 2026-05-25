"""Audio upload preprocessing — convert any container/codec to 16kHz mono WAV.

NeMo Canary's `.transcribe()` accepts file paths (any format soundfile/librosa
recognise) plus numpy arrays. The safe lowest-common-denominator is 16kHz mono
WAV on disk. Conversion via ffmpeg subprocess — librosa-soxr is faster but
ffmpeg covers a broader codec matrix (webm/m4a/opus/etc.) without extra deps.
"""

from __future__ import annotations

import os
import subprocess
import tempfile


class AudioConversionError(Exception):
    pass


def to_wav_16k_mono(raw_bytes: bytes, original_filename: str) -> str:
    """Write `raw_bytes` to a temp file, convert to 16kHz mono WAV, return WAV path.

    Caller is responsible for deleting both the input temp + the output WAV.
    """
    if not raw_bytes:
        raise AudioConversionError("upload is empty")

    suffix = ""
    if "." in original_filename:
        ext = original_filename.rsplit(".", 1)[-1].lower()
        if ext and len(ext) <= 8:
            suffix = "." + ext

    in_fd, in_path = tempfile.mkstemp(prefix="asrcanary-in-", suffix=suffix)
    try:
        with os.fdopen(in_fd, "wb") as fh:
            fh.write(raw_bytes)
    except Exception:
        os.unlink(in_path)
        raise

    out_fd, out_path = tempfile.mkstemp(prefix="asrcanary-out-", suffix=".wav")
    os.close(out_fd)

    cmd = [
        "ffmpeg",
        "-loglevel", "error",
        "-y",
        "-i", in_path,
        "-vn",
        "-ac", "1",
        "-ar", "16000",
        "-acodec", "pcm_s16le",
        out_path,
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            timeout=120,
        )
    finally:
        try:
            os.unlink(in_path)
        except OSError:
            pass

    if proc.returncode != 0:
        try:
            os.unlink(out_path)
        except OSError:
            pass
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise AudioConversionError(f"ffmpeg failed: {stderr or 'unknown error'}")

    return out_path
