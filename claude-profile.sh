# shellcheck shell=sh
# claude-profile.sh — Source this in .bashrc / .zshrc
#
#   source "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile/claude-profile.sh"
#
# Provides:
#   claude           — runs Claude Code with the active/default profile
#   claude-profile   — manage profiles (create, list, delete, default, use, which)
#
# Supports POSIX shells on Linux, macOS, WSL, and Git Bash / MSYS2 on Windows.
# On Git Bash the data directory is anchored at %LOCALAPPDATA% so profiles are
# shared with the cmd.exe and PowerShell implementations on the same machine.

# --- Internal helpers ---

_cp_die() {
    printf 'claude-profile: %s\n' "$1" >&2
}

# Detects MSYS-family environments (Git Bash, MSYS2, Cygwin shipped with
# MSYSTEM set). Used to decide whether to convert paths via cygpath.
_cp_is_msys() {
    case "${MSYSTEM:-}" in
        MINGW*|MSYS*|UCRT*|CLANG*) return 0 ;;
    esac
    return 1
}

# Resolves the profile data directory. On MSYS-family shells, anchors at
# %LOCALAPPDATA%/claude-profiles (matching the cmd.exe and PowerShell
# implementations) so profiles are shared across shells on the same machine.
# Falls back to $XDG_DATA_HOME/claude-profiles on every other platform.
_cp_data_dir() {
    if _cp_is_msys && [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "${LOCALAPPDATA}/claude-profiles"
        return 0
    fi
    printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/claude-profiles"
}

# Shared name validation for profiles and skills; $2 is the noun used in
# error messages so both validators stay rule-identical by construction.
_cp_validate_name_core() {
    case "$1" in
        "")
            _cp_die "$2 name must not be empty"
            return 1
            ;;
        .*)
            _cp_die "invalid $2 name '$1': must not start with '.'"
            return 1
            ;;
        *..*)
            _cp_die "invalid $2 name '$1': must not contain '..'"
            return 1
            ;;
        */*)
            _cp_die "invalid $2 name '$1': must not contain '/'"
            return 1
            ;;
        *\\*)
            _cp_die "invalid $2 name '$1': must not contain '\\'"
            return 1
            ;;
    esac
    case "$1" in
        *[!A-Za-z0-9_-]*)
            _cp_die "invalid $2 name '$1': use only letters, digits, hyphens, underscores"
            return 1
            ;;
    esac
}

_cp_validate_name() {
    _cp_validate_name_core "$1" profile || return 1
    case "$1" in
        [Ss][Kk][Ii][Ll][Ll][Ss])
            # Case-insensitive: on Windows filesystems (Git Bash) 'SKILLS'
            # resolves to the same directory as the pool.
            _cp_die "profile name 'skills' is reserved for the skill pool"
            return 1
            ;;
    esac
}

# --- Skill pool helpers ---
#
# A central pool at <data-root>/skills holds registered skills (directories
# or links to skill source directories). Each profile may carry a
# skills.conf manifest (one pool-skill name per line, # comments) naming
# the subset it wants; no manifest means every pool skill. Sync
# materializes the selection as links in <profile>/skills. Only links
# whose target lies under the pool are ever created or removed — hand-made
# links, real directories, and files are left alone.

_cp_validate_skill_name() {
    _cp_validate_name_core "$1" skill
}

# Returns 0 when link target $1 lies under pool directory $2. Case-folds
# on MSYS because the shared Windows data directory is case-insensitive
# and %LOCALAPPDATA% casing can differ between the shell that created a
# junction and this one (matches the cmd `if /i` and ps1
# OrdinalIgnoreCase behavior).
_cp_target_in_pool() {
    if _cp_is_msys; then
        _cp_tip_t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
        _cp_tip_p=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
    else
        _cp_tip_t="$1"
        _cp_tip_p="$2"
    fi
    case "$_cp_tip_t" in
        "$_cp_tip_p"/*) return 0 ;;
    esac
    return 1
}

# Prints the literal target of link $1 (fails if not a link). On MSYS the
# junction target may come back as a Windows path; normalize via cygpath
# so prefix comparison against the pool directory works.
_cp_link_target() {
    _cp_lt_t=$(readlink "$1" 2>/dev/null) || return 1
    [ -n "$_cp_lt_t" ] || return 1
    if _cp_is_msys && command -v cygpath >/dev/null 2>&1; then
        case "$_cp_lt_t" in
            [A-Za-z]:*|*\\*) _cp_lt_t=$(cygpath -u "$_cp_lt_t" 2>/dev/null) ;;
        esac
    fi
    printf '%s\n' "$_cp_lt_t"
}

# Creates a link at $2 pointing to directory $1. Uses a directory junction
# on MSYS (no admin rights needed, readable by the cmd and PowerShell
# implementations), a plain symlink everywhere else.
_cp_make_link() {
    if _cp_is_msys && command -v cygpath >/dev/null 2>&1; then
        _cp_ml_src=$(cygpath -w "$1" 2>/dev/null) || _cp_ml_src=""
        _cp_ml_dst=$(cygpath -w "$2" 2>/dev/null) || _cp_ml_dst=""
        if [ -n "$_cp_ml_src" ] && [ -n "$_cp_ml_dst" ]; then
            cmd //c mklink /J "$_cp_ml_dst" "$_cp_ml_src" >/dev/null 2>&1 && return 0
        fi
        return 1
    fi
    ln -s "$1" "$2" 2>/dev/null
}

# Removes a link without touching its target (junctions need rmdir).
_cp_remove_link() {
    rm -f "$1" 2>/dev/null || rmdir "$1" 2>/dev/null
}

# Prints the valid skill names from manifest file $1, one per line.
# Blank lines and # comments are skipped; invalid names warn and are
# skipped so one bad line never fails a whole sync.
_cp_read_manifest() {
    while IFS= read -r _cp_rm_line || [ -n "$_cp_rm_line" ]; do
        _cp_rm_line="${_cp_rm_line%"$_CP_CR"}"
        while :; do
            case "$_cp_rm_line" in
                " "*|"	"*) _cp_rm_line="${_cp_rm_line#?}" ;;
                *" "|*"	") _cp_rm_line="${_cp_rm_line%?}" ;;
                *) break ;;
            esac
        done
        case "$_cp_rm_line" in
            ''|'#'*) continue ;;
            .*|*..*|*/*|*\\*|*[!A-Za-z0-9_-]*)
                _cp_die "skills.conf: ignoring invalid skill name '${_cp_rm_line}'"
                continue
                ;;
        esac
        printf '%s\n' "$_cp_rm_line"
    done < "$1"
    return 0
}

# Prints the names of every skill registered in pool directory $1.
# Includes dangling registrations (link whose source is gone) so listings
# can report them and sync can warn.
_cp_pool_skills() {
    [ -d "$1" ] || return 0
    # The ls guard keeps zsh's nomatch from aborting on an empty glob.
    [ -n "$(ls "$1" 2>/dev/null)" ] || return 0
    for _cp_ps_e in "$1"/*; do
        [ -d "$_cp_ps_e" ] || [ -L "$_cp_ps_e" ] || continue
        printf '%s\n' "${_cp_ps_e##*/}"
    done
    return 0
}

# Prints the desired skill set for profile directory $1 against pool $2:
# the manifest names when skills.conf exists, every pool skill otherwise.
_cp_desired_skills() {
    if [ -f "$1/skills.conf" ]; then
        _cp_read_manifest "$1/skills.conf"
    else
        _cp_pool_skills "$2"
    fi
}

