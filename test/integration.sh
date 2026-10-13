#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Integration tests against a real Visual Studio installation.
# Must be run on Windows from a supported Bash (Git Bash, MSYS2, Cygwin, WSL).
# Each test runs in its own process, from a temporary directory.
#
# Note: cl is called as cl.exe, as WSL does not add the extension, and its options use the "-" form, as "/" ones
# get mangled by MSYS path conversion.

# Paths
root=$(realpath -- "$(dirname -- "$0")/..")
vswhere_default='C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'

function main() {
  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: work is local
  trap "rm -rf -- $(printf '%q' "$work")" EXIT
  cd -- "$work"
  write_hello_cpp

  local failed=()
  check failed 'eval vcvarsall.sh exports the MSVC environment' test_eval_exports_msvc_env
  check failed 'compile and run (x64)' test_compile_and_run x64 64
  check failed 'compile and run (x86)' test_compile_and_run x86 32
  check failed 'vcvarsrun.sh compiles' test_vcvarsrun_compile
  check failed 'vcvarsrun.sh preserves arguments and exit status' test_vcvarsrun_args_and_status
  check failed 'vcvarsall.bat options reach it unchanged' test_vcvarsall_options
  check failed 'special characters survive the round trip' test_special_chars_roundtrip
  check failed 'non-ASCII characters survive the round trip' test_non_ascii_chars_roundtrip
  check failed 'stdin is not consumed' test_stdin_not_consumed
  check failed 'VSWHEREPATH, VSWHEREARGS and VSINSTALLDIR are honored' test_install_options
  check failed 'invalid usages fail' test_invalid_usages
  check failed 'WSL: no warning from a Linux directory' test_wsl_no_unc_warning
  check failed 'WSL: VCVARS_WSL_SHARE_PATH passes the PATH to Windows programs' test_wsl_share_path

  if [[ "${#failed[@]}" -gt 0 ]]; then
    printf '\nerror: %d test(s) failed:\n' "${#failed[@]}" >&2
    printf '  - %s\n' "${failed[@]}" >&2
    return 1
  fi
  printf '\nAll tests passed\n'
}

### Tests

function test_eval_exports_msvc_env() {
  eval "$(vcvarsall x64)"
  assert 'INCLUDE is set' test -n "${INCLUDE:-}"
  assert 'LIB is set' test -n "${LIB:-}"
  assert 'WINDOWS_PATH is set' test -n "${WINDOWS_PATH:-}"
  assert "VSCMD_ARG_TGT_ARCH is x64 (${VSCMD_ARG_TGT_ARCH:-})" test "${VSCMD_ARG_TGT_ARCH:-}" == x64
  assert 'cl.exe is in PATH' command -v cl.exe
  local dups
  dups=$(tr ':' '\n' <<<"$PATH" | sort | uniq -d)
  assert "PATH has no duplicates (${dups})" test -z "$dups"
}

# Compile hello.cpp for an architecture, then check the bitness printed by the executable
function test_compile_and_run() {
  local arch=$1 bits=$2
  eval "$(vcvarsall "$arch")"
  cl.exe -nologo -EHsc "-Fehello_${arch}.exe" hello.cpp
  chmod +x -- "hello_${arch}.exe" # not executable when written to the Linux filesystem from WSL
  local out
  out=$("./hello_${arch}.exe" | tr -d '\r')
  assert "hello_${arch}.exe prints 'hello ${bits}' (${out})" test "$out" == "hello ${bits}"
}

function test_vcvarsrun_compile() {
  vcvarsrun x64 -- cl.exe -nologo -EHsc -Fehello_run.exe hello.cpp
  assert 'hello_run.exe exists' test -f hello_run.exe
}

function test_vcvarsrun_args_and_status() {
  local out
  # shellcheck disable=SC2016 # expanded by the inner bash
  out=$(vcvarsrun x64 -- bash -c 'printf "[%s]" "$@"' _ 'a b' '' "it's" --)
  assert "arguments are preserved (${out})" test "$out" == "[a b][][it's][--]"
  assert_status 3 vcvarsrun x64 -- bash -c 'exit 3'
}

# "-vcvars_ver=<version>" contains "=", which batch files treat as an argument separator
function test_vcvarsall_options() {
  local version
  version=$(
    eval "$(vcvarsall x64)"
    printf '%s' "$VCTOOLSVERSION"
  )
  eval "$(vcvarsall x64 "-vcvars_ver=${version}")"
  assert "VSCMD_ARG_VCVARS_VER is ${version} (${VSCMD_ARG_VCVARS_VER:-})" test "${VSCMD_ARG_VCVARS_VER:-}" == "$version"
  assert_status 1 vcvarsall x64 -vcvars_ver=0.0
}

# VSCMD_* variables are kept, so an inherited one goes through the whole pipeline
function test_special_chars_roundtrip() {
  check_roundtrip "it's \$HOME \`id\` a=b ; trailing\\"
}

