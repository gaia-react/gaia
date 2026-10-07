#!/usr/bin/env bash
# The owning-phase UAT gate. The generated plan orchestrator runs it from the
# resolved isolation root before an owning phase may commit, and once more over
# every e2e row before the pre-merge audit; the procedure is
# .claude/skills/gaia/references/spec/lifecycle.md.
#
#   uat-gate.sh <spec-path> --routing <routing-file> (--phase <N> | --all) [--report <playwright-json>]
#
# For the selected e2e rows (the phase's own, or every e2e row), in order:
#   1. static checks per spec file: it exists, line 1 is a contract marker, it
#      holds none of test.fail(, test.fixme(, test.skip(, .only(,
#      test.describe.skip( or test.describe.fixme(, and it clears a
#      deterministic floor (a page.<method>( call, and an expect( whose first
#      argument is not a bare literal);
#   2. uat-divergence-check.sh over the same selection;
#   3. working-doc-id-scan.sh over the frontend's Playwright tree;
#   4. Playwright over only the selected files with the JSON reporter, unless
#      --report supplies that JSON: every test in a file must be expected to
#      pass and have passed, and each file must hold at least one test.
# A failure in steps 1 to 3 stops before Playwright boots.
#
# Exit codes the caller branches on:
#   0  pass; also when the selection has no e2e rows (prints `no owned e2e specs`)
#   1  gate failure; one stderr line per failing file: `uat-gate: <file>: <reason>`
#      with reason one or more of missing, annotation, floor, divergence,
#      working-doc-id, expected-failure, skipped, fixme, failed, no-tests
#      (a line 1 that is not a contract marker reports missing)
#   2  invalid input (usage, malformed SPEC, invalid routing table, unreadable
#      --report)
#   4  Playwright could not run (jq, pnpm or a browser is missing, the dev or
#      Storybook port is held, a server failed to boot); stderr names the
#      prerequisite
#
# Honest limit: the gate proves a spec turned green and still carries its
# contract. Whether the test body truly exercises the UAT is judged by the
# pre-merge audit member, not here. The Playwright step boots the dev server and
# the Storybook server, needs a local Chromium, and aborts when `pnpm storybook`
# holds the Storybook port, so it runs only the owned files, never the suite.
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: uat-gate.sh <spec-path> --routing <routing-file> (--phase <N> | --all) [--report <playwright-json>]
USAGE
}

usage_failure() {
  printf 'uat-gate.sh: %s\n' "$1" >&2
  usage
  exit 2
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
source "$script_directory/uat-lib.sh"
repo_root="$PWD"

spec_path=''
routing_path=''
selected_phase=''
select_all=0
report_path=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 2
      ;;
    --routing)
      [ "$#" -ge 2 ] || usage_failure '--routing needs a file'
      routing_path="$2"
      shift 2
      ;;
    --phase)
      [ "$#" -ge 2 ] || usage_failure '--phase needs a number'
      selected_phase="$2"
      shift 2
      ;;
    --all)
      select_all=1
      shift
      ;;
    --report)
      [ "$#" -ge 2 ] || usage_failure '--report needs a file'
      report_path="$2"
      shift 2
      ;;
    -*)
      usage_failure "unknown option: $1"
      ;;
    *)
      [ -z "$spec_path" ] || usage_failure "unexpected argument: $1"
      spec_path="$1"
      shift
      ;;
  esac
done
[ -n "$spec_path" ] || usage_failure 'no SPEC path given'
[ -n "$routing_path" ] || usage_failure '--routing is required'
if [ -z "$selected_phase" ] && [ "$select_all" -eq 0 ]; then
  usage_failure 'one of --phase <N> or --all is required'
fi
if [ -n "$selected_phase" ] && [ "$select_all" -eq 1 ]; then
  usage_failure '--phase and --all are mutually exclusive'
fi
if [ -n "$selected_phase" ] && ! [[ "$selected_phase" =~ ^[1-9][0-9]*$ ]]; then
  usage_failure "--phase needs a positive integer, got '$selected_phase'"
fi
if [ -n "$report_path" ] && [ ! -f "$report_path" ]; then
  printf 'uat-gate.sh: report not found: %s\n' "$report_path" >&2
  exit 2
fi

uat_lib_parse_spec "$spec_path" >/dev/null || exit 2
uat_lib_validate_routing "$spec_path" "$routing_path" || exit 2
routing_rows=$(uat_lib_parse_routing "$routing_path") || exit 2
e2e_directory=$(uat_lib_e2e_directory "$repo_root") || exit 2

