# claude-code-profiles installer for Windows/PowerShell
# Usage:
#   irm https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/install.ps1 | iex
#
# Environment variables:
#   INSTALL_DIR  - Override the install directory (default: $env:LOCALAPPDATA\claude-profile)

$ErrorActionPreference = 'Stop'

$RepoBase = 'https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main'
$Scripts = @('claude-profile-init.ps1', 'claude-profile.cmd')

function Write-Step($msg) { Write-Host "`n=> $msg" -ForegroundColor Cyan }
function Write-Info($msg) { Write-Host "  $msg" }
function Write-Warn($msg) { Write-Host "  [warn] $msg" -ForegroundColor Yellow }
function Write-Fail($msg) {
    Write-Host "  [error] $msg" -ForegroundColor Red
    throw $msg
}

# --- Determine install directory ---

function Get-InstallDir {
    if ($env:INSTALL_DIR) {
        return $env:INSTALL_DIR
    }
    $default = Join-Path $env:LOCALAPPDATA 'claude-profile'
    return $default
}

# --- Check if directory is on PATH (user scope) ---

function Test-OnPath($dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { return $false }
    $paths = $userPath -split ';' | Where-Object { $_ -ne '' }
    foreach ($p in $paths) {
        if ($p.TrimEnd('\') -eq $dir.TrimEnd('\')) {
            return $true
        }
    }
    return $false
}

# --- Add directory to user PATH ---

function Add-ToUserPath($dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) {
        $newPath = $dir
    } else {
        $newPath = "$userPath;$dir"
    }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    # Also update current session so it's immediately usable
    if ($env:Path -notlike "*$dir*") {
        $env:Path = "$dir;$env:Path"
    }
}

# --- Main ---

Write-Host 'claude-code-profiles installer' -ForegroundColor White
Write-Host '================================' -ForegroundColor White

Write-Step 'Determining install directory...'
$installDir = Get-InstallDir

if (Test-Path $installDir) {
    Write-Info "Install directory: $installDir (exists, updating in place)"
} else {
    Write-Info "Install directory: $installDir (creating)"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

Write-Step 'Downloading scripts...'
foreach ($script in $Scripts) {
    $url = "$RepoBase/$script"
    $dest = Join-Path $installDir $script
    Write-Info "  $script -> $dest"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 30
    } catch {
        Write-Fail "Failed to download $script from $url : $_"
    }
}
Write-Info 'Downloaded successfully.'

Write-Step 'Downloading VERSION...'
try {
    Invoke-WebRequest -Uri "$RepoBase/VERSION" -OutFile (Join-Path $installDir 'VERSION') -UseBasicParsing -TimeoutSec 30
    Write-Info 'Downloaded VERSION.'
} catch {
    Write-Warn "Could not download VERSION file. Update notifications will show 'unknown' until the next successful 'claude-profile update'."
}

Write-Step 'Checking PATH...'
if (Test-OnPath $installDir) {
    Write-Info "$installDir is already on your PATH."
} else {
    Write-Info "Adding $installDir to user PATH..."
    Add-ToUserPath $installDir
    Write-Info 'PATH updated. New terminal windows will pick this up automatically.'
}

Write-Step 'Configuring PowerShell profile...'
$SourceLine = ". '$installDir\claude-profile-init.ps1'"
$ProfilePath = $PROFILE

if (-not (Test-Path $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    Write-Info "Created PowerShell profile: $ProfilePath"
}

$ProfileContent = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
if ($ProfileContent -and $ProfileContent.Contains('claude-profile-init.ps1')) {
    Write-Info 'Source line already in $PROFILE'
} else {
    Add-Content -Path $ProfilePath -Value "`n# claude-profile: manage Claude Code configuration profiles`n$SourceLine"
    Write-Info "Added source line to $ProfilePath"
}

Write-Step 'Done!'
Write-Info ''
Write-Info 'Restart PowerShell (or run: . $PROFILE) then:'
Write-Info ''
Write-Info '  claude-profile create work     # Create a profile'
Write-Info '  claude-profile default work    # Set it as default'
Write-Info '  claude                         # Runs with the active profile'
Write-Info ''
Write-Info 'For cmd.exe, use: call claude-profile use work'
Write-Info ''
Write-Info "Run 'claude-profile help' for all commands."
Write-Host ''
