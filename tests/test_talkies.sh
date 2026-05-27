#!/bin/bash

# ── talkies: gated on TALKIES=1 or TALKIES_CUDA=1 ─────────────────────────────
#
# talkies is reachable on the aigate-internal network only — no nginx route.
# Tests exec into the litellm container (which IS on aigate-internal) and hit
# http://talkies:8000 (or talkies-cuda:8000) directly. Multipart file uploads
# are done by piping the fixture into a python urllib heredoc, so we don't
# depend on LiteLLM aliases existing yet — these tests validate the talkies
# service itself, not the proxy path.

_talkies_enabled() {
    [ "${TALKIES:-0}" = "1" ] || [ "${TALKIES_CUDA:-0}" = "1" ]
}

_talkies_host() {
    if [ "${TALKIES_CUDA:-0}" = "1" ]; then
        echo "talkies-cuda"
        return
    fi
    echo "talkies"
}

_talkies_models_for_mode() {
    if [ "${TALKIES_CUDA:-0}" = "1" ]; then
        echo "whisper-large-v3 whisper-large-v3-turbo distil-whisper-large-v3 parakeet-tdt-0.6b-v3 canary-180m-flash canary-1b-flash canary-qwen-2.5b"
        return
    fi
    echo "whisper-large-v3 whisper-large-v3-turbo distil-whisper-large-v3 canary-180m-flash"
}

_talkies_exec_get() {
    local host
    host=$(_talkies_host)
    docker compose exec -T litellm python3 -c "
import sys, urllib.request
sys.stdout.write(urllib.request.urlopen('http://${host}:8000$1', timeout=15).read().decode())
"
}

_talkies_exec_method() {
    local method="$1" path="$2"
    local host
    host=$(_talkies_host)
    docker compose exec -T litellm python3 -c "
import sys, urllib.request
req = urllib.request.Request('http://${host}:8000${path}', method='${method}')
sys.stdout.write(urllib.request.urlopen(req, timeout=15).read().decode())
" 2>/dev/null
}

_talkies_exec_status() {
    local method="$1" path="$2"
    local host
    host=$(_talkies_host)
    docker compose exec -T litellm python3 -c "
import urllib.request, urllib.error
try:
    urllib.request.urlopen(urllib.request.Request('http://${host}:8000${path}', method='${method}'), timeout=15)
    print(200)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    sys.stderr.write('exc: '+repr(e)+'\n'); print(0)
"
}

# Upload a multipart audio file to /v1/audio/transcriptions on the talkies
# service. Uses litellm container's python (urllib) over aigate-internal.
# Args: $1=model, $2=fixture path on host, $3=response_format (default json),
# $4..$N=extra "key=value" form fields (e.g. "timestamp_granularities[]=word")
_talkies_transcribe() {
    local model="$1" fixture="$2" response_format="${3:-json}"
    shift 3
    local extras=("$@")
    local host
    host=$(_talkies_host)

    local fname
    fname=$(basename "$fixture")
    local content_type="application/octet-stream"
    case "$fname" in
        *.wav)  content_type="audio/wav" ;;
        *.mp3)  content_type="audio/mpeg" ;;
        *.m4a)  content_type="audio/mp4" ;;
        *.flac) content_type="audio/flac" ;;
        *.ogg)  content_type="audio/ogg" ;;
    esac

    local extras_json="["
    local sep=""
    for kv in "${extras[@]}"; do
        local k="${kv%%=*}" v="${kv#*=}"
        extras_json+="${sep}{\"k\":\"${k}\",\"v\":\"${v}\"}"
        sep=","
    done
    extras_json+="]"

    cat "$fixture" | docker compose exec -T litellm python3 -c "
import json, os, sys, uuid, urllib.request, urllib.error
audio = sys.stdin.buffer.read()
boundary = uuid.uuid4().hex
parts = []
def add_field(name, value):
    parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name=\"' + name + '\"\r\n\r\n' + value + '\r\n').encode())
