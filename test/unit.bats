#!/usr/bin/env bats
# Unit tests for the vcvarsall.sh functions, runnable on any OS (no Windows tools needed).
# shellcheck disable=SC2154,SC2034,SC1003,SC2016 # globals of the tested functions, literal backslashes

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load_vcvarsall
  # Ignore the user's settings (e.g. VSINSTALLDIR is set after "eval $(vcvarsall.sh x64)")
  unset VCVARS_SILENT VCVARS_WSL_SHARE_PATH VCVARSBASH_DEBUG VSINSTALLDIR VSWHEREARGS VSWHEREPATH WSLENV
  # Run the platform-dependent code as on Cygwin-like platforms, unless a test changes it
  bash_platform=win_cyg
}

# Print an array as "[a][b]..." to compare it in one assertion
function brackets() {
  printf '[%s]' "$@"
}

### detect_platform

@test "detect_platform: Cygwin-like (Git Bash, MSYS2, Cygwin)" {
  OSTYPE=msys detect_platform
  assert_equal "$bash_platform" 'win_cyg'
}

# Replace is_wsl_kernel with a stub returning the given status (0: WSL kernel)
function stub_wsl_kernel() {
  STUB_WSL_KERNEL_STATUS=$1
  # shellcheck disable=SC2329
  function is_wsl_kernel() { return "$STUB_WSL_KERNEL_STATUS"; }
}

# Write a kernel release file, and print its path
function osrelease() {
  printf '%s\n' "$1" >"${BATS_TEST_TMPDIR}/osrelease"
  printf '%s\n' "${BATS_TEST_TMPDIR}/osrelease"
}

