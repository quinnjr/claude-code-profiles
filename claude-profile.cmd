@echo off
setlocal enabledelayedexpansion

:: --- Platform-aware data directory ---
:: Uses %LOCALAPPDATA%\claude-profiles on Windows
set "DATA_DIR=%LOCALAPPDATA%\claude-profiles"
set "DEFAULT_FILE=%DATA_DIR%\.default"

:: --- Version tracking ---
set "_CP_INSTALL_DIR=%LOCALAPPDATA%\claude-profile"
set "_CP_VERSION_FILE=%_CP_INSTALL_DIR%\VERSION"
set "_CP_UPDATE_CACHE=%_CP_INSTALL_DIR%\.update-check"
set "_CP_REPO_API=https://api.github.com/repos/quinnjr/claude-code-profiles"
if defined CLAUDE_PROFILE_UPDATE_API_BASE set "_CP_REPO_API=%CLAUDE_PROFILE_UPDATE_API_BASE%"
set "_CP_ASSET_BASE=https://github.com/quinnjr/claude-code-profiles/releases/download"
if defined CLAUDE_PROFILE_UPDATE_ASSET_BASE set "_CP_ASSET_BASE=%CLAUDE_PROFILE_UPDATE_ASSET_BASE%"
set "_CP_UPDATE_INTERVAL=86400"
if defined CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL set "_CP_UPDATE_INTERVAL=%CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL%"
echo %_CP_UPDATE_INTERVAL%| findstr /R "^[0-9][0-9]*$" >nul 2>&1 || set "_CP_UPDATE_INTERVAL=86400"

:: --- Dispatcher ---
call :cp_update_check
:: No arguments: launch with default profile
if "%~1"=="" goto :cmd_launch_default

:: Command dispatch
if "%~1"=="create"  goto :dispatch_create
if "%~1"=="local"   goto :dispatch_local
if "%~1"=="list"    goto :dispatch_list
if "%~1"=="ls"      goto :dispatch_list
if "%~1"=="default" goto :dispatch_default
if "%~1"=="which"   goto :dispatch_which
if "%~1"=="use"     goto :dispatch_use
if "%~1"=="delete"  goto :dispatch_delete
if "%~1"=="help"    goto :usage
if "%~1"=="-h"      goto :usage
if "%~1"=="--help"  goto :usage
if "%~1"=="version" goto :dispatch_version
if "%~1"=="update"  goto :dispatch_update
if "%~1"=="skills"  goto :dispatch_skills

:: Flags without a subcommand are not supported
set "_first=%~1"
if "!_first:~0,1!"=="-" (
    echo claude-profile: unknown command '%~1'. Run 'claude-profile help' for usage. >&2
    exit /b 1
)

:: Unknown command
echo claude-profile: unknown command '%~1'. Run 'claude-profile help' for usage. >&2
exit /b 1

:: --- Dispatch helpers (shift then jump) ---

:dispatch_create
shift
goto :cmd_create

:dispatch_local
shift
goto :cmd_local

:dispatch_list
shift
goto :cmd_list

:dispatch_default
shift
goto :cmd_default

:dispatch_which
shift
goto :cmd_which

:dispatch_use
shift
goto :cmd_use

:dispatch_delete
shift
goto :cmd_delete

:dispatch_version
shift
goto :cmd_version

:dispatch_update
shift
goto :cmd_update

:dispatch_skills
shift
goto :cmd_skills

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

:: Rate-limited stderr diagnostic for persistent local cache-file I/O
:: failures (permissions, disk full) -- distinct from transient network
:: failures, which stay silent by design in :cp_update_check. Best-effort:
:: uses a separate marker file so a broken .update-check write doesn't
:: also block this diagnostic; if even the marker can't be written, this
:: degrades to printing every invocation rather than staying silent
:: forever (never worse than the bug being fixed).
::
:: Deliberately reuses _CP_UPDATE_INTERVAL (default 86400s) as a rolling
:: window approximating "at most once per calendar day" -- not a literal
:: calendar-day boundary, and coupled to the same user-tunable
:: CLAUDE_PROFILE_UPDATE_CHECK_INTERVAL override that governs the update
:: check's own polling frequency. This is an accepted simplification, not
:: a separate config knob (matches the sh/ps1 implementations' tradeoff).
::
:: Called from inside :write_update_cache (not from its callers) so the
:: epoch it already received as %~1 is reused directly instead of a
:: second `call :get_epoch` (a second powershell.exe spawn) -- this also
:: means every current and future caller of :write_update_cache gets this
:: diagnostic for free, with no risk of a call site forgetting to check
:: the errorlevel.
:: Usage: call :warn_cache_write_failure <epoch>
:warn_cache_write_failure
set "_wcf_now=%~1"
set "_wcf_marker=%_CP_INSTALL_DIR%\.update-check-diag"
set "_wcf_last=0"
if exist "!_wcf_marker!" set /p _wcf_last=<"!_wcf_marker!"
echo !_wcf_last!| findstr /R "^[0-9][0-9]*$" >nul 2>&1
if errorlevel 1 set "_wcf_last=0"
set /a _wcf_elapsed=_wcf_now-_wcf_last
if !_wcf_elapsed! geq !_CP_UPDATE_INTERVAL! (
    echo claude-profile: warning: could not write update-check cache in %_CP_INSTALL_DIR% -- update notifications may not work until this is fixed >&2
    set "_wcf_tmp=!_wcf_marker!.tmp.%RANDOM%"
    2>nul >"!_wcf_tmp!" echo !_wcf_now!
    if exist "!_wcf_tmp!" (
        move /y "!_wcf_tmp!" "!_wcf_marker!" >nul 2>&1
        if errorlevel 1 del /f /q "!_wcf_tmp!" >nul 2>&1
    )
)
goto :eof

:: write_update_cache <epoch> <version> <notified> — atomic via temp+rename.
:: Signals success/failure via errorlevel (exit /b 0/1) so callers can
:: detect persistent local cache I/O failures; on failure it also invokes
:: the rate-limited diagnostic above itself, so callers don't need to.
:write_update_cache
if not exist "%_CP_INSTALL_DIR%" mkdir "%_CP_INSTALL_DIR%" >nul 2>&1
set "_wuc_tmp=%_CP_UPDATE_CACHE%.tmp.%RANDOM%"
(
    echo %~1
    echo %~2
    echo %~3
) 2>nul >"!_wuc_tmp!"
if not exist "!_wuc_tmp!" (
    call :warn_cache_write_failure "%~1"
    exit /b 1
)
:: A disk-full failure mid-write can leave a truncated-but-existing temp
:: file, which `if exist` alone can't detect. Read back the third line
:: and confirm it matches what we tried to write, catching truncation
:: before it gets moved into place as the real cache file.
set "_wuc_verify="
set "_wuc_line=0"
for /f "usebackq delims=" %%L in ("!_wuc_tmp!") do (
    set /a _wuc_line+=1
    if "!_wuc_line!"=="3" set "_wuc_verify=%%L"
)
if not "!_wuc_verify!"=="%~3" (
    del /f /q "!_wuc_tmp!" >nul 2>&1
    call :warn_cache_write_failure "%~1"
    exit /b 1
)
move /y "!_wuc_tmp!" "%_CP_UPDATE_CACHE%" >nul 2>&1
if errorlevel 1 (
    del /f /q "!_wuc_tmp!" >nul 2>&1
    call :warn_cache_write_failure "%~1"
    exit /b 1
)
exit /b 0

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
    if not "!_cpu_installed!"=="unknown" (
        echo !_cpu_installed!| findstr /R "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul 2>&1
        if errorlevel 1 set "_cpu_installed=unknown"
    )
    call :version_lt "!_cpu_installed!" "!_cpu_ver!"
    if not errorlevel 1 (
        set "_cpu_installed_display=v!_cpu_installed!"
        if "!_cpu_installed!"=="unknown" set "_cpu_installed_display=unknown"
        echo A new claude-profile version is available ^(!_cpu_installed_display! -^> v!_cpu_ver!^). Run 'claude-profile update' to upgrade. >&2
        call :write_update_cache "!_cp_epoch!" "!_cpu_ver!" "1"
    )
)
goto :eof

