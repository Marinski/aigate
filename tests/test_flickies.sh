#!/bin/bash

# ── flickies: gated on FLICKIES=1 / FLICKIES_CUDA=1 ──────────────────────
#
# Two variants live side-by-side on distinct nginx routes:
#   /flickies/        → CPU container (FLICKIES=1)
#   /flickies-cuda/   → GPU container (FLICKIES_CUDA=1)
# Both bind the master-auth-chained `FLICKIES_AUTH_TOKEN`. Each variant
# also exposes its own MCP under `<route>/v1/mcp/`. The introspection
# helpers below are parameterised on the route prefix so the same suite
# covers both variants.

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_flickies_cpu_enabled()  { [ "${FLICKIES:-0}" = "1" ]; }
_flickies_cuda_enabled() { [ "${FLICKIES_CUDA:-0}" = "1" ]; }

_flickies_token() {
    # FLICKIES_AUTH_TOKEN if explicitly set, else AIGATE_TOKEN (master chain).
    echo "${FLICKIES_AUTH_TOKEN:-${AIGATE_TOKEN:-}}"
}

# ── shared assertions, parameterised on route prefix ─────────────────────────

_flickies_test_healthz_open() {
    local prefix="$1" tag="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL${prefix}/healthz")
    [ "$code" = "200" ] || {
        echo "  FAIL: ${tag} ${prefix}/healthz expected 200 (open), got $code"
        return 1
    }
    echo "OK: ${tag} healthz_open"
}

_flickies_test_requires_auth() {
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

_flickies_test_engines_list() {
    local prefix="$1" tag="$2"
    local tok
    tok=$(_flickies_token)
    local out
    out=$(curl -sf "$BASE_URL${prefix}/v1/engines" \
        -H "Authorization: Bearer $tok" 2>/dev/null) || {
        echo "  FAIL: ${tag} GET ${prefix}/v1/engines"; return 1
    }
    # Every variant exposes Wav2Lip (whether gate-loadable or not). GFPGAN +
    # LatentSync only appear on the CUDA build, so we don't pin them here.
    assert_contains "$out" "wav2lip" "${tag} engines list has wav2lip" || return 1
    echo "OK: ${tag} engines_list"
}

_flickies_test_mcp_tools_present() {
    local prefix="$1" tag="$2"
    local tok
    tok=$(_flickies_token)
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
    # Upstream advertises 11 tools (list_engines + info + lipsync + restore +
    # 7 ffmpeg ops). Floor at 8 so a future op rename / split doesn't break
    # this without genuinely shrinking the surface.
    if [ "${count:-0}" -lt 8 ]; then
        echo "  FAIL: ${tag} expected >= 8 MCP tools, got ${count:-0}"
        return 1
    fi
    for name in list_engines info lipsync transcode; do
        if ! echo "$tools_json" | grep -q "\"name\":\"$name\""; then
            echo "  FAIL: ${tag} expected tool '$name' not present"
            return 1
        fi
    done
    echo "OK: ${tag} mcp_tools_present ($count tools)"
}

# ── CPU variant ────────────────────────────────────────────────────────────

test_flickies_cpu_healthz_open()      { _flickies_cpu_enabled || { echo "  SKIP: FLICKIES not enabled"; return 0; }; _flickies_test_healthz_open      /flickies "flickies-cpu"; }
test_flickies_cpu_requires_auth()     { _flickies_cpu_enabled || { echo "  SKIP: FLICKIES not enabled"; return 0; }; _flickies_test_requires_auth     /flickies "flickies-cpu"; }
test_flickies_cpu_engines_list()      { _flickies_cpu_enabled || { echo "  SKIP: FLICKIES not enabled"; return 0; }; _flickies_test_engines_list      /flickies "flickies-cpu"; }
test_flickies_cpu_mcp_tools_present() { _flickies_cpu_enabled || { echo "  SKIP: FLICKIES not enabled"; return 0; }; _flickies_test_mcp_tools_present /flickies "flickies-cpu"; }

# ── CUDA variant ───────────────────────────────────────────────────────────

test_flickies_cuda_healthz_open()      { _flickies_cuda_enabled || { echo "  SKIP: FLICKIES_CUDA not enabled"; return 0; }; _flickies_test_healthz_open      /flickies-cuda "flickies-cuda"; }
test_flickies_cuda_requires_auth()     { _flickies_cuda_enabled || { echo "  SKIP: FLICKIES_CUDA not enabled"; return 0; }; _flickies_test_requires_auth     /flickies-cuda "flickies-cuda"; }
test_flickies_cuda_engines_list()      { _flickies_cuda_enabled || { echo "  SKIP: FLICKIES_CUDA not enabled"; return 0; }; _flickies_test_engines_list      /flickies-cuda "flickies-cuda"; }
test_flickies_cuda_mcp_tools_present() { _flickies_cuda_enabled || { echo "  SKIP: FLICKIES_CUDA not enabled"; return 0; }; _flickies_test_mcp_tools_present /flickies-cuda "flickies-cuda"; }

ALL_TESTS+=(
    test_flickies_cpu_healthz_open
    test_flickies_cpu_requires_auth
    test_flickies_cpu_engines_list
    test_flickies_cpu_mcp_tools_present
    test_flickies_cuda_healthz_open
    test_flickies_cuda_requires_auth
    test_flickies_cuda_engines_list
    test_flickies_cuda_mcp_tools_present
)