# Put a fake cmd.exe first in PATH, running the given shell commands (if any)
function fake_cmd_exe() {
  mkdir -p -- "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\n%s\n' "${1:-}" >"${BATS_TEST_TMPDIR}/bin/cmd.exe"
  chmod +x -- "${BATS_TEST_TMPDIR}/bin/cmd.exe"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

@test "detect_platform: WSL, from WSL_DISTRO_NAME" {
  fake_cmd_exe
  OSTYPE=linux-gnu WSL_DISTRO_NAME=Ubuntu detect_platform
  assert_equal "$bash_platform" 'win_wsl'
}

@test "detect_platform: WSL, from the kernel release (e.g. in an SSH session)" {
  fake_cmd_exe
  stub_wsl_kernel 0
  OSTYPE=linux-gnu WSL_DISTRO_NAME='' detect_platform
  assert_equal "$bash_platform" 'win_wsl'
}

@test "detect_platform: WSL without cmd.exe in PATH fails with a hint" {
  OSTYPE=linux-gnu WSL_DISTRO_NAME=Ubuntu PATH=/usr/bin:/bin run --separate-stderr detect_platform
  assert_equal "$status" 1
  assert_equal "${stderr_lines[0]}" 'error: cmd.exe not found in PATH'
  [[ "${stderr_lines[1]}" == 'hint: The Windows PATH is missing '* ]]
}

@test "detect_platform: other platforms are rejected" {
  stub_wsl_kernel 1
  OSTYPE=linux-gnu WSL_DISTRO_NAME='' run detect_platform
  assert_equal "$status" 1
  assert_equal "${lines[0]}" 'error: Unsupported platform (linux-gnu)'
}

@test "is_wsl_kernel: matches the kernel releases with a -microsoft part" {
  local release
  for release in '4.4.0-26100-Microsoft' '4.19.43-microsoft-standard' '6.18.40.1-microsoft-standard-WSL2'; do
    is_wsl_kernel "$(osrelease "$release")" || {
      echo "not detected: $release" >&2
      return 1
    }
  done
  for release in '6.8.0-45-generic' '6.1.0-notmicrosoft'; do
    if is_wsl_kernel "$(osrelease "$release")"; then
      echo "false positive: $release" >&2
      return 1
    fi
  done
  run ! is_wsl_kernel "${BATS_TEST_TMPDIR}/missing"
}

### parse_args_simple

@test "parse_args_simple: splits on any whitespace" {
  parse_args_simple $' -a\tb\nc\r d  '
  assert_equal "$(brackets "${result[@]}")" '[-a][b][c][d]'
}

@test "parse_args_simple: empty string gives no arguments" {
  parse_args_simple ''
  assert_equal "${#result[@]}" 0
  parse_args_simple $' \t '
  assert_equal "${#result[@]}" 0
}

@test "parse_args_simple: quoted arguments keep whitespace" {
  parse_args_simple '-products "a b" "" x'
  assert_equal "$(brackets "${result[@]}")" '[-products][a b][][x]'
}

@test "parse_args_simple: doubled quotes are escaped quotes" {
  parse_args_simple '"say ""hi""" """"'
  assert_equal "$(brackets "${result[@]}")" '[say "hi"]["]'
}

@test "parse_args_simple: quotes are literal inside unquoted arguments" {
  parse_args_simple 'a"b'
  assert_equal "$(brackets "${result[@]}")" '[a"b]'
}

@test "parse_args_simple: a closing quote ends the argument" {
  parse_args_simple '"a"b'
  assert_equal "$(brackets "${result[@]}")" '[a][b]'
}

@test "parse_args_simple: unfinished quoted argument fails" {
  run parse_args_simple '-a "b c'
  assert_equal "$status" 1
  assert_equal "$output" 'error: Unfinished quoted argument: b c '
}

### cmd

@test "cmd: on WSL, runs cmd.exe from its own directory, not the current one" {
  fake_cmd_exe 'pwd'
  bash_platform=win_wsl
  mkdir -- "${BATS_TEST_TMPDIR}/linux" && cd -- "${BATS_TEST_TMPDIR}/linux"
  assert_equal "$(cmd 'set')" "${BATS_TEST_TMPDIR}/bin"
  assert_equal "$PWD" "${BATS_TEST_TMPDIR}/linux"
}

### cmdesc

@test "cmdesc: escapes everything but alphanumerics" {
  assert_equal "$(cmdesc 'x64')" 'x64'
  assert_equal "$(cmdesc 'a b&c|d^e%f"g<h>i(j)k!l')" 'a^ b^&c^|d^^e^%f^"g^<h^>i^(j^)k^!l'
  assert_equal "$(cmdesc 'C:\VS\vcvarsall.bat')" 'C^:^\VS^\vcvarsall^.bat'
  assert_equal "$(cmdesc '')" ''
}

### find_vcvarsall

# Create a fake vswhere that records its arguments and prints VSWHERE_OUTPUT
function fake_vswhere() {
  export VSWHEREPATH="${BATS_TEST_TMPDIR}/vswhere"
  export VSWHERE_ARGS_FILE="${BATS_TEST_TMPDIR}/vswhere.args"
  cat >"$VSWHEREPATH" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$VSWHERE_ARGS_FILE"
printf '%s' "$VSWHERE_OUTPUT"
EOF
  chmod +x -- "$VSWHEREPATH"
}

@test "find_vcvarsall: uses VSINSTALLDIR without running vswhere" {
  stub_path_conversion
  fake_vswhere
  VSINSTALLDIR='C:\VS' run find_vcvarsall
  assert_equal "$status" 0
  assert_equal "$output" 'C:\VS\VC\Auxiliary\Build\vcvarsall.bat'
  [[ ! -e "$VSWHERE_ARGS_FILE" ]]
}

@test "find_vcvarsall: runs vswhere with the default arguments" {
  stub_path_conversion
  fake_vswhere
  VSWHERE_OUTPUT=$'C:\\Program Files\\VS\r\n' run find_vcvarsall
  assert_equal "$status" 0
  assert_equal "$output" 'C:\Program Files\VS\VC\Auxiliary\Build\vcvarsall.bat'
  assert_equal "$(<"$VSWHERE_ARGS_FILE")" $'-latest\n-property\ninstallationPath\n-products\n*'
}

@test "find_vcvarsall: VSWHEREARGS replaces the default arguments" {
  stub_path_conversion
  fake_vswhere
  cd -- "$BATS_TEST_TMPDIR" # contains files, so an unquoted * would be expanded
  VSWHEREARGS='-products * -requires "A B"' VSWHERE_OUTPUT='C:\VS' run find_vcvarsall
  assert_equal "$status" 0
  assert_equal "$(<"$VSWHERE_ARGS_FILE")" $'-latest\n-property\ninstallationPath\n-products\n*\n-requires\nA B'
}

@test "find_vcvarsall: looks for vswhere in PATH, then in its default location" {
  stub_path_conversion
  fake_vswhere
  unset VSWHEREPATH
  VCVARSBASH_DEBUG=1 VSWHERE_OUTPUT='C:\VS' PATH="${BATS_TEST_TMPDIR}:${PATH}" \
    run --separate-stderr find_vcvarsall
  assert_equal "$status" 0
  assert_equal "${stderr_lines[0]}" "debug: vswhere path: ${BATS_TEST_TMPDIR}/vswhere"

  # Only the debug line matters: vswhere may or may not be installed there
  VCVARSBASH_DEBUG=1 PATH=/usr/bin:/bin run --separate-stderr find_vcvarsall
  assert_equal "${stderr_lines[0]}" 'debug: vswhere path: /c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe'
}

@test "find_vcvarsall: fails when vswhere finds nothing" {
  stub_path_conversion
  fake_vswhere
  VSWHERE_OUTPUT='' run --separate-stderr find_vcvarsall
  assert_equal "$status" 1
  assert_equal "$output" ''
  assert_equal "$stderr" 'error: vswhere returned an empty installation path'
}

### unixpath / winpath

# Replace the path conversion tools with stubs printing how they were called
function stub_path_tools() {
  # shellcheck disable=SC2329
  function wslpath() { printf 'wslpath %s\n' "$*"; }
  # shellcheck disable=SC2329
  function cygpath() { printf 'cygpath %s\n' "$*"; }
  # shellcheck disable=SC2329
  function realpath() { printf 'realpath %s\n' "$*"; }
}

@test "unixpath/winpath: WSL converts Windows paths with wslpath, Unix ones with realpath" {
  stub_path_tools
  bash_platform=win_wsl
  local path
  for path in 'C:\a b' 'c:/a' '\\server\share' '//server/share'; do
    assert_equal "$(unixpath "$path")" "wslpath -u -a -- ${path}"
    assert_equal "$(winpath "$path")" "$path"
  done
  for path in '/mnt/c/a' 'relative/a'; do
    assert_equal "$(unixpath "$path")" "realpath -m -- ${path}"
    assert_equal "$(winpath "$path")" "wslpath -w -a -- ${path}"
  done
}

@test "unixpath/winpath: Cygwin-like platforms always use cygpath" {
  stub_path_tools
  bash_platform=win_cyg
  assert_equal "$(unixpath 'C:\a')" 'cygpath -u -a -- C:\a'
  assert_equal "$(winpath '/c/a')" 'cygpath -w -a -l -- /c/a'
}

### pathlist_normalize / pathlist_win_to_unix

@test "pathlist_normalize: removes duplicates and empty entries, keeps order" {
  assert_equal "$(pathlist_normalize '/a::/b:/a:/c:')" '/a:/b:/c'
  assert_equal "$(pathlist_normalize '/with space:/with space')" '/with space'
  assert_equal "$(pathlist_normalize '')" ''
}

@test "pathlist_win_to_unix: Cygwin-like platforms convert all the entries with a single cygpath call" {
  stub_path_conversion
  assert_equal "$(pathlist_win_to_unix 'C:\VS\bin;;D:\My Tools;')" $'/c/VS/bin\n/d/My Tools'
  assert_equal "$(<"$CYGPATH_CALLS_FILE")" '[C:\VS\bin][D:\My Tools]'
}

@test "pathlist_win_to_unix: WSL converts each entry" {
  stub_path_conversion
  bash_platform=win_wsl
  assert_equal "$(pathlist_win_to_unix 'C:\VS\bin;;D:\My Tools;')" $'/c/VS/bin\n/d/My Tools'
  [[ ! -e "$CYGPATH_CALLS_FILE" ]]
}

@test "pathlist_win_to_unix: WSL skips entries that can't be converted" {
  stub_path_conversion
  bash_platform=win_wsl
  # shellcheck disable=SC2329
  function unixpath() {
    if [[ "$1" == 'D:\'* ]]; then return 1; fi # like wslpath on an unmounted drive
    printf '/c/%s\n' "${1:3}"
  }
  assert_equal "$(pathlist_win_to_unix 'C:\VS;D:\Missing;C:\Tools')" $'/c/VS\n/c/Tools'
}

@test "pathlist_win_to_unix: an empty list gives an empty result" {
  stub_path_conversion
  assert_equal "$(pathlist_win_to_unix ';;')" ''
  [[ ! -e "$CYGPATH_CALLS_FILE" ]]
}

### run_vcvarsall

# Use a private TMPDIR and replace cmd (cmd.exe) with a stub that logs its calls to CMD_CALLS_FILE and prints its
# arguments with CRLF line endings. If STUB_BACKGROUND_SECONDS is set, the stub also leaves a background process
# holding its stdout open, like the VS telemetry.
function stub_cmd() {
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
  mkdir -p -- "$TMPDIR"
  CMD_CALLS_FILE="${BATS_TEST_TMPDIR}/cmd.calls"
  # shellcheck disable=SC2329
  function cmd() {
    printf '%s\n' "$*" >>"$CMD_CALLS_FILE"
    printf '%s\r\n' "$@"
    if [[ -n "${STUB_BACKGROUND_SECONDS:-}" ]]; then
      sleep "$STUB_BACKGROUND_SECONDS" 2>/dev/null 3>&- & # fd 3 closed: bats waits for it
    fi
  }
}

# Arguments the cmd stub receives from: run_vcvarsall 'C:\VS\vcvarsall.bat' 'x64' 'a^ b'
CMD_ARGS=('C^:^\VS^\vcvarsall^.bat' 'x64' 'a^ b' '&&' 'set')

# Check an output of run_vcvarsall, ignoring CRs: "$(...)" removes them on MSYS2-based platforms (Git Bash, MSYS2)
function assert_cmd_output() {
  assert_equal "${1//$'\r'/}" "$(printf '%s\n' "${CMD_ARGS[@]}")"
}

@test "run_vcvarsall: escapes the path, keeps the output unchanged, and deletes its temporary file" {
  stub_cmd
  # Read the output from a file, not with "$(...)" (see assert_cmd_output)
  local output expected
  (run_vcvarsall 'C:\VS\vcvarsall.bat' 'x64' 'a^ b') >"${BATS_TEST_TMPDIR}/output"
  IFS= read -r -d '' output <"${BATS_TEST_TMPDIR}/output" || true
  printf -v expected '%s\r\n' "${CMD_ARGS[@]}"
  assert_equal "$output" "$expected"
  assert_equal "$(ls -A -- "$TMPDIR")" ''
}

@test "run_vcvarsall: does not wait for background processes holding the output open" {
  stub_cmd
  STUB_BACKGROUND_SECONDS=5
  local start=$SECONDS output
  output=$(run_vcvarsall 'C:\VS\vcvarsall.bat' 'x64' 'a^ b')
  assert_cmd_output "$output"
  ((SECONDS - start < 3))
}

@test "run_vcvarsall: falls back to a pipe when no temporary file can be created" {
  stub_cmd
  TMPDIR="${BATS_TEST_TMPDIR}/missing"
  VCVARSBASH_DEBUG=1 run --separate-stderr run_vcvarsall 'C:\VS\vcvarsall.bat' 'x64' 'a^ b'
  assert_equal "$status" 0
  assert_cmd_output "$output"
  assert_equal "$stderr" 'debug: cannot use a temporary file, reading the vcvarsall.bat output from a pipe'
}

@test "run_vcvarsall: falls back to a pipe when the temporary file can't be written, running cmd once" {
  stub_cmd
  # shellcheck disable=SC2329
  function mktemp() {
    # Return an unwritable path for the script's temporary file only (bats uses mktemp too)
    if [[ "$*" != *vcvars-bash.* ]]; then
      command mktemp "$@"
      return
    fi
    printf '%s\n' "${BATS_TEST_TMPDIR}/missing/file"
  }
  run --separate-stderr run_vcvarsall 'C:\VS\vcvarsall.bat' 'x64' 'a^ b'
  assert_equal "$status" 0
  assert_cmd_output "$output"
  assert_equal "$(wc -l <"$CMD_CALLS_FILE")" 1
  [[ "$stderr" == *'No such file or directory'* ]]
}

### wslenv_merge

@test "wslenv_merge: keeps the other entries, and replaces the ones for the same variables" {
  assert_equal "$(wslenv_merge 'WT_SESSION::INCLUDE/p:Lib/l:PATH/l' 'INCLUDE/w' 'LIB/w' 'Path/w')" \
    'WT_SESSION:INCLUDE/w:LIB/w:Path/w'
  assert_equal "$(wslenv_merge 'WT_SESSION:INCLUDE/w' 'INCLUDE/w')" 'WT_SESSION:INCLUDE/w'
  assert_equal "$(wslenv_merge '' 'INCLUDE/w')" 'INCLUDE/w'
}

### parse_vcvarsall_env

# Short "vcvarsall.bat && set" output (with LF line endings), see also fixtures/vcvarsall-x64.txt
VCVARSALL_BANNER='**********************************************************************
** Visual Studio 2022 Developer Command Prompt v17.0
** Copyright (c) 2022 Microsoft Corporation
**********************************************************************
[vcvarsall.bat] Environment initialized for: '\''x64'\'''
VCVARSALL_OUTPUT="${VCVARSALL_BANNER}"'
__VSCMD_PREINIT_PATH=C:\Windows
ALLUSERSPROFILE=C:\ProgramData
INCLUDE=C:\VS\include;C:\SDK\include
LIB=C:\VS\lib
Path=C:\VS\bin;C:\Windows;C:\VS\bin
ProgramFiles(x86)=C:\Program Files (x86)
VSCMD_ARG_TGT_ARCH=x64
VSINSTALLDIR=C:\VS\
WindowsSdkDir=C:\SDK\
VS170COMNTOOLS=C:\VS\Tools\'

@test "parse_vcvarsall_env: banner goes to stderr, filtered exports to stdout" {
  stub_path_conversion
  script_mode=default
  PATH=/usr/bin:/bin
  run --separate-stderr parse_vcvarsall_env <<<"$VCVARSALL_OUTPUT"
  assert_equal "$status" 0
  assert_equal "$stderr" "$VCVARSALL_BANNER"
  assert_equal "$output" "export INCLUDE='C:\\VS\\include;C:\\SDK\\include'
export LIB='C:\\VS\\lib'
export WINDOWS_PATH='C:\\VS\\bin;C:\\Windows;C:\\VS\\bin'
export PATH='/usr/bin:/bin:/c/VS/bin:/c/Windows'
export VSCMD_ARG_TGT_ARCH='x64'
export VSINSTALLDIR='C:\\VS\\'
export WINDOWSSDKDIR='C:\\SDK\\'
export VS170COMNTOOLS='C:\\VS\\Tools\\'"
}

# Exported variables of VCVARSALL_OUTPUT, as WSLENV entries
WSLENV_ENTRIES='INCLUDE/w:LIB/w:VSCMD_ARG_TGT_ARCH/w:VSINSTALLDIR/w:WINDOWSSDKDIR/w:VS170COMNTOOLS/w'

@test "parse_vcvarsall_env: on WSL, adds the exported variables to WSLENV" {
  stub_path_conversion
  bash_platform=win_wsl
  script_mode=default
  PATH=/usr/bin:/bin
  WSLENV=WT_SESSION run --separate-stderr parse_vcvarsall_env <<<"$VCVARSALL_OUTPUT"
  assert_equal "$status" 0
  assert_equal "${lines[-1]}" "export WSLENV='WT_SESSION:${WSLENV_ENTRIES}'"
}

@test "parse_vcvarsall_env: on WSL, VCVARS_WSL_SHARE_PATH=1 also passes the PATH to Windows programs, as Path" {
  stub_path_conversion
  bash_platform=win_wsl
  script_mode=default
  PATH=/usr/bin:/bin
  VCVARS_WSL_SHARE_PATH=1 run --separate-stderr parse_vcvarsall_env <<<"$VCVARSALL_OUTPUT"
  assert_equal "$status" 0
  assert_equal "${lines[-2]}" "export Path='C:\\VS\\bin;C:\\Windows;C:\\VS\\bin'"
  assert_equal "${lines[-1]}" "export WSLENV='${WSLENV_ENTRIES}:Path/w'"
}

@test "parse_vcvarsall_env: exports the MSVC variables of a full vcvarsall.bat output" {
  stub_path_conversion
  script_mode=default
  run --separate-stderr parse_vcvarsall_env <"${BATS_TEST_DIRNAME}/fixtures/vcvarsall-x64.txt"
  assert_equal "$status" 0
  assert_equal "$(grep -o '^export [A-Z0-9_]*' <<<"$output")" 'export COMMANDPROMPTTYPE
export DEVENVDIR
export EXTENSIONSDKDIR
export EXTERNAL_INCLUDE
export FRAMEWORK40VERSION
export FRAMEWORKDIR
export FRAMEWORKDIR64
export FRAMEWORKVERSION
export FRAMEWORKVERSION64
export FSHARPINSTALLDIR
export HTMLHELPDIR
export INCLUDE
export LIB
export LIBPATH
export NETFXSDKDIR
export WINDOWS_PATH
export PATH
export PLATFORM
export UCRTVERSION
export UNIVERSALCRTSDKDIR
export VCIDEINSTALLDIR
export VCINSTALLDIR
export VCPKG_ROOT
export VCTOOLSINSTALLDIR
export VCTOOLSREDISTDIR
export VCTOOLSVERSION
export VISUALSTUDIOVERSION
export VS180COMNTOOLS
export VSCMD_ARG_APP_PLAT
export VSCMD_ARG_HOST_ARCH
export VSCMD_ARG_TGT_ARCH
export VSCMD_VER
export VSINSTALLDIR
export VSSDK150INSTALL
export VSSDKINSTALL
export WINDOWSLIBPATH
export WINDOWSSDKBINPATH
export WINDOWSSDKDIR
export WINDOWSSDKLIBVERSION
export WINDOWSSDKVERBINPATH
export WINDOWSSDKVERSION
export WINDOWSSDK_EXECUTABLEPATH_X64
export WINDOWSSDK_EXECUTABLEPATH_X86'
}

@test "parse_vcvarsall_env: CRLF line endings give the same result as LF" {
  stub_path_conversion
  script_mode=default
  PATH=/usr/bin:/bin
  run --separate-stderr parse_vcvarsall_env <<<"$VCVARSALL_OUTPUT"
  local lf_output=$output lf_stderr=$stderr
  run --separate-stderr parse_vcvarsall_env <<<"${VCVARSALL_OUTPUT//$'\n'/$'\r\n'}"$'\r'
  assert_equal "$status" 0
  assert_equal "$stderr" "$lf_stderr"
  assert_equal "$output" "$lf_output"
}

@test "parse_vcvarsall_env: banner lines are printed verbatim" {
  script_mode=default
  # Not using "run --separate-stderr": it strips leading whitespace from $stderr
  parse_vcvarsall_env <<<"  a=b=
c=
init: Environment initialized for: 'x64'" 2>"${BATS_TEST_TMPDIR}/stderr"
  assert_equal "$(<"${BATS_TEST_TMPDIR}/stderr")" "  a=b=
c=
init: Environment initialized for: 'x64'"
}

@test "parse_vcvarsall_env: keeps only the first of case-insensitive duplicates" {
  script_mode=default
  run --separate-stderr parse_vcvarsall_env <<<"init: Environment initialized for: 'x64'
VSCMD_TEST=4
vscmd_test=3
VsCmd_Test=1"
  assert_equal "$status" 0
  assert_equal "$output" "export VSCMD_TEST='4'"
}

@test "parse_vcvarsall_env: splits on the first '=' only" {
  script_mode=default
  run --separate-stderr parse_vcvarsall_env <<<"init: Environment initialized for: 'x64'
VSCMD_A=a=b=
VSCMD_B=abc=
VSCMD_C==
VSCMD_D=
VSCMD_E
PATH"
  assert_equal "$status" 0
  assert_equal "$output" "export VSCMD_A='a=b='
export VSCMD_B='abc='
export VSCMD_C='='
export VSCMD_D=''"
}

@test "parse_vcvarsall_env: exported values survive eval unchanged, in bash and other shells" {
  local value='it'\''s "$HOME" `id` $(id) \ \\ ; & | trailing\'
  script_mode=default
  run --separate-stderr parse_vcvarsall_env <<<"init: Environment initialized for: 'x64'
VSCMD_TEST=${value}"
  assert_equal "$status" 0
  eval "$output"
  assert_equal "$VSCMD_TEST" "$value"

  # Other shells to check, e.g. TEST_SHELLS="dash zsh" (as in CI)
  local shells shell
  read -ra shells <<<"${TEST_SHELLS:-sh}"
  for shell in "${shells[@]}"; do
    assert_equal "${shell}: $(env -u VSCMD_TEST "$shell" -c "${output}"$'\nprintf %s "$VSCMD_TEST"')" "${shell}: ${value}"
  done
}

@test "parse_vcvarsall_env: run mode exports into the current shell" {
  stub_path_conversion
  script_mode=run
  PATH=/usr/bin:/bin
  unset ALLUSERSPROFILE # set on Windows
  parse_vcvarsall_env <<<"$VCVARSALL_OUTPUT" >"${BATS_TEST_TMPDIR}/stdout" 2>/dev/null
  assert_equal "$(<"${BATS_TEST_TMPDIR}/stdout")" ''
  assert_equal "$INCLUDE" 'C:\VS\include;C:\SDK\include'
  assert_equal "$PATH" '/usr/bin:/bin:/c/VS/bin:/c/Windows'
  assert_equal "$WINDOWS_PATH" 'C:\VS\bin;C:\Windows;C:\VS\bin'
  assert_equal "$(printenv VSCMD_ARG_TGT_ARCH)" 'x64'
  assert_equal "${ALLUSERSPROFILE:-unset}" 'unset'
}

@test "parse_vcvarsall_env: VCVARS_SILENT=1 hides the vcvarsall.bat messages" {
  stub_path_conversion
  script_mode=default
  VCVARS_SILENT=1 run --separate-stderr parse_vcvarsall_env <<<"$VCVARSALL_OUTPUT"
  assert_equal "$status" 0
  assert_equal "$stderr" ''
  [[ "$output" == *"export VSCMD_ARG_TGT_ARCH='x64'"* ]]
}

@test "parse_vcvarsall_env: VCVARS_SILENT=1 still prints the messages on failure" {
  script_mode=default
  VCVARS_SILENT=1 run --separate-stderr parse_vcvarsall_env <<<'[ERROR:vcvarsall.bat] Invalid argument found : bogus'
  assert_equal "$status" 1
  assert_equal "$stderr" '[ERROR:vcvarsall.bat] Invalid argument found : bogus
error: vcvarsall.bat failed'
}

@test "parse_vcvarsall_env: fails when vcvarsall.bat did not initialize" {
  script_mode=default
  run --separate-stderr parse_vcvarsall_env <<<'[ERROR:vcvarsall.bat] Invalid argument found : bogus
VSCMD_TEST=1'
  assert_equal "$status" 1
  assert_equal "$output" ''
  assert_equal "$stderr" '[ERROR:vcvarsall.bat] Invalid argument found : bogus
VSCMD_TEST=1
error: vcvarsall.bat failed'
}
