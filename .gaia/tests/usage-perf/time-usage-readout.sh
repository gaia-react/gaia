#!/usr/bin/env bash
# time-usage-readout.sh: same-run timing of the usage readout, pre-change tree
# against the working tree, over a store directory gen-usage-stores.sh wrote.
#
# usage: time-usage-readout.sh --baseline-rev <rev> --stores <dir> [--probe <pr>]
#          [--runs 5] [--mode warm-day|cold] [--bash <interp>]
#          [--sub "pr <N>" | "initiative <ref>" | reconcile] [--repo <dir>]
#          [--out-dir <dir>]
#
# --baseline-rev   REQUIRED. The pre-change scripts come from `git archive <rev>`
#                  of .gaia/scripts, never from a merge base: a merge base
#                  drifts when main moves. A baseline from before the spec
#                  scripts moved into .gaia/scripts/spec also has them under the
#                  old extension lib directory, which is archived beside it.
# --stores         a directory holding usage.jsonl, links.jsonl, cost.jsonl and
#                  probes.json (the generator's output).
# --probe          the PR to read; shorthand for --sub "pr <N>".
# --sub            the readout to time (default: pr <probe>).
# --mode           warm-day (default): the memo is built over the stores cut at
#                  the final day, saved, and restored before each changed run, so
#                  every changed run reads one day of new bytes. cold: the memo
#                  is deleted before each changed run. Pre-change runs never see
#                  a memo.
# --runs           runs per tree (default 5), interleaved pre-change then
#                  changed so machine drift lands on both trees alike; the
#                  result is the median of each.
# --bash           interpreter that runs each readout (default: this bash), so
#                  /bin/bash 3.2 readouts can be timed from a bash 5 harness.
# --repo           repository whose working tree is the changed tree (default:
#                  the one this script sits in).
# --out-dir        where the outputs are kept (default: a fresh temp directory,
#                  left in place so the printed paths stay readable).
#
# Prints, then the output paths:
#   pre_median=<s> new_median=<s> ratio=<r> identical=<yes|no|degenerate>
# identical compares stdout, and stderr_identical compares stderr, of the last
# pre-change run against every changed run. An output without its figures line
# prints identical=degenerate and exits 1. A harness that cannot make a readout
# print figures would otherwise compare two empty outputs as equal.
#
# Exit: 0 timed, 1 degenerate or a run failed, 2 usage error or bash below 5.
# CI never reads the timings; the maintainer records them by hand.
#
# Maintainer tooling, release-excluded with the rest of .gaia/tests.

# EPOCHREALTIME arrived in bash 5.0. On bash 4 it is an empty variable, so
# every timing would read zero without any error.
if [ "${BASH_VERSINFO[0]:-0}" -ge 5 ]; then :; else
  printf 'time-usage-readout: bash 5 or later is required (EPOCHREALTIME); this is bash %s\n' "${BASH_VERSION:-unknown}" >&2
  exit 2
fi

set -uo pipefail
# A comma radix would break the microsecond arithmetic below.
export LC_ALL=C