def add_file(name, filename, ctype, data):
    parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name=\"' + name + '\"; filename=\"' + filename + '\"\r\nContent-Type: ' + ctype + '\r\n\r\n').encode())
    parts.append(data)
    parts.append(b'\r\n')
add_field('model', '${model}')
add_field('response_format', '${response_format}')
for entry in json.loads('${extras_json}'):
    add_field(entry['k'], entry['v'])
add_file('file', '${fname}', '${content_type}', audio)
parts.append(('--' + boundary + '--\r\n').encode())
body = b''.join(parts)
req = urllib.request.Request(
    'http://${host}:8000/v1/audio/transcriptions',
    data=body,
    headers={'Content-Type': 'multipart/form-data; boundary=' + boundary},
)
try:
    resp = urllib.request.urlopen(req, timeout=900)
    sys.stdout.write(resp.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write('HTTP ' + str(e.code) + ': ' + e.read().decode() + '\n')
    sys.exit(1)
except Exception as e:
    sys.stderr.write('exc: ' + repr(e) + '\n')
    sys.exit(2)
"
}

_talkies_find_fixture() {
    local ext fixture=""
    for ext in wav mp3 m4a flac ogg; do
        if [ -f "tests/.fixtures/audio.${ext}" ]; then
            fixture="tests/.fixtures/audio.${ext}"
            break
        fi
    done
    echo "$fixture"
}

# ── /healthz reachable, returns device + configured model_ids ─────────────────

test_talkies_healthz() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local out
    out=$(_talkies_exec_get "/healthz") || { echo "  FAIL: /healthz unreachable"; return 1; }
    assert_contains "$out" "\"ok\":true" "/healthz ok=true" || return 1
    assert_contains "$out" "canary-180m-flash" "/healthz lists canary-180m-flash" || return 1
    assert_contains "$out" "whisper-large-v3" "/healthz lists whisper-large-v3" || return 1
    echo "OK: talkies_healthz"
}

# ── /v1/models lists every configured model_id ────────────────────────────────

test_talkies_models_list() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local out mid
    out=$(_talkies_exec_get "/v1/models") || { echo "  FAIL: /v1/models unreachable"; return 1; }
    assert_contains "$out" "\"object\":\"list\"" "/v1/models openai shape" || return 1
    for mid in $(_talkies_models_for_mode); do
        assert_contains "$out" "\"$mid\"" "/v1/models has $mid" || return 1
    done
    echo "OK: talkies_models_list"
}

# ── /api/ps responds, may be empty before first request ───────────────────────

test_talkies_api_ps() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local out
    out=$(_talkies_exec_get "/api/ps") || { echo "  FAIL: /api/ps unreachable"; return 1; }
    assert_contains "$out" "models" "/api/ps has models field (speaches-compat shape)" || return 1
    echo "OK: talkies_api_ps"
}

# ── POST /unload always 200 ───────────────────────────────────────────────────

test_talkies_unload_all() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    _talkies_exec_method POST "/unload" >/dev/null || { echo "  FAIL: POST /unload"; return 1; }
    echo "OK: talkies_unload_all"
}

# ── Per-model: plain json transcription returns non-empty text ────────────────

test_talkies_transcribe_each_model_json() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local fixture
    fixture=$(_talkies_find_fixture)
    [ -n "$fixture" ] || { echo "  SKIP: tests/.fixtures/audio.* missing"; return 0; }

    local mid out text rc=0
    for mid in $(_talkies_models_for_mode); do
        out=$(_talkies_transcribe "$mid" "$fixture" "json") || {
            echo "  FAIL: $mid json transcribe"
            rc=1
            continue
        }
        text=$(echo "$out" | jq -r '.text' 2>/dev/null || echo "")
        if [ -z "$text" ] || [ "$text" = "null" ]; then
            echo "  FAIL: $mid empty text in json response"
            rc=1
            continue
        fi
        echo "  ok: $mid text=\"$(echo "$text" | head -c 80)\""
    done
    [ $rc -eq 0 ] && echo "OK: talkies_transcribe_each_model_json"
    return $rc
}