function test_non_ascii_chars_roundtrip() {
  type -P iconv >/dev/null || skip 'iconv not found'
  check_roundtrip 'Café José 日本 €'
}

function test_stdin_not_consumed() {
  local out
  out=$(printf 'keep me\n' | {
    eval "$(vcvarsall x64)"
    cat
  })
  assert "stdin is still readable (${out})" test "$out" == 'keep me'
}

function test_install_options() {
  VSWHEREPATH="$vswhere_default" VSWHEREARGS='-products *' vcvarsall x64 >/dev/null
  VSWHEREARGS='-requires "Nonexistent.Component"' assert_status 1 vcvarsall x64

  # VSINSTALLDIR is exported by vcvarsall.bat itself, so reuse it (vswhere must not be needed then)
  local vsinstalldir
  # shellcheck disable=SC2153 # VSINSTALLDIR comes from the eval
  vsinstalldir=$(
    eval "$(vcvarsall x64)"
    printf '%s' "$VSINSTALLDIR"
  )
  VSINSTALLDIR="$vsinstalldir" VSWHEREPATH='C:\nonexistent\vswhere.exe' vcvarsall x64 >/dev/null
  VSINSTALLDIR='C:\nonexistent' assert_status 1 vcvarsall x64
}

function test_wsl_no_unc_warning() {
  [[ "$OSTYPE" == linux* ]] || skip 'not on WSL'
  cd -- "$HOME" # a Linux directory
  local stderr
  stderr=$(vcvarsall x64 2>&1 >/dev/null)
  assert "no UNC warning (${stderr})" test "$stderr" == "${stderr/UNC paths/}"
}

function test_wsl_share_path() {
  [[ "$OSTYPE" == linux* ]] || skip 'not on WSL'
  eval "$(VCVARS_WSL_SHARE_PATH=1 vcvarsall x64)"
  local found
  found=$(cmd.exe /c where cl 2>/dev/null | tr -d '\r')
  assert "a Windows program finds cl.exe in its PATH (${found})" test "${found##*\\}" == 'cl.exe'
}

function test_invalid_usages() {
  assert_status 1 vcvarsall
  assert_status 1 vcvarsall x64 --
  assert_status 1 vcvarsrun x64
  assert_status 1 vcvarsrun x64 --
  assert_status 1 vcvarsall bogusarch
  VSWHEREARGS='"unclosed' assert_status 1 vcvarsall x64
}

### Helpers

# Export a variable so that Windows programs get it (on WSL, add it to WSLENV), then check that vcvarsall.sh exports
# it back from the vcvarsall.bat environment, unchanged
# Inputs:
#   $1: The value to check
function check_roundtrip() {
  local value=$1
  export VSCMD_TEST_VALUE="$value"
  if [[ "$OSTYPE" == linux* ]]; then export WSLENV="${WSLENV:+${WSLENV}:}VSCMD_TEST_VALUE/w"; fi
  local exports
  exports=$(vcvarsall x64)
  assert 'VSCMD_TEST_VALUE is exported' grep -q '^export VSCMD_TEST_VALUE=' <<<"$exports"
  eval "$exports"
  assert "value is preserved (${VSCMD_TEST_VALUE})" test "$VSCMD_TEST_VALUE" == "$value"
}

# Skip the current test, with a reason (see check)
function skip() {
  printf 'skip: %s\n' "$1"
  exit 77
}

# Run a test and print its result, adding its name to the array named by $1 when it fails.
# Never call it from a condition: the test runs as a background job so that it gets its own
# process with errexit active, which is not the case when the caller is in a condition.
function check() {
  local -n _failed="$1"
  local name=$2
  shift 2
  "$@" >test.log 2>&1 &
  local status=0
  wait "$!" || status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'ok - %s\n' "$name"
  elif [[ "$status" -eq 77 ]]; then
    printf 'ok - %s # %s\n' "$name" "$(sed -n 's/^skip: /skip /p' -- test.log | tail -n 1)"
  else
    printf 'not ok - %s\n' "$name"
    sed 's/^/  # /' -- test.log
    _failed+=("$name")
  fi
}

# Fail with a message if the command fails
function assert() {
  local msg=$1
  shift
  if ! "$@"; then
    printf 'error: assertion failed: %s\n' "$msg" >&2
    return 1
  fi
}

# Run a command and fail if its exit status is not the expected one
function assert_status() {
  local expected=$1
  shift
  local status
  if "$@"; then status=0; else status=$?; fi
  assert "exit status ${status} == ${expected} ($*)" test "$status" -eq "$expected"
}

function vcvarsall() {
  bash -- "${root}/vcvarsall.sh" "$@"
}

function vcvarsrun() {
  bash -- "${root}/vcvarsrun.sh" "$@"
}

# Write a program printing its bitness ("hello 64" or "hello 32")
function write_hello_cpp() {
  cat >hello.cpp <<'EOF'
#include <iostream>
int main() { std::cout << "hello " << sizeof(void*) * 8 << std::endl; return 0; }
EOF
}

eval 'main "$@";exit "$?"'
