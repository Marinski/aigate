#!/bin/sh
# vllm entrypoint — drops privileges, prefetches optional models, exec server.
set -eu

: "${VLLM_WRAP_HOST:=0.0.0.0}"
: "${VLLM_WRAP_PORT:=8000}"
: "${VLLM_WRAP_SUBPROCESS_PORT:=18000}"
: "${VLLM_WRAP_MODELS_FILE:=/app/models.json}"
: "${VLLM_WRAP_DATA_DIR:=/data}"
: "${HF_HOME:=${VLLM_WRAP_DATA_DIR}/hf}"

export VLLM_WRAP_HOST VLLM_WRAP_PORT VLLM_WRAP_SUBPROCESS_PORT
export VLLM_WRAP_MODELS_FILE VLLM_WRAP_DATA_DIR
export HF_HOME

mkdir -p "${HF_HOME}"

# Optional prefetch — pulls model snapshots into HF cache before server starts.
# VLLM_WRAP_PREFETCH is comma-separated model_id slugs (resolved via models.json).
if [ -n "${VLLM_WRAP_PREFETCH:-}" ]; then
    echo "[entrypoint] prefetching: ${VLLM_WRAP_PREFETCH}"
    python3 -c "
import os, sys, json
from huggingface_hub import snapshot_download
with open(os.environ['VLLM_WRAP_MODELS_FILE']) as fh:
    reg = json.load(fh)['models']
for slug in [s.strip() for s in os.environ['VLLM_WRAP_PREFETCH'].split(',') if s.strip()]:
    if slug not in reg:
        print(f'[entrypoint] prefetch: unknown model_id {slug!r} — skipping', file=sys.stderr)
        continue
    repo = reg[slug]['repo']
    print(f'[entrypoint] prefetch: {slug} -> {repo}')
    try:
        snapshot_download(repo)
    except Exception as e:
        print(f'[entrypoint] prefetch {repo} failed: {e}', file=sys.stderr)
"
fi

exec python3 -m vllm_wrap