:: --- Usage ---

:usage
echo Usage: claude-profile [command] [args...]
echo.
echo Commands:
echo     (no command)            Activate the .claude-profile or default profile
echo     use ^<name^>              Activate the named profile
echo     create ^<name^>           Create a new profile
echo     list, ls                List all profiles
echo     default [name]          Get or set the default profile
echo     local [name]            Show, set (.claude-profile), or --remove the
echo                             directory-local profile for this directory
echo     delete ^<name^>           Delete a profile
echo     which [name]            Show the resolved config directory path
echo     skills                  List pool skills and their status for the profile
echo     skills register ^<name^> ^<path^>   Add a skill directory to the shared pool
echo     skills unregister [--force] ^<name^>   Remove a skill from the pool
echo     skills add ^<skill^> [profile]     Add a pool skill to a profile
echo     skills remove ^<skill^> [profile]  Remove a pool skill from a profile
echo     skills set ^<s1,s2,...^> [profile] Replace a profile's skill selection
echo     skills reset [profile]           Back to the default (all pool skills^)
echo     skills sync [profile^|--all]      Re-materialize skill links
echo     version                 Show the installed version
echo     update [--force]        Update to the latest release
echo     help, -h, --help        Show this help message
echo.
echo Use 'call claude-profile use ^<name^>' to set CLAUDE_CONFIG_DIR in the
echo current cmd session, then run 'claude' separately.
echo.
echo A directory containing a .claude-profile file (holding a profile name)
echo is preferred over the default profile by a bare 'call claude-profile'.
echo cmd.exe has no cd hook, so this resolves at invocation time rather than
echo automatically on cd as it does in the sh and PowerShell versions.
echo.
echo Skills: a shared pool at %%LOCALAPPDATA%%\claude-profiles\skills holds
echo registered skills. A profile's skills.conf (one name per line, # comments^)
echo selects the subset linked into ^<profile^>\skills; without one the profile
echo gets every pool skill. Hand-made entries are never touched.
echo.
echo Examples:
echo     claude-profile create work
echo     claude-profile default work
echo     call claude-profile use work     # activates "work" profile
echo     claude                           # runs with "work" profile
echo     claude-profile local work        # write .claude-profile here
echo     call claude-profile              # activates "work" from .claude-profile
exit /b 0

:: --- Validate name ---
:: Expects profile name in %_vn_name%
:: Returns errorlevel 1 on failure

:validate_name

:: Check empty
if "%_vn_name%"=="" (
    echo claude-profile: profile name must not be empty >&2
    exit /b 1
)

:: Check starts with dot
if "!_vn_name:~0,1!"=="." (
    echo claude-profile: invalid profile name '%_vn_name%': must not contain '/' or start with '.' >&2
    exit /b 1
)

:: Check for path traversal and slashes (/  \  ..)
:: We use findstr with regex mode for reliable matching
echo !_vn_name! | findstr /R "[/\\]" >nul 2>&1 && (
    echo claude-profile: invalid profile name '%_vn_name%': must not contain '/' or start with '.' >&2
    exit /b 1
)
echo !_vn_name! | findstr /C:".." >nul 2>&1 && (
    echo claude-profile: invalid profile name '%_vn_name%': must not contain '/' or start with '.' >&2
    exit /b 1
)

:: Check only valid characters (letters, digits, hyphens, underscores)
echo !_vn_name!| findstr /R "^[a-zA-Z0-9_-][a-zA-Z0-9_-]*$" >nul 2>&1 || (
    echo claude-profile: invalid profile name '%_vn_name%': use only letters, digits, hyphens, underscores >&2
    exit /b 1
)

:: 'skills' is the skill pool directory inside the data dir
if /i "!_vn_name!"=="skills" (
    echo claude-profile: profile name 'skills' is reserved for the skill pool >&2
    exit /b 1
)

goto :eof