selected_files=''
selected_count=0
while IFS=$'\t' read -r uat_id surface phase feature_folder file_name; do
  [ "$surface" = "e2e" ] || continue
  if [ -n "$selected_phase" ] && [ "$phase" != "$selected_phase" ]; then
    continue
  fi
  selected_files="$selected_files$e2e_directory/$feature_folder/$file_name"$'\n'
  selected_count=$((selected_count + 1))
done <<<"$routing_rows"

if [ "$selected_count" -eq 0 ]; then
  printf 'no owned e2e specs\n'
  exit 0
fi

# failures rows: file<TAB>reason. One stderr line per file is printed at the end.
failures=''
add_failure() {
  failures="$failures$1"$'\t'"$2"$'\n'
}

# True when some expect( in the file has a first argument that is not a bare
# literal (true, false, null, undefined, a number, or a string without
# interpolation).
has_non_literal_expect() {
  awk '
    { text = text $0 "\n" }
    END {
      position = 1
      while ((offset = index(substr(text, position), "expect(")) > 0) {
        start = position + offset - 1
        before = start > 1 ? substr(text, start - 1, 1) : " "
        position = start + 7
        if (before ~ /[A-Za-z0-9_$.]/) continue
        rest = substr(text, position)
        sub(/^[ \t\r\n]+/, "", rest)
        first = substr(rest, 1, 1)
        if (first == "\047" || first == "\"" || first == "`") {
          closing = 0
          for (index_of = 2; index_of <= length(rest); index_of++) {
            character = substr(rest, index_of, 1)
            if (character == "\\") { index_of++; continue }
            if (character == first) { closing = index_of; break }
          }
          literal = 0
          if (closing > 0) {
            body = substr(rest, 2, closing - 2)
            after = substr(rest, closing + 1)
            sub(/^[ \t\r\n]+/, "", after)
            next_character = substr(after, 1, 1)
            if ((next_character == "," || next_character == ")") && !(first == "`" && index(body, "${") > 0)) literal = 1
          }
          if (!literal) { found = 1; exit }
          continue
        }
        token = ""
        for (index_of = 1; index_of <= length(rest); index_of++) {
          character = substr(rest, index_of, 1)
          if (character == "," || character == ")") break
          token = token character
        }
        gsub(/[ \t\r\n]+$/, "", token)
        if (token ~ /^(true|false|null|undefined)$/ || token ~ /^-?[0-9][0-9._]*$/) continue
        found = 1
        exit
      }
      exit found ? 0 : 1
    }
  ' "$1"
}

while IFS= read -r relative_path; do
  [ -n "$relative_path" ] || continue
  absolute_path="$repo_root/$relative_path"
  if [ ! -f "$absolute_path" ]; then
    add_failure "$relative_path" missing
    continue
  fi
  if [ -z "$(uat_lib_embedded_hash "$absolute_path")" ]; then
    add_failure "$relative_path" missing
    continue
  fi
  if grep -qE 'test\.fail\(|test\.fixme\(|test\.skip\(|\.only\(|test\.describe\.skip\(|test\.describe\.fixme\(' "$absolute_path"; then
    add_failure "$relative_path" annotation
  fi
  if ! grep -qE 'page\.[A-Za-z_]+\(' "$absolute_path" || ! has_non_literal_expect "$absolute_path"; then
    add_failure "$relative_path" floor
  fi
done <<<"$selected_files"

# Divergence: the check's own output names `<path> <uat_id> <field>`.
phase_arguments=(--all)
[ -z "$selected_phase" ] || phase_arguments=(--phase "$selected_phase")
divergence_output=$(bash "$script_directory/uat-divergence-check.sh" "$spec_path" --routing "$routing_path" ${phase_arguments[@]+"${phase_arguments[@]}"})
divergence_status=$?
if [ "$divergence_status" -eq 2 ]; then
  exit 2
fi
if [ "$divergence_status" -ne 0 ]; then
  while IFS= read -r divergence_line; do
    [ -n "$divergence_line" ] || continue
    divergence_path="${divergence_line%% *}"
    # A missing file or contract-less file is already reported as missing.
    [ "${divergence_line##* }" = "file" ] && continue
    add_failure "$divergence_path" divergence
  done <<<"$divergence_output"
fi

scan_output=$(bash "$script_directory/working-doc-id-scan.sh")
scan_status=$?
if [ "$scan_status" -eq 2 ]; then
  printf 'uat-gate.sh: the working-document id scan could not read the Playwright tree\n' >&2
  exit 2
fi
if [ "$scan_status" -ne 0 ]; then
  while IFS= read -r scan_line; do
    [ -n "$scan_line" ] || continue
    scan_path="${scan_line%%:[0-9]*}"
    add_failure "$scan_path" working-doc-id
  done <<<"$scan_output"
fi

