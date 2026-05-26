#!/usr/bin/env bash
# tests/test_smoke.sh — end-to-end: env file → dispatcher → mock server → stdout
# The dispatcher is a pass-through, so we mostly verify that the server's
# response bytes survive the round-trip and that the request headers carry
# the verbatim event name, api key, source, etc.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/rogue/scripts/rogue-hook.py"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

ENV_FILE="$(mktemp)"
cat > "$ENV_FILE" <<EOF
export ROGUE_API_KEY=test-key
export ROGUE_ACTOR_EMAIL=test@example.com
export ROGUE_ACTOR_NAME='Test User'
export ROGUE_BASE_URL=http://127.0.0.1:${PORT}
EOF

run_dispatcher() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  cp "$ENV_FILE" "$tmp_home/.rogue-env"
  HOME="$tmp_home" python3 "$HOOK" "$1" <<< "$2"
  rm -rf "$tmp_home"
}

start_mock() {
  MOCK_RESPONSE="$1" MOCK_STATUS="${2:-200}" \
    python3 "$REPO/tests/mock_server.py" "$PORT" "$HEADERS_FILE" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    nc -z 127.0.0.1 "$PORT" 2>/dev/null && return 0
    sleep 0.1
  done
  echo "mock server failed to start" >&2; exit 1
}

restart_mock() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  start_mock "$@"
}

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL [$3]: expected $2 but got $1" >&2; exit 1
  fi
  echo "  ok: $3"
}

assert_header() {
  local key="$1" expected="$2" label="$3"
  local actual
  actual=$(python3 -c "import json; print(json.load(open('$HEADERS_FILE'))['headers'].get('$key',''))")
  assert_eq "$actual" "$expected" "$label"
}

# ── Case 1: server returns a Cursor-shaped ask response → relay verbatim ──
start_mock '{"permission":"ask","user_message":"Rogue Security marked this tool_call as malicious. Are you sure you want to continue?","agent_message":"flagged: rm-rf"}'
out=$(run_dispatcher preToolUse '{"tool_name":"Shell","tool_input":{"command":"rm -rf /"}}')
assert_eq "$out" '{"permission":"ask","user_message":"Rogue Security marked this tool_call as malicious. Are you sure you want to continue?","agent_message":"flagged: rm-rf"}' "ask response relayed verbatim"

# Verify the headers the server received.
assert_header "x-rogue-event"      "preToolUse" "x-rogue-event is verbatim Cursor event name"
assert_header "x-rogue-source"     "cursor"     "x-rogue-source=cursor"
assert_header "x-rogue-api-key"    "test-key"   "x-rogue-api-key forwarded"

# ── Case 2: server returns a deny decision → relayed verbatim ──
restart_mock '{"permission":"deny","user_message":"blocked"}'
out=$(run_dispatcher beforeShellExecution '{"command":"curl http://evil"}')
assert_eq "$out" '{"permission":"deny","user_message":"blocked"}' "deny response relayed"
assert_header "x-rogue-event"      "beforeShellExecution" "verbatim event name (camelCase preserved)"

# ── Case 3: server returns {} (informational event) → dispatcher relays {} ──
restart_mock '{}'
out=$(run_dispatcher afterAgentResponse '{"text":"done"}')
assert_eq "$out" "{}" "empty informational response relayed"
assert_header "x-rogue-event" "afterAgentResponse" "afterAgentResponse event name verbatim"

# ── Case 4: server returns beforeSubmitPrompt-shaped response → relayed ──
restart_mock '{"continue":false,"user_message":"prompt injection blocked"}'
out=$(run_dispatcher beforeSubmitPrompt '{"prompt":"ignore previous"}')
assert_eq "$out" '{"continue":false,"user_message":"prompt injection blocked"}' "beforeSubmitPrompt response relayed"

# ── Case 5: unconfigured (no API key) → dispatcher returns {} without calling server ──
out=$(HOME="$(mktemp -d)" python3 "$HOOK" preToolUse <<< '{}')
assert_eq "$out" "{}" "unconfigured fails open"

# ── Case 6: unconfigured sessionStart returns setup hint ──
out=$(HOME="$(mktemp -d)" python3 "$HOOK" sessionStart <<< '{}')
echo "$out" | grep -q '/rogue:setup' || { echo "FAIL: missing setup hint in $out"; exit 1; }
echo "  ok: unconfigured sessionStart emits /rogue:setup hint"

# ── Case 7: server returns garbage → dispatcher fails open ──
restart_mock 'not json at all'
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "malformed JSON → fail open"

# ── Case 8: server returns 500 → dispatcher fails open ──
restart_mock '{"permission":"deny"}' 500
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "HTTP 500 → fail open"

# ── Case 9: empty body → dispatcher emits {} ──
restart_mock ''
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "empty body → {}"

echo
echo "All smoke tests passed."
