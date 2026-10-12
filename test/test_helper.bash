# shellcheck shell=bash

# Load the vcvarsall.sh functions, without invoking main
# The script options (set -Eeuo pipefail, ...) stay active, so functions run as in production.
function load_vcvarsall() {
  local code
  code=$(sed -- "/^eval 'main /d" "${BATS_TEST_DIRNAME}/../vcvarsall.sh")
  eval "$code"
}

# Replace unixpath, winpath and the path list conversion (which need wslpath/cygpath) with minimal stand-ins:
# "C:\a\b" <-> "/c/a/b", other paths are kept as-is.
# The platform is set to Cygwin-like, and the cygpath calls are logged to CYGPATH_CALLS_FILE.
function stub_path_conversion() {
  # shellcheck disable=SC2034 # used by the tested functions
  bash_platform=win_cyg
  CYGPATH_CALLS_FILE="${BATS_TEST_TMPDIR}/cygpath.calls"
  # shellcheck disable=SC2329
  function cygpath() {
    if [[ "$#" -lt 4 || "$1 $2 $3" != '-u -a --' ]]; then
      printf 'unexpected cygpath call: %s\n' "$*" >&2
      return 1
    fi
    shift 3
    printf '[%s]' "$@" >>"$CYGPATH_CALLS_FILE"
    printf '\n' >>"$CYGPATH_CALLS_FILE"
    local path_dir
    for path_dir in "$@"; do unixpath "$path_dir"; done
  }
  # shellcheck disable=SC2329
  function unixpath() {
    local path=$1
    if [[ "$path" != [a-zA-Z]:\\* ]]; then
      printf '%s\n' "$path"
      return
    fi
    path=${path//\\//}
    local drive=${path:0:1}
    printf '/%s%s\n' "${drive,,}" "${path:2}"
  }
  # shellcheck disable=SC2329
  function winpath() {
    local path=$1
    if [[ "$path" != /[a-z]/* ]]; then
      printf '%s\n' "$path"
      return
    fi
    path=${path:1:1}:${path:2}
    printf '%s\n' "${path//\//\\}"
  }
}

# Fail with a readable message if the two values differ
function assert_equal() {
  local actual=$1 expected=$2
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    return 1
  fi
}