:: --- Skill pool helpers ---
::
:: A central pool at %DATA_DIR%\skills holds registered skills (directories
:: or junctions to skill source directories). Each profile may carry a
:: skills.conf manifest (one pool-skill name per line, # comments) naming
:: the subset it wants; no manifest means every pool skill. Sync
:: materializes the selection as junctions in <profile>\skills. Only
:: junctions pointing at the pool are ever created or removed -- hand-made
:: links, real directories, and files are left alone.

:: validate_skill_name -- expects the name in %_vs_name%, errorlevel 1 on failure
:validate_skill_name
if "%_vs_name%"=="" (
    echo claude-profile: skill name must not be empty >&2
    exit /b 1
)
echo !_vs_name!| findstr /R "^[a-zA-Z0-9_-][a-zA-Z0-9_-]*$" >nul 2>&1 || (
    echo claude-profile: invalid skill name '%_vs_name%': use only letters, digits, hyphens, underscores >&2
    exit /b 1
)
goto :eof

:: get_link_target <parent-dir> <entry-name> -> sets _lt_target to the link
:: target shown by `dir /AL` (empty when the entry is not a link). Names are
:: validated (no spaces or brackets), so " name [" is an exact-entry match.
:get_link_target
set "_lt_target="
for /f "usebackq tokens=*" %%L in (`dir /AL "%~1" 2^>nul ^| findstr /C:" %~2 [" 2^>nul`) do (
    set "_lt_line=%%L"
    set "_lt_target=!_lt_line:*[=!"
    if "!_lt_target:~-1!"=="]" set "_lt_target=!_lt_target:~0,-1!"
)
goto :eof

:: read_manifest <path> -> sets _mf_list to a space-delimited list of the
:: valid skill names (with leading/trailing spaces for membership tests).
:: Blank lines and # comments are skipped; invalid names warn and are
:: skipped so one bad line never fails a whole sync.
:read_manifest
call :capture_cr
set "_mf_list= "
if not exist "%~1" goto :eof
for /f "usebackq eol=# tokens=* delims=	 " %%L in ("%~1") do (
    set "_mf_line=%%L"
    call :trim_manifest_line
    if defined _mf_line (
        echo !_mf_line!| findstr /R "^[a-zA-Z0-9_-][a-zA-Z0-9_-]*$" >nul 2>&1
        if not errorlevel 1 (
            set "_mf_list=!_mf_list!!_mf_line! "
        ) else (
            echo claude-profile: skills.conf: ignoring invalid skill name '!_mf_line!' >&2
        )
    )
)
goto :eof

:: count_manifest -> sets _mf_count to the number of names in _mf_list.
:count_manifest
set "_mf_count=0"
for %%n in (!_mf_list!) do set /a _mf_count+=1
goto :eof

:trim_manifest_line
if not defined _mf_line goto :eof
if "!_mf_line:~-1!"==" "       (set "_mf_line=!_mf_line:~0,-1!" & goto :trim_manifest_line)
if "!_mf_line:~-1!"=="	"      (set "_mf_line=!_mf_line:~0,-1!" & goto :trim_manifest_line)
if "!_mf_line:~-1!"=="!_CP_CR!" (set "_mf_line=!_mf_line:~0,-1!" & goto :trim_manifest_line)
goto :eof

:: pool_skills -> sets _pl_list to a space-delimited list of every skill
:: registered in the pool (junctions enumerate like directories, dangling
:: ones included) and _pl_count to how many there are.
:pool_skills
set "_pl_list= "
set "_pl_count=0"
if not exist "%DATA_DIR%\skills\" goto :eof
for /d %%d in ("%DATA_DIR%\skills\*") do (
    set "_pl_list=!_pl_list!%%~nxd "
    set /a _pl_count+=1
)
goto :eof

:: desired_skills <profile-dir> -> sets _ds_list to the space-delimited
:: desired skill set: the manifest names when skills.conf exists, every
:: pool skill otherwise.
:desired_skills
if exist "%~1\skills.conf" (
    call :read_manifest "%~1\skills.conf"
    set "_ds_list=!_mf_list!"
) else (
    call :pool_skills
    set "_ds_list=!_pl_list!"
)
goto :eof

:: skills_profile <name-or-empty> -> sets _sp_name to the profile a skills
:: command acts on: the explicit argument if given, else the active profile
:: (CLAUDE_CONFIG_DIR under DATA_DIR), else the default. errorlevel 1 on failure.
:skills_profile
set "_sp_name="
if not "%~1"=="" (
    set "_vn_name=%~1"
    call :validate_name
    if errorlevel 1 exit /b 1
    set "_sp_name=%~1"
    goto :skills_profile_check
)
if defined CLAUDE_CONFIG_DIR (
    for %%p in ("!CLAUDE_CONFIG_DIR!") do set "_sp_cand=%%~nxp"
    if /i "!CLAUDE_CONFIG_DIR!"=="%DATA_DIR%\!_sp_cand!" (
        set "_sp_name=!_sp_cand!"
        goto :skills_profile_check
    )
    echo claude-profile: active CLAUDE_CONFIG_DIR is not a managed profile; pass a profile name >&2
    exit /b 1
)
if not exist "%DEFAULT_FILE%" (
    echo claude-profile: no profile specified and no default profile set >&2
    exit /b 1
)
set /p _sp_name=<"%DEFAULT_FILE%"
if "!_sp_name!"=="" (
    echo claude-profile: no profile specified and no default profile set >&2
    exit /b 1
)
:skills_profile_check
if not exist "%DATA_DIR%\!_sp_name!\" (
    echo claude-profile: profile '!_sp_name!' does not exist >&2
    exit /b 1
)
exit /b 0

:: pool_guard -> errorlevel 1 when %DATA_DIR%\skills exists but looks like
:: a Claude Code profile (a profile named 'skills' created before that
:: name was reserved). Without this, pool operations would enumerate its
:: internals as skills and link them into every profile.
:pool_guard
if not exist "%DATA_DIR%\skills\" exit /b 0
if exist "%DATA_DIR%\skills\settings.json" goto :pool_guard_fail
if exist "%DATA_DIR%\skills\.credentials.json" goto :pool_guard_fail
exit /b 0
:pool_guard_fail
echo claude-profile: %DATA_DIR%\skills looks like a Claude Code profile, not a skill pool ^(the name 'skills' is now reserved^). Move that profile aside before using skill pools. >&2
exit /b 1

