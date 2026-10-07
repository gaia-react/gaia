# shellcheck shell=bash
# File-wide: the runner's globals are assigned in the runner, the constants
# here are read there, and the single-quoted reproduce text is printed for a
# person, not expanded.
# shellcheck disable=SC2154,SC2034,SC2016
#
# Private to .gaia/tests/verify-harness.sh: sourced by that runner and by
# nothing else. Defines functions only. The two bats steps live beside it in
# verify-harness-bats-lib.sh, which calls verify_report_outcome from here.
#
# The functions read the runner's globals:
#   verified_root            the checkout the run verifies
#   run_temporary_directory  scratch space, removed by the runner's trap
#   worktree_list_file       every temporary worktree, removed by the trap
#   symlink_list_file        every node_modules symlink, removed before its
#                            worktree so a forced removal never walks into the
#                            verified checkout's dependencies
#   base_worktree_map_file   "<merge-base> <path>" for each base worktree
#   skipped_list_file        "<label>: <reason>" per SKIP, for the pass record
#   preexisting_list_file    "<label>" per PRE-EXISTING, for the pass record
#   flaky_list_file          "<suite path>: <test name>" per FLAKY, for the record
#   new_failure_count        checks with at least one failure absent on the base
#   jq_missing, rsync_missing  the runner's tool probes, read by the distribution step
#
# Pre-existing classification never downgrades on doubt: an item counts as
# reproduced only when the merge-base re-run positively shows it. A suite
# absent at the base, a base re-run that cannot start, and a bats suite that
# fails to load at HEAD but runs at the base all stay new failures.
#
# Maintainer-only: .gaia/tests is release-excluded wholesale.

# git's well-known empty tree, the base of a parentless HEAD's range.
verify_empty_tree_object=4b825dc642cb6eb9a060e54bf8d69288fbee4904
# Raw failure output past this many lines is cut, with a pointer to the
# reproduce command; a full shell-lint report can run to hundreds of lines.
verify_detail_line_limit=200

verify_git() {
  git -C "$verified_root" "$@"
}

# verify_is_harness_path <repo-relative path>
verify_is_harness_path() {
  case "$1" in
    .claude/* | .gaia/* | .github/* | .githooks/* | wiki/* | CLAUDE.md | */CLAUDE.md) return 0 ;;
  esac
  return 1
}

verify_short_sha() {
  git -C "$verified_root" rev-parse --short "$1" 2>/dev/null || printf '%s\n' "${1:0:7}"
}

verify_skip() {
  printf 'SKIP  %s: %s\n' "$1" "$2"
  printf '%s: %s\n' "$1" "$2" >>"$skipped_list_file"
}

verify_indent() {
  sed 's/^/  /' "$1"
}

# verify_print_raw_detail <output-file>: the check's own diagnostic, capped.
verify_print_raw_detail() {
  local output_file="$1" line_count
  line_count="$(wc -l <"$output_file" | tr -d ' ')"
  if [ "$line_count" -gt "$verify_detail_line_limit" ]; then
    head -n "$verify_detail_line_limit" "$output_file" | sed 's/^/  /'
    printf '  (%s more lines cut; run the reproduce command for the full output)\n' \
      "$((line_count - verify_detail_line_limit))"
  else
    sed 's/^/  /' "$output_file"
  fi
}

# verify_merge_base <commit>: print the merge base with origin/main, or fail.
verify_merge_base() {
  local remote_main
  remote_main="$(verify_git rev-parse -q --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null)" || return 1
  [ -n "$remote_main" ] || return 1
  verify_git merge-base "$remote_main" "$1" 2>/dev/null
}

# verify_report_merge_base <commit> <prefix>: the staleness line, or the WARN
# naming the fetch; fails when there is no merge base.
verify_report_merge_base() {
  local commit="$1" prefix="$2" merge_base commit_date behind_count
  if ! verify_git rev-parse -q --verify 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1; then
    printf 'WARN  %srefs/remotes/origin/main not found: run git fetch origin main; without a merge base no failure can be shown pre-existing\n' "$prefix"
    return 1
  fi
  if ! merge_base="$(verify_merge_base "$commit")" || [ -z "$merge_base" ]; then
    printf 'WARN  %sno merge base between refs/remotes/origin/main and %s: run git fetch origin main; without a merge base no failure can be shown pre-existing\n' \
      "$prefix" "$(verify_short_sha "$commit")"
    return 1
  fi
  commit_date="$(verify_git log -1 --format=%cs "$merge_base" 2>/dev/null)"
  behind_count="$(verify_git rev-list --count "$merge_base..refs/remotes/origin/main" 2>/dev/null)"
  printf 'BASE  %smerge base %s (%s), %s commit(s) behind refs/remotes/origin/main\n' \
    "$prefix" "$(verify_short_sha "$merge_base")" "${commit_date:-unknown date}" "${behind_count:-unknown}"
}

