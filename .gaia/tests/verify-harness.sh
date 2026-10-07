#!/usr/bin/env bash
# File-wide: the verify_* globals come from the sourced private library, the
# probe flags set here are read there, and the single-quoted jq program and
# reproduce text are jq or shell text printed for a person, not expansions.
# shellcheck disable=SC2154,SC2016,SC2034
# verify-harness.sh: run the checks that turn a maintainer pull request red on
# CI before the push or the audit dispatch, not after.
#
# Usage:
#   bash .gaia/tests/verify-harness.sh branch          # full verification; writes the pass record on success
#   bash .gaia/tests/verify-harness.sh round           # one audit round's delta; no pass record
#   bash .gaia/tests/verify-harness.sh push <sha>...   # the pre-push hook's entry: distribution checks only
#
# Checks, in order, each run with the tree under check as its working
# directory: shell-lint (branch, round), the release-scrub leak check (a bare
# build-staging into an empty directory), 01-files-present, 03-marker-strip,
# then the bats suites carrying the whole-tree mark and the suites the change
# selector picks (branch, round). Branch mode selects over <merge-base> HEAD
# and always runs the marked suites; round mode selects over the round's delta
# (the uncommitted tracked changes when there are any, else the HEAD commit)
# and adds the marked suites only when that delta touches a harness path.
#
# A failing check is re-run on the merge base with refs/remotes/origin/main, in
# a temporary worktree. A failure that reproduces there prints PRE-EXISTING
# ("main is red") and does not fail the run. The ref is never fetched; a
# missing one is a WARN naming `git fetch origin main`, and then every failure
# counts as new.
#
# A failing bats test is first re-run alone at HEAD, in the same tree, filtered
# to the failing names the way the base re-run is. A wall-clock budget suite
# can fail under the step's parallel load and pass alone, while the base
# re-run always runs alone, so without this a load flake would read as new.
# A test the isolated report shows passing prints
#   FLAKY  <label>: <suite path>: <test name> failed under parallel load and passed when re-run alone
# goes into the pass record's `flaky` array, and does not fail the run. A step
# whose only failures were flaky prints its PASS line followed by its FLAKY
# lines. A test that fails again alone, or whose isolated re-run produced no
# report or did not run it, goes on to the merge-base comparison unchanged:
# a missing signal never downgrades a failure.
#
# A missing tool skips only the steps that need it, with a WARN naming the
# install command; a skipped step never prints PASS.
#
# Exit: 0 no failure absent on the merge base; 1 at least one; 2 usage error;
# 3 branch mode refused to start (a detached HEAD or uncommitted tracked
# changes), nothing run. No flag and no environment variable skips a check.
#
# Branch mode removes the branch's pass record before it runs and writes a new
# one only on exit 0 with jq installed:
#   <main-root>/.gaia/local/protected/verify-pass/<branch-key>.json
# The audit-loop dispatch gate reads it through the read-only
# .gaia/tests/helpers/verify-pass-record.sh. The writer lives inline below and
# nowhere else, so no sourceable function can stamp a record.
#
# Bash 3.2 compatible; BSD and GNU tools. Maintainer-only: .gaia/tests is
# release-excluded wholesale.

set -uo pipefail

# A git hook exports these, and each one would redirect every git call below
# away from the checkout the runner was started in.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

SECONDS=0

verify_usage() {
  printf 'usage: bash .gaia/tests/verify-harness.sh branch | round | push <sha>...\n' >&2
  exit 2
}

mode="${1:-}"
pushed_shas=()
case "$mode" in
  branch | round)
    [ "$#" -eq 1 ] || verify_usage
    ;;
  push)
    shift
    [ "$#" -ge 1 ] || verify_usage
    for pushed_sha in "$@"; do
      [[ "$pushed_sha" =~ ^[0-9a-f]{40}$ || "$pushed_sha" =~ ^[0-9a-f]{64}$ ]] || verify_usage
      case " ${pushed_shas[*]-} " in
        *" $pushed_sha "*) ;;
        *) pushed_shas+=("$pushed_sha") ;;
      esac
    done
    ;;
  *)
    verify_usage
    ;;
esac

runner_directory="$(cd "$(dirname "$0")" && pwd -P)" || {
  printf 'verify-harness: cannot resolve the runner directory\n' >&2
  exit 2
}
for library_path in "$runner_directory/../scripts/audit-loop-state-lib.sh" \
  "$runner_directory/helpers/verify-pass-record.sh" \
  "$runner_directory/helpers/verify-harness-lib.sh" \
  "$runner_directory/helpers/verify-harness-bats-lib.sh"; do
  if [ ! -f "$library_path" ]; then
    printf 'verify-harness: missing library %s\n' "$library_path" >&2
    exit 2
  fi
  # shellcheck source=/dev/null
  . "$library_path"
