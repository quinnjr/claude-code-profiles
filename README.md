# claude-profile

Manage multiple [Claude Code](https://code.claude.com) configuration profiles. Switch between work and personal accounts, different MCP server setups, or separate settings without logging in and out.

Each profile is a complete, isolated Claude Code configuration directory (settings, credentials, MCP servers, CLAUDE.md, history -- everything). Once configured, `claude` automatically uses your active profile -- no special launch command needed.

## Install

**Linux / macOS / WSL / Git Bash (MSYS2):**

```sh
curl -fsSL https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/install.sh | sh
```

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/install.ps1 | iex
```

The installer downloads the appropriate scripts and configures your shell. **Restart your shell** (or open a new terminal) after installing.

## Quick Start

```sh
# Create profiles
claude-profile create work
claude-profile create personal

# Set a default
claude-profile default work

# Just use claude — it automatically uses your default profile
claude
claude --resume
claude -p "explain this code"
```

## Commands

| Command | Description |
|---------|-------------|
| `claude-profile` | Show current profile status |
| `claude-profile use <name>` | Switch to a profile for this session |
| `claude-profile create <name>` | Create a new profile |
| `claude-profile list` | List all profiles |
| `claude-profile default [name]` | Get or set the default profile |
| `claude-profile local [name]` | Show, set, or `--remove` this directory's `.claude-profile` |
| `claude-profile auto [on\|off\|status]` | Control directory-local auto-switching (not on cmd.exe) |
| `claude-profile skills` | List pool skills and their status for the profile |
| `claude-profile skills register <name> <path>` | Add a skill directory to the shared pool |
| `claude-profile skills unregister [--force] <name>` | Remove a skill from the pool |
| `claude-profile skills add <skill> [profile]` | Add a pool skill to a profile |
| `claude-profile skills remove <skill> [profile]` | Remove a pool skill from a profile |
| `claude-profile skills set <s1,s2,...> [profile]` | Replace a profile's skill selection |
| `claude-profile skills reset [profile]` | Back to the default (all pool skills) |
| `claude-profile skills sync [profile\|--all]` | Re-materialize skill links |
| `claude-profile delete <name>` | Delete a profile (with confirmation) |
| `claude-profile which [name]` | Show the config directory path |
| `claude-profile version` | Show the installed version |
| `claude-profile update [--force]` | Update to the latest release |
| `claude-profile help` | Show help |

## How It Works

Claude Code supports a `CLAUDE_CONFIG_DIR` environment variable that redirects where it stores configuration and data. `claude-profile` provides a `claude()` shell function that wraps the real `claude` binary:

1. On each directory change, the nearest `.claude-profile` file (if any) sets `CLAUDE_CONFIG_DIR` — see [Per-Directory Profiles](#per-directory-profiles).
2. Before each invocation, the wrapper checks if a default profile exists and auto-sets `CLAUDE_CONFIG_DIR`.
3. If `CLAUDE_CONFIG_DIR` is already set (e.g., via `claude-profile use`), it is used as-is.
4. The real `claude` binary is then called with all your arguments.

This means you never need to think about profiles during normal use -- just run `claude` as you always have.

### Session Override

To temporarily use a different profile in the current shell session:

```sh
# Temporarily use a different profile
claude-profile use personal
claude                          # uses "personal" for this shell session
```

The override lasts until you close the shell or run `claude-profile use` again.

### Per-Directory Profiles

A directory can pin itself (and everything under it) to a profile by holding
a `.claude-profile` file whose first non-empty, non-comment line is a profile
name:

```sh
cd ~/work/acme
claude-profile local work        # writes ./.claude-profile containing "work"
```

Your shell now switches to `work` whenever you `cd` into that tree, and back
to the default when you leave:

```
$ cd ~/work/acme/api
claude-profile: switched to profile 'work' (from /home/you/work/acme/.claude-profile)
$ cd ~
claude-profile: directory profile cleared; using the default profile
```

The file is plain text — you can commit it to a repo, and blank lines and
`#` comments are ignored:

```
# every checkout of this repo uses the client's isolated profile
client-acme
```

Precedence and control:

- An explicit `claude-profile use <name>` **pins** the session: it wins over
  any `.claude-profile` until you run `claude-profile auto on`, which clears
  the pin and re-resolves the current directory.
- `claude-profile auto off` disables auto-switching for the session;
  `claude-profile auto status` shows what's in effect.
- `CLAUDE_PROFILE_NO_AUTO_SWITCH=1` disables it entirely,
  `CLAUDE_PROFILE_AUTO_QUIET=1` switches silently.
- A `.claude-profile` naming a profile that doesn't exist (or an invalid
  name) is reported on stderr once per directory entry and otherwise ignored.
- `claude-profile local --remove` deletes the `.claude-profile` in the
  current directory.

Hooking into directory changes is per-shell: zsh uses `chpwd`, bash uses
`PROMPT_COMMAND`, and other POSIX shells get a `cd` wrapper. PowerShell 6+
uses `LocationChangedAction`; Windows PowerShell 5.1 hooks the `prompt`
function.

**cmd.exe is different.** It has no `cd` hook and no transparent `claude`
wrapper, so it can't switch automatically. Instead, a bare
`call claude-profile.cmd` prefers the nearest `.claude-profile` over the
default profile, and `claude-profile local <name>` writes the file:

```bat
claude-profile local work
call claude-profile
claude
```

### Per-Profile Skills

Skills usually have to be curated by hand per config directory. `claude-profile`
can instead manage them from a **shared pool** at `<data-dir>/skills/`
(next to your profile directories), with each profile selecting the subset
it wants — so a `backend` profile only loads backend skills, keeping
context lean:

```sh
# Register skills into the pool (each path must contain a SKILL.md)
claude-profile skills register api-design ~/skills/api-design
claude-profile skills register ui-design  ~/skills/ui-design

# Pick subsets per profile
claude-profile skills set api-design backend
claude-profile skills set ui-design frontend

# Or tweak incrementally
claude-profile skills add ui-design backend
claude-profile skills remove ui-design backend
```

How it works:

- Registering creates a symlink (a directory **junction** on Windows — no
  admin rights needed) in the pool; the pool entry name is what profiles
  refer to.
- A profile's selection lives in `<profile>/skills.conf` — plain text, one
  skill name per line, `#` comments allowed. **No `skills.conf` means the
  profile gets every pool skill**, so existing profiles keep working
  unchanged. An empty file means none.
- Syncing materializes the selection as links in `<profile>/skills/`. The
  tool only ever creates or removes links that point into the pool —
  hand-made symlinks, real directories, and files in `<profile>/skills/`
  are never touched (a name collision is reported and the unmanaged entry
  wins).
- Links update only when you run a `skills` command (or at
  `claude-profile create`) — switching profiles does no filesystem work.
  After registering or unregistering pool skills, run
  `claude-profile skills sync --all` to propagate.
- The profile name `skills` is reserved for the pool directory.

Filtered profiles are annotated in `claude-profile list` (e.g.
`work [skills: 3/12]`) and in the bare `claude-profile` status output
(`Skills: 3 of 12 pool skills (filtered)`). (cmd.exe has no bare status
command, so there the annotation appears in `list` only.)

### Profile Storage

Profiles are stored in platform-appropriate locations:

| Platform | Location |
|----------|----------|
| Linux | `$XDG_DATA_HOME/claude-profiles/` (default: `~/.local/share/claude-profiles/`) |
| macOS | `$XDG_DATA_HOME/claude-profiles/` (default: `~/.local/share/claude-profiles/`) |
| Windows | `%LOCALAPPDATA%\claude-profiles\` |
| Git Bash / MSYS2 | `%LOCALAPPDATA%\claude-profiles\` (shared with cmd/PowerShell) |

Each profile directory is a complete Claude Code config directory. After creating a profile and launching Claude with it, Claude will populate it with `settings.json`, `.credentials.json`, and everything else it needs.

### Profile Names

Profile names can contain letters, digits, hyphens, and underscores. Examples: `work`, `personal`, `client-acme`, `side_project`.

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

If the update-check cache itself can't be written (permissions, a full
disk), you'll see a similar one-time-per-day warning instead:

```
claude-profile: warning: could not write update-check cache in ~/.local/share/claude-profile -- update notifications may not work until this is fixed
```

This doesn't block `claude` from running — it's just letting you know
update notifications may be unreliable until the underlying issue is
fixed.

## Platform Support

| Script | Platform | Shell |
|--------|----------|-------|
| `claude-profile.sh` | Linux, macOS, WSL, Git Bash / MSYS2 | bash, zsh (sourced) |
| `claude-profile-init.ps1` | Windows, Linux, macOS | PowerShell 5.1+ / pwsh 6+ (dot-sourced) |
| `claude-profile.cmd` | Windows | cmd.exe (use with `call` prefix) |

### Git Bash / MSYS2 Support

On Git Bash and other MSYS2-based shells on Windows, `claude-profile.sh` automatically detects the environment and:

- Stores profiles at `%LOCALAPPDATA%\claude-profiles\` (shared with cmd.exe and PowerShell implementations)
- Converts Unix-style paths to Windows-native paths via `cygpath -w` before passing them to the native `claude.exe` binary
- Uses the `MSYSTEM` environment variable for detection (`MINGW64`, `MINGW32`, `MSYS`, etc.)

This means Git Bash users share the same profile data with cmd.exe and PowerShell on the same machine — no duplication or conflicts.

## Manual Install

If you prefer not to use the install scripts:

**Linux / macOS:**

```sh
# Download
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile"
curl -fsSL https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/claude-profile.sh \
  -o "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile/claude-profile.sh"

# Add to shell profile (.bashrc or .zshrc)
echo '. "${XDG_DATA_HOME:-$HOME/.local/share}/claude-profile/claude-profile.sh"' >> ~/.bashrc
```

**Windows (PowerShell):**

```powershell
$dir = "$env:LOCALAPPDATA\claude-profile"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/claude-profile-init.ps1" -OutFile "$dir\claude-profile-init.ps1"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/quinnjr/claude-code-profiles/main/claude-profile.cmd" -OutFile "$dir\claude-profile.cmd"
# Add to PowerShell profile
Add-Content -Path $PROFILE -Value ". '$dir\claude-profile-init.ps1'"
# Add to PATH for cmd.exe
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path -notlike "*$dir*") { [Environment]::SetEnvironmentVariable('Path', "$path;$dir", 'User') }
```

## License

MIT