# verify_add_worktree <path> <commit>: a temporary detached worktree, recorded
# for the trap before anything can fail after its creation.
verify_add_worktree() {
  local worktree_path="$1" commit="$2"
  if ! verify_git worktree add --detach --quiet "$worktree_path" "$commit" >"$worktree_path.log" 2>&1; then
    return 1
  fi
  printf '%s\n' "$worktree_path" >>"$worktree_list_file"
}

# verify_link_dependencies <worktree>: symlink each node_modules directory of
# the verified checkout into the same place, so a re-run needs no install.
# git lists an ignored directory once without descending, so nested
# node_modules and other worktrees under .claude/worktrees are never walked.
verify_link_dependencies() {
  local worktree_path="$1" ignored_path relative_path
  while IFS= read -r -d '' ignored_path; do
    relative_path="${ignored_path%/}"
    case "/$relative_path" in
      */node_modules) ;;
      *) continue ;;
    esac
    [ -d "$verified_root/$relative_path" ] || continue
    [ -e "$worktree_path/$relative_path" ] && continue
    mkdir -p "$(dirname "$worktree_path/$relative_path")" || continue
    ln -s "$verified_root/$relative_path" "$worktree_path/$relative_path" || continue
    printf '%s\n' "$worktree_path/$relative_path" >>"$symlink_list_file"
  done < <(verify_git -c core.quotepath=false ls-files --others --ignored --exclude-standard --directory -z 2>/dev/null)
}

# verify_base_worktree <merge-base>: print the base worktree's path, creating
# it on first use; every failing check of the run shares it.
verify_base_worktree() {
  local merge_base="$1" worktree_path
  worktree_path="$(awk -v merge_base="$merge_base" '$1 == merge_base { print $2; exit }' "$base_worktree_map_file")"
  if [ -n "$worktree_path" ]; then
    printf '%s\n' "$worktree_path"
    return 0
  fi
  worktree_path="$run_temporary_directory/base-$(verify_short_sha "$merge_base")"
  verify_add_worktree "$worktree_path" "$merge_base" || return 1
  verify_link_dependencies "$worktree_path"
  printf '%s %s\n' "$merge_base" "$worktree_path" >>"$base_worktree_map_file"
  printf '%s\n' "$worktree_path"
}

verify_label_for() {
  case "$1" in
    shell-lint) printf 'shell-lint' ;;
    leak) printf 'release-scrub leak check' ;;
    files-present) printf '01-files-present' ;;
    marker-strip) printf '03-marker-strip' ;;
  esac
}

verify_reproduce_for() {
  case "$1" in
    shell-lint) printf 'bash .gaia/tests/shell-lint.sh' ;;
    leak) printf 'bash .gaia/tests/distribution/lib/build-staging.sh "$(mktemp -d)"' ;;
    files-present) printf 'bash .gaia/tests/distribution/01-files-present.sh' ;;
    marker-strip) printf 'bash .gaia/tests/distribution/03-marker-strip.sh' ;;
  esac
}

# verify_execute_check <kind> <tree> <output-file>: run the tree's own copy of
# the check with the tree as the working directory. 01, 03 and their lib.sh
# resolve the repository root from the working directory, not their own path.
verify_execute_check() {
  local kind="$1" tree="$2" output_file="$3" staging_directory
  case "$kind" in
    shell-lint)
      (cd "$tree" && bash .gaia/tests/shell-lint.sh) >"$output_file" 2>&1 </dev/null
      ;;
    leak)
      staging_directory="$(mktemp -d "$run_temporary_directory/staging.XXXXXX")" || return 1
      (cd "$tree" && bash .gaia/tests/distribution/lib/build-staging.sh "$staging_directory") >"$output_file" 2>&1 </dev/null
      ;;
    files-present)
      (cd "$tree" && bash .gaia/tests/distribution/01-files-present.sh) >"$output_file" 2>&1 </dev/null
      ;;
    marker-strip)
      (cd "$tree" && bash .gaia/tests/distribution/03-marker-strip.sh) >"$output_file" 2>&1 </dev/null
      ;;
  esac
}

