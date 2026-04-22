#!/usr/bin/env bash
# MCP Streamable-HTTP smoke test (GEP-29 wave f).
#
# Exercises the full MCP protocol against a running Glorbo server:
#
#   initialize → tools/list → tools/call → resources/list →
#   resources/subscribe → GET /mcp (SSE) → trigger change →
#   verify notifications/resources/updated frame → DELETE.
#
# Treats Glorbo as a black box — no app-internal hooks, just curl +
# jq against the MCP endpoint. Runs against `mix phx.server` on
# localhost:4000 by default; override with MCP_URL=http://host:port/mcp.
#
# Requires: curl, jq.
#
# Exit 0 on success; non-zero on any protocol failure. Prints a
# per-step pass/fail line so it's readable as either a human smoke
# test or a CI script.

set -euo pipefail

MCP_URL="${MCP_URL:-http://localhost:4000/mcp}"
CLIENT="glorbo-smoke"
PROTO="2025-06-18"

# ── helpers ────────────────────────────────────────────────────────

step() { printf '→ %s\n' "$*"; }
pass() { printf '  ✓ %s\n' "$*"; }
fail() { printf '  ✗ %s\n' "$*" >&2; exit 1; }

# POST a JSON-RPC envelope. Arg 1 is the full body as a JSON string.
# Arg 2 (optional) is an extra header, e.g. "mcp-session-id: xyz".
mcp_post() {
  local body="$1"
  local extra_header="${2:-}"
  local args=(
    -sS -X POST "$MCP_URL"
    -H "content-type: application/json"
    -H "mcp-client-name: $CLIENT"
    # MCP-Protocol-Version is required on every non-initialize POST
    # per the 2025-06-18 transport spec. Sending it on initialize too
    # is harmless — the server ignores the header on that method
    # and reads the version from the JSON body instead.
    -H "mcp-protocol-version: $PROTO"
    --data-binary "$body"
  )
  if [[ -n "$extra_header" ]]; then
    args+=(-H "$extra_header")
  fi
  # Also print headers so the caller can grep for Mcp-Session-Id.
  curl "${args[@]}" -D - -o /tmp/mcp-body.$$
  cat /tmp/mcp-body.$$
  rm -f /tmp/mcp-body.$$
}

# ── step 1: initialize, capture session id ─────────────────────────

step "POST initialize"
init_resp=$(mcp_post "$(jq -cn --arg p "$PROTO" '{
  jsonrpc:"2.0", id:1, method:"initialize",
  params:{protocolVersion:$p, capabilities:{}, clientInfo:{name:"smoke",version:"0"}}
}')")

session_id=$(printf '%s' "$init_resp" \
  | grep -i '^mcp-session-id:' \
  | head -1 \
  | awk '{print $2}' | tr -d '\r')

[[ -n "$session_id" ]] || fail "no Mcp-Session-Id header in initialize response"
pass "session_id=$session_id"

# Strip HTTP headers; body is after the blank line.
init_body=$(printf '%s' "$init_resp" | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')
proto_out=$(printf '%s' "$init_body" | jq -r '.result.protocolVersion // empty')
[[ "$proto_out" == "$PROTO" ]] || fail "protocol mismatch: server replied $proto_out"
pass "server speaks $PROTO"

caps=$(printf '%s' "$init_body" | jq -r '.result.capabilities.resources.subscribe // false')
[[ "$caps" == "true" ]] || fail "resources.subscribe capability not advertised"
pass "resources.subscribe advertised"

# ── step 2: tools/list ─────────────────────────────────────────────

step "POST tools/list"
tools_body=$(mcp_post \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  "mcp-session-id: $session_id" \
  | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')

tool_count=$(printf '%s' "$tools_body" | jq '.result.tools | length')
(( tool_count >= 15 )) || fail "expected ≥15 registered tools, got $tool_count"
pass "tool catalog has $tool_count tools"

first_tool=$(printf '%s' "$tools_body" | jq -r '.result.tools[0].name')
[[ "$first_tool" =~ ^glorbo\. ]] || fail "tool name doesn't follow glorbo.* convention: $first_tool"
pass "tool naming convention OK (first: $first_tool)"

# ── step 3: tools/call glorbo.list_companies ───────────────────────

step "POST tools/call glorbo.list_companies"
call_body=$(mcp_post \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"glorbo.list_companies","arguments":{}}}' \
  "mcp-session-id: $session_id" \
  | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')

# `//` triggers on `false`, not just null — use `has` to disambiguate.
is_err=$(printf '%s' "$call_body" | jq -r 'if (.result | has("isError")) then .result.isError else "missing" end')
[[ "$is_err" == "false" ]] || fail "list_companies returned isError=$is_err: $call_body"
pass "list_companies succeeded"

# ── step 4: resources/list + resources/templates/list ──────────────