# Ensures profile directory $1 has a concrete skills.conf, materializing
# the implicit "all pool skills" default first so add/remove edits stay
# sticky instead of silently narrowing "all" to one skill.
_cp_skills_materialize_manifest() {
    [ -f "$1/skills.conf" ] && return 0
    _cp_pool_skills "${_cp_data}/skills" > "$1/skills.conf"
}

# Fails when <data>/skills exists but looks like a Claude Code profile —
# i.e. a profile named 'skills' created before that name was reserved.
# Without this, pool operations would enumerate its internals as skills
# and link them into every profile.
_cp_pool_guard() {
    _cp_pg_pool="${_cp_data}/skills"
    [ -d "$_cp_pg_pool" ] || return 0
    if [ -f "${_cp_pg_pool}/settings.json" ] || [ -f "${_cp_pg_pool}/.credentials.json" ]; then
        _cp_die "${_cp_pg_pool} looks like a Claude Code profile, not a skill pool (the name 'skills' is now reserved). Move that profile aside before using skill pools."
        return 1
    fi
    return 0
}

# Re-materializes managed skill links for profile NAME ($1) from its
# manifest (or the whole pool when no manifest). Uses $_cp_data.
_cp_skills_sync_one() {
    _cp_ss_name="$1"
    _cp_ss_pool="${_cp_data}/skills"
    _cp_ss_pdir="${_cp_data}/${_cp_ss_name}"
    _cp_ss_sdir="${_cp_ss_pdir}/skills"
    _cp_pool_guard || return 1
    # A manifest that exists but can't be read must abort, not silently
    # become "select nothing" and strip the profile's managed links.
    if [ -f "${_cp_ss_pdir}/skills.conf" ] && [ ! -r "${_cp_ss_pdir}/skills.conf" ]; then
        _cp_die "cannot read ${_cp_ss_pdir}/skills.conf; not syncing"
        return 1
    fi
    _cp_ss_desired=$(_cp_desired_skills "$_cp_ss_pdir" "$_cp_ss_pool")
    mkdir -p "$_cp_ss_sdir" 2>/dev/null || { _cp_die "cannot create ${_cp_ss_sdir}"; return 1; }

    # Pass 1: drop managed links that are dangling or no longer desired.
    # The ls guard keeps zsh's nomatch from aborting on an empty glob.
    [ -n "$(ls "$_cp_ss_sdir" 2>/dev/null)" ] && for _cp_ss_e in "$_cp_ss_sdir"/*; do
        [ -L "$_cp_ss_e" ] || continue
        _cp_ss_t=$(_cp_link_target "$_cp_ss_e") || continue
        _cp_target_in_pool "$_cp_ss_t" "$_cp_ss_pool" || continue
        _cp_ss_b="${_cp_ss_e##*/}"
        if [ ! -d "${_cp_ss_pool}/${_cp_ss_b}" ] \
            || ! printf '%s\n' "$_cp_ss_desired" | grep -Fqx "$_cp_ss_b"; then
            _cp_remove_link "$_cp_ss_e" || _cp_die "could not remove ${_cp_ss_e}"
        fi
    done

    # Pass 2: create links missing from the desired set.
    [ -n "$_cp_ss_desired" ] || return 0
    printf '%s\n' "$_cp_ss_desired" | while IFS= read -r _cp_ss_want; do
        [ -n "$_cp_ss_want" ] || continue
        if [ ! -d "${_cp_ss_pool}/${_cp_ss_want}" ]; then
            _cp_die "skill '${_cp_ss_want}' is not in the pool (or its source is gone); skipping"
            continue
        fi
        _cp_ss_dst="${_cp_ss_sdir}/${_cp_ss_want}"
        if [ -L "$_cp_ss_dst" ]; then
            _cp_ss_t=$(_cp_link_target "$_cp_ss_dst")
            if _cp_target_in_pool "$_cp_ss_t" "$_cp_ss_pool"; then
                continue
            fi
            _cp_die "skill '${_cp_ss_want}': unmanaged entry already at ${_cp_ss_dst}; skipping"
            continue
        fi
        if [ -e "$_cp_ss_dst" ]; then
            _cp_die "skill '${_cp_ss_want}': unmanaged entry already at ${_cp_ss_dst}; skipping"
            continue
        fi
        _cp_make_link "${_cp_ss_pool}/${_cp_ss_want}" "$_cp_ss_dst" \
            || _cp_die "could not link skill '${_cp_ss_want}'"
    done
    return 0
}

# Resolves the profile a skills command acts on into _cp_sp_name: the
# explicit argument $1 if given, else the active profile, else the
# default. Uses $_cp_data / $_cp_default_file.
_cp_skills_profile() {
    if [ -n "${1:-}" ]; then
        _cp_validate_name "$1" || return 1
        _cp_sp_name="$1"
    elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        case "$CLAUDE_CONFIG_DIR" in
            "${_cp_data}"/*) _cp_sp_name="${CLAUDE_CONFIG_DIR##*/}" ;;
            *)
                _cp_die "active CLAUDE_CONFIG_DIR is not a managed profile; pass a profile name"
                return 1
                ;;
        esac
    elif [ -f "$_cp_default_file" ]; then
        _cp_sp_name=$(cat "$_cp_default_file")
        if [ -z "$_cp_sp_name" ]; then
            _cp_die "no profile specified and no default profile set"
            return 1
        fi
    else
        _cp_die "no profile specified and no default profile set"
        return 1
    fi
    if [ ! -d "${_cp_data}/${_cp_sp_name}" ]; then
        _cp_die "profile '${_cp_sp_name}' does not exist"
        return 1
    fi
    return 0
}

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
    case "$_cp_vlt_a1" in ''|*[!0-9]*) _cp_vlt_a1=0 ;; esac
    case "$_cp_vlt_a2" in ''|*[!0-9]*) _cp_vlt_a2=0 ;; esac
    case "$_cp_vlt_a3" in ''|*[!0-9]*) _cp_vlt_a3=0 ;; esac
    case "$_cp_vlt_b1" in ''|*[!0-9]*) _cp_vlt_b1=0 ;; esac
    case "$_cp_vlt_b2" in ''|*[!0-9]*) _cp_vlt_b2=0 ;; esac
    case "$_cp_vlt_b3" in ''|*[!0-9]*) _cp_vlt_b3=0 ;; esac
    [ "$_cp_vlt_a1" -lt "$_cp_vlt_b1" ] && return 0
    [ "$_cp_vlt_a1" -gt "$_cp_vlt_b1" ] && return 1
    [ "$_cp_vlt_a2" -lt "$_cp_vlt_b2" ] && return 0
    [ "$_cp_vlt_a2" -gt "$_cp_vlt_b2" ] && return 1
    [ "$_cp_vlt_a3" -lt "$_cp_vlt_b3" ] && return 0
    return 1
}

# --- Passive update check ---

