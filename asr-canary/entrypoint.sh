#!/bin/sh
# asr-canary entrypoint — drops privileges, prefetches optional models, exec server.
set -eu

: "${ASR_CANARY_HOST:=0.0.0.0}"
: "${ASR_CANARY_PORT:=8000}"
: "${ASR_CANARY_DEVICE:=auto}"
: "${ASR_CANARY_MODELS_FILE:=/app/models.json}"
: "${ASR_CANARY_DATA_DIR:=/data}"
: "${HF_HOME:=${ASR_CANARY_DATA_DIR}/hf}"
: "${NEMO_CACHE_DIR:=${ASR_CANARY_DATA_DIR}/nemo}"

export ASR_CANARY_HOST ASR_CANARY_PORT ASR_CANARY_DEVICE
export ASR_CANARY_MODELS_FILE ASR_CANARY_DATA_DIR
export HF_HOME NEMO_CACHE_DIR

mkdir -p "${HF_HOME}" "${NEMO_CACHE_DIR}"

# Optional prefetch — pulls model snapshots into HF cache before server starts.
# Useful for prod boxes that want all models cached on disk on first boot.
if [ -n "${ASR_CANARY_PREFETCH:-}" ]; then
    echo "[entrypoint] prefetching: ${ASR_CANARY_PREFETCH}"
    python3 -c "
import os, sys
from huggingface_hub import snapshot_download
repos = [s.strip() for s in os.environ['ASR_CANARY_PREFETCH'].split(',') if s.strip()]
import json
with open(os.environ['ASR_CANARY_MODELS_FILE']) as fh:
    reg = json.load(fh)['models']
for slug in repos:
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

exec python3 -m asr_canary