report_failures() {
  [ -n "$failures" ] || return 1
  printf '%s' "$failures" | LC_ALL=C awk -F'\t' '
    {
      if (!($1 in reasons)) { order[++count] = $1; reasons[$1] = $2; next }
      if (index("," reasons[$1] ",", "," $2 ",") == 0) reasons[$1] = reasons[$1] "," $2
    }
    END { for (item = 1; item <= count; item++) printf "uat-gate: %s: %s\n", order[item], reasons[order[item]] > "/dev/stderr" }
  '
  return 0
}

if report_failures; then
  exit 1
fi

# --- Playwright ---
if ! command -v jq >/dev/null 2>&1; then
  printf 'uat-gate.sh: jq is not on PATH. Next step: install jq and retry.\n' >&2
  exit 4
fi

package_directory="${e2e_directory%/.playwright/e2e}"
[ "$package_directory" != "$e2e_directory" ] || package_directory='.'
if [ "$package_directory" = "." ]; then package_prefix=''; else package_prefix="$package_directory/"; fi

if [ -z "$report_path" ]; then
  if ! command -v pnpm >/dev/null 2>&1; then
    printf 'uat-gate.sh: pnpm is not on PATH, so Playwright cannot run. Next step: install pnpm and the frontend dependencies, then retry.\n' >&2
    exit 4
  fi
  gate_temporary=$(mktemp -d)
  trap 'rm -rf "$gate_temporary"' EXIT
  report_path="$gate_temporary/report.json"
  playwright_arguments=()
  while IFS= read -r relative_path; do
    [ -n "$relative_path" ] || continue
    playwright_arguments+=("${relative_path#"$package_prefix"}")
  done <<<"$selected_files"
  PLAYWRIGHT_JSON_OUTPUT_NAME="$report_path" pnpm -C "$package_directory" exec playwright test ${playwright_arguments[@]+"${playwright_arguments[@]}"} --reporter=json >/dev/null 2>"$gate_temporary/playwright.stderr"
  if ! jq -e . "$report_path" >/dev/null 2>&1; then
    printf 'uat-gate.sh: Playwright produced no report. Prerequisites: Chromium installed (pnpm exec playwright install chromium), the frontend dependencies installed, and the dev and Storybook ports free (stop pnpm storybook). Playwright said: %s\n' "$(head -c 400 "$gate_temporary/playwright.stderr" | LC_ALL=C tr '\r\n\t' '   ')" >&2
    exit 4
  fi
else
  if ! jq -e . "$report_path" >/dev/null 2>&1; then
    printf 'uat-gate.sh: report is not valid JSON: %s\n' "$report_path" >&2
    exit 2
  fi
fi

# A browser that is not installed, or a server that did not boot, shows up as
# top-level errors or as launch errors on every test, not as a test verdict.
if jq -e '((.errors // []) | length) > 0 or ([.. | objects | select(has("results")) | .results[]?.error.message // empty | select(test("Executable doesn.t exist|playwright install|browserType\\.launch|already used|webServer"))] | length) > 0' "$report_path" >/dev/null 2>&1; then
  printf 'uat-gate.sh: Playwright could not run the owned specs. Prerequisites: Chromium installed (pnpm exec playwright install chromium), the dev and Storybook ports free (stop pnpm storybook), the servers able to boot. Playwright said: %s\n' "$(jq -r '[(.errors // [])[]?.message // empty] | first // "see the report"' "$report_path" | head -c 400 | LC_ALL=C tr '\r\n\t' '   ')" >&2
  exit 4
fi

while IFS= read -r relative_path; do
  [ -n "$relative_path" ] || continue
  from_package="${relative_path#"$package_prefix"}"
  from_test_directory="${relative_path#"$e2e_directory"/}"
  verdict=$(jq -r --arg a "$from_test_directory" --arg b "$from_package" --arg c "$relative_path" '
    [.. | objects | select(has("tests") and has("file") and has("title")) | select(.file == $a or .file == $b or .file == $c) | .tests[]] as $tests
    | if ($tests | length) == 0 then "no-tests"
      elif any($tests[]; .status == "skipped" or .expectedStatus == "skipped") then
        (if any($tests[]; (.annotations // []) | any(.type == "fixme")) then "fixme" else "skipped" end)
      elif any($tests[]; .expectedStatus != "passed") then "expected-failure"
      elif any($tests[]; .status != "expected" or ((.results // []) | length) == 0 or (.results[-1].status != "passed")) then "failed"
      else "passed" end
  ' "$report_path")
  [ "$verdict" = "passed" ] || add_failure "$relative_path" "$verdict"
done <<<"$selected_files"

if report_failures; then
  exit 1
fi
exit 0
