#!/usr/bin/env bash
# selection-replay.sh: replays the change-scoped bats selection over historical
# pull-request heads and reports whether each recorded failing test would still
# run on that change.
#
# Usage:
#   bash .gaia/tests/selection-replay.sh --input <cases.json> --output <results.json> [--repo <dir>]
#
# <cases.json> is an array of {run_id, pr, head, merge_base, leg, suite, test,
# successor_suite?, successor_test?}. A set `successor_suite` replaces the
# original suite as the target; with `successor_test` null it means the suite as
# a whole, so the test-existence check is skipped and only a file-level
# whole-tree mark, or a full listing, counts. `leg` is informational: the leg a
# suite runs on today is derived from the repo's own sharder.
#
# <repo> is the repository every command runs against (default: the one this
# script lives in). Each command names it explicitly, so a run against a scratch
# worktree exercises that tree's own sharder, classifier, selector and marks.
#
# Per case, in the order the sharder's plan applies them:
#   test-gone-today    the target suite file or test name is absent from <repo>
#   leg-armed          a self-contained leg's suite (concurrency, sandbox,
#                      commitlint) whose leg filter matches a changed path
#   harness-full       the leg's plan is a whole-shard run for a harness change
#   unreadable-full    the leg's plan is a whole-shard run for an unreadable change
#   selected-full      the selector picks the target suite
#   dependency-full    a dependency change and the suite carries the
#                      installed-dependencies mark
#   whole-tree-marked  the target test, or its suite, carries a whole-tree mark
#   miss               the target would not run
#
# The leg filters are read from the one dorny/paths-filter step of <repo>'s
# audit-ci-tests workflow with python3 and PyYAML, and matched with git's own
# glob pathspecs, so no glob translator exists here to drift from git.
#
# Output: a JSON array of {run_id, pr, head, suite, test, verdict} in input
# order. Selector, classifier and plan results are cached per key, so a large
# case set costs one call per distinct key. Progress goes to stderr.
#
# Exit codes:
#   0  no verdict is miss or test-gone-today
#   1  at least one miss or test-gone-today (each listed on stderr)
#   2  a usage or input error (malformed JSON, an absent commit, merge_base equal
#      to head, an unreadable workflow filter block, a command that failed)
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.
# File-wide: the mark patterns are assigned by the sourced library, and sed
# strips a repository prefix off every line of a listing, which a single
# parameter expansion does not.
# shellcheck disable=SC2154,SC2001
set -euo pipefail

TAB="$(printf '\t')"

die() {
  printf 'selection-replay: %s\n' "$*" >&2
  exit 2
}

usage() {
  printf 'Usage: bash .gaia/tests/selection-replay.sh --input <cases.json> --output <results.json> [--repo <dir>]\n' >&2
}

input_path=''
output_path=''
repo=''
while [ $# -gt 0 ]; do
  case "$1" in
    --input | --output | --repo)
      [ $# -ge 2 ] || {
        usage
        die "$1 needs a value"
      }
      case "$1" in
        --input) input_path="$2" ;;
        --output) output_path="$2" ;;
        --repo) repo="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done
[ -n "$input_path" ] || {
  usage
  die '--input is required'
}
[ -n "$output_path" ] || {
  usage
  die '--output is required'
}
if [ -z "$repo" ]; then
  repo="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
fi
[ -d "$repo" ] || die "repository not found: $repo"
# git's own toplevel, the physical path the sharder derives for itself, so the
# absolute paths it prints strip cleanly through a symlinked temporary directory.
repo="$(git -C "$repo" rev-parse --show-toplevel)" || die "not a git repository: $repo"

command -v jq >/dev/null 2>&1 || die 'jq is required'
command -v python3 >/dev/null 2>&1 || die 'python3 is required'
python3 -c 'import yaml' >/dev/null 2>&1 || die 'python3 needs PyYAML to read the workflow filter block'
[ -f "$input_path" ] || die "input not found: $input_path"

