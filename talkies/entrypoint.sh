#!/bin/sh
# talkies entrypoint — drops privileges, prefetches optional models, exec server.
set -eu

: "${TALKIES_HOST:=0.0.0.0}"
: "${TALKIES_PORT:=8000}"
: "${TALKIES_DEVICE:=auto}"
: "${TALKIES_MODELS_FILE:=/app/models.json}"
: "${TALKIES_DATA_DIR:=/data}"
: "${HF_HOME:=${TALKIES_DATA_DIR}/hf}"
: "${NEMO_CACHE_DIR:=${TALKIES_DATA_DIR}/nemo}"

export TALKIES_HOST TALKIES_PORT TALKIES_DEVICE
export TALKIES_MODELS_FILE TALKIES_DATA_DIR
export HF_HOME NEMO_CACHE_DIR

mkdir -p "${HF_HOME}" "${NEMO_CACHE_DIR}"

# Optional prefetch — pulls model snapshots into HF cache before server starts.
# Useful for prod boxes that want all models cached on disk on first boot.
if [ -n "${TALKIES_PREFETCH:-}" ]; then
    echo "[entrypoint] prefetching: ${TALKIES_PREFETCH}"
    python3 -c "
import os, sys
from huggingface_hub import snapshot_download
repos = [s.strip() for s in os.environ['TALKIES_PREFETCH'].split(',') if s.strip()]
import json
with open(os.environ['TALKIES_MODELS_FILE']) as fh:
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

exec python3 -m talkies
