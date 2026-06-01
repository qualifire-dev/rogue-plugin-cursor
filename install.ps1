#Requires -Version 5.1
<#
.SYNOPSIS
    Rogue Security — one-line installer for Cursor (Windows).
.DESCRIPTION
    iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.ps1 | iex

    With credentials via environment variables:
    $env:ROGUE_API_KEY='rsk_xxx'; $env:ROGUE_ACTOR_EMAIL='you@co.com'; $env:ROGUE_ACTOR_NAME='Your Name'; iwr -useb https://raw.githubusercontent.com/qualifire-dev/rogue-plugin-cursor/main/install.ps1 | iex

    Direct invocation with flags:
    .\install.ps1 -ApiKey rsk_xxx -Email you@co.com -Name 'Your Name'
    .\install.ps1 -LocalPath C:\path\to\repo
    .\install.ps1 -NonInteractive
.PARAMETER ApiKey
    Rogue API key (rsk_...).
.PARAMETER Email
    Actor email address.
.PARAMETER Name
    Actor display name.
.PARAMETER ApiUrl
    Override the API base URL (default: https://api.rogue.security).
.PARAMETER LocalPath
    Use a local source directory instead of downloading from GitHub.
.PARAMETER NonInteractive
    Fail rather than prompt for missing values.
#>
[CmdletBinding()]
param(
    [string]$ApiKey,
    [string]$Email,
    [string]$Name,
    [string]$ApiUrl,
    [string]$LocalPath,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$ROGUE_API_URL_DEFAULT = 'https://api.rogue.security'
$PluginRepo   = if ($env:ROGUE_PLUGIN_REPO)    { $env:ROGUE_PLUGIN_REPO }    else { 'qualifire-dev/rogue-plugin-cursor' }
$VersionPin   = $env:ROGUE_PLUGIN_VERSION
$PluginName   = 'rogue'

$CursorDir        = Join-Path $env:USERPROFILE '.cursor'
$PluginInstallDir = Join-Path $CursorDir "plugins\local\$PluginName"
$EnvFile          = if ($env:ROGUE_ENV_FILE) { $env:ROGUE_ENV_FILE } else { Join-Path $env:USERPROFILE '.rogue-env' }

# Merge env vars -> params (params win if explicitly set).
if (-not $ApiKey)    { $ApiKey    = $env:ROGUE_API_KEY }
if (-not $Email)     { $Email     = $env:ROGUE_ACTOR_EMAIL }
if (-not $Name)      { $Name      = $env:ROGUE_ACTOR_NAME }
if (-not $ApiUrl)    { $ApiUrl    = if ($env:ROGUE_API_URL) { $env:ROGUE_API_URL } else { $ROGUE_API_URL_DEFAULT } }
if (-not $LocalPath) { $LocalPath = $env:ROGUE_LOCAL_PATH }
if ($env:ROGUE_NON_INTERACTIVE) { $NonInteractive = $true }

function Log  { param([string]$Msg) Write-Host "-> $Msg" }
function Warn { param([string]$Msg) Write-Warning $Msg }
function Err  { param([string]$Msg) Write-Error   $Msg; exit 1 }

# Locate python3
$Python = $null
foreach ($candidate in @('python3', 'python', 'py')) {
    try {
        $ver = & $candidate --version 2>&1
        if ($ver -match 'Python 3') { $Python = $candidate; break }
    } catch { }
}
if (-not $Python) {
    Err 'python3 is required. Install from https://python.org/downloads or run: winget install Python.Python.3'
}
Log "Python: $Python"

# Load creds from existing env files (same priority order as rogue-hook.py: later wins).
# MDM path on Windows mirrors /etc/rogue/env -> C:\ProgramData\rogue\env.
function Load-ExistingCreds {
    $paths = @('C:\ProgramData\rogue\env', (Join-Path $env:USERPROFILE '.rogue-env'))
    foreach ($f in $paths) {
        if (-not (Test-Path $f)) { continue }
        foreach ($line in Get-Content $f -ErrorAction SilentlyContinue) {
            if ($line -match '^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.+)$') {
                $k = $Matches[1]
                # Strip surrounding single or double quotes (mirrors shlex.split).
                $v = $Matches[2].Trim() -replace "^'(.*)'$", '$1' -replace '^"(.*)"$', '$1'
                switch ($k) {
                    'ROGUE_API_KEY'     { if (-not $script:ApiKey) { $script:ApiKey = $v } }
                    'ROGUE_ACTOR_EMAIL' { if (-not $script:Email)  { $script:Email  = $v } }
                    'ROGUE_ACTOR_NAME'  { if (-not $script:Name)   { $script:Name   = $v } }
                    'ROGUE_BASE_URL'    {
                        if ($script:ApiUrl -eq $ROGUE_API_URL_DEFAULT) { $script:ApiUrl = $v }
                    }
                }
            }
        }
        Log "Read credentials from $f"
    }
}

Load-ExistingCreds

if (-not $ApiKey) {
    if ($NonInteractive) { Err 'ROGUE_API_KEY not set and -NonInteractive specified' }
    $secure = Read-Host 'Rogue API key (rsk_...)' -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    if (-not $ApiKey) { Err 'API key cannot be empty' }
}

# Actor identity: git config -> env fallbacks.
if (-not $Email) {
    try { $Email = (& git config --global user.email 2>$null).Trim() } catch { }
}
if (-not $Name) {
    try { $Name = (& git config --global user.name 2>$null).Trim() } catch { }
}
if (-not $Email) { $Email = "$env:USERNAME@$env:COMPUTERNAME" }
if (-not $Name)  { $Name  = $env:USERNAME }
Log "Actor: $Name <$Email>"

# Validate API key.
Log 'Validating API key...'
try {
    $resp = Invoke-WebRequest -Uri "$ApiUrl/api/v1/hooks/ping" `
        -Headers @{ 'x-rogue-api-key' = $ApiKey } `
        -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    if ($resp.StatusCode -ne 200) {
        Err "API key validation failed (HTTP $($resp.StatusCode))"
    }
} catch {
    Err "API key validation failed: $_"
}
Log 'API key valid.'

# Write env file.
# Format is `export KEY=value` — matches the regex in rogue-hook.py.
# Values containing whitespace or single-quotes are shell-quoted.
function Format-EnvVal {
    param([string]$Val)
    if ($Val -match "[\s']") {
        return "'" + $Val.Replace("'", "'\\''") + "'"
    }
    return $Val
}

$envLines = @(
    '# Managed by the rogue Cursor plugin installer.',
    "export ROGUE_API_KEY=$(Format-EnvVal $ApiKey)",
    "export ROGUE_ACTOR_EMAIL=$(Format-EnvVal $Email)",
    "export ROGUE_ACTOR_NAME=$(Format-EnvVal $Name)"
)
if ($ApiUrl -ne $ROGUE_API_URL_DEFAULT) {
    $envLines += "export ROGUE_BASE_URL=$(Format-EnvVal $ApiUrl)"
}

$envDir = Split-Path $EnvFile
if ($envDir -and -not (Test-Path $envDir)) {
    New-Item -ItemType Directory -Path $envDir -Force | Out-Null
}
Set-Content -Path $EnvFile -Value $envLines -Encoding UTF8

# Restrict file to current user only (best-effort).
try {
    $acl = Get-Acl $EnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        'FullControl', 'Allow')
    $acl.SetAccessRule($rule)
    Set-Acl $EnvFile $acl
} catch {
    Warn "Could not restrict permissions on $EnvFile (non-fatal)"
}
Log "Wrote $EnvFile"

# Download or copy the plugin.
$TmpDir = Join-Path $env:TEMP "rogue-install-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $TmpDir | Out-Null

try {
    if ($LocalPath) {
        $manifest = Join-Path $LocalPath "plugins\$PluginName\.cursor-plugin\plugin.json"
        if (-not (Test-Path $manifest)) { Err '-LocalPath is missing the plugin manifest' }
        $SrcDir = $LocalPath
    } else {
        $asset = "rogue-plugin-cursor.tar.gz"
        $url = if ($VersionPin) {
            "https://github.com/$PluginRepo/releases/download/$VersionPin/$asset"
        } else {
            "https://github.com/$PluginRepo/releases/latest/download/$asset"
        }
        Log "Downloading: $url"
        $archive = Join-Path $TmpDir 'p.tar.gz'
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -TimeoutSec 60
        $extractDir = Join-Path $TmpDir 'extract'
        New-Item -ItemType Directory -Path $extractDir | Out-Null
        # tar ships with Windows 10 1803+ and Windows Server 2019+.
        & tar -xzf $archive -C $extractDir
        if ($LASTEXITCODE -ne 0) { Err 'tar extraction failed' }
        $SrcDir = $extractDir
    }

    $PluginSrc = Join-Path $SrcDir "plugins\$PluginName"
    if (-not (Test-Path (Join-Path $PluginSrc '.cursor-plugin\plugin.json'))) {
        Err 'Missing plugin manifest in source'
    }

    # Install.
    $parentDir = Split-Path $PluginInstallDir
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    if (Test-Path $PluginInstallDir) {
        Remove-Item $PluginInstallDir -Recurse -Force
    }
    Copy-Item $PluginSrc $PluginInstallDir -Recurse
    Log "Installed -> $PluginInstallDir"
} finally {
    Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host @"

v Rogue Security (Cursor) installed.

  Plugin:       $PluginInstallDir
  Credentials:  $EnvFile

Next steps:
  1. Fully quit Cursor and reopen.
  2. Run /rogue:status inside Cursor to verify.
  3. AIDR dashboard: https://app.rogue.security/aidr

Re-running this installer upgrades the plugin and is safe.
"@
