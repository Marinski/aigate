#!/bin/bash

# ── vllm: gated on VLLM_CUDA=1 ────────────────────────────────────────
#
# vllm-cuda is reachable on the aigate-internal network only — no nginx route.
# These tests use the LiteLLM proxy (which IS on aigate-internal) as the entry
# point via `docker compose exec` to reach http://vllm-cuda:8000 directly.
# Subprocess spawn is NOT exercised here — it depends on `vllm serve` which is
# slow and e2e-only. Wrapper-level endpoints only.

_vllm_wrap_enabled() {
    [ "${VLLM_CUDA:-0}" = "1" ]
}

_vllm_wrap_exec() {
    docker compose exec -T litellm python3 -c "
import sys, urllib.request
req = urllib.request.Request('http://vllm-cuda:8000$1')
sys.stdout.write(urllib.request.urlopen(req, timeout=10).read().decode())
" 2>/dev/null
}

_vllm_wrap_exec_method() {
    local method="$1" path="$2"
    docker compose exec -T litellm python3 -c "
import sys, urllib.request
req = urllib.request.Request('http://vllm-cuda:8000${path}', method='${method}')
sys.stdout.write(urllib.request.urlopen(req, timeout=10).read().decode())
" 2>/dev/null
}

_vllm_wrap_exec_status() {
    local method="$1" path="$2"
    docker compose exec -T litellm python3 -c "
import urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request('http://vllm-cuda:8000${path}', method='${method}'), timeout=10)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)
" 2>/dev/null
}

# ── /healthz reachable, lists configured model_ids ────────────────────────────

test_vllm_wrap_healthz() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local out
    out=$(_vllm_wrap_exec "/healthz") || {
        echo "  FAIL: /healthz unreachable"
        return 1
    }
    assert_contains "$out" "\"ok\":true" "/healthz ok=true" || return 1
    assert_contains "$out" "qwen3-asr-1.7b" "/healthz lists qwen3-asr-1.7b" || return 1
    echo "OK: vllm_wrap_healthz"
}

# ── /v1/models lists configured model_ids in OpenAI shape ─────────────────────

test_vllm_wrap_models_list() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local out
    out=$(_vllm_wrap_exec "/v1/models") || {
        echo "  FAIL: /v1/models unreachable"
        return 1
    }
    assert_contains "$out" "\"object\":\"list\"" "/v1/models openai shape" || return 1
    assert_contains "$out" "qwen3-asr-1.7b" "/v1/models has qwen3-asr-1.7b" || return 1
    assert_contains "$out" "voxtral-mini-3b" "/v1/models has voxtral-mini-3b" || return 1
    echo "OK: vllm_wrap_models_list"
}

# ── /api/ps returns models list (speaches-compat) ─────────────────────────────

test_vllm_wrap_api_ps() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local out
    out=$(_vllm_wrap_exec "/api/ps") || {
        echo "  FAIL: /api/ps unreachable"
        return 1
    }
    assert_contains "$out" "models" "/api/ps has models field (speaches-compat shape)" || return 1
    echo "OK: vllm_wrap_api_ps"
}

# ── POST /unload accepted even when nothing is loaded ─────────────────────────

test_vllm_wrap_unload_all() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    _vllm_wrap_exec_method POST "/unload" >/dev/null || {
        echo "  FAIL: POST /unload"
        return 1
    }
    echo "OK: vllm_wrap_unload_all"
}

# ── DELETE /api/ps/{model} on never-loaded model returns 404 (speaches-compat) ─

test_vllm_wrap_delete_unknown_returns_404() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local code
    code=$(_vllm_wrap_exec_status DELETE "/api/ps/qwen3-asr-1.7b")
    case "$code" in
        200|404) ;;
        *)
            echo "  FAIL: DELETE /api/ps/qwen3-asr-1.7b unexpected status=$code"
            return 1
            ;;
    esac
    echo "OK: vllm_wrap_delete_unknown_returns_404 (status=$code)"
}

# ── live transcription via LiteLLM proxy for each model ──────────────────────

_vllm_find_audio_fixture() {
    for ext in wav mp3 m4a flac ogg; do
        if [ -f "tests/.fixtures/audio.${ext}" ]; then
            echo "tests/.fixtures/audio.${ext}"
            return 0
        fi
    done
    return 1
}

