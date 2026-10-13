#!/usr/bin/env bash
#
# Source: https://github.com/nathan818fr/vcvars-bash
# Author: Nathan Poirier <nathan@poirier.io>
#
set -Eeuo pipefail
shopt -s inherit_errexit

declare -r VERSION='2026-10-13.1'

# Detect the platform
# Outputs:
#   bash_platform: 'win_cyg' (Git Bash, MSYS2, Cygwin) or 'win_wsl'
function detect_platform() {
  case "${OSTYPE:-}" in
  cygwin* | msys* | win32)
    declare -gr bash_platform='win_cyg'
    ;;
  *)
    # WSL sets WSL_DISTRO_NAME in the sessions it starts, but not in others (e.g. SSH sessions)
    if [[ -n "${WSL_DISTRO_NAME:-}" ]] || is_wsl_kernel; then
      declare -gr bash_platform='win_wsl'
    else
      printf 'error: Unsupported platform (%s)\n' "${OSTYPE:-}" >&2
      printf 'hint: This script only supports Bash on Windows (Git Bash, WSL, etc.)\n' >&2
      return 1
    fi

    if ! type -P cmd.exe >/dev/null; then
      printf 'error: cmd.exe not found in PATH\n' >&2
      printf 'hint: The Windows PATH is missing (e.g. SSH session, appendWindowsPath=false)\n' >&2
      printf 'hint: Add the Windows system directory to PATH, e.g. /mnt/c/Windows/System32\n' >&2
      return 1
    fi
    ;;
  esac
}

function detect_mode() {
  # Detect the mode depending on the name called
  if [[ "${0##*/}" == vcvarsrun* ]]; then
    declare -gr script_mode='run' # vcvarsrun.sh
  else
    declare -gr script_mode='default' # vcvarsall.sh
  fi
}

function print_usage() {
  case "$script_mode" in
  default)
    cat <<EOF
Usage: eval "\$(vcvarsall.sh [vcvarsall.bat arguments])"
Script version: $VERSION

Load MSVC environment variables using vcvarsall.bat and export them.
The script writes a list of export commands to stdout, to be evaluated by a
POSIX-compliant shell.

Example: eval "\$(vcvarsall.sh x86)"
EOF
    ;;
  run)
    cat <<EOF
Usage: vcvarsrun.sh [vcvarsall.bat arguments] -- command [arguments...]
Script version: $VERSION

Load MSVC environment variables using vcvarsall.bat and execute a command with
them.

Example: vcvarsrun.sh x64 -- cl /nologo /EHsc /Fe:hello.exe hello.cpp
EOF
    ;;
  esac
  cat <<EOF

Environment variables:
  VCVARS_SILENT
    If set to 1, suppress the vcvarsall.bat output (still prints errors if
    initialization fails).
    Default: 0

  VCVARS_WSL_SHARE_PATH
    WSL only. If set to 1, also pass the PATH to the Windows programs (e.g. so
    that a Windows cmake.exe finds cl.exe), through a "Path" variable.
    Default: 0

  VSINSTALLDIR
    The path to the Visual Studio installation directory.
    Example: "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community"
    Default: The latest Visual Studio installation directory found by
             vswhere.exe

  VSWHEREPATH
    The path to the vswhere.exe executable.
    Example: "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
    Default: Automatically detected (in the PATH or well-known locations)

  VSWHEREARGS
    The arguments to pass to vswhere.exe.
    This value is always automatically prefixed with "-latest -property installationPath".
    Default: "-products *"
EOF
  local vcvarsall
  vcvarsall=$(find_vcvarsall)
  printf '\nvcvarsall.bat arguments: %s\n' "$({ cmd "$(cmdesc "$vcvarsall")" -help </dev/null 2>/dev/null || true; } | sed 's/\r$//; /^Syntax:/d; s/^    vcvarsall.bat //')"
}

