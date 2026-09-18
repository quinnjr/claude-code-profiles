# Auto-Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a passive, opt-outable update-availability notice plus an explicit `claude-profile update` / `claude-profile version` command pair to all three implementations, backed by checksum-verified GitHub Release assets.

**Architecture:** Each of `claude-profile.sh`, `claude-profile-init.ps1`, `claude-profile.cmd` gains: (1) a `VERSION`-file reader + numeric version-compare helper, (2) a passive check hooked into the hot path (`claude()` for sh/ps1, command dispatch for cmd) that queries the GitHub Releases API at most once per 24h and caches the result atomically, (3) an `update` command that fetches `VERSION` + the matching script + a `SHA256SUMS` checksum file from **GitHub Release assets** (not the mutable `main` branch) and only replaces the installed files after the checksums verify and the fetched version is confirmed newer.

**Deliberate scope decision (read before implementing Task 8-10):** the design doc allowed either full GPG-signed-manifest verification or, as an explicit fallback, "pin against the release's commit SHA" if signing is deferred. This plan takes the fallback: release assets are checksummed via `SHA256SUMS` but not GPG-signed. This still closes the main attack this was meant to close (a reverted/tampered `main` branch can no longer be used to downgrade or substitute content, since release assets are immutable once published), without adding a hard `gpg` dependency that isn't reliably present on Windows/cmd. Full signature verification is a reasonable follow-up, not part of this plan.

**Tech Stack:** POSIX sh, PowerShell 5.1+/pwsh 6+, Windows cmd batch, curl, `sha256sum`/`shasum`/`certutil`/`Get-FileHash` (all already present on their respective platforms — no new hard dependencies).

**Testing note:** this repo has no automated test framework — verification is manual, per its own convention ("No build step. No test framework. Manual verification by running commands against real profiles."). Every task below replaces the usual "write failing test / implement / run test" cycle with "implement / manually verify with exact commands and expected output," plus `shellcheck`/`checkbashisms` where the project's own `## Checking Scripts` convention already calls for it.