done

verified_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'verify-harness: not inside a git checkout\n' >&2
  exit 2
}
for pushed_sha in ${pushed_shas[@]+"${pushed_shas[@]}"}; do
  verify_git cat-file -e "$pushed_sha^{commit}" 2>/dev/null || {
    printf 'verify-harness: %s is not a commit in this repository\n' "$pushed_sha" >&2
    exit 2
  }
done

if [ "$mode" = branch ]; then
  if ! verify_git symbolic-ref -q HEAD >/dev/null 2>&1; then
    printf 'REFUSED  branch mode verifies a branch, and HEAD is detached: check out the branch first\n'
    exit 3
  fi
  if ! verify_git diff --quiet HEAD -- 2>/dev/null; then
    printf 'REFUSED  uncommitted tracked changes (see git status): commit first, branch mode verifies the committed HEAD\n'
    exit 3
  fi
fi

run_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/verify-harness.XXXXXX")" || {
  printf 'verify-harness: cannot create a temporary directory\n' >&2
  exit 2
}
worktree_list_file="$run_temporary_directory/worktrees"
symlink_list_file="$run_temporary_directory/symlinks"
base_worktree_map_file="$run_temporary_directory/base-worktrees"
skipped_list_file="$run_temporary_directory/skipped"
preexisting_list_file="$run_temporary_directory/preexisting"
flaky_list_file="$run_temporary_directory/flaky"
: >"$worktree_list_file"
: >"$symlink_list_file"
: >"$base_worktree_map_file"
: >"$skipped_list_file"
: >"$preexisting_list_file"
: >"$flaky_list_file"
new_failure_count=0

# Invoked through the EXIT trap.
# shellcheck disable=SC2329
verify_cleanup() {
  local cleanup_path
  while IFS= read -r cleanup_path; do
    rm -f "$cleanup_path"
  done <"$symlink_list_file"
  while IFS= read -r cleanup_path; do
    git -C "$verified_root" worktree remove --force "$cleanup_path" >/dev/null 2>&1 || rm -rf "$cleanup_path"
  done <"$worktree_list_file"
  [ -s "$worktree_list_file" ] && git -C "$verified_root" worktree prune >/dev/null 2>&1
  rm -rf "$run_temporary_directory"
}
trap verify_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

head_sha="$(verify_git rev-parse HEAD 2>/dev/null)"
tracked_tree_clean=0
verify_git diff --quiet HEAD -- 2>/dev/null && tracked_tree_clean=1

record_path=""
branch_key=""
if [ "$mode" = branch ]; then
  untracked_harness_paths=""
  untracked_harness_count=0
  while IFS= read -r -d '' untracked_path; do
    if verify_is_harness_path "$untracked_path"; then
      untracked_harness_count=$((untracked_harness_count + 1))
      [ "$untracked_harness_count" -le 5 ] && untracked_harness_paths="$untracked_harness_paths $untracked_path"
    fi
  done < <(verify_git -c core.quotepath=false ls-files --others --exclude-standard -z 2>/dev/null)
  if [ "$untracked_harness_count" -gt 0 ]; then
    printf 'WARN  %s untracked file(s) under harness paths are not covered by this run:%s\n' \
      "$untracked_harness_count" "$untracked_harness_paths"
  fi
  if branch_key="$(gaia_loop_key "$verified_root")" \
    && main_root="$(gaia_resolve_main_root "$verified_root" 2>/dev/null)"; then
    record_path="$(gaia_verify_pass_record_path "$main_root" "$branch_key")"
    rm -f "$record_path"
  else
    printf 'WARN  cannot resolve the branch key or the main checkout: no pass record can be written\n'
  fi
fi

# Tool probes, before any check runs.
shellcheck_missing=0
jq_missing=0
rsync_missing=0
bats_missing=0
if [ "$mode" != push ] && tool_missing shellcheck; then
  shellcheck_missing=1
  warn_missing_tool shellcheck 'brew install shellcheck' 'shell-lint'
fi
if tool_missing jq; then
  jq_missing=1
  if [ "$mode" = branch ]; then
    warn_missing_tool jq 'brew install jq' '01-files-present, and no pass record can be written'
  else
    warn_missing_tool jq 'brew install jq' '01-files-present'
  fi
fi
if tool_missing rsync; then
  rsync_missing=1
  warn_missing_tool rsync 'brew install rsync' 'release-scrub leak check, 01-files-present, 03-marker-strip'
fi
if [ "$mode" != push ] && tool_missing bats; then
  bats_missing=1
  warn_missing_tool bats 'brew install bats-core' 'bats whole-tree, bats selected'