function main() {
  detect_platform
  detect_mode

  # Parse arguments
  if [[ $# -eq 0 ]]; then
    print_usage >&2
    return 1
  fi

  local arg vcvarsall_args=()
  for arg in "$@"; do
    shift
    if [[ "$arg" == '--' ]]; then
      if [[ "$script_mode" == 'default' ]]; then
        printf 'error: Unexpected argument: --\n' >&2
        printf 'hint: Use vcvarsrun to run a command\n' >&2
        return 1
      fi
      break
    fi
    vcvarsall_args+=("$(cmdesc "$arg")")
  done

  if [[ "$script_mode" == 'run' && $# -eq 0 ]]; then
    printf 'error: No command specified\n' >&2
    return 1
  fi

  # Get MSVC environment variables from vcvarsall.bat
  local vcvarsall vcvarsall_env
  vcvarsall=$(find_vcvarsall)
  vcvarsall_env=$(run_vcvarsall "$vcvarsall" "${vcvarsall_args[@]}")

  # Filter MSVC environment variables and export them
  parse_vcvarsall_env <<<"$vcvarsall_env"

  # Execute command if needed
  if [[ "$script_mode" == 'run' ]]; then
    exec "$@"
  fi
}

# Filter MSVC environment variables from the vcvarsall.bat output and export them
# Inputs:
#   stdin: The output of "vcvarsall.bat && set" (with CRLF or LF line endings)
#   script_mode: 'default' to write export commands, 'run' to export variables in the current shell
#   VCVARS_SILENT: If 1, print the vcvarsall.bat messages only on failure
# Outputs:
#   stdout: The export commands (in 'default' mode)
#   stderr: The vcvarsall.bat messages (everything up to the "Environment initialized" line)
function parse_vcvarsall_env() {
  # The list of variables to export was based on a comparison between a clean environment and the vcvarsall.bat
  # environment (on different MSVC versions, tools and architectures).
  #
  # Windows environment variables are case-insensitive while Unix-like environment variables are case-sensitive, so:
  # - we always use uppercase names to prevent duplicates environment variables on the Unix-like side
  # - we also ensure that only the first occurrence of a variable is exported (see below)
  #
  # While Windows environment variables are case-insensitive, it is possible to have duplicates in some edge cases.
  # e.g. using Git Bash:
  #  export xxx=1; export XXX=2; export xXx=3; cmd.exe //c set XxX=4 '&&' set
  # will output:
  #  XXX=4
  #  xXx=3
  #  xxx=1

  declare -A seen_vars
  local windows_vars=() # The exported variables to pass to Windows programs (see WSLENV below)
  function export_env() {
    local name=${1^^}
    local value=$2
    if [[ ! "$name" =~ ^[A-Z0-9_]+$ ]]; then return; fi
    if [[ -n "${seen_vars[$name]:-}" ]]; then return; fi
    seen_vars[$name]=1
    if [[ "$name" != @(PATH|WINDOWS_PATH|WSLENV) ]]; then windows_vars+=("$name"); fi
    export_var "$name" "$value"
  }
  function export_var() {
    if [[ "$script_mode" == 'run' ]]; then
      export "${1}=${2}"
    else
      printf "export %s='%s'\n" "$1" "${2//\'/\'\\\'\'}"
    fi
  }

  local line name value initialized=false suppressed_output=() windows_path=''
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ "$initialized" == 'false' ]]; then
      if [[ "$line" == *' Environment initialized for: '* ]]; then initialized=true; fi
      if [[ "${VCVARS_SILENT:-}" == 1 ]]; then
        suppressed_output+=("$line")
      else
        printf '%s\n' "$line" >&2
      fi
      continue
    fi

    # Split on the first "=" only ("IFS='=' read" would drop a trailing "=" from the value)
    if [[ "$line" != *=* ]]; then continue; fi
    name=${line%%=*}
    value=${line#*=}

    case "${name^^}" in
    LIB | LIBPATH | INCLUDE | EXTERNAL_INCLUDE | COMMANDPROMPTTYPE | DEVENVDIR | EXTENSIONSDKDIR | FRAMEWORK* | \
      FSHARPINSTALLDIR | HTMLHELPDIR | NETFXSDKDIR | PLATFORM | PREFERREDTOOLARCHITECTURE | UCRT* | UNIVERSALCRTSDK* | \
      VCIDE* | VCINSTALL* | VCPKG* | VCTOOLS* | VSCMD* | VSINSTALL* | VSSDK* | VS[0-9]* | VISUALSTUDIO* | WINDOWSLIB* | \
      WINDOWSSDK*)
      export_env "$name" "$value"
      ;;
    PATH)
      # PATH is a special case, requiring special handling
      local new_paths
      new_paths=$(pathlist_win_to_unix "$value")             # Convert to unix-style paths, one per line
      new_paths=${new_paths//$'\n'/:}                        # Join them into a path list
      new_paths=$(pathlist_normalize "${PATH}:${new_paths}") # Prepend the current PATH
      export_env 'WINDOWS_PATH' "$value"
      export_env 'PATH' "$new_paths"
      windows_path=$value
      ;;
    esac
  done

  if [[ "$initialized" == 'false' ]]; then
    # Always print the suppressed output on initialization failure, to help debugging
    for line in "${suppressed_output[@]}"; do
      printf '%s\n' "$line" >&2
    done
    printf 'error: vcvarsall.bat failed\n' >&2
    return 1
  fi

  # On WSL, Windows programs (e.g. cl.exe) only get the Linux variables listed in WSLENV.
  # So add the exported ones there, only from WSL to Windows ("/w"), replacing their previous entries.
  #
  # PATH is not added: WSL would replace the Windows PATH with a translation of the whole Linux one.
  # So Windows programs keep their own PATH, without the MSVC tools...
  #
  # VCVARS_WSL_SHARE_PATH=1 works around it: export the Windows PATH from vcvarsall.bat as "Path", and add "Path/w" to
  # WSLENV. Linux variable names are case-sensitive, so it doesn't change the Linux PATH. But Windows ones are not, so
  # Windows programs get it as their PATH. This relies on how WSL merges the environments, which is not documented:
  # hence the flag.
  if [[ "$bash_platform" == 'win_wsl' ]]; then
    local entries=()
    for name in "${windows_vars[@]}"; do entries+=("${name}/w"); done
    if [[ "${VCVARS_WSL_SHARE_PATH:-}" == 1 && -n "$windows_path" ]]; then
      export_var 'Path' "$windows_path" # not export_env, which uppercases the names
      entries+=('Path/w')
    fi
    export_env 'WSLENV' "$(wslenv_merge "${WSLENV:-}" "${entries[@]}")"
  fi
}

# Locate vcvarsall.bat
# Inputs:
#   VSINSTALLDIR: The path to the Visual Studio installation directory (optional)
#   VSWHEREPATH: The path to the vswhere.exe executable (optional)
#   VSWHEREARGS: The arguments to pass to vswhere.exe (optional)
# Outputs:
#   stdout: The windows-style path to vcvarsall.bat
function find_vcvarsall() {
  local vsinstalldir
  if [[ -n "${VSINSTALLDIR:-}" ]]; then
    vsinstalldir="$VSINSTALLDIR"
  else
    local vswhere
    if [[ -n "${VSWHEREPATH:-}" ]]; then
      vswhere=$(unixpath "$VSWHEREPATH")
    else
      vswhere=$(command -v 'vswhere' 2>/dev/null || unixpath 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe')
    fi

    local vswhereargs=(-latest -property installationPath)
    if [[ -n "${VSWHEREARGS:-}" ]]; then
      parse_args_simple "$VSWHEREARGS"
      vswhereargs+=("${result[@]}")
    else
      vswhereargs+=(-products '*')
    fi

    if [[ "${VCVARSBASH_DEBUG:-}" == 1 ]]; then
      printf 'debug: vswhere path: %s\n' "$vswhere" >&2
      printf 'debug: vswhere args:\n' >&2
      printf 'debug:  [ %s ]\n' "${vswhereargs[@]}" >&2
    fi

    vsinstalldir=$("$vswhere" "${vswhereargs[@]}" </dev/null)
    vsinstalldir=${vsinstalldir%$'\r'}
    if [[ -z "$vsinstalldir" ]]; then
      printf 'error: vswhere returned an empty installation path\n' >&2
      return 1
    fi
  fi

  printf '%s\n' "$(winpath "$vsinstalldir")\\VC\\Auxiliary\\Build\\vcvarsall.bat"
}

# Run vcvarsall.bat followed by "set"
# Must run in a subshell, e.g. "$(run_vcvarsall ...)", as it sets an EXIT trap
# Inputs:
#   $1: The windows-style path to vcvarsall.bat
#   $2...: The vcvarsall.bat arguments (escaped with cmdesc)
# Outputs:
#   stdout: The output of "vcvarsall.bat && set" (with CRLF line endings)
function run_vcvarsall() {
  local vcvarsall
  vcvarsall=$(cmdesc "$1")
  shift

  if ! utf16_to_utf8_supported && [[ "${VCVARSBASH_DEBUG:-}" == 1 ]]; then
    printf 'debug: iconv not found, non-ASCII characters may be mangled\n' >&2
  fi

  # Prefer a temporary file to a pipe: VsDevCmd.bat sends telemetry from a background PowerShell (START /B) that
  # inherits cmd.exe's stdout, so a pipe would only be closed when it exits, several seconds after vcvarsall.bat.
  local output_file
  if output_file=$(mktemp -t vcvars-bash.XXXXXXXXXX 2>/dev/null); then
    # shellcheck disable=SC2064 # expand now: output_file is local
    trap "rm -f -- $(printf '%q' "$output_file")" EXIT
    if { cmd_unicode "$vcvarsall" "$@" '&&' 'set' </dev/null || true; } >"$output_file"; then
      cmd_unicode_to_utf8 <"$output_file"
      return
    fi
  fi

  # Fall back to a pipe if the temporary file can't be created or opened (the redirection fails before cmd.exe starts)
  if [[ "${VCVARSBASH_DEBUG:-}" == 1 ]]; then
    printf 'debug: cannot use a temporary file, reading the vcvarsall.bat output from a pipe\n' >&2
  fi
  { cmd_unicode "$vcvarsall" "$@" '&&' 'set' </dev/null || true; } | cmd_unicode_to_utf8
}

# Split command arguments into an array, with a simple logic
# - Arguments are separated by whitespace (space, tab, newline, carriage return)
# - To include whitespace in an argument, it must be enclosed in double quotes (")
# - When inside a double-quoted argument, quotes can be escaped by doubling them ("")
# Inputs:
#   $1: The string to parse
# Outputs:
#   result: An array of parsed arguments
function parse_args_simple() {
  declare -g result=()
  local str="$1 " # add a trailing space to simplify the last argument handling
  local args=()
  local current_type=none # none = waiting for next arg, normal = inside normal arg, quoted = inside quoted arg
  local current_value=''
  local i=0 len=${#str}
  while ((i < len)); do
    local c=${str:i:1}
    case "$current_type" in
    none)
      case "$c" in
      ' ' | $'\t' | $'\n' | $'\r')
        # Ignore whitespace
        ;;
      '"')
        # Start a quoted argument
        current_type=quoted
        current_value=''
        ;;
      *)
        # Start a normal argument
        current_type=normal
        current_value="$c"
        ;;
      esac
      ;;
    normal)
      case "$c" in
      ' ' | $'\t' | $'\n' | $'\r')
        # End of normal argument, add it to the list
        args+=("$current_value")
        current_type=none
        current_value=''
        ;;
      *)
        # Continue building the normal argument
        current_value+="$c"
        ;;
      esac
      ;;
    quoted)
      case "$c" in
      '"')
        if [[ "${str:i+1:1}" != '"' ]]; then
          # End of quoted argument, add it to the list
          args+=("$current_value")
          current_type=none
          current_value=''
        else
          # Escaped quote, add a single quote to the current value
          current_value+='"'
          ((++i)) # Skip the next quote
        fi
        ;;
      *)
        # Continue building the quoted argument
        current_value+="$c"
        ;;
      esac
      ;;
    esac
    ((++i))
  done
  if [[ "$current_type" != none ]]; then
    printf 'error: Unfinished %s argument: %s\n' "$current_type" "$current_value" >&2
    return 1
  fi
  declare -g result=("${args[@]}")
}