sharder="$repo/.gaia/tests/bats-shards.sh"
selector="$repo/.gaia/scripts/bats-suites-for-change.sh"
classifier="$repo/.gaia/tests/bats-change-scope.sh"
mark_library="$repo/.gaia/tests/helpers/verify-harness-bats-lib.sh"
workflow="$repo/.github/workflows/audit-ci-tests.yml"
for required in "$sharder" "$selector" "$classifier" "$mark_library" "$workflow"; do
  [ -f "$required" ] || die "missing in $repo: ${required#"$repo"/}"
done

# The mark patterns come from the repository under replay.
# shellcheck source=/dev/null
. "$mark_library"

work_directory="$(mktemp -d)"
trap 'rm -rf "$work_directory"' EXIT

jq -e 'type == "array"' "$input_path" >/dev/null 2>&1 || die "input is not a JSON array (malformed JSON?): $input_path"
case_count="$(jq 'length' "$input_path")"
[ "$case_count" -gt 0 ] || die 'input holds no cases'

# case_field <index> <field>: the field's value, empty for absent or null.
case_field() {
  jq -r --argjson index "$1" --arg field "$2" '.[$index][$field] // empty' "$input_path"
}

case_label() {
  printf 'case %s (run %s)' "$1" "$(case_field "$1" run_id)"
}

# Input checks run over every case before any replay work.
index=0
while [ "$index" -lt "$case_count" ]; do
  label="$(case_label "$index")"
  jq -e --argjson index "$index" '.[$index] | type == "object"' "$input_path" >/dev/null || die "$label: not an object"
  head_sha="$(case_field "$index" head)"
  merge_base="$(case_field "$index" merge_base)"
  suite="$(case_field "$index" suite)"
  [ -n "$head_sha" ] || die "$label: head is missing"
  [ -n "$merge_base" ] || die "$label: merge_base is missing"
  [ -n "$suite" ] || die "$label: suite is missing"
  if [ -z "$(case_field "$index" successor_suite)" ] && [ -z "$(case_field "$index" test)" ]; then
    die "$label: test is missing"
  fi
  git -C "$repo" cat-file -e "${head_sha}^{commit}" 2>/dev/null || die "$label: head commit $head_sha is absent from $repo"
  git -C "$repo" cat-file -e "${merge_base}^{commit}" 2>/dev/null || die "$label: merge_base commit $merge_base is absent from $repo"
  [ "$(git -C "$repo" rev-parse "${head_sha}^{commit}")" != "$(git -C "$repo" rev-parse "${merge_base}^{commit}")" ] \
    || die "$label: merge_base equals head, so the diff is empty"
  index=$((index + 1))
done

# The filter block, as JSON, read once. A missing step or parser is an input
# error, never a miss.
filters_json="$work_directory/filters.json"
python3 - "$workflow" >"$filters_json" <<'PY' || die "no readable filter block in ${workflow#"$repo"/}"
import json
import sys

import yaml

with open(sys.argv[1], encoding='utf-8') as handle:
    document = yaml.safe_load(handle)
jobs = document.get('jobs') if isinstance(document, dict) else None
if not isinstance(jobs, dict):
    sys.exit(1)
blocks = []
for job in jobs.values():
    steps = job.get('steps') if isinstance(job, dict) else None
    for step in steps or []:
        if isinstance(step, dict) and str(step.get('uses', '')).startswith('dorny/paths-filter'):
            blocks.append(step)
if len(blocks) != 1:
    sys.exit(1)
filters = (blocks[0].get('with') or {}).get('filters')
if not isinstance(filters, str):
    sys.exit(1)
parsed = yaml.safe_load(filters)
if not isinstance(parsed, dict) or not parsed:
    sys.exit(1)
json.dump(parsed, sys.stdout)
PY

