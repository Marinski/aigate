#!/bin/bash

# ── mailbox: gated on MAILBOX=1 ──────────────────────────────────────────────

_MCP_ACCEPT="Accept: application/json, text/event-stream"

_mailbox_enabled() {
    [ "${MAILBOX:-0}" = "1" ]
}

# ── health is always open (no bearer required) ───────────────────────────────

test_mailbox_health() {
    _mailbox_enabled || { echo "  SKIP: MAILBOX not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/mailbox/health")
    assert_eq "$code" "200" "mailbox /health returns 200" || return 1
    echo "OK: mailbox_health"
}

# ── auth enforced on non-/health endpoints ───────────────────────────────────

test_mailbox_requires_auth() {
    _mailbox_enabled || { echo "  SKIP: MAILBOX not enabled"; return 0; }
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/mailbox/mailboxes")
    if [ "$code" != "401" ] && [ "$code" != "403" ]; then
        echo "  FAIL: expected 401/403 without token, got $code"
        return 1
    fi
    echo "OK: mailbox_requires_auth ($code)"
}

# ── /mailboxes lists configured accounts ─────────────────────────────────────

test_mailbox_list_mailboxes() {
    _mailbox_enabled || { echo "  SKIP: MAILBOX not enabled"; return 0; }
    local out
    out=$(curl -sf "$BASE_URL/mailbox/mailboxes" \
        -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" 2>/dev/null)
    assert_not_empty "$out" "mailbox /mailboxes response" || return 1
    # response shape: list of {name, description, imap, smtp} — must have at least one entry
    local count
    count=$(echo "$out" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else len(d.get('mailboxes',[])))" 2>/dev/null)
    if [ "${count:-0}" -lt 1 ]; then
        echo "  FAIL: expected >=1 configured mailbox, got ${count:-0}"
        return 1
    fi
    echo "OK: mailbox_list_mailboxes ($count accounts)"
}

# ── MCP exposes mailbox tools via LiteLLM's /mcp/ aggregator ─────────────────

test_mailbox_mcp_tools_present() {
    _mailbox_enabled || { echo "  SKIP: MAILBOX not enabled"; return 0; }
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
print(sum(1 for t in tools if t['name'].startswith('mailbox-')))
" 2>/dev/null)
    if [ "${count:-0}" -lt 4 ]; then
        echo "  FAIL: expected >= 4 mailbox MCP tools, got ${count:-0}"
        return 1
    fi
    echo "OK: mailbox_mcp_tools_present ($count tools)"
}

# ── end-to-end: send to self, find it, read it, delete it ───────────────────
# Gated on MAILBOX_TEST_MAILBOX_NAME + MAILBOX_TEST_ADDRESS so this only fires
# when the operator has wired a mailbox they're willing to send real mail to.
# The mailbox is sent to itself, so it must have both IMAP and SMTP configured.

_mailbox_e2e_enabled() {
    _mailbox_enabled \
        && [ -n "${MAILBOX_TEST_MAILBOX_NAME:-}" ] \
        && [ -n "${MAILBOX_TEST_ADDRESS:-}" ]
}

test_mailbox_send_recv_delete() {
    if ! _mailbox_e2e_enabled; then
        echo "  SKIP: MAILBOX_TEST_MAILBOX_NAME / MAILBOX_TEST_ADDRESS not set"
        return 0
    fi

    local name="$MAILBOX_TEST_MAILBOX_NAME"
    local addr="$MAILBOX_TEST_ADDRESS"
    local token
    token=$(printf 'aigate-mailbox-e2e-%s-%s' "$(date +%s)" "$RANDOM")
    local subject="[aigate-test] $token"
    local body="aigate mailbox e2e — token=$token. Safe to delete."

    # 1. send to self
    local send_out
    send_out=$(curl -sf -X POST "$BASE_URL/mailbox/mailboxes/$name/send" \
        -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        --max-time 60 \
        -d "$(python3 -c "
import json, sys
print(json.dumps({
    'to': [sys.argv[1]],
    'subject': sys.argv[2],
    'body_text': sys.argv[3],
}))
" "$addr" "$subject" "$body")" 2>/dev/null)
    assert_not_empty "$send_out" "mailbox send response" || { echo "  send failed"; return 1; }
    echo "  sent: $subject"

    # 2. poll inbox until the message shows up (IMAP delivery can take a moment)
    local encoded_subject uid mailbox_name found=""
    encoded_subject=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$token")
    local deadline=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local inbox_json
        inbox_json=$(curl -sf "$BASE_URL/mailbox/inbox?mailbox=$name&subject=$encoded_subject&limit=10" \
            -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" 2>/dev/null)
        if [ -n "$inbox_json" ]; then
            uid=$(echo "$inbox_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
msgs = d.get('messages') if isinstance(d, dict) else d
for m in msgs or []:
    if '${token}' in (m.get('subject') or ''):
        print(m.get('uid', ''))
        break
" 2>/dev/null)
            if [ -n "$uid" ]; then
                found=1
                break
            fi
        fi
        sleep 3
    done

    if [ -z "$found" ]; then
        echo "  FAIL: message with token=$token did not appear within 90s"
        return 1
    fi
    echo "  received: uid=$uid"

    # 3. read the full message and verify the body marker round-trips
    local msg_json
    msg_json=$(curl -sf "$BASE_URL/mailbox/mailboxes/$name/messages/$uid" \
        -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" 2>/dev/null)
    assert_not_empty "$msg_json" "get_message response" || return 1
    local body_seen
    body_seen=$(echo "$msg_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print((d.get('body_text') or d.get('body_html') or ''))
" 2>/dev/null)
    if ! echo "$body_seen" | grep -q "$token"; then
        echo "  FAIL: token=$token not found in retrieved message body"
        return 1
    fi
    echo "  read: body matches"

    # 4. delete it
    local del_code
    del_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        "$BASE_URL/mailbox/mailboxes/$name/messages/$uid" \
        -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN")
    if [ "$del_code" != "200" ] && [ "$del_code" != "204" ]; then
        echo "  FAIL: DELETE returned $del_code"
        return 1
    fi
    echo "  deleted: uid=$uid ($del_code)"

    # 5. confirm gone — search for the same subject must come back empty
    sleep 2
    local after_json after_count
    after_json=$(curl -sf "$BASE_URL/mailbox/inbox?mailbox=$name&subject=$encoded_subject&limit=10" \
        -H "Authorization: Bearer $MAILBOX_AUTH_TOKEN" 2>/dev/null)
    after_count=$(echo "$after_json" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
msgs = d.get('messages') if isinstance(d, dict) else d
print(sum(1 for m in (msgs or []) if '${token}' in (m.get('subject') or '')))
" 2>/dev/null)
    if [ "${after_count:-0}" != "0" ]; then
        echo "  FAIL: message still visible after delete (count=$after_count)"
        return 1
    fi
    echo "OK: mailbox_send_recv_delete (send → recv → read → delete → gone)"
}

ALL_TESTS+=(
    test_mailbox_health
    test_mailbox_requires_auth
    test_mailbox_list_mailboxes
    test_mailbox_mcp_tools_present
    test_mailbox_send_recv_delete
)
