#!/usr/bin/env bats
#
# Doc conformance for the one-command wiki maintenance chain. The router and
# the playbooks are prose instructions Claude executes, so the only
# deterministic check on them is on their text.
#
#   UAT-002: the router takes no arguments and prints one notice for any.
#   UAT-003: sync ends with a completion line the router branches on, and the
#            router gates nothing on consolidate.
#   UAT-004: a skipped consolidate finding resurfaces on the next run.
#   UAT-011: lint carries the broken-wikilink check and the router surfaces it.
#   UAT-012: the lint fix loop handles a broken wikilink.
#   UAT-014: the router stops the chain when the begin step fails.
#
# Each assertion is a helper that takes its file paths as arguments, so the
# same helper runs on the real file and on a scratch copy that holds the bad
# form and must fail. Banned stage invocations and the removed subcommand are
# owned by wiki-stage-args-retired.bats; this suite names none of them.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SKILL="$REPO_ROOT/.claude/skills/gaia-wiki/SKILL.md"
  ROUTER="$REPO_ROOT/.claude/skills/gaia/references/wiki.md"
  SYNC="$REPO_ROOT/.claude/skills/gaia/references/wiki/sync.md"
  CONSOLIDATE="$REPO_ROOT/.claude/skills/gaia/references/wiki/consolidate.md"
  LINT="$REPO_ROOT/.claude/skills/gaia/references/wiki/lint.md"
  LINT_FIX="$REPO_ROOT/.claude/skills/gaia/references/wiki/lint-fix.md"
  EN_DASH="$(printf '\xe2\x80\x93')"
  # Built from fragments so this file never carries the removed gate's own
  # spellings; the patterns still name them for the assertions.
  GATE_WORD="ga"
  GATE_WORD="${GATE_WORD}te"
  TRIGGER_FLAG="CONSOLIDATE_"
  TRIGGER_FLAG="${TRIGGER_FLAG}TRIGGERED"
  GATE_WORDING="consolidat[a-z]* ${GATE_WORD}|${GATE_WORD} trips|\\(${GATE_WORD}d\\)|${TRIGGER_FLAG}|threshold"
}

# --- shared helpers -------------------------------------------------------

# Fail unless file $1 exists and is non-empty, so a moved file is not a pass.
need_file() {
  [ -s "$1" ] || { echo "missing or empty file: $1"; return 1; }
}

# Print the body of the "## <name>" section of file $1: from its heading to the
# next "## " heading or end of file.
section_text() {
  awk -v heading="## $2" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

# Fail unless file $1 holds fixed string $2.
has_fixed() {
  need_file "$1" || return 1
  grep -qF -- "$2" "$1" || { echo "missing in $1: $2"; return 1; }
  return 0
}

# Fail when file $1 has a line matching extended regex $2 (case-sensitive).
lacks_regex() {
  need_file "$1" || return 1
  if grep -qE -- "$2" "$1"; then
    echo "unwanted in $1:"
    grep -nE -- "$2" "$1"
    return 1
  fi
  return 0
}

# Fail unless section $2 of file $1 holds fixed string $3.
section_has_fixed() {
  local text
  need_file "$1" || return 1
  text="$(section_text "$1" "$2")"
  [ -n "$text" ] || { echo "section is empty or absent in $1: $2"; return 1; }
  grep -qF -- "$3" <<<"$text" || { echo "missing in section '$2' of $1: $3"; return 1; }
  return 0
}

# Fail when section $2 of file $1 has a line matching extended regex $3,
# case-insensitive.
section_lacks_regex() {
  local text
  need_file "$1" || return 1
  text="$(section_text "$1" "$2")"
  [ -n "$text" ] || { echo "section is empty or absent in $1: $2"; return 1; }
  if grep -qiE -- "$3" <<<"$text"; then
    echo "unwanted in section '$2' of $1:"
    grep -niE -- "$3" <<<"$text"
    return 1
  fi
  return 0
}

# A scratch copy of file $1 named $2 under the test's temp dir; prints its path.
scratch_copy() {
  local destination="$BATS_TEST_TMPDIR/$2"
  cp "$1" "$destination"
  printf '%s\n' "$destination"
}

# A scratch copy of $1 with one line $3 added directly under heading line $2.
scratch_with_line_under() {
  local destination="$BATS_TEST_TMPDIR/$4"
  awk -v heading="$2" -v added="$3" '{ print } $0 == heading { print added }' "$1" >"$destination"
  printf '%s\n' "$destination"
}

# --- UAT-002: router arguments -------------------------------------------

assert_router_takes_no_arguments() {
  local router="$1" retired
  has_fixed "$router" 'Usage: /gaia-wiki' || return 1
  grep -qxF -- 'Usage: /gaia-wiki' "$router" || { echo "usage line is not on a line of its own"; return 1; }
  has_fixed "$router" 'Note: /gaia-wiki takes no arguments; ignoring "<arguments>" and running the full chain.' || return 1
  for retired in sync consolidate lint; do
    has_fixed "$router" "\`$retired\`" || return 1
  done
  lacks_regex "$router" 'Print help|No chaining|stop after relaying|sub-arg|Usage: /gaia-wiki \[' || return 1
  return 0
}

@test "UAT-002: the router takes no arguments and prints one notice for any" {
  run assert_router_takes_no_arguments "$ROUTER"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-002 can fail: a router with the print-help row back is flagged" {
  local scratch
  scratch="$(scratch_copy "$ROUTER" router-help.md)"
  printf '| (anything else) | Print help. |\n' >>"$scratch"
  run assert_router_takes_no_arguments "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Print help"* ]]
}