# ── verbose_json: backends that support timestamps return segments + words ────

test_talkies_transcribe_each_model_verbose_json() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local fixture
    fixture=$(_talkies_find_fixture)
    [ -n "$fixture" ] || { echo "  SKIP: tests/.fixtures/audio.* missing"; return 0; }

    local mid out rc=0 segs words
    for mid in $(_talkies_models_for_mode); do
        out=$(_talkies_transcribe "$mid" "$fixture" "verbose_json" \
            "timestamp_granularities[]=segment" "timestamp_granularities[]=word") || {
            echo "  FAIL: $mid verbose_json transcribe"
            rc=1
            continue
        }
        assert_contains "$out" "\"task\":" "$mid verbose_json has task" || { rc=1; continue; }
        assert_contains "$out" "\"language\":" "$mid verbose_json has language" || { rc=1; continue; }
        assert_contains "$out" "\"duration\":" "$mid verbose_json has duration" || { rc=1; continue; }
        assert_contains "$out" "\"segments\":" "$mid verbose_json has segments" || { rc=1; continue; }
        assert_contains "$out" "\"words\":" "$mid verbose_json has words" || { rc=1; continue; }
        segs=$(echo "$out" | jq '.segments | length' 2>/dev/null || echo 0)
        words=$(echo "$out" | jq '.words | length' 2>/dev/null || echo 0)
        # canary-qwen-2.5b (SALM) has no timestamp head: empty arrays OK, schema must still validate.
        if [ "$mid" = "canary-qwen-2.5b" ]; then
            echo "  ok: $mid (SALM, segments=$segs words=$words)"
            continue
        fi
        if [ "$segs" -lt 1 ]; then
            echo "  FAIL: $mid expected >=1 segment, got $segs"
            rc=1
            continue
        fi
        echo "  ok: $mid segments=$segs words=$words"
    done
    [ $rc -eq 0 ] && echo "OK: talkies_transcribe_each_model_verbose_json"
    return $rc
}

# ── srt subtitle format works for every backend ───────────────────────────────

test_talkies_transcribe_each_model_srt() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local fixture
    fixture=$(_talkies_find_fixture)
    [ -n "$fixture" ] || { echo "  SKIP: tests/.fixtures/audio.* missing"; return 0; }

    local mid out rc=0
    for mid in $(_talkies_models_for_mode); do
        out=$(_talkies_transcribe "$mid" "$fixture" "srt") || {
            echo "  FAIL: $mid srt transcribe"
            rc=1
            continue
        }
        if ! echo "$out" | grep -q -- "-->"; then
            echo "  FAIL: $mid srt missing timestamp arrows"
            rc=1
            continue
        fi
        echo "  ok: $mid srt"
    done
    [ $rc -eq 0 ] && echo "OK: talkies_transcribe_each_model_srt"
    return $rc
}

# ── DELETE /api/ps/{unknown} returns 404 ─────────────────────────────────────

test_talkies_delete_unknown_returns_404() {
    _talkies_enabled || { echo "  SKIP: TALKIES not enabled"; return 0; }
    local code
    code=$(_talkies_exec_status DELETE "/api/ps/nonexistent-model")
    case "$code" in
        404) ;;
        *)
            echo "  FAIL: DELETE /api/ps/nonexistent-model expected 404, got $code"
            return 1
            ;;
    esac
    echo "OK: talkies_delete_unknown_returns_404"
}

ALL_TESTS+=(
    test_talkies_healthz
    test_talkies_models_list
    test_talkies_api_ps
    test_talkies_unload_all
    test_talkies_delete_unknown_returns_404
    test_talkies_transcribe_each_model_json
    test_talkies_transcribe_each_model_verbose_json
    test_talkies_transcribe_each_model_srt
)
