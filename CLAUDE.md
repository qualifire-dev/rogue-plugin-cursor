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
- `plugins/rogue/scripts/rogue-hook.py` — the dispatcher. Pass-through to the server. Unit-tested (`tests/test_rogue_hook.py`) for the small bits it does locally (env parsing, actor resolution, JSON validation, unconfigured hint); HTTP round-trip is smoke-tested.
- `plugins/rogue/scripts/setup.sh` — writes `~/.rogue-env` (mode 600).
- `plugins/rogue/scripts/auto-update.sh` — background updater fired from sessionStart. Rate-limited to once per 24h via `~/.rogue/.auto-update-check-cursor`.
- `plugins/rogue/commands/{setup,status}.md` — slash commands.
- `scripts/compile-customer-plugin.sh` — builds a flat tarball with `ROGUE_API_KEY` baked into `<plugin_root>/env`. Used to ship an MDM-free install option. Actor identity is NOT baked in — it's resolved per-user at hook-fire time via `_resolve_actor()`.

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

- `_load_creds()` — env file + process env resolution. Searches `${CURSOR_PLUGIN_ROOT}/env` (compiled plugin), `/etc/rogue/env` (MDM), `~/.rogue-env` (per-user); later wins, process env wins over all.
- `_resolve_actor()` — actor email/name. Order: explicit `ROGUE_ACTOR_*` → `git config` → `whoami`/`hostname` commands (last-resort, used when git isn't installed).
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