_CP_REPO_API="${CLAUDE_PROFILE_UPDATE_API_BASE:-https://api.github.com/repos/quinnjr/claude-code-profiles}"
_CP_ASSET_BASE="${CLAUDE_PROFILE_UPDATE_ASSET_BASE:-https://github.com/quinnjr/claude-code-profiles/releases/download}"
_CP_UPDATE_INTERVAL="${CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL:-86400}"
case "$_CP_UPDATE_INTERVAL" in ''|*[!0-9]*) _CP_UPDATE_INTERVAL=86400 ;; esac

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
    _cp_upd_latest=$(_cp_extract_tag_version "$_cp_upd_resp")
    if [ -z "$_cp_upd_latest" ]; then
        _cp_die "update failed: could not determine latest version"
        return 1
    fi
    _cp_upd_tag="v${_cp_upd_latest}"

    _cp_upd_installed=$(_cp_installed_version)
    if [ "$_cp_upd_force" -eq 0 ] && [ "$_cp_upd_installed" != "unknown" ] \
        && ! _cp_version_lt "$_cp_upd_installed" "$_cp_upd_latest"; then
        _cp_die "already up to date (v${_cp_upd_installed}); latest is v${_cp_upd_latest}"
        return 1
    fi

    _cp_upd_install="$(_cp_install_dir)"
    mkdir -p "$_cp_upd_install" || { _cp_die "update failed: could not create install directory"; return 1; }
    _cp_upd_tmpdir=$(mktemp -d "${_cp_upd_install}/.update.XXXXXX") || { _cp_die "update failed: could not create temp directory"; return 1; }
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

    if ! mv -f "${_cp_upd_tmpdir}/claude-profile.sh" "${_cp_upd_install}/claude-profile.sh"; then
        _cp_die "update failed: could not replace claude-profile.sh"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi
    if ! mv -f "${_cp_upd_tmpdir}/VERSION" "${_cp_upd_install}/VERSION"; then
        _cp_die "update failed: could not replace VERSION"
        rm -rf "$_cp_upd_tmpdir"
        return 1
    fi
    rm -rf "$_cp_upd_tmpdir"

    case "$_cp_upd_installed" in
        unknown) _cp_upd_installed_display="unknown" ;;
        *) _cp_upd_installed_display="v${_cp_upd_installed}" ;;
    esac
    printf 'Updating claude-profile.sh: %s -> v%s\n' "$_cp_upd_installed_display" "$_cp_upd_latest"
    printf "Done. Run 'source ~/.bashrc' (or restart your shell) to use the new version.\\n"
    return 0
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
        [ "$_cp_line_n" -ge 3 ] && break
    done < "$_cp_cache_file"
    return 0
}

# Writes a single value to a file atomically (temp file + rename).
# Usage: _cp_atomic_write FILE VALUE
_cp_atomic_write() {
    _cp_aw_tmp="${1}.tmp.$$"
    { printf '%s\n' "$2" > "$_cp_aw_tmp"; } 2>/dev/null || { rm -f "$_cp_aw_tmp" 2>/dev/null; return 1; }
    mv -f "$_cp_aw_tmp" "$1" 2>/dev/null || { rm -f "$_cp_aw_tmp" 2>/dev/null; return 1; }
    return 0
}

# Rate-limited stderr diagnostic for persistent local cache-file I/O
# failures (permissions, disk full) -- distinct from transient network
# failures, which stay silent by design per _cp_update_check. Best-effort:
# uses a separate marker file so a broken .update-check write doesn't also
# block this diagnostic; if even the marker can't be written, this
# degrades to printing every invocation rather than staying silent forever
# (never worse than the bug being fixed).
#
# Deliberately reuses _CP_UPDATE_INTERVAL (default 86400s) as a rolling
# window approximating the design's "at most once per calendar day" --
# not a literal calendar-day boundary, and coupled to the same
# user-tunable CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL override that governs
# the update check's own polling frequency. Lowering that interval (e.g.
# for testing) also shortens this diagnostic's rate limit; this is an
# accepted simplification, not a separate config knob.
#
# Called from inside _cp_write_update_cache (not from its callers) so the
# already-resolved install dir and epoch are reused rather than
# re-resolved — this also means every current and future caller of
# _cp_write_update_cache gets this diagnostic for free, with no risk of a
# call site forgetting to check the write's return value.
# Usage: _cp_warn_cache_write_failure DIR EPOCH
_cp_warn_cache_write_failure() {
    _cp_wcf_dir="$1"
    _cp_wcf_now="$2"
    _cp_wcf_marker="${_cp_wcf_dir}/.update-check-diag"
    _cp_wcf_last=0
    if [ -f "$_cp_wcf_marker" ]; then
        _cp_wcf_read=$(cat "$_cp_wcf_marker" 2>/dev/null)
        case "$_cp_wcf_read" in ''|*[!0-9]*) ;; *) _cp_wcf_last="$_cp_wcf_read" ;; esac
    fi
    if [ $((_cp_wcf_now - _cp_wcf_last)) -ge "$_CP_UPDATE_INTERVAL" ]; then
        printf 'claude-profile: warning: could not write update-check cache in %s -- update notifications may not work until this is fixed\n' "$_cp_wcf_dir" >&2
        _cp_atomic_write "$_cp_wcf_marker" "$_cp_wcf_now"
    fi
    return 0
}

# Writes the cache atomically (temp file + rename), so concurrent
# invocations can't torn-write it. Usage: _cp_write_update_cache TS VER NOTIFIED
_cp_write_update_cache() {
    _cp_wuc_dir="$(_cp_install_dir)"
    mkdir -p "$_cp_wuc_dir" 2>/dev/null || { _cp_warn_cache_write_failure "$_cp_wuc_dir" "$1"; return 1; }
    _cp_wuc_file="${_cp_wuc_dir}/.update-check"
    _cp_wuc_tmp="${_cp_wuc_file}.tmp.$$"
    if ! printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$_cp_wuc_tmp" 2>/dev/null; then
        rm -f "$_cp_wuc_tmp" 2>/dev/null
        _cp_warn_cache_write_failure "$_cp_wuc_dir" "$1"
        return 1
    fi
    mv -f "$_cp_wuc_tmp" "$_cp_wuc_file" 2>/dev/null || {
        rm -f "$_cp_wuc_tmp" 2>/dev/null
        _cp_warn_cache_write_failure "$_cp_wuc_dir" "$1"
        return 1
    }
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
    case "$_cp_now" in ''|*[!0-9]*) return 0 ;; esac
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
            case "$_cp_installed" in
                unknown) _cp_installed_display="unknown" ;;
                *) _cp_installed_display="v${_cp_installed}" ;;
            esac
            printf "A new claude-profile version is available (%s -> v%s). Run 'claude-profile update' to upgrade.\\n" \
                "$_cp_installed_display" "$_cp_cache_ver" >&2
            _cp_write_update_cache "$_cp_now" "$_cp_cache_ver" 1
        fi
    fi
    return 0
}

# --- Directory-local profile (.claude-profile) auto-switching ---
#
# A directory may contain a `.claude-profile` file whose first non-empty,
# non-comment line names a profile. Entering that directory (or any
# descendant) switches CLAUDE_CONFIG_DIR to it; leaving reverts to the
# default. Explicit `claude-profile use <name>` pins the session and
# suppresses auto-switching until `claude-profile auto on`.
#
# Environment knobs:
#   CLAUDE_PROFILE_NO_AUTO_SWITCH=1   disable auto-switching entirely
#   CLAUDE_PROFILE_AUTO_QUIET=1       switch silently (no stderr notices)
#
# CLAUDE_PROFILE_AUTO_SET is exported so nested shells know the current
# CLAUDE_CONFIG_DIR came from auto-switching (and may be re-managed) rather
# than from an explicit `use`.

_CP_DOTFILE=".claude-profile"
_CP_CR=$(printf '\r')

_cp_auto_notice() {
    [ -n "${CLAUDE_PROFILE_AUTO_QUIET:-}" ] && return 0
    printf 'claude-profile: %s\n' "$1" >&2
    return 0
}

