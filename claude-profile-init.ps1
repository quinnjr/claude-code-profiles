# claude-profile-init.ps1 — Dot-source this in your $PROFILE
#
#   . "${env:LOCALAPPDATA}\claude-profile\claude-profile-init.ps1"    (Windows)
#   . "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile/claude-profile-init.ps1"  (Linux/macOS)
#
# Provides:
#   claude           — runs Claude Code with the active/default profile
#   claude-profile   — manage profiles (create, list, delete, default, use, which)

# --- Version tracking helpers ---

function Get-CPInstallDir {
    if ($IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
        return Join-Path $env:LOCALAPPDATA 'claude-profile'
    }
    if ($env:XDG_DATA_HOME) {
        return Join-Path $env:XDG_DATA_HOME 'claude-profile'
    }
    return Join-Path $HOME '.local' 'share' 'claude-profile'
}

function Get-CPDataDir {
    if ($IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
        return Join-Path $env:LOCALAPPDATA 'claude-profiles'
    }
    if ($env:XDG_DATA_HOME) {
        return Join-Path $env:XDG_DATA_HOME 'claude-profiles'
    }
    return Join-Path $HOME '.local' 'share' 'claude-profiles'
}

function Get-CPInstalledVersion {
    $versionFile = Join-Path (Get-CPInstallDir) 'VERSION'
    if (Test-Path $versionFile) {
        $raw = Get-Content $versionFile -Raw -ErrorAction SilentlyContinue
        if ($raw) {
            $v = $raw.Trim()
            if ($v) { return $v }
        }
    }
    return 'unknown'
}

# Numeric MAJOR.MINOR.PATCH comparison. "unknown" is always less than any
# real version, and equal to itself.
function Test-CPVersionLessThan {
    param([string]$A, [string]$B)
    if ($A -eq 'unknown') { return ($B -ne 'unknown') }
    if ($B -eq 'unknown') { return $false }
    try {
        return ([version]$A) -lt ([version]$B)
    } catch {
        return $false
    }
}

# --- Passive update check ---

$Script:CPRepoApi = if ($env:CLAUDE_PROFILE_UPDATE_API_BASE) { $env:CLAUDE_PROFILE_UPDATE_API_BASE } else { 'https://api.github.com/repos/quinnjr/claude-code-profiles' }
$Script:CPAssetBase = if ($env:CLAUDE_PROFILE_UPDATE_ASSET_BASE) { $env:CLAUDE_PROFILE_UPDATE_ASSET_BASE } else { 'https://github.com/quinnjr/claude-code-profiles/releases/download' }

function Test-CPChecksum {
    param([string]$FilePath, [string]$SumsPath)
    $name = Split-Path $FilePath -Leaf
    $line = (Get-Content $SumsPath -ErrorAction SilentlyContinue) | Where-Object { $_ -match [regex]::Escape($name) } | Select-Object -First 1
    if (-not $line) { return $false }
    $expected = ($line -split '\s+')[0]
    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    return ($expected.ToLower() -eq $actual.ToLower())
}

$Script:CPUpdateInterval = 86400
if ($env:CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL) {
    try { $Script:CPUpdateInterval = [long]$env:CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL }
    catch { }
}

function Get-CPTagVersion {
    param([string]$Json)
    if ($Json -notmatch '"tag_name"\s*:\s*"([^"]*)"') { return $null }
    $tag = $Matches[1].TrimStart('v')
    if ($tag -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { return $null }
    return $tag
}

function Read-CPUpdateCache {
    $cacheFile = Join-Path (Get-CPInstallDir) '.update-check'
    $result = [ordered]@{ Timestamp = [long]0; Version = 'unknown'; Notified = 0 }
    if (-not (Test-Path $cacheFile)) { return $result }
    $lines = @(Get-Content $cacheFile -ErrorAction SilentlyContinue)
    if ($lines.Count -ge 1 -and $lines[0] -match '^\d+$') { $result.Timestamp = [long]$lines[0] }
    if ($lines.Count -ge 2 -and $lines[1]) { $result.Version = $lines[1] }
    if ($lines.Count -ge 3 -and ($lines[2] -eq '0' -or $lines[2] -eq '1')) { $result.Notified = [int]$lines[2] }
    return $result
}

# Rate-limited stderr diagnostic for persistent local cache-file I/O
# failures (permissions, disk full) -- distinct from transient network
# failures, which stay silent by design in Invoke-CPUpdateCheck.
# Best-effort: uses a separate marker file so a broken .update-check
# write doesn't also block this diagnostic; if even the marker can't be
# written, this degrades to printing every invocation rather than
# staying silent forever (never worse than the bug being fixed).
#
# Deliberately reuses $Script:CPUpdateInterval (default 86400s) as a
# rolling window approximating "at most once per calendar day" -- not a
# literal calendar-day boundary, and coupled to the same user-tunable
# CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL override that governs the update
# check's own polling frequency. This is an accepted simplification, not
# a separate config knob (matches the sh implementation's tradeoff).
#
# Called from inside Write-CPUpdateCache (not from its callers) so the
# already-resolved install dir and timestamp are reused rather than
# re-resolved -- this also means every current and future caller of
# Write-CPUpdateCache gets this diagnostic for free, with no risk of a
# call site forgetting to check the write's return value.
function Write-CPCacheFailureDiagnostic {
    param([string]$InstallDir, [long]$Now)
    $marker = Join-Path $InstallDir '.update-check-diag'
    $last = [long]0
    if (Test-Path $marker) {
        $raw = Get-Content $marker -Raw -ErrorAction SilentlyContinue
        if ($raw -and ($raw.Trim() -match '^\d+$')) { $last = [long]$raw.Trim() }
    }
    if (($Now - $last) -ge $Script:CPUpdateInterval) {
        $host.UI.WriteErrorLine("claude-profile: warning: could not write update-check cache in $InstallDir -- update notifications may not work until this is fixed")
        $tmpMarker = "$marker.tmp.$PID"
        try {
            Set-Content -Path $tmpMarker -Value "$Now" -ErrorAction Stop
            Move-Item -Path $tmpMarker -Destination $marker -Force -ErrorAction Stop
        } catch {
            Remove-Item -Path $tmpMarker -Force -ErrorAction SilentlyContinue
        }
    }
}

# Atomic write: temp file + Move-Item, so a crash mid-write can't corrupt
# the cache that every claude() invocation reads.
function Write-CPUpdateCache {
    param([long]$Timestamp, [string]$Version, [int]$Notified)
    $installDir = Get-CPInstallDir
    New-Item -ItemType Directory -Path $installDir -Force -ErrorAction SilentlyContinue | Out-Null
    $cacheFile = Join-Path $installDir '.update-check'
    $tmpFile = "$cacheFile.tmp.$PID"
    try {
        Set-Content -Path $tmpFile -Value "$Timestamp`n$Version`n$Notified" -ErrorAction Stop
        Move-Item -Path $tmpFile -Destination $cacheFile -Force -ErrorAction Stop
        return $true
    } catch {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        Write-CPCacheFailureDiagnostic -InstallDir $installDir -Now $Timestamp
        return $false
    }
}

function Invoke-CPUpdateCheck {
    try {
        if ($env:CLAUDE_PROFILE_NO_UPDATE_CHECK) { return }
        $cache = Read-CPUpdateCache
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        if (($now - $cache.Timestamp) -ge $Script:CPUpdateInterval) {
            $newVer = $cache.Version
            try {
                $resp = Invoke-RestMethod -Uri "$($Script:CPRepoApi)/releases/latest" -TimeoutSec 3 -ErrorAction Stop
                $extracted = Get-CPTagVersion -Json ($resp | ConvertTo-Json -Compress)
                if ($extracted) { $newVer = $extracted }
            } catch {
                # network/API failure: silently keep the previous cached version
            }
            if ($newVer -ne $cache.Version) {
                Write-CPUpdateCache -Timestamp $now -Version $newVer -Notified 0 | Out-Null
                $cache.Version = $newVer
                $cache.Notified = 0
            } else {
                Write-CPUpdateCache -Timestamp $now -Version $cache.Version -Notified $cache.Notified | Out-Null
            }
        }

        if ($cache.Notified -eq 0 -and $cache.Version -ne 'unknown') {
            $installed = Get-CPInstalledVersion
            if (Test-CPVersionLessThan -A $installed -B $cache.Version) {
                $installedDisplay = if ($installed -eq 'unknown') { 'unknown' } else { "v$installed" }
                $host.UI.WriteErrorLine("A new claude-profile version is available ($installedDisplay -> v$($cache.Version)). Run 'claude-profile update' to upgrade.")
                Write-CPUpdateCache -Timestamp $now -Version $cache.Version -Notified 1 | Out-Null
            }
        }
    } catch {
        # Never let the update check break claude() startup.
    }
}

# --- Directory-local profile (.claude-profile) auto-switching ---
#
# A directory may contain a `.claude-profile` file whose first non-empty,
# non-comment line names a profile. Entering that directory (or any
# descendant) switches CLAUDE_CONFIG_DIR to it; leaving reverts to the
# default. An explicit `claude-profile use <name>` pins the session and
# suppresses auto-switching until `claude-profile auto on`.
#
# Environment knobs:
#   CLAUDE_PROFILE_NO_AUTO_SWITCH=1   disable auto-switching entirely
#   CLAUDE_PROFILE_AUTO_QUIET=1       switch silently (no stderr notices)
#
# CLAUDE_PROFILE_AUTO_SET is an environment variable (not a script variable)
# so nested shells know the current CLAUDE_CONFIG_DIR came from
# auto-switching rather than from an explicit `use`.

$Script:CPDotfileName = '.claude-profile'

function Write-CPAutoNotice {
    param([string]$Message)
    if ($env:CLAUDE_PROFILE_AUTO_QUIET) { return }
    $host.UI.WriteErrorLine("claude-profile: $Message")
}

# Returns the path of the nearest .claude-profile at or above $StartDir, or
# $null when none exists.
function Find-CPDotfile {
    param([string]$StartDir)
    if (-not $StartDir) { return $null }
    try {
        $dir = Get-Item -LiteralPath $StartDir -Force -ErrorAction Stop
    } catch {
        return $null
    }
    while ($dir) {
        $candidate = Join-Path $dir.FullName $Script:CPDotfileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        $dir = $dir.Parent
    }
    return $null
}

# Returns the first non-empty, non-comment line of $Path, trimmed, or $null.
function Read-CPDotfile {
    param([string]$Path)
    try {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    } catch {
        return $null
    }
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        return $trimmed
    }
    return $null
}