**Rebase note (read before Task 2):** this plan was originally written against an older snapshot of `claude-profile.sh` and `claude-profile-init.ps1`. Two upstream changes landed since (PR #4 "fix(windows): fix profile name truncation in PS and validation in CMD", PR #10 "feat(shell): add --init flag to create command for settings skeleton") that this plan has been updated to account for:

1. `claude-profile-init.ps1` no longer has a `$Rest` variable — `claude-profile`'s dispatch now indexes `$args` directly (`$args[1]`, `$args[2]`, ...). Every ps1 snippet below already reflects this; if you see `$Rest` anywhere, that's stale and should be `$args`.
2. `claude-profile.sh` grew by ~60 lines from the `--init` flag feature, and `claude-profile.cmd`'s name-validation logic was simplified to a single `findstr` call. **Any absolute line number cited below may be off by a few lines** — every insertion point is also described by anchor text (a nearby comment, case label, or function name). Trust the anchor text, not the parenthetical line number, and use Read + Edit's exact-string matching rather than jumping to a line number.

---

## File Structure

| File | Change |
|---|---|
| `VERSION` (new, repo root) | Source-of-truth version string, bumped alongside git tags. |
| `scripts/make-release-checksums.sh` (new) | Maintainer-only tool: prints `SHA256SUMS` for `VERSION` + the three scripts. Run when cutting a release; output is uploaded as a release asset. |
| `claude-profile.sh` | Version helpers, passive check hooked into `claude()`, `update`/`version` subcommands. |
| `claude-profile-init.ps1` | Same, PowerShell equivalents. |
| `claude-profile.cmd` | Same, batch equivalents; passive check hooked into command dispatch (no wrapper exists here). |
| `install.sh` | Add download timeouts (pre-existing gap); download+write `VERSION` at install time. |
| `install.ps1` | Same. |
| `README.md` | Document `update`, `version`, the passive notice, and the opt-out env var. |

---

## Task 1: Foundation — repo VERSION file + release checksum script

**Files:**
- Create: `VERSION`
- Create: `scripts/make-release-checksums.sh`

- [ ] **Step 1: Create the repo-root VERSION file**

Content is exactly `1.0.0` with **no trailing newline** (matches the existing `.default` file convention used elsewhere in this repo).

```bash
printf '1.0.0' > VERSION
```

- [ ] **Step 2: Create the release checksum script**

```sh
#!/bin/sh
set -e
# Generates SHA256SUMS for the current repo's VERSION file and the three
# claude-profile scripts. Run from the repo root when cutting a release,
# then upload the output alongside VERSION/claude-profile.sh/
# claude-profile-init.ps1/claude-profile.cmd as GitHub Release assets.
#
# Usage: ./scripts/make-release-checksums.sh > SHA256SUMS

if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD="shasum -a 256"
else
    echo "error: sha256sum or shasum required" >&2
    exit 1
fi

for f in VERSION claude-profile.sh claude-profile-init.ps1 claude-profile.cmd; do
    if [ ! -f "$f" ]; then
        echo "error: $f not found in current directory (run from repo root)" >&2
        exit 1
    fi
    $SHA_CMD "$f"
done
```

- [ ] **Step 3: Make it executable and verify it runs**

```bash
chmod +x scripts/make-release-checksums.sh
./scripts/make-release-checksums.sh
```

Expected: four lines, each `<64-hex-char-hash>  <filename>`, one per file (`VERSION`, `claude-profile.sh`, `claude-profile-init.ps1`, `claude-profile.cmd`).

- [ ] **Step 4: Commit**

```bash
git add VERSION scripts/make-release-checksums.sh
git commit -m "feat(release): add VERSION file and release checksum script"
```

---

## Task 2: `claude-profile.sh` — version helpers + `version` command

**Files:**
- Modify: `claude-profile.sh`

- [ ] **Step 1: Add install-dir, version-read, and version-compare helpers**

Insert after the existing `_cp_validate_name` function (after line 70, before the `# --- claude() wrapper ---` comment):

```sh
# --- Version tracking helpers ---

# Resolves the tool's own install directory (singular "claude-profile",
# distinct from the plural "claude-profiles" data directory). Mirrors
# _cp_data_dir's MSYS handling.
_cp_install_dir() {
    if _cp_is_msys && [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "${LOCALAPPDATA}/claude-profile"
        return 0
    fi
    printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/claude-profile"
}

# Reads the installed VERSION file; prints "unknown" if missing/empty.
_cp_installed_version() {
    _cp_ver_file="$(_cp_install_dir)/VERSION"
    if [ -f "$_cp_ver_file" ]; then
        _cp_ver=$(cat "$_cp_ver_file")
        if [ -n "$_cp_ver" ]; then
            printf '%s\n' "$_cp_ver"
            return 0
        fi
    fi
    printf 'unknown\n'
}

# Numeric MAJOR.MINOR.PATCH comparison. Usage: _cp_version_lt A B
# Returns 0 (true, shell success) if A < B, 1 (false) otherwise.
# "unknown" is always considered less than any real version, and equal to
# itself.
_cp_version_lt() {
    _cp_vlt_a="$1"
    _cp_vlt_b="$2"
    if [ "$_cp_vlt_a" = "unknown" ]; then
        [ "$_cp_vlt_b" = "unknown" ] && return 1
        return 0
    fi
    [ "$_cp_vlt_b" = "unknown" ] && return 1
    _cp_vlt_a1=$(printf '%s' "$_cp_vlt_a" | cut -d. -f1)
    _cp_vlt_a2=$(printf '%s' "$_cp_vlt_a" | cut -d. -f2)
    _cp_vlt_a3=$(printf '%s' "$_cp_vlt_a" | cut -d. -f3)
    _cp_vlt_b1=$(printf '%s' "$_cp_vlt_b" | cut -d. -f1)
    _cp_vlt_b2=$(printf '%s' "$_cp_vlt_b" | cut -d. -f2)
    _cp_vlt_b3=$(printf '%s' "$_cp_vlt_b" | cut -d. -f3)
    _cp_vlt_a1=${_cp_vlt_a1:-0}; _cp_vlt_a2=${_cp_vlt_a2:-0}; _cp_vlt_a3=${_cp_vlt_a3:-0}
    _cp_vlt_b1=${_cp_vlt_b1:-0}; _cp_vlt_b2=${_cp_vlt_b2:-0}; _cp_vlt_b3=${_cp_vlt_b3:-0}
    [ "$_cp_vlt_a1" -lt "$_cp_vlt_b1" ] && return 0
    [ "$_cp_vlt_a1" -gt "$_cp_vlt_b1" ] && return 1
    [ "$_cp_vlt_a2" -lt "$_cp_vlt_b2" ] && return 0
    [ "$_cp_vlt_a2" -gt "$_cp_vlt_b2" ] && return 1
    [ "$_cp_vlt_a3" -lt "$_cp_vlt_b3" ] && return 0
    return 1
}
```

- [ ] **Step 2: Add the `version` case to `claude-profile()` dispatch**

Add immediately before the `help|-h|--help)` case:

```sh
        version)
            _cp_installed_version
            ;;

```

- [ ] **Step 3: Add `version` to the help text**

In the `help|-h|--help)` heredoc, add a line after `which [name]`:

```
    which [name]            Show the resolved config directory path
    version                 Show the installed version
    delete <name>           Delete a profile
```

(Replaces the existing `which [name]` / `delete <name>` two-line sequence with the three-line sequence above.)

- [ ] **Step 4: Manually verify the helpers**

```bash
sh -c '
. ./claude-profile.sh
_cp_version_lt 1.9.0 1.10.0; echo "1.9.0 < 1.10.0 -> $?"   # expect 0
_cp_version_lt 1.10.0 1.9.0; echo "1.10.0 < 1.9.0 -> $?"   # expect 1
_cp_version_lt 1.0.0 1.0.0;  echo "1.0.0 < 1.0.0  -> $?"   # expect 1
_cp_version_lt unknown 1.0.0; echo "unknown < 1.0.0 -> $?" # expect 0
_cp_version_lt 1.0.0 unknown; echo "1.0.0 < unknown -> $?" # expect 1
'
```

Expected output: `0`, `1`, `1`, `0`, `1` respectively.

- [ ] **Step 5: Manually verify `claude-profile version`**

```bash
mkdir -p /tmp/cp-test-install
printf '9.9.9' > /tmp/cp-test-install/VERSION
XDG_DATA_HOME=/tmp/cp-test-xdg sh -c '
. ./claude-profile.sh
_cp_install_dir() { printf "/tmp/cp-test-install\n"; }
claude-profile version
'
```

Expected: `9.9.9`

- [ ] **Step 6: Lint**

```bash
shellcheck claude-profile.sh
checkbashisms claude-profile.sh
```

Expected: no errors (the hyphenated `claude-profile()` function name warning from `checkbashisms`/`shellcheck` SC3033 is already expected/suppressed per existing project convention).

- [ ] **Step 7: Commit**

```bash
git add claude-profile.sh
git commit -m "feat(sh): add version tracking helpers and 'version' command"
```

---

## Task 3: `claude-profile-init.ps1` — version helpers + `version` command

**Files:**
- Modify: `claude-profile-init.ps1`

- [ ] **Step 1: Add script-scoped version helpers**

Insert after line 8 (the `#   claude-profile   — ...` comment), before the `# --- claude wrapper ---` comment:

```powershell
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

function Get-CPInstalledVersion {
    $versionFile = Join-Path (Get-CPInstallDir) 'VERSION'
    if (Test-Path $versionFile) {
        $v = (Get-Content $versionFile -Raw).Trim()
        if ($v) { return $v }
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
```

- [ ] **Step 2: Add the `version` case to `claude-profile`'s switch**

Add immediately before the `{ $_ -eq 'help' -or $_ -eq '-h' -or $_ -eq '--help' }` case:

```powershell
        'version' {
            Write-Host (Get-CPInstalledVersion)
        }

```

- [ ] **Step 3: Add `version` to the help text**

In the help here-string, add a line after `which [name]`:

```
    which [name]            Show the resolved config directory path
    version                 Show the installed version
    delete <name>           Delete a profile
```

- [ ] **Step 4: Manually verify**

```powershell
. ./claude-profile-init.ps1
Test-CPVersionLessThan -A '1.9.0' -B '1.10.0'   # expect True
Test-CPVersionLessThan -A '1.10.0' -B '1.9.0'   # expect False
Test-CPVersionLessThan -A 'unknown' -B '1.0.0'  # expect True
Test-CPVersionLessThan -A '1.0.0' -B 'unknown'  # expect False

$env:LOCALAPPDATA = '/tmp/cp-test-install'
New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA | Out-Null
Set-Content -Path (Join-Path $env:LOCALAPPDATA 'claude-profile/VERSION') -Value '9.9.9' -NoNewline -Force
New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'claude-profile') | Out-Null
Set-Content -Path (Join-Path $env:LOCALAPPDATA 'claude-profile/VERSION') -Value '9.9.9' -NoNewline
claude-profile version   # expect: 9.9.9
```

- [ ] **Step 5: Commit**

```bash
git add claude-profile-init.ps1
git commit -m "feat(ps1): add version tracking helpers and 'version' command"
```

---

## Task 4: `claude-profile.cmd` — version helpers + `version` command

**Files:**
- Modify: `claude-profile.cmd`

- [ ] **Step 1: Add install-dir/version constants**

After line 7 (`set "DEFAULT_FILE=%DATA_DIR%\.default"`), add:

```bat
:: --- Version tracking ---
set "_CP_INSTALL_DIR=%LOCALAPPDATA%\claude-profile"
set "_CP_VERSION_FILE=%_CP_INSTALL_DIR%\VERSION"
```

- [ ] **Step 2: Add `version` to the command dispatch**

After line 21 (`if "%~1"=="--help"  goto :usage`), add:

```bat
if "%~1"=="version" goto :dispatch_version
```

- [ ] **Step 3: Add the dispatch helper**

After the `:dispatch_delete` block (after line 60), add:

```bat
:dispatch_version
shift
goto :cmd_version
```

- [ ] **Step 4: Add the `version` command**

After `:cmd_default`'s `exit /b 0` (the block ending right before the `:cmd_which` label), add:

```bat
:cmd_version
set "_cv_installed=unknown"
if exist "%_CP_VERSION_FILE%" set /p _cv_installed=<"%_CP_VERSION_FILE%"
if "!_cv_installed!"=="" set "_cv_installed=unknown"
echo !_cv_installed!
exit /b 0
```

- [ ] **Step 5: Add `version` to the usage text**

In the `:usage` block, add a line after `which [name]`:

```bat
echo     which [name]            Show the resolved config directory path
echo     version                 Show the installed version
echo     delete ^<name^>           Delete a profile
```

- [ ] **Step 6: Manually verify (on Windows, or via `wine cmd.exe` / a Windows VM)**

```bat
mkdir %TEMP%\cp-test-install
echo|set /p="9.9.9">%TEMP%\cp-test-install\VERSION
set "LOCALAPPDATA=%TEMP%\cp-test-install-root"
mkdir %LOCALAPPDATA%\claude-profile
echo|set /p="9.9.9">%LOCALAPPDATA%\claude-profile\VERSION
call claude-profile.cmd version
```

Expected: `9.9.9`

- [ ] **Step 7: Commit**

```bash
git add claude-profile.cmd
git commit -m "feat(cmd): add version tracking and 'version' command"
```

---

## Task 5: `claude-profile.sh` — passive update check

**Files:**
- Modify: `claude-profile.sh`

- [ ] **Step 1: Add cache constants and the tag-extraction/cache helpers**

Insert after the version helpers added in Task 2 (after `_cp_version_lt`), before the `# --- claude() wrapper ---` comment:

```sh
# --- Passive update check ---

_CP_REPO_API="${CLAUDE_PROFILE_UPDATE_API_BASE:-https://api.github.com/repos/quinnjr/claude-code-profiles}"
_CP_UPDATE_INTERVAL="${CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL:-86400}"

# Extracts and validates a "vX.Y.Z" tag_name from a GitHub releases-API JSON
# response body. Prints the version WITHOUT the leading 'v' on success;
# prints nothing on failure (missing field or doesn't match X.Y.Z).
_cp_extract_tag_version() {
    _cp_etv_tag=$(printf '%s' "$1" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)
    _cp_etv_tag=${_cp_etv_tag#v}
    case "$_cp_etv_tag" in
        [0-9]*.[0-9]*.[0-9]*)
            case "$_cp_etv_tag" in
                *[!0-9.]*) return 1 ;;
            esac
            printf '%s\n' "$_cp_etv_tag"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Reads the update-check cache file into _cp_cache_ts / _cp_cache_ver /
# _cp_cache_notified globals. Defaults (0 / unknown / 0) on missing or
# unparseable cache — treated identically, per design, so a corrupted file
# self-heals on the next successful write instead of erroring.
_cp_read_update_cache() {
    _cp_cache_ts=0
    _cp_cache_ver="unknown"
    _cp_cache_notified=0
    _cp_cache_file="$(_cp_install_dir)/.update-check"
    [ -f "$_cp_cache_file" ] || return 0
    _cp_line_n=0
    while IFS= read -r _cp_field; do
        _cp_line_n=$((_cp_line_n + 1))
        case "$_cp_line_n" in
            1) case "$_cp_field" in *[!0-9]*|'') ;; *) _cp_cache_ts="$_cp_field" ;; esac ;;
            2) [ -n "$_cp_field" ] && _cp_cache_ver="$_cp_field" ;;
            3) case "$_cp_field" in 0|1) _cp_cache_notified="$_cp_field" ;; esac ;;
        esac
    done < "$_cp_cache_file"
    return 0
}

# Writes the cache atomically (temp file + rename), so concurrent
# invocations can't torn-write it. Usage: _cp_write_update_cache TS VER NOTIFIED
_cp_write_update_cache() {
    _cp_wuc_dir="$(_cp_install_dir)"
    mkdir -p "$_cp_wuc_dir" 2>/dev/null || return 1
    _cp_wuc_file="${_cp_wuc_dir}/.update-check"
    _cp_wuc_tmp="${_cp_wuc_file}.tmp.$$"
    printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$_cp_wuc_tmp" 2>/dev/null || return 1
    mv -f "$_cp_wuc_tmp" "$_cp_wuc_file" 2>/dev/null || { rm -f "$_cp_wuc_tmp" 2>/dev/null; return 1; }
    return 0
}

# Runs the passive update check, rate-limited to once per
# CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL seconds (default 24h). Prints a
# one-line stderr notice the first time a newer version is seen. Every
# failure path is a silent no-op — this must never block or break claude().
_cp_update_check() {
    [ -n "${CLAUDE_PROFILE_NO_UPDATE_CHECK:-}" ] && return 0
    command -v curl >/dev/null 2>&1 || return 0

    _cp_read_update_cache

    _cp_now=$(date +%s 2>/dev/null) || return 0
    _cp_elapsed=$((_cp_now - _cp_cache_ts))

    if [ "$_cp_elapsed" -ge "$_CP_UPDATE_INTERVAL" ]; then
        _cp_resp=$(curl -fsSL --connect-timeout 3 --max-time 3 "${_CP_REPO_API}/releases/latest" 2>/dev/null)
        _cp_new_ver="$_cp_cache_ver"
        if [ -n "$_cp_resp" ]; then
            _cp_extracted=$(_cp_extract_tag_version "$_cp_resp")
            [ -n "$_cp_extracted" ] && _cp_new_ver="$_cp_extracted"
        fi
        if [ "$_cp_new_ver" != "$_cp_cache_ver" ]; then
            _cp_write_update_cache "$_cp_now" "$_cp_new_ver" 0
            _cp_cache_ver="$_cp_new_ver"
            _cp_cache_notified=0
        else
            _cp_write_update_cache "$_cp_now" "$_cp_cache_ver" "$_cp_cache_notified"
        fi
    fi

    if [ "$_cp_cache_notified" = "0" ] && [ "$_cp_cache_ver" != "unknown" ]; then
        _cp_installed=$(_cp_installed_version)
        if _cp_version_lt "$_cp_installed" "$_cp_cache_ver"; then
            printf "A new claude-profile version is available (v%s -> v%s). Run 'claude-profile update' to upgrade.\\n" \
                "$_cp_installed" "$_cp_cache_ver" >&2
            _cp_write_update_cache "$_cp_now" "$_cp_cache_ver" 1
        fi
    fi
    return 0
}
```

- [ ] **Step 2: Hook the check into `claude()`**

Modify the start of `claude()` (currently line 77) from:

```sh
claude() {
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
```

to:

```sh
claude() {
    _cp_update_check
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
```

- [ ] **Step 3: Manually verify the tag-extraction helper**

```bash
sh -c '
. ./claude-profile.sh
_cp_extract_tag_version "{\"tag_name\":\"v1.2.3\",\"name\":\"Release 1.2.3\"}"
echo "exit=$?"
_cp_extract_tag_version "{\"tag_name\":\"garbage\"}"
echo "exit=$?ドexpect nonzero, no output above"
'
```

Expected: first call prints `1.2.3` and `exit=0`; second call prints nothing and `exit` is nonzero.

- [ ] **Step 4: Manually verify the cache read/write round-trip and atomic write**

```bash
XDG_DATA_HOME=/tmp/cp-test-xdg2 sh -c '
. ./claude-profile.sh
_cp_write_update_cache 1000 1.2.3 0
_cp_read_update_cache
echo "$_cp_cache_ts $_cp_cache_ver $_cp_cache_notified"   # expect: 1000 1.2.3 0
cat "$(_cp_install_dir)/.update-check"                     # expect 3 lines: 1000 / 1.2.3 / 0
'
```

- [ ] **Step 5: Manually verify the opt-out and the full notice path using a stubbed curl**

```bash
mkdir -p /tmp/cp-fake-bin
cat > /tmp/cp-fake-bin/curl <<'EOF'
#!/bin/sh
echo '{"tag_name":"v9.9.9"}'
EOF
chmod +x /tmp/cp-fake-bin/curl

# Opt-out: no output, no cache file written
CLAUDE_PROFILE_NO_UPDATE_CHECK=1 XDG_DATA_HOME=/tmp/cp-test-xdg3 PATH="/tmp/cp-fake-bin:$PATH" sh -c '
. ./claude-profile.sh
_cp_update_check
'
ls /tmp/cp-test-xdg3/claude-profile/.update-check 2>&1   # expect: No such file or directory

# Notice fires once, then stays quiet on a second call
rm -rf /tmp/cp-test-xdg4
XDG_DATA_HOME=/tmp/cp-test-xdg4 PATH="/tmp/cp-fake-bin:$PATH" sh -c '
. ./claude-profile.sh
_cp_update_check   # expect: stderr notice v unknown -> v9.9.9
_cp_update_check   # expect: no output (already notified)
'
```

- [ ] **Step 6: Lint**

```bash
shellcheck claude-profile.sh
checkbashisms claude-profile.sh
```

- [ ] **Step 7: Commit**

```bash
git add claude-profile.sh
git commit -m "feat(sh): add passive update-check hooked into claude()"
```

---

## Task 6: `claude-profile-init.ps1` — passive update check

**Files:**
- Modify: `claude-profile-init.ps1`

- [ ] **Step 1: Add cache + check helpers**

Insert after the version helpers added in Task 3, before the `# --- claude wrapper ---` comment:

```powershell
# --- Passive update check ---

$Script:CPRepoApi = if ($env:CLAUDE_PROFILE_UPDATE_API_BASE) { $env:CLAUDE_PROFILE_UPDATE_API_BASE } else { 'https://api.github.com/repos/quinnjr/claude-code-profiles' }
$Script:CPUpdateInterval = if ($env:CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL) { [long]$env:CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL } else { 86400 }

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
    } catch {
        Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CPUpdateCheck {
    if ($env:CLAUDE_PROFILE_NO_UPDATE_CHECK) { return }
    try {
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
                Write-CPUpdateCache -Timestamp $now -Version $newVer -Notified 0
                $cache.Version = $newVer
                $cache.Notified = 0
            } else {
                Write-CPUpdateCache -Timestamp $now -Version $cache.Version -Notified $cache.Notified
            }
        }

        if ($cache.Notified -eq 0 -and $cache.Version -ne 'unknown') {
            $installed = Get-CPInstalledVersion
            if (Test-CPVersionLessThan -A $installed -B $cache.Version) {
                $host.UI.WriteErrorLine("A new claude-profile version is available (v$installed -> v$($cache.Version)). Run 'claude-profile update' to upgrade.")
                Write-CPUpdateCache -Timestamp $now -Version $cache.Version -Notified 1
            }
        }
    } catch {
        # Never let the update check break claude() startup.
    }
}
```

- [ ] **Step 2: Hook the check into `claude`**

Modify the start of `function claude {` (currently line 15) from:

```powershell
function claude {
    if (-not $env:CLAUDE_CONFIG_DIR) {
```

to:

```powershell
function claude {
    Invoke-CPUpdateCheck
    if (-not $env:CLAUDE_CONFIG_DIR) {
```

- [ ] **Step 3: Manually verify `Get-CPTagVersion`**

```powershell
. ./claude-profile-init.ps1
Get-CPTagVersion -Json '{"tag_name":"v1.2.3"}'   # expect: 1.2.3
Get-CPTagVersion -Json '{"tag_name":"garbage"}'  # expect: (nothing / $null)
```

- [ ] **Step 4: Manually verify cache round-trip**

```powershell
$env:XDG_DATA_HOME = '/tmp/cp-test-xdg-ps1'
Write-CPUpdateCache -Timestamp 1000 -Version '1.2.3' -Notified 0
$c = Read-CPUpdateCache
"$($c.Timestamp) $($c.Version) $($c.Notified)"   # expect: 1000 1.2.3 0
```

- [ ] **Step 5: Manually verify opt-out and once-per-version notice**

```powershell
$env:CLAUDE_PROFILE_NO_UPDATE_CHECK = '1'
Invoke-CPUpdateCheck
Remove-Item Env:\CLAUDE_PROFILE_NO_UPDATE_CHECK

# Fake a cached "newer version known" state directly, bypassing the network
$env:XDG_DATA_HOME = '/tmp/cp-test-xdg-ps1-2'
Write-CPUpdateCache -Timestamp ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Version '9.9.9' -Notified 0
Invoke-CPUpdateCheck   # expect: stderr notice (unknown -> 9.9.9)
Invoke-CPUpdateCheck   # expect: no output (already notified)
```

- [ ] **Step 6: Commit**

```bash
git add claude-profile-init.ps1
git commit -m "feat(ps1): add passive update-check hooked into claude"
```

---

## Task 7: `claude-profile.cmd` — passive update check

**Files:**
- Modify: `claude-profile.cmd`

- [ ] **Step 1: Add cache/interval constants**

After the `_CP_VERSION_FILE` line added in Task 4, add:

```bat
set "_CP_UPDATE_CACHE=%_CP_INSTALL_DIR%\.update-check"
set "_CP_REPO_API=https://api.github.com/repos/quinnjr/claude-code-profiles"
if not defined _CP_REPO_API_OVERRIDE (rem no-op, placeholder for readability)
if defined CLAUDE_PROFILE_UPDATE_API_BASE set "_CP_REPO_API=%CLAUDE_PROFILE_UPDATE_API_BASE%"
set "_CP_UPDATE_INTERVAL=86400"
if defined CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL set "_CP_UPDATE_INTERVAL=%CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL%"
```

- [ ] **Step 2: Call the check unconditionally at the top of the dispatcher**

Immediately after the `:: --- Dispatcher ---` comment (before line 10's `if "%~1"=="" goto :cmd_launch_default`), add:

```bat
call :cp_update_check
```

- [ ] **Step 3: Add the helper subroutines**

Add these new labels after `:dispatch_version`'s `goto :cmd_version` (from Task 4), before the `:: --- Usage ---` comment:

```bat
:get_epoch
:: cmd has no native epoch-time support; PowerShell ships with every
:: supported Windows version, so shell out to it rather than reinventing
:: date arithmetic in batch.
set "_cp_epoch="
for /f %%e in ('powershell -NoProfile -Command "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()" 2^>nul') do set "_cp_epoch=%%e"
if not defined _cp_epoch set "_cp_epoch=0"
goto :eof

:: extract_tag_version <raw findstr line containing "tag_name":"..."> ->
:: sets _cp_tag_version (without leading v) on success, leaves it undefined
:: on failure.
:extract_tag_version
set "_cp_tag_version="
set "_etv_line=%~1"
for /f "tokens=2 delims=:" %%v in ("!_etv_line!") do set "_etv_raw=%%v"
set "_etv_raw=!_etv_raw:"=!"
set "_etv_raw=!_etv_raw: =!"
set "_etv_raw=!_etv_raw:,=!"
if "!_etv_raw:~0,1!"=="v" set "_etv_raw=!_etv_raw:~1!"
echo !_etv_raw!| findstr /R "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul 2>&1
if not errorlevel 1 set "_cp_tag_version=!_etv_raw!"
goto :eof

:: version_lt <a> <b> -> errorlevel 0 if a<b, 1 otherwise.
:: "unknown" is always < any real version, and equal to itself.
:version_lt
set "_vlt_a=%~1"
set "_vlt_b=%~2"
if "!_vlt_a!"=="unknown" (
    if "!_vlt_b!"=="unknown" (exit /b 1) else (exit /b 0)
)
if "!_vlt_b!"=="unknown" exit /b 1
for /f "tokens=1-3 delims=." %%x in ("!_vlt_a!") do (set "_vlt_a1=%%x" & set "_vlt_a2=%%y" & set "_vlt_a3=%%z")
for /f "tokens=1-3 delims=." %%x in ("!_vlt_b!") do (set "_vlt_b1=%%x" & set "_vlt_b2=%%y" & set "_vlt_b3=%%z")
if !_vlt_a1! lss !_vlt_b1! exit /b 0
if !_vlt_a1! gtr !_vlt_b1! exit /b 1
if !_vlt_a2! lss !_vlt_b2! exit /b 0
if !_vlt_a2! gtr !_vlt_b2! exit /b 1
if !_vlt_a3! lss !_vlt_b3! exit /b 0
exit /b 1

:: write_update_cache <epoch> <version> <notified> — atomic via temp+rename
:write_update_cache
if not exist "%_CP_INSTALL_DIR%" mkdir "%_CP_INSTALL_DIR%" >nul 2>&1
set "_wuc_tmp=%_CP_UPDATE_CACHE%.tmp.%RANDOM%"
(
    echo %~1
    echo %~2
    echo %~3
)>"!_wuc_tmp!" 2>nul
if exist "!_wuc_tmp!" move /y "!_wuc_tmp!" "%_CP_UPDATE_CACHE%" >nul 2>&1
goto :eof

:cp_update_check
if defined CLAUDE_PROFILE_NO_UPDATE_CHECK goto :eof
where curl >nul 2>&1
if errorlevel 1 goto :eof

set "_cpu_ts=0"
set "_cpu_ver=unknown"
set "_cpu_notified=0"
if exist "%_CP_UPDATE_CACHE%" (
    set "_cpu_line=0"
    for /f "usebackq delims=" %%L in ("%_CP_UPDATE_CACHE%") do (
        set /a _cpu_line+=1
        if "!_cpu_line!"=="1" set "_cpu_ts=%%L"
        if "!_cpu_line!"=="2" set "_cpu_ver=%%L"
        if "!_cpu_line!"=="3" set "_cpu_notified=%%L"
    )
)

call :get_epoch
set /a _cpu_elapsed=_cp_epoch-_cpu_ts

if !_cpu_elapsed! geq !_CP_UPDATE_INTERVAL! (
    set "_cpu_resp_file=%TEMP%\cp-release-%RANDOM%.json"
    curl -fsSL --connect-timeout 3 --max-time 3 -o "!_cpu_resp_file!" "%_CP_REPO_API%/releases/latest" >nul 2>&1
    set "_cpu_new_ver=!_cpu_ver!"
    if exist "!_cpu_resp_file!" (
        set "_cpu_tagline="
        for /f "usebackq delims=" %%T in (`findstr /R "\"tag_name\"" "!_cpu_resp_file!"`) do set "_cpu_tagline=%%T"
        del /f /q "!_cpu_resp_file!" >nul 2>&1
        if defined _cpu_tagline (
            call :extract_tag_version "!_cpu_tagline!"
            if defined _cp_tag_version set "_cpu_new_ver=!_cp_tag_version!"
        )
    )
    if not "!_cpu_new_ver!"=="!_cpu_ver!" (
        call :write_update_cache "!_cp_epoch!" "!_cpu_new_ver!" "0"
        set "_cpu_ver=!_cpu_new_ver!"
        set "_cpu_notified=0"
    ) else (
        call :write_update_cache "!_cp_epoch!" "!_cpu_ver!" "!_cpu_notified!"
    )
)

if "!_cpu_notified!"=="0" if not "!_cpu_ver!"=="unknown" (
    set "_cpu_installed=unknown"
    if exist "%_CP_VERSION_FILE%" set /p _cpu_installed=<"%_CP_VERSION_FILE%"
    if "!_cpu_installed!"=="" set "_cpu_installed=unknown"
    call :version_lt "!_cpu_installed!" "!_cpu_ver!"
    if not errorlevel 1 (
        echo A new claude-profile version is available ^(v!_cpu_installed! -^> v!_cpu_ver!^). Run 'claude-profile update' to upgrade. >&2
        call :write_update_cache "!_cp_epoch!" "!_cpu_ver!" "1"
    )
)
goto :eof
```

- [ ] **Step 4: Manually verify each helper in isolation (Windows or Windows VM required)**

```bat
call claude-profile.cmd version
echo Sanity: script still runs after adding cp_update_check
```

```bat
:: extract_tag_version
call :extract_tag_version "  \"tag_name\": \"v1.2.3\","
echo !_cp_tag_version!
```
(Run this from a modified copy of the script with an `echo` added, or step through with `echo on`, since `:extract_tag_version` isn't directly callable from outside the script.)

Expected: `1.2.3`

```bat
call claude-profile.cmd version
:: (fresh cache) run once, confirm .update-check now has 3 lines
type "%LOCALAPPDATA%\claude-profile\.update-check"
```

- [ ] **Step 5: Manually verify opt-out**

```bat
set "CLAUDE_PROFILE_NO_UPDATE_CHECK=1"
del /f /q "%LOCALAPPDATA%\claude-profile\.update-check" 2>nul
call claude-profile.cmd version
if exist "%LOCALAPPDATA%\claude-profile\.update-check" (echo FAIL: cache written despite opt-out) else (echo PASS: no cache written)
set "CLAUDE_PROFILE_NO_UPDATE_CHECK="
```

- [ ] **Step 6: Commit**

```bash
git add claude-profile.cmd
git commit -m "feat(cmd): add passive update-check hooked into command dispatch"
```

---

## Task 8: `claude-profile.sh` — `update` command

**Files:**
- Modify: `claude-profile.sh`

- [ ] **Step 1: Add the asset-base constant and checksum-verify helper**

Add next to `_CP_REPO_API` (from Task 5):

```sh
_CP_ASSET_BASE="${CLAUDE_PROFILE_UPDATE_ASSET_BASE:-https://github.com/quinnjr/claude-code-profiles/releases/download}"
```

Add after `_cp_extract_tag_version` (from Task 5):

```sh
# Verifies a downloaded file's SHA-256 against a SHA256SUMS file. Usage:
# _cp_verify_checksum <file> <sums-file>. Requires $_cp_sha_cmd to be set by
# the caller (sha256sum or "shasum -a 256").
_cp_verify_checksum() {
    _cp_vc_file="$1"
    _cp_vc_sums="$2"
    _cp_vc_name=$(basename "$_cp_vc_file")
    _cp_vc_expected=$(grep -F " ${_cp_vc_name}" "$_cp_vc_sums" 2>/dev/null | awk '{print $1}' | head -n1)
    [ -n "$_cp_vc_expected" ] || return 1
    _cp_vc_actual=$($_cp_sha_cmd "$_cp_vc_file" | awk '{print $1}')
    [ "$_cp_vc_expected" = "$_cp_vc_actual" ]
}
```

- [ ] **Step 2: Add the `update` command function**

Add after `_cp_verify_checksum`:

```sh
# Fetches, checksum-verifies, and atomically replaces claude-profile.sh (and
# the shared VERSION file) from the latest GitHub release. Exit status 0 on
# success, 1 on any failure — never leaves a partial install in place.
#
# NOTE: deliberately does NOT use `trap ... EXIT` for temp-dir cleanup.
# claude-profile.sh is sourced into a long-lived interactive shell, so a
# trap set here would persist for the rest of the shell session and fire
# at the wrong time. Cleanup is instead explicit at every return point,
# matching this file's existing "no set -e" / no-trap discipline.
_cp_do_update() {
    _cp_upd_force=0
    case "${1:-}" in
        --force) _cp_upd_force=1 ;;
        "") : ;;
        *) _cp_die "usage: claude-profile update [--force]"; return 1 ;;
    esac

    command -v curl >/dev/null 2>&1 || { _cp_die "update requires curl"; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        _cp_sha_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        _cp_sha_cmd="shasum -a 256"
    else
        _cp_die "update requires sha256sum or shasum"
        return 1
    fi

    _cp_upd_resp=$(curl -fsSL --connect-timeout 10 --max-time 30 "${_CP_REPO_API}/releases/latest" 2>/dev/null) || {
        _cp_die "update failed: could not reach GitHub"
        return 1
    }
    _cp_upd_tag=$(printf '%s' "$_cp_upd_resp" | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)
    if [ -z "$_cp_upd_tag" ]; then
        _cp_die "update failed: could not determine latest version"
        return 1
    fi
    _cp_upd_latest="${_cp_upd_tag#v}"
    case "$_cp_upd_latest" in
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) _cp_die "update failed: unexpected version format from GitHub"; return 1 ;;
    esac

    _cp_upd_installed=$(_cp_installed_version)
    if [ "$_cp_upd_force" -eq 0 ] && [ "$_cp_upd_installed" != "unknown" ] \
        && ! _cp_version_lt "$_cp_upd_installed" "$_cp_upd_latest"; then
        _cp_die "already up to date (v${_cp_upd_installed}); latest is v${_cp_upd_latest}"
        return 1
    fi

    _cp_upd_tmpdir=$(mktemp -d) || { _cp_die "update failed: could not create temp directory"; return 1; }
    _cp_upd_base="${_CP_ASSET_BASE}/${_cp_upd_tag}"

    if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "${_cp_upd_tmpdir}/SHA256SUMS" "${_cp_upd_base}/SHA256SUMS" 2>/dev/null; then
        _cp_die "update failed: could not download checksums"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi
    if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "${_cp_upd_tmpdir}/VERSION" "${_cp_upd_base}/VERSION" 2>/dev/null; then
        _cp_die "update failed: could not download VERSION"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "${_cp_upd_tmpdir}/claude-profile.sh" "${_cp_upd_base}/claude-profile.sh" 2>/dev/null; then
        _cp_die "update failed: could not download claude-profile.sh"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi

    if ! _cp_verify_checksum "${_cp_upd_tmpdir}/VERSION" "${_cp_upd_tmpdir}/SHA256SUMS"; then
        _cp_die "update failed: VERSION checksum mismatch"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi
    if ! _cp_verify_checksum "${_cp_upd_tmpdir}/claude-profile.sh" "${_cp_upd_tmpdir}/SHA256SUMS"; then
        _cp_die "update failed: claude-profile.sh checksum mismatch"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi

    _cp_upd_downloaded_version=$(cat "${_cp_upd_tmpdir}/VERSION")
    if [ "$_cp_upd_downloaded_version" != "$_cp_upd_latest" ]; then
        _cp_die "update failed: downloaded VERSION (${_cp_upd_downloaded_version}) does not match release tag (${_cp_upd_latest})"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi

    _cp_upd_install="$(_cp_install_dir)"
    mkdir -p "$_cp_upd_install" || { _cp_die "update failed: could not create install directory"; rm -rf "$_cp_upd_tmpdir"; return 1; }
    if ! mv -f "${_cp_upd_tmpdir}/claude-profile.sh" "${_cp_upd_install}/claude-profile.sh"; then
        _cp_die "update failed: could not replace claude-profile.sh"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi
    mv -f "${_cp_upd_tmpdir}/VERSION" "${_cp_upd_install}/VERSION"
    rm -rf "$_cp_upd_tmpdir"

    printf 'Updating claude-profile.sh: v%s -> v%s\n' "$_cp_upd_installed" "$_cp_upd_latest"
    printf "Done. Run 'source ~/.bashrc' (or restart your shell) to use the new version.\\n"
    return 0
}
```

- [ ] **Step 3: Wire `update` into `claude-profile()` dispatch**

Add next to the `version)` case added in Task 2:

```sh
        update)
            shift
            _cp_do_update "${1:-}"
            ;;

```

- [ ] **Step 4: Add `update` to the help text**

Add a line to the heredoc after `version`:

```
    version                 Show the installed version
    update [--force]        Update to the latest release
    delete <name>           Delete a profile
```

- [ ] **Step 5: Manually verify the failure paths against a local fixture (no real release needed)**

```bash
mkdir -p /tmp/cp-fixture/v9.9.9
cd /tmp/cp-fixture/v9.9.9
printf '9.9.9' > VERSION
cp /path/to/repo/claude-profile.sh .
sha256sum VERSION claude-profile.sh > SHA256SUMS
python3 -m http.server 8123 &
HTTPD_PID=$!

mkdir -p /tmp/cp-fixture-api
cat > /tmp/cp-fixture-api/releases_latest <<'EOF'
{"tag_name":"v9.9.9"}
EOF
cd /tmp/cp-fixture-api && python3 -m http.server 8124 &
API_PID=$!
cd -

# Point the update command at the local fixture instead of GitHub:
XDG_DATA_HOME=/tmp/cp-test-update sh -c '
export CLAUDE_PROFILE_UPDATE_API_BASE="http://127.0.0.1:8124"
. ./claude-profile.sh
# The fixture server has no real "/repos/.../releases/latest" path, so
# curl this directly to confirm the API-base override works, then adjust
# the fixture path/served file names to match before testing update end
# to end; primarily this validates URL construction and checksum logic.
'

kill $HTTPD_PID $API_PID
```

Since a full end-to-end run requires either a real GitHub release or a fixture server whose path layout exactly matches `/repos/.../releases/latest` and `/releases/download/<tag>/<file>`, the practical verification for this task is:
1. Confirm the checksum-mismatch failure path: corrupt one byte in a fixture's `SHA256SUMS` and confirm `_cp_do_update` reports `"VERSION checksum mismatch"` or `"claude-profile.sh checksum mismatch"` and leaves the installed files untouched.
2. Confirm the downgrade-blocked path: with `_cp_upd_installed` set higher than the fixture's version, confirm `_cp_do_update` reports `"already up to date"` and returns 1.
3. Defer the full happy-path (real download + real install swap) to Task 13, after the first real release tagged under this plan exists.

- [ ] **Step 6: Lint**

```bash
shellcheck claude-profile.sh
checkbashisms claude-profile.sh
```

- [ ] **Step 7: Commit**

```bash
git add claude-profile.sh
git commit -m "feat(sh): add 'update' command with checksum-verified atomic replace"
```

---

## Task 9: `claude-profile-init.ps1` — `update` command

**Files:**
- Modify: `claude-profile-init.ps1`

- [ ] **Step 1: Add the asset-base constant and checksum-verify helper**

Add next to `$Script:CPRepoApi` (from Task 6):

```powershell
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
```

- [ ] **Step 2: Add the `update` case to `claude-profile`'s switch**

Add next to the `'version'` case added in Task 3:

```powershell
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

            $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "claude-profile-update-$PID"
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
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

                $installDir = Get-CPInstallDir
                New-Item -ItemType Directory -Path $installDir -Force -ErrorAction SilentlyContinue | Out-Null
                Move-Item -Path (Join-Path $tmpDir 'claude-profile-init.ps1') -Destination (Join-Path $installDir 'claude-profile-init.ps1') -Force
                Move-Item -Path (Join-Path $tmpDir 'VERSION') -Destination (Join-Path $installDir 'VERSION') -Force

                Write-Host "Updating claude-profile-init.ps1: v$installed -> v$latest"
                Write-Host "Done. Run '. `$PROFILE' (or restart PowerShell) to use the new version."
            } finally {
                Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

```

- [ ] **Step 3: Add `update` to the help text**

```
    version                 Show the installed version
    update [--force]        Update to the latest release
    delete <name>           Delete a profile
```

- [ ] **Step 4: Manually verify checksum matching**

```powershell
Set-Content -Path /tmp/cp-ps1-test.txt -Value 'hello'
$hash = (Get-FileHash /tmp/cp-ps1-test.txt -Algorithm SHA256).Hash
Set-Content -Path /tmp/cp-ps1-test.sums -Value "$hash  cp-ps1-test.txt"
Test-CPChecksum -FilePath /tmp/cp-ps1-test.txt -SumsPath /tmp/cp-ps1-test.sums   # expect: True
Set-Content -Path /tmp/cp-ps1-test.sums -Value "0000000000000000000000000000000000000000000000000000000000000000  cp-ps1-test.txt"
Test-CPChecksum -FilePath /tmp/cp-ps1-test.txt -SumsPath /tmp/cp-ps1-test.sums   # expect: False
```

- [ ] **Step 5: Manually verify the downgrade-blocked path**

```powershell
$env:LOCALAPPDATA = '/tmp/cp-ps1-installed'
New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'claude-profile') | Out-Null
Set-Content -Path (Join-Path $env:LOCALAPPDATA 'claude-profile/VERSION') -Value '99.0.0' -NoNewline
# Then run `claude-profile update` (requires network / a real or fixture
# release) and confirm it reports "already up to date" without touching
# the installed files, per the same fixture-server approach as Task 8.
```

Defer the full happy-path to Task 13, same rationale as Task 8.

- [ ] **Step 6: Commit**

```bash
git add claude-profile-init.ps1
git commit -m "feat(ps1): add 'update' command with checksum-verified atomic replace"
```

---

## Task 10: `claude-profile.cmd` — `update` command

**Files:**
- Modify: `claude-profile.cmd`

- [ ] **Step 1: Add asset-base override support**

Next to `_CP_REPO_API` (from Task 7), add:

```bat
set "_CP_ASSET_BASE=https://github.com/quinnjr/claude-code-profiles/releases/download"
if defined CLAUDE_PROFILE_UPDATE_ASSET_BASE set "_CP_ASSET_BASE=%CLAUDE_PROFILE_UPDATE_ASSET_BASE%"
```

- [ ] **Step 2: Add `update` to the command dispatch**

Next to the `version` dispatch line added in Task 4:

```bat
if "%~1"=="update"  goto :dispatch_update
```

- [ ] **Step 3: Add the dispatch helper**

Next to `:dispatch_version`:

```bat
:dispatch_update
shift
goto :cmd_update
```

- [ ] **Step 4: Add the checksum-verify helper and `cmd_update`**

Add after `:cmd_version` (from Task 4):

```bat
:verify_checksum
:: verify_checksum <file> <sums-file> -> errorlevel 0 on match, 1 otherwise
set "_vc_file=%~1"
set "_vc_sums=%~2"
for %%F in ("!_vc_file!") do set "_vc_name=%%~nxF"
set "_vc_actual="
for /f "skip=1 tokens=* delims=" %%h in ('certutil -hashfile "!_vc_file!" SHA256 2^>nul') do (
    if not defined _vc_actual (
        echo %%h | findstr /R "^[0-9A-Fa-f][0-9A-Fa-f]*$" >nul 2>&1
        if not errorlevel 1 set "_vc_actual=%%h"
    )
)
set "_vc_expected="
for /f "usebackq delims=" %%L in ("!_vc_sums!") do (
    echo %%L | findstr /C:"!_vc_name!" >nul 2>&1
    if not errorlevel 1 (
        for /f "tokens=1" %%h in ("%%L") do set "_vc_expected=%%h"
    )
)
if not defined _vc_expected exit /b 1
if not defined _vc_actual exit /b 1
if /i "!_vc_expected!"=="!_vc_actual!" (exit /b 0) else (exit /b 1)

:cmd_update
set "_cu_force=0"
if /i "%~1"=="--force" set "_cu_force=1"

where curl >nul 2>&1
if errorlevel 1 (
    echo claude-profile: update requires curl >&2
    exit /b 1
)

set "_cu_resp=%TEMP%\cp-update-release-%RANDOM%.json"
curl -fsSL --connect-timeout 10 --max-time 30 -o "!_cu_resp!" "%_CP_REPO_API%/releases/latest" >nul 2>&1
if not exist "!_cu_resp!" (
    echo claude-profile: update failed: could not reach GitHub >&2
    exit /b 1
)
set "_cu_tagline="
for /f "usebackq delims=" %%T in (`findstr /R "\"tag_name\"" "!_cu_resp!"`) do set "_cu_tagline=%%T"
del /f /q "!_cu_resp!" >nul 2>&1
if not defined _cu_tagline (
    echo claude-profile: update failed: could not determine latest version >&2
    exit /b 1
)
call :extract_tag_version "!_cu_tagline!"
if not defined _cp_tag_version (
    echo claude-profile: update failed: could not determine latest version >&2
    exit /b 1
)
set "_cu_latest=!_cp_tag_version!"
set "_cu_tag=v!_cu_latest!"

set "_cu_installed=unknown"
if exist "%_CP_VERSION_FILE%" set /p _cu_installed=<"%_CP_VERSION_FILE%"
if "!_cu_installed!"=="" set "_cu_installed=unknown"

if "!_cu_force!"=="0" if not "!_cu_installed!"=="unknown" (
    call :version_lt "!_cu_installed!" "!_cu_latest!"
    if errorlevel 1 (
        echo claude-profile: already up to date ^(v!_cu_installed!^); latest is v!_cu_latest! >&2
        exit /b 1
    )
)

set "_cu_tmpdir=%TEMP%\cp-update-%RANDOM%"
mkdir "!_cu_tmpdir!" >nul 2>&1

set "_cu_asset_base=%_CP_ASSET_BASE%/!_cu_tag!"
curl -fsSL --connect-timeout 10 --max-time 30 -o "!_cu_tmpdir!\SHA256SUMS" "!_cu_asset_base!/SHA256SUMS" >nul 2>&1
curl -fsSL --connect-timeout 10 --max-time 30 -o "!_cu_tmpdir!\VERSION" "!_cu_asset_base!/VERSION" >nul 2>&1
curl -fsSL --connect-timeout 10 --max-time 60 -o "!_cu_tmpdir!\claude-profile.cmd" "!_cu_asset_base!/claude-profile.cmd" >nul 2>&1

if not exist "!_cu_tmpdir!\SHA256SUMS" (
    echo claude-profile: update failed: could not download checksums >&2
    goto :update_fail_cleanup
)
if not exist "!_cu_tmpdir!\VERSION" (
    echo claude-profile: update failed: could not download VERSION >&2
    goto :update_fail_cleanup
)
if not exist "!_cu_tmpdir!\claude-profile.cmd" (
    echo claude-profile: update failed: could not download claude-profile.cmd >&2
    goto :update_fail_cleanup
)

call :verify_checksum "!_cu_tmpdir!\VERSION" "!_cu_tmpdir!\SHA256SUMS"
if errorlevel 1 (
    echo claude-profile: update failed: VERSION checksum mismatch >&2
    goto :update_fail_cleanup
)
call :verify_checksum "!_cu_tmpdir!\claude-profile.cmd" "!_cu_tmpdir!\SHA256SUMS"
if errorlevel 1 (
    echo claude-profile: update failed: claude-profile.cmd checksum mismatch >&2
    goto :update_fail_cleanup
)

set "_cu_downloaded_version="
set /p _cu_downloaded_version=<"!_cu_tmpdir!\VERSION"
if not "!_cu_downloaded_version!"=="!_cu_latest!" (
    echo claude-profile: update failed: downloaded VERSION ^(!_cu_downloaded_version!^) does not match release tag ^(!_cu_latest!^) >&2
    goto :update_fail_cleanup
)

if not exist "%_CP_INSTALL_DIR%" mkdir "%_CP_INSTALL_DIR%" >nul 2>&1
move /y "!_cu_tmpdir!\claude-profile.cmd" "%_CP_INSTALL_DIR%\claude-profile.cmd" >nul 2>&1
move /y "!_cu_tmpdir!\VERSION" "%_CP_VERSION_FILE%" >nul 2>&1
rd /s /q "!_cu_tmpdir!" >nul 2>&1

echo Updating claude-profile.cmd: v!_cu_installed! -^> v!_cu_latest!
echo Done. Open a new cmd window ^(or re-run 'call claude-profile.cmd'^) to use the new version.
exit /b 0

:update_fail_cleanup
if exist "!_cu_tmpdir!" rd /s /q "!_cu_tmpdir!" >nul 2>&1
exit /b 1
```

- [ ] **Step 5: Add `update` to the usage text**

```bat
echo     version                 Show the installed version
echo     update [--force]        Update to the latest release
```

- [ ] **Step 6: Manually verify the checksum helper (Windows required)**

```bat
echo hello>%TEMP%\cp-cmd-test.txt
for /f "skip=1 tokens=* delims=" %%h in ('certutil -hashfile %TEMP%\cp-cmd-test.txt SHA256') do if not defined H set "H=%%h"
echo %H%  cp-cmd-test.txt>%TEMP%\cp-cmd-test.sums
call :verify_checksum "%TEMP%\cp-cmd-test.txt" "%TEMP%\cp-cmd-test.sums"
echo errorlevel=%errorlevel%
:: expect 0
```

(Extract `:verify_checksum` into a scratch `.cmd` file to call it standalone, since it isn't exposed outside `claude-profile.cmd`'s own dispatch.)

- [ ] **Step 7: Note the highest-risk implementation**

cmd batch has the weakest error-handling and quoting primitives of the three implementations — this is the file most likely to have a subtle bug (delayed-expansion edge cases, quoting around `!_cu_tag!` interpolated into URLs). Before considering this task done, run every subcommand (`version`, `update` against a fixture with a deliberately-wrong checksum, `update --force` against a fixture with a matching one) interactively on a real Windows machine or VM, not just read the code.

- [ ] **Step 8: Commit**

```bash
git add claude-profile.cmd
git commit -m "feat(cmd): add 'update' command with checksum-verified atomic replace"
```

---

## Task 11: `install.sh` / `install.ps1` — download timeouts + VERSION fetch

**Files:**
- Modify: `install.sh`
- Modify: `install.ps1`

- [ ] **Step 1: Add timeouts to `install.sh`'s `download_file`**

Change (currently lines 45-52):

```sh
download_file() {
    _dl_url="$1"
    _dl_dest="$2"
    case "$DOWNLOAD_CMD" in
        curl) curl -fsSL "$_dl_url" -o "$_dl_dest" ;;
        wget) wget -qO "$_dl_dest" "$_dl_url" ;;
    esac
}
```

to:

```sh
download_file() {
    _dl_url="$1"
    _dl_dest="$2"
    case "$DOWNLOAD_CMD" in
        curl) curl -fsSL --connect-timeout 10 --max-time 60 "$_dl_url" -o "$_dl_dest" ;;
        wget) wget -qO "$_dl_dest" --timeout=60 "$_dl_url" ;;
    esac
}
```

- [ ] **Step 2: Download and write VERSION in `install.sh`'s `main()`**

After the existing "Installing to..." step (currently lines 110-113):

```sh
    step "Installing to ${INSTALL_DIR}/claude-profile.sh..."
    cp "$_tmp_file" "${INSTALL_DIR}/claude-profile.sh"
    chmod +r "${INSTALL_DIR}/claude-profile.sh"
    info "Installed: ${INSTALL_DIR}/claude-profile.sh"

    step "Downloading VERSION..."
    if download_file "${REPO_BASE}/VERSION" "${INSTALL_DIR}/VERSION"; then
        info "Installed: ${INSTALL_DIR}/VERSION"
    else
        warn "Could not download VERSION file. Update notifications will show 'unknown' until the next successful 'claude-profile update'."
    fi