:: sync_profile <name> -> re-materializes managed skill junctions for the
:: profile from its manifest (or the whole pool when no manifest).
:sync_profile
call :pool_guard
if errorlevel 1 exit /b 1
set "_sy_pool=%DATA_DIR%\skills"
set "_sy_pdir=%DATA_DIR%\%~1"
set "_sy_sdir=!_sy_pdir!\skills"
:: A manifest that exists but can't be read must abort, not silently
:: become "select nothing" and strip the profile's managed links.
if exist "!_sy_pdir!\skills.conf" (
    type "!_sy_pdir!\skills.conf" >nul 2>&1
    if errorlevel 1 (
        echo claude-profile: cannot read !_sy_pdir!\skills.conf; not syncing >&2
        exit /b 1
    )
)
call :desired_skills "!_sy_pdir!"
if not exist "!_sy_sdir!\" mkdir "!_sy_sdir!" >nul 2>&1
if not exist "!_sy_sdir!\" (
    echo claude-profile: cannot create !_sy_sdir! >&2
    exit /b 1
)

:: Pass 1: drop managed junctions that are dangling or no longer desired.
for /f "usebackq delims=" %%e in (`dir /AL /B "!_sy_sdir!" 2^>nul`) do (
    call :get_link_target "!_sy_sdir!" "%%e"
    if /i "!_lt_target!"=="!_sy_pool!\%%e" (
        set "_sy_keep=1"
        if "!_ds_list: %%e =!"=="!_ds_list!" set "_sy_keep=0"
        if not exist "!_sy_pool!\%%e\" set "_sy_keep=0"
        if "!_sy_keep!"=="0" (
            rmdir "!_sy_sdir!\%%e" >nul 2>&1
            if exist "!_sy_sdir!\%%e" echo claude-profile: could not remove !_sy_sdir!\%%e >&2
        )
    )
)

:: Pass 2: create junctions missing from the desired set.
for %%n in (!_ds_list!) do (
    if not exist "!_sy_pool!\%%n\" (
        echo claude-profile: skill '%%n' is not in the pool ^(or its source is gone^); skipping >&2
    ) else if exist "!_sy_sdir!\%%n" (
        call :get_link_target "!_sy_sdir!" "%%n"
        if /i not "!_lt_target!"=="!_sy_pool!\%%n" (
            echo claude-profile: skill '%%n': unmanaged entry already at !_sy_sdir!\%%n; skipping >&2
        )
    ) else (
        mklink /J "!_sy_sdir!\%%n" "!_sy_pool!\%%n" >nul 2>&1
        if not exist "!_sy_sdir!\%%n" echo claude-profile: could not link skill '%%n' >&2
    )
)
exit /b 0

:: --- Directory-local profile (.claude-profile) ---
::
:: A directory may contain a `.claude-profile` file whose first non-empty,
:: non-comment line names a profile. cmd.exe has no cd hook and no way to
:: install a transparent `claude` wrapper, so unlike the sh and PowerShell
:: implementations this cannot switch on cd. Instead, a bare
:: `call claude-profile.cmd` resolves the nearest .claude-profile walking up
:: from the current directory and prefers it over the default profile.

:: Sets _fd_result to the nearest .claude-profile at or above %CD%, or leaves
:: it empty when none is found.
:find_dotfile
set "_fd_result="
set "_fd_dir=%CD%"
:find_dotfile_loop
if exist "!_fd_dir!\.claude-profile" (
    set "_fd_result=!_fd_dir!\.claude-profile"
    goto :eof
)
set "_fd_parent="
for %%p in ("!_fd_dir!\..") do set "_fd_parent=%%~fp"
if not defined _fd_parent goto :eof
if /i "!_fd_parent!"=="!_fd_dir!" goto :eof
set "_fd_dir=!_fd_parent!"
goto :find_dotfile_loop

:: Captures a literal CR into _CP_CR. `for /f` leaves the CR attached to each
:: token when reading a CRLF file, which would otherwise make an otherwise
:: valid profile name fail validation. Resolved lazily (only :read_dotfile
:: needs it) so the common command paths don't pay for the copy.
:capture_cr
if defined _CP_CR goto :eof
for /f %%a in ('copy /Z "%~f0" nul') do set "_CP_CR=%%a"
goto :eof

:: read_dotfile <path> -> sets _rd_name to the first non-empty, non-comment
:: line, with surrounding whitespace and any trailing CR stripped.
:read_dotfile
call :capture_cr
set "_rd_name="
for /f "usebackq eol=# tokens=* delims=	 " %%L in ("%~1") do (
    if not defined _rd_name set "_rd_name=%%L"
)
if not defined _rd_name goto :eof
:read_dotfile_trim
if not defined _rd_name goto :eof
if "!_rd_name:~-1!"==" "       (set "_rd_name=!_rd_name:~0,-1!" & goto :read_dotfile_trim)
if "!_rd_name:~-1!"=="	"      (set "_rd_name=!_rd_name:~0,-1!" & goto :read_dotfile_trim)
if "!_rd_name:~-1!"=="!_CP_CR!" (set "_rd_name=!_rd_name:~0,-1!" & goto :read_dotfile_trim)
goto :eof

:: Resolves the directory-local profile into _dl_name / _dl_file, or leaves
:: _dl_name empty. Reports (to stderr) a dotfile that names something
:: unusable, so a typo isn't silently ignored.
:resolve_dotfile_profile
set "_dl_name="
set "_dl_file="
call :find_dotfile
if not defined _fd_result goto :eof
set "_dl_file=!_fd_result!"
call :read_dotfile "!_dl_file!"
if not defined _rd_name (
    echo claude-profile: ignoring !_dl_file!: no profile name in file >&2
    goto :eof
)
set "_vn_name=!_rd_name!"
call :validate_name >nul 2>&1
if errorlevel 1 (
    echo claude-profile: ignoring !_dl_file!: invalid profile name '!_rd_name!' >&2
    goto :eof
)
if not exist "%DATA_DIR%\!_rd_name!\" (
    echo claude-profile: ignoring !_dl_file!: profile '!_rd_name!' does not exist >&2
    goto :eof
)
set "_dl_name=!_rd_name!"
goto :eof