# filter_globs <key>: that key's globs, one per line.
filter_globs() {
  jq -e -r --arg key "$1" '.[$key] | if type == "array" then .[] else error("not a list") end' "$filters_json" 2>/dev/null \
    || die "workflow filter block has no list under key '$1'"
}

# locate_test <suite-file> <test-name>: prints "<line> <marked>" for the first
# @test line holding the name, marked being 1 when the comment lines directly
# above it carry the whole-tree test mark; prints nothing when absent.
locate_test() {
  TEST_NAME="$2" MARK_PATTERN="$verify_whole_tree_test_mark_pattern" awk '
    /^[[:space:]]*#/ { if ($0 ~ ENVIRON["MARK_PATTERN"]) { pending = 1 } ; next }
    /^[[:space:]]*@test[[:space:]]/ {
      if (index($0, ENVIRON["TEST_NAME"]) > 0) { print NR, pending + 0; exit }
      pending = 0; next
    }
    { pending = 0 }
  ' "$1"
}

# cached <key> <command>...: runs the command once per key; a failure is fatal.
cached() {
  local key="$1" cache_file
  shift
  cache_file="$work_directory/cache-$(printf '%s' "$key" | cksum | tr -d ' ')"
  if [ ! -f "$cache_file" ]; then
    "$@" >"$cache_file" 2>"$cache_file.err" || {
      printf 'selection-replay: command failed (%s): %s\n' "$key" "$(cat "$cache_file.err")" >&2
      exit 2
    }
  fi
  cat "$cache_file"
}

# Each suite's leg today, "<leg><TAB><repo-relative path>" per line. A shard the
# sharder refuses to list in this repository contributes nothing.
leg_table="$work_directory/legs.tsv"
: >"$leg_table"
shard_ids="$(bash "$sharder" shards)" || die 'bats-shards.sh shards failed'
while IFS= read -r shard_id; do
  [ -n "$shard_id" ] || continue
  shard_listing="$(bash "$sharder" files "$shard_id" 2>/dev/null)" || continue
  while IFS= read -r listed; do
    [ -n "$listed" ] || continue
    printf '%s\t%s\n' "$shard_id" "${listed#"$repo"/}" >>"$leg_table"
  done <<EOF
$shard_listing
EOF
done <<EOF
$shard_ids
EOF

leg_of() {
  awk -F "$TAB" -v suite="$1" '$2 == suite { print $1; exit }' "$leg_table"
}

