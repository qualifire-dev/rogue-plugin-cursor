# Rogue Security hook dispatcher for Cursor — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json loads this WITHOUT -File so the
# PowerShell ExecutionPolicy never applies (running a scriptblock built from a
# string is not subject to policy, unlike invoking a .ps1 on disk):
#
#   powershell -NoProfile -NonInteractive -Command \
#     "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath 'scripts/hook.ps1'))) <event>"
#
# The one-liner has no `$` and no backticks, so it survives Cursor's hook
# bootstrap intact whether that bootstrap is PowerShell or (Git) Bash.
#
# This script OWNS native Windows. It stands down on non-Windows (pwsh on
# macOS/Linux) because hook.sh runs there. It does NOT need the Git Bash guard
# that hook.sh has — `powershell` simply doesn't resolve off Windows.
#
# Fail-open everywhere: missing API key, network error, non-200, empty body, or
# non-JSON response all yield `{}` on stdout, exit 0.
#
# Credential resolution (later file wins; process env wins over all), the
# Windows analogue of hook.sh's search:
#   1. ${CURSOR_PLUGIN_ROOT}\env        (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env         (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env         (user / installer-written)

param([string]$EventName = '')

$ErrorActionPreference = 'SilentlyContinue'

function Write-Raw { param([string]$Text) [Console]::Out.Write($Text) }

function Emit-Json {
    param([string]$Data)
    if (-not $Data) { Write-Raw '{}'; return }
    try { $null = $Data | ConvertFrom-Json -ErrorAction Stop; Write-Raw $Data }
    catch { Write-Raw '{}' }
}

# ── stand down on non-Windows (pwsh on macOS/Linux) ────────────────────────
# $IsWindows exists only in PowerShell 6+. In 5.1 (Windows-only) it is $null,
# so guard on the version to avoid a false stand-down there.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Write-Raw '{}'; exit 0 }

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
$pluginRoot = $env:CURSOR_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }

$credFiles = @(
    (Join-Path $pluginRoot 'env'),
    'C:\ProgramData\rogue\env',
    (Join-Path $env:USERPROFILE '.rogue-env')
)
foreach ($f in $credFiles) {
    if (-not $f) { continue }
    if (-not (Test-Path -LiteralPath $f)) { continue }
    foreach ($line in (Get-Content -LiteralPath $f)) {
        if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
            $k = $Matches[1]
            # Strip surrounding single/double quotes (mirrors shlex.split).
            $v = $Matches[2].Trim() -replace "^'(.*)'$", '$1' -replace '^"(.*)"$', '$1'
            $creds[$k] = $v
        }
    }
}
foreach ($k in 'ROGUE_API_KEY','ROGUE_ACTOR_EMAIL','ROGUE_ACTOR_NAME','ROGUE_BASE_URL') {
    $val = [Environment]::GetEnvironmentVariable($k)
    if ($val) { $creds[$k] = $val }
}

$apiKey = $creds['ROGUE_API_KEY']
if (-not $apiKey) {
    if ($EventName -eq 'sessionStart') {
        Write-Raw '{"additional_context": "Rogue Security plugin is installed but not configured. Run /rogue:setup to connect your API key."}'
    } else {
        Write-Raw '{}'
    }
    exit 0
}

$baseUrl = $creds['ROGUE_BASE_URL']
if (-not $baseUrl) { $baseUrl = 'https://api.rogue.security' }
$baseUrl = $baseUrl.TrimEnd('/')

# ── actor resolution: explicit creds → git config → username/hostname ──────
$actorName = $creds['ROGUE_ACTOR_NAME']
if (-not $actorName) { try { $actorName = (& git config --global user.name 2>$null | Out-String).Trim() } catch {} }
if (-not $actorName) { $actorName = $env:USERNAME }

$actorEmail = $creds['ROGUE_ACTOR_EMAIL']
if (-not $actorEmail) { try { $actorEmail = (& git config --global user.email 2>$null | Out-String).Trim() } catch {} }
if (-not $actorEmail) {
    if ($env:USERNAME -and $env:COMPUTERNAME) { $actorEmail = "$($env:USERNAME)@$($env:COMPUTERNAME)" }
    elseif ($env:USERNAME) { $actorEmail = $env:USERNAME }
    else { $actorEmail = $env:COMPUTERNAME }
}

# ── payload from stdin ─────────────────────────────────────────────────────
$payload = [Console]::In.ReadToEnd()
if (-not $payload) { $payload = '{}' }

# ── POST (fail-open) ───────────────────────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-source'      = 'cursor'
}

$resp = ''
try {
    $r = Invoke-WebRequest -Uri "$baseUrl/api/v1/hooks/cursor" -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $payload `
        -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $resp = [string]$r.Content }
} catch { $resp = '' }

Emit-Json $resp
exit 0