```

- [ ] **Step 3: Add `-TimeoutSec` to `install.ps1`'s script download loop**

Change (currently lines 76-87):

```powershell
Write-Step 'Downloading scripts...'
foreach ($script in $Scripts) {
    $url = "$RepoBase/$script"
    $dest = Join-Path $installDir $script
    Write-Info "  $script -> $dest"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } catch {
        Write-Fail "Failed to download $script from $url : $_"
    }
}
Write-Info 'Downloaded successfully.'
```

to:

```powershell
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
```

- [ ] **Step 4: Manually verify `install.sh` end-to-end against a local checkout**

```bash
INSTALL_DIR=/tmp/cp-install-test sh -c '
REPO_BASE="file://$(pwd)"
. ./install.sh 2>&1 | head -50
' 2>&1 || true
# Since install.sh hardcodes REPO_BASE to the real GitHub URL, the
# practical check here is narrower: run `sh -n install.sh` to confirm it
# still parses, then re-run the existing manual install flow against a
# real network connection and confirm VERSION now appears in the install
# directory alongside claude-profile.sh.
sh -n install.sh
```

- [ ] **Step 5: Lint**

```bash
shellcheck install.sh
checkbashisms install.sh
```

- [ ] **Step 6: Commit**

```bash
git add install.sh install.ps1
git commit -m "feat(install): add download timeouts and fetch VERSION at install time"
```

---

## Task 12: README.md updates

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add `version` and `update` to the commands table**

Change the table (currently lines 41-50) by adding two rows after `claude-profile which [name]`:

```markdown
| `claude-profile which [name]` | Show the config directory path |
| `claude-profile version` | Show the installed version |
| `claude-profile update [--force]` | Update to the latest release |
| `claude-profile help` | Show help |
```

- [ ] **Step 2: Add an "Updating" section**

Insert a new section after "### Profile Names" (after line 89), before "## Platform Support":

```markdown
## Updating

