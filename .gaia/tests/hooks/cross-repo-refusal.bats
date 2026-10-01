#!/usr/bin/env bats
#
# The fork (cross-repository) refusal: .claude/hooks/lib/cross-repo-refusal.sh
# on its own, and the merge gate (.claude/hooks/pr-merge-audit-check.sh)
# refusing a fork pull request before it reads or runs anything the checked-out
# tree carries.
#
# The merge cases check a fork head out as the working tree, with canary
# scripts at the paths the gate would otherwise source or run from it; a canary
# that runs appends to a log, so "the log does not exist" is the proof that no
# fork-supplied code ran. A mutant with the refusal neutralized shows the
# canaries do fire when the gate reaches them, so their silence is evidence.
# The audit-dispatch side lives in audit-loop-bound.bats and the pre-checkout
# guard in block-fork-pr-checkout.bats.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/cross-repo-refusal.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-fixture.sh"
  LIB="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/cross-repo-refusal.sh"
}

# --- the library ----------------------------------------------------------------

# lib_stub <stdout> <stderr> <exit>: a gh answering every call the same way.
lib_stub() {
  LIB_STUB_BIN="$BATS_TEST_TMPDIR/lib-stub"
  mkdir -p "$LIB_STUB_BIN"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %q\n' "$BATS_TEST_TMPDIR/lib-gh.log"
    printf 'printf %%s %q\n' "$1"
    printf 'printf %%s %q >&2\n' "$2"
    printf 'exit %s\n' "$3"
  } > "$LIB_STUB_BIN/gh"
  chmod +x "$LIB_STUB_BIN/gh"
}

# ask <pr-argument>: the library's exit status, then its error line, on stdout.
ask() {
  run bash -c '. "$1"; s=0; gaia_pr_is_cross_repository "$2" || s=$?; printf "%s\n%s" "$s" "$GAIA_CROSS_REPO_GH_ERROR"' \
    _ "$LIB" "$1"
}

ask_with_stub() {
  local saved="$PATH"
  PATH="$LIB_STUB_BIN:$PATH"
  ask "$1"
  PATH="$saved"
}

@test "library: true is a fork (0), false is not (1), and the pull request number reaches gh" {
  lib_stub 'true' '' 0
  ask_with_stub 34
  [ "${lines[0]}" = 0 ]
  grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$BATS_TEST_TMPDIR/lib-gh.log"
  lib_stub 'false' '' 0
  ask_with_stub 34
  [ "${lines[0]}" = 1 ]
}

@test "library: an empty argument asks about the current branch and passes gh no empty positional" {
  lib_stub 'false' '' 0
  ask_with_stub ''
  [ "${lines[0]}" = 1 ]
  grep -qxF -- 'pr view --json isCrossRepository --jq .isCrossRepository' "$BATS_TEST_TMPDIR/lib-gh.log"
}

@test "library: no pull request for the current branch is exit 1, read off gh's own wording" {
  lib_stub '' 'no pull requests found for branch "feature"' 1
  ask_with_stub ''
  [ "${lines[0]}" = 1 ]
}

@test "library: that wording for a NUMBERED pull request is exit 2, never a same-repo answer" {
  lib_stub '' 'no pull requests found for branch "feature"' 1
  ask_with_stub 34
  [ "${lines[0]}" = 2 ]
}

@test "library: any other gh failure is exit 2 and the error names it" {
  lib_stub '' 'HTTP 502: Bad Gateway' 1
  ask_with_stub 34
  [ "${lines[0]}" = 2 ]
  grep -qF -- 'HTTP 502: Bad Gateway' <<<"${lines[1]}"
  grep -qF -- 'exited 1' <<<"${lines[1]}"
}

@test "library: an answer that is neither true nor false is exit 2" {
  lib_stub '{"isCrossRepository":false}' '' 0
  ask_with_stub 34
  [ "${lines[0]}" = 2 ]
  grep -qF -- 'neither true nor false' <<<"${lines[1]}"
}

@test "library: gh absent from PATH is exit 2 and the error says so" {
  local bin="$BATS_TEST_TMPDIR/no-gh-bin"
  mkdir -p "$bin"
  ln -s "$(command -v bash)" "$bin/bash"
  run env PATH="$bin" bash -c '. "$1"; s=0; gaia_pr_is_cross_repository 34 || s=$?; printf "%s\n%s" "$s" "$GAIA_CROSS_REPO_GH_ERROR"' _ "$LIB"
  [ "${lines[0]}" = 2 ]
  [ "${lines[1]}" = 'gh is not on PATH' ]
}

@test "library: a non-numeric argument is exit 2 without asking gh" {
  lib_stub 'false' '' 0
  ask_with_stub 'feature-branch'
  [ "${lines[0]}" = 2 ]
  [ ! -s "$BATS_TEST_TMPDIR/lib-gh.log" ]
}

