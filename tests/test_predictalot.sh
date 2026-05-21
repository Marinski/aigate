#!/bin/bash

# ── predictalot: gated on PREDICTALOT=1 or PREDICTALOT_CUDA=1 ──────────────────

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_predictalot_enabled() {
    [ "${PREDICTALOT:-0}" = "1" ] || [ "${PREDICTALOT_CUDA:-0}" = "1" ]
}

# ── direct /v1/models reachable ──────────────────────────────────────────────

test_predictalot_models_list() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local out
    out=$(curl -sf "$BASE_URL/predictalot/v1/models" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" 2>/dev/null)
    assert_contains "$out" "chronos-2" "predictalot /v1/models has chronos-2" || return 1
    assert_contains "$out" "timesfm-2.5" "predictalot /v1/models has timesfm-2.5" || return 1
    assert_contains "$out" "moirai-2" "predictalot /v1/models has moirai-2" || return 1
    assert_contains "$out" "toto-1" "predictalot /v1/models has toto-1" || return 1
    assert_contains "$out" "sundial-base-128m" "predictalot /v1/models has sundial-base-128m" || return 1
    echo "OK: predictalot_models_list"
}

# ── auth enforced ────────────────────────────────────────────────────────────

test_predictalot_requires_auth() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/predictalot/v1/models")
    if [ "$code" != "401" ] && [ "$code" != "403" ]; then
        echo "  FAIL: expected 401/403 without token, got $code"
        return 1
    fi
    echo "OK: predictalot_requires_auth ($code)"
}

# ── forecast via chronos-2 (smallest model, fastest cold-load) ───────────────

test_predictalot_forecast_chronos() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local out
    out=$(curl -sf -X POST "$BASE_URL/predictalot/v1/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        --max-time 300 \
        -d '{
            "model": "chronos-2",
            "context": [[10,11,12,13,14,15,16,17,18,19,20,21,22,23]],
            "config": {"horizon": 5, "quantileLevels": [0.1, 0.5, 0.9]}
        }' 2>/dev/null)
    assert_contains "$out" '"model"' "forecast response has model field" || { echo "got: $out"; return 1; }
    assert_contains "$out" '"median"' "forecast response has median" || return 1
    assert_contains "$out" '"quantiles"' "forecast response has quantiles" || return 1
    assert_contains "$out" '"0.1"' "forecast has 0.1 quantile" || return 1
    assert_contains "$out" '"0.9"' "forecast has 0.9 quantile" || return 1
    echo "OK: predictalot_forecast_chronos"
}

# ── unknown model -> 404 ─────────────────────────────────────────────────────

test_predictalot_unknown_model() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL/predictalot/v1/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"model":"not-a-real-model","context":[[1,2,3]],"config":{"horizon":1}}')
    assert_eq "$code" "404" "unknown model returns 404" || return 1
    echo "OK: predictalot_unknown_model"
}

# ── MCP exposes forecast tools via LiteLLM's /mcp/ aggregator ────────────────

test_predictalot_mcp_tools_present() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local tools_json
    tools_json=$(curl -s -X POST "$BASE_URL/mcp/" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -H "$_MCP_ACCEPT" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
        | grep "^data:" | head -1 | sed 's/^data: //')
    assert_not_empty "$tools_json" "mcp tools response" || return 1

    local count
    count=$(echo "$tools_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tools = data.get('result', {}).get('tools', [])
print(sum(1 for t in tools if t['name'].startswith('predictalot-')))
" 2>/dev/null)
    if [ "${count:-0}" -lt 6 ]; then
        echo "  FAIL: expected >= 6 predictalot MCP tools, got ${count:-0}"
        return 1
    fi
    echo "OK: predictalot_mcp_tools_present ($count tools)"
}

ALL_TESTS+=(
    test_predictalot_models_list
    test_predictalot_requires_auth
    test_predictalot_forecast_chronos
    test_predictalot_unknown_model
    test_predictalot_mcp_tools_present
)