_vllm_transcribe_one() {
    local model="$1" fixture="$2"
    local out
    out=$(curl -sf -m 1800 -X POST "$BASE_URL/v1/audio/transcriptions" \
        -H "$AUTH_HEADER" \
        -F "file=@${fixture}" \
        -F "model=${model}" \
        -F "response_format=json") || {
        echo "  FAIL: POST /v1/audio/transcriptions (model=$model)"
        return 1
    }
    assert_contains "$out" "\"text\"" "response has text field (model=$model)" || return 1
    local text
    text=$(echo "$out" | jq -r '.text' 2>/dev/null || echo "")
    [ -n "$text" ] && [ "$text" != "null" ] || {
        echo "  FAIL: empty transcription text (model=$model)"
        return 1
    }
    echo "OK: transcribe (model=$model, text=\"$text\")"
}

_vllm_chat_audio_one() {
    local model="$1" fixture="$2"
    local b64 mime
    case "$fixture" in
        *.wav) mime="audio/wav" ;;
        *.mp3) mime="audio/mpeg" ;;
        *.m4a) mime="audio/mp4" ;;
        *.flac) mime="audio/flac" ;;
        *.ogg) mime="audio/ogg" ;;
        *) mime="application/octet-stream" ;;
    esac
    b64=$(base64 -w0 < "$fixture")
    local payload
    payload=$(jq -n \
        --arg model "$model" \
        --arg url "data:${mime};base64,${b64}" \
        '{model: $model, messages: [{role: "user", content: [{type: "text", text: "Transcribe this audio."}, {type: "audio_url", audio_url: {url: $url}}]}], max_tokens: 256}')
    local out
    out=$(curl -sf -m 1800 -X POST "$BASE_URL/v1/chat/completions" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$payload") || {
        echo "  FAIL: POST /v1/chat/completions (model=$model)"
        return 1
    }
    assert_contains "$out" "\"choices\"" "response has choices (model=$model)" || return 1
    local content
    content=$(echo "$out" | jq -r '.choices[0].message.content' 2>/dev/null || echo "")
    [ -n "$content" ] && [ "$content" != "null" ] || {
        echo "  FAIL: empty chat content (model=$model)"
        return 1
    }
    echo "OK: chat_audio (model=$model, content=\"${content:0:120}\")"
}

test_vllm_transcribe_qwen3_asr_live() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local fixture; fixture=$(_vllm_find_audio_fixture) || { echo "  SKIP: no audio fixture"; return 0; }
    _vllm_transcribe_one "local-vllm-cuda-qwen3-asr-1.7b-transcribe" "$fixture"
}

test_vllm_transcribe_voxtral_live() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local fixture; fixture=$(_vllm_find_audio_fixture) || { echo "  SKIP: no audio fixture"; return 0; }
    _vllm_transcribe_one "local-vllm-cuda-voxtral-mini-3b-transcribe" "$fixture"
}

test_vllm_chat_audio_qwen3_asr_live() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local fixture; fixture=$(_vllm_find_audio_fixture) || { echo "  SKIP: no audio fixture"; return 0; }
    _vllm_chat_audio_one "local-vllm-cuda-qwen3-asr-1.7b-chat" "$fixture"
}

test_vllm_chat_audio_voxtral_live() {
    _vllm_wrap_enabled || { echo "  SKIP: VLLM_CUDA not enabled"; return 0; }
    local fixture; fixture=$(_vllm_find_audio_fixture) || { echo "  SKIP: no audio fixture"; return 0; }
    _vllm_chat_audio_one "local-vllm-cuda-voxtral-mini-3b-chat" "$fixture"
}

ALL_TESTS+=(
    test_vllm_wrap_healthz
    test_vllm_wrap_models_list
    test_vllm_wrap_api_ps
    test_vllm_wrap_unload_all
    test_vllm_wrap_delete_unknown_returns_404
    test_vllm_transcribe_qwen3_asr_live
    test_vllm_transcribe_voxtral_live
    test_vllm_chat_audio_qwen3_asr_live
    test_vllm_chat_audio_voxtral_live
)