# verify_extract_items <kind> <tree> <output-file>: the failure items a base
# comparison matches on, one per line, sorted. Empty means the items could not
# be read, and the comparison falls back to the whole check.
verify_extract_items() {
  local kind="$1" tree="$2" output_file="$3"
  case "$kind" in
    shell-lint)
      # The linter's "In <file> line N:", bash -n's "<file>: line N:", and
      # the repo guards' "<file>:<line>:" each name the offending file.
      sed -n -E \
        -e 's/^In (.+) line [0-9]+:.*$/\1/p' \
        -e 's/^([^ :]+): line [0-9]+:.*$/\1/p' \
        -e 's/^([^ :]+):[0-9]+(:.*)?$/\1/p' "$output_file" | LC_ALL=C sort -u
      ;;
    *)
      verify_normalize_distribution_output "$tree" "$output_file"
      ;;
  esac
}

# Distribution diagnostics, normalized so the base and HEAD runs compare: the
# tree's own path and temporary paths are replaced, line numbers and counts
# are dropped, and the summary lines a passing scrub also prints are removed
# along with the warning-only allowlist section.
verify_normalize_distribution_output() {
  local tree="$1" output_file="$2" temporary_root="${TMPDIR:-/tmp}"
  temporary_root="${temporary_root%/}"
  awk -v tree="$tree" -v temporary_root="$temporary_root" '
    function replace_all(text, needle, replacement,   result, position) {
      result = ""
      if (needle == "") return text
      while ((position = index(text, needle)) > 0) {
        result = result substr(text, 1, position - 1) replacement
        text = substr(text, position + length(needle))
      }
      return result text
    }
    /^[[:space:]]*$/ { in_warning_section = 0; next }
    /warning only\):[[:space:]]*$/ { in_warning_section = 1; next }
    in_warning_section { next }
    /^release scrub: / || /^release runtime-deps: scanned / { next }
    /^(runtime-dependency )?leaks: none$/ || /^PASS / || /^==> / { next }
    {
      line = replace_all($0, tree, "<root>")
      line = replace_all(line, temporary_root, "<tmp>")
      print line
    }
  ' "$output_file" | sed -E \
    -e 's#(/private)?/(var/folders|tmp)/[^ :"]*#<tmp>#g' \
    -e 's#<tmp>/[^ :"]*#<tmp>#g' \
    -e 's#([A-Za-z0-9_./<>-]+):[0-9]+#\1:<line>#g' \
    -e 's#\([0-9]+((, warning only)?)\):$#(<n>\1):#' \
    -e 's#^(FAIL  [^:]+): [0-9]+ #\1: <n> #' | LC_ALL=C sort -u
}

# verify_report_outcome <label> <elapsed> <head-items> <base-items> <base-status|"">
#   <base-elapsed> <short-base> <raw-output> <reproduce>
# Prints the PRE-EXISTING and FAIL lines and updates the run's lists. A base
# status of "" means no base re-run happened, so nothing can be pre-existing.
verify_report_outcome() {
  local label="$1" elapsed="$2" head_items="$3" base_items="$4" base_status="$5" base_elapsed="$6"
  local short_base="$7" raw_output="$8" reproduce="$9" reproduced_items new_items
  reproduced_items="$run_temporary_directory/reproduced.$$"
  new_items="$run_temporary_directory/new.$$"
  : >"$reproduced_items"
  if [ -s "$head_items" ]; then
    cp "$head_items" "$new_items"
    if [ -n "$base_status" ] && [ "$base_status" -ne 0 ] && [ -s "$base_items" ]; then
      LC_ALL=C comm -12 "$head_items" "$base_items" >"$reproduced_items"
      LC_ALL=C comm -23 "$head_items" "$base_items" >"$new_items"
    fi
  else
    # No item could be read at HEAD: the whole check is the item.
    printf '%s\n' "$label" >"$new_items"
    if [ -n "$base_status" ] && [ "$base_status" -ne 0 ]; then
      printf '%s\n' "$label" >"$reproduced_items"
      : >"$new_items"
    fi
  fi
  if [ -s "$reproduced_items" ]; then
    printf 'PRE-EXISTING  %s: also fails on merge base %s; main is red (%ss)\n' "$label" "$short_base" "$elapsed"
    if [ -s "$head_items" ]; then
      verify_indent "$reproduced_items"
    else
      verify_print_raw_detail "$raw_output"
    fi
    printf '  merge-base re-run: %ss\n' "$base_elapsed"
    printf '%s\n' "$label" >>"$preexisting_list_file"
  fi
  if [ -s "$new_items" ]; then
    printf 'FAIL  %s (%ss)\n' "$label" "$elapsed"
    if [ -s "$reproduced_items" ]; then
      verify_indent "$new_items"
    else
      verify_print_raw_detail "$raw_output"
    fi
    if [ -n "$base_status" ]; then
      printf '  merge-base re-run on %s: %ss, did not reproduce these\n' "$short_base" "$base_elapsed"
    else
      printf '  (no merge-base re-run: %s)\n' "${verify_no_base_reason:-no merge base}"
    fi
    printf '  reproduce: %s\n' "$reproduce"
    new_failure_count=$((new_failure_count + 1))
  fi
  rm -f "$reproduced_items" "$new_items"
}