:: --- Commands ---

:cmd_local
if "%~1"=="" goto :cmd_local_show
if /i "%~1"=="--remove" goto :cmd_local_remove
if /i "%~1"=="--clear"  goto :cmd_local_remove
set "_first=%~1"
if "!_first:~0,1!"=="-" (
    echo claude-profile: unknown option '%~1' >&2
    exit /b 1
)
if not "%~2"=="" (
    echo claude-profile: unexpected argument after profile name: '%~2' >&2
    exit /b 1
)
set "_vn_name=%~1"
call :validate_name
if errorlevel 1 exit /b 1
if not exist "%DATA_DIR%\%~1\" (
    echo claude-profile: profile '%~1' does not exist. Create it with: claude-profile create %~1 >&2
    exit /b 1
)
>"%CD%\.claude-profile" echo %~1
if not exist "%CD%\.claude-profile" (
    echo claude-profile: could not write %CD%\.claude-profile >&2
    exit /b 1
)
echo Wrote %CD%\.claude-profile ^(profile: %~1^)
echo Run 'call claude-profile.cmd' here to activate it.
exit /b 0

:cmd_local_show
call :resolve_dotfile_profile
if not defined _dl_file (
    echo claude-profile: no .claude-profile found in this directory or any parent >&2
    exit /b 1
)
echo !_dl_file!
if defined _dl_name (
    echo Profile: !_dl_name!
) else (
    exit /b 1
)
exit /b 0

:cmd_local_remove
if not exist "%CD%\.claude-profile" (
    echo claude-profile: no .claude-profile in the current directory >&2
    exit /b 1
)
del /f /q "%CD%\.claude-profile" >nul 2>&1
if exist "%CD%\.claude-profile" (
    echo claude-profile: could not remove %CD%\.claude-profile >&2
    exit /b 1
)
echo Removed %CD%\.claude-profile
exit /b 0

:cmd_create
if "%~1"=="" (
    echo claude-profile: usage: claude-profile create ^<name^> >&2
    exit /b 1
)
set "_vn_name=%~1"
call :validate_name
if errorlevel 1 exit /b 1

set "_cc_dir=%DATA_DIR%\%~1"
if exist "%_cc_dir%\" (
    echo claude-profile: profile '%~1' already exists >&2
    exit /b 1
)
mkdir "%_cc_dir%"
echo Created profile: %~1
echo Config directory: %_cc_dir%
:: A new profile has no manifest, so this links every pool skill (the
:: backward-compatible "all" default). No pool: no-op.
set "_sk_pool=%DATA_DIR%\skills"
if exist "%DATA_DIR%\skills\" call :sync_profile "%~1"
exit /b 0

:cmd_list
if not exist "%DATA_DIR%\" (
    echo No profiles found. Create one with: claude-profile create ^<name^>
    exit /b 0
)

set "_cl_default="
if exist "%DEFAULT_FILE%" (
    set /p _cl_default=<"%DEFAULT_FILE%"
)

call :pool_skills
set "_cl_found=0"
for /d %%d in ("%DATA_DIR%\*") do (
    if /i not "%%~nxd"=="skills" (
        set "_cl_found=1"
        set "_cl_name=%%~nxd"
        set "_cl_note="
        if exist "%%d\skills.conf" (
            call :read_manifest "%%d\skills.conf"
            call :count_manifest
            set "_cl_note= [skills: !_mf_count!/!_pl_count!]"
        )
        if "!_cl_name!"=="!_cl_default!" (
            echo * !_cl_name! (default^)!_cl_note!
        ) else (
            echo   !_cl_name!!_cl_note!
        )
    )
)

if "!_cl_found!"=="0" (
    echo No profiles found. Create one with: claude-profile create ^<name^>
)
exit /b 0

:cmd_default
if "%~1"=="" (
    if exist "%DEFAULT_FILE%" (
        type "%DEFAULT_FILE%"
        echo.
        exit /b 0
    ) else (
        echo claude-profile: no default profile set. Set one with: claude-profile default ^<name^> >&2
        exit /b 1
    )
)

set "_vn_name=%~1"
call :validate_name
if errorlevel 1 exit /b 1

set "_cd_dir=%DATA_DIR%\%~1"
if not exist "%_cd_dir%\" (
    echo claude-profile: profile '%~1' does not exist. Create it with: claude-profile create %~1 >&2
    exit /b 1
)
if not exist "%DATA_DIR%\" mkdir "%DATA_DIR%"
:: Write profile name without trailing newline (cmd echo always adds one, but set /p reads the first line)
>"%DEFAULT_FILE%" (echo|set /p="%~1")
echo Default profile set to: %~1
exit /b 0