# Run a command with cmd.exe
# Inputs:
#   $1: -u to get the output of the cmd.exe internal commands (e.g. echo, set) in UTF-16, instead of the console code
#       page (e.g. 437) which mangles the non-ASCII characters (optional)
#   $@: The command string to run (use cmdesc to escape arguments when needed)
# Outputs:
#   stdout: The cmd.exe standard output
#   stderr: The cmd.exe error output
function cmd() {
  local options=()
  if [[ "${1:-}" == '-u' ]]; then
    options=(/u)
    shift
  fi

  if [[ "$bash_platform" == 'win_wsl' ]]; then
    # When started from a Linux directory, cmd.exe prints a warning ("UNC paths are not supported") and falls back to
    # the Windows directory. So start it from its own directory instead, which is a Windows one
    # (e.g. /mnt/c/Windows/System32).
    local cmd_exe
    cmd_exe=$(type -P cmd.exe)
    (cd -- "${cmd_exe%/*}" && cmd.exe "${options[@]}" /s /c " ; $* ")
    return
  fi

  # This seems to work fine on all supported platforms
  # (even with all the weird path and argument conversions on MSYS-like)
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' cmd.exe "${options[@]}" /s /c " ; $* "
}

# Shortcut for "cmd -u" when supported, otherwise "cmd" (convert its output with cmd_unicode_to_utf8)
function cmd_unicode() {
  if utf16_to_utf8_supported; then
    cmd -u "$@"
  else
    cmd "$@"
  fi
}

