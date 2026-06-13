#!/bin/sh
# llamacpp entrypoint — drops privileges and execs the wrapper. No model
# download / prefetch happens here — that's the `llamacpp-pull` sidecar's
# job. Wrapper runs in strict HF_HUB_OFFLINE mode and depends on
# llamacpp-pull having populated /data/models/<repo>/ before boot.
set -eu

: "${LLAMACPP_WRAP_HOST:=0.0.0.0}"
: "${LLAMACPP_WRAP_PORT:=8000}"
: "${LLAMACPP_WRAP_SUBPROCESS_PORT:=18000}"
: "${LLAMACPP_WRAP_MODELS_FILE:=/app/models.json}"
: "${LLAMACPP_WRAP_DATA_DIR:=/data}"
: "${HF_HOME:=${LLAMACPP_WRAP_DATA_DIR}/hf}"

export LLAMACPP_WRAP_HOST LLAMACPP_WRAP_PORT LLAMACPP_WRAP_SUBPROCESS_PORT
export LLAMACPP_WRAP_MODELS_FILE LLAMACPP_WRAP_DATA_DIR
export HF_HOME

mkdir -p "${HF_HOME}"

exec python3 -m llamacpp_wrap
