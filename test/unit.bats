#!/usr/bin/env bats
# Unit tests for the vcvarsall.sh functions, runnable on any OS (no Windows tools needed).
# shellcheck disable=SC2154,SC2034,SC1003,SC2016 # globals of the tested functions, literal backslashes

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  load_vcvarsall
  # Ignore the user's settings (e.g. VSINSTALLDIR is set after "eval $(vcvarsall.sh x64)")
  unset VCVARS_SILENT VCVARSBASH_DEBUG VSINSTALLDIR VSWHEREARGS VSWHEREPATH
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

@test "detect_platform: WSL" {
  OSTYPE=linux-gnu WSL_DISTRO_NAME=Ubuntu detect_platform
  assert_equal "$bash_platform" 'win_wsl'
}

@test "detect_platform: other platforms are rejected" {
  OSTYPE=linux-gnu WSL_DISTRO_NAME='' run detect_platform
  assert_equal "$status" 1
  assert_equal "${lines[0]}" 'error: Unsupported platform (linux-gnu)'
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

### cmdesc

@test "cmdesc: escapes everything but alphanumerics" {
  assert_equal "$(cmdesc 'x64')" 'x64'
  assert_equal "$(cmdesc 'a b&c|d^e%f"g<h>i(j)k!l')" 'a^ b^&c^|d^^e^%f^"g^<h^>i^(j^)k^!l'
  assert_equal "$(cmdesc 'C:\VS\vcvarsall.bat')" 'C^:^\VS^\vcvarsall^.bat'
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

### pathlist_normalize / pathlist_win_to_unix / fix_crlf

@test "pathlist_normalize: removes duplicates and empty entries, keeps order" {
  assert_equal "$(pathlist_normalize '/a::/b:/a:/c:')" '/a:/b:/c'
  assert_equal "$(pathlist_normalize '/with space:/with space')" '/with space'
  assert_equal "$(pathlist_normalize '')" ''
}

@test "pathlist_win_to_unix: converts each entry, skips empty ones" {
  stub_path_conversion
  assert_equal "$(pathlist_win_to_unix 'C:\VS\bin;;D:\My Tools;')" '/c/VS/bin:/d/My Tools'
}

@test "fix_crlf: removes trailing CR only" {
  assert_equal "$(printf 'a\r\nb\rc\r\n' | fix_crlf)" $'a\nb\rc'
}

### parse_vcvarsall_env

# Short "vcvarsall.bat && set" output (after fix_crlf), see also fixtures/vcvarsall-x64.txt
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

@test "parse_vcvarsall_env: exports the MSVC variables of a full vcvarsall.bat output" {
  stub_path_conversion
  script_mode=default
  local fixture
  fixture=$(fix_crlf <"${BATS_TEST_DIRNAME}/fixtures/vcvarsall-x64.txt")
  run --separate-stderr parse_vcvarsall_env <<<"$fixture"
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