fi

if [ "$mode" = push ]; then
  pushed_count="${#pushed_shas[@]}"
  for pushed_sha in ${pushed_shas[@]+"${pushed_shas[@]}"}; do
    short_sha="$(verify_short_sha "$pushed_sha")"
    label_suffix=""
    base_prefix=""
    if [ "$pushed_count" -gt 1 ]; then
      label_suffix=" @$short_sha"
      base_prefix="$short_sha: "
    fi
    merge_base=""
    verify_report_merge_base "$pushed_sha" "$base_prefix" && merge_base="$(verify_merge_base "$pushed_sha")"
    if [ "$pushed_sha" = "$head_sha" ] && [ "$tracked_tree_clean" -eq 1 ]; then
      check_tree="$verified_root"
      reproduce_prefix=""
    else
      check_tree="$run_temporary_directory/push-$short_sha"
      reproduce_prefix="git checkout --detach $pushed_sha && "
      if ! verify_add_worktree "$check_tree" "$pushed_sha"; then
        printf 'FAIL  distribution checks%s (0s)\n' "$label_suffix"
        printf '  cannot check out %s into a temporary worktree:\n' "$pushed_sha"
        verify_print_raw_detail "$check_tree.log"
        printf '  reproduce: git worktree add --detach "$(mktemp -d)" %s\n' "$pushed_sha"
        new_failure_count=$((new_failure_count + 1))
        continue
      fi
    fi
    binary_missing=0
    verify_maintainer_binary_missing "$check_tree" && binary_missing=1
    verify_run_distribution "$check_tree" "$merge_base" "$label_suffix" "$reproduce_prefix" "$binary_missing"
  done
else
  merge_base=""
  verify_report_merge_base HEAD "" && merge_base="$(verify_merge_base HEAD)"
  binary_missing=0
  verify_maintainer_binary_missing "$verified_root" && binary_missing=1

  if [ "$shellcheck_missing" -eq 1 ]; then
    verify_skip shell-lint "shellcheck not found"
  else
    verify_run_check shell-lint "$verified_root" "$merge_base" "" ""
  fi
  verify_run_distribution "$verified_root" "$merge_base" "" "" "$binary_missing"

  # Bats selection.
  marked_suites="$run_temporary_directory/marked-suites"
  selected_suites="$run_temporary_directory/selected-suites"
  selector_error="$run_temporary_directory/selector-error"
  : >"$marked_suites"
  : >"$selected_suites"
  run_whole_tree=1
  whole_tree_skip_reason=""
  selected_skip_reason=""
  selector_status=0
  selector_arguments=()
  if [ "$mode" = branch ]; then
    if [ -n "$merge_base" ]; then
      selector_arguments=("$merge_base" HEAD)
    else
      selected_skip_reason="no merge base with refs/remotes/origin/main (run git fetch origin main)"
    fi
  else
    if [ -n "$(verify_git diff --name-only HEAD -- 2>/dev/null)" ]; then
      selector_arguments=(HEAD)
      delta_description="uncommitted tracked changes against HEAD"
    elif verify_git rev-parse -q --verify 'HEAD~1^{commit}' >/dev/null 2>&1; then
      selector_arguments=(HEAD~1 HEAD)
      delta_description="the HEAD commit"
    else
      selector_arguments=("$verify_empty_tree_object" HEAD)
      delta_description="the root commit"
    fi
    harness_path_touched=0
    delta_path_count=0
    while IFS= read -r -d '' delta_path; do
      delta_path_count=$((delta_path_count + 1))
      verify_is_harness_path "$delta_path" && harness_path_touched=1
    done < <(verify_git -c core.quotepath=false diff --name-only --no-renames -z ${selector_arguments[@]+"${selector_arguments[@]}"} -- 2>/dev/null)
    if [ "$harness_path_touched" -eq 1 ]; then
      printf 'DELTA  %s: %s path(s), harness paths touched\n' "$delta_description" "$delta_path_count"
    else
      printf 'DELTA  %s: %s path(s), no harness path touched\n' "$delta_description" "$delta_path_count"
      run_whole_tree=0
      whole_tree_skip_reason="the round's delta touches no harness path"
    fi
  fi

  if [ "$bats_missing" -eq 1 ]; then
    verify_skip "bats whole-tree" "bats not found"
    verify_skip "bats selected" "bats not found"
  else
    marked_discovery_failed=0
    if [ "$run_whole_tree" -eq 1 ]; then
      verify_marked_suites "$verified_root" >"$marked_suites" 2>"$selector_error" || marked_discovery_failed=1
    fi
    if [ "${#selector_arguments[@]}" -gt 0 ]; then
      bash "$verified_root/.gaia/scripts/bats-suites-for-change.sh" --dir "$verified_root" \
        ${selector_arguments[@]+"${selector_arguments[@]}"} >"$selected_suites" 2>>"$selector_error"
      selector_status=$?
    fi
    if [ "$run_whole_tree" -eq 1 ] && [ "$selector_status" -eq 0 ]; then
      # A suite in both sets runs once, under bats whole-tree.
      LC_ALL=C sort -u "$marked_suites" -o "$marked_suites"
      LC_ALL=C sort -u "$selected_suites" | LC_ALL=C comm -23 - "$marked_suites" >"$selected_suites.only"
      mv "$selected_suites.only" "$selected_suites"
    fi

    if [ "$marked_discovery_failed" -eq 1 ]; then
      printf 'FAIL  bats whole-tree (0s)\n'
      printf '  the whole-tree mark discovery failed:\n'
      verify_print_raw_detail "$selector_error"
      printf "  reproduce: git grep -l -E '%s' -- '*.bats'\n" "$verify_whole_tree_mark_pattern"
      new_failure_count=$((new_failure_count + 1))
    elif [ "$run_whole_tree" -eq 0 ]; then
      verify_skip "bats whole-tree" "$whole_tree_skip_reason"
    elif [ ! -s "$marked_suites" ]; then
      verify_skip "bats whole-tree" "no tracked suite carries the whole-tree mark"
    else
      verify_run_bats_step "bats whole-tree" "$verified_root" "$marked_suites" "$merge_base"
    fi

    if [ -n "$selected_skip_reason" ]; then
      verify_skip "bats selected" "$selected_skip_reason"
    elif [ "$selector_status" -ne 0 ]; then
      printf 'FAIL  bats selected (0s)\n'
      printf '  the change selector exited %s; this is not an empty selection:\n' "$selector_status"
      verify_print_raw_detail "$selector_error"
      printf '  reproduce: bash .gaia/scripts/bats-suites-for-change.sh --dir .'
      printf ' %s' ${selector_arguments[@]+"${selector_arguments[@]}"}
      printf '\n'
      new_failure_count=$((new_failure_count + 1))
    elif [ ! -s "$selected_suites" ]; then
      if [ "$mode" = round ]; then
        verify_skip "bats selected" "no suite outside the whole-tree set references the round's delta"
      else
        verify_skip "bats selected" "no suite outside the whole-tree set references the change"
      fi
    else
      verify_run_bats_step "bats selected" "$verified_root" "$selected_suites" "$merge_base"
    fi
  fi