# armed_by <merge_base> <head> <key>...: success when a changed path matches any
# glob of the keys.
armed_by() {
  local merge_base="$1" head_sha="$2" key glob globs matched
  local -a pathspecs
  shift 2
  pathspecs=()
  for key in "$@"; do
    globs="$(filter_globs "$key")"
    while IFS= read -r glob; do
      if [ -n "$glob" ]; then pathspecs+=(":(glob)$glob"); fi
    done <<EOF
$globs
EOF
  done
  [ ${#pathspecs[@]} -gt 0 ] || return 1
  matched="$(git -C "$repo" diff --name-only -z --no-renames "$merge_base" "$head_sha" -- ${pathspecs[@]+"${pathspecs[@]}"} | tr '\0' '\n')"
  [ -n "$matched" ]
}

results_lines="$work_directory/results.ndjson"
: >"$results_lines"
problem_lines="$work_directory/problems.txt"
: >"$problem_lines"

index=0
while [ "$index" -lt "$case_count" ]; do
  printf 'selection-replay: case %s of %s\n' "$((index + 1))" "$case_count" >&2
  head_sha="$(case_field "$index" head)"
  merge_base="$(case_field "$index" merge_base)"
  successor_suite="$(case_field "$index" successor_suite)"
  whole_suite=0
  if [ -n "$successor_suite" ]; then
    target_suite="$successor_suite"
    target_test="$(case_field "$index" successor_test)"
    if [ -z "$target_test" ]; then whole_suite=1; fi
  else
    target_suite="$(case_field "$index" suite)"
    target_test="$(case_field "$index" test)"
  fi

  verdict=''
  test_marked=0
  target_file="$repo/$target_suite"
  if [ ! -f "$target_file" ]; then
    verdict=test-gone-today
  elif [ "$whole_suite" -eq 0 ]; then
    located="$(locate_test "$target_file" "$target_test")"
    if [ -z "$located" ]; then
      verdict=test-gone-today
    else
      test_marked="${located#* }"
    fi
  fi

  if [ -z "$verdict" ]; then
    case "$target_suite" in
      .gaia/tests/concurrency/*) leg_keys='code scoped' ;;
      .gaia/tests/sandbox/*) leg_keys='sandbox' ;;
      .gaia/tests/commitlint/*) leg_keys='commitlint' ;;
      *) leg_keys='' ;;
    esac
    if [ -n "$leg_keys" ]; then
      # shellcheck disable=SC2086 # leg_keys is a fixed word list
      if armed_by "$merge_base" "$head_sha" $leg_keys; then
        verdict='leg-armed'
      else
        verdict=miss
      fi
    fi
  fi

  if [ -z "$verdict" ]; then
    leg="$(leg_of "$target_suite")"
    if [ -z "$leg" ]; then
      verdict=miss
    else
      plan="$(cached "plan $leg $merge_base $head_sha" bash "$sharder" plan "$leg" "$merge_base" "$head_sha")"
      plan_mode="$(sed -n 's/^mode=//p' <<<"$plan")"
      plan_reason="$(sed -n 's/^reason=//p' <<<"$plan")"
      if [ "$plan_mode" = full ] && [ "$plan_reason" = harness-change ]; then
        verdict=harness-full
      elif [ "$plan_mode" = full ] && [ "$plan_reason" = change-unreadable ]; then
        verdict=unreadable-full
      fi
    fi
  fi

  if [ -z "$verdict" ]; then
    listing="$(cached "files $leg $merge_base $head_sha" bash "$sharder" files-for-change "$leg" "$merge_base" "$head_sha")"
    listing="$(sed "s#^$repo/##" <<<"$listing")"
    if ! grep -qxF -- "$target_suite" <<<"$listing"; then
      verdict=miss
    else
      selected="$(cached "selector $merge_base $head_sha" bash "$selector" --dir "$repo" "$merge_base" "$head_sha")"
      selected="$(sed "s#^$repo/##" <<<"$selected")"
      classified="$(cached "classifier $merge_base $head_sha" bash "$classifier" --dir "$repo" "$merge_base" "$head_sha")"
      if grep -qxF -- "$target_suite" <<<"$selected"; then
        verdict='selected-full'
      elif grep -q "^dependency$TAB" <<<"$classified" && grep -qE "$verify_installed_dependencies_mark_pattern" "$target_file"; then
        verdict=dependency-full
      elif [ "$test_marked" -eq 1 ] || grep -qE "$verify_whole_tree_file_mark_pattern" "$target_file"; then
        verdict=whole-tree-marked
      else
        verdict=miss
      fi
    fi
  fi

  case "$verdict" in
    miss | test-gone-today)
      printf '%s: %s: %s :: %s\n' "$verdict" "$(case_label "$index")" "$target_suite" "${target_test:-<whole suite>}" >>"$problem_lines"
      ;;
    unreadable-full)
      printf 'selection-replay: unreadable-full: %s: %s\n' "$(case_label "$index")" "$target_suite" >&2
      ;;
  esac

  jq -c --argjson index "$index" --arg verdict "$verdict" \
    '.[$index] | {run_id, pr, head, suite, test, verdict: $verdict}' "$input_path" >>"$results_lines"
  index=$((index + 1))
done

jq -s '.' "$results_lines" >"$output_path"

if [ -s "$problem_lines" ]; then
  while IFS= read -r problem; do
    printf 'selection-replay: %s\n' "$problem" >&2
  done <"$problem_lines"
  exit 1
fi
exit 0
