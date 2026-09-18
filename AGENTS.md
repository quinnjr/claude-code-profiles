# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Cross-platform shell functions for managing multiple Claude Code configuration profiles via `CLAUDE_CONFIG_DIR`. Each profile is a complete, isolated config directory. A transparent `claude()` wrapper auto-resolves the active profile so users just run `claude` normally.

Three equivalent implementations: POSIX sh (sourced), PowerShell (dot-sourced), and Windows cmd batch.

## Architecture

The POSIX and PowerShell implementations are sourceable function files (not standalone scripts). They each define two functions: `claude()` (transparent wrapper) and `claude-profile()` (management). The cmd batch script is standalone since cmd lacks a function-sourcing mechanism.

- **`claude-profile.sh`** (POSIX sh) — reference implementation. Sourced in `.bashrc`/`.zshrc`. Provides `claude()` wrapper that auto-resolves the default profile before calling the real binary via `command claude`. Provides `claude-profile()` for management commands. Strict POSIX only: no `local`, no `[[ ]]`, no arrays, no bashisms. Uses `printf` over `echo`, `_cp_`-prefixed variables, `return` (not `exit` — runs in user's shell). On Git Bash / MSYS2 (detected via `$MSYSTEM`), profiles are stored at `%LOCALAPPDATA%\claude-profiles\` and paths are converted via `cygpath -w` before invoking `claude.exe` so they are shared with the cmd/PowerShell implementations.
- **`claude-profile-init.ps1`** (PowerShell 5.1+/pwsh 6+) — cross-platform. Dot-sourced in `$PROFILE`. Same two-function model. Uses `$args` manual parsing (not `param()`) to avoid conflicts with PowerShell parameter binding. `Get-Command -CommandType Application` to find the real `claude` binary past the function.
- **`claude-profile.cmd`** (Windows batch) — standalone script. Uses `goto :label` dispatch, `setlocal enabledelayedexpansion`, `endlocal & set` idiom to leak `CLAUDE_CONFIG_DIR` to the caller. No transparent `claude` wrapper (cmd limitation). Users run `call claude-profile.cmd use <name>` then `claude` separately.

Profile data lives at `$XDG_DATA_HOME/claude-profiles/` (Linux/macOS/WSL, default `~/.local/share/claude-profiles/`) or `%LOCALAPPDATA%\claude-profiles\` (Windows, including Git Bash/MSYS2). A `.default` file stores the default profile name as plain text without trailing newline.

The tool itself is installed at `$XDG_DATA_HOME/claude-profile/` (Linux/macOS) or `%LOCALAPPDATA%\claude-profile\` (Windows) — note the singular form, distinct from the plural `claude-profiles/` data directory.

## Command Interface

All three implementations share the same command interface:

| Command | Description |
|---------|-------------|
| `claude-profile` | Show current profile status (active + default) |
| `claude-profile use <name>` | Switch to a profile for the current session |
| `claude-profile create <name>` | Create a new profile |
| `claude-profile list` | List all profiles (marks default and active) |
| `claude-profile default [name]` | Get or set the default profile |
| `claude-profile local [name]` | Show, set, or `--remove` the directory-local `.claude-profile` |
| `claude-profile auto [on\|off\|status]` | Control directory-local auto-switching (sh/ps1 only) |
| `claude-profile skills ...` | Manage the shared skill pool and per-profile selections (see below) |
| `claude-profile which [name]` | Show the resolved config directory path |
| `claude-profile delete <name>` | Delete a profile (with confirmation) |
| `claude-profile help` | Show help |

## Directory-Local Profiles

A `.claude-profile` file (first non-empty, non-comment line = profile name) switches `CLAUDE_CONFIG_DIR` when the shell enters that directory or any descendant, and reverts on leaving. An explicit `claude-profile use` pins the session and wins until `claude-profile auto on`.

The pin is tracked via an exported `CLAUDE_PROFILE_AUTO_SET` marker: auto-switching only manages `CLAUDE_CONFIG_DIR` when its value equals that marker, so anything set by hand (or inherited from outside) is left alone. Exporting it means nested shells keep auto-managing rather than treating the inherited value as manual.

Directory-change hooks differ per shell: zsh `chpwd`, bash `PROMPT_COMMAND`, `cd` wrapper elsewhere; PowerShell 6+ `LocationChangedAction`, PowerShell 5.1 `prompt` wrapper. cmd.exe has no hook — a bare `call claude-profile.cmd` resolves the dotfile at invocation time instead.

Because bash re-runs the resolver on every prompt, `_cp_auto_switch` short-circuits when `$PWD` is unchanged and the upward walk uses only parameter expansion (no `dirname` fork per component). That short-circuit also rate-limits the "invalid/missing profile" warnings to once per directory entry.

## Per-Profile Skills

A shared skill pool lives at `<data-root>/skills/` (the profile name
`skills` is therefore reserved and rejected by validation in all three
implementations, including the `.claude-profile` resolvers). `skills
register <name> <path>` links a skill source directory (must contain
`SKILL.md`) into the pool — `ln -s` on POSIX, directory junctions
(`mklink /J`, no admin rights) on Windows including via Git Bash
(`cmd //c mklink /J` + `cygpath -w`) so all three implementations share
the links.

Each profile may have a `skills.conf` manifest (one pool-skill name per
line, `#` comments, same parser style as `.claude-profile`). Absent
manifest = all pool skills (backward-compatible default); empty manifest
= none. `skills add`/`remove` first materialize the implicit "all" list
into `skills.conf` so edits stay sticky.

Sync (`skills sync`, also run by `create` and every manifest-editing
command) is two-pass: remove managed links that are dangling or
undesired, then create missing ones. A link is *managed* iff its literal
target lies under the pool directory — anything else in
`<profile>/skills/` (hand-made symlinks, real dirs) is never touched;
name collisions warn and the unmanaged entry wins. Sync never runs on
`use` or the auto-switch hot path. In cmd, link targets are read by
parsing `dir /AL` output and managed detection is an exact-target
comparison against `<pool>\<name>`.

## Validation Rules

Profile names must match `[A-Za-z0-9_-]+`. Reject: empty, starts with `.`, contains `/` or `\` or `..`. This prevents path traversal — all three implementations enforce this identically.

## Checking Scripts

```sh
shellcheck claude-profile.sh         # Lint POSIX sh function file
checkbashisms claude-profile.sh      # Verify no bashisms (hyphenated function name is expected)
```

No build step. No test framework. Manual verification by running commands against real profiles.

## Branching Model

This project uses git-flow. Branch types:

- **`main`** — stable, release-ready. Never commit directly; merge via PR only.
- **`develop`** — integration branch for next release. Feature branches merge here.
- **`feature/*`** — new features and non-trivial changes. Branch from `develop`, merge back to `develop`.
- **`release/*`** — release prep (version bumps, changelog). Branch from `develop`, merge to both `main` and `develop`.
- **`hotfix/*`** — urgent fixes for production. Branch from `main`, merge to both `main` and `develop`.

Use `git worktree` (via `.worktrees/`) for parallel branch work.

## When Modifying

Any behavioral change must be applied to all three implementations (`claude-profile.sh`, `claude-profile.cmd`, `claude-profile-init.ps1`) plus updated in `README.md`. The install scripts (`install.sh`, `install.ps1`) reference `https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/` for download URLs.