:cmd_version
set "_cv_installed=unknown"
if exist "%_CP_VERSION_FILE%" set /p _cv_installed=<"%_CP_VERSION_FILE%"
if "!_cv_installed!"=="" set "_cv_installed=unknown"
echo !_cv_installed!
exit /b 0

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
:: Proactive fix (learned from Task 7's cp_update_check fix, commit 0d89002):
:: validate the locally-installed VERSION file's content is a real X.Y.Z
:: triplet before feeding it into version_lt, since a truncated/hand-edited
:: file would otherwise silently mis-compare (version_lt's undefined-segment
:: bug, also fixed in Task 7) instead of honestly falling back to "unknown".
if not "!_cu_installed!"=="unknown" (
    echo !_cu_installed!| findstr /R "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul 2>&1
    if errorlevel 1 set "_cu_installed=unknown"
)

if "!_cu_force!"=="0" if not "!_cu_installed!"=="unknown" (
    call :version_lt "!_cu_installed!" "!_cu_latest!"
    if errorlevel 1 (
        echo claude-profile: already up to date ^(v!_cu_installed!^); latest is v!_cu_latest! >&2
        exit /b 1
    )
)

:: Proactive fix (learned from Task 8/9's same-filesystem-tmpdir fix):
:: create the install directory FIRST, then create the temp directory
:: INSIDE it (not under %TEMP%), so the later `move` calls are guaranteed
:: same-volume, atomic renames rather than a possible cross-volume
:: copy+delete.
if not exist "%_CP_INSTALL_DIR%" mkdir "%_CP_INSTALL_DIR%" >nul 2>&1
set "_cu_tmpdir=%_CP_INSTALL_DIR%\.update-%RANDOM%"
mkdir "!_cu_tmpdir!" >nul 2>&1
if not exist "!_cu_tmpdir!\" (
    echo claude-profile: update failed: could not create temp directory >&2
    exit /b 1
)

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

:: Proactive fix (learned from Task 8's unchecked-second-mv fix, commit
:: 8cf1fca): both moves are now checked; a failure on either one cleans
:: up and reports an error rather than silently reporting success.
move /y "!_cu_tmpdir!\claude-profile.cmd" "%_CP_INSTALL_DIR%\claude-profile.cmd" >nul 2>&1
if errorlevel 1 (
    echo claude-profile: update failed: could not replace claude-profile.cmd >&2
    goto :update_fail_cleanup
)
move /y "!_cu_tmpdir!\VERSION" "%_CP_VERSION_FILE%" >nul 2>&1
if errorlevel 1 (
    echo claude-profile: update failed: could not replace VERSION >&2
    goto :update_fail_cleanup
)
rd /s /q "!_cu_tmpdir!" >nul 2>&1

set "_cu_installed_display=v!_cu_installed!"
if "!_cu_installed!"=="unknown" set "_cu_installed_display=unknown"
echo Updating claude-profile.cmd: !_cu_installed_display! -^> v!_cu_latest!
echo Done. Open a new cmd window ^(or re-run 'call claude-profile.cmd'^) to use the new version.
exit /b 0

:update_fail_cleanup
if exist "!_cu_tmpdir!" rd /s /q "!_cu_tmpdir!" >nul 2>&1
exit /b 1

:cmd_which
:: Resolve profile dir for optional name argument
set "_rp_name=%~1"
if "!_rp_name!"=="" (
    if not exist "%DEFAULT_FILE%" (
        echo claude-profile: no default profile set. Use: claude-profile default ^<name^> >&2
        exit /b 1
    )
    set /p _rp_name=<"%DEFAULT_FILE%"
    if "!_rp_name!"=="" (
        echo claude-profile: default profile file is empty. Set one with: claude-profile default ^<name^> >&2
        exit /b 1
    )
)
set "_rp_dir=%DATA_DIR%\!_rp_name!"
if not exist "!_rp_dir!\" (
    echo claude-profile: profile '!_rp_name!' does not exist. Create it with: claude-profile create !_rp_name! >&2
    exit /b 1
)
echo !_rp_dir!
exit /b 0

:cmd_use
if "%~1"=="" (
    echo claude-profile: usage: claude-profile use ^<name^> >&2
    exit /b 1
)
if not "%~2"=="" (
    echo claude-profile: 'use' takes exactly one argument (profile name) >&2
    exit /b 1
)

:: Resolve profile dir
set "_rp_name=%~1"
set "_rp_dir=%DATA_DIR%\!_rp_name!"
if not exist "!_rp_dir!\" (
    echo claude-profile: profile '!_rp_name!' does not exist. Create it with: claude-profile create !_rp_name! >&2
    exit /b 1
)

:: Set CLAUDE_CONFIG_DIR for the calling session (requires 'call' prefix)
endlocal & set "CLAUDE_CONFIG_DIR=%_rp_dir%" & echo Switched to profile: %_rp_name%
exit /b 0

:cmd_delete
if "%~1"=="" (
    echo claude-profile: usage: claude-profile delete ^<name^> >&2
    exit /b 1
)
set "_cdel_name=%~1"
set "_vn_name=!_cdel_name!"
call :validate_name
if errorlevel 1 exit /b 1

set "_cdel_dir=%DATA_DIR%\!_cdel_name!"
if not exist "!_cdel_dir!\" (
    echo claude-profile: profile '!_cdel_name!' does not exist >&2
    exit /b 1
)

set "_cdel_prompt=Delete profile "!_cdel_name!" and all its data? [y/N] "
set /p _cdel_confirm=!_cdel_prompt!
if /i "!_cdel_confirm!"=="y" goto :do_delete
if /i "!_cdel_confirm!"=="yes" goto :do_delete
echo Cancelled.
exit /b 0

:do_delete
rmdir /s /q "!_cdel_dir!"
echo Deleted profile: !_cdel_name!

if exist "%DEFAULT_FILE%" (
    set /p _cdel_current=<"%DEFAULT_FILE%"
    if "!_cdel_current!"=="!_cdel_name!" (
        del /f "%DEFAULT_FILE%" >nul 2>&1
        echo Cleared default profile (was "!_cdel_name!"^)
    )
)
exit /b 0

:cmd_skills
set "_sk_pool=%DATA_DIR%\skills"
call :pool_guard
if errorlevel 1 exit /b 1
if "%~1"=="" goto :cmd_skills_list
if /i "%~1"=="register"   goto :cmd_skills_register
if /i "%~1"=="unregister" goto :cmd_skills_unregister
if /i "%~1"=="add"        goto :cmd_skills_addremove
if /i "%~1"=="remove"     goto :cmd_skills_addremove
if /i "%~1"=="set"        goto :cmd_skills_set
if /i "%~1"=="reset"      goto :cmd_skills_reset
if /i "%~1"=="sync"       goto :cmd_skills_sync
echo claude-profile: unknown skills command '%~1'. Run 'claude-profile help' for usage. >&2
exit /b 1