# Returns the current filesystem directory, or $null when the session is on a
# non-filesystem provider (Registry:, Cert:, ...) where .claude-profile has no
# meaning.
function Get-CPCurrentFileSystemPath {
    $loc = Get-Location
    if ($loc.Provider.Name -ne 'FileSystem') { return $null }
    return $loc.ProviderPath
}

# Resolves and applies the directory-local profile for the current directory.
# Safe to call repeatedly: it short-circuits when the directory hasn't
# changed, which also rate-limits the warnings below to once per directory
# entry rather than once per prompt.
function Invoke-CPAutoSwitch {
    try {
        if ($env:CLAUDE_PROFILE_NO_AUTO_SWITCH) { return }
        if ($Script:CPAutoOff) { return }
        $cwd = Get-CPCurrentFileSystemPath
        if (-not $cwd) { return }
        if ($cwd -eq $Script:CPAutoLastPwd) { return }
        $Script:CPAutoLastPwd = $cwd

        # An explicitly-chosen profile (claude-profile use, or a
        # CLAUDE_CONFIG_DIR inherited from outside) wins over .claude-profile.
        if ($env:CLAUDE_CONFIG_DIR -and ($env:CLAUDE_CONFIG_DIR -ne $env:CLAUDE_PROFILE_AUTO_SET)) { return }

        $dotfile = Find-CPDotfile -StartDir $cwd
        $name = if ($dotfile) { Read-CPDotfile -Path $dotfile } else { $null }

        if (-not $name) {
            if ($env:CLAUDE_PROFILE_AUTO_SET) {
                Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
                Remove-Item Env:\CLAUDE_PROFILE_AUTO_SET -ErrorAction SilentlyContinue
                Write-CPAutoNotice 'directory profile cleared; using the default profile'
            }
            if ($dotfile) {
                $host.UI.WriteErrorLine("claude-profile: ignoring ${dotfile}: no profile name in file")
            }
            return
        }

        if ($name -notmatch '^[A-Za-z0-9_-]+$' -or $name -eq 'skills') {
            $host.UI.WriteErrorLine("claude-profile: ignoring ${dotfile}: invalid profile name '$name'")
            return
        }

        $profileDir = Join-Path (Get-CPDataDir) $name
        if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
            $host.UI.WriteErrorLine("claude-profile: ignoring ${dotfile}: profile '$name' does not exist")
            return
        }

        if ($env:CLAUDE_CONFIG_DIR -ne $profileDir) {
            $env:CLAUDE_CONFIG_DIR = $profileDir
            Write-CPAutoNotice "switched to profile '$name' (from $dotfile)"
        }
        $env:CLAUDE_PROFILE_AUTO_SET = $profileDir
    } catch {
        # Never let auto-switching break the prompt.
    }
}

# Registers Invoke-CPAutoSwitch with whatever directory-change mechanism the
# running host offers. PowerShell 6+ has a real LocationChangedAction hook;
# Windows PowerShell 5.1 only has the prompt function. Both paths are guarded
# so re-dot-sourcing this file can't chain a handler into itself.
if (-not $Script:CPLocationHookInstalled) {
    if ($ExecutionContext.InvokeCommand.PSObject.Properties.Name -contains 'LocationChangedAction') {
        $Script:CPPrevLocationAction = $ExecutionContext.InvokeCommand.LocationChangedAction
        $ExecutionContext.InvokeCommand.LocationChangedAction = {
            param($EventSender, $EventArgs)
            if ($Script:CPPrevLocationAction) { & $Script:CPPrevLocationAction $EventSender $EventArgs }
            Invoke-CPAutoSwitch
        }
    } else {
        $Script:CPPrevPrompt = $function:prompt
        function global:prompt {
            Invoke-CPAutoSwitch
            if ($Script:CPPrevPrompt) {
                & $Script:CPPrevPrompt
            } else {
                "PS $($ExecutionContext.SessionState.Path.CurrentLocation)$('>' * ($NestedPromptLevel + 1)) "
            }
        }
    }
    $Script:CPLocationHookInstalled = $true
}

# Resolve once at load time so a session started inside a .claude-profile
# tree is already on the right profile.
Invoke-CPAutoSwitch