fi

printf 'TOTAL %ss\n' "$SECONDS"
if [ "$new_failure_count" -gt 0 ]; then
  printf 'VERDICT  fail: %s check(s) with a failure absent on the merge base\n' "$new_failure_count"
  exit_status=1
else
  printf 'VERDICT  verified: no failure absent on the merge base\n'
  exit_status=0
fi

if [ "$mode" = branch ]; then
  if [ "$exit_status" -ne 0 ]; then
    printf 'No pass record written: the run has a failure absent on the merge base.\n'
  elif [ "$jq_missing" -eq 1 ]; then
    printf 'WARN  no pass record written: jq not found; the audit dispatch gate will deny until jq is installed (brew install jq) and branch mode is re-run\n'
  elif [ -z "$record_path" ]; then
    printf 'WARN  no pass record written: the branch key or the main checkout could not be resolved\n'
  else
    # The private writer: atomic (temporary file in the same directory, then
    # mv). It is inline rather than a function so nothing can source it.
    record_directory="${record_path%/*}"
    record_temporary=""
    if mkdir -p "$record_directory" \
      && record_temporary="$(mktemp "$record_directory/.verify-pass.XXXXXX")" \
      && jq -n \
        --arg branch "$branch_key" \
        --arg head "$head_sha" \
        --arg written_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --rawfile skipped "$skipped_list_file" \
        --rawfile preexisting "$preexisting_list_file" \
        --rawfile flaky "$flaky_list_file" \
        '{schema: 1, branch: $branch, head: $head, written_at: $written_at,
          skipped: ($skipped | split("\n") | map(select(length > 0))),
          preexisting: ($preexisting | split("\n") | map(select(length > 0))),
          flaky: ($flaky | split("\n") | map(select(length > 0)))}' >"$record_temporary" \
      && mv -f "$record_temporary" "$record_path"; then
      printf 'Pass record written: %s\n' "$record_path"
    else
      [ -n "$record_temporary" ] && rm -f "$record_temporary"
      printf 'WARN  no pass record written: writing %s failed; the audit dispatch gate will deny until branch mode is re-run\n' "$record_path"
    fi
  fi
fi

exit "$exit_status"