:cmd_skills_register
if "%~2"=="" (
    echo claude-profile: usage: claude-profile skills register ^<name^> ^<path^> >&2
    exit /b 1
)
if "%~3"=="" (
    echo claude-profile: usage: claude-profile skills register ^<name^> ^<path^> >&2
    exit /b 1
)
if not "%~4"=="" (
    echo claude-profile: unexpected argument '%~4' >&2
    exit /b 1
)
set "_vs_name=%~2"
call :validate_skill_name
if errorlevel 1 exit /b 1
if not exist "%~3\" (
    echo claude-profile: '%~3' is not a directory >&2
    exit /b 1
)
if not exist "%~3\SKILL.md" (
    echo claude-profile: '%~3' does not contain a SKILL.md >&2
    exit /b 1
)
if not exist "!_sk_pool!\" mkdir "!_sk_pool!" >nul 2>&1
if not exist "!_sk_pool!\" (
    echo claude-profile: cannot create !_sk_pool! >&2
    exit /b 1
)
if exist "!_sk_pool!\%~2" (
    echo claude-profile: skill '%~2' is already registered >&2
    exit /b 1
)
set "_sk_abs=%~f3"
mklink /J "!_sk_pool!\%~2" "!_sk_abs!" >nul 2>&1
if not exist "!_sk_pool!\%~2\" (
    echo claude-profile: could not create pool link for '%~2' >&2
    exit /b 1
)
echo Registered skill: %~2 -^> !_sk_abs!
echo Run 'claude-profile skills sync --all' to link it into unfiltered profiles.
exit /b 0

:cmd_skills_unregister
if not "%~4"=="" (
    echo claude-profile: unexpected argument '%~4' >&2
    exit /b 1
)
set "_sk_force=0"
set "_sk_name="
if /i "%~2"=="--force" (
    set "_sk_force=1"
) else if not "%~2"=="" (
    set "_sk_name=%~2"
)
if /i "%~3"=="--force" (
    set "_sk_force=1"
) else if not "%~3"=="" (
    if defined _sk_name (
        echo claude-profile: unexpected argument '%~3' >&2
        exit /b 1
    )
    set "_sk_name=%~3"
)
if not defined _sk_name (
    echo claude-profile: usage: claude-profile skills unregister [--force] ^<name^> >&2
    exit /b 1
)
set "_vs_name=!_sk_name!"
call :validate_skill_name
if errorlevel 1 exit /b 1
set "_sk_entry=!_sk_pool!\!_sk_name!"
:: Detect link-ness FIRST (never probe by deleting). `if exist` resolves
:: links, so a dangling junction reads as absent — the dir /AL scan still
:: sees the entry itself and lets it be unregistered.
set "_sk_islink=0"
for /f "usebackq delims=" %%e in (`dir /AL /B "!_sk_pool!" 2^>nul ^| findstr /X /C:"!_sk_name!" 2^>nul`) do set "_sk_islink=1"
if "!_sk_islink!"=="1" (
    rmdir "!_sk_entry!" >nul 2>&1
    if exist "!_sk_entry!\" (
        echo claude-profile: could not remove !_sk_entry! >&2
        exit /b 1
    )
) else if exist "!_sk_entry!\" (
    if "!_sk_force!"=="0" (
        echo claude-profile: '!_sk_name!' is a real directory in the pool; pass --force to delete it and its contents >&2
        exit /b 1
    )
    rmdir /s /q "!_sk_entry!" >nul 2>&1
    if exist "!_sk_entry!\" (
        echo claude-profile: could not remove !_sk_entry! >&2
        exit /b 1
    )
) else (
    echo claude-profile: skill '!_sk_name!' is not registered >&2
    exit /b 1
)
for /d %%d in ("%DATA_DIR%\*") do (
    if /i not "%%~nxd"=="skills" if exist "%%d\skills.conf" (
        call :read_manifest "%%d\skills.conf"
        call :warn_manifest_reference "%%~nxd"
    )
)
echo Unregistered skill: !_sk_name!
echo Run 'claude-profile skills sync --all' to remove stale links from profiles.
exit /b 0

:: warn_manifest_reference <profile-name> -- warns when the manifest just
:: read into _mf_list still lists !_sk_name!. Split out of the loop above
:: because nested delayed expansions of _sk_name inside a for block don't
:: compose with the substring-membership test.
:warn_manifest_reference
if "!_mf_list: %_sk_name% =!"=="!_mf_list!" goto :eof
echo claude-profile: note: profile '%~1' still lists '!_sk_name!' in skills.conf >&2
goto :eof

:cmd_skills_addremove
set "_sk_op=%~1"
if "%~2"=="" (
    echo claude-profile: usage: claude-profile skills %_sk_op% ^<skill^> [profile] >&2
    exit /b 1
)
if not "%~4"=="" (
    echo claude-profile: unexpected argument '%~4' >&2
    exit /b 1
)
set "_vs_name=%~2"
call :validate_skill_name
if errorlevel 1 exit /b 1
call :skills_profile "%~3"
if errorlevel 1 exit /b 1
set "_sk_pdir=%DATA_DIR%\!_sp_name!"
set "_sk_manifest=!_sk_pdir!\skills.conf"
if /i "!_sk_op!"=="add" if not exist "!_sk_pool!\%~2\" (
    echo claude-profile: skill '%~2' is not in the pool. Register it with: claude-profile skills register %~2 ^<path^> >&2
    exit /b 1
)
:: Materialize the implicit "all pool skills" default first so add/remove
:: edits stay sticky.
if not exist "!_sk_manifest!" (
    call :pool_skills
    >"!_sk_manifest!" type nul
    for %%n in (!_pl_list!) do >>"!_sk_manifest!" echo %%n
)
if /i "!_sk_op!"=="add" (
    findstr /X /C:"%~2" "!_sk_manifest!" >nul 2>&1
    if errorlevel 1 >>"!_sk_manifest!" echo %~2
) else (
    set "_sk_tmp=!_sk_manifest!.tmp.%RANDOM%"
    findstr /V /X /C:"%~2" "!_sk_manifest!" >"!_sk_tmp!" 2>nul
    move /y "!_sk_tmp!" "!_sk_manifest!" >nul 2>&1
)
call :sync_profile "!_sp_name!"
if errorlevel 1 exit /b 1
if /i "!_sk_op!"=="add" (
    echo Added skill '%~2' to profile '!_sp_name!'
) else (
    echo Removed skill '%~2' from profile '!_sp_name!'
)
exit /b 0

