#!/usr/bin/env bats
#
# Tests for the verification gate inside .claude/hooks/audit-loop-bound.sh: the
# first Code Audit Team member dispatch, and the first audit-loop-unit
# dispatch, on a branch is refused unless the verification runner's branch
# mode left a pass record for the branch's current HEAD. The fixture is the
# verification runner's own (.gaia/tests/lib/helpers/verify-harness-fixture.sh),
# so a record is produced by the real runner or written here as JSON in the
# record's shape; no writer function exists to call.
#
# The hook runs from a scratch hook root built by this suite, not from the
# real checkout: a copy of the hook, the script libraries it loads, and (except
# in the missing-helper case) the pass-record helper. The maintainer-rule file
# under the fixture's main checkout is what marks it as the maintainer repo.
#
# GAIA_VERIFY_GATE_HOOK points the suite at a scratch copy of the hook, which
# is how a mutant is run without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-loop-verify-gate.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  unset GAIA_AUDIT_CHECKPOINT_ROUND GAIA_AUDIT_GRANT_ROUNDS GAIA_AUDIT_LOOP_DEADLINE_SECONDS
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/lib/helpers/verify-harness-fixture.sh"
  vhf_init || return 1
  mkdir -p "$VHF_ROOT/.claude/rules/maintainers"
  : >"$VHF_ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  STATE_FILE="$VHF_ROOT/.gaia/local/protected/audit-loop/feat/verify.json"
  RECORD_FILE="$VHF_RECORD"
  STUB_BIN="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$STUB_BIN"
  # No pull request exists for the fixture branch, which gh reports by failing.
  printf '#!/bin/sh\necho "no pull requests found" >&2\nexit 1\n' >"$STUB_BIN/gh"
  chmod +x "$STUB_BIN/gh"
  build_hook_root with-helper
}

# build_hook_root with-helper|without-helper: a scratch hook root whose
# .gaia/scripts holds real copies of what the hook loads. The whole real .gaia
# is never linked in, so the helper can be absent.
build_hook_root() {
  local hook_root="$BATS_TEST_TMPDIR/hook-root" script_name
  rm -rf "$hook_root"
  mkdir -p "$hook_root/.claude/hooks" "$hook_root/.gaia/scripts" "$hook_root/.gaia/tests/helpers"
  for script_name in audit-loop-state-lib.sh branch-name-lib.sh main-root-lib.sh audit-key-lib.sh context-checkpoint-lib.sh \
    audit-loop-eval.sh audit-loop-signals-lib.sh audit-dispositions-check.sh; do
    cp "$REPO_ROOT/.gaia/scripts/$script_name" "$hook_root/.gaia/scripts/$script_name"
  done
  ln -sfn "$REPO_ROOT/.claude/hooks/lib" "$hook_root/.claude/hooks/lib"
  cp "${GAIA_VERIFY_GATE_HOOK:-$REPO_ROOT/.claude/hooks/audit-loop-bound.sh}" "$hook_root/.claude/hooks/audit-loop-bound.sh"
  if [ "$1" = with-helper ]; then
    cp "$REPO_ROOT/.gaia/tests/helpers/verify-pass-record.sh" "$hook_root/.gaia/tests/helpers/verify-pass-record.sh"
  fi
  HOOK="$hook_root/.claude/hooks/audit-loop-bound.sh"
}

# member_payload <subagent_type> <root>
member_payload() {
  jq -n -c --arg member "$1" --arg root "$2" \
    '{session_id: "sess-a", hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: $member, prompt: ("Audit the change. Working root: " + $root + ", base main")}}'
}

# unit_payload <root>
unit_payload() {
  jq -n -c --arg root "$1" \
    '{session_id: "sess-a", hook_event_name: "PreToolUse", tool_name: "Agent", cwd: $root,
      tool_input: {subagent_type: "audit-loop-unit",
        prompt: ("Run one audit unit.\nWorking root: " + $root + "\nUnit: 1\nStart round: 1")}}'
}

# run_hook <payload-json>
run_hook() {
  run env PATH="$STUB_BIN:$PATH" bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$HOOK"
}

dispatch_member() {
  run_hook "$(member_payload "${1:-code-audit-frontend}" "${2:-$VHF_ROOT}")"
}

assert_allowed() {
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ -z "$output" ] || { printf 'unexpected output: %s\n' "$output" >&2; return 1; }
}

reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output" ||
    { printf 'raw output: %s\n' "$output" >&2; return 1; }
}

# assert_verify_denied: the last run denied with the verification gate's text.
assert_verify_denied() {
  [ "$status" -eq 0 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || { printf 'not a deny: %s\n' "$output" >&2; return 1; }
  case "$(reason)" in 'BLOCKED: audit verify'*) ;; *) printf 'want the verify prefix, got: %s\n' "$(reason)" >&2; return 1 ;; esac
}

# reason_has <text>: the decoded reason contains <text>.
reason_has() {
  grep -qF -- "$1" <<<"$(reason)" || { printf 'reason lacks %s: %s\n' "$1" "$(reason)" >&2; return 1; }
}

rounds_recorded() {
  if [ -f "$STATE_FILE" ]; then jq -r '.history.rounds | length' "$STATE_FILE"; else printf '0\n'; fi
}

units_recorded() {
  if [ -f "$STATE_FILE" ]; then jq -r '(.history.units // []) | length' "$STATE_FILE"; else printf '0\n'; fi
}