`claude-profile` checks for new releases at most once every 24 hours, as a
side effect of running `claude` (or, on cmd.exe, any `claude-profile`
command). If a newer version is available, you'll see a one-time notice:

```
A new claude-profile version is available (v1.0.0 -> v1.1.0). Run 'claude-profile update' to upgrade.
```

Run the update:

```sh
claude-profile update
```

This downloads the new script and the shared `VERSION` file from the
matching GitHub Release (not the `main` branch), verifies their SHA-256
checksums, and only replaces your installed files once both checks pass. It
refuses to downgrade unless you pass `--force`. After updating, restart your
shell (or `source ~/.bashrc` / `. $PROFILE`) to pick up the new version —
cmd.exe re-reads the file on every `call`, so no restart is needed there.

To disable the passive check entirely, set:

```sh
export CLAUDE_PROFILE_NO_UPDATE_CHECK=1
```
```

- [ ] **Step 3: Manually verify the rendered markdown**

```bash
grep -n "claude-profile update" README.md
grep -n "CLAUDE_PROFILE_NO_UPDATE_CHECK" README.md
```

Expected: both terms appear.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): document 'update'/'version' commands and update opt-out"
```

---

## Task 13: Cross-implementation verification pass + first real release

**Files:** none (verification only)

- [ ] **Step 1: Full lint pass**

