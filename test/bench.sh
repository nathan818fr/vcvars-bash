#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Benchmark vcvarsall.sh versions against each other.
# Must be run on Windows, with Visual Studio installed.

root=$(realpath -- "$(dirname -- "$0")/..")

function print_usage() {
  cat <<'EOF'
Usage: test/bench.sh [options] <version>...

Compare the run time of vcvarsall.sh versions. A version is the path to a
vcvarsall.sh file, or else a git ref of this repository (e.g. main, HEAD).

Options:
  -n RUNS     Measured runs per version (default: 5)
  -w RUNS     Warmup runs per version, not measured (default: 1)
  -a ARGS     vcvarsall.bat arguments, space-separated (default: x64)
  -p SECONDS  Idle pause before each run (default: 10 in real mode, 0 in
              replay mode), so that the background processes of the previous
              run (e.g. the VS telemetry) don't overlap with it
  -m MODE     real:   run vcvarsall.bat (default), i.e. what users get
              replay: replay a captured vcvarsall.bat output with a fake
                      cmd.exe, to measure the script overhead only, without
                      the noise of vcvarsall.bat (about +-1 s per run)
  -h          Show this help

Each run is timed like eval "$(vcvarsall.sh ARGS)". Versions run in turn, in
reverse order every other round (A B, B A, ...), after the warmup runs. Before
that, each version runs once, with a warning if it doesn't export the same
variables as the first one.

Progress goes to stderr. The results go to stdout, one tab-separated line per
version: version, median_ms, min_ms, max_ms, samples_ms (comma-separated).
Compare the medians: differences smaller than the min-max spread are noise.

Example: test/bench.sh main HEAD
EOF
}

function main() {
  local runs=5 warmup=1 args=x64 pause='' mode=real
  local opt OPTIND=1
  while getopts ':n:w:a:p:m:h' opt; do
    case "$opt" in
    n) runs=$OPTARG ;;
    w) warmup=$OPTARG ;;
    a) args=$OPTARG ;;
    p) pause=$OPTARG ;;
    m) mode=$OPTARG ;;
    h)
      print_usage
      return 0
      ;;
    *)
      print_usage >&2
      return 2
      ;;
    esac
  done
  shift $((OPTIND - 1))

  if [[ $# -eq 0 || ! "$runs" =~ ^[1-9][0-9]*$ || ! "$warmup" =~ ^[0-9]+$ || ! "$pause" =~ ^[0-9]*$ ||
    ("$mode" != real && "$mode" != replay) ]]; then
    print_usage >&2
    return 2
  fi
  if [[ -z "$pause" ]]; then
    if [[ "$mode" == 'real' ]]; then pause=10; else pause=0; fi
  fi
  read -ra vc_args <<<"$args"

  work=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: work is set once
  trap "rm -rf -- $(printf '%q' "$work")" EXIT

  prepare_versions "$@"
  if [[ "$mode" == 'replay' ]]; then setup_replay; fi
  check_outputs
  measure "$runs" "$warmup" "$pause"
  report
}

# Copy each version into the work directory
# Inputs:
#   $@: The versions (vcvarsall.sh paths or git refs)
#   work: The work directory
# Outputs:
#   labels, scripts: The version labels and vcvarsall.sh copies
function prepare_versions() {
  declare -ga labels=() scripts=()
  local version script
  for version in "$@"; do
    script="${work}/${#scripts[@]}.sh"
    if [[ -f "$version" ]]; then
      cp -- "$version" "$script"
    elif ! git -C "$root" show "${version}:vcvarsall.sh" >"$script" 2>"${work}/git.err"; then
      printf 'error: not a file nor a git ref: %s\n' "$version" >&2
      sed 's/^/  /' -- "${work}/git.err" >&2
      return 2
    fi
    labels+=("$version")
    scripts+=("$script")
  done
}

