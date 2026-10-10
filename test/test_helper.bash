# shellcheck shell=bash

# Load the vcvarsall.sh functions, without invoking main
# The script options (set -Eeuo pipefail, ...) stay active, so functions run as in production.
function load_vcvarsall() {
  local code
  code=$(sed -- "/^eval 'main /d" "${BATS_TEST_DIRNAME}/../vcvarsall.sh")
  eval "$code"
}

# Replace unixpath and winpath (which need wslpath/cygpath) with minimal stand-ins:
# "C:\a\b" <-> "/c/a/b", other paths are kept as-is
function stub_path_conversion() {
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