usage() {
  sed -n '2,/^# Maintainer tooling/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

die() {
  printf 'time-usage-readout: %s\n' "$*" >&2
  exit 2
}

here="$(cd "${BASH_SOURCE[0]%/*}" && pwd -P)" || exit 2
repo="$(cd "$here/../../.." && pwd -P)" || exit 2

baseline="" stores="" probe="" runs=5 mode=warm-day interpreter="$BASH" subcommand="" output_directory=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --baseline-rev | --stores | --probe | --runs | --mode | --bash | --sub | --repo | --out-dir)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --baseline-rev) baseline="$2" ;; --stores) stores="$2" ;; --probe) probe="$2" ;;
        --runs) runs="$2" ;; --mode) mode="$2" ;; --bash) interpreter="$2" ;; --sub) subcommand="$2" ;;
        --repo) repo="$2" ;; --out-dir) output_directory="$2" ;;
      esac
      shift 2 ;;
    *) usage >&2; die "unknown argument $1" ;;
  esac
done

[ -n "$baseline" ] || die "--baseline-rev is required: name the revision the readout is timed against"
[ -n "$stores" ] || die "--stores is required"
[[ "$runs" =~ ^[1-9][0-9]{0,2}$ ]] || die "--runs takes a whole number from 1 to 999"
case "$mode" in warm-day | cold) ;; *) die "--mode takes warm-day or cold" ;; esac
if [ -z "$subcommand" ]; then
  [ -n "$probe" ] || die "--probe (or --sub) is required"
  [[ "$probe" =~ ^[1-9][0-9]{0,9}$ ]] || die "--probe takes a PR number"
  subcommand="pr $probe"
fi
read -r -a subcommand_args <<<"$subcommand"
case "${subcommand_args[0]:-}" in
  pr) figures='^  tokens: ' ;;
  initiative) figures='^  total \(distinct segments\): tokens ' ;;
  reconcile) figures='^  all segments: +tokens ' ;;
  *) die "--sub takes \"pr <N>\", \"initiative <ref>\", or reconcile" ;;
esac
for store_file in usage.jsonl links.jsonl cost.jsonl; do
  [ -f "$stores/$store_file" ] || die "--stores has no $store_file"
done
[ -d "$repo" ] || die "--repo is not a directory"
command -v jq >/dev/null 2>&1 || die "jq is required"
git -C "$repo" rev-parse --verify --quiet "$baseline^{commit}" >/dev/null || die "--baseline-rev $baseline names no commit in $repo"
[ -x "$interpreter" ] || command -v "$interpreter" >/dev/null 2>&1 || die "--bash $interpreter is not runnable"

cut_usage="" cut_links="" cut_cost=""
if [ "$mode" = warm-day ]; then
  [ -f "$stores/probes.json" ] || die "warm-day mode reads the cut offsets from $stores/probes.json"
  read -r cut_usage cut_links cut_cost < <(jq -r '[.cut.u, .cut.l, .cut.c] | map(tostring) | join(" ")' "$stores/probes.json") ||
    die "probes.json has no cut offsets"
  [[ "$cut_usage$cut_links$cut_cost" =~ ^[0-9]+$ ]] || die "probes.json has no cut offsets"
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/usage-perf.XXXXXX")" || die "no scratch directory"
trap 'rm -rf "$scratch"' EXIT
if [ -z "$output_directory" ]; then output_directory="$(mktemp -d "${TMPDIR:-/tmp}/usage-perf-out.XXXXXX")" || die "no output directory"; fi
mkdir -p "$output_directory" || die "cannot create --out-dir"

old="$scratch/old" new="$scratch/new" main="$scratch/main"
telemetry_directory_old="$scratch/tel-old" telemetry_directory_new="$scratch/tel-new" projects="$scratch/projects"
mkdir -p "$old" "$new" "$main/.claude" "$telemetry_directory_old" "$telemetry_directory_new" "$projects"
baseline_archive_paths=(.gaia/scripts)
if git -C "$repo" cat-file -e "$baseline:.specify/extensions/gaia/lib" 2>/dev/null; then
  baseline_archive_paths+=(.specify/extensions/gaia/lib)
fi
git -C "$repo" archive "$baseline" ${baseline_archive_paths[@]+"${baseline_archive_paths[@]}"} | tar -x -C "$old" || die "git archive of $baseline failed"
mkdir -p "$new/.gaia"
cp -R "$repo/.gaia/scripts" "$new/.gaia/scripts"
rates="$repo/.gaia/scripts/token-rates.json"
[ -f "$rates" ] || die "no rate table at $rates"

git -C "$main" init -q || die "git init failed"
cat >"$main/.claude/settings.json" <<'EOF'
{"hooks": {
  "Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}],
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/usage-capture.sh"}]}]
}}
EOF

export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$scratch/rates-state"
unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_MEMO_TRACE GAIA_USAGE_MEMO_SEAM

memo="$telemetry_directory_new/usage-branch-memo.json"
saved_memo="$scratch/memo.saved"

# run_readout <tree> <telemetry dir> <out prefix>: sets ELAPSED_MICROSECONDS.
run_readout() {
  local tree="$1" telemetry_directory="$2" prefix="$3" start_microseconds end_microseconds exit_status=0
  start_microseconds="${EPOCHREALTIME/./}"
  "$interpreter" "$tree/.gaia/scripts/usage.sh" ${subcommand_args[@]+"${subcommand_args[@]}"} --main-root "$main" --telemetry-dir "$telemetry_directory" \
    --rate-table "$rates" --projects-root "$projects" >"$prefix.out" 2>"$prefix.err" || exit_status=$?
  end_microseconds="${EPOCHREALTIME/./}"
  ELAPSED_MICROSECONDS=$((end_microseconds - start_microseconds))
  return "$exit_status"
}

cp "$stores/usage.jsonl" "$stores/links.jsonl" "$stores/cost.jsonl" "$telemetry_directory_old/"

memo_state=deleted
if [ "$mode" = warm-day ]; then
  memo_state=absent
  head -c "$cut_usage" "$stores/usage.jsonl" >"$telemetry_directory_new/usage.jsonl"
  head -c "$cut_links" "$stores/links.jsonl" >"$telemetry_directory_new/links.jsonl"
  head -c "$cut_cost" "$stores/cost.jsonl" >"$telemetry_directory_new/cost.jsonl"
  run_readout "$new" "$telemetry_directory_new" "$scratch/warmup" || die "the warm-up readout failed"
  if [ -f "$memo" ]; then cp "$memo" "$saved_memo"; memo_state=present; fi
fi
cp "$stores/usage.jsonl" "$stores/links.jsonl" "$stores/cost.jsonl" "$telemetry_directory_new/"

pre_times=() new_times=()
i=1
while [ "$i" -le "$runs" ]; do
  run_readout "$old" "$telemetry_directory_old" "$output_directory/pre-$i" || die "pre-change run $i failed (see $output_directory/pre-$i.err)"
  pre_times[${#pre_times[@]}]="$ELAPSED_MICROSECONDS"
  rm -f "$memo"
  if [ "$mode" = warm-day ] && [ -f "$saved_memo" ]; then cp "$saved_memo" "$memo"; fi
  run_readout "$new" "$telemetry_directory_new" "$output_directory/new-$i" || die "changed run $i failed (see $output_directory/new-$i.err)"
  new_times[${#new_times[@]}]="$ELAPSED_MICROSECONDS"
  i=$((i + 1))
done

median_microseconds() {
  printf '%s\n' "$@" | sort -n | awk '{ sorted_values[NR] = $1 }
    END { if (NR % 2) print sorted_values[(NR + 1) / 2]; else printf "%d\n", (sorted_values[NR / 2] + sorted_values[NR / 2 + 1]) / 2 }'
}
pre_microseconds="$(median_microseconds ${pre_times[@]+"${pre_times[@]}"})"
new_microseconds="$(median_microseconds ${new_times[@]+"${new_times[@]}"})"
pre_seconds="$(awk -v microseconds="$pre_microseconds" 'BEGIN { printf "%.3f", microseconds / 1000000 }')"
new_seconds="$(awk -v microseconds="$new_microseconds" 'BEGIN { printf "%.3f", microseconds / 1000000 }')"
ratio="$(awk -v baseline_microseconds="$pre_microseconds" -v changed_microseconds="$new_microseconds" 'BEGIN { if (baseline_microseconds > 0) printf "%.3f", changed_microseconds / baseline_microseconds; else print "n/a" }')"

last_pre="$output_directory/pre-$runs"
identical=yes stderr_identical=yes degenerate=0
grep -Eq -- "$figures" "$last_pre.out" || degenerate=1
i=1
while [ "$i" -le "$runs" ]; do
  grep -Eq -- "$figures" "$output_directory/new-$i.out" || degenerate=1
  cmp -s "$last_pre.out" "$output_directory/new-$i.out" || identical=no
  cmp -s "$last_pre.err" "$output_directory/new-$i.err" || stderr_identical=no
  i=$((i + 1))
done
[ "$degenerate" = 1 ] && identical=degenerate

printf 'pre_median=%s new_median=%s ratio=%s identical=%s\n' "$pre_seconds" "$new_seconds" "$ratio" "$identical"
printf 'stderr_identical=%s\n' "$stderr_identical"
printf 'mode=%s memo=%s sub=%s runs=%s\n' "$mode" "$memo_state" "$subcommand" "$runs"
printf 'pre_output=%s\nnew_output=%s\n' "$last_pre.out" "$output_directory/new-$runs.out"
[ "$identical" != degenerate ] || exit 1
exit 0