# --- Skill pool helpers ---
#
# A central pool at <data-root>/skills holds registered skills (directories
# or links to skill source directories). Each profile may carry a
# skills.conf manifest (one pool-skill name per line, # comments) naming
# the subset it wants; no manifest means every pool skill. Sync
# materializes the selection as links in <profile>/skills. Only links
# whose target lies under the pool are ever created or removed — hand-made
# links, real directories, and files are left alone.

function Get-CPSkillPoolDir {
    return Join-Path (Get-CPDataDir) 'skills'
}

# Creates a link at $Dest pointing to directory $Source: a directory
# junction on Windows (no admin rights needed, readable by the cmd and sh
# implementations), a symlink elsewhere. Returns $true on success.
function New-CPSkillLink {
    param([string]$Source, [string]$Dest)
    try {
        if ($IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
            New-Item -ItemType Junction -Path $Dest -Target $Source -ErrorAction Stop | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $Dest -Target $Source -ErrorAction Stop | Out-Null
        }
        return $true
    } catch {
        return $false
    }
}

# Returns the literal link target of $Path, or $null when it is not a
# link (junction or symlink).
function Get-CPLinkTarget {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not $item.LinkType) { return $null }
    $target = @($item.Target) | Select-Object -First 1
    if ($target) { return [string]$target }
    return $null
}

# Removes a link without touching its target. FileSystemInfo.Delete() is
# non-recursive, so on a junction it removes only the reparse point.
# Deliberately NO Remove-Item fallback: on Windows PowerShell 5.1,
# Remove-Item on a junction follows the reparse point and deletes the
# TARGET's contents (fixed only in PS 6.2+) — failing here must never
# escalate into deleting the user's skill source.
function Remove-CPSkillLink {
    param([string]$Path)
    try {
        (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Delete()
        return $true
    } catch {
        return $false
    }
}

# Returns $true when the link at $Path is managed, i.e. its target lies
# under the pool directory.
function Test-CPManagedSkillLink {
    param([string]$Path, [string]$PoolDir)
    $target = Get-CPLinkTarget -Path $Path
    if (-not $target) { return $false }
    $normTarget = $target.Replace('\', '/').TrimEnd('/')
    $normPool = $PoolDir.Replace('\', '/').TrimEnd('/')
    # Windows paths are case-insensitive; %LOCALAPPDATA% casing can differ
    # between the shell that created a junction and this one.
    if ($IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
        return $normTarget.StartsWith("$normPool/", [System.StringComparison]::OrdinalIgnoreCase)
    }
    return $normTarget.StartsWith("$normPool/", [System.StringComparison]::Ordinal)
}

# Returns the valid skill names from manifest file $Path. Blank lines and
# # comments are skipped; invalid names warn and are skipped so one bad
# line never fails a whole sync.
function Read-CPSkillManifest {
    param([string]$Path)
    $names = @()
    try {
        $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    } catch {
        return $names
    }
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^[A-Za-z0-9_-]+$') {
            $host.UI.WriteErrorLine("claude-profile: skills.conf: ignoring invalid skill name '$trimmed'")
            continue
        }
        $names += $trimmed
    }
    return $names
}

# Returns the names of every skill registered in the pool, including
# dangling registrations (link whose source is gone) so listings can
# report them and sync can warn.
function Get-CPPoolSkills {
    param([string]$PoolDir)
    if (-not (Test-Path -LiteralPath $PoolDir -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $PoolDir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer -or $_.LinkType } |
        ForEach-Object { $_.Name })
}

# Returns the desired skill set for a profile: the manifest names when
# skills.conf exists, every pool skill otherwise.
function Get-CPDesiredSkills {
    param([string]$ProfileDir, [string]$PoolDir)
    $manifest = Join-Path $ProfileDir 'skills.conf'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        return @(Read-CPSkillManifest -Path $manifest)
    }
    return @(Get-CPPoolSkills -PoolDir $PoolDir)
}

# Fails when <data>/skills exists but looks like a Claude Code profile —
# i.e. a profile named 'skills' created before that name was reserved.
# Without this, pool operations would enumerate its internals as skills
# and link them into every profile.
function Test-CPPoolGuard {
    $poolDir = Get-CPSkillPoolDir
    if (-not (Test-Path -LiteralPath $poolDir -PathType Container)) { return $true }
    if ((Test-Path -LiteralPath (Join-Path $poolDir 'settings.json') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $poolDir '.credentials.json') -PathType Leaf)) {
        $host.UI.WriteErrorLine("claude-profile: $poolDir looks like a Claude Code profile, not a skill pool (the name 'skills' is now reserved). Move that profile aside before using skill pools.")
        return $false
    }
    return $true
}

# Re-materializes managed skill links for profile $Name from its manifest
# (or the whole pool when no manifest).
function Sync-CPProfileSkills {
    param([string]$Name)
    $dataDir = Get-CPDataDir
    $poolDir = Get-CPSkillPoolDir
    $profileDir = Join-Path $dataDir $Name
    $skillsDir = Join-Path $profileDir 'skills'
    if (-not (Test-CPPoolGuard)) { return $false }
    # A manifest that exists but can't be read must abort, not silently
    # become "select nothing" and strip the profile's managed links.
    $manifest = Join-Path $profileDir 'skills.conf'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
            [void](Get-Content -LiteralPath $manifest -ErrorAction Stop)
        } catch {
            $host.UI.WriteErrorLine("claude-profile: cannot read ${manifest}; not syncing")
            return $false
        }
    }
    $desired = @(Get-CPDesiredSkills -ProfileDir $profileDir -PoolDir $poolDir)
    try {
        New-Item -ItemType Directory -Path $skillsDir -Force -ErrorAction Stop | Out-Null
    } catch {
        $host.UI.WriteErrorLine("claude-profile: cannot create $skillsDir")
        return $false
    }

    # Pass 1: drop managed links that are dangling or no longer desired.
    foreach ($entry in @(Get-ChildItem -LiteralPath $skillsDir -Force -ErrorAction SilentlyContinue)) {
        if (-not $entry.LinkType) { continue }
        if (-not (Test-CPManagedSkillLink -Path $entry.FullName -PoolDir $poolDir)) { continue }
        $poolEntry = Join-Path $poolDir $entry.Name
        if (($desired -notcontains $entry.Name) -or
            -not (Test-Path -LiteralPath $poolEntry -PathType Container)) {
            if (-not (Remove-CPSkillLink -Path $entry.FullName)) {
                $host.UI.WriteErrorLine("claude-profile: could not remove $($entry.FullName)")
            }
        }
    }

    # Pass 2: create links missing from the desired set.
    foreach ($want in $desired) {
        $poolEntry = Join-Path $poolDir $want
        if (-not (Test-Path -LiteralPath $poolEntry -PathType Container)) {
            $host.UI.WriteErrorLine("claude-profile: skill '$want' is not in the pool (or its source is gone); skipping")
            continue
        }
        $dest = Join-Path $skillsDir $want
        if (Test-Path -LiteralPath $dest) {
            if (-not (Test-CPManagedSkillLink -Path $dest -PoolDir $poolDir)) {
                $host.UI.WriteErrorLine("claude-profile: skill '$want': unmanaged entry already at $dest; skipping")
            }
            continue
        }
        if (-not (New-CPSkillLink -Source $poolEntry -Dest $dest)) {
            $host.UI.WriteErrorLine("claude-profile: could not link skill '$want'")
        }
    }
    return $true
}