@test "UAT-002 can fail: a router without the notice line is flagged" {
  local scratch
  scratch="$BATS_TEST_TMPDIR/router-no-notice.md"
  grep -v '^Note: /gaia-wiki takes no arguments' "$ROUTER" >"$scratch" || true
  run assert_router_takes_no_arguments "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"takes no arguments"* ]]
}

# --- UAT-003: completion signal -------------------------------------------

assert_completion_signal() {
  local sync="$1" router="$2" file
  has_fixed "$sync" 'SYNC_COMPLETE: true' || return 1
  section_has_fixed "$router" 'Sync' 'SYNC_COMPLETE: true' || return 1
  section_has_fixed "$router" 'Full chain' 'SYNC_COMPLETE: true' || return 1
  for file in "$sync" "$router"; do
    lacks_regex "$file" "$TRIGGER_FLAG" || return 1
  done
  lacks_regex "$sync" '--diff-filter=A|^## Step 9' || return 1
  section_lacks_regex "$router" 'Full chain' "$GATE_WORDING" || return 1
  return 0
}

@test "UAT-003: sync ends with a completion line and the router gates nothing on consolidate" {
  run assert_completion_signal "$SYNC" "$ROUTER"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-003 can fail: a router whose full chain carries a sentence gating consolidate is flagged" {
  local scratch
  scratch="$(scratch_with_line_under "$ROUTER" '## Full chain' "Consolidate runs only when its ${GATE_WORD} trips on added pages." router-gate.md)"
  run assert_completion_signal "$SYNC" "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unwanted in section 'Full chain'"* ]]
}

@test "UAT-003: the unrelated merge gate sentence in the full chain is not flagged" {
  local scratch
  scratch="$(scratch_with_line_under "$ROUTER" '## Full chain' 'The merge gate outlasts any single wait.' router-merge-gate.md)"
  run assert_completion_signal "$SYNC" "$scratch"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-003 can fail: a sync playbook without the completion line is flagged" {
  local scratch="$BATS_TEST_TMPDIR/sync-no-signal.md"
  grep -v 'SYNC_COMPLETE: true' "$SYNC" >"$scratch" || true
  run assert_completion_signal "$scratch" "$ROUTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing in $scratch"* ]]
}

@test "UAT-003 can fail: a router whose full chain carries the old trigger flag is flagged" {
  local scratch
  scratch="$(scratch_with_line_under "$ROUTER" '## Full chain' "${TRIGGER_FLAG}: false" router-trigger.md)"
  run assert_completion_signal "$SYNC" "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TRIGGER_FLAG"* ]]
}

@test "UAT-003 can fail: a sync playbook with the old ninth step is flagged" {
  local scratch
  scratch="$(scratch_copy "$SYNC" sync-step9.md)"
  printf '## Step 9: Old gate\n' >>"$scratch"
  run assert_completion_signal "$scratch" "$ROUTER"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Step 9"* ]]
}

# --- UAT-004: a skipped finding resurfaces ----------------------------------

assert_skip_resurfaces() {
  local consolidate="$1"
  has_fixed "$consolidate" 'No-op. The finding stays active and resurfaces on the next `/gaia-wiki` run.' || return 1
  has_fixed "$consolidate" '`Keep both` is the only answer that suppresses a finding on later runs.' || return 1
  lacks_regex "$consolidate" 'revisit .* manually|running .*consolidate.* manually' || return 1
  return 0
}

