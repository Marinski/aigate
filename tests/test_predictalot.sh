#!/bin/bash

# ── predictalot: gated on PREDICTALOT=1 / PREDICTALOT_CUDA=1 ──────────────
#
# v0.2.x ships a type-routed API. There is no `/v1/models` or `/v1/forecast`
# anymore — each forecast type has its own subtree:
#   /v1/{univariate,multivariate,covariates/past,covariates/future,covariates,samples}/{forecast,forecast/ensemble,models}
# All five models implement `univariate`, so that's the smoke-test surface.
# v0.2.1 closes the auth gap on /v1/<type>/models (open in v0.2.0); only
# /healthz is open now.
#
# Two variants live side-by-side on distinct nginx routes:
#   /predictalot/        → CPU container (PREDICTALOT=1)
#   /predictalot-cuda/   → GPU container (PREDICTALOT_CUDA=1)
# Tools in /mcp/ are namespaced `predictalot-<tool>` and
# `predictalot_cuda-<tool>` respectively. The helpers below parameterise on
# route prefix + namespace so the same suite covers both variants.

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_predictalot_cpu_enabled()  { [ "${PREDICTALOT:-0}" = "1" ]; }
_predictalot_cuda_enabled() { [ "${PREDICTALOT_CUDA:-0}" = "1" ]; }

# ── shared assertions, parameterised on route prefix + mcp namespace ─────

_predictalot_test_models_list() {
    local prefix="$1" tag="$2"
    local out
    out=$(curl -sf "$BASE_URL${prefix}/v1/univariate/models" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" 2>/dev/null)
    assert_contains "$out" "chronos-2" "${tag} ${prefix}/v1/univariate/models has chronos-2" || return 1
    assert_contains "$out" "timesfm-2.5" "${tag} /v1/univariate/models has timesfm-2.5" || return 1
    assert_contains "$out" "moirai-2" "${tag} /v1/univariate/models has moirai-2" || return 1
    assert_contains "$out" "toto-1" "${tag} /v1/univariate/models has toto-1" || return 1
    assert_contains "$out" "sundial-base-128m" "${tag} /v1/univariate/models has sundial-base-128m" || return 1
    echo "OK: ${tag} models_list"
}

_predictalot_test_multivariate_models_list() {
    local prefix="$1" tag="$2"
    local out
    out=$(curl -sf "$BASE_URL${prefix}/v1/multivariate/models" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" 2>/dev/null)
    assert_contains "$out" "chronos-2" "${tag} multivariate has chronos-2" || return 1
    assert_contains "$out" "moirai-2" "${tag} multivariate has moirai-2" || return 1
    assert_contains "$out" "toto-1" "${tag} multivariate has toto-1" || return 1
    if echo "$out" | grep -q "timesfm-2.5"; then
        echo "  FAIL: ${tag} timesfm-2.5 should not appear in /v1/multivariate/models"
        return 1
    fi
    echo "OK: ${tag} multivariate_models_list"
}

_predictalot_test_requires_auth() {
    local prefix="$1" tag="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL${prefix}/v1/univariate/forecast" \
        -H "Content-Type: application/json" \
        -d '{"model":"chronos-2","context":[[1,2,3,4,5]],"config":{"horizon":1}}')
    if [ "$code" != "401" ] && [ "$code" != "403" ]; then
        echo "  FAIL: ${tag} expected 401/403 without token on /forecast, got $code"
        return 1
    fi
    echo "OK: ${tag} requires_auth ($code)"
}

_predictalot_test_forecast_chronos() {
    local prefix="$1" tag="$2"
    local out
    out=$(curl -sf -X POST "$BASE_URL${prefix}/v1/univariate/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        --max-time 300 \
        -d '{
            "model": "chronos-2",
            "context": [[10,11,12,13,14,15,16,17,18,19,20,21,22,23]],
            "config": {"horizon": 5, "quantileLevels": [0.1, 0.5, 0.9]}
        }' 2>/dev/null)
    assert_contains "$out" '"model"' "${tag} forecast response has model field" || { echo "got: $out"; return 1; }
    assert_contains "$out" '"median"' "${tag} forecast response has median" || return 1
    assert_contains "$out" '"quantiles"' "${tag} forecast response has quantiles" || return 1
    assert_contains "$out" '"0.1"' "${tag} forecast has 0.1 quantile" || return 1
    assert_contains "$out" '"0.9"' "${tag} forecast has 0.9 quantile" || return 1
    echo "OK: ${tag} forecast_chronos"
}

_predictalot_test_univariate_ensemble() {
    local prefix="$1" tag="$2"
    local out
    out=$(curl -sf -X POST "$BASE_URL${prefix}/v1/univariate/forecast/ensemble" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        --max-time 300 \
        -d '{
            "context": [[10,11,12,13,14,15,16,17,18,19,20,21,22,23]],
            "config": {"horizon": 5},
            "weights": {"chronos-2": 1, "timesfm-2.5": 0, "moirai-2": 0, "toto-1": 0, "sundial-base-128m": 0}
        }' 2>/dev/null)
    assert_contains "$out" '"ensembleMembers"' "${tag} ensemble has ensembleMembers" || { echo "got: $out"; return 1; }
    assert_contains "$out" '"individual"' "${tag} ensemble has individual map" || return 1
    assert_contains "$out" '"weights"' "${tag} ensemble has normalized weights" || return 1
    echo "OK: ${tag} univariate_ensemble"
}

_predictalot_test_unknown_model() {
    local prefix="$1" tag="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL${prefix}/v1/univariate/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"model":"not-a-real-model","context":[[1,2,3]],"config":{"horizon":1}}')
    assert_eq "$code" "404" "${tag} unknown model returns 404" || return 1
    echo "OK: ${tag} unknown_model"
}

_predictalot_test_non_member_rejected() {
    local prefix="$1" tag="$2"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL${prefix}/v1/multivariate/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"model":"timesfm-2.5","context":[[[1,2,3],[4,5,6]]],"config":{"horizon":1}}')
    if [ "$code" = "200" ]; then
        echo "  FAIL: ${tag} timesfm-2.5 should not be accepted on /v1/multivariate/forecast (got 200)"
        return 1
    fi
    echo "OK: ${tag} non_member_rejected ($code)"
}