```bash
shellcheck claude-profile.sh install.sh
checkbashisms claude-profile.sh install.sh
```

Expected: no errors beyond the pre-existing, already-accepted SC3033 hyphenated-function-name note.

- [ ] **Step 2: Side-by-side smoke test of `version` across all three implementations**

Run on each of Linux/macOS (sh), Windows PowerShell, and Windows cmd, with a real installed `VERSION` file:

```bash
claude-profile version   # sh / ps1
call claude-profile.cmd version   # cmd
```

Expected: identical output (the version string) across all three, given the same `VERSION` file content.

- [ ] **Step 3: Cut the first real release under this feature**

```bash
# Bump VERSION and tag together, per the design doc's convention:
printf '1.1.0' > VERSION
git add VERSION
git commit -m "chore(release): bump to 1.1.0"
git tag -a v1.1.0 -m "v1.1.0"
git push origin main --tags   # only after explicit user go-ahead

./scripts/make-release-checksums.sh > SHA256SUMS
gh release create v1.1.0 VERSION claude-profile.sh claude-profile-init.ps1 claude-profile.cmd SHA256SUMS \
  --title "v1.1.0" --notes "Adds passive update checks and the update/version commands."
```

- [ ] **Step 4: Full happy-path verification of `update` against the real release**

On a machine with an older/`unknown` installed version:

```bash
claude-profile update
```

Expected: `Updating claude-profile.sh: v<old> -> v1.1.0`, followed by the re-source reminder; the installed `claude-profile.sh` and `VERSION` now match the release; running `claude-profile update` again reports "already up to date."

Repeat for `claude-profile-init.ps1` (PowerShell) and `claude-profile.cmd` (cmd), each against their own asset.

- [ ] **Step 5: Verify the passive-check notify/reset flow against the real release**

```bash
rm -f "$(claude-profile which 2>/dev/null >/dev/null; echo "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile/.update-check")"
printf '1.0.0' > "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile/VERSION"
claude   # expect: stderr notice v1.0.0 -> v1.1.0
claude   # expect: no notice (already notified for 1.1.0)
```

- [ ] **Step 6: Final commit (if any fixes were needed during this pass)**

```bash
git add -A
git commit -m "fix: address issues found during cross-implementation verification"
```
