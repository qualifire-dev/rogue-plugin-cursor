# Rogue Security hook dispatcher for Cursor — PowerShell implementation.
#
# Cross-platform sibling of hook.sh. hooks.json loads this WITHOUT -File so the
# PowerShell ExecutionPolicy never applies (running a scriptblock built from a
# string is not subject to policy, unlike invoking a .ps1 on disk — this also
# survives a GPO-enforced policy, which -ExecutionPolicy Bypass does not):
#
#   powershell -NoProfile -NonInteractive -Command \
#     "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$env:CURSOR_PLUGIN_ROOT/scripts/hook.ps1'))) <event>"
#
# Cursor substitutes $env:CURSOR_PLUGIN_ROOT (the plugin root) into the command
# before PowerShell parses it; the single quotes make the injected absolute path
# a string literal. Cursor runs this entry from a cwd that is NOT the plugin
# root, so a relative path would not resolve here.
#
# This script OWNS native Windows. It stands down on non-Windows (pwsh on
# macOS/Linux) because hook.sh runs there.
#
# Fail-open everywhere: missing API key, network error, non-200, empty body, or
# non-JSON response all yield `{}` on stdout, exit 0.
#
# Set ROGUE_DEBUG=1 (process/user env var) to emit diagnostics to stderr;
# Cursor shows stderr in its hook log without treating it as the response.
#
# Credential resolution (later file wins; process env wins over all), the
# Windows analogue of hook.sh's search:
#   1. ${CURSOR_PLUGIN_ROOT}\env        (baked into a compiled customer plugin)
#   2. C:\ProgramData\rogue\env         (MDM-provisioned; mirrors /etc/rogue/env)
#   3. %USERPROFILE%\.rogue-env         (user / installer-written)

param([string]$EventName = '')

$ErrorActionPreference = 'SilentlyContinue'
# Invoke-WebRequest renders a progress bar that, when stdout/stderr is
# redirected (always true under a Cursor hook), can slow the call 10-50x or
# effectively hang it. Silencing progress is the standard fix.
$ProgressPreference = 'SilentlyContinue'