@test "UAT-004: a skipped consolidate finding resurfaces and Keep both is the only dismissal" {
  run assert_skip_resurfaces "$CONSOLIDATE"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-004 can fail: the old skip wording is flagged" {
  local scratch="$BATS_TEST_TMPDIR/consolidate-old-skip.md"
  sed 's/^No-op\. The finding stays active.*/No-op. Finding remains active and will re-surface on the next consolidate run./' "$CONSOLIDATE" >"$scratch"
  run assert_skip_resurfaces "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing in $scratch"* ]]
}

@test "UAT-004 can fail: an instruction to revisit skipped findings manually is flagged" {
  local scratch
  scratch="$(scratch_copy "$CONSOLIDATE" consolidate-manual.md)"
  printf 'You can revisit them by running consolidate manually.\n' >>"$scratch"
  run assert_skip_resurfaces "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"manually"* ]]
}

# --- UAT-011: broken-wikilink check ----------------------------------------

# Prints the number of the last "## Step N" heading of lint file $1.
last_lint_step_number() {
  grep -E '^## Step [0-9]+' "$1" | tail -1 | sed -E 's/^## Step ([0-9]+).*/\1/'
}

assert_broken_wikilink_check() {
  local lint="$1" router="$2" consolidate="$3" last_step
  has_fixed "$lint" '## #17: Broken wikilinks' || return 1
  has_fixed "$lint" '.gaia/cli/gaia wiki broken-links --json' || return 1
  has_fixed "$lint" 'WIKI BROKEN-LINKS:' || return 1
  last_step="$(grep -E '^## Step ' "$lint" | tail -1)"
  [ "$last_step" = '## Step 9: Surface to the user' ] || { echo "last lint step is: $last_step"; return 1; }
  section_has_fixed "$router" 'Lint' 'WIKI BROKEN-LINKS:' || return 1
  section_has_fixed "$router" 'Lint' "Steps 1${EN_DASH}$(last_lint_step_number "$lint")" || return 1
  lacks_regex "$consolidate" 'No lint check detects a broken wikilink' || return 1
  return 0
}

@test "UAT-011: lint carries the broken-wikilink check and the router surfaces it" {
  run assert_broken_wikilink_check "$LINT" "$ROUTER" "$CONSOLIDATE"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-011 can fail: a router that does not surface the broken-link line is flagged" {
  local scratch="$BATS_TEST_TMPDIR/router-no-broken-links.md"
  sed 's/WIKI BROKEN-LINKS://g' "$ROUTER" >"$scratch"
  run assert_broken_wikilink_check "$LINT" "$scratch" "$CONSOLIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"WIKI BROKEN-LINKS:"* ]]
}

@test "UAT-011 can fail: a lint playbook renumbered to eight steps while the router says nine is flagged" {
  local scratch="$BATS_TEST_TMPDIR/lint-eight-steps.md"
  sed 's/^## Step 9: Surface to the user/## Step 8: Surface to the user/' "$LINT" >"$scratch"
  run assert_broken_wikilink_check "$scratch" "$ROUTER" "$CONSOLIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"last lint step is: ## Step 8"* ]]
}

@test "UAT-011 can fail: a consolidate playbook that denies any lint check for broken wikilinks is flagged" {
  local scratch
  scratch="$(scratch_copy "$CONSOLIDATE" consolidate-denial.md)"
  printf 'No lint check detects a broken wikilink.\n' >>"$scratch"
  run assert_broken_wikilink_check "$LINT" "$ROUTER" "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No lint check detects"* ]]
}

# --- Conformance beyond the UAT clauses ------------------------------------

assert_no_stage_invocation_wording() {
  local file
  for file in "$@"; do
    lacks_regex "$file" 'stage name such as|standalone' || return 1
  done
  return 0
}

assert_sync_commits_only_through_chain() {
  has_fixed "$1" 'gaia wiki chain commit' || return 1
  lacks_regex "$1" 'git commit|git -C [^ ]+ commit|commit -m' || return 1
  return 0
}

assert_router_lint_names_broken_wikilinks() {
  local text
  text="$(section_text "$1" 'Lint')"
  grep -qiE 'broken[- ]wikilink' <<<"$text" || { echo "the Lint section does not name broken wikilinks in $1"; return 1; }
  return 0
}

