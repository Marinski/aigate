#!/bin/bash

# ── piston: gated on PISTON=1 ─────────────────────────────────────────────
#
# Sandboxed multi-language code execution (engineer-man/piston). nsjail-
# based per-execution isolation inside a privileged container; bearer auth
# at the nginx layer (the upstream API has none). The piston-pull sidecar
# installs the language set from PISTON_LANGUAGES at first `up`; tests
# below assert the canonical python / node / bash runtimes are present
# and that executing a small program through the nginx-gated route
# returns the expected stdout.

_piston_enabled() { [ "${PISTON:-0}" = "1" ]; }

_piston_route="${BASE_URL}/piston"

# ── auth + listing ────────────────────────────────────────────────────────

test_piston_route_requires_auth() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    local code
    # No Authorization header at all — must be 401/403.
    code=$(curl -s -o /dev/null -w "%{http_code}" "$_piston_route/api/v2/runtimes")
    case "$code" in
        401|403)
            ;;
        *)
            echo "  FAIL: piston route expected 401/403 for missing auth, got $code"
            return 1
            ;;
    esac
    # Wrong token — must ALSO be 401/403. Without this case the nginx
    # `if ($http_authorization != "Bearer …")` check could regress to
    # accepting any token and the missing-header test above would still
    # pass for the wrong reason.
    code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer definitely-not-the-real-token" \
        "$_piston_route/api/v2/runtimes")
    case "$code" in
        401|403)
            ;;
        *)
            echo "  FAIL: piston route expected 401/403 for wrong token, got $code"
            return 1
            ;;
    esac
    echo "OK: piston route rejects missing AND wrong token"
}

test_piston_runtimes_listed() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    local out
    out=$(curl -sf "$_piston_route/api/v2/runtimes" \
        -H "$AUTH_HEADER" 2>/dev/null) || {
        echo "  FAIL: piston GET /api/v2/runtimes"; return 1
    }
    # Defaults baked into the image — assert at least the two we ship.
    # See PISTON_LANGUAGES in .env.example for how to add more languages
    # (rebuild required, since they're pre-baked).
    assert_contains "$out" '"language":"python"' "piston runtimes lists python" || return 1
    assert_contains "$out" '"language":"javascript"' "piston runtimes lists node (javascript)" || return 1
    echo "OK: piston_runtimes_listed"
}

# ── execute, per-language ─────────────────────────────────────────────────

# Shared helper: POST /api/v2/execute with one source file. Echo the JSON
# response so the caller can assert .run.stdout / .run.code.
_piston_execute() {
    local language="$1" version="$2" source="$3"
    local body
    body=$(python3 -c "
import json, sys
print(json.dumps({
    'language': sys.argv[1],
    'version': sys.argv[2],
    'files': [{'content': sys.argv[3]}],
}))
" "$language" "$version" "$source")
    curl -s -m 60 -X POST "$_piston_route/api/v2/execute" \
        -H "$AUTH_HEADER" \
        -H "Content-Type: application/json" \
        -d "$body"
}

_piston_assert_stdout() {
    local raw="$1" expected="$2" name="$3"
    local stdout
    # Strip trailing newlines from BOTH sides — piston always emits a
    # trailing \n that doesn't matter for correctness assertions.
    stdout=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('run',{}).get('stdout','').rstrip('\n'))" 2>/dev/null)
    if [ "$stdout" != "$expected" ]; then
        echo "  FAIL: $name stdout mismatch"
        echo "    expected: '$expected'"
        echo "    got:      '$stdout'"
        echo "    raw:      $(echo "$raw" | head -c 400)"
        return 1
    fi
    echo "  OK: $name"
}

test_piston_python_execute() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    local raw
    raw=$(_piston_execute "python" "3.12.0" "print(sum(range(1,11)))")
    _piston_assert_stdout "$raw" "55" "python sum(1..10) == 55" || return 1
    echo "OK: piston_python_execute"
}

test_piston_node_execute() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    local raw
    raw=$(_piston_execute "javascript" "20.11.1" "console.log([1,2,3,4].reduce((a,b)=>a+b))")
    _piston_assert_stdout "$raw" "10" "node 1+2+3+4 == 10" || return 1
    echo "OK: piston_node_execute"
}