# Convert an output of cmd_unicode to UTF-8 (unchanged if it is not in UTF-16)
# Inputs:
#   stdin: The cmd_unicode output
# Outputs:
#   stdout: The converted output
function cmd_unicode_to_utf8() {
  if utf16_to_utf8_supported; then
    if ! utf16_to_utf8; then
      printf 'error: cannot convert the cmd.exe output from UTF-16\n' >&2
      return 1
    fi
  else
    local output
    IFS= read -r -d '' output || true # read until EOF
    printf '%s' "$output"
  fi
}

# Escape a cmd.exe command argument
# Inputs:
#   $1: The argument to escape
# Outputs:
#   stdout: The escaped argument
function cmdesc() {
  local str=$1 escaped='' i c
  for ((i = 0; i < ${#str}; i++)); do
    c=${str:i:1}
    if [[ "$c" == [0-9A-Za-z] ]]; then escaped+=$c; else escaped+="^$c"; fi
  done
  printf '%s\n' "$escaped"
}

# Convert path to an absolute unix-style path
# Inputs:
#   $1: The path to convert
# Outputs:
#   stdout: The converted path
function unixpath() {
  local path=$1
  case "$bash_platform" in
  win_wsl)
    case "$path" in
    [a-zA-Z]:\\* | [a-zA-Z]:/* | \\\\* | //*)
      # Convert windows path using wslpath (unix mode, absolute path)
      wslpath -u -a -- "$path"
      ;;
    *)
      # Convert unix path using realpath
      realpath -m -- "$path"
      ;;
    esac
    ;;
  *)
    cygpath -u -a -- "$path"
    ;;
  esac
}

# Convert path to an absolute windows-style path
# Inputs:
#   $1: The path to convert
# Outputs:
#   stdout: The converted path
function winpath() {
  local path=$1
  case "$bash_platform" in
  win_wsl)
    case "$path" in
    [a-zA-Z]:\\* | [a-zA-Z]:/* | \\\\* | //*)
      # Already a windows path
      printf '%s' "$path"
      ;;
    *)
      # Convert using wslpath (windows mode, absolute path)
      wslpath -w -a -- "$path"
      ;;
    esac
    ;;
  *)
    # Convert using cygpath (windows mode, absolute path, long form)
    cygpath -w -a -l -- "$path"
    ;;
  esac
}

# Convert a windows-style path list to unix-style paths, skipping empty entries
# Inputs:
#   $1: The windows-style path list to convert
# Outputs:
#   stdout: The converted unix-style paths, one per line
function pathlist_win_to_unix() {
  local win_paths=$1

  local path_dir entries=()
  while IFS= read -r -d';' path_dir; do
    if [[ -n "$path_dir" ]]; then entries+=("$path_dir"); fi
  done <<<"${win_paths};"
  if [[ "${#entries[@]}" -eq 0 ]]; then return; fi

  case "$bash_platform" in
  win_wsl)
    # wslpath converts a single path, and fails for some entries (e.g. on an unmounted drive): skip them
    for path_dir in "${entries[@]}"; do unixpath "$path_dir" || true; done
    ;;
  *)
    # A single cygpath call for all the entries (same options as unixpath)
    cygpath -u -a -- "${entries[@]}"
    ;;
  esac
}

# Normalize a unix-style path list, removing duplicates and empty entries
# Inputs:
#   $1: The list to normalize
# Outputs:
#   stdout: The normalized path list
function pathlist_normalize() {
  local unix_paths=$1

  declare -A seen_paths
  local path_dir first=true
  while IFS= read -r -d ':' path_dir; do
    if [[ -z "$path_dir" ]]; then continue; fi
    if [[ -n "${seen_paths[$path_dir]:-}" ]]; then continue; fi
    seen_paths[$path_dir]=1

    if [[ "$first" == 'true' ]]; then first=false; else printf ':'; fi
    printf '%s' "$path_dir"
  done <<<"${unix_paths}:"
}

# Check whether the kernel is a WSL one, from its release (see https://github.com/microsoft/WSL/issues/423)
# Inputs:
#   $1: The kernel release file (default: /proc/sys/kernel/osrelease)
function is_wsl_kernel() {
  local release
  read -r release 2>/dev/null <"${1:-/proc/sys/kernel/osrelease}" || return 1
  release=${release,,}
  [[ "$release" == *-microsoft || "$release" == *-microsoft-* ]]
}

# Add entries to a WSLENV value, replacing the previous ones for the same variables
# Inputs:
#   $1: The WSLENV value
#   $2...: The entries to add (e.g. "INCLUDE/w")
# Outputs:
#   stdout: The new WSLENV value
function wslenv_merge() {
  local wslenv=$1 entry name merged=''
  shift

  declare -A replaced=()
  for entry in "$@"; do
    name=${entry%%/*}
    replaced[${name^^}]=1
  done
  while IFS= read -r -d ':' entry; do
    name=${entry%%/*}
    if [[ -n "$entry" && -z "${replaced[${name^^}]:-}" ]]; then merged+="${entry}:"; fi
  done <<<"${wslenv}:"

  for entry in "$@"; do merged+="${entry}:"; done
  printf '%s\n' "${merged%:}"
}

# Convert UTF-16 (little-endian) to UTF-8
# Inputs:
#   stdin: The UTF-16 input
# Outputs:
#   stdout: The UTF-8 output
function utf16_to_utf8() {
  iconv -f UTF-16LE -t UTF-8
}

# Check whether utf16_to_utf8 is supported (iconv is available)
# The result is cached on the first call.
function utf16_to_utf8_supported() {
  if [[ -z "${_utf16_to_utf8_supported:-}" ]]; then
    if type -P iconv >/dev/null; then
      declare -g _utf16_to_utf8_supported=true
    else
      declare -g _utf16_to_utf8_supported=false
    fi
  fi
  [[ "$_utf16_to_utf8_supported" == 'true' ]]
}

eval 'main "$@";exit "$?"'