# write_record <head> [preexisting-json] [path]: a pass record in the helper's shape.
write_record() {
  local record_path="${3:-$RECORD_FILE}"
  mkdir -p "${record_path%/*}"
  jq -n -c --arg head "$1" --argjson preexisting "${2:-[]}" \
    '{schema: 1, branch: "feat/verify", head: $head, written_at: "2026-01-01T00:00:00Z", skipped: [], preexisting: $preexisting}' >"$record_path"
}

head_sha() {
  vhf_git rev-parse HEAD
}

# run_runner_branch <directory>: the real runner's branch mode from <directory>.
run_runner_branch() {
  run env PATH="$VHF_SHIM:$PATH" bash -c 'cd "$1" && bash .gaia/tests/verify-harness.sh branch' _ "$1"
}

@test "a first member dispatch with no pass record is refused naming the runner step, and records no round; with a record for HEAD it is allowed and records round one" {
  dispatch_member
  assert_verify_denied
  reason_has 'bash .gaia/tests/verify-harness.sh branch'
  reason_has 'feat/verify'
  reason_has "$(head_sha | cut -c1-8)"
  reason_has 'no verification pass record'
  [ "$(rounds_recorded)" = 0 ]
  write_record "$(head_sha)"
  dispatch_member
  assert_allowed
  [ "$(rounds_recorded)" = 1 ]
}

@test "the record the real runner writes satisfies the gate in the main checkout" {
  run_runner_branch "$VHF_ROOT"
  [ "$status" -eq 0 ]
  [ -f "$RECORD_FILE" ]
  dispatch_member
  assert_allowed
  [ "$(rounds_recorded)" = 1 ]
}

@test "the record the real runner writes from a linked worktree lands at the main checkout and satisfies the gate for that worktree" {
  local worktree="$BATS_TEST_TMPDIR/linked"
  vhf_git worktree add -q -b feat/linked "$worktree"
  worktree="$(cd "$worktree" && pwd -P)"
  run_runner_branch "$worktree"
  [ "$status" -eq 0 ]
  [ -f "$VHF_ROOT/.gaia/local/protected/verify-pass/feat/linked.json" ]
  [ ! -e "$worktree/.gaia/local/protected/verify-pass" ]
  dispatch_member code-audit-frontend "$worktree"
  assert_allowed
  [ "$(jq -r '.history.rounds | length' "$VHF_ROOT/.gaia/local/protected/audit-loop/feat/linked.json")" = 1 ]
}

@test "a commit after the pass makes the first dispatch refused again, naming the recorded head" {
  local recorded
  recorded="$(head_sha)"
  write_record "$recorded"
  printf 'more\n' >"$VHF_ROOT/after.txt"
  vhf_commit "a commit after the pass"
  dispatch_member
  assert_verify_denied
  reason_has 'bash .gaia/tests/verify-harness.sh branch'
  reason_has "$(printf '%s' "$recorded" | cut -c1-8)"
  reason_has "$(head_sha | cut -c1-8)"
  [ "$(rounds_recorded)" = 0 ]
}

@test "a record naming a pre-existing failure and matching HEAD allows the dispatch" {
  write_record "$(head_sha)" '["bats whole-tree"]'
  dispatch_member
  assert_allowed
  [ "$(rounds_recorded)" = 1 ]
}

@test "a first unit dispatch with no record is refused with the same text and appends no unit; with a record for HEAD it is admitted" {
  run_hook "$(unit_payload "$VHF_ROOT")"
  assert_verify_denied
  reason_has 'bash .gaia/tests/verify-harness.sh branch'
  [ "$(units_recorded)" = 0 ]
  [ "$(rounds_recorded)" = 0 ]
  write_record "$(head_sha)"
  run_hook "$(unit_payload "$VHF_ROOT")"
  assert_allowed
  [ "$(units_recorded)" = 1 ]
}

@test "only the first round is gated: with a round recorded and no record, a dispatch on a new tree is not refused by the verification gate" {
  write_record "$(head_sha)"
  dispatch_member
  assert_allowed
  [ "$(rounds_recorded)" = 1 ]
  rm -f "$RECORD_FILE"
  printf 'next\n' >"$VHF_ROOT/next.txt"
  vhf_commit "a second tree"
  dispatch_member
  case "$output" in *'BLOCKED: audit verify'*) printf 'the gate fired after round one: %s\n' "$output" >&2; return 1 ;; esac
  [ "$status" -eq 0 ]
}

@test "a light reviewer dispatch is not refused by the verification gate" {
  dispatch_member audit-light-reviewer
  assert_allowed
  [ "$(rounds_recorded)" = 0 ]
}

@test "a repository without the maintainer rule file is not gated" {
  rm -f "$VHF_ROOT/.claude/rules/maintainers/harness-triage-threshold.md"
  dispatch_member
  assert_allowed
  [ "$(rounds_recorded)" = 1 ]
}

@test "a record that is not JSON denies naming its path and branch mode" {
  mkdir -p "${RECORD_FILE%/*}"
  printf 'not json at all\n' >"$RECORD_FILE"
  dispatch_member
  assert_verify_denied
  reason_has "$RECORD_FILE"
  reason_has 'bash .gaia/tests/verify-harness.sh branch'
  reason_has 'unreadable'
  [ "$(rounds_recorded)" = 0 ]
}

@test "a hook root without the pass-record helper denies instead of allowing" {
  write_record "$(head_sha)"
  build_hook_root without-helper
  dispatch_member
  assert_verify_denied
  reason_has 'will not load'
  [ "$(rounds_recorded)" = 0 ]
}