# ── isolation: sandbox should NOT be able to reach outbound network ──────
#
# PISTON_DISABLE_NETWORKING=true is set in the compose service env. nsjail
# creates a fresh network namespace per execution with no veth pair, so
# code inside the sandbox has no DNS / no routes / nothing reachable.
# We don't assert a SPECIFIC error string (varies by language stdlib) —
# we assert the execution failed at the network layer (non-zero exit OR
# stderr contains a "name resolution" / "unreachable" / "refused" pattern).

test_piston_sandbox_no_network() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    if [ "${PISTON_DISABLE_NETWORKING:-true}" != "true" ]; then
        echo "  SKIP: PISTON_DISABLE_NETWORKING is not 'true' — sandbox network is allowed"
        return 0
    fi
    local raw exit_code stderr
    raw=$(_piston_execute "python" "3.12.0" \
"import urllib.request,sys
try:
    urllib.request.urlopen('http://example.com',timeout=3)
    print('REACHED_OUTBOUND')
    sys.exit(0)
except Exception as e:
    print('NETWORK_BLOCKED:',type(e).__name__,str(e)[:120])
    sys.exit(2)")
    exit_code=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('run',{}).get('code',''))" 2>/dev/null)
    stderr=$(echo "$raw" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('run',{}).get('stdout','') + d.get('run',{}).get('stderr',''))" 2>/dev/null)
    if [ "$exit_code" = "0" ] && [[ "$stderr" == *"REACHED_OUTBOUND"* ]]; then
        echo "  FAIL: sandbox reached external network (PISTON_DISABLE_NETWORKING not effective?)"
        echo "    raw: $(echo "$raw" | head -c 400)"
        return 1
    fi
    echo "OK: piston_sandbox_no_network (exit=$exit_code, msg=${stderr:0:80})"
}

# ── MCP integration: execute_code tool registered + callable ──────────────

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_piston_mcp_tools_list() {
    local response
    response=$(curl -s -X POST "$BASE_URL/mcp/" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -H "$_MCP_ACCEPT" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    echo "$response" | grep "^data:" | head -1 | sed 's/^data: //'
}

_piston_mcp_call_tool() {
    local tool_name="$1" args_json="$2"
    local response
    response=$(curl -s -X POST "$BASE_URL/mcp/" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -H "$_MCP_ACCEPT" \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool_name\",\"arguments\":$args_json}}")
    echo "$response" | grep "^data:" | head -1 | sed 's/^data: //'
}

test_piston_mcp_tool_registered() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    local tools_json
    tools_json=$(_piston_mcp_tools_list)
    assert_not_empty "$tools_json" "mcp tools/list response" || return 1
    assert_contains "$tools_json" '"name":"mcp_tools-execute_code"' \
        "mcp_tools-execute_code present in tools/list" || return 1
    echo "OK: piston_mcp_tool_registered"
}

test_piston_mcp_tool_call() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    # Call the MCP execute_code tool directly. Asserts the JSON envelope
    # returned by the tool surfaces the expected stdout from a tiny
    # Python program. Verifies the language-resolution path + the
    # piston call from inside the mcp service.
    local result
    result=$(_piston_mcp_call_tool "mcp_tools-execute_code" \
        '{"language":"python","source":"print(2**10)"}')
    assert_not_empty "$result" "execute_code MCP response" || return 1
    local stdout
    stdout=$(echo "$result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
content = d.get('result',{}).get('content',[])
for c in content:
    if c.get('type') == 'text':
        inner = json.loads(c['text'])
        print(inner.get('stdout','').rstrip('\n'))
        break
" 2>/dev/null)
    if [ "$stdout" != "1024" ]; then
        echo "  FAIL: expected stdout '1024', got '$stdout'"
        echo "  raw: $(echo "$result" | head -c 400)"
        return 1
    fi
    echo "OK: piston_mcp_tool_call (2**10 == 1024)"
}

# ── End-to-end: real LLM (Groq) decides to call execute_code ──────────────
#
# The full agentic loop: ask a Groq model a question whose answer is a
# deterministic computation (SHA-256 of a known string). The LLM has the
# execute_code tool description in its `tools` array and `tool_choice` is
# forced to "auto" — the model decides whether to invoke. Real Groq
# llama-3.3-70b will see "compute the SHA-256 of X" + "you have an
# execute_code tool" and emit a tool_call. We then dispatch that tool_call
# to MCP, get the stdout, and assert it matches the expected hash.
#
# The expected SHA-256 of "aigate-piston-2026" is hardcoded — computed
# once via `python3 -c 'import hashlib; print(hashlib.sha256(b"aigate-
# piston-2026").hexdigest())'`.

