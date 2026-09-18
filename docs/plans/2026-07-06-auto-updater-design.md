# Auto-Updater Design

**Date:** 2026-07-06
**Status:** Approved (v2 — revised after review)

## Problem

The tool has no way to tell a user their `claude-profile.sh` / `claude-profile-init.ps1`
/ `claude-profile.cmd` install is out of date. Today, upgrading means re-running the
install one-liner manually and hoping to remember to do so. There's also no version
marker anywhere in the repo besides the `v1.0.0` git tag — nothing installed on a
user's machine records what version they're running.

## Scope

Updates the **tool only** — `claude-profile.sh`, `claude-profile-init.ps1`,
`claude-profile.cmd`, and their installed `VERSION` file. Per-profile data under
`$XDG_DATA_HOME/claude-profiles/` (or `%LOCALAPPDATA%\claude-profiles\`) is untouched.

## Decision

### 1. Version tracking — separate `VERSION` file

A standalone `VERSION` file (plain text, e.g. `1.0.0`, no trailing newline — matching
the `.default` file convention) is installed alongside the scripts in the tool's
install dir:

- `$XDG_DATA_HOME/claude-profile/VERSION` (Linux/macOS/WSL, default
  `~/.local/share/claude-profile/VERSION`)
- `%LOCALAPPDATA%\claude-profile\VERSION` (Windows, including Git Bash/MSYS2)

Note the singular `claude-profile/` — the existing install directory, distinct from
the plural `claude-profiles/` profile-data directory (see `CLAUDE.md`).

`install.sh` / `install.ps1` write this file at install time, alongside the scripts
they already download. Each release bumps the `VERSION` file content and the git tag
together.

**Pre-existing installs with no `VERSION` file**: any install performed before this
feature shipped has no `VERSION` file. Treat this as an explicit "unknown" state, not
an error:

- The passive check (below) skips the numeric "newer than" comparison and always
  shows the notice once for the current known-latest version (using the same
  notified-flag mechanism as any other version).
- `claude-profile update` prints `unknown → vX.Y.Z` in place of the old version, and
  proceeds unconditionally (an unknown version is always treated as behind).

### 2. Passive check mechanism

Hook points (only the common path per implementation, not an extra always-on
background process):

- **sh / ps1**: inside the `claude()` wrapper, on every invocation.
- **cmd**: inside `claude-profile.cmd`'s command dispatch (any subcommand), since cmd
  has no transparent `claude()` wrapper to hook into.

**Opt-out**: if the environment variable `CLAUDE_PROFILE_NO_UPDATE_CHECK` is set (to
any non-empty value), skip this entire mechanism — no cache read, no network call, no
stderr output. Checked first, before anything else below. Implemented identically
across sh/ps1/cmd and documented in the README.

**Cache file schema**: `$XDG_DATA_HOME/claude-profile/.update-check` (mirrored path on
Windows) is a plain-text file, three lines:

```
<unix epoch seconds of last check>
<latest known version string, e.g. 1.1.0, or "unknown">
<notified flag: 0 or 1>
```

All three implementations read and write this exact three-line format so the cache is
shared correctly regardless of which shell touches it. Writes use the same
write-to-temp-file-then-rename pattern as the script update (section 3) — never an
in-place truncate-and-write — so a crash or two concurrent `claude` invocations racing
to write it can't leave a torn file. If the cache file exists but fails to parse (e.g.
a torn write from a version of this tool predating the atomic-write fix, or manual
corruption), treat it identically to "cache file doesn't exist": proceed to the
network-check branch below rather than erroring, and let the next successful write
self-heal it.

Behavior on each hook:

1. Read the cache file (see schema above).
2. If last-checked was less than 24h ago, skip the network call entirely and only
   act on the cached result (see step 4).
3. If 24h+ has elapsed (or the cache file doesn't exist / doesn't parse): query
   `https://api.github.com/repos/quinnjr/claude-code-profiles/releases/latest`
   with a short timeout (2-3s connect/max-time). Extract `tag_name` via a strict,
   quoted parse (e.g. an anchored `"tag_name":"..."` match, not free-form text
   extraction), strip a leading `v` so it's in the same `MAJOR.MINOR.PATCH` format as
   the local `VERSION` file, and validate it against `^[0-9]+\.[0-9]+\.[0-9]+$` —
   treat a non-matching value the same as a network failure (below).

   Compare the validated version against the local `VERSION` **numerically**: split
   both strings on `.` and compare each segment (major, minor, patch) as an integer,
   left to right — never a lexicographic string comparison (`"1.9.0" > "1.10.0"` as a
   string, which is wrong). cmd's implementation needs an explicit segment-splitting
   loop since batch has no native version-compare primitive; PowerShell can cast to
   `[version]`; POSIX sh needs a small field-by-field numeric comparison.

   Write the result back to the cache file (new timestamp, latest version, reset
   "notified" flag to `0` if the version differs from what was previously cached).

   Two distinct failure tiers on this step:
   - **Network/API failures** — timeout, no connectivity, non-200 response,
     rate-limited, malformed JSON, or a `tag_name` that fails validation above —
     **silently skip**. Still update the timestamp (so a fully offline machine
     doesn't retry the network call on every invocation), but leave the cached
     version/notified state untouched.
   - **Local cache-file I/O failures** — the cache path itself can't be read/created/
     written (permissions, disk full, missing parent directory) — this is not
     transient and will recur on every invocation forever if never surfaced. Print a
     single diagnostic line to stderr at most once per calendar day (reuse the
     timestamp field to rate-limit it) rather than staying silent indefinitely, but
     never block or fail the hot path because of it.
4. If the cached latest version is newer than the installed `VERSION` (numeric
   comparison; "unknown" installed version always counts as behind) **and** the
   "notified" flag for that version is not yet set: print one line to stderr —

   ```
   A new claude-profile version is available (v1.0.0 → v1.1.0). Run 'claude-profile update' to upgrade.
   ```

   then set the "notified" flag for that version in the cache file. On subsequent
   invocations, stay silent about that same version (avoids nagging every command).
   If an even newer version later appears, the flag resets and the notice fires once
   more for the new version.

This check must never meaningfully delay `claude` startup or `claude-profile`
dispatch — the timeout is short, network failures are silent, local I/O failures are
rate-limited rather than blocking, and the common case (checked within 24h) does zero
network I/O.

### 3. Update command — dedicated logic per implementation

New `claude-profile update` subcommand, implemented independently in each of the
three files (not reusing `install.sh`/`install.ps1`):

1. Fetch a signed release manifest (published alongside each GitHub Release — e.g. a
   `SHA256SUMS.asc` covering the `VERSION` file and all three scripts, signed with a
   maintainer GPG key or via a signed git tag) plus the `VERSION` file and the
   matching script for that implementation (`claude-profile.sh`,
   `claude-profile-init.ps1`, or `claude-profile.cmd`) from the raw GitHub URLs
   referenced in `CLAUDE.md`
   (`https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/...`).
   Use an explicit timeout on every fetch (10-15s connect / 30-60s max-time — longer
   than the passive check's since this is a foreground command the user is actively
   waiting on, but still bounded so a stalled connection fails within a predictable
   window instead of hanging the terminal indefinitely).
2. Verify the manifest's signature, then verify the downloaded `VERSION` file and
   script both match their entries in that one signed manifest — this binds the two
   files together so they can't be independently mismatched or tampered with.
3. Compare the fetched `VERSION` against the installed `VERSION` using the same
   numeric comparison as section 2. If the fetched version is not strictly greater
   (and the installed version isn't "unknown"), abort with a clear message — do not
   downgrade — unless the user passes an explicit `--force` / `--allow-downgrade`
   flag.
4. Download to a temp file first (sh: `mktemp` + `trap ... EXIT`, matching
   `install.sh`'s existing pattern; ps1: a temp path via the standard temp dir with
   `try`/`finally`; cmd: a temp file in `%TEMP%`). For cmd specifically — batch has no
   equivalent of a POSIX trap — every exit point in this flow (signature-check
   failure, manifest-mismatch failure, version-check-abort, download failure,
   atomic-replace failure, success) must `goto` a single idempotent cleanup label
   rather than `exit /b` directly, so no path can skip temp-file removal.
5. Only after signature verification, manifest-match verification, and the
   version-monotonicity check all pass, atomically replace the installed script and
   `VERSION` file (rename/move over the old files).
6. On any failure (network error, timeout, empty/truncated download, signature
   mismatch, manifest mismatch, downgrade blocked without `--force`), leave the
   existing install untouched, clean up the temp file, and print an error. No partial
   upgrade is ever left in place. Exit code is `0` on success and `1` on any failure
   path, identically across sh/ps1/cmd. Output messages follow a shared template
   across all three implementations:
   - Success: `Updating <script>: v<old> -> v<new>` (or `unknown -> v<new>`)
   - Failure: `Error: update failed: <reason>`
7. On success, print old → new version. For sh/ps1, remind the user to re-source
   their shell config (`source ~/.bashrc` / `. $PROFILE` or equivalent) since a
   running shell can't hot-swap already-sourced functions. cmd needs no such
   reminder — `call claude-profile.cmd` re-reads the file fresh every invocation.

**Manual verification note** (this repo has no automated test suite — verification is
manual, per existing convention): to exercise the "leaves existing install untouched
on failure" guarantee, point the download URL at an unreachable host (or block it via
hosts file/firewall) and run `claude-profile update`; confirm the installed script's
version/mtime and `VERSION` file are unchanged and that no temp file remains in
`$TMPDIR`/`%TEMP%`. To exercise the passive-check notify/reset behavior without
publishing real releases, hand-write the `.update-check` cache file (per the schema in
section 2) with a fabricated newer version and `notified=0`, run the hot path once to
confirm the notice fires, confirm it's suppressed on the next run, then edit the cache
again with an even newer fabricated version to confirm the notice reappears. To force
a re-check without waiting 24h, delete the cache file.

### 4. Version query command

A `claude-profile version` (or `--version`) subcommand prints the local `VERSION` file
content only (or `unknown` if absent) — no network call, no cache interaction.
Implemented identically across sh/ps1/cmd, so a user can check their installed
version without depending on or triggering the passive-check path.

### 5. Error handling & offline behavior

- Every network call (passive check and `update`) uses a short, explicit timeout and
  fails gracefully on the network/API side. This tool's core purpose — managing local
  profile directories — has no dependency on connectivity, and the updater must never
  break that.
- Local cache-file I/O failures are treated differently from network failures (see
  section 2) — surfaced at a rate-limited cadence rather than swallowed forever, so a
  persistent local misconfiguration doesn't go undetected indefinitely.
- Unauthenticated GitHub API rate limits (60 req/hr per IP) are a non-issue at a
  once-per-24h-per-user cadence.

## User Experience

```sh
# Normal usage — passive check runs silently in the background of the common path
claude
# stderr, only once when a new version first becomes known:
# A new claude-profile version is available (v1.0.0 → v1.1.0). Run 'claude-profile update' to upgrade.

# Check installed version without triggering any network call
claude-profile version
# 1.0.0

# Explicit upgrade
claude-profile update
# Updating claude-profile.sh: v1.0.0 -> v1.1.0
# Done. Run 'source ~/.zshrc' (or restart your shell) to use the new version.

# Opt out of passive checks entirely
export CLAUDE_PROFILE_NO_UPDATE_CHECK=1
```

## File Changes

- `claude-profile.sh`: add version check (with opt-out) inside `claude()`; add
  `update` and `version` cases to `claude-profile()` dispatch.
- `claude-profile-init.ps1`: same additions, PowerShell equivalents.
- `claude-profile.cmd`: add version check to command dispatch; add `update` and
  `version` labels; single idempotent cleanup label for all `update` exit paths.
- `install.sh` / `install.ps1`: write `VERSION` file alongside the scripts at install
  time; add an explicit download timeout (this fixes a gap in the *existing*
  untimed `download_file`/`Invoke-WebRequest` calls, surfaced during this review).
- Release process: publish a signed checksum manifest (e.g. `SHA256SUMS.asc`) covering
  `VERSION` and all three scripts alongside each GitHub Release.
- `README.md`: document `claude-profile update`, `claude-profile version`, the
  passive-check notice's exact text/trigger/throttling, the `CLAUDE_PROFILE_NO_UPDATE_CHECK`
  opt-out, and the post-update re-source caveat for sh/ps1.

## Out of Scope

- Updating per-profile data/configs.
- Auto-applying updates without an explicit `claude-profile update` run.
- Retry/backoff on the network calls (single-shot, fail-silent/fail-fast is
  sufficient for a low-frequency interactive tool — matches the existing installer's
  approach).
