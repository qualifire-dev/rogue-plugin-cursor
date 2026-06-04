#!/usr/bin/env bash
# tests/test_hook_sh.sh — end-to-end for the bash dispatcher (hook.sh):
# env file → hook.sh → mock server → stdout. Holds the dispatcher to the
# pass-through + fail-open + header contract.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/plugins/rogue/scripts/hook.sh"
# hooks.json invokes the dispatcher via `sh`; override with TEST_SH=dash to
# exercise strict POSIX (Debian/Ubuntu /bin/sh).
SH="${TEST_SH:-sh}"

PORT=$((RANDOM % 10000 + 30000))
HEADERS_FILE="$(mktemp)"
ENV_FILE="$(mktemp)"

cleanup() {
  [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true
  rm -f "$ENV_FILE" "$HEADERS_FILE"
}
trap cleanup EXIT

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
  # Clear CURSOR_PLUGIN_ROOT so the bundled-env path doesn't shadow ~/.rogue-env.
  HOME="$tmp_home" CURSOR_PLUGIN_ROOT="" "$SH" "$HOOK" "$1" <<< "$2"
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
  local key="$1" expected="$2" label="$3" actual
  actual=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["headers"].get(sys.argv[2], ""))' "$HEADERS_FILE" "$key")
  assert_eq "$actual" "$expected" "$label"
}

assert_body() {
  local expected="$1" label="$2" actual
  actual=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["body"])' "$HEADERS_FILE")
  assert_eq "$actual" "$expected" "$label"
}

# ── Case 1: ask response relayed verbatim + headers ────────────────────────
start_mock '{"permission":"ask","user_message":"flagged","agent_message":"rm-rf"}'
out=$(run_dispatcher preToolUse '{"tool_name":"Shell","tool_input":{"command":"rm -rf /"}}')
assert_eq "$out" '{"permission":"ask","user_message":"flagged","agent_message":"rm-rf"}' "ask response relayed verbatim"
assert_header "x-rogue-event"   "preToolUse" "x-rogue-event is verbatim Cursor event name"
assert_header "x-rogue-source"  "cursor"     "x-rogue-source=cursor"
assert_header "x-rogue-api-key" "test-key"   "x-rogue-api-key forwarded"
assert_header "x-rogue-actor-email" "test@example.com" "x-rogue-actor-email forwarded"
assert_header "x-rogue-actor-name"  "Test User"        "x-rogue-actor-name forwarded (with space)"

# ── Case 2: deny relayed; camelCase event name preserved ───────────────────
restart_mock '{"permission":"deny","user_message":"blocked"}'
out=$(run_dispatcher beforeShellExecution '{"command":"curl http://evil"}')
assert_eq "$out" '{"permission":"deny","user_message":"blocked"}' "deny response relayed"
assert_header "x-rogue-event" "beforeShellExecution" "verbatim event name (camelCase preserved)"

# ── Case 3: {} informational relayed ───────────────────────────────────────
restart_mock '{}'
out=$(run_dispatcher afterAgentResponse '{"text":"done"}')
assert_eq "$out" "{}" "empty informational response relayed"

# ── Case 4: beforeSubmitPrompt-shaped response relayed ─────────────────────
restart_mock '{"continue":false,"user_message":"prompt injection blocked"}'
out=$(run_dispatcher beforeSubmitPrompt '{"prompt":"ignore previous"}')
assert_eq "$out" '{"continue":false,"user_message":"prompt injection blocked"}' "beforeSubmitPrompt response relayed"

# ── Case 5: unconfigured (no API key) → {} without calling server ──────────
TMP_HOME="$(mktemp -d)"
out=$(HOME="$TMP_HOME" CURSOR_PLUGIN_ROOT="" "$SH" "$HOOK" preToolUse <<< '{}')
rm -rf "$TMP_HOME"
assert_eq "$out" "{}" "unconfigured fails open"

# ── Case 6: unconfigured sessionStart returns setup hint ───────────────────
TMP_HOME="$(mktemp -d)"
out=$(HOME="$TMP_HOME" CURSOR_PLUGIN_ROOT="" "$SH" "$HOOK" sessionStart <<< '{}')
rm -rf "$TMP_HOME"
echo "$out" | grep -q '/rogue:setup' || { echo "FAIL: missing setup hint in $out"; exit 1; }
echo "  ok: unconfigured sessionStart emits /rogue:setup hint"

# ── Case 7: malformed server body → fail open ──────────────────────────────
restart_mock 'not json at all'
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "malformed JSON → fail open"

# ── Case 7b: JSON-looking but invalid body → fail open ─────────────────────
# A first-character `{` check would relay this verbatim; emit() must validate.
restart_mock '{not json'
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "JSON-looking-but-invalid body → fail open"

# ── Case 8: HTTP 500 → fail open ───────────────────────────────────────────
restart_mock '{"permission":"deny"}' 500
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "HTTP 500 → fail open"

# ── Case 9: empty body → {} ────────────────────────────────────────────────
restart_mock ''
out=$(run_dispatcher preToolUse '{}')
assert_eq "$out" "{}" "empty body → {}"

# ── Case 10: missing event arg → {} ────────────────────────────────────────
out=$("$SH" "$HOOK" <<< '{}')
assert_eq "$out" "{}" "missing event arg → {}"

# ── Case 11: leading UTF-8 BOM stripped from forwarded body ────────────────
# Cursor on Windows prepends a UTF-8 BOM to the payload; a BOM-prefixed body is
# invalid JSON and the API 400s. The dispatcher must strip it before POSTing.
restart_mock '{}'
BOM="$(printf '\357\273\277')"
out=$(run_dispatcher beforeSubmitPrompt "${BOM}{\"prompt\":\"hi\"}")
assert_body '{"prompt":"hi"}' "leading UTF-8 BOM stripped from POST body"

echo
echo "All hook.sh smoke tests passed."