# Tools surface via the aggregated /mcp/. Each variant namespaces under its
# server name; the dash in `predictalot-cuda` becomes an underscore in the
# tool prefix per LiteLLM's SEP-986 normalization.
_predictalot_test_mcp_tools_present() {
    local namespace="$1" tag="$2"
    local tools_json
    tools_json=$(curl -s -X POST "$BASE_URL/mcp/" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -H "$_MCP_ACCEPT" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
        | grep "^data:" | head -1 | sed 's/^data: //')
    assert_not_empty "$tools_json" "${tag} mcp tools response" || return 1

    local count
    count=$(echo "$tools_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
tools = data.get('result', {}).get('tools', [])
print(sum(1 for t in tools if t['name'].startswith('${namespace}-')))
" 2>/dev/null)
    if [ "${count:-0}" -lt 20 ]; then
        echo "  FAIL: ${tag} expected >= 20 ${namespace} MCP tools (v0.2.x ships 26), got ${count:-0}"
        return 1
    fi
    if ! echo "$tools_json" | grep -q "${namespace}-forecast_univariate_chronos_2"; then
        echo "  FAIL: ${tag} expected tool '${namespace}-forecast_univariate_chronos_2' not present"
        return 1
    fi
    if ! echo "$tools_json" | grep -q "${namespace}-list_univariate_models"; then
        echo "  FAIL: ${tag} expected tool '${namespace}-list_univariate_models' not present"
        return 1
    fi
    echo "OK: ${tag} mcp_tools_present ($count tools)"
}

# ── CPU variant ────────────────────────────────────────────────────────────

test_predictalot_cpu_models_list()              { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_models_list              /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_multivariate_models_list() { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_multivariate_models_list /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_requires_auth()            { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_requires_auth            /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_forecast_chronos()         { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_forecast_chronos         /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_univariate_ensemble()      { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_univariate_ensemble      /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_unknown_model()            { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_unknown_model            /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_non_member_rejected()      { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_non_member_rejected      /predictalot      "predictalot-cpu"; }
test_predictalot_cpu_mcp_tools_present()        { _predictalot_cpu_enabled  || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }; _predictalot_test_mcp_tools_present        predictalot       "predictalot-cpu"; }

# ── CUDA variant ───────────────────────────────────────────────────────────

test_predictalot_cuda_models_list()              { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_models_list              /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_multivariate_models_list() { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_multivariate_models_list /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_requires_auth()            { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_requires_auth            /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_forecast_chronos()         { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_forecast_chronos         /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_univariate_ensemble()      { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_univariate_ensemble      /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_unknown_model()            { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_unknown_model            /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_non_member_rejected()      { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_non_member_rejected      /predictalot-cuda "predictalot-cuda"; }
test_predictalot_cuda_mcp_tools_present()        { _predictalot_cuda_enabled || { echo "  SKIP: PREDICTALOT_CUDA not enabled"; return 0; }; _predictalot_test_mcp_tools_present        predictalot_cuda  "predictalot-cuda"; }

ALL_TESTS+=(
    test_predictalot_cpu_models_list
    test_predictalot_cpu_multivariate_models_list
    test_predictalot_cpu_requires_auth
    test_predictalot_cpu_forecast_chronos
    test_predictalot_cpu_univariate_ensemble
    test_predictalot_cpu_unknown_model
    test_predictalot_cpu_non_member_rejected
    test_predictalot_cpu_mcp_tools_present
    test_predictalot_cuda_models_list
    test_predictalot_cuda_multivariate_models_list
    test_predictalot_cuda_requires_auth
    test_predictalot_cuda_forecast_chronos
    test_predictalot_cuda_univariate_ensemble
    test_predictalot_cuda_unknown_model
    test_predictalot_cuda_non_member_rejected
    test_predictalot_cuda_mcp_tools_present
)