step "POST resources/list"
rlist_body=$(mcp_post \
  '{"jsonrpc":"2.0","id":4,"method":"resources/list"}' \
  "mcp-session-id: $session_id" \
  | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')
rcount=$(printf '%s' "$rlist_body" | jq '.result.resources | length')
pass "resources/list returned $rcount resources"

step "POST resources/templates/list"
tmpl_body=$(mcp_post \
  '{"jsonrpc":"2.0","id":5,"method":"resources/templates/list"}' \
  "mcp-session-id: $session_id" \
  | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')
tmpl_names=$(printf '%s' "$tmpl_body" | jq -r '.result.resourceTemplates[].name' | tr '\n' ',' | sed 's/,$//')
[[ "$tmpl_names" =~ company-audit ]] || fail "missing company-audit template: $tmpl_names"
pass "templates: $tmpl_names"

# ── step 5: resources/subscribe to audit URI ───────────────────────

# Pick the first chat URI from resources/list. Channel events flow
# through the Watcher → PubSub path, which is the deterministic
# broadcast surface that the Session subscribes to for chat URIs.
sub_uri=$(printf '%s' "$rlist_body" \
  | jq -r '[.result.resources[] | select(.uri | startswith("glorbo://chat/"))] | .[0].uri // empty')

[[ -n "$sub_uri" ]] || fail "no chat URI advertised; does any company have a channel?"

step "POST resources/subscribe $sub_uri"
sub_body=$(mcp_post \
  "$(jq -cn --arg u "$sub_uri" '{jsonrpc:"2.0",id:6,method:"resources/subscribe",params:{uri:$u}}')" \
  "mcp-session-id: $session_id" \
  | awk 'BEGIN{b=0} /^\r?$/{b=1;next} b{print}')

# resources/subscribe returns an empty result object on success.
err_code=$(printf '%s' "$sub_body" | jq -r '.error.code // empty')
[[ -z "$err_code" ]] || fail "subscribe returned error $err_code: $sub_body"
pass "subscribed to $sub_uri"

# Extract company + channel slug from the chosen URI — the chat URI
# we're about to subscribe to may belong to a different company than
# MCP_SMOKE_COMPANY (the script picks the first chat URI advertised).
# Subscription and trigger MUST target the same resource.
sub_co=$(printf '%s' "$sub_uri" | awk -F/ '{print $4}')
channel_slug="${sub_uri##*/}"

# ── step 6: open SSE stream, trigger an audit change, capture it ──

step "GET /mcp (SSE) in background"
sse_log=$(mktemp /tmp/mcp-sse.XXXXXX)
# Note: curl --max-time bounds the run to ~4s so we don't hang forever.
curl -sS -N \
  -H "mcp-session-id: $session_id" \
  -H "mcp-protocol-version: $PROTO" \
  --max-time 4 \
  "$MCP_URL" > "$sse_log" 2>/dev/null &
sse_pid=$!

# Give the SSE stream a moment to open.
sleep 0.5

# Trigger a channel broadcast: post_message writes to
# channels/<slug>.md → Watcher detects → broadcasts on
# `company:<co>:channels:<slug>`. Session forwards to SSE.
step "POST tools/call glorbo.post_message (triggers channel broadcast)"
trigger_args="$(jq -cn \
  --arg c "$sub_co" \
  --arg ch "$channel_slug" \
  --arg body "mcp-smoke trigger $(date -u +%H%M%S)" '{
  jsonrpc:"2.0", id:7, method:"tools/call",
  params:{name:"glorbo.post_message", arguments:{company:$c, channel:$ch, body:$body}}
}')"
mcp_post "$trigger_args" "mcp-session-id: $session_id" >/dev/null
pass "trigger dispatched"

# Wait for SSE to finish (or timeout).
wait "$sse_pid" 2>/dev/null || true

step "verify resources/updated frame arrived"
if grep -q '"method":"notifications/resources/updated"' "$sse_log" \
   && grep -q "\"uri\":\"$sub_uri\"" "$sse_log"; then
  pass "SSE delivered notifications/resources/updated for $sub_uri"
else
  echo "---- SSE log begin ----" >&2
  cat "$sse_log" >&2
  echo "---- SSE log end ----" >&2
  fail "did not observe expected notification frame"
fi
rm -f "$sse_log"

# ── step 7: DELETE the session ─────────────────────────────────────

step "DELETE /mcp"
del_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X DELETE \
  -H "mcp-session-id: $session_id" \
  "$MCP_URL")
[[ "$del_status" == "204" ]] || fail "DELETE returned $del_status, expected 204"
pass "session terminated"

# Subsequent request with the same session must 404.
step "POST ping with stale session (expect 404)"
stale_status=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "$MCP_URL" \
  -H "content-type: application/json" \
  -H "mcp-session-id: $session_id" \
  -H "mcp-protocol-version: $PROTO" \
  --data-binary '{"jsonrpc":"2.0","id":99,"method":"ping"}')
[[ "$stale_status" == "404" ]] || fail "stale session should 404, got $stale_status"
pass "stale session rejected"

printf '\nAll checks passed.\n'
