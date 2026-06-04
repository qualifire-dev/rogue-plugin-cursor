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
- `plugins/rogue/hooks/hooks.json` — all 18 lifecycle hooks. Every event registers **two** entries: an `sh` one (`hook.sh`) and a PowerShell one (`hook.ps1`). Exactly one does real work per machine (see below).
- `plugins/rogue/scripts/hook.sh` — the POSIX-sh + `curl` dispatcher. Invoked via `sh` (NOT `bash` — see below), so it is kept POSIX-clean and tested under `dash` (`tests/test_hook_sh.sh`, runs under both `sh` and `TEST_SH=dash`). Runs on macOS / Linux / WSL. **Stands down** (emits `{}`, exits) under Git Bash (`uname` = MINGW/MSYS/CYGWIN) so the PowerShell entry owns native Windows.
- `plugins/rogue/scripts/hook.ps1` — the PowerShell + `Invoke-WebRequest` dispatcher. Owns native Windows; stands down on non-Windows (`pwsh`). No external binaries (`python`/`node`/`curl`) assumed on either path — the sh path uses `curl`, PowerShell uses `Invoke-WebRequest`.
- `plugins/rogue/scripts/setup.sh` — writes `~/.rogue-env` (mode 600). `plugins/rogue/scripts/setup.ps1` is the Windows analogue (writes `%USERPROFILE%\.rogue-env`, ACL-restricted); both emit the same shell-quoted format. `commands/setup.md` (`/rogue:setup`) drives whichever matches the user's OS.
- `plugins/rogue/commands/{setup,status}.md` — slash commands.
- `scripts/compile-customer-plugin.sh` — builds a flat tarball with `ROGUE_API_KEY` baked into `<plugin_root>/env`. Used to ship an MDM-free install option. Actor identity is NOT baked in — it's resolved per-user at hook-fire time via `_resolve_actor()`.

## The hook pattern

Every event in `hooks.json` registers two entries — `sh` and PowerShell — pointing at the matching dispatcher:

```json
{ "command": "sh ./scripts/hook.sh <eventName>", "timeout": 120 },
{ "command": "powershell -NoProfile -NonInteractive -Command \"& ([scriptblock]::Create((Get-Content -Raw -LiteralPath (Join-Path $env:CURSOR_PLUGIN_ROOT 'scripts/hook.ps1')))) <eventName>\"", "timeout": 120 }
```

Each dispatcher's job: collect creds, POST stdin to `/api/v1/hooks/cursor`, relay the response bytes verbatim. **It does not interpret the response.** The server returns whatever Cursor's hook output schema for that event requires.

Two path subtleties, both learned from real Windows logs:
- **`sh`, not `bash`.** On Windows, `bash` resolves to the WSL launcher stub (`System32\bash.exe`), which on a machine with no WSL distro prints a UTF-16 "no installed distributions" notice — non-JSON output that breaks Cursor's parse. There is no `sh.exe` stub, so `sh` simply isn't found on a bash-less Windows box → clean fail-open.
- **The PowerShell path is resolved at runtime from an env var.** Cursor runs the `sh` entry with cwd = plugin root (so its `./scripts/...` resolves), but runs the PowerShell entry from a *different* cwd, so a relative path fails there. Cursor exposes the plugin root as the **process environment variable** `CURSOR_PLUGIN_ROOT` (the same var `hook.sh` reads at `${CURSOR_PLUGIN_ROOT}` and `hook.ps1` reads at `$env:CURSOR_PLUGIN_ROOT`), so the bootstrap resolves it at runtime with `Join-Path $env:CURSOR_PLUGIN_ROOT 'scripts/hook.ps1'`. It must **not** be single-quoted — single quotes are literal in PowerShell and would never expand. `Join-Path` also keeps a path with spaces intact.

### Exactly-one-runs (cross-platform arbitration)

Cursor runs **all** entries for an event and fails open if a command's binary is missing. The two entries are arranged so exactly one does real work per machine, gated by credential location and a Git Bash stand-down:

| Environment | `sh` entry | PowerShell entry |
|---|---|---|
| macOS / Linux / WSL (Cursor in WSL) | runs | `powershell` absent → fail-open `{}` |
| native Windows + Git Bash | `sh` = Git Bash sh, `uname`=MINGW → stands down `{}` | runs |
| native Windows, no Git Bash | `sh` not found → fail-open (no output) | runs |
| native Windows + WSL stub bash | irrelevant — entry uses `sh`, not `bash` | runs |

The Git Bash stand-down (`uname` = MINGW/MSYS/CYGWIN → emit `{}`, exit) exists because Git Bash's `~` maps to `%USERPROFILE%` — the same creds `hook.ps1` reads — so without it both would POST. WSL bash uses a different home, so it self-resolves via credential gating.

Invariants when editing hooks (apply to **both** dispatchers — keep them in lockstep):

