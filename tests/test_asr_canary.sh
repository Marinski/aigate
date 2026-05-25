#!/bin/bash

# ── asr-canary: gated on ASR_CANARY=1 or ASR_CANARY_CUDA=1 ────────────────────
#
# asr-canary is reachable on the aigate-internal network only — no nginx route.
# These tests use the LiteLLM proxy (which IS on aigate-internal) as the entry
# point: model registration is asserted via /v1/models (covered in test_litellm),
# and the service-specific endpoints are exercised through docker exec into the
# litellm container so we can hit http://asr-canary:8000 directly.

_asr_canary_enabled() {
    [ "${ASR_CANARY:-0}" = "1" ] || [ "${ASR_CANARY_CUDA:-0}" = "1" ]
}

_asr_canary_host() {
    if [ "${ASR_CANARY_CUDA:-0}" = "1" ]; then
        echo "asr-canary-cuda"
        return
    fi
    echo "asr-canary"
}

_asr_canary_exec() {
    local host
    host=$(_asr_canary_host)
    docker compose exec -T litellm python3 -c "
import sys, urllib.request
req = urllib.request.Request('http://${host}:8000$1')
sys.stdout.write(urllib.request.urlopen(req, timeout=10).read().decode())
" 2>/dev/null
}

_asr_canary_exec_method() {
    local method="$1" path="$2"
    local host
    host=$(_asr_canary_host)
    docker compose exec -T litellm python3 -c "
import sys, urllib.request
req = urllib.request.Request('http://${host}:8000${path}', method='${method}')
sys.stdout.write(urllib.request.urlopen(req, timeout=10).read().decode())
" 2>/dev/null
}

_asr_canary_exec_status() {
    local method="$1" path="$2"
    local host
    host=$(_asr_canary_host)
    docker compose exec -T litellm python3 -c "
import urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request('http://${host}:8000${path}', method='${method}'), timeout=10)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
" 2>/dev/null
}

# ── /healthz reachable, returns device + configured model_ids ─────────────────

test_asr_canary_healthz() {
    _asr_canary_enabled || { echo "  SKIP: ASR_CANARY not enabled"; return 0; }
    local out
    out=$(_asr_canary_exec "/healthz") || {
        echo "  FAIL: /healthz unreachable"
        return 1
    }
    assert_contains "$out" "\"ok\":true" "/healthz ok=true" || return 1
    assert_contains "$out" "canary-180m-flash" "/healthz lists canary-180m-flash" || return 1
    echo "OK: asr_canary_healthz"
}

# ── /v1/models lists configured model_ids in OpenAI shape ─────────────────────

test_asr_canary_models_list() {
    _asr_canary_enabled || { echo "  SKIP: ASR_CANARY not enabled"; return 0; }
    local out
    out=$(_asr_canary_exec "/v1/models") || {
        echo "  FAIL: /v1/models unreachable"
        return 1
    }
    assert_contains "$out" "\"object\":\"list\"" "/v1/models openai shape" || return 1
    assert_contains "$out" "canary-180m-flash" "/v1/models has canary-180m-flash" || return 1
    if [ "${ASR_CANARY_CUDA:-0}" = "1" ]; then
        assert_contains "$out" "canary-1b-flash" "/v1/models has canary-1b-flash (CUDA)" || return 1
        assert_contains "$out" "canary-qwen-2.5b" "/v1/models has canary-qwen-2.5b (CUDA)" || return 1
    fi
    echo "OK: asr_canary_models_list"
}

# ── /api/ps returns loaded list (may be empty before first transcription) ─────

test_asr_canary_api_ps() {
    _asr_canary_enabled || { echo "  SKIP: ASR_CANARY not enabled"; return 0; }
    local out
    out=$(_asr_canary_exec "/api/ps") || {
        echo "  FAIL: /api/ps unreachable"
        return 1
    }
    assert_contains "$out" "models" "/api/ps has models field (speaches-compat shape)" || return 1
    echo "OK: asr_canary_api_ps"
}

# ── POST /unload accepted even when nothing is loaded ─────────────────────────

test_asr_canary_unload_all() {
    _asr_canary_enabled || { echo "  SKIP: ASR_CANARY not enabled"; return 0; }
    _asr_canary_exec_method POST "/unload" >/dev/null || {
        echo "  FAIL: POST /unload"
        return 1
    }
    echo "OK: asr_canary_unload_all"
}

# ── live transcription via LiteLLM proxy (gated on fixtures/audio.wav) ───────

test_asr_canary_transcribe_live() {
    _asr_canary_enabled || { echo "  SKIP: ASR_CANARY not enabled"; return 0; }
    local fixture=""
    for ext in wav mp3 m4a flac ogg; do
        if [ -f "tests/.fixtures/audio.${ext}" ]; then
            fixture="tests/.fixtures/audio.${ext}"
            break
        fi
    done
    [ -n "$fixture" ] || { echo "  SKIP: tests/.fixtures/audio.{wav,mp3,m4a,flac,ogg} missing"; return 0; }

    local model="local-asr-canary-180m-flash"
    if [ "${ASR_CANARY_CUDA:-0}" = "1" ]; then
        model="local-asr-canary-cuda-180m-flash"
    fi

    local out
    out=$(curl -sf -m 120 -X POST "$BASE_URL/v1/audio/transcriptions" \
        -H "$AUTH_HEADER" \
        -F "file=@${fixture}" \
        -F "model=${model}") || {
        echo "  FAIL: POST /v1/audio/transcriptions (model=$model)"
        return 1
    }
    assert_contains "$out" "\"text\"" "response has text field" || return 1
    local text
    text=$(echo "$out" | jq -r '.text' 2>/dev/null || echo "")
    [ -n "$text" ] && [ "$text" != "null" ] || {
        echo "  FAIL: empty transcription text"
        return 1
    }
    echo "OK: asr_canary_transcribe_live (model=$model, fixture=$fixture, text=\"$text\")"
}

# ── DELETE /api/ps/{model} on never-loaded model returns 404 (speaches-compat) ─

test_asr_canary_delete_unknown_returns_404() {
    _asr_canary_enabled || { echo "  SKIP: ASR_CANARY not enabled"; return 0; }
    local code
    code=$(_asr_canary_exec_status DELETE "/api/ps/canary-180m-flash")
    case "$code" in
        200|404) ;;
        *)
            echo "  FAIL: DELETE /api/ps/canary-180m-flash unexpected status=$code"
            return 1
            ;;
    esac
    echo "OK: asr_canary_delete_unknown_returns_404 (status=$code)"
}

ALL_TESTS+=(
    test_asr_canary_healthz
    test_asr_canary_models_list
    test_asr_canary_api_ps
    test_asr_canary_unload_all
    test_asr_canary_delete_unknown_returns_404
    test_asr_canary_transcribe_live
)