# Sets _cp_dotfile to the nearest .claude-profile at or above directory $1,
# or empty when none is found. Deliberately uses only parameter expansion
# (no dirname/basename subprocesses): this runs on every shell prompt under
# bash's PROMPT_COMMAND, so a fork per path component would be felt.
_cp_find_dotfile() {
    _cp_dotfile=""
    _cp_fd_dir="$1"
    while :; do
        [ -n "$_cp_fd_dir" ] || _cp_fd_dir="/"
        if [ -f "${_cp_fd_dir%/}/${_CP_DOTFILE}" ]; then
            _cp_dotfile="${_cp_fd_dir%/}/${_CP_DOTFILE}"
            return 0
        fi
        [ "$_cp_fd_dir" = "/" ] && break
        _cp_fd_dir="${_cp_fd_dir%/*}"
    done
    return 1
}

# Sets _cp_dotname to the first non-empty, non-comment line of file $1,
# with surrounding whitespace and any trailing CR stripped (so a file
# authored on Windows and used from WSL/Git Bash still resolves).
_cp_read_dotfile() {
    _cp_dotname=""
    while IFS= read -r _cp_rd_line || [ -n "$_cp_rd_line" ]; do
        _cp_rd_line="${_cp_rd_line%"$_CP_CR"}"
        while :; do
            case "$_cp_rd_line" in
                " "*|"	"*) _cp_rd_line="${_cp_rd_line#?}" ;;
                *" "|*"	") _cp_rd_line="${_cp_rd_line%?}" ;;
                *) break ;;
            esac
        done
        case "$_cp_rd_line" in
            ''|'#'*) continue ;;
        esac
        _cp_dotname="$_cp_rd_line"
        return 0
    done < "$1"
    return 1
}

