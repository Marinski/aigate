#!/bin/bash

# ── audiolla: gated on AUDIOLLA=1 / AUDIOLLA_CUDA=1 ───────────────────────
#
# Two variants live side-by-side on distinct nginx routes:
#   /audiolla/        → CPU container (AUDIOLLA=1)
#   /audiolla-cuda/   → GPU container (AUDIOLLA_CUDA=1)
# Both bind the master-auth-chained `AUDIOLLA_AUTH_TOKEN`. Each variant
# also exposes its own MCP under `<route>/v1/mcp/`. The introspection
# helpers below are parameterised on the route prefix so the same suite
# covers both variants.

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_audiolla_cpu_enabled()  { [ "${AUDIOLLA:-0}" = "1" ]; }
_audiolla_cuda_enabled() { [ "${AUDIOLLA_CUDA:-0}" = "1" ]; }

_audiolla_token() {
    # AUDIOLLA_AUTH_TOKEN if explicitly set, else AIGATE_TOKEN (master chain).
    echo "${AUDIOLLA_AUTH_TOKEN:-${AIGATE_TOKEN:-}}"
}

# ── shared assertions, parameterised on route prefix ─────────────────────────

_audiolla_test_healthz_open() {
    local prefix="$1" tag="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL${prefix}/healthz")
    [ "$code" = "200" ] || {
        echo "  FAIL: ${tag} ${prefix}/healthz expected 200 (open), got $code"
        return 1
    }
    echo "OK: ${tag} healthz_open"
}

_audiolla_test_requires_auth() {
    local prefix="$1" tag="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL${prefix}/v1/engines")
    case "$code" in
        401|403) ;;
        *)
            echo "  FAIL: ${tag} ${prefix}/v1/engines without auth expected 401/403, got $code"
            return 1
            ;;
    esac
    echo "OK: ${tag} requires_auth (status=$code)"
}

_audiolla_test_engines_list() {
    local prefix="$1" tag="$2"
    local tok
    tok=$(_audiolla_token)
    local out
    out=$(curl -sf "$BASE_URL${prefix}/v1/engines" \
        -H "Authorization: Bearer $tok" 2>/dev/null) || {
        echo "  FAIL: ${tag} GET ${prefix}/v1/engines"; return 1
    }
    assert_contains "$out" "htdemucs" "${tag} engines list has htdemucs" || return 1
    assert_contains "$out" "librosa-analyze" "${tag} engines list has librosa-analyze" || return 1
    echo "OK: ${tag} engines_list"
}

_audiolla_test_catalog() {
    local prefix="$1" tag="$2"
    local tok
    tok=$(_audiolla_token)
    local out
    out=$(curl -sf "$BASE_URL${prefix}/v1/catalog" \
        -H "Authorization: Bearer $tok" 2>/dev/null) || {
        echo "  FAIL: ${tag} GET ${prefix}/v1/catalog"; return 1
    }
    assert_contains "$out" "/v1/audio/" "${tag} catalog mentions /v1/audio/ paths" || return 1
    echo "OK: ${tag} catalog"
}

_audiolla_test_info_live() {
    local prefix="$1" tag="$2"
    local fixture="tests/.fixtures/audio.mp3"
    [ -f "$fixture" ] || { echo "  SKIP: missing $fixture"; return 0; }
    local tok
    tok=$(_audiolla_token)
    local out
    out=$(curl -sf -m 60 -X POST "$BASE_URL${prefix}/v1/audio/info" \
        -H "Authorization: Bearer $tok" \
        -F "file=@${fixture}" 2>/dev/null) || {
        echo "  FAIL: ${tag} POST ${prefix}/v1/audio/info"; return 1
    }
    assert_contains "$out" "\"duration" "${tag} info response has duration field" || return 1
    assert_contains "$out" "\"sample_rate" "${tag} info response has sample_rate field" || return 1
    echo "OK: ${tag} info_live"
}

_audiolla_test_analyze_live() {
    local prefix="$1" tag="$2"
    local fixture="tests/.fixtures/audio.mp3"
    [ -f "$fixture" ] || { echo "  SKIP: missing $fixture"; return 0; }
    local tok
    tok=$(_audiolla_token)
    local out
    out=$(curl -sf -m 120 -X POST "$BASE_URL${prefix}/v1/audio/analyze" \
        -H "Authorization: Bearer $tok" \
        -F "file=@${fixture}" 2>/dev/null) || {
        echo "  FAIL: ${tag} POST ${prefix}/v1/audio/analyze"; return 1
    }
    assert_contains "$out" "\"bpm\"" "${tag} analyze response has bpm" || return 1
    assert_contains "$out" "\"duration" "${tag} analyze response has duration" || return 1
    echo "OK: ${tag} analyze_live"
}

