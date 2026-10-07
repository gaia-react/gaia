# shellcheck shell=bash
# File-wide: the runner's globals are assigned in the runner, the pattern is
# read there, and verify_report_outcome and the other shared functions come
# from verify-harness-lib.sh, sourced first.
# shellcheck disable=SC2154,SC2034
#
# Private to .gaia/tests/verify-harness.sh: the two bats steps. Sourced by that
# runner after verify-harness-lib.sh and by nothing else. Defines functions
# only. Maintainer-only: .gaia/tests is release-excluded wholesale.

# The whole-tree mark, matched the way every consumer discovers marked suites.
verify_whole_tree_mark_pattern='^# bats file_tags=([^,]*,)*whole-tree(,|$)'

# verify_junit <mode> <suites-file> <report-file>
#   failures: "<suite path>\t<test name>" per failing testcase
#   passes:   "<suite path>\t<test name>" per testcase that ran and passed
#   missing:  each suite with no testsuite entry in the report
# The report names a suite relative to the common directory of the suites run
# and a testcase by its classname, so a failure maps back to its suite path
# through the "in test file <path>," its failure text carries when it has one,
# and otherwise by the unique suite whose path ends with that name.
verify_junit() {
  local mode="$1" suites_file="$2" report_file="$3"
  [ -f "$report_file" ] || {
    [ "$mode" = missing ] && cat "$suites_file"
    return 0
  }
  awk -v mode="$mode" '
    function attribute(line, key,   start, value) {
      if (!match(line, " " key "=\"[^\"]*\"")) return ""
      return substr(line, RSTART + length(key) + 3, RLENGTH - length(key) - 4)
    }
    function unescape(text) {
      gsub(/&lt;/, "<", text); gsub(/&gt;/, ">", text); gsub(/&quot;/, "\"", text)
      gsub(/&#39;/, "\047", text); gsub(/&apos;/, "\047", text); gsub(/&amp;/, "\\&", text)
      return text
    }
    function ends_with(path, name) {
      return path == name || (length(path) > length(name) && substr(path, length(path) - length(name)) == "/" name)
    }
    function suite_for(name, failure_path,   index_number, match_count, found) {
      if (failure_path != "") for (index_number = 1; index_number <= suite_count; index_number++) if (suites[index_number] == failure_path) return failure_path
      match_count = 0
      for (index_number = 1; index_number <= suite_count; index_number++) if (ends_with(suites[index_number], name)) { match_count++; found = suites[index_number] }
      if (match_count == 1) return found
      if (failure_path != "") return failure_path
      return name
    }
    FNR == NR { suites[++suite_count] = $0; next }
    /<testsuite / { reported[unescape(attribute($0, "name"))] = 1 }
    /<testcase / {
      classname = unescape(attribute($0, "classname")); test_name = unescape(attribute($0, "name"))
      open = ($0 !~ /\/>[[:space:]]*$/); failed = 0; skipped = 0; failure_path = ""
      if (!open && mode == "passes") print suite_for(classname, "") "\t" test_name
    }
    open && (/<failure/ || /<error/) { failed = 1 }
    open && /<skipped/ { skipped = 1 }
    open && failed && failure_path == "" && match($0, /in test file [^,]*, line/) {
      failure_path = unescape(substr($0, RSTART + 13, RLENGTH - 19))
    }
    /<\/testcase>/ {
      if (open && failed && mode == "failures") print suite_for(classname, failure_path) "\t" test_name
      if (open && !failed && !skipped && mode == "passes") print suite_for(classname, "") "\t" test_name
      open = 0; failed = 0; skipped = 0
    }
    END {
      if (mode != "missing") exit
      for (index_number = 1; index_number <= suite_count; index_number++) {
        seen = 0
        for (name in reported) if (ends_with(suites[index_number], name)) seen = 1
        if (!seen) print suites[index_number]
      }
    }
  ' "$suites_file" "$report_file"
}

# verify_invoke_bats <tree> <suites-file> <report-directory> <output> <error> [<filter>]
verify_invoke_bats() {
  local tree="$1" suites_file="$2" report_directory="$3" output_file="$4" error_file="$5" filter="${6:-}"
  local suite_path
  local -a suite_arguments filter_arguments
  suite_arguments=()
  filter_arguments=()
  while IFS= read -r suite_path; do
    [ -n "$suite_path" ] && suite_arguments+=("$suite_path")
  done <"$suites_file"
  [ -n "$filter" ] && filter_arguments=(--filter "$filter")
  (cd "$tree" && bash "$tree/.gaia/scripts/bats5.sh" --jobs 8 --report-formatter junit \
    --output "$report_directory" ${filter_arguments[@]+"${filter_arguments[@]}"} \
    ${suite_arguments[@]+"${suite_arguments[@]}"}) </dev/null >"$output_file" 2>"$error_file"
}

# verify_escape_regex: a test name as an anchored-safe extended regex literal.
verify_escape_regex() {
  printf '%s\n' "$1" | sed -e 's/[][\.^$*+?(){}|]/\\&/g'
}

# verify_name_filter <failures-file>: one anchored --filter over every failing
# test name, so a re-run runs exactly those tests and nothing else.
verify_name_filter() {
  local test_name filter=""
  while IFS= read -r test_name; do
    filter="$filter${filter:+|}$(verify_escape_regex "$test_name")"
  done < <(awk -F'\t' '{ print $2 }' "$1" | LC_ALL=C sort -u)
  printf '^(%s)$\n' "$filter"
}

# verify_isolate_flaky <tree> <failures-file> <head-items> <flaky-items>
# Re-runs the failing names alone at HEAD, in the same tree, the way the base
# re-run runs them. A wall-clock budget test can fail under the step's parallel
# load and pass alone, and comparing that load failure with a base re-run that
# runs alone would read a flake as new. A test is flaky only when the isolated
# report shows it ran and passed; one that fails again, was not run, or sits
# in a report that never appeared stays a failure. Flaky tests go to
# <flaky-items> and leave the failures and head-items files, edited in place.
verify_isolate_flaky() {
  local tree="$1" failures_file="$2" head_items="$3" flaky_items="$4"
  local isolated_suites isolated_report isolated_output isolated_error passed_items
  isolated_suites="$(mktemp "$run_temporary_directory/suites.XXXXXX")"
  isolated_report="$(mktemp -d "$run_temporary_directory/junit.XXXXXX")"
  isolated_output="$(mktemp "$run_temporary_directory/output.XXXXXX")"
  isolated_error="$(mktemp "$run_temporary_directory/error.XXXXXX")"
  passed_items="$(mktemp "$run_temporary_directory/items.XXXXXX")"
  awk -F'\t' '{ print $1 }' "$failures_file" | LC_ALL=C sort -u >"$isolated_suites"
  verify_invoke_bats "$tree" "$isolated_suites" "$isolated_report" "$isolated_output" "$isolated_error" \
    "$(verify_name_filter "$failures_file")"
  verify_junit passes "$isolated_suites" "$isolated_report/report.xml" \
    | awk -F'\t' '{ print $1 ": " $2 }' | LC_ALL=C sort -u >"$passed_items"
  LC_ALL=C comm -12 "$head_items" "$passed_items" >"$flaky_items"
  [ -s "$flaky_items" ] || return 0
  cat "$flaky_items" >>"$flaky_list_file"
  LC_ALL=C comm -23 "$head_items" "$flaky_items" >"$head_items.kept"
  mv "$head_items.kept" "$head_items"
  awk -F'\t' 'FNR == NR { flaky[$0] = 1; next } !(($1 ": " $2) in flaky)' "$flaky_items" "$failures_file" \
    >"$failures_file.kept"
  mv "$failures_file.kept" "$failures_file"
}

# verify_print_flaky <label> <flaky-items>: one loud line per flaky test.
verify_print_flaky() {
  local flaky_item
  while IFS= read -r flaky_item; do
    printf 'FLAKY  %s: %s failed under parallel load and passed when re-run alone\n' "$1" "$flaky_item"
  done <"$2"
}

# verify_run_bats_step <label> <tree> <suites-file> <merge-base|"">
verify_run_bats_step() {
  local label="$1" tree="$2" suites_file="$3" merge_base="$4"
  local report_directory output_file error_file status start_seconds elapsed failures_file
  local head_items base_items base_tree base_suites base_report base_output base_error base_status=""
  local base_elapsed=0 short_base="" suite_path filter="" load_failure=0 reproduce_suites flaky_items
  report_directory="$(mktemp -d "$run_temporary_directory/junit.XXXXXX")"
  output_file="$(mktemp "$run_temporary_directory/output.XXXXXX")"
  error_file="$(mktemp "$run_temporary_directory/error.XXXXXX")"
  start_seconds="$SECONDS"
  verify_invoke_bats "$tree" "$suites_file" "$report_directory" "$output_file" "$error_file"
  status=$?
  elapsed=$((SECONDS - start_seconds))
  # bats5.sh's bash-3.2 and serial-run warnings, relayed as written.
  cat "$error_file" >&2
  if [ "$status" -eq 0 ]; then
    printf 'PASS  %s (%ss)\n' "$label" "$elapsed"
    return 0
  fi
  failures_file="$(mktemp "$run_temporary_directory/failures.XXXXXX")"
  head_items="$(mktemp "$run_temporary_directory/items.XXXXXX")"
  base_items="$(mktemp "$run_temporary_directory/items.XXXXXX")"
  verify_junit failures "$suites_file" "$report_directory/report.xml" >"$failures_file"
  if [ -s "$failures_file" ]; then
    awk -F'\t' '{ print $1 ": " $2 }' "$failures_file" | LC_ALL=C sort -u >"$head_items"
  else
    load_failure=1
    verify_junit missing "$suites_file" "$report_directory/report.xml" >"$failures_file"
    [ -s "$failures_file" ] || cp "$suites_file" "$failures_file"
    awk '{ print $0 ": suite failed to run (see bats output)" }' "$failures_file" | LC_ALL=C sort -u >"$head_items"
    cat "$error_file" >>"$output_file"
  fi
  flaky_items="$(mktemp "$run_temporary_directory/items.XXXXXX")"
  # A load failure names no test to re-run alone, so it goes straight to the
  # base comparison.
  [ "$load_failure" -eq 0 ] && verify_isolate_flaky "$tree" "$failures_file" "$head_items" "$flaky_items"
  if [ ! -s "$head_items" ]; then
    printf 'PASS  %s (%ss)\n' "$label" "$elapsed"
    verify_print_flaky "$label" "$flaky_items"
    return 0
  fi
  verify_print_flaky "$label" "$flaky_items"
  verify_no_base_reason="no merge base with refs/remotes/origin/main"
  if [ -n "$merge_base" ]; then
    if base_tree="$(verify_base_worktree "$merge_base")"; then
      short_base="$(verify_short_sha "$merge_base")"
      base_suites="$(mktemp "$run_temporary_directory/suites.XXXXXX")"
      base_report="$(mktemp -d "$run_temporary_directory/junit.XXXXXX")"
      base_output="$(mktemp "$run_temporary_directory/output.XXXXXX")"
      base_error="$(mktemp "$run_temporary_directory/error.XXXXXX")"
      # A suite absent at the base cannot reproduce anything: its items stay new.
      awk -F'\t' '{ print $1 }' "$failures_file" | LC_ALL=C sort -u | while IFS= read -r suite_path; do
        [ -f "$base_tree/$suite_path" ] && printf '%s\n' "$suite_path"
      done >"$base_suites"
      [ "$load_failure" -eq 0 ] && filter="$(verify_name_filter "$failures_file")"
      if [ -s "$base_suites" ]; then
        start_seconds="$SECONDS"
        verify_invoke_bats "$base_tree" "$base_suites" "$base_report" "$base_output" "$base_error" "$filter"
        base_status=$?
        base_elapsed=$((SECONDS - start_seconds))
        if [ "$load_failure" -eq 0 ]; then
          verify_junit failures "$base_suites" "$base_report/report.xml" \
            | awk -F'\t' '{ print $1 ": " $2 }' | LC_ALL=C sort -u >"$base_items"
        elif [ "$base_status" -ne 0 ] \
          && [ -z "$(verify_junit failures "$base_suites" "$base_report/report.xml")" ]; then
          # The base fails to run the same suites too.
          awk '{ print $0 ": suite failed to run (see bats output)" }' "$base_suites" | LC_ALL=C sort -u >"$base_items"
        fi
      else
        base_status=0
      fi
    else
      verify_no_base_reason="the merge-base worktree could not be created"
    fi
  fi
  reproduce_suites="$(awk -F'\t' '{ print $1 }' "$failures_file" | LC_ALL=C sort -u | tr '\n' ' ')"
  if [ "$load_failure" -eq 1 ]; then
    # Load failures print bats' own output as the detail, so the items list
    # is the head of it and the raw output follows.
    cat "$head_items" "$output_file" >"$output_file.detail"
    mv "$output_file.detail" "$output_file"
  else
    cp "$head_items" "$output_file"
  fi
  verify_report_outcome "$label" "$elapsed" "$head_items" "$base_items" "$base_status" "$base_elapsed" \
    "$short_base" "$output_file" "bash .gaia/scripts/bats5.sh ${reproduce_suites}< /dev/null"
}

# verify_marked_suites <tree>: every tracked suite carrying the whole-tree mark.
verify_marked_suites() {
  local status
  git -C "$1" grep -l -E "$verify_whole_tree_mark_pattern" -- '*.bats'
  status=$?
  [ "$status" -le 1 ]
}