# Resolves and applies the directory-local profile for $PWD. Safe to call
# repeatedly: it short-circuits when the directory hasn't changed, which
# also rate-limits the warnings below to once per directory entry rather
# than once per prompt.
_cp_auto_switch() {
    [ -n "${CLAUDE_PROFILE_NO_AUTO_SWITCH:-}" ] && return 0
    [ "${_CP_AUTO_OFF:-0}" = "1" ] && return 0
    [ "${PWD:-}" = "${_CP_AUTO_LAST_PWD:-}" ] && return 0
    _CP_AUTO_LAST_PWD="${PWD:-}"

    # An explicitly-chosen profile (claude-profile use, or a CLAUDE_CONFIG_DIR
    # inherited from outside) wins over any .claude-profile file.
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "${CLAUDE_PROFILE_AUTO_SET:-}" ]; then
        return 0
    fi

    _cp_dotname=""
    if _cp_find_dotfile "${PWD:-}"; then
        _cp_read_dotfile "$_cp_dotfile"
    fi

    if [ -z "$_cp_dotname" ]; then
        if [ -n "${CLAUDE_PROFILE_AUTO_SET:-}" ]; then
            unset CLAUDE_CONFIG_DIR
            unset CLAUDE_PROFILE_AUTO_SET
            _cp_auto_notice "directory profile cleared; using the default profile"
        fi
        [ -n "$_cp_dotfile" ] && _cp_die "ignoring ${_cp_dotfile}: no profile name in file"
        return 0
    fi

    case "$_cp_dotname" in
        [Ss][Kk][Ii][Ll][Ll][Ss]|.*|*..*|*/*|*\\*|*[!A-Za-z0-9_-]*)
            _cp_die "ignoring ${_cp_dotfile}: invalid profile name '${_cp_dotname}'"
            return 1
            ;;
    esac

    [ -n "${_CP_DATA_CACHE:-}" ] || _CP_DATA_CACHE=$(_cp_data_dir)
    _cp_as_dir="${_CP_DATA_CACHE}/${_cp_dotname}"
    if [ ! -d "$_cp_as_dir" ]; then
        _cp_die "ignoring ${_cp_dotfile}: profile '${_cp_dotname}' does not exist"
        return 1
    fi

    if [ "${CLAUDE_CONFIG_DIR:-}" = "$_cp_as_dir" ]; then
        export CLAUDE_PROFILE_AUTO_SET="$_cp_as_dir"
        return 0
    fi
    export CLAUDE_CONFIG_DIR="$_cp_as_dir"
    export CLAUDE_PROFILE_AUTO_SET="$_cp_as_dir"
    _cp_auto_notice "switched to profile '${_cp_dotname}' (from ${_cp_dotfile})"
    return 0
}

# Registers _cp_auto_switch with whatever directory-change mechanism the
# running shell offers. zsh has a real chpwd hook; bash only has
# PROMPT_COMMAND; everything else (dash, ash, ksh) gets a cd wrapper, which
# covers the common case even though it misses pushd/popd.
if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook chpwd _cp_auto_switch
elif [ -n "${BASH_VERSION:-}" ]; then
    case "${PROMPT_COMMAND:-}" in
        *_cp_auto_switch*) : ;;
        '') PROMPT_COMMAND="_cp_auto_switch" ;;
        *) PROMPT_COMMAND="${PROMPT_COMMAND%;};_cp_auto_switch" ;;
    esac
else
    # `command cd` bypasses this function, so re-sourcing can't recurse.
    # eval keeps the definition out of zsh's parser, which would otherwise
    # alias-expand `cd` at source time and abort with a parse error.
    eval 'cd() {
        command cd "$@" || return $?
        _cp_auto_switch
    }'
fi

# Resolve once at source time so a shell started inside a .claude-profile
# tree is already on the right profile.
_cp_auto_switch

# --- claude() wrapper ---
# Auto-resolves the default profile before calling the real claude binary.
# If CLAUDE_CONFIG_DIR is already set (e.g. via 'claude-profile use'),
# it passes through without overriding.

claude() {
    _cp_update_check
    # Covers shells whose cd we couldn't hook (and directory changes made by
    # something other than cd) — resolving here is cheap and idempotent.
    _cp_auto_switch
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
        _cp_data=$(_cp_data_dir)
        _cp_def="${_cp_data}/.default"
        if [ -f "$_cp_def" ]; then
            _cp_name=$(cat "$_cp_def")
            if [ -n "$_cp_name" ] && [ -d "${_cp_data}/${_cp_name}" ]; then
                export CLAUDE_CONFIG_DIR="${_cp_data}/${_cp_name}"
                # Mark it auto-managed, not an explicit pin: without this, the
                # first `claude` run would freeze the session on the default
                # profile and later .claude-profile directories would be
                # ignored.
                export CLAUDE_PROFILE_AUTO_SET="$CLAUDE_CONFIG_DIR"
            fi
        fi
    fi
    # Native claude.exe on Windows expects backslash paths; convert MSYS paths
    # for the subprocess only, leaving the shell-side value untouched so
    # internal commands (list, status) still match against the unix form.
    # Fail loudly if cygpath is missing or conversion fails, because silently
    # passing a /c/Users/... path to claude.exe causes it to create a new
    # config dir at an unexpected location instead of honoring the profile.
    if _cp_is_msys && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        if ! command -v cygpath >/dev/null 2>&1; then
            _cp_die "cygpath not found on PATH; required on Git Bash / MSYS2 to convert CLAUDE_CONFIG_DIR for claude.exe"
            return 127
        fi
        _cp_native=$(cygpath -w "$CLAUDE_CONFIG_DIR" 2>/dev/null) || _cp_native=""
        if [ -z "$_cp_native" ]; then
            _cp_die "failed to convert CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' to a Windows path via cygpath -w"
            return 1
        fi
        CLAUDE_CONFIG_DIR="$_cp_native" command claude "$@"
        return $?
    fi
    command claude "$@"
}

# --- claude-profile() management function ---

# shellcheck disable=SC3033  # hyphenated function name works in bash/zsh
claude-profile() {
    _cp_data=$(_cp_data_dir)
    _cp_default_file="${_cp_data}/.default"

    case "${1:-}" in
        use)
            shift
            if [ -z "${1:-}" ]; then
                _cp_die "usage: claude-profile use <name>"
                return 1
            fi
            _cp_name="$1"
            shift
            if [ -n "${1:-}" ]; then
                _cp_die "unexpected argument after profile name: '$1'"
                return 1
            fi
            _cp_validate_name "$_cp_name" || return 1
            _cp_dir="${_cp_data}/${_cp_name}"
            if [ ! -d "$_cp_dir" ]; then
                _cp_die "profile '${_cp_name}' does not exist. Create it with: claude-profile create ${_cp_name}"
                return 1
            fi
            export CLAUDE_CONFIG_DIR="$_cp_dir"
            # Dropping the auto-set marker pins the session: subsequent
            # directory changes will no longer override this choice.
            unset CLAUDE_PROFILE_AUTO_SET
            printf 'Switched to profile: %s\n' "$_cp_name"
            ;;

        auto)
            shift
            case "${1:-}" in
                on)
                    unset _CP_AUTO_OFF
                    unset CLAUDE_CONFIG_DIR
                    unset CLAUDE_PROFILE_AUTO_SET
                    _CP_AUTO_LAST_PWD=""
                    _cp_auto_switch
                    printf 'Directory-local auto-switching enabled.\n'
                    ;;
                off)
                    _CP_AUTO_OFF=1
                    printf 'Directory-local auto-switching disabled for this session.\n'
                    ;;
                ""|status)
                    if [ -n "${CLAUDE_PROFILE_NO_AUTO_SWITCH:-}" ]; then
                        printf 'Auto-switching: disabled (CLAUDE_PROFILE_NO_AUTO_SWITCH is set)\n'
                    elif [ "${_CP_AUTO_OFF:-0}" = "1" ]; then
                        printf 'Auto-switching: disabled for this session\n'
                    elif [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ "$CLAUDE_CONFIG_DIR" != "${CLAUDE_PROFILE_AUTO_SET:-}" ]; then
                        printf 'Auto-switching: pinned (an explicit profile is active)\n'
                        printf "Run 'claude-profile auto on' to resume auto-switching.\\n"
                    else
                        printf 'Auto-switching: enabled\n'
                    fi
                    if _cp_find_dotfile "${PWD:-}"; then
                        _cp_read_dotfile "$_cp_dotfile"
                        printf 'Directory profile: %s (%s)\n' "${_cp_dotname:-<empty>}" "$_cp_dotfile"
                    else
                        printf 'Directory profile: none in scope\n'
                    fi
                    ;;
                *)
                    _cp_die "usage: claude-profile auto [on|off|status]"
                    return 1
                    ;;
            esac
            ;;

        local)
            shift
            case "${1:-}" in
                "")
                    if _cp_find_dotfile "${PWD:-}"; then
                        _cp_read_dotfile "$_cp_dotfile"
                        printf '%s\n' "$_cp_dotfile"
                        printf 'Profile: %s\n' "${_cp_dotname:-<empty>}"
                    else
                        _cp_die "no ${_CP_DOTFILE} found in this directory or any parent"
                        return 1
                    fi
                    ;;
                --remove|--clear)
                    if [ ! -f "./${_CP_DOTFILE}" ]; then
                        _cp_die "no ${_CP_DOTFILE} in the current directory"
                        return 1
                    fi
                    rm -f "./${_CP_DOTFILE}" || return 1
                    printf 'Removed %s\n' "${PWD}/${_CP_DOTFILE}"
                    _CP_AUTO_LAST_PWD=""
                    _cp_auto_switch
                    ;;
                -*)
                    _cp_die "unknown option '$1'"
                    return 1
                    ;;
                *)
                    _cp_name="$1"
                    shift
                    if [ -n "${1:-}" ]; then
                        _cp_die "unexpected argument after profile name: '$1'"
                        return 1
                    fi
                    _cp_validate_name "$_cp_name" || return 1
                    _cp_dir="${_cp_data}/${_cp_name}"
                    if [ ! -d "$_cp_dir" ]; then
                        _cp_die "profile '${_cp_name}' does not exist. Create it with: claude-profile create ${_cp_name}"
                        return 1
                    fi
                    printf '%s\n' "$_cp_name" > "./${_CP_DOTFILE}" || return 1
                    printf 'Wrote %s (profile: %s)\n' "${PWD}/${_CP_DOTFILE}" "$_cp_name"
                    _CP_AUTO_LAST_PWD=""
                    _cp_auto_switch
                    ;;
            esac
            ;;

        create)
            shift
            _cp_do_init=0
            _cp_name=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --init) _cp_do_init=1 ;;
                    -*)
                        _cp_die "unknown option '$1'"
                        return 1
                        ;;
                    *)
                        if [ -n "$_cp_name" ]; then
                            _cp_die "unexpected argument '$1'"
                            return 1
                        fi
                        _cp_name="$1"
                        ;;
                esac
                shift
            done
            if [ -z "$_cp_name" ]; then
                _cp_die "usage: claude-profile create [--init] <name>"
                return 1
            fi
            _cp_validate_name "$_cp_name" || return 1
            _cp_dir="${_cp_data}/${_cp_name}"
            if [ -d "$_cp_dir" ]; then
                _cp_die "profile '${_cp_name}' already exists"
                return 1
            fi
            mkdir -p "$_cp_dir"
            printf 'Created profile: %s\n' "$_cp_name"
            printf 'Config directory: %s\n' "$_cp_dir"
            # A new profile has no manifest, so this links every pool skill
            # (the backward-compatible "all" default). No pool: no-op.
            if [ -d "${_cp_data}/skills" ]; then
                _cp_skills_sync_one "$_cp_name"
            fi
            if [ "$_cp_do_init" -eq 1 ]; then
                _cp_settings="${_cp_dir}/settings.json"
                cat > "$_cp_settings" <<'SETTINGSEOF'
{
  "env": {
    "ANTHROPIC_API_KEY": "YOUR_API_KEY_HERE",
    "ANTHROPIC_BASE_URL": "https://YOUR_ENDPOINT_HERE",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "0"
  },
  "model": "claude-sonnet-4-6",
  "advisorModel": "claude-opus-4-8",
  "fallbackModel": ["claude-haiku-4-5"],
  "effortLevel": "high",
  "alwaysThinkingEnabled": false,
  "permissions": {
    "allow": [],
    "deny": []
  },
  "autoMemoryEnabled": true,
  "autoCompactEnabled": true,
  "fileCheckpointingEnabled": true,
  "cleanupPeriodDays": 30,
  "language": "english",
  "editorMode": "normal",
  "preferredNotifChannel": "auto"
}
SETTINGSEOF
                printf 'Config skeleton written to: %s\n' "$_cp_settings"
                printf 'Tip: remove "ANTHROPIC_BASE_URL" if using the default Anthropic endpoint.\n'
                if [ -n "${VISUAL:-}" ]; then
                    "${VISUAL}" "$_cp_settings"
                elif [ -n "${EDITOR:-}" ]; then
                    "${EDITOR}" "$_cp_settings"
                fi
            fi
            ;;

        list|ls)
            if [ ! -d "$_cp_data" ]; then
                printf 'No profiles found. Create one with: claude-profile create <name>\n'
                return 0
            fi
            _cp_cur_default=""
            if [ -f "$_cp_default_file" ]; then
                _cp_cur_default=$(cat "$_cp_default_file")
            fi
            # Derive active profile name from CLAUDE_CONFIG_DIR
            _cp_active=""
            if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
                case "$CLAUDE_CONFIG_DIR" in
                    "${_cp_data}"/*)
                        _cp_active=$(basename "$CLAUDE_CONFIG_DIR")
                        ;;
                esac
            fi
            _cp_found=0
            _cp_pool_n=$(_cp_pool_skills "${_cp_data}/skills" | grep -c .)
            for _cp_entry in "$_cp_data"/*/; do
                [ -d "$_cp_entry" ] || continue
                _cp_entry_name=$(basename "$_cp_entry")
                [ "$_cp_entry_name" = "skills" ] && continue
                _cp_found=1
                _cp_sk_note=""
                if [ -f "${_cp_entry%/}/skills.conf" ]; then
                    _cp_sk_n=$(_cp_read_manifest "${_cp_entry%/}/skills.conf" 2>/dev/null | grep -c .)
                    _cp_sk_note=" [skills: ${_cp_sk_n}/${_cp_pool_n}]"
                fi
                _cp_is_default=0
                _cp_is_active=0
                if [ "$_cp_entry_name" = "$_cp_cur_default" ]; then
                    _cp_is_default=1
                fi
                if [ "$_cp_entry_name" = "$_cp_active" ]; then
                    _cp_is_active=1
                fi
                if [ "$_cp_is_default" -eq 1 ] && [ "$_cp_is_active" -eq 1 ]; then
                    printf '>* %s (default, active)%s\n' "$_cp_entry_name" "$_cp_sk_note"
                elif [ "$_cp_is_default" -eq 1 ]; then
                    printf ' * %s (default)%s\n' "$_cp_entry_name" "$_cp_sk_note"
                elif [ "$_cp_is_active" -eq 1 ]; then
                    printf '>  %s (active)%s\n' "$_cp_entry_name" "$_cp_sk_note"
                else
                    printf '   %s%s\n' "$_cp_entry_name" "$_cp_sk_note"
                fi
            done
            if [ "$_cp_found" -eq 0 ]; then
                printf 'No profiles found. Create one with: claude-profile create <name>\n'
            fi
            ;;

        default)
            shift
            if [ -z "${1:-}" ]; then
                if [ -f "$_cp_default_file" ]; then
                    _cp_name=$(cat "$_cp_default_file")
                    if [ -n "$_cp_name" ]; then
                        printf '%s\n' "$_cp_name"
                    else
                        _cp_die "default profile file is empty. Set one with: claude-profile default <name>"
                        return 1
                    fi
                else
                    _cp_die "no default profile set. Set one with: claude-profile default <name>"
                    return 1
                fi
                return 0
            fi
            _cp_name="$1"
            _cp_validate_name "$_cp_name" || return 1
            _cp_dir="${_cp_data}/${_cp_name}"
            if [ ! -d "$_cp_dir" ]; then
                _cp_die "profile '${_cp_name}' does not exist. Create it with: claude-profile create ${_cp_name}"
                return 1
            fi
            mkdir -p "$_cp_data"
            printf '%s' "$_cp_name" > "$_cp_default_file"
            printf 'Default profile set to: %s\n' "$_cp_name"
            ;;

        which)
            shift
            if [ -n "${1:-}" ]; then
                _cp_name="$1"
                _cp_validate_name "$_cp_name" || return 1
                _cp_dir="${_cp_data}/${_cp_name}"
                if [ ! -d "$_cp_dir" ]; then
                    _cp_die "profile '${_cp_name}' does not exist. Create it with: claude-profile create ${_cp_name}"
                    return 1
                fi
                printf '%s\n' "$_cp_dir"
            else
                if [ ! -f "$_cp_default_file" ]; then
                    _cp_die "no default profile set. Use: claude-profile default <name>"
                    return 1
                fi
                _cp_name=$(cat "$_cp_default_file")
                if [ -z "$_cp_name" ]; then
                    _cp_die "default profile file is empty. Set one with: claude-profile default <name>"
                    return 1
                fi
                _cp_dir="${_cp_data}/${_cp_name}"
                if [ ! -d "$_cp_dir" ]; then
                    _cp_die "profile '${_cp_name}' does not exist. Create it with: claude-profile create ${_cp_name}"
                    return 1
                fi
                printf '%s\n' "$_cp_dir"
            fi
            ;;

        delete)
            shift
            if [ -z "${1:-}" ]; then
                _cp_die "usage: claude-profile delete <name>"
                return 1
            fi
            _cp_name="$1"
            _cp_validate_name "$_cp_name" || return 1
            _cp_dir="${_cp_data}/${_cp_name}"
            if [ ! -d "$_cp_dir" ]; then
                _cp_die "profile '${_cp_name}' does not exist"
                return 1
            fi
            printf 'Delete profile "%s" and all its data? [y/N] ' "$_cp_name"
            read -r _cp_confirm
            case "$_cp_confirm" in
                [yY]|[yY][eE][sS])
                    rm -rf "$_cp_dir"
                    printf 'Deleted profile: %s\n' "$_cp_name"
                    # Clear default if the deleted profile was the default
                    if [ -f "$_cp_default_file" ]; then
                        _cp_cur_default=$(cat "$_cp_default_file")
                        if [ "$_cp_cur_default" = "$_cp_name" ]; then
                            rm -f "$_cp_default_file"
                            printf 'Cleared default profile (was "%s")\n' "$_cp_name"
                        fi
                    fi
                    # Unset CLAUDE_CONFIG_DIR if the deleted profile was active
                    if [ "${CLAUDE_CONFIG_DIR:-}" = "$_cp_dir" ]; then
                        unset CLAUDE_CONFIG_DIR
                        printf 'Cleared active profile (was "%s")\n' "$_cp_name"
                    fi
                    ;;
                *)
                    printf 'Cancelled.\n'
                    ;;
            esac
            ;;

        skills)
            shift
            _cp_sk_pool="${_cp_data}/skills"
            _cp_pool_guard || return 1
            case "${1:-}" in
                register)
                    shift
                    _cp_sk_name="${1:-}"
                    _cp_sk_path="${2:-}"
                    if [ -z "$_cp_sk_name" ] || [ -z "$_cp_sk_path" ]; then
                        _cp_die "usage: claude-profile skills register <name> <path>"
                        return 1
                    fi
                    if [ -n "${3:-}" ]; then
                        _cp_die "unexpected argument '$3'"
                        return 1
                    fi
                    _cp_validate_skill_name "$_cp_sk_name" || return 1
                    if [ ! -d "$_cp_sk_path" ]; then
                        _cp_die "'${_cp_sk_path}' is not a directory"
                        return 1
                    fi
                    if [ ! -f "${_cp_sk_path}/SKILL.md" ]; then
                        _cp_die "'${_cp_sk_path}' does not contain a SKILL.md"
                        return 1
                    fi
                    mkdir -p "$_cp_sk_pool" || { _cp_die "cannot create ${_cp_sk_pool}"; return 1; }
                    if [ -e "${_cp_sk_pool}/${_cp_sk_name}" ] || [ -L "${_cp_sk_pool}/${_cp_sk_name}" ]; then
                        _cp_die "skill '${_cp_sk_name}' is already registered"
                        return 1
                    fi
                    _cp_sk_abs=$(CDPATH='' cd -- "$_cp_sk_path" 2>/dev/null && pwd) || _cp_sk_abs=""
                    if [ -z "$_cp_sk_abs" ]; then
                        _cp_die "could not resolve '${_cp_sk_path}' to an absolute path"
                        return 1
                    fi
                    if ! _cp_make_link "$_cp_sk_abs" "${_cp_sk_pool}/${_cp_sk_name}"; then
                        _cp_die "could not create pool link for '${_cp_sk_name}'"
                        return 1
                    fi
                    printf 'Registered skill: %s -> %s\n' "$_cp_sk_name" "$_cp_sk_abs"
                    printf "Run 'claude-profile skills sync --all' to link it into unfiltered profiles.\\n"
                    ;;

                unregister)
                    shift
                    _cp_sk_force=0
                    _cp_sk_name=""
                    while [ $# -gt 0 ]; do
                        case "$1" in
                            --force) _cp_sk_force=1 ;;
                            -*)
                                _cp_die "unknown option '$1'"
                                return 1
                                ;;
                            *)
                                if [ -n "$_cp_sk_name" ]; then
                                    _cp_die "unexpected argument '$1'"
                                    return 1
                                fi
                                _cp_sk_name="$1"
                                ;;
                        esac
                        shift
                    done
                    if [ -z "$_cp_sk_name" ]; then
                        _cp_die "usage: claude-profile skills unregister [--force] <name>"
                        return 1
                    fi
                    _cp_validate_skill_name "$_cp_sk_name" || return 1
                    _cp_sk_entry="${_cp_sk_pool}/${_cp_sk_name}"
                    if [ -L "$_cp_sk_entry" ]; then
                        _cp_remove_link "$_cp_sk_entry" || { _cp_die "could not remove ${_cp_sk_entry}"; return 1; }
                    elif [ -d "$_cp_sk_entry" ]; then
                        if [ "$_cp_sk_force" -eq 0 ]; then
                            _cp_die "'${_cp_sk_name}' is a real directory in the pool; pass --force to delete it and its contents"
                            return 1
                        fi
                        rm -rf "$_cp_sk_entry" || { _cp_die "could not remove ${_cp_sk_entry}"; return 1; }
                    else
                        _cp_die "skill '${_cp_sk_name}' is not registered"
                        return 1
                    fi
                    for _cp_sk_p in "$_cp_data"/*/; do
                        [ -d "$_cp_sk_p" ] || continue
                        _cp_sk_pn="${_cp_sk_p%/}"
                        _cp_sk_pn="${_cp_sk_pn##*/}"
                        [ "$_cp_sk_pn" = "skills" ] && continue
                        # Read via _cp_read_manifest so CRLF manifests
                        # written by the cmd/PowerShell implementations
                        # still match.
                        if [ -f "${_cp_sk_p%/}/skills.conf" ] \
                            && _cp_read_manifest "${_cp_sk_p%/}/skills.conf" 2>/dev/null | grep -Fqx "$_cp_sk_name"; then
                            _cp_die "note: profile '${_cp_sk_pn}' still lists '${_cp_sk_name}' in skills.conf"
                        fi
                    done
                    printf 'Unregistered skill: %s\n' "$_cp_sk_name"
                    printf "Run 'claude-profile skills sync --all' to remove stale links from profiles.\\n"
                    ;;

                add|remove)
                    _cp_sk_op="$1"
                    shift
                    _cp_sk_name="${1:-}"
                    if [ -z "$_cp_sk_name" ]; then
                        _cp_die "usage: claude-profile skills ${_cp_sk_op} <skill> [profile]"
                        return 1
                    fi
                    if [ -n "${3:-}" ]; then
                        _cp_die "unexpected argument '$3'"
                        return 1
                    fi
                    _cp_validate_skill_name "$_cp_sk_name" || return 1
                    _cp_skills_profile "${2:-}" || return 1
                    _cp_sk_pdir="${_cp_data}/${_cp_sp_name}"
                    if [ "$_cp_sk_op" = "add" ] && [ ! -d "${_cp_sk_pool}/${_cp_sk_name}" ]; then
                        _cp_die "skill '${_cp_sk_name}' is not in the pool. Register it with: claude-profile skills register ${_cp_sk_name} <path>"
                        return 1
                    fi
                    _cp_skills_materialize_manifest "$_cp_sk_pdir" || { _cp_die "could not write skills.conf"; return 1; }
                    _cp_sk_file="${_cp_sk_pdir}/skills.conf"
                    # Membership and removal go through CR/whitespace
                    # trimming (not bare grep -x) so CRLF manifests written
                    # by the cmd/PowerShell implementations still match.
                    if [ "$_cp_sk_op" = "add" ]; then
                        if ! _cp_read_manifest "$_cp_sk_file" 2>/dev/null | grep -Fqx "$_cp_sk_name"; then
                            printf '%s\n' "$_cp_sk_name" >> "$_cp_sk_file" || return 1
                        fi
                        _cp_skills_sync_one "$_cp_sp_name" || return 1
                        printf "Added skill '%s' to profile '%s'\n" "$_cp_sk_name" "$_cp_sp_name"
                    else
                        awk -v n="$_cp_sk_name" '{
                            l = $0
                            sub(/\r$/, "", l)
                            gsub(/^[ \t]+/, "", l); gsub(/[ \t]+$/, "", l)
                            if (l == n) next
                            print
                        }' "$_cp_sk_file" > "${_cp_sk_file}.tmp.$$" 2>/dev/null
                        mv -f "${_cp_sk_file}.tmp.$$" "$_cp_sk_file" || { rm -f "${_cp_sk_file}.tmp.$$"; return 1; }
                        _cp_skills_sync_one "$_cp_sp_name" || return 1
                        printf "Removed skill '%s' from profile '%s'\n" "$_cp_sk_name" "$_cp_sp_name"
                    fi
                    ;;

                set)
                    shift
                    _cp_sk_list="${1:-}"
                    if [ -z "$_cp_sk_list" ]; then
                        _cp_die "usage: claude-profile skills set <skill1,skill2,...> [profile]"
                        return 1
                    fi
                    if [ -n "${3:-}" ]; then
                        _cp_die "unexpected argument '$3'"
                        return 1
                    fi
                    _cp_skills_profile "${2:-}" || return 1
                    _cp_sk_file="${_cp_data}/${_cp_sp_name}/skills.conf"
                    _cp_sk_tmp="${_cp_sk_file}.tmp.$$"
                    : > "$_cp_sk_tmp" || { _cp_die "could not write skills.conf"; return 1; }
                    _cp_sk_old_ifs="$IFS"
                    IFS=','
                    set -f
                    # shellcheck disable=SC2086  # word splitting on commas is the point
                    set -- $_cp_sk_list
                    set +f
                    IFS="$_cp_sk_old_ifs"
                    for _cp_sk_name in "$@"; do
                        [ -n "$_cp_sk_name" ] || continue
                        _cp_validate_skill_name "$_cp_sk_name" || { rm -f "$_cp_sk_tmp"; return 1; }
                        if [ ! -d "${_cp_sk_pool}/${_cp_sk_name}" ]; then
                            _cp_die "warning: skill '${_cp_sk_name}' is not in the pool"
                        fi
                        printf '%s\n' "$_cp_sk_name" >> "$_cp_sk_tmp"
                    done
                    mv -f "$_cp_sk_tmp" "$_cp_sk_file" || { rm -f "$_cp_sk_tmp"; return 1; }
                    _cp_skills_sync_one "$_cp_sp_name" || return 1
                    printf "Set skills for profile '%s'\n" "$_cp_sp_name"
                    ;;

                reset)
                    shift
                    if [ -n "${2:-}" ]; then
                        _cp_die "unexpected argument '$2'"
                        return 1
                    fi
                    _cp_skills_profile "${1:-}" || return 1
                    rm -f "${_cp_data}/${_cp_sp_name}/skills.conf"
                    _cp_skills_sync_one "$_cp_sp_name" || return 1
                    printf "Profile '%s' reset to all pool skills\n" "$_cp_sp_name"
                    ;;

                sync)
                    shift
                    if [ -n "${2:-}" ]; then
                        _cp_die "unexpected argument '$2'"
                        return 1
                    fi
                    if [ "${1:-}" = "--all" ]; then
                        # The ls guard keeps zsh's nomatch from aborting on
                        # an empty glob.
                        [ -n "$(ls "$_cp_data" 2>/dev/null)" ] && for _cp_sk_p in "$_cp_data"/*/; do
                            [ -d "$_cp_sk_p" ] || continue
                            _cp_sk_pn="${_cp_sk_p%/}"
                            _cp_sk_pn="${_cp_sk_pn##*/}"
                            [ "$_cp_sk_pn" = "skills" ] && continue
                            _cp_skills_sync_one "$_cp_sk_pn"
                            printf "Synced profile '%s'\n" "$_cp_sk_pn"
                        done
                    else
                        _cp_skills_profile "${1:-}" || return 1
                        _cp_skills_sync_one "$_cp_sp_name" || return 1
                        printf "Synced profile '%s'\n" "$_cp_sp_name"
                    fi
                    ;;

                "")
                    if [ ! -d "$_cp_sk_pool" ]; then
                        printf 'No skill pool yet. Register a skill with: claude-profile skills register <name> <path>\n'
                        return 0
                    fi
                    _cp_skills_profile "" || return 1
                    _cp_sk_pdir="${_cp_data}/${_cp_sp_name}"
                    if [ -f "${_cp_sk_pdir}/skills.conf" ]; then
                        printf "Profile '%s': skills.conf present (filtered)\n" "$_cp_sp_name"
                    else
                        printf "Profile '%s': no skills.conf (all pool skills)\n" "$_cp_sp_name"
                    fi
                    printf 'Skill pool: %s\n' "$_cp_sk_pool"
                    _cp_sk_desired=$(_cp_desired_skills "$_cp_sk_pdir" "$_cp_sk_pool")
                    _cp_sk_found=0
                    # The ls guard keeps zsh's nomatch from aborting on an
                    # empty glob.
                    [ -n "$(ls "$_cp_sk_pool" 2>/dev/null)" ] && for _cp_sk_e in "$_cp_sk_pool"/*; do
                        [ -d "$_cp_sk_e" ] || [ -L "$_cp_sk_e" ] || continue
                        _cp_sk_found=1
                        _cp_sk_n="${_cp_sk_e##*/}"
                        _cp_sk_dst="${_cp_sk_pdir}/skills/${_cp_sk_n}"
                        _cp_sk_status="not linked"
                        if [ ! -d "$_cp_sk_e" ]; then
                            _cp_sk_status="dangling (target missing)"
                        elif [ -L "$_cp_sk_dst" ]; then
                            _cp_sk_t=$(_cp_link_target "$_cp_sk_dst") || _cp_sk_t=""
                            if _cp_target_in_pool "$_cp_sk_t" "$_cp_sk_pool"; then
                                _cp_sk_status="linked"
                            else
                                _cp_sk_status="conflict (unmanaged entry)"
                            fi
                        elif [ -e "$_cp_sk_dst" ]; then
                            _cp_sk_status="conflict (unmanaged entry)"
                        elif printf '%s\n' "$_cp_sk_desired" | grep -Fqx "$_cp_sk_n"; then
                            _cp_sk_status="selected, not linked (run sync)"
                        fi
                        printf '  %-24s %s\n' "$_cp_sk_n" "$_cp_sk_status"
                    done
                    if [ "$_cp_sk_found" -eq 0 ]; then
                        printf '  (pool is empty)\n'
                    fi
                    ;;

                *)
                    _cp_die "unknown skills command '$1'. Run 'claude-profile help' for usage."
                    return 1
                    ;;
            esac
            ;;

        version)
            _cp_installed_version
            ;;

        update)
            shift
            _cp_do_update "${1:-}"
            ;;

        help|-h|--help)
            cat <<'HELPEOF'