_audiolla_test_mcp_tools_present() {
    local prefix="$1" tag="$2"
    local tok
    tok=$(_audiolla_token)
    local raw
    raw=$(curl -s -m 30 -X POST "$BASE_URL${prefix}/v1/mcp/" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $tok" \
        -H "$_MCP_ACCEPT" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    # Response may be plain JSON or SSE (`data: <json>` line). Try SSE first.
    local tools_json
    tools_json=$(echo "$raw" | sed -n 's/^data: //p' | head -1)
    [ -z "$tools_json" ] && tools_json="$raw"
    assert_not_empty "$tools_json" "${tag} mcp tools response" || return 1

    local count
    count=$(echo "$tools_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tools = data.get('result', {}).get('tools', [])
print(len(tools))
" 2>/dev/null)
    if [ "${count:-0}" -lt 20 ]; then
        echo "  FAIL: ${tag} expected >= 20 MCP tools, got ${count:-0}"
        return 1
    fi
    for name in separate analyze chords; do
        if ! echo "$tools_json" | grep -q "\"name\":\"$name\""; then
            echo "  FAIL: ${tag} expected tool '$name' not present"
            return 1
        fi
    done
    echo "OK: ${tag} mcp_tools_present ($count tools)"
}

# ── CPU variant ────────────────────────────────────────────────────────────

test_audiolla_cpu_healthz_open()         { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_healthz_open       /audiolla "audiolla-cpu"; }
test_audiolla_cpu_requires_auth()        { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_requires_auth      /audiolla "audiolla-cpu"; }
test_audiolla_cpu_engines_list()         { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_engines_list       /audiolla "audiolla-cpu"; }
test_audiolla_cpu_catalog()              { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_catalog            /audiolla "audiolla-cpu"; }
test_audiolla_cpu_info_live()            { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_info_live          /audiolla "audiolla-cpu"; }
test_audiolla_cpu_analyze_live()         { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_analyze_live       /audiolla "audiolla-cpu"; }
test_audiolla_cpu_mcp_tools_present()    { _audiolla_cpu_enabled || { echo "  SKIP: AUDIOLLA not enabled"; return 0; }; _audiolla_test_mcp_tools_present  /audiolla "audiolla-cpu"; }

# ── CUDA variant ───────────────────────────────────────────────────────────

test_audiolla_cuda_healthz_open()        { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_healthz_open       /audiolla-cuda "audiolla-cuda"; }
test_audiolla_cuda_requires_auth()       { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_requires_auth      /audiolla-cuda "audiolla-cuda"; }
test_audiolla_cuda_engines_list()        { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_engines_list       /audiolla-cuda "audiolla-cuda"; }
test_audiolla_cuda_catalog()             { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_catalog            /audiolla-cuda "audiolla-cuda"; }
test_audiolla_cuda_info_live()           { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_info_live          /audiolla-cuda "audiolla-cuda"; }
test_audiolla_cuda_analyze_live()        { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_analyze_live       /audiolla-cuda "audiolla-cuda"; }
test_audiolla_cuda_mcp_tools_present()   { _audiolla_cuda_enabled || { echo "  SKIP: AUDIOLLA_CUDA not enabled"; return 0; }; _audiolla_test_mcp_tools_present  /audiolla-cuda "audiolla-cuda"; }

ALL_TESTS+=(
    test_audiolla_cpu_healthz_open
    test_audiolla_cpu_requires_auth
    test_audiolla_cpu_engines_list
    test_audiolla_cpu_catalog
    test_audiolla_cpu_info_live
    test_audiolla_cpu_analyze_live
    test_audiolla_cpu_mcp_tools_present
    test_audiolla_cuda_healthz_open
    test_audiolla_cuda_requires_auth
    test_audiolla_cuda_engines_list
    test_audiolla_cuda_catalog
    test_audiolla_cuda_info_live
    test_audiolla_cuda_analyze_live
    test_audiolla_cuda_mcp_tools_present
)