# --- claude wrapper ---
# Auto-resolves the default profile before calling the real claude binary.
# If CLAUDE_CONFIG_DIR is already set (e.g. via 'claude-profile use'),
# it passes through without overriding.

function claude {
    Invoke-CPUpdateCheck
    # Covers directory changes the hook above may have missed.
    Invoke-CPAutoSwitch
    if (-not $env:CLAUDE_CONFIG_DIR) {
        $DataDir = Get-CPDataDir
        $DefaultFile = Join-Path $DataDir '.default'
        if (Test-Path $DefaultFile) {
            $Name = (Get-Content $DefaultFile -Raw).Trim()
            $ProfilePath = Join-Path $DataDir $Name
            if ($Name -and (Test-Path $ProfilePath -PathType Container)) {
                $env:CLAUDE_CONFIG_DIR = $ProfilePath
                # Mark it auto-managed, not an explicit pin: without this, the
                # first `claude` run would freeze the session on the default
                # profile and later .claude-profile directories would be
                # ignored.
                $env:CLAUDE_PROFILE_AUTO_SET = $ProfilePath
            }
        }
    }
    $ClaudePath = (Get-Command claude -CommandType Application -ErrorAction SilentlyContinue |
                   Select-Object -First 1).Source
    if (-not $ClaudePath) {
        $host.UI.WriteErrorLine("claude-profile: 'claude' binary not found in PATH")
        return
    }
    & $ClaudePath @args
}

# --- claude-profile management function ---

