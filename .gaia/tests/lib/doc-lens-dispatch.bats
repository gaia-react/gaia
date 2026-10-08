#!/usr/bin/env bats
#
# Doc-conformance suite for the shared adversarial-audit lens-dispatch contract
# (.claude/skills/gaia/references/spec/lens-dispatch.md), read by the spec
# audit and the plan decomposition audit.
#
# THE PROBLEM. A dispatched lens that no-ops writes nothing, and a caller that
# never classifies the file reads the absence as "the lens found nothing". The
# contract prescribes one classify command; this suite EXECUTES that command
# (extracted from the file's own fenced block, not a retyped copy) against
# fixtures, then runs every prose check against a mutated scratch copy to prove
# each one can fail.
#
# Every check is a function taking the contract file, so a red twin hands it a
# mutated copy under BATS_TEST_TMPDIR.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CONTRACT="$REPO_ROOT/.claude/skills/gaia/references/spec/lens-dispatch.md"
}

# Print the classify command from the file's fenced bash block, with the script
# path made absolute and the findings-file placeholder replaced by $2.
classify_command() {
  local file="$1" findings="$2" line
  line="$(grep -E '^[[:space:]]*bash \.gaia/scripts/audit-noop-detect\.sh ' "$file" | head -n 1)"
  [ -n "$line" ] || return 1
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line/bash .gaia\/scripts\//bash $REPO_ROOT/.gaia/scripts/}"
  printf '%s\n' "${line/<findings file>/$findings}"
}

# Run the extracted command against a fixture body ($2); "-" means no file.
# Prints the exit code.
classify_exit() {
  local file="$1" body="$2" fixture="$BATS_TEST_TMPDIR/fixture.json" cmd
  rm -f "$fixture"
  if [ "$body" != "-" ]; then printf '%s' "$body" >"$fixture"; fi
  cmd="$(classify_command "$file" "$fixture")" || { echo "no-command"; return 0; }
  local rc=0
  (cd "$REPO_ROOT" && bash -c "$cmd" >/dev/null 2>&1) || rc=$?
  echo "$rc"
}

check_section_order() {
  local file="$1" got want
  got="$(grep -E '^## ' "$file" | tr '\n' '|')"
  want='## Caller slots|## Shared preamble|## Write and return|## Findings file schema|## Pre-clear, classify, re-dispatch|'
  [ "$got" = "$want" ]
}

check_under_500_lines() {
  [ "$(wc -l <"$1")" -lt 500 ]
}

check_opening_sentence() {
  grep -qF 'You are an ADVERSARIAL auditor of <ARTIFACT>' "$1"
}

check_redispatch_once() {
  grep -qF 're-dispatch that lens exactly once' "$1"
}

check_inline_fallback() {
  grep -qF 'run that lens inline on the main thread' "$1"
}

check_completion_notification() {
  grep -qF "completion notification, never at the moment the dispatch call returns" "$1"
}

check_repo_relative_preclear() {
  local file="$1"
  grep -qF 'rm -f .gaia/local/cache/audit-<spec_id>/findings/<LENS>.json' "$file" || return 1
  grep -qF 'rm -rf .gaia/local/plans/<PLAN-NNN>/audit' "$file" || return 1
  grep -qF 'mkdir -p .gaia/local/plans/<PLAN-NNN>/audit' "$file"
}

check_plan_bash_write_note() {
  local file="$1"
  grep -qF 'write the findings file with `Bash` at the main-checkout path' "$file" || return 1
  grep -qF 'read it back to confirm both its content and its location' "$file"
}

check_no_banned_prose() {
  local file="$1"
  grep -qF "$(printf '\xe2\x80\x94')" "$file" && return 1
  grep -qE 'SPEC-[0-9]+|UAT-[0-9]+|PLAN-[0-9]+|#[0-9]{2,}' "$file" && return 1
  true
}