# verify_run_check <kind> <tree> <merge-base|""> <label-suffix> <reproduce-prefix>
# Runs one non-bats check, re-runs it on the merge base when it fails, and
# reports. Sets verify_last_check_status to the HEAD run's exit status.
verify_run_check() {
  local kind="$1" tree="$2" merge_base="$3" label_suffix="$4" reproduce_prefix="$5"
  local label output_file head_items base_items base_tree base_output start_seconds elapsed
  local base_status="" base_elapsed=0 short_base=""
  label="$(verify_label_for "$kind")$label_suffix"
  output_file="$(mktemp "$run_temporary_directory/output.XXXXXX")"
  start_seconds="$SECONDS"
  verify_execute_check "$kind" "$tree" "$output_file"
  verify_last_check_status=$?
  elapsed=$((SECONDS - start_seconds))
  if [ "$verify_last_check_status" -eq 0 ]; then
    printf 'PASS  %s (%ss)\n' "$label" "$elapsed"
    return 0
  fi
  head_items="$(mktemp "$run_temporary_directory/items.XXXXXX")"
  base_items="$(mktemp "$run_temporary_directory/items.XXXXXX")"
  verify_extract_items "$kind" "$tree" "$output_file" >"$head_items"
  verify_no_base_reason="no merge base with refs/remotes/origin/main"
  if [ -n "$merge_base" ]; then
    if base_tree="$(verify_base_worktree "$merge_base")"; then
      short_base="$(verify_short_sha "$merge_base")"
      base_output="$(mktemp "$run_temporary_directory/output.XXXXXX")"
      start_seconds="$SECONDS"
      verify_execute_check "$kind" "$base_tree" "$base_output"
      base_status=$?
      base_elapsed=$((SECONDS - start_seconds))
      verify_extract_items "$kind" "$base_tree" "$base_output" >"$base_items"
    else
      verify_no_base_reason="the merge-base worktree could not be created"
    fi
  fi
  verify_report_outcome "$label" "$elapsed" "$head_items" "$base_items" "$base_status" "$base_elapsed" \
    "$short_base" "$output_file" "$reproduce_prefix$(verify_reproduce_for "$kind")"
}

tool_missing() {
  ! command -v "$1" >/dev/null 2>&1
}
warn_missing_tool() {
  printf 'WARN  %s not found: install with %s; CI remains the only check for %s\n' "$1" "$2" "$3"
}

# verify_maintainer_binary_missing <tree>: warn when the tree cannot build a
# staging tree.
verify_maintainer_binary_missing() {
  [ -x "$1/.gaia/cli/gaia-maintainer" ] && return 1
  warn_missing_tool .gaia/cli/gaia-maintainer 'pnpm -C .gaia/cli bundle' \
    'release-scrub leak check, 01-files-present, 03-marker-strip'
  return 0
}

# verify_run_distribution <tree> <merge-base|""> <label-suffix> <reproduce-prefix> <binary-missing>
verify_run_distribution() {
  local tree="$1" merge_base="$2" label_suffix="$3" reproduce_prefix="$4" binary_missing="$5" reason="" kind
  [ "$rsync_missing" -eq 1 ] && reason="rsync not found"
  [ "$binary_missing" -eq 1 ] && reason=".gaia/cli/gaia-maintainer not found or not executable"
  if [ -n "$reason" ]; then
    for kind in leak files-present marker-strip; do
      verify_skip "$(verify_label_for "$kind")$label_suffix" "$reason"
    done
    return
  fi
  verify_run_check leak "$tree" "$merge_base" "$label_suffix" "$reproduce_prefix"
  if [ "$verify_last_check_status" -ne 0 ]; then
    verify_skip "01-files-present$label_suffix" "staging build failed (see release-scrub leak check)"
    verify_skip "03-marker-strip$label_suffix" "staging build failed (see release-scrub leak check)"
    return
  fi
  if [ "$jq_missing" -eq 1 ]; then
    verify_skip "01-files-present$label_suffix" "jq not found"
  else
    verify_run_check files-present "$tree" "$merge_base" "$label_suffix" "$reproduce_prefix"
  fi
  verify_run_check marker-strip "$tree" "$merge_base" "$label_suffix" "$reproduce_prefix"
}