@test "the skill entry and the playbooks carry no stage-invocation wording" {
  run assert_no_stage_invocation_wording "$SKILL" "$SYNC" "$CONSOLIDATE" "$LINT" "$LINT_FIX"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "can fail: a skill entry that names a stage name such as an argument is flagged" {
  local scratch
  scratch="$(scratch_copy "$SKILL" skill-stage-wording.md)"
  printf 'Pass a stage name such as the first one.\n' >>"$scratch"
  run assert_no_stage_invocation_wording "$scratch" "$SYNC" "$CONSOLIDATE" "$LINT" "$LINT_FIX"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stage name such as"* ]]
}

@test "can fail: a playbook that is missing is flagged rather than skipped" {
  run assert_no_stage_invocation_wording "$SKILL" "$BATS_TEST_TMPDIR/no-such-playbook.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or empty file"* ]]
}

@test "sync commits only through the chain commit command" {
  run assert_sync_commits_only_through_chain "$SYNC"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "can fail: a sync playbook with a bare git commit line is flagged" {
  local scratch
  scratch="$(scratch_copy "$SYNC" sync-bare-commit.md)"
  printf 'git commit -m "wiki: sync"\n' >>"$scratch"
  run assert_sync_commits_only_through_chain "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git commit"* ]]
}

@test "the router describes lint as covering broken wikilinks" {
  run assert_router_lint_names_broken_wikilinks "$ROUTER"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "can fail: a router whose lint section never names broken wikilinks is flagged" {
  local scratch="$BATS_TEST_TMPDIR/router-lint-silent.md"
  sed -E 's/broken[- ][wW]ikilink/another/g' "$ROUTER" >"$scratch"
  run assert_router_lint_names_broken_wikilinks "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name broken wikilinks"* ]]
}

# --- UAT-012: lint fix loop ---------------------------------------------------

# Print the broken-wikilink entries of lint-fix file $1: each bullet that opens
# with the #17 marker, up to the next top-level bullet or heading.
fix_loop_broken_link_text() {
  awk '
    /^- \*\*#17/ { inside = 1; print; next }
    inside && (/^- / || /^#/) { inside = 0 }
    inside { print }
  ' "$1"
}

assert_fix_loop_handles_broken_links() {
  local text
  need_file "$1" || return 1
  text="$(fix_loop_broken_link_text "$1")"
  [ -n "$text" ] || { echo "no broken-wikilink entry in $1"; return 1; }
  local literal
  for literal in 'wiki/_archived/' 'Repoint to <page title>' 'Remove the link' 'Leave as is'; do
    grep -qF -- "$literal" <<<"$text" || { echo "missing in the broken-wikilink entry of $1: $literal"; return 1; }
  done
  return 0
}

@test "UAT-012: the fix loop repoints, removes, or leaves a broken wikilink and never repoints into the archive" {
  run assert_fix_loop_handles_broken_links "$LINT_FIX"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-012 can fail: a fix loop that never mentions the archive is flagged" {
  local scratch="$BATS_TEST_TMPDIR/lint-fix-no-archive.md"
  sed 's#wiki/_archived/#elsewhere/#g' "$LINT_FIX" >"$scratch"
  run assert_fix_loop_handles_broken_links "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wiki/_archived/"* ]]
}

@test "UAT-012 can fail: a fix loop without the remove option is flagged" {
  local scratch="$BATS_TEST_TMPDIR/lint-fix-no-remove.md"
  sed 's/Remove the link/Delete it/g' "$LINT_FIX" >"$scratch"
  run assert_fix_loop_handles_broken_links "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Remove the link"* ]]
}

# --- UAT-014: the chain stops when begin fails -------------------------------

assert_router_stops_on_failed_begin() {
  section_has_fixed "$1" 'Full chain' 'If `chain begin` exits non-zero, stop the chain:' || return 1
  section_lacks_regex "$1" 'Full chain' 'proceed regardless' || return 1
  return 0
}

@test "UAT-014: the router stops the chain when the begin step fails" {
  run assert_router_stops_on_failed_begin "$ROUTER"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-014 can fail: a router that proceeds regardless is flagged" {
  local scratch="$BATS_TEST_TMPDIR/router-proceeds.md"
  sed 's/If `chain begin` exits non-zero, stop the chain:/Proceed regardless of which./' "$ROUTER" >"$scratch"
  run assert_router_stops_on_failed_begin "$scratch"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stop the chain"* ]]
}
