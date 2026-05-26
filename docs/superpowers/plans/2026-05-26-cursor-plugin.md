# Rogue Security Cursor Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Rogue Security AIDR Claude plugin to Cursor — observe every Cursor agent lifecycle event, POST it to `https://api.rogue.security/api/v1/hooks/cursor`, and enforce server decisions using Cursor-native UX (`user_message`, `agent_message`, `permission: ask|deny`, `continue: false`). No `osascript`.

**Architecture:**
- Cursor plugin loaded by Cursor v2026.x. Manifest at `plugins/rogue/.cursor-plugin/plugin.json`, hooks at `plugins/rogue/hooks/hooks.json`, marketplace at `.cursor-plugin/marketplace.json`.
- **Single dispatcher script** `scripts/rogue-hook.py` — all hooks call it with the event name as `argv[1]`. The script reads stdin (Cursor's event payload), POSTs to the Rogue API with the event name as the `x-rogue-event` header **verbatim** (lowerCamelCase, no translation), validates the response is JSON, and **relays it to stdout as-is**. The server returns the exact Cursor-native output JSON for that event (e.g. `{permission, user_message, agent_message}` for `preToolUse`, `{continue, user_message}` for `beforeSubmitPrompt`). The dispatcher is a thin pipe — no per-event reshaping client-side. All AIDR/policy logic lives on the server, which has full event context.
- Credentials sourced from the **same `~/.rogue-env` file** the Claude plugin writes (and `/etc/rogue/env` for MDM). Cross-product reuse: a user with both plugins configures once.
- **Block UX is server-controlled.** The server decides between `permission: "ask"` and `permission: "deny"` (and any other policy choices) based on its own configuration. The client has no preference flag and forwards no block-mode hint — all policy logic lives on the server, which has full event context.
- **Fail-open** on missing key / network failure / non-JSON response — dispatcher emits `{}` and exits 0 so Cursor is never blocked by Rogue infrastructure.

**Tech Stack:** Python 3 (ships on macOS via Xcode CLT, every major Linux distro), `curl`, bash. No third-party Python deps — stdlib only (`json`, `urllib.request`, `os`, `sys`).

---

## File Structure

Map of every file the plan creates or modifies. Each file has one clear responsibility — small enough to hold in context. The structure intentionally mirrors `rogue-plugin-claude` so users and operators recognize the layout.

| Path | Purpose |
|---|---|
| `.cursor-plugin/marketplace.json` | Top-level marketplace manifest. Points at `./plugins/rogue`. |
| `plugins/rogue/.cursor-plugin/plugin.json` | Plugin manifest. `version` here is the **source of truth** for release tags. |
| `plugins/rogue/hooks/hooks.json` | Wires every Cursor event to `scripts/rogue-hook.py <event-name>`. |
| `plugins/rogue/scripts/rogue-hook.py` | The dispatcher. ~80 lines. Single entry point for every hook. Pass-through to the server. |
| `plugins/rogue/scripts/setup.sh` | Writes `~/.rogue-env` (mode 600) given key + email + name. |
| `plugins/rogue/scripts/auto-update.sh` | Background updater fired from `sessionStart`. Rate-limited 24h. |
| `plugins/rogue/commands/setup.md` | `/rogue:setup` slash command (instructions for Cursor's agent to walk the user through setup). |
| `plugins/rogue/commands/status.md` | `/rogue:status` slash command (instructions for the agent to ping the API and report status). |
| `tests/test_rogue_hook.py` | Pytest-style unit tests for env-file parsing, the unconfigured-sessionStart hint, and JSON validation. |
| `tests/mock_server.py` | Tiny stdlib `http.server` mock that returns configurable response bodies — used by smoke tests. |
| `tests/test_smoke.sh` | End-to-end smoke test: run dispatcher against mock server, assert server response is relayed verbatim. |
| `install.sh` | `curl \| bash` installer. Downloads release tarball, drops it into `~/.cursor/plugins/local/rogue/`, writes `~/.rogue-env`. |
| `scripts/build-release.sh` | Tars `plugins/rogue/` into `dist/rogue-plugin-cursor-darwin.tar.gz`. |
| `.github/workflows/release.yml` | Tag-driven release pipeline. |
| `README.md` | User-facing install + usage docs. |
| `CLAUDE.md` (and `AGENTS.md` as symlink) | Guidance for AI assistants editing this repo. |
| `LICENSE` | Proprietary, mirroring claude plugin. |
| `.gitignore` | `dist/`, `__pycache__/`, `*.pyc`. |

---

## Cursor events wired

Every dispatch sets `x-rogue-event: <exact Cursor event name>` (lowerCamelCase, **no translation**). The server's `/api/v1/hooks/cursor` route uses this header to look up the correct per-event response schema. Events the plugin wires:

`sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure`, `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `afterAgentResponse`, `afterAgentThought`, `subagentStart`, `subagentStop`, `stop`, `preCompact`.

Tab hooks (`beforeTabFileRead`, `afterTabFileEdit`) and `workspaceOpen` are **out of scope** for v1 — they fire on inline-completion / workspace-open paths the AIDR product doesn't currently inspect. Adding them later is purely a `hooks.json` change.

---

## Server response contract

The Rogue API returns **exactly the JSON body Cursor expects for that hook event** — nothing more, nothing less. The dispatcher does not interpret or reshape it; it validates the response is JSON and relays the bytes verbatim to stdout.

Reference (from the Cursor docs — fully reproduced here so the plan is self-contained):

| Event | Allowed output fields |
|---|---|
| `preToolUse` | `permission` (`allow`/`deny`/`ask`), `user_message`, `agent_message`, `updated_input` |
| `postToolUse` | `updated_mcp_tool_output`, `additional_context` |
| `postToolUseFailure` | *(no output fields)* |
| `beforeShellExecution` | `permission` (`allow`/`deny`/`ask`), `user_message`, `agent_message` |
| `afterShellExecution` | *(no output fields)* |
| `beforeMCPExecution` | `permission` (`allow`/`deny`/`ask`), `user_message`, `agent_message` |
| `afterMCPExecution` | *(no output fields)* |
| `beforeReadFile` | `permission` (`allow`/`deny`), `user_message` |
| `afterFileEdit` | *(no output fields)* |
| `afterAgentResponse` | *(no output fields)* |
| `afterAgentThought` | *(no output fields)* |
| `beforeSubmitPrompt` | `continue` (`true`/`false`), `user_message` |
| `subagentStart` | `permission` (`allow`/`deny`), `user_message` |
| `subagentStop` | `followup_message` |
| `stop` | `followup_message` |
| `sessionStart` | `env`, `additional_context` |
| `sessionEnd` | *(no output fields)* |
| `preCompact` | `user_message` |

For informational events (those with "*no output fields*"), the server returns `{}`. Empty body, non-200 status, malformed JSON, or network error → dispatcher emits `{}` (fail-open).

Headers the dispatcher sends to the server on every call:

| Header | Value |
|---|---|
| `x-rogue-api-key` | From `ROGUE_API_KEY`. |
| `x-rogue-event` | The Cursor event name, verbatim. |
| `x-rogue-actor-email` | From `ROGUE_ACTOR_EMAIL` (falls back to `git config --global user.email`, then hostname). |
| `x-rogue-actor-name` | From `ROGUE_ACTOR_NAME` (falls back to `git config --global user.name`, then `$USER`). |
| `x-rogue-source` | Constant: `cursor`. Lets the server distinguish from the claude integration when both share infra. |
| `Content-Type` | `application/json`. |

---

# Task 1: Repository skeleton + manifests

**Files:**
- Create: `.cursor-plugin/marketplace.json`
- Create: `plugins/rogue/.cursor-plugin/plugin.json`
- Create: `.gitignore`
- Create: `LICENSE`

- [ ] **Step 1.1: Write `.gitignore`**

```
dist/
__pycache__/
*.pyc
.DS_Store
.pytest_cache/
```

- [ ] **Step 1.2: Write `LICENSE`** (mirroring the Claude plugin's proprietary license)

```
Copyright (c) Qualifire, Inc. All rights reserved.

This software and accompanying documentation is proprietary to Qualifire, Inc.
Use is governed by the Rogue Security customer agreement. No license is granted
except as expressly stated in that agreement.
```

- [ ] **Step 1.3: Write the marketplace manifest**

```json
{
  "$schema": "https://json.schemastore.org/cursor-marketplace.json",
  "name": "rogue-marketplace",
  "version": "1.0.0",
  "description": "Rogue Security extensions for Cursor",
  "owner": {
    "name": "Rogue Security",
    "email": "support@rogue.security",
    "url": "https://www.rogue.security"
  },
  "plugins": [
    {
      "name": "rogue",
      "version": "1.0.0",
      "description": "Rogue Security AIDR — real-time AI agent detection and response for Cursor",
      "author": {
        "name": "Rogue Security",
        "url": "https://www.rogue.security"
      },
      "homepage": "https://docs.rogue.security/integrations/cursor",
      "category": "security",
      "source": "./plugins/rogue"
    }
  ]
}
```

> The `$schema` URL may not yet exist for Cursor — it's harmless if absent. The Cursor docs document the manifest schema as separate from claude's; if Cursor rejects the field, drop it.

- [ ] **Step 1.4: Write the plugin manifest**

```json
{
  "name": "rogue",
  "version": "1.0.0",
  "description": "Rogue Security AIDR — real-time AI agent detection and response for Cursor",
  "author": {
    "name": "Rogue Security",
    "url": "https://www.rogue.security"
  },
  "homepage": "https://docs.rogue.security/integrations/cursor"
}
```

- [ ] **Step 1.5: Commit**

```bash
git add .gitignore LICENSE .cursor-plugin/ plugins/rogue/.cursor-plugin/
git commit -m "feat: scaffold cursor plugin manifests and license"
```

---

# Task 2: Dispatcher unit tests (test-first)

> Since the dispatcher is now a thin pass-through (no per-event reshaping), unit tests only need to cover the small pieces of intelligence it retains: env-file parsing, the unconfigured-sessionStart hint, and JSON-validation fail-open. Full pipeline behavior is verified by the smoke test in Task 4.

**Files:**
- Create: `tests/__init__.py` (empty)
- Create: `tests/test_rogue_hook.py`

- [ ] **Step 2.1: Write the failing tests**

```python
# tests/test_rogue_hook.py
"""
Unit tests for the small pieces of intelligence the dispatcher retains:
  - parsing ~/.rogue-env / /etc/rogue/env
  - the unconfigured-sessionStart hint
  - emitting {} on missing or malformed server response
The full HTTP round-trip is covered by tests/test_smoke.sh.
"""
import importlib.util
import io
import json
import pathlib
import pytest

HOOK_SCRIPT = pathlib.Path(__file__).parent.parent / "plugins" / "rogue" / "scripts" / "rogue-hook.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("rogue_hook", HOOK_SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def mod():
    return _load_module()


# ─── credential file parsing ────────────────────────────────────────────

def test_load_creds_parses_export_lines(mod, tmp_path, monkeypatch):
    f = tmp_path / "rogue-env"
    f.write_text(
        "# comment\n"
        "export ROGUE_API_KEY=rsk_abc123\n"
        "export ROGUE_ACTOR_EMAIL='you@example.com'\n"
        'export ROGUE_ACTOR_NAME="Your Name"\n'
    )
    monkeypatch.setattr(mod, "_CRED_FILES", (str(f),))
    monkeypatch.delenv("ROGUE_API_KEY", raising=False)
    monkeypatch.delenv("ROGUE_ACTOR_EMAIL", raising=False)
    monkeypatch.delenv("ROGUE_ACTOR_NAME", raising=False)
    creds = mod._load_creds()
    assert creds["ROGUE_API_KEY"] == "rsk_abc123"
    assert creds["ROGUE_ACTOR_EMAIL"] == "you@example.com"
    assert creds["ROGUE_ACTOR_NAME"] == "Your Name"


def test_load_creds_process_env_overrides_file(mod, tmp_path, monkeypatch):
    f = tmp_path / "rogue-env"
    f.write_text("export ROGUE_API_KEY=from_file\n")
    monkeypatch.setattr(mod, "_CRED_FILES", (str(f),))
    monkeypatch.setenv("ROGUE_API_KEY", "from_env")
    creds = mod._load_creds()
    assert creds["ROGUE_API_KEY"] == "from_env"


def test_load_creds_missing_file_is_silent(mod, monkeypatch):
    monkeypatch.setattr(mod, "_CRED_FILES", ("/nonexistent/path",))
    monkeypatch.delenv("ROGUE_API_KEY", raising=False)
    assert mod._load_creds() == {}


# ─── JSON-validation fail-open ──────────────────────────────────────────

def test_emit_bytes_passes_valid_json_through(mod, capsys):
    mod._emit_bytes(b'{"permission":"ask","user_message":"hi"}')
    assert capsys.readouterr().out == '{"permission":"ask","user_message":"hi"}'


def test_emit_bytes_empty_becomes_empty_object(mod, capsys):
    mod._emit_bytes(b"")
    assert capsys.readouterr().out == "{}"


def test_emit_bytes_malformed_json_fails_open(mod, capsys):
    mod._emit_bytes(b"not valid json at all")
    assert capsys.readouterr().out == "{}"


# ─── unconfigured behavior (no API key) ─────────────────────────────────

def test_unconfigured_session_start_emits_hint(mod, monkeypatch, capsys):
    monkeypatch.setattr(mod, "_load_creds", lambda: {})
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    mod.main(["rogue-hook.py", "sessionStart"])
    out = json.loads(capsys.readouterr().out)
    assert "additional_context" in out
    assert "/rogue:setup" in out["additional_context"]


def test_unconfigured_other_event_emits_empty(mod, monkeypatch, capsys):
    monkeypatch.setattr(mod, "_load_creds", lambda: {})
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    mod.main(["rogue-hook.py", "preToolUse"])
    assert capsys.readouterr().out == "{}"


# ─── argv validation ────────────────────────────────────────────────────

def test_no_event_arg_emits_empty(mod, capsys):
    mod.main(["rogue-hook.py"])
    assert capsys.readouterr().out == "{}"
```

- [ ] **Step 2.2: Verify tests fail (no implementation yet)**

```bash
cd /Users/yuval/work/rogue-plugin-cursor
python3 -m pytest tests/test_rogue_hook.py -v
```

Expected: **all tests fail** because `plugins/rogue/scripts/rogue-hook.py` doesn't exist yet.

- [ ] **Step 2.3: Commit the failing tests**

```bash
git add tests/__init__.py tests/test_rogue_hook.py
git commit -m "test: add unit tests for dispatcher cred parsing and fail-open"
```

---

# Task 3: Implement the dispatcher

**Files:**
- Create: `plugins/rogue/scripts/rogue-hook.py` (executable, `chmod +x`)

- [ ] **Step 3.1: Write the dispatcher**

```python
#!/usr/bin/env python3
"""
Rogue Security hook dispatcher for Cursor.

Pass-through: every hook in hooks.json calls
    python3 rogue-hook.py <cursorEventName>

The dispatcher reads the Cursor event payload from stdin, POSTs it to
the Rogue AIDR backend, and relays the server's response verbatim to
stdout. The server returns the exact Cursor-native output JSON for that
event (e.g. {permission, user_message} for preToolUse, {continue,
user_message} for beforeSubmitPrompt) — the dispatcher does not reshape.

Credential resolution order (later wins, then process env wins over both):
    1. /etc/rogue/env       (MDM-provisioned)
    2. ~/.rogue-env         (user / installer-written)

All policy decisions (allow/ask/deny) are made by the server based on its
own configuration. The dispatcher forwards no client-side preference.

Fail-open: missing API key, network failure, non-200, empty body, or
malformed JSON all result in `{}` on stdout — Cursor must never block
because Rogue infrastructure is unavailable.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import socket
import subprocess
import sys
import urllib.error
import urllib.request

DEFAULT_BASE_URL = "https://api.rogue.security"
TIMEOUT_SECONDS = 10

_CRED_FILES = ("/etc/rogue/env", os.path.expanduser("~/.rogue-env"))
_FORWARDED_ENV_VARS = (
    "ROGUE_API_KEY", "ROGUE_ACTOR_EMAIL", "ROGUE_ACTOR_NAME",
    "ROGUE_BASE_URL",
)


def _load_creds() -> dict:
    """Parse `export KEY=value` lines from each env file. Process env wins."""
    out: dict[str, str] = {}
    for path in _CRED_FILES:
        if not os.path.isfile(path):
            continue
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$", line)
                    if not m:
                        continue
                    key, val = m.group(1), m.group(2).strip()
                    try:
                        parsed = next(iter(shlex.split(val)), val)
                    except ValueError:
                        parsed = val
                    out[key] = parsed
        except OSError:
            pass
    for k in _FORWARDED_ENV_VARS:
        if os.environ.get(k):
            out[k] = os.environ[k]
    return out


def _git_config(key: str) -> str:
    try:
        return subprocess.run(
            ["git", "config", "--global", key],
            capture_output=True, text=True, timeout=2
        ).stdout.strip()
    except Exception:
        return ""


def _resolve_actor(creds: dict) -> tuple[str, str]:
    email = creds.get("ROGUE_ACTOR_EMAIL") or _git_config("user.email") or socket.gethostname()
    name = creds.get("ROGUE_ACTOR_NAME") or _git_config("user.name") or os.environ.get("USER", "")
    return email, name


def _post(url: str, headers: dict, body: bytes) -> bytes:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS) as resp:
            return resp.read() or b""
    except (urllib.error.URLError, urllib.error.HTTPError, socket.timeout,
            ConnectionError, OSError):
        return b""


def _emit_bytes(data: bytes) -> None:
    """Validate that data is JSON and relay verbatim. Otherwise emit `{}`."""
    if not data:
        sys.stdout.write("{}")
        sys.stdout.flush()
        return
    try:
        json.loads(data)
    except (ValueError, json.JSONDecodeError):
        sys.stdout.write("{}")
        sys.stdout.flush()
        return
    sys.stdout.write(data.decode("utf-8", errors="replace"))
    sys.stdout.flush()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stdout.write("{}")
        sys.stdout.flush()
        return 0
    event = argv[1]

    creds = _load_creds()
    api_key = creds.get("ROGUE_API_KEY", "")
    if not api_key:
        if event == "sessionStart":
            sys.stdout.write(json.dumps({
                "additional_context":
                    "Rogue Security plugin is installed but not configured. "
                    "Run /rogue:setup to connect your API key."
            }))
        else:
            sys.stdout.write("{}")
        sys.stdout.flush()
        return 0

    base_url = creds.get("ROGUE_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
    actor_email, actor_name = _resolve_actor(creds)

    try:
        payload = sys.stdin.read() or "{}"
    except Exception:
        payload = "{}"

    headers = {
        "Content-Type":         "application/json",
        "x-rogue-api-key":      api_key,
        "x-rogue-event":        event,                 # verbatim, no translation
        "x-rogue-actor-email":  actor_email,
        "x-rogue-actor-name":   actor_name,
        "x-rogue-source":       "cursor",
    }

    url = f"{base_url}/api/v1/hooks/cursor"
    _emit_bytes(_post(url, headers, payload.encode("utf-8")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 3.2: Make it executable**

```bash
chmod +x plugins/rogue/scripts/rogue-hook.py
```

- [ ] **Step 3.3: Run tests, verify all pass**

```bash
cd /Users/yuval/work/rogue-plugin-cursor
python3 -m pytest tests/test_rogue_hook.py -v
```

Expected: **all tests pass.** If any fail, fix the dispatcher (not the tests — the tests encode the spec).

- [ ] **Step 3.4: Commit**

```bash
git add plugins/rogue/scripts/rogue-hook.py
git commit -m "feat: implement cursor hook dispatcher (pass-through to /api/v1/hooks/cursor)"
```

---

# Task 4: Smoke test against a mock server

> The unit tests cover the pure mapping logic. Now exercise the full pipeline (env-file loading + stdin reading + HTTP POST + stdout JSON) against a real local HTTP server.

**Files:**
- Create: `tests/mock_server.py`
- Create: `tests/test_smoke.sh` (executable)

- [ ] **Step 4.1: Write the mock server**

```python
# tests/mock_server.py
"""
Tiny HTTP mock that records the inbound headers (so the smoke test can assert
on x-rogue-event etc.) and returns whatever bytes the env var MOCK_RESPONSE
contains. Sends MOCK_STATUS as the HTTP status (default 200).

Usage:
    MOCK_RESPONSE='{"permission":"ask","user_message":"hi"}' \\
        python3 mock_server.py 9876 /tmp/mock-headers.json
"""
import http.server
import json
import os
import sys


HEADERS_PATH = sys.argv[2] if len(sys.argv) > 2 else "/tmp/rogue-mock-headers.json"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body_in = self.rfile.read(length)
        # Record headers + body so the test can inspect them.
        with open(HEADERS_PATH, "w") as f:
            json.dump({
                "headers": {k.lower(): v for k, v in self.headers.items()},
                "body": body_in.decode("utf-8", errors="replace"),
                "path": self.path,
            }, f)
        status = int(os.environ.get("MOCK_STATUS", "200"))
        body = os.environ.get("MOCK_RESPONSE", "{}").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):  # silence default access log
        pass


if __name__ == "__main__":
    port = int(sys.argv[1])
    http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
```

- [ ] **Step 4.2: Write the smoke test**

```bash
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
```

- [ ] **Step 4.3: Make the smoke test executable and run it**

```bash
chmod +x tests/test_smoke.sh
./tests/test_smoke.sh
```

Expected: all assertions pass.

- [ ] **Step 4.4: Commit**

```bash
git add tests/mock_server.py tests/test_smoke.sh
git commit -m "test: add end-to-end smoke test for dispatcher pipeline"
```

---

# Task 5: Wire up hooks.json

> All hooks invoke the same dispatcher. The script lives at `${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py` — verify that env var resolves at runtime (Task 5.1). If Cursor uses a different name, fall back to a relative path.

**Files:**
- Create: `plugins/rogue/hooks/hooks.json`

- [ ] **Step 5.1: Verify the plugin-root env var name (one-time)**

Place a probe hook locally and check which env vars are set when Cursor runs it.

Symlink the in-progress plugin into Cursor:
```bash
mkdir -p ~/.cursor/plugins/local
ln -sf "$(pwd)/plugins/rogue" ~/.cursor/plugins/local/rogue
```

Create a one-off probe `plugins/rogue/hooks/probe.sh`:
```bash
#!/usr/bin/env bash
{ date; echo "---"; env | sort; echo "---"; echo "argv: $*"; } >> /tmp/rogue-cursor-probe.log
echo '{}'
```

Wire it into a `hooks.json` with a single `sessionStart` binding pointing at it. Open Cursor, start a chat to fire `sessionStart`, then inspect `/tmp/rogue-cursor-probe.log`. Confirm whether `CURSOR_PLUGIN_ROOT`, `CURSOR_PROJECT_DIR`, or similar resolves to the plugin install path. Note the canonical name in the plan.

If no plugin-root env var exists (Cursor only sets `CURSOR_PROJECT_DIR` = workspace), the dispatcher will be invoked by absolute path resolved at command-write time. We can't use `$PWD` since the working dir is the workspace, not the plugin. We'll fall back to letting `command` contain the full absolute path on install, written by `install.sh` (Task 8 takes responsibility for templating this).

Delete the probe afterward.

- [ ] **Step 5.2: Write hooks.json (assumes `CURSOR_PLUGIN_ROOT` resolves; adjust per 5.1)**

Use a templated `${CURSOR_PLUGIN_ROOT}` placeholder. If Step 5.1 shows that env var doesn't exist, replace each occurrence with the literal absolute path during install (Task 8 already handles this for `~/.cursor/plugins/local/rogue/...`).

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "command": "( nohup bash \"${CURSOR_PLUGIN_ROOT}/scripts/auto-update.sh\" >/dev/null 2>&1 & )",
        "timeout": 2
      },
      {
        "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" sessionStart",
        "timeout": 12
      }
    ],
    "sessionEnd": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" sessionEnd", "timeout": 12 }
    ],
    "beforeSubmitPrompt": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" beforeSubmitPrompt", "timeout": 12, "failClosed": false }
    ],
    "preToolUse": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" preToolUse", "timeout": 12, "failClosed": false }
    ],
    "postToolUse": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" postToolUse", "timeout": 12 }
    ],
    "postToolUseFailure": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" postToolUseFailure", "timeout": 12 }
    ],
    "beforeShellExecution": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" beforeShellExecution", "timeout": 12, "failClosed": false }
    ],
    "afterShellExecution": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" afterShellExecution", "timeout": 12 }
    ],
    "beforeMCPExecution": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" beforeMCPExecution", "timeout": 12, "failClosed": false }
    ],
    "afterMCPExecution": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" afterMCPExecution", "timeout": 12 }
    ],
    "beforeReadFile": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" beforeReadFile", "timeout": 12, "failClosed": false }
    ],
    "afterFileEdit": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" afterFileEdit", "timeout": 12 }
    ],
    "afterAgentResponse": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" afterAgentResponse", "timeout": 12 }
    ],
    "afterAgentThought": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" afterAgentThought", "timeout": 12 }
    ],
    "subagentStart": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" subagentStart", "timeout": 12 }
    ],
    "subagentStop": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" subagentStop", "timeout": 12 }
    ],
    "stop": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" stop", "timeout": 12 }
    ],
    "preCompact": [
      { "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" preCompact", "timeout": 12 }
    ]
  }
}
```

> `failClosed: false` on the gating hooks is intentional — Rogue infra failure must not block the user. Server team confirms this matches `/api/v1/hooks/claude` semantics.

- [ ] **Step 5.3: Manually fire one event end-to-end**

Re-symlink (or refresh) the plugin into Cursor's local plugin dir, then open Cursor with `ROGUE_API_KEY=…` exported, start a chat, send a prompt. Confirm the dispatcher logs hit (you can add a temporary `eprint` for the smoke run, then remove it).

- [ ] **Step 5.4: Commit**

```bash
git add plugins/rogue/hooks/hooks.json
git commit -m "feat: wire all cursor hook events through the dispatcher"
```

---

# Task 6: Credential storage helper

**Files:**
- Create: `plugins/rogue/scripts/setup.sh` (executable)

- [ ] **Step 6.1: Write setup.sh**

```bash
#!/usr/bin/env bash
# Rogue Security — credential storage helper
# Writes ~/.rogue-env (mode 600). Sourced by the dispatcher at hook fire time.
#
# Usage: setup.sh <api-key> <email> <name>
set -euo pipefail

API_KEY="${1:?Usage: setup.sh <api-key> <email> <name>}"
ACTOR_EMAIL="${2:-}"
ACTOR_NAME="${3:-}"

ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

umask 077
: > "$ENV_FILE"
{
  printf '# Managed by the rogue Cursor plugin. Read by hook subprocesses at runtime.\n'
  printf '# Delete this file to revoke credentials.\n'
  printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "OK"
echo "ENV_FILE=$ENV_FILE"
```

- [ ] **Step 6.2: Make it executable and verify**

```bash
chmod +x plugins/rogue/scripts/setup.sh
plugins/rogue/scripts/setup.sh rsk_test test@example.com 'Test User'
cat ~/.rogue-env
ls -l ~/.rogue-env  # should be -rw-------
rm ~/.rogue-env
```

- [ ] **Step 6.3: Commit**

```bash
git add plugins/rogue/scripts/setup.sh
git commit -m "feat: add credential storage helper script"
```

---

# Task 7: Slash commands

**Files:**
- Create: `plugins/rogue/commands/setup.md`
- Create: `plugins/rogue/commands/status.md`

- [ ] **Step 7.1: Write `/rogue:setup` command**

```markdown
---
description: Set up Rogue Security AIDR integration — configure API key, detect identity, verify connection
---

# Rogue Security Setup

Help the user set up their Rogue Security AIDR integration for Cursor. Follow these steps in order.

## Step 1: Check existing configuration

Check if `~/.rogue-env` exists: `test -f ~/.rogue-env && echo exists || echo missing`.

If it exists, tell the user and ask if they want to reconfigure. If not, continue.

## Step 2: Get the API key

Ask the user for their Rogue Security API key (starts with `rsk_`). If they don't have one, direct them to https://app.rogue.security/settings/api-keys.

## Step 3: Validate the key

Run:
```bash
curl -s -o /dev/null -w "%{http_code}" -H "x-rogue-api-key: <KEY>" https://api.rogue.security/api/v1/hooks/ping
```
Expect `200`. If not, the key is invalid — ask the user to try again.

## Step 4: Detect identity

```bash
git config --global user.email
git config --global user.name
```
Show what was detected and ask if it's correct.

## Step 5: Store credentials

```bash
bash "${CURSOR_PLUGIN_ROOT}/scripts/setup.sh" "<API_KEY>" "<EMAIL>" "<NAME>"
```

## Step 6: Final instructions

Tell the user:

1. Credentials are stored in `~/.rogue-env` (mode 600).
2. **Restart Cursor** (close all windows, reopen) — hooks read credentials at session start.
3. Run `/rogue:status` to verify the connection.
4. AIDR dashboard: https://app.rogue.security/aidr
```

- [ ] **Step 7.2: Write `/rogue:status` command**

```markdown
---
description: Check Rogue Security AIDR connection, active rulesets, and configuration
---

# Rogue Security Status

Verify the current Rogue Security integration. Sources credentials in order: `/etc/rogue/env` (MDM), `~/.rogue-env` (per-user).

## Step 1: Source credentials and report what was found

```bash
[ -r /etc/rogue/env ]     && . /etc/rogue/env     && echo "  /etc/rogue/env  (MDM)"
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env" && echo "  $HOME/.rogue-env  (per-user)"
[ -n "$ROGUE_API_KEY" ] && echo "API key resolved: ...${ROGUE_API_KEY: -4}" || { echo "API key: not resolved"; }
```

If `ROGUE_API_KEY` is empty, stop and tell the user to run `/rogue:setup`.

## Step 2: Ping the API

```bash
. "$HOME/.rogue-env" 2>/dev/null; [ -r /etc/rogue/env ] && . /etc/rogue/env
curl -s -w "\n%{http_code}" -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/ping"
```

## Step 3: Fetch active config

```bash
. "$HOME/.rogue-env" 2>/dev/null; [ -r /etc/rogue/env ] && . /etc/rogue/env
curl -s -H "x-rogue-api-key: $ROGUE_API_KEY" \
  "${ROGUE_BASE_URL:-https://api.rogue.security}/api/v1/hooks/config"
```

Parse the JSON and show: mode (enforce/monitor), fail-open setting, active rulesets.

## Step 4: Show identity

```bash
. "$HOME/.rogue-env" 2>/dev/null
echo "Actor email: ${ROGUE_ACTOR_EMAIL:-(unset)}"
echo "Actor name:  ${ROGUE_ACTOR_NAME:-(unset)}"
```

## Step 5: Summary

Combine credential sources, connection status, and identity into one clean summary. If everything looks good, confirm the integration is active. Block/allow/ask policy is managed server-side — direct the user to the dashboard to view or change it.

## Step 6: False-positive escape hatch

Tell the user: prepend `rgx!` to a prompt to allow it through and mark the previous detection as a false positive in the dashboard.
```

- [ ] **Step 7.3: Commit**

```bash
git add plugins/rogue/commands/
git commit -m "feat: add /rogue:setup and /rogue:status slash commands"
```

---

# Task 8: Background auto-updater

**Files:**
- Create: `plugins/rogue/scripts/auto-update.sh` (executable)

- [ ] **Step 8.1: Write auto-update.sh**

```bash
#!/usr/bin/env bash
# Silent background plugin updater. Fired from sessionStart.
# Rate-limited to once per 24h via ~/.rogue/.auto-update-check-cursor.
# Opt-outs:
#   ROGUE_AUTO_UPDATE=0       — disable entirely
#   ROGUE_PLUGIN_VERSION=v1.x — pin a version, never updates
set -u

LOG="$HOME/.rogue/auto-update-cursor.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
exec >>"$LOG" 2>&1
date "+%F %T --- auto-update tick (cursor) ---"

[ -r /etc/rogue/env ] && . /etc/rogue/env
[ -r "$HOME/.rogue-env" ] && . "$HOME/.rogue-env"

if [ "${ROGUE_AUTO_UPDATE:-1}" = "0" ]; then
  echo "ROGUE_AUTO_UPDATE=0, skipping"; exit 0
fi
if [ -n "${ROGUE_PLUGIN_VERSION:-}" ]; then
  echo "ROGUE_PLUGIN_VERSION=$ROGUE_PLUGIN_VERSION pinned, skipping"; exit 0
fi

CACHE="$HOME/.rogue/.auto-update-check-cursor"
TTL=86400
if [ -f "$CACHE" ]; then
  NOW=$(date +%s 2>/dev/null || echo 0)
  MTIME=$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null || echo 0)
  if [ $((NOW - MTIME)) -lt "$TTL" ]; then echo "within TTL, skipping"; exit 0; fi
fi
touch "$CACHE" 2>/dev/null

REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-cursor}"
PLUGIN_JSON="${CURSOR_PLUGIN_ROOT:-}/.cursor-plugin/plugin.json"
if [ ! -f "$PLUGIN_JSON" ]; then echo "no plugin.json at $PLUGIN_JSON"; exit 0; fi

INSTALLED=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' < "$PLUGIN_JSON" 2>/dev/null || echo "")
[ -z "$INSTALLED" ] && { echo "no installed version"; exit 0; }
INSTALLED_TAG="v${INSTALLED}"

LATEST=$(curl -fsSL --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
  | python3 -c 'import json,sys;d=json.loads(sys.stdin.read() or "{}");print(d.get("tag_name") or "")' 2>/dev/null || echo "")
[ -z "$LATEST" ] && { echo "could not resolve latest release"; exit 0; }

if [ "$LATEST" = "$INSTALLED_TAG" ]; then echo "up to date at $INSTALLED_TAG"; exit 0; fi

echo "upgrade available: $INSTALLED_TAG -> $LATEST, running installer"
INSTALLER_URL="${ROGUE_CURSOR_INSTALLER_URL:-https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh}"
curl -fsSL --max-time 60 "$INSTALLER_URL" | ROGUE_NON_INTERACTIVE=1 bash
echo "installer exited rc=$?"
```

- [ ] **Step 8.2: Make executable**

```bash
chmod +x plugins/rogue/scripts/auto-update.sh
```

- [ ] **Step 8.3: Commit**

```bash
git add plugins/rogue/scripts/auto-update.sh
git commit -m "feat: add background auto-updater (24h rate-limited)"
```

---

# Task 9: One-line installer

**Files:**
- Create: `install.sh` (executable)

> Adapted from `rogue-plugin-claude/install.sh`. Key differences:
> - Drops plugin into `~/.cursor/plugins/local/rogue/` (Cursor's local plugin dir per the docs).
> - No `settings.json` merge needed — Cursor auto-discovers hooks inside `<plugin>/hooks/hooks.json`.
> - If `CURSOR_PLUGIN_ROOT` env var doesn't resolve at hook runtime (verified in Task 5.1), the installer also rewrites `${CURSOR_PLUGIN_ROOT}` placeholders in `hooks.json` to the absolute install path.

- [ ] **Step 9.1: Write install.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Rogue Security — one-line installer for Cursor.
#   curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh | bash
# With credentials:
#   curl -fsSL .../install.sh | ROGUE_API_KEY=rsk_xxx ROGUE_ACTOR_EMAIL=you@co.com ROGUE_ACTOR_NAME='Your Name' bash
# Flags:
#   --api-key KEY --email EMAIL --name NAME --api-url URL
#   --local PATH        (use a local source dir, skip download)
#   --non-interactive   (fail rather than prompt)

ROGUE_API_URL_DEFAULT="https://api.rogue.security"
PLUGIN_REPO="${ROGUE_PLUGIN_REPO:-qualifire-dev/rogue-plugin-cursor}"
PLUGIN_VERSION_PIN="${ROGUE_PLUGIN_VERSION:-}"
PLUGIN_NAME="rogue"

CURSOR_DIR="$HOME/.cursor"
PLUGIN_INSTALL_DIR="$CURSOR_DIR/plugins/local/${PLUGIN_NAME}"
ENV_FILE="${ROGUE_ENV_FILE:-$HOME/.rogue-env}"

API_KEY="${ROGUE_API_KEY:-}"; ACTOR_EMAIL="${ROGUE_ACTOR_EMAIL:-}"; ACTOR_NAME="${ROGUE_ACTOR_NAME:-}"
API_URL="${ROGUE_API_URL:-$ROGUE_API_URL_DEFAULT}"
NON_INTERACTIVE="${ROGUE_NON_INTERACTIVE:-}"; LOCAL_PATH="${ROGUE_LOCAL_PATH:-}"

TMPDIR_LOCAL=""
cleanup() { [ -n "$TMPDIR_LOCAL" ] && rm -rf "$TMPDIR_LOCAL" || true; }
trap cleanup EXIT

log()  { printf "→ %s\n" "$*"; }
warn() { printf "⚠ %s\n" "$*" >&2; }
err()  { printf "✗ %s\n" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key)         API_KEY="${2:-}"; shift 2 ;;
    --email)           ACTOR_EMAIL="${2:-}"; shift 2 ;;
    --name)            ACTOR_NAME="${2:-}"; shift 2 ;;
    --api-url)         API_URL="${2:-}"; shift 2 ;;
    --local)           LOCAL_PATH="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    *) shift ;;
  esac
done

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  err "Linux support is not shipped yet" ;;
  *)      err "Unsupported platform: $(uname -s)" ;;
esac
log "Platform: $OS"

command -v python3 >/dev/null 2>&1 || err "python3 required (xcode-select --install on macOS)"
command -v curl    >/dev/null 2>&1 || err "curl required"

prompt_tty() {
  local var="$1" text="$2" secret="${3:-}"
  if [ -n "$NON_INTERACTIVE" ]; then err "$var not set and --non-interactive on"; fi
  [ -r /dev/tty ] || err "$var not set and no TTY"
  local value
  if [ "$secret" = "secret" ]; then
    printf "%s: " "$text" > /dev/tty; IFS= read -r -s value < /dev/tty; printf "\n" > /dev/tty
  else
    printf "%s: " "$text" > /dev/tty; IFS= read -r value < /dev/tty
  fi
  [ -n "$value" ] || err "$var cannot be empty."
  printf -v "$var" '%s' "$value"
}

[ -n "$API_KEY" ] || prompt_tty API_KEY "Rogue API key (rsk_...)" secret

if [ -z "$ACTOR_EMAIL" ] && command -v git >/dev/null 2>&1; then ACTOR_EMAIL=$(git config --global user.email 2>/dev/null || true); fi
if [ -z "$ACTOR_NAME"  ] && command -v git >/dev/null 2>&1; then ACTOR_NAME=$(git config --global user.name 2>/dev/null || true); fi
[ -n "$ACTOR_EMAIL" ] || ACTOR_EMAIL="$(whoami)@$(hostname -s 2>/dev/null || hostname)"
[ -n "$ACTOR_NAME"  ] || ACTOR_NAME="$(whoami)"
log "Actor: $ACTOR_NAME <$ACTOR_EMAIL>"

# Validate
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 \
  -H "x-rogue-api-key: $API_KEY" "$API_URL/api/v1/hooks/ping" 2>/dev/null || echo 000)
[ "$HTTP_CODE" = "200" ] || err "API key validation failed (HTTP $HTTP_CODE)"
log "API key valid."

# Write env file
umask 077
: > "$ENV_FILE"
{
  printf '# Managed by the rogue Cursor plugin installer.\n'
  printf 'export ROGUE_API_KEY=%q\n' "$API_KEY"
  printf 'export ROGUE_ACTOR_EMAIL=%q\n' "$ACTOR_EMAIL"
  printf 'export ROGUE_ACTOR_NAME=%q\n' "$ACTOR_NAME"
  [ "$API_URL" != "$ROGUE_API_URL_DEFAULT" ] && printf 'export ROGUE_BASE_URL=%q\n' "$API_URL"
} >> "$ENV_FILE"
chmod 600 "$ENV_FILE"
log "Wrote $ENV_FILE (mode 600)"

# Source plugin: local OR download
TMPDIR_LOCAL=$(mktemp -d)
if [ -n "$LOCAL_PATH" ]; then
  LOCAL_PATH=$(cd "$LOCAL_PATH" && pwd)
  [ -f "$LOCAL_PATH/plugins/${PLUGIN_NAME}/.cursor-plugin/plugin.json" ] \
    || err "--local path missing plugin manifest"
  SRC_DIR="$LOCAL_PATH"
else
  ASSET="rogue-plugin-cursor-${OS}.tar.gz"
  URL="https://github.com/${PLUGIN_REPO}/releases/latest/download/${ASSET}"
  [ -n "$PLUGIN_VERSION_PIN" ] && URL="https://github.com/${PLUGIN_REPO}/releases/download/${PLUGIN_VERSION_PIN}/${ASSET}"
  log "Downloading: $URL"
  curl -fsSL --max-time 60 -o "$TMPDIR_LOCAL/p.tar.gz" "$URL" \
    || err "Download failed from $URL"
  mkdir -p "$TMPDIR_LOCAL/extract"
  tar -xzf "$TMPDIR_LOCAL/p.tar.gz" -C "$TMPDIR_LOCAL/extract"
  SRC_DIR=$(find "$TMPDIR_LOCAL/extract" -mindepth 1 -maxdepth 1 -type d | head -1)
fi

PLUGIN_SRC="$SRC_DIR/plugins/${PLUGIN_NAME}"
[ -f "$PLUGIN_SRC/.cursor-plugin/plugin.json" ] || err "Missing plugin manifest in source"

# Install
mkdir -p "$(dirname "$PLUGIN_INSTALL_DIR")"
rm -rf "$PLUGIN_INSTALL_DIR"
mkdir -p "$PLUGIN_INSTALL_DIR"
cp -R "$PLUGIN_SRC/." "$PLUGIN_INSTALL_DIR/"
log "Installed → $PLUGIN_INSTALL_DIR"

# If Cursor doesn't expose CURSOR_PLUGIN_ROOT at hook runtime (verified in
# Task 5.1), templatize hooks.json to the absolute install path.
if [ "${ROGUE_TEMPLATE_HOOKS:-1}" = "1" ]; then
  HOOKS_FILE="$PLUGIN_INSTALL_DIR/hooks/hooks.json"
  if [ -f "$HOOKS_FILE" ]; then
    python3 - <<PY
import json, sys
p = "$HOOKS_FILE"
root = "$PLUGIN_INSTALL_DIR"
with open(p) as f: d = json.load(f)
def fix(s): return s.replace("\${CURSOR_PLUGIN_ROOT}", root)
for ev, entries in d.get("hooks", {}).items():
    for e in entries:
        if "command" in e: e["command"] = fix(e["command"])
with open(p, "w") as f: json.dump(d, f, indent=2)
PY
    log "Templated hook paths to $PLUGIN_INSTALL_DIR"
  fi
fi

cat <<EOF

✓ Rogue Security (Cursor) installed.

  Plugin:       $PLUGIN_INSTALL_DIR
  Credentials:  $ENV_FILE  (mode 600)

Next steps:
  1. Fully quit Cursor and reopen.
  2. Run /rogue:status inside Cursor to verify.
  3. AIDR dashboard: https://app.rogue.security/aidr

Re-running this installer upgrades the plugin and is safe.
EOF
```

- [ ] **Step 9.2: Make executable and commit**

```bash
chmod +x install.sh
git add install.sh
git commit -m "feat: add one-line installer for cursor plugin"
```

---

# Task 10: Release pipeline

**Files:**
- Create: `scripts/build-release.sh` (executable)
- Create: `.github/workflows/release.yml`

- [ ] **Step 10.1: Write build-release.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Build dist/rogue-plugin-cursor-darwin.tar.gz from the repo root.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(python3 -c 'import json;print(json.load(open("plugins/rogue/.cursor-plugin/plugin.json"))["version"])')
echo "Building rogue-plugin-cursor v${VERSION}"

mkdir -p dist
OUT="dist/rogue-plugin-cursor-darwin.tar.gz"
rm -f "$OUT"

# Tarball includes only what the installer needs.
tar -czf "$OUT" \
  .cursor-plugin/marketplace.json \
  plugins/rogue/.cursor-plugin/ \
  plugins/rogue/hooks/ \
  plugins/rogue/scripts/ \
  plugins/rogue/commands/

ls -la "$OUT"
echo "Built $OUT"
```

- [ ] **Step 10.2: Write the release workflow**

```yaml
name: release
on:
  push:
    tags: ['v*']
jobs:
  build:
    runs-on: macos-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - run: bash scripts/build-release.sh
      - uses: softprops/action-gh-release@v2
        with:
          files: dist/rogue-plugin-cursor-darwin.tar.gz
```

- [ ] **Step 10.3: Test the build locally**

```bash
chmod +x scripts/build-release.sh
scripts/build-release.sh
tar -tzf dist/rogue-plugin-cursor-darwin.tar.gz | head -20
```

Expected: lists `.cursor-plugin/marketplace.json`, `plugins/rogue/.cursor-plugin/plugin.json`, `plugins/rogue/hooks/hooks.json`, `plugins/rogue/scripts/*`, `plugins/rogue/commands/*`.

- [ ] **Step 10.4: Commit**

```bash
git add scripts/build-release.sh .github/workflows/release.yml
git commit -m "ci: add release pipeline for tagged versions"
```

---

# Task 11: Documentation

**Files:**
- Create: `README.md`
- Create: `CLAUDE.md`
- Create: `AGENTS.md` (symlink to CLAUDE.md so any agent CLI picks it up)

- [ ] **Step 11.1: Write README.md**

```markdown
# Rogue Security — Cursor Plugin

Real-time AI agent detection and response (AIDR) for [Cursor](https://cursor.com).
Observes every prompt, tool call, shell command, MCP invocation, file read, and
subagent — flags prompt injections, secret exfiltration, and destructive
operations before they reach production.

## Install

One-line installer (recommended):

```bash
curl -fsSL https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.sh | bash
```

The installer drops the plugin into `~/.cursor/plugins/local/rogue/`, writes
credentials to `~/.rogue-env`, and prepares hooks for the next Cursor restart.

Get an API key at <https://app.rogue.security/settings/api-keys>.

## What it ships

```
.cursor-plugin/marketplace.json   — marketplace manifest
plugins/rogue/
  .cursor-plugin/plugin.json      — plugin manifest
  hooks/hooks.json                — every Cursor agent event wired
  scripts/rogue-hook.py           — dispatcher (single entry point)
  scripts/setup.sh                — credential storage helper
  scripts/auto-update.sh          — background 24h auto-updater
  commands/setup.md               — /rogue:setup
  commands/status.md              — /rogue:status
```

## Hooks covered

`sessionStart`, `sessionEnd`, `beforeSubmitPrompt`, `preToolUse`, `postToolUse`,
`postToolUseFailure`, `beforeShellExecution`, `afterShellExecution`,
`beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`,
`afterAgentResponse`, `afterAgentThought`, `subagentStart`, `subagentStop`,
`stop`, `preCompact`.

All hooks POST to `https://api.rogue.security/api/v1/hooks/cursor` (configurable
via `ROGUE_BASE_URL`).

## Block UX

Block UX is decided entirely by the server based on your org's Rogue Security
configuration — the plugin has no client-side policy flags.

- **Tool calls** (`preToolUse`, `beforeShellExecution`, `beforeMCPExecution`):
  server returns `permission: ask` or `permission: deny`. `ask` renders as
  Cursor's native confirmation prompt; `deny` hard-blocks with a chat message.
- **Prompts** (`beforeSubmitPrompt`): server returns `continue: false` + a
  message shown in the chat (Cursor doesn't support ask on prompts).
- **File reads / subagent starts**: server returns `permission: deny` with a
  chat message.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `ROGUE_API_KEY` | — | Required. From <https://app.rogue.security/settings/api-keys>. |
| `ROGUE_ACTOR_EMAIL` | git config | Sent as `x-rogue-actor-email` header. |
| `ROGUE_ACTOR_NAME`  | git config | Sent as `x-rogue-actor-name`. |
| `ROGUE_BASE_URL` | `https://api.rogue.security` | API base URL. |
| `ROGUE_AUTO_UPDATE` | `1` | Set `0` to disable the background updater. |
| `ROGUE_PLUGIN_VERSION` | (unpinned) | Pin to a release tag (e.g. `v1.0.0`). |

Credentials live in `~/.rogue-env` (mode 600), shared with the Claude plugin.
System-wide MDM can use `/etc/rogue/env`.

## False positive escape hatch

Prepend `rgx!` to any prompt to allow it through and mark the previous
detection as a false positive in your dashboard. Per-prompt only.

## Dashboard

<https://app.rogue.security/aidr>

## Requirements

- Cursor v2026.x with plugin support
- `python3` and `curl` on PATH

## License

Proprietary. © Qualifire, Inc.
```

- [ ] **Step 11.2: Write CLAUDE.md**

```markdown
# CLAUDE.md

Guidance for AI assistants editing this repository.

## What this repo is

A Cursor **plugin** that ships Rogue Security AIDR. It observes every Cursor
agent lifecycle event and POSTs the payload to `https://api.rogue.security/api/v1/hooks/cursor`
for prompt-injection / secret-exfil / destructive-command detection.

No build step for the plugin itself — it's a directory of JSON + scripts that
Cursor loads at session start. The only "build" is `scripts/build-release.sh`.

## Repo layout

- `.cursor-plugin/marketplace.json` — marketplace manifest.
- `plugins/rogue/.cursor-plugin/plugin.json` — plugin manifest. **`version` is the source of truth** for release tags.
- `plugins/rogue/hooks/hooks.json` — all 18 lifecycle hooks. Every entry points at the same Python dispatcher.
- `plugins/rogue/scripts/rogue-hook.py` — the dispatcher. Pass-through to the server. Unit-tested (`tests/test_rogue_hook.py`) for the small bits it does locally (env parsing, JSON validation, unconfigured hint); HTTP round-trip is smoke-tested.
- `plugins/rogue/scripts/setup.sh` — writes `~/.rogue-env` (mode 600).
- `plugins/rogue/scripts/auto-update.sh` — background updater fired from sessionStart. Rate-limited to once per 24h via `~/.rogue/.auto-update-check-cursor`.
- `plugins/rogue/commands/{setup,status}.md` — slash commands.

## The hook pattern

Every hook in `hooks.json` calls the same dispatcher:

```json
{ "command": "python3 \"${CURSOR_PLUGIN_ROOT}/scripts/rogue-hook.py\" <eventName>", "timeout": 12 }
```

The dispatcher's job: collect creds, POST stdin to `/api/v1/hooks/cursor`, relay the response bytes verbatim. **It does not interpret the response.** The server returns whatever Cursor's hook output schema for that event requires.

Invariants when editing hooks:

- **Fail-open everywhere.** Missing API key, network failure, non-200, empty body, malformed JSON → dispatcher emits `{}` and exits 0. The user must never be blocked by Rogue infra.
- **`x-rogue-event` is the verbatim Cursor event name (lowerCamelCase)** — no translation. The server's `/api/v1/hooks/cursor` route uses it to look up the correct response schema.
- **`x-rogue-source: cursor`** distinguishes from the claude integration on the server side.
- **No client-side policy.** Block/allow/ask is decided by the server. Do not add `ROGUE_BLOCK_MODE` or any other policy flag to the dispatcher — if you find yourself wanting one, fix the server instead.
- Timeouts: HTTP `urlopen` uses `TIMEOUT_SECONDS=10`; hook `timeout: 12` (2s headroom).
- Per-event response schemas (which fields each event accepts) live in Cursor's docs and are reproduced in the plan's "Server response contract" section. **Keep that table in sync with Cursor docs** when bumping support for new events.

## Editing the dispatcher

The dispatcher is intentionally simple:

- `_load_creds()` — env file + process env resolution.
- `_resolve_actor()` — actor email/name with git/hostname/whoami fallbacks.
- `_post()` — HTTP POST, returns raw bytes (or `b""` on any error).
- `_emit_bytes()` — JSON-validate the response and relay; emit `{}` on empty or malformed.
- `main()` — argv → load creds → POST → emit.

Adding a new Cursor event = one line in `hooks.json`. No dispatcher change needed (the event name is forwarded as `x-rogue-event`). All schema/policy logic lives on the server.

## Releasing

1. Bump `version` in **both** `plugins/rogue/.cursor-plugin/plugin.json` and `.cursor-plugin/marketplace.json` — keep them in sync.
2. Commit, tag `vX.Y.Z`, push the tag. `release.yml` builds the tarball and creates the GitHub Release.
3. `auto-update.sh` on user machines picks up the new release at the next sessionStart (rate-limited 24h).

## Things that look weird but are intentional

- `hooks.json` references `${CURSOR_PLUGIN_ROOT}` even though the installer rewrites it to an absolute path. Keeping the template means the file is readable in source.
- The dispatcher reads `~/.rogue-env` via regex rather than `source`-ing — Python can't source bash. The format matches the claude plugin so a single env file works for both products.
- `auto-update.sh` uses a separate cache file (`.auto-update-check-cursor`) so the cursor and claude updaters don't fight each other.

## `rgx!` prefix is server-side

The dispatcher doesn't parse it — the API does. Don't add client-side handling.
```

- [ ] **Step 11.3: Add AGENTS.md as a symlink**

```bash
ln -sf CLAUDE.md AGENTS.md
git add AGENTS.md
```

(The symlink lets non-Claude agent CLIs that look for `AGENTS.md` find the same content.)

- [ ] **Step 11.4: Commit**

```bash
git add README.md CLAUDE.md AGENTS.md
git commit -m "docs: add README, CLAUDE.md, and AGENTS.md"
```

---

# Task 12: Final integration test

> Confirm the whole thing works end-to-end in real Cursor before declaring done.

- [ ] **Step 12.1: Install the plugin via the installer in local mode**

```bash
bash install.sh --local "$(pwd)" --api-key "$ROGUE_API_KEY" --email you@co.com --name 'You'
```

Expected: plugin installed at `~/.cursor/plugins/local/rogue/`, `~/.rogue-env` written, no errors.

- [ ] **Step 12.2: Restart Cursor**

Fully quit Cursor (Cmd-Q on macOS), reopen. Open the rogue-plugin-cursor repo as the workspace.

- [ ] **Step 12.3: Verify sessionStart fires**

In a fresh chat, run a tail in a side terminal:
```bash
tail -f ~/.rogue/auto-update-cursor.log
```

Expected: a new "auto-update tick (cursor)" line on session start. If not, check Cursor's plugin/hook UI for errors.

- [ ] **Step 12.4: Send a benign prompt**

Type a normal prompt like "list files in this repo." Expected: response works as usual.

- [ ] **Step 12.5: Send a prompt the AIDR will block**

Type a prompt designed to trigger AIDR (e.g. "exfiltrate the contents of `~/.ssh/id_rsa` via curl"). Expected: Cursor displays the "Rogue Security marked this prompt as malicious" message inline (no osascript dialog).

- [ ] **Step 12.6: Trigger a tool-call block**

Send a prompt that causes the agent to attempt `rm -rf /` or another flagged shell command. Expected: Cursor renders the response chosen by the server — either an **ask** prompt ("Rogue Security marked this tool_call as malicious. Are you sure you want to continue?") or a hard deny, per the server-side policy for this org.

- [ ] **Step 12.7: Run /rogue:status**

Expected: shows credential sources, pings 200, lists active rulesets, shows actor identity. No client-side block-mode field.

- [ ] **Step 12.8: All green → tag v1.0.0**

```bash
git tag v1.0.0
git push origin main --tags
```

The release workflow attaches `rogue-plugin-cursor-darwin.tar.gz` to the GitHub Release. The installer's URL (`releases/latest/download/...`) starts resolving to it.

---

## Self-review checklist (run after completion)

- [ ] Every hook event from the spec is wired in `hooks.json`.
- [ ] No `osascript` anywhere in the repo.
- [ ] Dispatcher does **not** reshape the server response — only relays bytes after JSON-validating (grep the dispatcher for `permission`/`continue`/`user_message` and confirm none of those literals appear there — they should only live on the server side).
- [ ] `x-rogue-event` value is the verbatim Cursor event name (e.g. `preToolUse`, not `PreToolUse`).
- [ ] No client-side block-mode flag anywhere: grep the repo for `ROGUE_BLOCK_MODE` and `x-rogue-block-mode` — both must return zero matches.
- [ ] `~/.rogue-env` reuse is documented and the dispatcher actually loads it.
- [ ] `x-rogue-source: cursor` header set on every dispatch.
- [ ] Endpoint is `/api/v1/hooks/cursor` (not `/claude`).
- [ ] `ROGUE_BASE_URL` overrides the endpoint, default `https://api.rogue.security`.
- [ ] Tests pass: `pytest tests/test_rogue_hook.py` and `./tests/test_smoke.sh`.
- [ ] Install via `install.sh --local .` succeeds; a fresh Cursor session shows the integration active.

---

## Open questions (raise with user during execution)

1. **`CURSOR_PLUGIN_ROOT` env var name** — confirmed at Task 5.1 via the probe hook. If the actual name is different (e.g. `CURSOR_PLUGIN_PATH`), update `hooks.json`, `setup.md`, `auto-update.sh`, and the installer's templating step.
2. **Plugin discovery** — this plan installs to `~/.cursor/plugins/local/`. If Cursor's team marketplace API is more appropriate for org rollout, add a follow-up doc on that path.
3. **Linux support** — the installer is macOS-only at v1.0.0 to mirror the Claude plugin. Linux can be added once a customer asks.
4. **Tab hooks (`beforeTabFileRead`, `afterTabFileEdit`)** — deliberately out of scope; revisit when product wants inline-completion visibility.