- **Fail-open everywhere.** Missing API key, missing HTTP client, network failure, non-200, empty body, malformed JSON → emit `{}` and exit 0. The user must never be blocked by Rogue infra.
- **`x-rogue-event` is the verbatim Cursor event name (lowerCamelCase)** — no translation. The server's `/api/v1/hooks/cursor` route uses it to look up the correct response schema.
- **`x-rogue-source: cursor`** distinguishes from the claude integration on the server side.
- **No client-side policy.** Block/allow/ask is decided by the server. Do not add `ROGUE_BLOCK_MODE` or any other policy flag — if you find yourself wanting one, fix the server instead.
- **No `-File` / no `-ExecutionPolicy Bypass`.** The PowerShell entry loads logic via `[scriptblock]::Create(Get-Content)` precisely so ExecutionPolicy never applies — this also survives a GPO-enforced policy, which `-ExecutionPolicy Bypass` does not. The only variable in the one-liner is `$env:CURSOR_PLUGIN_ROOT` (a process env var resolved by PowerShell at runtime via `Join-Path`, **not** single-quoted); avoid adding other `$`/backtick constructs that an outer bootstrap could mangle.
- Timeouts: HTTP client uses 10s; hook `timeout: 120`.
- Per-event response schemas (which fields each event accepts) live in Cursor's docs and are reproduced in the plan's "Server response contract" section. **Keep that table in sync with Cursor docs** when bumping support for new events.

## Editing the dispatcher

Both dispatchers are intentionally simple and mirror each other stage-for-stage:

- **creds** — search `${CURSOR_PLUGIN_ROOT}/env` (compiled plugin) → MDM path → per-user file; later wins, process env wins over all. MDM path is `/etc/rogue/env` (bash) / `C:\ProgramData\rogue\env` (PowerShell); per-user is `~/.rogue-env` / `%USERPROFILE%\.rogue-env`. `hook.sh` `source`s the files (they're bash-quoted, valid POSIX sh); `hook.ps1` regex-matches `export KEY=value` lines and then decodes the shell quoting (single/double quotes + backslash escapes, via `ConvertFrom-ShellQuoted`) so values like `O'Brien` round-trip identically across both dispatchers. The installers must emit POSIX-correct quoting — `install.sh` uses `printf %q`; `install.ps1`'s `Format-EnvVal` escapes `'` as `'\''` (not `'\\''`, which is an unterminated quote).
- **actor** — email/name. Order: explicit `ROGUE_ACTOR_*` → `git config` → `whoami`/`USERNAME`+`hostname`/`COMPUTERNAME` (last-resort, used when git isn't installed).
- **POST** — `curl -fsS --max-time 10` (bash) / `Invoke-WebRequest -TimeoutSec 10` (PowerShell). `-f` / `-ErrorAction Stop` give fail-open on non-200.
- **emit** — relay the server response to Cursor verbatim (empty body → `{}`). Both dispatchers deliberately do **not** validate the JSON: a 200 from the Rogue API is always valid JSON, and if a malformed body ever slips through, Cursor ignores it AND logs the raw output — exactly what's wanted for debugging. Validating client-side would only let us swallow that signal (turning it into `{}`) for no gain, so neither `jq` (sh) nor `ConvertFrom-Json` (PowerShell) is used to gate the response.

Adding a new Cursor event = **two** lines in `hooks.json` (one `sh`, one PowerShell). No dispatcher change needed (the event name is forwarded as `x-rogue-event`). All schema/policy logic lives on the server.

If you change one dispatcher's behavior, change the other to match, and re-run `tests/test_hook_sh.sh` (also under `TEST_SH=dash` to catch bashisms). `hook.ps1` has no local test harness — verify it on a Windows box.

## Releasing

1. Bump `version` in **both** `plugins/rogue/.cursor-plugin/plugin.json` and `.cursor-plugin/marketplace.json` — keep them in sync.
2. Commit, tag `vX.Y.Z`, push the tag. `release.yml` builds the tarball and creates the GitHub Release.
3. Team-marketplace installs pick up the new version once Cursor re-reviews and publishes it. One-line (`install.sh`) users re-run the installer to upgrade — there is no background auto-updater.

## Things that look weird but are intentional

- The `sh` entry uses a **relative** path (`./scripts/hook.sh`) — Cursor runs it with cwd = plugin root, like the previous Python entries. The PowerShell entry builds an **absolute** path at runtime (`Join-Path $env:CURSOR_PLUGIN_ROOT 'scripts/hook.ps1'`) because Cursor runs it from a different cwd where the relative path fails. Asymmetric but correct per platform.
- The dispatcher is invoked via `sh`, not `bash`, specifically to dodge the WSL `bash.exe` stub on Windows (see "The hook pattern"). Keep `hook.sh` POSIX-clean.
- The PowerShell one-liner loads logic via `[scriptblock]::Create((Get-Content ...))` rather than `-File`. This sidesteps ExecutionPolicy (including GPO-enforced policy) without `-ExecutionPolicy Bypass`.
- `hook.sh` `source`s the env files (they are valid POSIX sh); `hook.ps1` regex-parses the same `export KEY=value` format. The format matches the claude plugin so a single env file works for both products.

## `rgx!` prefix is server-side

The dispatcher doesn't parse it — the API does. Don't add client-side handling.