# Scratch copy of the contract with one fixed string deleted.
mutate_delete() {
  local out="$BATS_TEST_TMPDIR/mutated.md"
  sed "s|$1||" "$CONTRACT" >"$out"
  printf '%s\n' "$out"
}

@test "contract has the five sections in order and stays small" {
  check_section_order "$CONTRACT"
  check_under_500_lines "$CONTRACT"
}

@test "red twin: a reordered section list fails the order check" {
  local mutated="$BATS_TEST_TMPDIR/reordered.md"
  sed 's|^## Shared preamble|## Preamble first|' "$CONTRACT" >"$mutated"
  check_section_order "$mutated" && return 1
  true
}

@test "classify command: an empty findings array is real (exit 0)" {
  [ "$(classify_exit "$CONTRACT" '{"dimension":"FG","findings":[]}')" = "0" ]
}

@test "classify command: a missing file is a no-op (exit 1)" {
  [ "$(classify_exit "$CONTRACT" '-')" = "1" ]
}

@test "classify command: a file with no findings key is a no-op (exit 1)" {
  [ "$(classify_exit "$CONTRACT" '{"dimension":"FG"}')" = "1" ]
}

@test "red twin: a fence that lost --report-key reads the empty-array fixture as a no-op" {
  local mutated
  mutated="$(mutate_delete ' --report-key findings')"
  [ "$(classify_exit "$mutated" '{"dimension":"FG","findings":[]}')" = "1" ]
}

@test "contract states the once-only re-dispatch" {
  check_redispatch_once "$CONTRACT"
}

@test "red twin: a copy without the re-dispatch sentence fails" {
  local mutated
  mutated="$(mutate_delete 're-dispatch that lens exactly once')"
  check_redispatch_once "$mutated" && return 1
  true
}

@test "contract states the inline fallback after a second no-op" {
  check_inline_fallback "$CONTRACT"
}

@test "red twin: a copy without the inline fallback fails" {
  local mutated
  mutated="$(mutate_delete 'run that lens inline on the main thread')"
  check_inline_fallback "$mutated" && return 1
  true
}

@test "contract names the completion notification as the classification point" {
  check_completion_notification "$CONTRACT"
}

@test "red twin: a copy that classifies at dispatch return fails" {
  local mutated
  mutated="$(mutate_delete ', never at the moment the dispatch call returns')"
  check_completion_notification "$mutated" && return 1
  true
}

@test "shared preamble keeps the literal ADVERSARIAL opening" {
  check_opening_sentence "$CONTRACT"
}

@test "red twin: a copy without the ADVERSARIAL opening fails" {
  local mutated
  mutated="$(mutate_delete 'You are an ADVERSARIAL auditor of')"
  check_opening_sentence "$mutated" && return 1
  true
}

@test "pre-clear commands are spelled repo-relative for both callers" {
  check_repo_relative_preclear "$CONTRACT"
}

@test "red twin: an absolute plan pre-clear spelling fails" {
  local mutated="$BATS_TEST_TMPDIR/absolute.md"
  sed 's|rm -rf .gaia/local/plans/<PLAN-NNN>/audit|rm -rf <PLAN_DIR>/audit|' "$CONTRACT" >"$mutated"
  check_repo_relative_preclear "$mutated" && return 1
  true
}

@test "plan column carries the Bash-at-main-path write note with read-back" {
  check_plan_bash_write_note "$CONTRACT"
}

@test "red twin: a copy without the read-back fails" {
  local mutated
  mutated="$(mutate_delete 'read it back to confirm both its content and its location')"
  check_plan_bash_write_note "$mutated" && return 1
  true
}

@test "contract carries no em dash and no working-document id" {
  check_no_banned_prose "$CONTRACT"
}

@test "red twin: a copy with an em dash fails the prose check" {
  local mutated="$BATS_TEST_TMPDIR/dash.md"
  { cat "$CONTRACT"; printf 'a \xe2\x80\x94 b\n'; } >"$mutated"
  check_no_banned_prose "$mutated" && return 1
  true
}