function claude-profile {
    $ErrorActionPreference = 'Stop'

    # --- Platform-aware data directory ---
    $DataDir = Get-CPDataDir
    $DefaultFile = Join-Path $DataDir '.default'

    # --- Parse $args manually ---
    $Command = if ($args.Count -gt 0) { $args[0] } else { $null }

    # --- Helpers (nested functions, scoped to claude-profile) ---

    function _cp_die {
        param([string]$Message)
        $host.UI.WriteErrorLine("claude-profile: $Message")
    }

    function _cp_validate_name {
        param([string]$Name)
        if ([string]::IsNullOrEmpty($Name)) {
            _cp_die 'profile name must not be empty'
            return $false
        }
        if ($Name.StartsWith('.')) {
            _cp_die "invalid profile name '$Name': must not start with '.'"
            return $false
        }
        if ($Name.Contains('..')) {
            _cp_die "invalid profile name '$Name': must not contain '..'"
            return $false
        }
        if ($Name.Contains('/')) {
            _cp_die "invalid profile name '$Name': must not contain '/'"
            return $false
        }
        if ($Name.Contains('\')) {
            _cp_die "invalid profile name '$Name': must not contain '\'"
            return $false
        }
        if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
            _cp_die "invalid profile name '$Name': use only letters, digits, hyphens, underscores"
            return $false
        }
        if ($Name -eq 'skills') {
            _cp_die "profile name 'skills' is reserved for the skill pool"
            return $false
        }
        return $true
    }

    function _cp_validate_skill_name {
        param([string]$Name)
        if ([string]::IsNullOrEmpty($Name)) {
            _cp_die 'skill name must not be empty'
            return $false
        }
        if ($Name -notmatch '^[A-Za-z0-9_-]+$') {
            _cp_die "invalid skill name '$Name': use only letters, digits, hyphens, underscores"
            return $false
        }
        return $true
    }

    # Resolves the profile a skills command acts on: the explicit argument
    # if given, else the active profile, else the default. Returns the
    # profile name, or $null after printing an error.
    function _cp_skills_profile {
        param([string]$ArgName)
        $name = $null
        if ($ArgName) {
            if (-not (_cp_validate_name $ArgName)) { return $null }
            $name = $ArgName
        } elseif ($env:CLAUDE_CONFIG_DIR) {
            $normalized = $env:CLAUDE_CONFIG_DIR.Replace('\', '/')
            $normalizedData = $DataDir.Replace('\', '/')
            # Case-insensitive on Windows: CLAUDE_CONFIG_DIR may be
            # inherited from a cmd/Git Bash session with different
            # %LOCALAPPDATA% casing.
            $cmp = if ($IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')) {
                [System.StringComparison]::OrdinalIgnoreCase
            } else {
                [System.StringComparison]::Ordinal
            }
            if ($normalized.StartsWith("$normalizedData/", $cmp)) {
                $name = Split-Path $env:CLAUDE_CONFIG_DIR -Leaf
            } else {
                _cp_die 'active CLAUDE_CONFIG_DIR is not a managed profile; pass a profile name'
                return $null
            }
        } elseif (Test-Path $DefaultFile) {
            $name = (Get-Content $DefaultFile -Raw).Trim()
            if (-not $name) {
                _cp_die 'no profile specified and no default profile set'
                return $null
            }
        } else {
            _cp_die 'no profile specified and no default profile set'
            return $null
        }
        if (-not (Test-Path (Join-Path $DataDir $name) -PathType Container)) {
            _cp_die "profile '$name' does not exist"
            return $null
        }
        return $name
    }

    # --- Command dispatch ---

    switch ($Command) {
        'use' {
            $ArgName = if ($args.Count -gt 1) { $args[1] } else { $null }
            if ([string]::IsNullOrEmpty($ArgName)) {
                _cp_die 'usage: claude-profile use <name>'
                return
            }
            if ($args.Count -gt 2) {
                _cp_die "unexpected argument after profile name: '$($args[2])'"
                return
            }
            if (-not (_cp_validate_name $ArgName)) { return }
            $ProfileDir = Join-Path $DataDir $ArgName
            if (-not (Test-Path $ProfileDir -PathType Container)) {
                _cp_die "profile '$ArgName' does not exist. Create it with: claude-profile create $ArgName"
                return
            }
            $env:CLAUDE_CONFIG_DIR = $ProfileDir
            # Dropping the auto-set marker pins the session: subsequent
            # directory changes will no longer override this choice.
            Remove-Item Env:\CLAUDE_PROFILE_AUTO_SET -ErrorAction SilentlyContinue
            Write-Host "Switched to profile: $ArgName"
        }

        'auto' {
            # Defaulted to 'status' rather than $null so the inner switch has a
            # real value to match on.
            $Sub = if ($args.Count -gt 1) { $args[1] } else { 'status' }
            switch ($Sub) {
                'on' {
                    $Script:CPAutoOff = $false
                    Remove-Item Env:\CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
                    Remove-Item Env:\CLAUDE_PROFILE_AUTO_SET -ErrorAction SilentlyContinue
                    $Script:CPAutoLastPwd = $null
                    Invoke-CPAutoSwitch
                    Write-Host 'Directory-local auto-switching enabled.'
                }
                'off' {
                    $Script:CPAutoOff = $true
                    Write-Host 'Directory-local auto-switching disabled for this session.'
                }
                'status' {
                    if ($env:CLAUDE_PROFILE_NO_AUTO_SWITCH) {
                        Write-Host 'Auto-switching: disabled (CLAUDE_PROFILE_NO_AUTO_SWITCH is set)'
                    } elseif ($Script:CPAutoOff) {
                        Write-Host 'Auto-switching: disabled for this session'
                    } elseif ($env:CLAUDE_CONFIG_DIR -and ($env:CLAUDE_CONFIG_DIR -ne $env:CLAUDE_PROFILE_AUTO_SET)) {
                        Write-Host 'Auto-switching: pinned (an explicit profile is active)'
                        Write-Host "Run 'claude-profile auto on' to resume auto-switching."
                    } else {
                        Write-Host 'Auto-switching: enabled'
                    }
                    $Dotfile = Find-CPDotfile -StartDir (Get-CPCurrentFileSystemPath)
                    if ($Dotfile) {
                        $DotName = Read-CPDotfile -Path $Dotfile
                        if (-not $DotName) { $DotName = '<empty>' }
                        Write-Host "Directory profile: $DotName ($Dotfile)"
                    } else {
                        Write-Host 'Directory profile: none in scope'
                    }
                }
                default {
                    _cp_die 'usage: claude-profile auto [on|off|status]'
                    return
                }
            }
        }

        'local' {
            $Sub = if ($args.Count -gt 1) { $args[1] } else { $null }
            $Cwd = Get-CPCurrentFileSystemPath
            if (-not $Cwd) {
                _cp_die 'the current location is not a filesystem directory'
                return
            }
            $LocalFile = Join-Path $Cwd $Script:CPDotfileName
            if (-not $Sub) {
                $Dotfile = Find-CPDotfile -StartDir $Cwd
                if (-not $Dotfile) {
                    _cp_die "no $($Script:CPDotfileName) found in this directory or any parent"
                    return
                }
                $DotName = Read-CPDotfile -Path $Dotfile
                if (-not $DotName) { $DotName = '<empty>' }
                Write-Host $Dotfile
                Write-Host "Profile: $DotName"
                return
            }
            if ($Sub -eq '--remove' -or $Sub -eq '--clear') {
                if (-not (Test-Path -LiteralPath $LocalFile -PathType Leaf)) {
                    _cp_die "no $($Script:CPDotfileName) in the current directory"
                    return
                }
                Remove-Item -LiteralPath $LocalFile -Force
                Write-Host "Removed $LocalFile"
                $Script:CPAutoLastPwd = $null
                Invoke-CPAutoSwitch
                return
            }
            if ($Sub.StartsWith('-')) {
                _cp_die "unknown option '$Sub'"
                return
            }
            if ($args.Count -gt 2) {
                _cp_die "unexpected argument after profile name: '$($args[2])'"
                return
            }
            if (-not (_cp_validate_name $Sub)) { return }
            $ProfileDir = Join-Path $DataDir $Sub
            if (-not (Test-Path $ProfileDir -PathType Container)) {
                _cp_die "profile '$Sub' does not exist. Create it with: claude-profile create $Sub"
                return
            }
            [System.IO.File]::WriteAllText($LocalFile, "$Sub`n")
            Write-Host "Wrote $LocalFile (profile: $Sub)"
            $Script:CPAutoLastPwd = $null
            Invoke-CPAutoSwitch
        }

        'create' {
            $ArgName = if ($args.Count -gt 1) { $args[1] } else { $null }
            if ([string]::IsNullOrEmpty($ArgName)) {
                _cp_die 'usage: claude-profile create <name>'
                return
            }
            if (-not (_cp_validate_name $ArgName)) { return }
            $ProfileDir = Join-Path $DataDir $ArgName
            if (Test-Path $ProfileDir -PathType Container) {
                _cp_die "profile '$ArgName' already exists"
                return
            }
            New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
            Write-Host "Created profile: $ArgName"
            Write-Host "Config directory: $ProfileDir"
            # A new profile has no manifest, so this links every pool skill
            # (the backward-compatible "all" default). No pool: no-op.
            if (Test-Path (Get-CPSkillPoolDir) -PathType Container) {
                Sync-CPProfileSkills -Name $ArgName | Out-Null
            }
        }

        { $_ -eq 'list' -or $_ -eq 'ls' } {
            if (-not (Test-Path $DataDir -PathType Container)) {
                Write-Host 'No profiles found. Create one with: claude-profile create <name>'
                return
            }
            $CurDefault = ''
            if (Test-Path $DefaultFile) {
                $CurDefault = (Get-Content $DefaultFile -Raw).Trim()
            }
            # Derive active profile name from CLAUDE_CONFIG_DIR
            $Active = ''
            if ($env:CLAUDE_CONFIG_DIR) {
                $Normalized = $env:CLAUDE_CONFIG_DIR.Replace('\', '/')
                $NormalizedData = $DataDir.Replace('\', '/')
                if ($Normalized.StartsWith("$NormalizedData/")) {
                    $Active = Split-Path $env:CLAUDE_CONFIG_DIR -Leaf
                }
            }
            $Entries = @(Get-ChildItem -Path $DataDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'skills' })
            if (-not $Entries -or $Entries.Count -eq 0) {
                Write-Host 'No profiles found. Create one with: claude-profile create <name>'
                return
            }
            $PoolCount = @(Get-CPPoolSkills -PoolDir (Get-CPSkillPoolDir)).Count
            foreach ($Entry in $Entries) {
                $SkillNote = ''
                $Manifest = Join-Path $Entry.FullName 'skills.conf'
                if (Test-Path -LiteralPath $Manifest -PathType Leaf) {
                    $SkillCount = @(Read-CPSkillManifest -Path $Manifest).Count
                    $SkillNote = " [skills: $SkillCount/$PoolCount]"
                }
                $IsDefault = ($Entry.Name -eq $CurDefault)
                $IsActive = ($Entry.Name -eq $Active)
                if ($IsDefault -and $IsActive) {
                    Write-Host ">* $($Entry.Name) (default, active)$SkillNote"
                } elseif ($IsDefault) {
                    Write-Host " * $($Entry.Name) (default)$SkillNote"
                } elseif ($IsActive) {
                    Write-Host ">  $($Entry.Name) (active)$SkillNote"
                } else {
                    Write-Host "   $($Entry.Name)$SkillNote"
                }
            }
        }

        'default' {
            $ArgName = if ($args.Count -gt 1) { $args[1] } else { $null }
            if ([string]::IsNullOrEmpty($ArgName)) {
                # Get default
                if (Test-Path $DefaultFile) {
                    $CurDefault = (Get-Content $DefaultFile -Raw).Trim()
                    if ($CurDefault) {
                        Write-Host $CurDefault
                    } else {
                        _cp_die 'default profile file is empty. Set one with: claude-profile default <name>'
                        return
                    }
                } else {
                    _cp_die 'no default profile set. Set one with: claude-profile default <name>'
                    return
                }
                return
            }
            # Set default
            if (-not (_cp_validate_name $ArgName)) { return }
            $ProfileDir = Join-Path $DataDir $ArgName
            if (-not (Test-Path $ProfileDir -PathType Container)) {
                _cp_die "profile '$ArgName' does not exist. Create it with: claude-profile create $ArgName"
                return
            }
            if (-not (Test-Path $DataDir -PathType Container)) {
                New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
            }
            [System.IO.File]::WriteAllText($DefaultFile, $ArgName)
            Write-Host "Default profile set to: $ArgName"
        }

        'which' {
            $ArgName = if ($args.Count -gt 1) { $args[1] } else { $null }
            if (-not [string]::IsNullOrEmpty($ArgName)) {
                # Named profile
                if (-not (_cp_validate_name $ArgName)) { return }
                $ProfileDir = Join-Path $DataDir $ArgName
                if (-not (Test-Path $ProfileDir -PathType Container)) {
                    _cp_die "profile '$ArgName' does not exist. Create it with: claude-profile create $ArgName"
                    return
                }
                Write-Host $ProfileDir
            } else {
                # Resolve default
                if (-not (Test-Path $DefaultFile)) {
                    _cp_die 'no default profile set. Use: claude-profile default <name>'
                    return
                }
                $CurDefault = (Get-Content $DefaultFile -Raw).Trim()
                if ([string]::IsNullOrEmpty($CurDefault)) {
                    _cp_die 'default profile file is empty. Set one with: claude-profile default <name>'
                    return
                }
                $ProfileDir = Join-Path $DataDir $CurDefault
                if (-not (Test-Path $ProfileDir -PathType Container)) {
                    _cp_die "profile '$CurDefault' does not exist. Create it with: claude-profile create $CurDefault"
                    return
                }
                Write-Host $ProfileDir
            }
        }

        'delete' {
            $ArgName = if ($args.Count -gt 1) { $args[1] } else { $null }
            if ([string]::IsNullOrEmpty($ArgName)) {
                _cp_die 'usage: claude-profile delete <name>'
                return
            }
            if (-not (_cp_validate_name $ArgName)) { return }
            $ProfileDir = Join-Path $DataDir $ArgName
            if (-not (Test-Path $ProfileDir -PathType Container)) {
                _cp_die "profile '$ArgName' does not exist"
                return
            }
            $Confirm = Read-Host "Delete profile `"$ArgName`" and all its data? [y/N]"
            if ($Confirm -match '^[yY]([eE][sS])?$') {
                Remove-Item -Path $ProfileDir -Recurse -Force
                Write-Host "Deleted profile: $ArgName"
                # Clear default if the deleted profile was the default
                if (Test-Path $DefaultFile) {
                    $CurDefault = (Get-Content $DefaultFile -Raw).Trim()
                    if ($CurDefault -eq $ArgName) {
                        Remove-Item -Path $DefaultFile -Force
                        Write-Host "Cleared default profile (was `"$ArgName`")"
                    }
                }
                # Unset CLAUDE_CONFIG_DIR if the deleted profile was active
                if ($env:CLAUDE_CONFIG_DIR -eq $ProfileDir) {
                    Remove-Item Env:\CLAUDE_CONFIG_DIR
                    Write-Host "Cleared active profile (was `"$ArgName`")"
                }
            } else {
                Write-Host 'Cancelled.'
            }
        }

        'skills' {
            $PoolDir = Get-CPSkillPoolDir
            if (-not (Test-CPPoolGuard)) { return }
            $Sub = if ($args.Count -gt 1) { $args[1] } else { $null }
            switch ($Sub) {
                'register' {
                    $SkillName = if ($args.Count -gt 2) { $args[2] } else { $null }
                    $SkillPath = if ($args.Count -gt 3) { $args[3] } else { $null }
                    if (-not $SkillName -or -not $SkillPath) {
                        _cp_die 'usage: claude-profile skills register <name> <path>'
                        return
                    }
                    if ($args.Count -gt 4) {
                        _cp_die "unexpected argument '$($args[4])'"
                        return
                    }
                    if (-not (_cp_validate_skill_name $SkillName)) { return }
                    if (-not (Test-Path -LiteralPath $SkillPath -PathType Container)) {
                        _cp_die "'$SkillPath' is not a directory"
                        return
                    }
                    if (-not (Test-Path -LiteralPath (Join-Path $SkillPath 'SKILL.md') -PathType Leaf)) {
                        _cp_die "'$SkillPath' does not contain a SKILL.md"
                        return
                    }
                    New-Item -ItemType Directory -Path $PoolDir -Force | Out-Null
                    $PoolEntry = Join-Path $PoolDir $SkillName
                    # Get-Item -Force sees dangling junctions too, which
                    # plain Test-Path resolves (to $false) and would let
                    # fall through to a misleading link-creation failure.
                    if (Get-Item -LiteralPath $PoolEntry -Force -ErrorAction SilentlyContinue) {
                        _cp_die "skill '$SkillName' is already registered"
                        return
                    }
                    $AbsPath = (Resolve-Path -LiteralPath $SkillPath).ProviderPath
                    if (-not (New-CPSkillLink -Source $AbsPath -Dest $PoolEntry)) {
                        _cp_die "could not create pool link for '$SkillName'"
                        return
                    }
                    Write-Host "Registered skill: $SkillName -> $AbsPath"
                    Write-Host "Run 'claude-profile skills sync --all' to link it into unfiltered profiles."
                }

                'unregister' {
                    $Rest = @($args | Select-Object -Skip 2)
                    $Force = $Rest -contains '--force'
                    $Names = @($Rest | Where-Object { $_ -ne '--force' })
                    foreach ($Token in $Names) {
                        if ("$Token".StartsWith('-')) {
                            _cp_die "unknown option '$Token'"
                            return
                        }
                    }
                    if ($Names.Count -ne 1) {
                        _cp_die 'usage: claude-profile skills unregister [--force] <name>'
                        return
                    }
                    $SkillName = $Names[0]
                    if (-not (_cp_validate_skill_name $SkillName)) { return }
                    $PoolEntry = Join-Path $PoolDir $SkillName
                    $Item = Get-Item -LiteralPath $PoolEntry -Force -ErrorAction SilentlyContinue
                    if (-not $Item) {
                        _cp_die "skill '$SkillName' is not registered"
                        return
                    }
                    if ($Item.LinkType) {
                        if (-not (Remove-CPSkillLink -Path $PoolEntry)) {
                            _cp_die "could not remove $PoolEntry"
                            return
                        }
                    } else {
                        if (-not $Force) {
                            _cp_die "'$SkillName' is a real directory in the pool; pass --force to delete it and its contents"
                            return
                        }
                        Remove-Item -LiteralPath $PoolEntry -Recurse -Force
                    }
                    foreach ($ProfileEntry in @(Get-ChildItem -Path $DataDir -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -ne 'skills' })) {
                        $Manifest = Join-Path $ProfileEntry.FullName 'skills.conf'
                        if ((Test-Path -LiteralPath $Manifest -PathType Leaf) -and
                            (@(Read-CPSkillManifest -Path $Manifest) -contains $SkillName)) {
                            _cp_die "note: profile '$($ProfileEntry.Name)' still lists '$SkillName' in skills.conf"
                        }
                    }
                    Write-Host "Unregistered skill: $SkillName"
                    Write-Host "Run 'claude-profile skills sync --all' to remove stale links from profiles."
                }

                { $_ -eq 'add' -or $_ -eq 'remove' } {
                    $Op = $Sub
                    $SkillName = if ($args.Count -gt 2) { $args[2] } else { $null }
                    $ProfileArg = if ($args.Count -gt 3) { $args[3] } else { $null }
                    if (-not $SkillName) {
                        _cp_die "usage: claude-profile skills $Op <skill> [profile]"
                        return
                    }
                    if ($args.Count -gt 4) {
                        _cp_die "unexpected argument '$($args[4])'"
                        return
                    }
                    if (-not (_cp_validate_skill_name $SkillName)) { return }
                    $ProfileName = _cp_skills_profile $ProfileArg
                    if (-not $ProfileName) { return }
                    if ($Op -eq 'add' -and
                        -not (Test-Path -LiteralPath (Join-Path $PoolDir $SkillName) -PathType Container)) {
                        _cp_die "skill '$SkillName' is not in the pool. Register it with: claude-profile skills register $SkillName <path>"
                        return
                    }
                    $Manifest = Join-Path (Join-Path $DataDir $ProfileName) 'skills.conf'
                    # Materialize the implicit "all pool skills" default first
                    # so add/remove edits stay sticky.
                    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
                        $All = @(Get-CPPoolSkills -PoolDir $PoolDir)
                        [System.IO.File]::WriteAllLines($Manifest, [string[]]$All)
                    }
                    $Current = @(Read-CPSkillManifest -Path $Manifest)
                    if ($Op -eq 'add') {
                        if ($Current -notcontains $SkillName) { $Current += $SkillName }
                    } else {
                        $Current = @($Current | Where-Object { $_ -ne $SkillName })
                    }
                    [System.IO.File]::WriteAllLines($Manifest, [string[]]$Current)
                    if (-not (Sync-CPProfileSkills -Name $ProfileName)) { return }
                    if ($Op -eq 'add') {
                        Write-Host "Added skill '$SkillName' to profile '$ProfileName'"
                    } else {
                        Write-Host "Removed skill '$SkillName' from profile '$ProfileName'"
                    }
                }

                'set' {
                    $ListArg = if ($args.Count -gt 2) { $args[2] } else { $null }
                    $ProfileArg = if ($args.Count -gt 3) { $args[3] } else { $null }
                    if (-not $ListArg) {
                        _cp_die 'usage: claude-profile skills set <skill1,skill2,...> [profile]'
                        return
                    }
                    if ($args.Count -gt 4) {
                        _cp_die "unexpected argument '$($args[4])'"
                        return
                    }
                    $ProfileName = _cp_skills_profile $ProfileArg
                    if (-not $ProfileName) { return }
                    $Names = @()
                    foreach ($SkillName in ($ListArg -split ',')) {
                        if (-not $SkillName) { continue }
                        if (-not (_cp_validate_skill_name $SkillName)) { return }
                        if (-not (Test-Path -LiteralPath (Join-Path $PoolDir $SkillName) -PathType Container)) {
                            _cp_die "warning: skill '$SkillName' is not in the pool"
                        }
                        $Names += $SkillName
                    }
                    $Manifest = Join-Path (Join-Path $DataDir $ProfileName) 'skills.conf'
                    [System.IO.File]::WriteAllLines($Manifest, [string[]]$Names)
                    if (-not (Sync-CPProfileSkills -Name $ProfileName)) { return }
                    Write-Host "Set skills for profile '$ProfileName'"
                }

                'reset' {
                    $ProfileArg = if ($args.Count -gt 2) { $args[2] } else { $null }
                    if ($args.Count -gt 3) {
                        _cp_die "unexpected argument '$($args[3])'"
                        return
                    }
                    $ProfileName = _cp_skills_profile $ProfileArg
                    if (-not $ProfileName) { return }
                    Remove-Item -LiteralPath (Join-Path (Join-Path $DataDir $ProfileName) 'skills.conf') -Force -ErrorAction SilentlyContinue
                    if (-not (Sync-CPProfileSkills -Name $ProfileName)) { return }
                    Write-Host "Profile '$ProfileName' reset to all pool skills"
                }

                'sync' {
                    $Target = if ($args.Count -gt 2) { $args[2] } else { $null }
                    if ($args.Count -gt 3) {
                        _cp_die "unexpected argument '$($args[3])'"
                        return
                    }
                    if ($Target -eq '--all') {
                        foreach ($ProfileEntry in @(Get-ChildItem -Path $DataDir -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -ne 'skills' })) {
                            Sync-CPProfileSkills -Name $ProfileEntry.Name | Out-Null
                            Write-Host "Synced profile '$($ProfileEntry.Name)'"
                        }
                    } else {
                        $ProfileName = _cp_skills_profile $Target
                        if (-not $ProfileName) { return }
                        if (-not (Sync-CPProfileSkills -Name $ProfileName)) { return }
                        Write-Host "Synced profile '$ProfileName'"
                    }
                }

                $null {
                    if (-not (Test-Path -LiteralPath $PoolDir -PathType Container)) {
                        Write-Host 'No skill pool yet. Register a skill with: claude-profile skills register <name> <path>'
                        return
                    }
                    $ProfileName = _cp_skills_profile $null
                    if (-not $ProfileName) { return }
                    $ProfileDir = Join-Path $DataDir $ProfileName
                    if (Test-Path -LiteralPath (Join-Path $ProfileDir 'skills.conf') -PathType Leaf) {
                        Write-Host "Profile '$ProfileName': skills.conf present (filtered)"
                    } else {
                        Write-Host "Profile '$ProfileName': no skills.conf (all pool skills)"
                    }
                    Write-Host "Skill pool: $PoolDir"
                    $Desired = @(Get-CPDesiredSkills -ProfileDir $ProfileDir -PoolDir $PoolDir)
                    $Pool = @(Get-CPPoolSkills -PoolDir $PoolDir)
                    if ($Pool.Count -eq 0) {
                        Write-Host '  (pool is empty)'
                        return
                    }
                    foreach ($SkillName in $Pool) {
                        $PoolEntry = Join-Path $PoolDir $SkillName
                        $Dest = Join-Path (Join-Path $ProfileDir 'skills') $SkillName
                        $DestItem = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
                        $Status = 'not linked'
                        if (-not (Test-Path -LiteralPath $PoolEntry -PathType Container)) {
                            $Status = 'dangling (target missing)'
                        } elseif ($DestItem) {
                            if (Test-CPManagedSkillLink -Path $Dest -PoolDir $PoolDir) {
                                $Status = 'linked'
                            } else {
                                $Status = 'conflict (unmanaged entry)'
                            }
                        } elseif ($Desired -contains $SkillName) {
                            $Status = 'selected, not linked (run sync)'
                        }
                        Write-Host ("  {0,-24} {1}" -f $SkillName, $Status)
                    }
                }

                default {
                    _cp_die "unknown skills command '$Sub'. Run 'claude-profile help' for usage."
                    return
                }
            }
        }

        'version' {
            Write-Host (Get-CPInstalledVersion)
        }

        'update' {
            $Force = $args -contains '--force'

            try {
                $resp = Invoke-RestMethod -Uri "$($Script:CPRepoApi)/releases/latest" -TimeoutSec 10 -ErrorAction Stop
            } catch {
                _cp_die 'update failed: could not reach GitHub'
                return
            }
            $latest = Get-CPTagVersion -Json ($resp | ConvertTo-Json -Compress)
            if (-not $latest) {
                _cp_die 'update failed: could not determine latest version'
                return
            }
            $tag = "v$latest"

            $installed = Get-CPInstalledVersion
            if (-not $Force -and $installed -ne 'unknown' -and -not (Test-CPVersionLessThan -A $installed -B $latest)) {
                _cp_die "already up to date (v$installed); latest is v$latest"
                return
            }

            $installDir = Get-CPInstallDir
            New-Item -ItemType Directory -Path $installDir -Force -ErrorAction SilentlyContinue | Out-Null
            # Temp dir is created INSIDE $installDir (not $env:TEMP) so the
            # final Move-Item below is guaranteed to be a same-volume,
            # atomic rename rather than a possible cross-volume copy+delete.
            $tmpDir = Join-Path $installDir ".update-$PID"
            try {
                New-Item -ItemType Directory -Path $tmpDir -Force -ErrorAction Stop | Out-Null
            } catch {
                _cp_die "update failed: could not create temp directory: $_"
                return
            }
            try {
                $assetBase = "$($Script:CPAssetBase)/$tag"
                try {
                    Invoke-WebRequest -Uri "$assetBase/SHA256SUMS" -OutFile (Join-Path $tmpDir 'SHA256SUMS') -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                    Invoke-WebRequest -Uri "$assetBase/VERSION" -OutFile (Join-Path $tmpDir 'VERSION') -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
                    Invoke-WebRequest -Uri "$assetBase/claude-profile-init.ps1" -OutFile (Join-Path $tmpDir 'claude-profile-init.ps1') -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                } catch {
                    _cp_die "update failed: download error: $_"
                    return
                }

                $sumsFile = Join-Path $tmpDir 'SHA256SUMS'
                if (-not (Test-CPChecksum -FilePath (Join-Path $tmpDir 'VERSION') -SumsPath $sumsFile)) {
                    _cp_die 'update failed: VERSION checksum mismatch'
                    return
                }
                if (-not (Test-CPChecksum -FilePath (Join-Path $tmpDir 'claude-profile-init.ps1') -SumsPath $sumsFile)) {
                    _cp_die 'update failed: claude-profile-init.ps1 checksum mismatch'
                    return
                }

                $downloadedVersion = (Get-Content (Join-Path $tmpDir 'VERSION') -Raw).Trim()
                if ($downloadedVersion -ne $latest) {
                    _cp_die "update failed: downloaded VERSION ($downloadedVersion) does not match release tag ($latest)"
                    return
                }

                try {
                    Move-Item -Path (Join-Path $tmpDir 'claude-profile-init.ps1') -Destination (Join-Path $installDir 'claude-profile-init.ps1') -Force -ErrorAction Stop
                    Move-Item -Path (Join-Path $tmpDir 'VERSION') -Destination (Join-Path $installDir 'VERSION') -Force -ErrorAction Stop
                } catch {
                    _cp_die "update failed: could not replace installed files: $_"
                    return
                }

                $installedDisplay = if ($installed -eq 'unknown') { 'unknown' } else { "v$installed" }
                Write-Host "Updating claude-profile-init.ps1: $installedDisplay -> v$latest"
                Write-Host "Done. Run '. `$PROFILE' (or restart PowerShell) to use the new version."
            } finally {
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        { $_ -eq 'help' -or $_ -eq '-h' -or $_ -eq '--help' } {
            Write-Host @"
Usage: claude-profile [command] [args...]

Commands:
    (no command)            Show current profile status
    use <name>              Switch session to the named profile (pins it)
    create <name>           Create a new profile
    list, ls                List all profiles
    default [name]          Get or set the default profile
    local [name]            Show, set (.claude-profile), or --remove the
                            directory-local profile for the current directory
    auto [on|off|status]    Control directory-local auto-switching
    which [name]            Show the resolved config directory path
    skills                  List pool skills and their status for the profile
    skills register <name> <path>
                            Add a skill directory to the shared pool
    skills unregister [--force] <name>
                            Remove a skill from the pool
    skills add <skill> [profile]
                            Add a pool skill to a profile
    skills remove <skill> [profile]
                            Remove a pool skill from a profile
    skills set <s1,s2,...> [profile]
                            Replace a profile's skill selection
    skills reset [profile]  Back to the default (all pool skills)
    skills sync [profile|--all]
                            Re-materialize skill links
    version                 Show the installed version
    update [--force]        Update to the latest release
    delete <name>           Delete a profile
    help, -h, --help        Show this help message

The claude command automatically uses the default profile. Use
'claude-profile use <name>' to override for the current session.

A directory containing a .claude-profile file (holding a profile name)
switches the session to that profile on Set-Location, and reverts on
leaving. An explicit 'claude-profile use' pins the session and wins over
any .claude-profile until 'claude-profile auto on'. Set
CLAUDE_PROFILE_NO_AUTO_SWITCH=1 to disable, CLAUDE_PROFILE_AUTO_QUIET=1
to switch silently.

Skills: a shared pool at <data-dir>\skills holds registered skills. A
profile's skills.conf (one name per line, # comments) selects the subset
linked into <profile>\skills; without one the profile gets every pool
skill. Hand-made entries in <profile>\skills are never touched.

Examples:
    claude-profile create work
    claude-profile skills register humanize C:\skills\humanize
    claude-profile skills set humanize,optimize work
    claude-profile default work
    claude-profile use work
    claude                          # runs with "work" profile
    claude-profile                  # shows active/default status
    claude-profile local work       # pin this directory tree to "work"
    claude-profile local --remove   # drop the directory-local profile
"@
        }

        $null {
            # Bare invocation: show status
            $Active = ''
            if ($env:CLAUDE_CONFIG_DIR) {
                $Normalized = $env:CLAUDE_CONFIG_DIR.Replace('\', '/')
                $NormalizedData = $DataDir.Replace('\', '/')
                if ($Normalized.StartsWith("$NormalizedData/")) {
                    $Active = Split-Path $env:CLAUDE_CONFIG_DIR -Leaf
                }
            }
            if ($Active) {
                $Dotfile = $null
                if ($env:CLAUDE_CONFIG_DIR -eq $env:CLAUDE_PROFILE_AUTO_SET) {
                    $Dotfile = Find-CPDotfile -StartDir (Get-CPCurrentFileSystemPath)
                }
                if ($Dotfile) {
                    Write-Host "Active profile: $Active (from $Dotfile)"
                } else {
                    Write-Host "Active profile: $Active"
                }
                Write-Host "Config directory: $env:CLAUDE_CONFIG_DIR"
            } elseif ($env:CLAUDE_CONFIG_DIR) {
                Write-Host "Active config directory: $env:CLAUDE_CONFIG_DIR (not a managed profile)"
            } else {
                Write-Host 'No active profile'
            }
            $CurDefault = ''
            if (Test-Path $DefaultFile) {
                $CurDefault = (Get-Content $DefaultFile -Raw).Trim()
            }
            if ($CurDefault) {
                Write-Host "Default profile: $CurDefault"
            } else {
                Write-Host 'No default profile set'
            }
            # Skills annotation for the active (else default) profile;
            # silent until a skill pool exists.
            $PoolDir = Get-CPSkillPoolDir
            if (Test-Path -LiteralPath $PoolDir -PathType Container) {
                $SkillProfile = if ($Active) { $Active } else { $CurDefault }
                if ($SkillProfile -and (Test-Path (Join-Path $DataDir $SkillProfile) -PathType Container)) {
                    $PoolCount = @(Get-CPPoolSkills -PoolDir $PoolDir).Count
                    $Manifest = Join-Path (Join-Path $DataDir $SkillProfile) 'skills.conf'
                    if (Test-Path -LiteralPath $Manifest -PathType Leaf) {
                        $SkillCount = @(Read-CPSkillManifest -Path $Manifest).Count
                        Write-Host "Skills: $SkillCount of $PoolCount pool skills (filtered)"
                    } else {
                        Write-Host "Skills: all pool skills ($PoolCount)"
                    }
                }
            }
        }

        default {
            _cp_die "unknown command '$Command'. Run 'claude-profile help' for usage."
            return
        }
    }
}
