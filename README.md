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