:cmd_skills_set
if "%~2"=="" (
    echo claude-profile: usage: claude-profile skills set ^<skill1,skill2,...^> [profile] >&2
    exit /b 1
)
if not "%~4"=="" (
    echo claude-profile: unexpected argument '%~4' >&2
    exit /b 1
)
call :skills_profile "%~3"
if errorlevel 1 exit /b 1
set "_sk_listarg=%~2"
:: Reject anything but names and commas up front: a bare `for %%n in (...)`
:: would otherwise glob-expand wildcards against the current directory.
echo !_sk_listarg!| findstr /R "^[a-zA-Z0-9_,-][a-zA-Z0-9_,-]*$" >nul 2>&1 || (
    echo claude-profile: invalid skill list '%~2': use comma-separated names ^(letters, digits, hyphens, underscores^) >&2
    exit /b 1
)
set "_sk_manifest=%DATA_DIR%\!_sp_name!\skills.conf"
set "_sk_tmp=!_sk_manifest!.tmp.%RANDOM%"
set "_sk_bad=0"
>"!_sk_tmp!" type nul
:: cmd's for treats commas as delimiters, so the comma list splits natively.
for %%n in (!_sk_listarg!) do (
    set "_vs_name=%%n"
    call :validate_skill_name
    if errorlevel 1 (
        set "_sk_bad=1"
    ) else (
        if not exist "!_sk_pool!\%%n\" (
            echo claude-profile: warning: skill '%%n' is not in the pool >&2
        )
        >>"!_sk_tmp!" echo %%n
    )
)
if "!_sk_bad!"=="1" (
    del /f /q "!_sk_tmp!" >nul 2>&1
    exit /b 1
)
move /y "!_sk_tmp!" "!_sk_manifest!" >nul 2>&1
call :sync_profile "!_sp_name!"
if errorlevel 1 exit /b 1
echo Set skills for profile '!_sp_name!'
exit /b 0

:cmd_skills_reset
if not "%~3"=="" (
    echo claude-profile: unexpected argument '%~3' >&2
    exit /b 1
)
call :skills_profile "%~2"
if errorlevel 1 exit /b 1
del /f /q "%DATA_DIR%\!_sp_name!\skills.conf" >nul 2>&1
call :sync_profile "!_sp_name!"
if errorlevel 1 exit /b 1
echo Profile '!_sp_name!' reset to all pool skills
exit /b 0

:cmd_skills_sync
if not "%~3"=="" (
    echo claude-profile: unexpected argument '%~3' >&2
    exit /b 1
)
if /i "%~2"=="--all" (
    for /d %%d in ("%DATA_DIR%\*") do (
        if /i not "%%~nxd"=="skills" (
            call :sync_profile "%%~nxd"
            echo Synced profile '%%~nxd'
        )
    )
    exit /b 0
)
call :skills_profile "%~2"
if errorlevel 1 exit /b 1
call :sync_profile "!_sp_name!"
if errorlevel 1 exit /b 1
echo Synced profile '!_sp_name!'
exit /b 0

:cmd_skills_list
if not exist "!_sk_pool!\" (
    echo No skill pool yet. Register a skill with: claude-profile skills register ^<name^> ^<path^>
    exit /b 0
)
call :skills_profile ""
if errorlevel 1 exit /b 1
set "_sk_pdir=%DATA_DIR%\!_sp_name!"
if exist "!_sk_pdir!\skills.conf" (
    echo Profile '!_sp_name!': skills.conf present ^(filtered^)
) else (
    echo Profile '!_sp_name!': no skills.conf ^(all pool skills^)
)
echo Skill pool: !_sk_pool!
call :desired_skills "!_sk_pdir!"
set "_sk_found=0"
for /d %%d in ("!_sk_pool!\*") do (
    set "_sk_found=1"
    set "_sk_status=not linked"
    if not exist "!_sk_pool!\%%~nxd\" (
        set "_sk_status=dangling (target missing)"
    ) else if exist "!_sk_pdir!\skills\%%~nxd" (
        call :get_link_target "!_sk_pdir!\skills" "%%~nxd"
        if /i "!_lt_target!"=="!_sk_pool!\%%~nxd" (
            set "_sk_status=linked"
        ) else (
            set "_sk_status=conflict (unmanaged entry)"
        )
    ) else (
        if not "!_ds_list: %%~nxd =!"=="!_ds_list!" set "_sk_status=selected, not linked (run sync)"
    )
    echo   %%~nxd	!_sk_status!
)
if "!_sk_found!"=="0" echo   (pool is empty)
exit /b 0

:cmd_launch_default
:: A .claude-profile in this directory (or any parent) wins over the default.
call :resolve_dotfile_profile
if defined _dl_name goto :launch_dotfile

:: Resolve default profile
if not exist "%DEFAULT_FILE%" (
    echo claude-profile: no default profile set. Use: claude-profile default ^<name^> >&2
    exit /b 1
)
set /p _rp_name=<"%DEFAULT_FILE%"
if "!_rp_name!"=="" (
    echo claude-profile: default profile file is empty. Set one with: claude-profile default ^<name^> >&2
    exit /b 1
)
set "_rp_dir=%DATA_DIR%\!_rp_name!"
if not exist "!_rp_dir!\" (
    echo claude-profile: profile '!_rp_name!' does not exist. Create it with: claude-profile create !_rp_name! >&2
    exit /b 1
)

:: Set CLAUDE_CONFIG_DIR for the calling session (requires 'call' prefix)
endlocal & set "CLAUDE_CONFIG_DIR=%_rp_dir%" & echo Switched to profile: %_rp_name% (default)
exit /b 0

:launch_dotfile
:: Kept out of the `if defined` block above: `endlocal & set VAR=%...%`
:: relies on percent-expansion happening after the preceding set lines have
:: run, which a parenthesised block would break.
set "_rp_name=%_dl_name%"
set "_rp_dir=%DATA_DIR%\%_dl_name%"
set "_rp_src=%_dl_file%"
endlocal & set "CLAUDE_CONFIG_DIR=%_rp_dir%" & echo Switched to profile: %_rp_name% (from %_rp_src%)
exit /b 0
