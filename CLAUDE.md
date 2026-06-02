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
- `plugins/rogue/hooks/hooks.json` — all 18 lifecycle hooks. Every event registers **two** entries: a bash one (`hook.sh`) and a PowerShell one (`hook.ps1`). Exactly one does real work per machine (see below).
- `plugins/rogue/scripts/hook.sh` — the bash + `curl` dispatcher. Runs on macOS / Linux / WSL. Smoke-tested (`tests/test_hook_sh.sh`) against the mock server. **Stands down** (emits `{}`, exits) under Git Bash (`uname` = MINGW/MSYS/CYGWIN) so the PowerShell entry owns native Windows.
- `plugins/rogue/scripts/hook.ps1` — the PowerShell + `Invoke-WebRequest` dispatcher. Owns native Windows; stands down on non-Windows (`pwsh`). No external binaries (`python`/`node`/`curl`) assumed on either path — bash uses `curl`, PowerShell uses `Invoke-WebRequest`.
- `plugins/rogue/scripts/rogue-hook.py` — **legacy** Python dispatcher, no longer referenced by `hooks.json` (kept for reference + `tests/test_rogue_hook.py`). `hook.sh`/`hook.ps1` are faithful ports. Safe to remove once the shell ports are field-proven.
- `plugins/rogue/scripts/setup.sh` — writes `~/.rogue-env` (mode 600).
- `plugins/rogue/scripts/auto-update.sh` — background updater fired from sessionStart. Rate-limited to once per 24h via `~/.rogue/.auto-update-check-cursor`.
- `plugins/rogue/commands/{setup,status}.md` — slash commands.
- `scripts/compile-customer-plugin.sh` — builds a flat tarball with `ROGUE_API_KEY` baked into `<plugin_root>/env`. Used to ship an MDM-free install option. Actor identity is NOT baked in — it's resolved per-user at hook-fire time via `_resolve_actor()`.

## The hook pattern

Every event in `hooks.json` registers two entries — bash and PowerShell — pointing at the matching dispatcher:

```json
{ "command": "bash ./scripts/hook.sh <eventName>", "timeout": 120 },
{ "command": "powershell -NoProfile -NonInteractive -Command \"& ([scriptblock]::Create((Get-Content -Raw -LiteralPath 'scripts/hook.ps1'))) <eventName>\"", "timeout": 120 }
```

Each dispatcher's job: collect creds, POST stdin to `/api/v1/hooks/cursor`, relay the response bytes verbatim. **It does not interpret the response.** The server returns whatever Cursor's hook output schema for that event requires.

### Exactly-one-runs (cross-platform arbitration)

Cursor runs **all** entries for an event and fails open if a command's binary is missing. The two entries are arranged so exactly one does real work per machine, gated by credential location and a Git Bash stand-down:

| Environment | bash entry | PowerShell entry |
|---|---|---|
| macOS / Linux / WSL (Cursor in WSL) | runs | `powershell` absent → fail-open `{}` |
| native Windows + Git Bash | `uname`=MINGW → stands down `{}` | runs |
| native Windows, no bash | `bash` absent → fail-open | runs |
| native Windows + WSL bash, installed on Windows | WSL `~` has no creds → `{}` | runs |

The Git Bash stand-down (`uname` = MINGW/MSYS/CYGWIN → emit `{}`, exit) exists because Git Bash's `~` maps to `%USERPROFILE%` — the same creds `hook.ps1` reads — so without it both would POST. WSL bash uses a different home, so it self-resolves via credential gating.

Invariants when editing hooks (apply to **both** dispatchers — keep them in lockstep):

