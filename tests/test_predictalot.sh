#!/bin/bash

# ── predictalot: gated on PREDICTALOT=1 or PREDICTALOT_CUDA=1 ──────────────────
#
# v0.2.x ships a type-routed API. There is no `/v1/models` or `/v1/forecast`
# anymore — each forecast type has its own subtree:
#   /v1/{univariate,multivariate,covariates/past,covariates/future,covariates,samples}/{forecast,forecast/ensemble,models}
# All five models implement `univariate`, so that's the smoke-test surface.
# v0.2.1 closes the auth gap on /v1/<type>/models (open in v0.2.0); only
# /healthz is open now.

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_predictalot_enabled() {
    [ "${PREDICTALOT:-0}" = "1" ] || [ "${PREDICTALOT_CUDA:-0}" = "1" ]
}

# ── per-type model listing reachable (univariate has all 5 members) ──────────

test_predictalot_models_list() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local out
    out=$(curl -sf "$BASE_URL/predictalot/v1/univariate/models" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" 2>/dev/null)
    assert_contains "$out" "chronos-2" "predictalot /v1/univariate/models has chronos-2" || return 1
    assert_contains "$out" "timesfm-2.5" "predictalot /v1/univariate/models has timesfm-2.5" || return 1
    assert_contains "$out" "moirai-2" "predictalot /v1/univariate/models has moirai-2" || return 1
    assert_contains "$out" "toto-1" "predictalot /v1/univariate/models has toto-1" || return 1
    assert_contains "$out" "sundial-base-128m" "predictalot /v1/univariate/models has sundial-base-128m" || return 1
    echo "OK: predictalot_models_list"
}

# ── multivariate listing excludes univariate-only models ─────────────────────

test_predictalot_multivariate_models_list() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local out
    out=$(curl -sf "$BASE_URL/predictalot/v1/multivariate/models" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" 2>/dev/null)
    assert_contains "$out" "chronos-2" "multivariate has chronos-2" || return 1
    assert_contains "$out" "moirai-2" "multivariate has moirai-2" || return 1
    assert_contains "$out" "toto-1" "multivariate has toto-1" || return 1
    # timesfm-2.5 and sundial-base-128m are NOT multivariate members
    if echo "$out" | grep -q "timesfm-2.5"; then
        echo "  FAIL: timesfm-2.5 should not appear in /v1/multivariate/models"
        return 1
    fi
    echo "OK: predictalot_multivariate_models_list"
}

# ── auth enforced on forecast endpoints ──────────────────────────────────────
#
# v0.2.1+ gates /v1/<type>/{forecast,forecast/ensemble,models} on the bearer.
# /healthz is the only open route. Probe with a forecast call so we exercise
# both the auth dependency and the route's request-shape parser.

test_predictalot_requires_auth() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL/predictalot/v1/univariate/forecast" \
        -H "Content-Type: application/json" \
        -d '{"model":"chronos-2","context":[[1,2,3,4,5]],"config":{"horizon":1}}')
    if [ "$code" != "401" ] && [ "$code" != "403" ]; then
        echo "  FAIL: expected 401/403 without token on /forecast, got $code"
        return 1
    fi
    echo "OK: predictalot_requires_auth ($code)"
}

# ── forecast via chronos-2 on /v1/univariate/forecast ────────────────────────

test_predictalot_forecast_chronos() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local out
    out=$(curl -sf -X POST "$BASE_URL/predictalot/v1/univariate/forecast" \
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

# ── univariate ensemble (parallel multi-model + weighted mean) ───────────────

test_predictalot_univariate_ensemble() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local out
    # weight 0 disables a model (= not called). Keep just chronos-2 so the test
    # doesn't trigger cold-loads of the larger models on every CI run.
    out=$(curl -sf -X POST "$BASE_URL/predictalot/v1/univariate/forecast/ensemble" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        --max-time 300 \
        -d '{
            "context": [[10,11,12,13,14,15,16,17,18,19,20,21,22,23]],
            "config": {"horizon": 5},
            "weights": {"chronos-2": 1, "timesfm-2.5": 0, "moirai-2": 0, "toto-1": 0, "sundial-base-128m": 0}
        }' 2>/dev/null)
    assert_contains "$out" '"ensembleMembers"' "ensemble has ensembleMembers" || { echo "got: $out"; return 1; }
    assert_contains "$out" '"individual"' "ensemble has individual map" || return 1
    assert_contains "$out" '"weights"' "ensemble has normalized weights" || return 1
    echo "OK: predictalot_univariate_ensemble"
}

# ── unknown model -> 404 ─────────────────────────────────────────────────────

test_predictalot_unknown_model() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL/predictalot/v1/univariate/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"model":"not-a-real-model","context":[[1,2,3]],"config":{"horizon":1}}')
    assert_eq "$code" "404" "unknown model returns 404" || return 1
    echo "OK: predictalot_unknown_model"
}

# ── non-member model rejected for type (timesfm-2.5 has no multivariate) ─────

test_predictalot_non_member_rejected() {
    _predictalot_enabled || { echo "  SKIP: PREDICTALOT not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "$BASE_URL/predictalot/v1/multivariate/forecast" \
        -H "Authorization: Bearer $PREDICTALOT_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"model":"timesfm-2.5","context":[[[1,2,3],[4,5,6]]],"config":{"horizon":1}}')
    # Should be 400 (not a multivariate member) — never 200.
    if [ "$code" = "200" ]; then
        echo "  FAIL: timesfm-2.5 should not be accepted on /v1/multivariate/forecast (got 200)"
        return 1
    fi
    echo "OK: predictalot_non_member_rejected ($code)"
}

# ── MCP exposes the 26-tool surface via LiteLLM's /mcp/ aggregator ───────────
#
# v0.2.x: 18 per-(type,model) tools + 6 ensembles + 6 list_<type>_models = 26.
# LiteLLM prefixes each with `predictalot-`. Allow margin for naming drift but
# require well over the v0.1.x baseline of 7 tools.

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
    if [ "${count:-0}" -lt 20 ]; then
        echo "  FAIL: expected >= 20 predictalot MCP tools (v0.2.x ships 26), got ${count:-0}"
        return 1
    fi
    # Spot-check a couple of v0.2.x-specific names.
    if ! echo "$tools_json" | grep -q "predictalot-forecast_univariate_chronos_2"; then
        echo "  FAIL: expected tool 'predictalot-forecast_univariate_chronos_2' not present"
        return 1
    fi
    if ! echo "$tools_json" | grep -q "predictalot-list_univariate_models"; then
        echo "  FAIL: expected tool 'predictalot-list_univariate_models' not present"
        return 1
    fi
    echo "OK: predictalot_mcp_tools_present ($count tools)"
}

ALL_TESTS+=(
    test_predictalot_models_list
    test_predictalot_multivariate_models_list
    test_predictalot_requires_auth
    test_predictalot_forecast_chronos
    test_predictalot_univariate_ensemble
    test_predictalot_unknown_model
    test_predictalot_non_member_rejected
    test_predictalot_mcp_tools_present
)