# Capture the vcvarsall.bat output once, then put a fake cmd.exe replaying it first in PATH
# Inputs:
#   scripts: The vcvarsall.sh copies (the first one is used for the capture)
#   vc_args: The vcvarsall.bat arguments
function setup_replay() {
  local real_cmd capture="${work}/capture.txt" fake="${work}/fake"
  if ! real_cmd=$(type -P cmd.exe); then
    printf 'error: cmd.exe not found\n' >&2
    return 1
  fi
  mkdir -- "$fake"

  # Capture with a cmd.exe wrapper copying the output of the real one
  printf '#!/usr/bin/env bash\n%q "$@" | tee -- %q\n' "$real_cmd" "$capture" >"${fake}/cmd.exe"
  chmod +x -- "${fake}/cmd.exe"
  printf 'Capturing the vcvarsall.bat output...\n' >&2
  PATH="${fake}:${PATH}" bash -- "${scripts[0]}" "${vc_args[@]}" >/dev/null 2>&1 || true
  if [[ ! -s "$capture" ]]; then
    printf 'error: failed to capture the vcvarsall.bat output\n' >&2
    return 1
  fi

  printf '#!/usr/bin/env bash\nexec cat -- %q\n' "$capture" >"${fake}/cmd.exe"
  export PATH="${fake}:${PATH}"
}

# Run each version once, and warn if it doesn't export the same variables as the first one
# Inputs:
#   labels, scripts: The versions
#   vc_args: The vcvarsall.bat arguments
function check_outputs() {
  local i output first_output
  for i in "${!scripts[@]}"; do
    if ! output=$(bash -- "${scripts[i]}" "${vc_args[@]}" 2>"${work}/stderr.txt"); then
      printf 'error: %s failed:\n' "${labels[i]}" >&2
      cat -- "${work}/stderr.txt" >&2
      return 1
    fi
    if [[ "$i" -eq 0 ]]; then
      first_output=$output
    elif [[ "$output" != "$first_output" ]]; then
      printf 'warning: %s does not export the same variables as %s\n' "${labels[i]}" "${labels[0]}" >&2
    fi
  done
}

# Time the versions like "eval $(vcvarsall.sh ARGS)", interleaved, after the warmup rounds.
# The order is reversed every other round (A B, B A, ...), so that no version always runs in the same position.
# Inputs:
#   $1: The number of measured runs
#   $2: The number of warmup runs
#   $3: The pause before each run, in seconds
#   labels, scripts: The versions
#   vc_args: The vcvarsall.bat arguments
# Outputs:
#   samples: The measured durations of each version, in milliseconds (space-separated, in run order)
function measure() {
  local runs=$1 warmup=$2 pause=$3
  declare -ga samples=()
  # shellcheck disable=SC2034 # captured on purpose, like eval "$(vcvarsall.sh)" does
  local round i tmp t0 t1 ms output order=("${!scripts[@]}")
  for ((round = 1 - warmup; round <= runs; round++)); do
    for i in "${order[@]}"; do
      if ((pause > 0)); then sleep "$pause"; fi
      t0=$EPOCHREALTIME
      if ! output=$(bash -- "${scripts[i]}" "${vc_args[@]}" 2>/dev/null); then
        printf 'error: %s failed\n' "${labels[i]}" >&2
        return 1
      fi
      t1=$EPOCHREALTIME
      ms=$(((${t1//[.,]/} - ${t0//[.,]/}) / 1000))
      if ((round > 0)); then
        samples[i]+="${ms} "
        printf '[run %d/%d] %s: %d ms\n' "$round" "$runs" "${labels[i]}" "$ms" >&2
      else
        printf '[warmup] %s: %d ms\n' "${labels[i]}" "$ms" >&2
      fi
    done
    for ((i = 0; i < ${#order[@]} / 2; i++)); do # reverse the order
      tmp=${order[i]}
      order[i]=${order[-i - 1]}
      order[-i - 1]=$tmp
    done
  done
}

# Print the results: one tab-separated line per version
# Inputs:
#   labels, samples: The versions and their measured durations
function report() {
  local i
  printf 'version\tmedian_ms\tmin_ms\tmax_ms\tsamples_ms\n'
  local list
  for i in "${!labels[@]}"; do
    list=${samples[i]% }
    printf '%s\t%s\t%s\n' "${labels[i]}" "$(tr ' ' '\n' <<<"$list" | sort -n | awk '
      { v[NR] = $1 }
      END { printf "%d\t%d\t%d", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2, v[1], v[NR] }')" "${list// /,}"
  done
}

eval 'main "$@";exit "$?"'