function Write-Raw {
    # Write raw UTF-8 bytes to stdout, bypassing [Console]::Out whose encoding
    # may be a legacy codepage (e.g. CP437) that mangles non-ASCII output back
    # into mojibake. Cursor reads the hook's stdout as UTF-8.
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
# TEMP DEBUG: always print (revert by restoring the `if ($env:ROGUE_DEBUG)` gate).
function Dbg { param([string]$Msg) [Console]::Error.WriteLine("[rogue] $Msg"); [Console]::Error.Flush() }

function Emit-Json {
    param([string]$Data)
    if (-not $Data) { Write-Raw '{}'; return }
    try { $null = $Data | ConvertFrom-Json -ErrorAction Stop; Write-Raw $Data }
    catch { Dbg "response is not JSON -> {}"; Write-Raw '{}' }
}

# Windows PowerShell 5.1 may negotiate only TLS 1.0/1.1 by default, which
# modern HTTPS endpoints reject ("Could not create SSL/TLS secure channel").
# Add TLS 1.2 without clobbering any protocols already enabled.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

# ── stand down on non-Windows (pwsh on macOS/Linux) ────────────────────────
# $IsWindows exists only in PowerShell 6+. In 5.1 (Windows-only) it is $null,
# so guard on the version to avoid a false stand-down there.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { Write-Raw '{}'; exit 0 }

if (-not $EventName) { Dbg "no event name -> {}"; Write-Raw '{}'; exit 0 }
Dbg "event=$EventName rev=bom-byte-strip"

# ── credential resolution (later file wins; process env wins over all) ─────
$creds = @{}
$pluginRoot = $env:CURSOR_PLUGIN_ROOT
if (-not $pluginRoot) { try { $pluginRoot = (Get-Location).Path } catch { $pluginRoot = '.' } }
Dbg "pluginRoot=$pluginRoot"

$credFiles = @(
    (Join-Path $pluginRoot 'env'),
    'C:\ProgramData\rogue\env',
    (Join-Path $env:USERPROFILE '.rogue-env')
)
foreach ($f in $credFiles) {
    if (-not $f) { continue }
    if (-not (Test-Path -LiteralPath $f)) { Dbg "cred file absent: $f"; continue }
    Dbg "cred file found: $f"
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
    Dbg "no API key after cred resolution -> fail-open"
    if ($EventName -eq 'sessionStart') {
        Write-Raw '{"additional_context": "Rogue Security plugin is installed but not configured. Run /rogue:setup to connect your API key."}'
    } else {
        Write-Raw '{}'
    }
    exit 0
}
$keyTail = if ($apiKey.Length -ge 4) { $apiKey.Substring($apiKey.Length - 4) } else { '****' }
Dbg "apiKey present (tail $keyTail)"

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
# Cursor sends a UTF-8 payload, but the console often reads stdin under a legacy
# OEM codepage (observed in the field: IBM437), which mojibakes it — e.g. the
# leading UTF-8 BOM (bytes EF BB BF) decodes to "∩╗┐", not a single U+FEFF.
# Chasing per-codepage code points is futile, so instead round-trip the string
# back through the ACTUAL input encoding to recover the original bytes, then
# decode them as real UTF-8. CP437↔Unicode is a bijection, so this also fully
# recovers any non-ASCII prompt text. No-op when the console is already UTF-8.
Dbg "InputEncoding=$([Console]::InputEncoding.WebName) CP=$([Console]::InputEncoding.CodePage)"
try {
    $raw = [Console]::InputEncoding.GetBytes($payload)
    $payload = [System.Text.Encoding]::UTF8.GetString($raw)
} catch { Dbg "utf8 re-decode failed: $($_.Exception.Message)" }

# After re-decoding, a UTF-8 BOM is a single U+FEFF char. Strip it: a
# BOM-prefixed body is invalid JSON and the API rejects it with HTTP 400.
$payload = $payload.TrimStart([char]0xFEFF)

# TEMP DEBUG: confirm the payload now starts with clean JSON ('{' = 007B).
$head = ($payload.ToCharArray() | Select-Object -First 8 | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' '
Dbg "post-fix head codepoints: $head"
Dbg "payload length $($payload.Length): $($payload.Substring(0, [Math]::Min(500, $payload.Length)))"

# ── POST (fail-open) ───────────────────────────────────────────────────────
$headers = @{
    'x-rogue-api-key'     = $apiKey
    'x-rogue-event'       = $EventName
    'x-rogue-actor-email' = $actorEmail
    'x-rogue-actor-name'  = $actorName
    'x-rogue-source'      = 'cursor'
}

$url = "$baseUrl/api/v1/hooks/cursor"
Dbg "POST $url actor=$actorEmail"
# Send an explicit UTF-8 byte array: Windows PowerShell 5.1's Invoke-WebRequest
# re-encodes a string body (commonly to Latin-1), which corrupts non-ASCII
# prompt content and can reintroduce a BOM. GetBytes() never emits a BOM.
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
$resp = ''
try {
    $r = Invoke-WebRequest -Uri $url -Method Post `
        -Headers $headers -ContentType 'application/json' -Body $bodyBytes `
        -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Dbg "HTTP $($r.StatusCode), body length $($r.Content.Length)"
    if ($r.StatusCode -eq 200) {
        # Decode the body explicitly as UTF-8. Invoke-WebRequest's .Content
        # mis-decodes as ISO-8859-1 when the server omits a charset, turning
        # UTF-8 punctuation (— ') into mojibake (â€" â€™). RawContentStream
        # holds the original bytes.
        try { $resp = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
        catch { $resp = [string]$r.Content }
    }
} catch {
    Dbg "POST failed: $($_.Exception.Message)"
    # TEMP DEBUG: a 4xx/5xx almost always explains itself in the response body.
    # PS7 stashes it in ErrorDetails.Message; PS5.1 needs the response stream.
    $errBody = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        $errBody = $_.ErrorDetails.Message
    } elseif ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $sr = New-Object System.IO.StreamReader($stream)
            $errBody = $sr.ReadToEnd(); $sr.Close()
        } catch {}
    }
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        Dbg "error status: $([int]$_.Exception.Response.StatusCode)"
    }
    if ($errBody) { Dbg "error response body: $errBody" }
    $resp = ''
}

Emit-Json $resp
exit 0