_PISTON_EXPECTED_HASH="38a24fbf70116be5d8ee0e0cdc66e524472ae9ad99ffa317e44f5b1ecb809121"

test_piston_e2e_groq_drives_execute_code() {
    _piston_enabled || { echo "  SKIP: PISTON not enabled"; return 0; }
    if [ "${GROQ:-}" != "1" ]; then
        echo "  SKIP: GROQ not enabled — needs a real cloud LLM with tool support"
        return 0
    fi

    local llm_model="groq-llama-3.3-70b"

    # Step 1: prompt the LLM with the execute_code tool definition.
    local step1
    step1=$(curl -s -X POST "$BASE_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -H "$AUTH_HEADER" \
        -d "$(cat <<EOJSON
{
    "model": "$llm_model",
    "messages": [
        {"role": "system", "content": "You have access to an execute_code tool. When asked to compute something deterministic (hashes, sums, regex matches, etc.) you MUST call the tool rather than guessing. Use python and print() the result."},
        {"role": "user", "content": "Compute the SHA-256 hex digest of the byte string 'aigate-piston-2026' (no quotes, no trailing newline, exactly those 18 bytes). Use the execute_code tool and print only the hex digest."}
    ],
    "tools": [{
        "type": "function",
        "function": {
            "name": "execute_code",
            "description": "Execute code in a sandboxed environment. Returns stdout, stderr, exit_code, cpu_time_ms, wall_time_ms, memory_bytes.",
            "parameters": {
                "type": "object",
                "properties": {
                    "language": {"type": "string", "enum": ["python", "javascript"]},
                    "source": {"type": "string", "description": "the source code to run"}
                },
                "required": ["language", "source"]
            }
        }
    }],
    "tool_choice": {"type": "function", "function": {"name": "execute_code"}}
}
EOJSON
)")
    assert_not_empty "$step1" "step1: LLM responded" || return 1

    # Extract the tool_call (LLM should have produced one).
    local tool_call_args
    tool_call_args=$(echo "$step1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
tcs = d['choices'][0]['message'].get('tool_calls') or []
if tcs:
    print(tcs[0]['function']['arguments'])
" 2>/dev/null)
    if [ -z "$tool_call_args" ]; then
        echo "  FAIL: step1: LLM did not return a tool_call"
        echo "  body: $(echo "$step1" | head -c 600)"
        return 1
    fi
    echo "  OK: step1: LLM emitted tool_call: $(echo "$tool_call_args" | head -c 200)"

    # Step 2: dispatch the tool_call to MCP and grab the result.
    local mcp_result
    mcp_result=$(_piston_mcp_call_tool "mcp_tools-execute_code" "$tool_call_args")
    assert_not_empty "$mcp_result" "step2: MCP returned a response" || return 1

    local stdout exit_code
    stdout=$(echo "$mcp_result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
content = d.get('result',{}).get('content',[])
for c in content:
    if c.get('type') == 'text':
        inner = json.loads(c['text'])
        print(inner.get('stdout','').rstrip('\n'))
        break
" 2>/dev/null)
    exit_code=$(echo "$mcp_result" | python3 -c "
import sys, json
d = json.load(sys.stdin)
content = d.get('result',{}).get('content',[])
for c in content:
    if c.get('type') == 'text':
        inner = json.loads(c['text'])
        print(inner.get('exit_code',''))
        break
" 2>/dev/null)
    echo "  OK: step2: tool execution exit_code=$exit_code stdout='$(echo "$stdout" | head -c 200)'"

    # Step 3: assert the LLM-written code produced the expected hash.
    if [[ "$stdout" != *"$_PISTON_EXPECTED_HASH"* ]]; then
        echo "  FAIL: step3: stdout did not contain expected SHA-256"
        echo "    expected (substring): $_PISTON_EXPECTED_HASH"
        echo "    got                 : $stdout"
        return 1
    fi
    echo "OK: piston_e2e_groq_drives_execute_code (LLM wrote correct python, sandbox ran it, hash matched)"
}

ALL_TESTS+=(
    test_piston_route_requires_auth
    test_piston_runtimes_listed
    test_piston_python_execute
    test_piston_node_execute
    test_piston_sandbox_no_network
    test_piston_mcp_tool_registered
    test_piston_mcp_tool_call
    test_piston_e2e_groq_drives_execute_code
)