Usage: claude-profile [command] [args...]

Commands:
    (no command)            Show current profile status
    use <name>              Switch session to the named profile (pins it)
    create [--init] <name>  Create a new profile (--init writes a settings.json skeleton)
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
switches the shell to that profile on cd, and reverts on leaving. An
explicit 'claude-profile use' pins the session and wins over any
.claude-profile until 'claude-profile auto on'. Set
CLAUDE_PROFILE_NO_AUTO_SWITCH=1 to disable, CLAUDE_PROFILE_AUTO_QUIET=1
to switch silently.

Skills: a shared pool at <data-dir>/skills holds registered skills. A
profile's skills.conf (one name per line, # comments) selects the subset
linked into <profile>/skills; without one the profile gets every pool
skill. Hand-made entries in <profile>/skills are never touched.

Examples:
    claude-profile create work
    claude-profile create --init work
    claude-profile skills register humanize ~/skills/humanize
    claude-profile skills set humanize,optimize work
    claude-profile default work
    claude-profile use work
    claude                          # runs with "work" profile
    claude-profile                  # shows active/default status
    claude-profile local work       # pin this directory tree to "work"
    claude-profile local --remove   # drop the directory-local profile
HELPEOF
            ;;

        "")
            # Bare invocation: show status
            _cp_active=""
            if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
                case "$CLAUDE_CONFIG_DIR" in
                    "${_cp_data}"/*)
                        _cp_active=$(basename "$CLAUDE_CONFIG_DIR")
                        ;;
                esac
            fi
            if [ -n "$_cp_active" ]; then
                if [ "${CLAUDE_CONFIG_DIR:-}" = "${CLAUDE_PROFILE_AUTO_SET:-}" ] && _cp_find_dotfile "${PWD:-}"; then
                    printf 'Active profile: %s (from %s)\n' "$_cp_active" "$_cp_dotfile"
                else
                    printf 'Active profile: %s\n' "$_cp_active"
                fi
                printf 'Config directory: %s\n' "$CLAUDE_CONFIG_DIR"
            elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
                printf 'Active config directory: %s (not a managed profile)\n' "$CLAUDE_CONFIG_DIR"
            else
                printf 'No active profile\n'
            fi
            _cp_cur_default=""
            if [ -f "$_cp_default_file" ]; then
                _cp_cur_default=$(cat "$_cp_default_file")
            fi
            if [ -n "$_cp_cur_default" ]; then
                printf 'Default profile: %s\n' "$_cp_cur_default"
            else
                printf 'No default profile set\n'
            fi
            # Skills annotation for the active (else default) profile;
            # silent until a skill pool exists.
            if [ -d "${_cp_data}/skills" ]; then
                _cp_sk_prof="$_cp_active"
                [ -n "$_cp_sk_prof" ] || _cp_sk_prof="$_cp_cur_default"
                if [ -n "$_cp_sk_prof" ] && [ -d "${_cp_data}/${_cp_sk_prof}" ]; then
                    _cp_sk_pool_n=$(_cp_pool_skills "${_cp_data}/skills" | grep -c .)
                    if [ -f "${_cp_data}/${_cp_sk_prof}/skills.conf" ]; then
                        _cp_sk_n=$(_cp_read_manifest "${_cp_data}/${_cp_sk_prof}/skills.conf" 2>/dev/null | grep -c .)
                        printf 'Skills: %s of %s pool skills (filtered)\n' "$_cp_sk_n" "$_cp_sk_pool_n"
                    else
                        printf 'Skills: all pool skills (%s)\n' "$_cp_sk_pool_n"
                    fi
                fi
            fi
            ;;

        *)
            _cp_die "unknown command '$1'. Run 'claude-profile help' for usage."
            return 1
            ;;
    esac
}