@test "library: the refusal message names the manual path, and sourcing twice is safe" {
  run bash -c '. "$1"; . "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$LIB"
  [ "$status" -eq 0 ]
  grep -qF -- 'This pull request comes from a fork (cross-repository).' <<<"$output"
  grep -qF -- "would run the fork's own harness code with your credentials" <<<"$output"
  grep -qF -- 'review the harness diff by hand (.claude/, .gaia/, .github/, .specify/)' <<<"$output"
  grep -qF -- 'push the branch to origin so it becomes a same-repo pull request' <<<"$output"
  grep -qF -- 'run the PR Merge Workflow on that.' <<<"$output"
}

@test "library: sourcing does no work (no gh call)" {
  lib_stub 'true' '' 0
  PATH="$LIB_STUB_BIN:$PATH" bash -c '. "$1"' _ "$LIB"
  [ ! -s "$BATS_TEST_TMPDIR/lib-gh.log" ]
}

# --- the merge gate -------------------------------------------------------------

# fork_head_fixture: REPO's working tree IS the fork's head, carrying canaries
# where the gate would source or run code from the acting tree.
fork_head_fixture() {
  mgf_init
  CANARY_LOG="$BATS_TEST_TMPDIR/canary.log"
  local canary
  for canary in .gaia/scripts/resolve-audit-members.sh .gaia/scripts/chore-deps-skip.sh \
    .gaia/scripts/main-root-lib.sh \
    .claude/hooks/lib/audit-scope.sh .claude/hooks/lib/audit-digest.sh; do
    mkdir -p "$REPO/$(dirname "$canary")"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q >> %q\n' "$canary" "$CANARY_LOG" > "$REPO/$canary"
    chmod +x "$REPO/$canary"
  done
  mgf_commit "wiki/page.md" "doc"
  git -C "$REPO" add -f .gaia/scripts .claude/hooks/lib
  git -C "$REPO" commit --quiet -m "fork harness"
  mgf_record 34 true "docs: from a fork" "wiki/page.md"
}

refusal_message() {
  bash -c '. "$1"; printf "%s" "$GAIA_CROSS_REPO_REFUSAL_MESSAGE"' _ "$LIB"
}

@test "UAT-010: a fork pull request's merge is denied with the refusal, and no fork-supplied code runs" {
  local reason
  fork_head_fixture
  mgf_run_merge "gh pr merge 34 --squash"
  assert_denied_by_json
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  grep -qF -- "$(refusal_message)" <<<"$reason"
  grep -qF -- 'review the harness diff by hand' <<<"$reason"
  grep -qF -- 'push the branch to origin' <<<"$reason"
  grep -qxF -- 'pr view 34 --json isCrossRepository --jq .isCrossRepository' "$MGF_GH_LOG"
  [ ! -e "$CANARY_LOG" ] || { printf 'fork code ran:\n%s\n' "$(cat "$CANARY_LOG")" >&2; return 1; }
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-010: a merge naming no pull request is checked against the current branch's, and a fork is denied" {
  fork_head_fixture
  mgf_run_merge "gh pr merge --squash --delete-branch"
  assert_denied_by_json
  grep -qF -- 'comes from a fork (cross-repository)' <<<"$output"
  grep -qxF -- 'pr view --json isCrossRepository --jq .isCrossRepository' "$MGF_GH_LOG"
  [ ! -e "$CANARY_LOG" ]
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-010: when gh cannot say whether the pull request is a fork, the merge is denied and nothing is posted" {
  local reason
  fork_head_fixture
  printf 'HTTP 502: Bad Gateway (https://api.github.com/graphql)\n' > "$MGF_STUB_DIR/pr-view-fails"

  mgf_run_merge "gh pr merge 34 --squash"
  assert_denied_by_json
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")"
  grep -qF -- 'cannot tell whether pull request 34 comes from a fork' <<<"$reason"
  grep -qF -- 'HTTP 502: Bad Gateway' <<<"$reason"
  grep -qF -- 'push the branch to origin' <<<"$reason"
  [ ! -e "$CANARY_LOG" ]
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-010 mutation: with the fork check neutralized the canaries do run, so their silence above is evidence" {
  local mutant
  fork_head_fixture
  mutant="$(mgf_scratch_hook 's/if _fork_deny_reason=\$\(gaia_cross_repo_deny_reason/if false && _fork_deny_reason=\$(gaia_cross_repo_deny_reason/')"

  mgf_run_merge "gh pr merge 34 --squash" "$mutant"
  [ -s "$CANARY_LOG" ]
  grep -qxF -- '.gaia/scripts/resolve-audit-members.sh' "$CANARY_LOG"
}

@test "UAT-010: the same pull request reported same-repo is not refused as a fork" {
  fork_head_fixture
  mgf_record 34 false "docs: same repo" "wiki/page.md"
  mgf_run_merge "gh pr merge 34 --squash"
  grep -qF -- 'comes from a fork' <<<"$output" && return 1
  true
}