- **Fail-open everywhere.** Missing API key, missing HTTP client, network failure, non-200, empty body, malformed JSON → emit `{}` and exit 0. The user must never be blocked by Rogue infra.
- **`x-rogue-event` is the verbatim Cursor event name (lowerCamelCase)** — no translation. The server's `/api/v1/hooks/cursor` route uses it to look up the correct response schema.
- **`x-rogue-source: cursor`** distinguishes from the claude integration on the server side.
- **No client-side policy.** Block/allow/ask is decided by the server. Do not add `ROGUE_BLOCK_MODE` or any other policy flag — if you find yourself wanting one, fix the server instead.
- **No `-File` / no `-ExecutionPolicy Bypass`.** The PowerShell entry loads logic via `[scriptblock]::Create(Get-Content)` precisely so ExecutionPolicy never applies. Keep the one-liner free of `$` and backticks so it survives Cursor's hook bootstrap (PowerShell *or* Git Bash) intact.
- Timeouts: HTTP client uses 10s; hook `timeout: 120`.
- Per-event response schemas (which fields each event accepts) live in Cursor's docs and are reproduced in the plan's "Server response contract" section. **Keep that table in sync with Cursor docs** when bumping support for new events.

## Editing the dispatcher

Both dispatchers are intentionally simple and mirror each other stage-for-stage:

- **creds** — search `${CURSOR_PLUGIN_ROOT}/env` (compiled plugin) → MDM path → per-user file; later wins, process env wins over all. MDM path is `/etc/rogue/env` (bash) / `C:\ProgramData\rogue\env` (PowerShell); per-user is `~/.rogue-env` / `%USERPROFILE%\.rogue-env`. `hook.sh` `source`s the files (they're bash-quoted, like `auto-update.sh` already does); `hook.ps1` regex-parses them (same regex as `install.ps1`).
- **actor** — email/name. Order: explicit `ROGUE_ACTOR_*` → `git config` → `whoami`/`USERNAME`+`hostname`/`COMPUTERNAME` (last-resort, used when git isn't installed).
- **POST** — `curl -fsS --max-time 10` (bash) / `Invoke-WebRequest -TimeoutSec 10` (PowerShell). `-f` / `-ErrorAction Stop` give fail-open on non-200.
- **emit** — relay the response verbatim if it validates as JSON, else `{}`. bash uses a first-char `{`/`[` heuristic (no `jq` dependency); PowerShell uses `ConvertFrom-Json`.

Adding a new Cursor event = **two** lines in `hooks.json` (one bash, one PowerShell). No dispatcher change needed (the event name is forwarded as `x-rogue-event`). All schema/policy logic lives on the server.

If you change one dispatcher's behavior, change the other to match, and re-run `tests/test_hook_sh.sh` (bash). `hook.ps1` has no local test harness — verify it on a Windows box.

## Releasing

1. Bump `version` in **both** `plugins/rogue/.cursor-plugin/plugin.json` and `.cursor-plugin/marketplace.json` — keep them in sync.
2. Commit, tag `vX.Y.Z`, push the tag. `release.yml` builds the tarball and creates the GitHub Release.
3. `auto-update.sh` on user machines picks up the new release at the next sessionStart (rate-limited 24h).

## Things that look weird but are intentional

- `hooks.json` commands use **relative** paths (`./scripts/hook.sh`, `'scripts/hook.ps1'`) — Cursor runs plugin hooks with cwd = plugin root, the same assumption the previous Python entries relied on.
- The PowerShell one-liner deliberately contains **no `$` and no backticks** and loads logic via `[scriptblock]::Create((Get-Content ...))` rather than `-File`. This survives Cursor's hook bootstrap regardless of shell and sidesteps ExecutionPolicy without needing `-ExecutionPolicy Bypass` (which the user may lack rights to set).
- `hook.sh` `source`s the env files (they are valid bash); `hook.ps1` regex-parses the same `export KEY=value` format. The format matches the claude plugin so a single env file works for both products.
- `auto-update.sh` runs only on the bash path (sessionStart) and still uses `python3` internally — Windows-native auto-update is not yet implemented; Windows users re-run `install.ps1` to upgrade.
- `auto-update.sh` uses a separate cache file (`.auto-update-check-cursor`) so the cursor and claude updaters don't fight each other.

## `rgx!` prefix is server-side

The dispatcher doesn't parse it — the API does. Don't add client-side handling.
