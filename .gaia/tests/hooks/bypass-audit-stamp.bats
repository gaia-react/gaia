#!/usr/bin/env bats
#
# The merge gate's GAIA-Audit bypass stamp (.claude/hooks/pr-merge-audit-check.sh
# with .claude/hooks/lib/audit-bypass-stamp.sh), and the marker path it leaves
# to post-audit-status.sh.
#
# A pull request the gate clears through a bypass (out of scope, or a
# manifest-only chore(deps)) has no member marker, so the gate itself posts the
# GAIA-Audit status branch protection waits on, immediately before the allow.
# The refusal state is the other half and the one that must hold: no POST on a
# deny, and none for a pull request cleared by a marker rather than a bypass.
#
# Every case drives the real hook with a logging gh stub
# (helpers/merge-gate-fixture.sh) and asserts on the stub's log.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/bypass-audit-stamp.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-fixture.sh"
  mgf_init
}

# assert_one_post <description>: exactly one status POST, to the pull request's
# head, carrying the bypass fields and <description>, and it is the last gh call
# the gate made (the allow follows it with nothing on stdout).
assert_one_post() {
  local head posts
  head="$(git -C "$REPO" rev-parse HEAD)"
  posts="$(mgf_post_lines)"
  [ "$(mgf_post_count)" -eq 1 ] || { printf 'expected one POST, log:\n%s\n' "$(cat "$MGF_GH_LOG")" >&2; return 1; }
  grep -qF -- "repos/test-owner/test-repo/statuses/${head}" <<<"$posts" || return 1
  grep -qF -- '-f state=success' <<<"$posts" || return 1
  grep -qF -- '-f context=GAIA-Audit' <<<"$posts" || return 1
  grep -qxF -- "api -X POST repos/test-owner/test-repo/statuses/${head} -f state=success -f context=GAIA-Audit -f description=$1" <<<"$posts" || return 1
  [ "$(tail -n 1 "$MGF_GH_LOG")" = "$posts" ] || { printf 'the POST is not the last gh call:\n%s\n' "$(cat "$MGF_GH_LOG")" >&2; return 1; }
}

assert_allowed_silently() {
  [ "$status" -eq 0 ] || return 1
  [ -z "$output" ] || { printf 'expected an allow (empty stdout), got: %s\n' "$output" >&2; return 1; }
}

# The marker-present fixture both the real hook and its mutant run.
wiki_pr_with_stale_marker() {
  mgf_commit "frontend/app/x.ts" "export const x = 1"
  git -C "$REPO" checkout --quiet main
  git -C "$REPO" merge --quiet --ff-only feature
  git -C "$REPO" checkout --quiet feature
  mgf_marker code-audit-frontend >/dev/null
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
}

# --- out of scope ------------------------------------------------------------

@test "UAT-011: a wiki-only pull request is allowed and gets exactly one out-of-scope stamp before the allow" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  assert_one_post 'skipped: out of scope'
}

@test "UAT-011: a wiki-only pull request a still-valid frontend marker would clear first still gets the out-of-scope stamp" {
  wiki_pr_with_stale_marker
  # The marker validates for the unchanged digest: a wiki change rotates none.
  [ -f "$REPO/.gaia/local/audit/$(mgf_member_digest code-audit-frontend).ok" ]

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  assert_one_post 'skipped: out of scope'
}

@test "UAT-011: a wiki-only pull request whose head already carries a cleared GAIA-Audit status is allowed with no POST" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  mgf_status_success

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]
  # Non-vacuity: the gate did read the statuses the fixture planted.
  grep -qF -- '/statuses --jq' "$MGF_GH_LOG"
}

@test "UAT-011 mutation: evaluating the out-of-scope check after frontend_cleared loses the stamp on the marker-present fixture" {
  local mutant
  mutant="$(mgf_scratch_hook 's/\n  check_out_of_scope_pr && out_of_scope_pr=1\n/\n/; s/(\n  if \[ "\$out_of_scope_pr" -eq 1 \]; then\n    github_status_cleared)/\n  check_out_of_scope_pr && out_of_scope_pr=1$1/')"
  # Moved, not deleted: the evaluation still runs, after the marker allows.
  [ "$(grep -c 'check_out_of_scope_pr && out_of_scope_pr=1' "$mutant")" -eq 1 ]
  wiki_pr_with_stale_marker

  mgf_run_merge "gh pr merge 12 --squash" "$mutant"
  assert_allowed_silently
  # The real hook posts once here (the test above); the mutant posts nothing,
  # so that test's assertion is red against it.
  [ "$(mgf_post_count)" -eq 0 ]
}

# --- chore(deps) --------------------------------------------------------------

@test "UAT-011: a manifest-only chore(deps) pull request is allowed and gets the chore(deps) stamp" {
  cp "$MGF_REPO_ROOT/.gaia/scripts/chore-deps-skip.sh" "$REPO/.gaia/scripts/chore-deps-skip.sh"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$MGF_REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/gaia-packages.sh"
  mgf_commit "package.json" '{"name":"x","version":"1.0.1"}'
  mgf_record 12 false "chore(deps): bump x from 1.0.0 to 1.0.1" "package.json"
  # Non-vacuity: package.json dispatches a member, so this is the member-aware
  # gate's allow, cleared by the waiver rather than a marker.
  [ -n "$(cd "$REPO" && bash .gaia/scripts/resolve-audit-members.sh 2>/dev/null)" ]

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  assert_one_post 'skipped: chore(deps) manifest-only'
}

# --- the refusal state ----------------------------------------------------------

@test "UAT-011: an in-scope pull request with no marker is denied and nothing is posted" {
  mgf_commit "frontend/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "frontend/app/x.ts"

  mgf_run_merge "gh pr merge 12 --squash"
  assert_denied_by_json
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-011: an in-scope pull request cleared by its member marker is allowed with no bypass POST" {
  mgf_commit "frontend/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "frontend/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-011: an ownerless in-scope pull request cleared by the legacy marker is allowed with no bypass POST" {
  mgf_commit "Makefile" "all:"
  mgf_record 12 false "build: makefile" "Makefile"
  mgf_marker code-audit-frontend >/dev/null

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]
}

@test "UAT-011 mutation: posting on every member-aware allow turns the marker-cleared case red" {
  local mutant
  mutant="$(mgf_scratch_hook 's/\[ "\$frontend_chore_deps_waived" -eq 0 \] \|\| gate_post_bypass_stamp/gate_post_bypass_stamp/')"
  mgf_commit "frontend/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "frontend/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null

  mgf_run_merge "gh pr merge 12 --squash" "$mutant"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 1 ]
}

@test "no stamp when the pull request's recorded head is not local HEAD, and the reason names the manual command" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  mgf_commit "wiki/other.md" "unpushed"

  mgf_run_merge "gh pr merge 12 --squash"
  [ "$(mgf_post_count)" -eq 0 ]
  grep -qF -- 'GAIA-Audit bypass status not posted' <<<"$stderr" || return 1
  grep -qF -- 'gh api -X POST' <<<"$stderr" || return 1
}

# The head GitHub reports on a numbered read after the classification is a
# commit nobody classified: the stamp must still land on local HEAD.
moved_head_after_record() {
  jq -c '.headRefOid = "0123456789abcdef0123456789abcdef01234567"' "$MGF_STUB_DIRECTORY/record.json" \
    > "$MGF_STUB_DIRECTORY/numbered-record.json"
}

@test "the stamp posts on the classified local HEAD even when a numbered head read would answer a moved head" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  moved_head_after_record

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  assert_one_post 'skipped: out of scope'
  ! grep -qF -- '0123456789abcdef0123456789abcdef01234567' "$MGF_GH_LOG"
}

@test "mutation: re-reading the pull request head for the stamp moves the POST onto the unclassified head" {
  local mutant
  mutant="$(mgf_scratch_hook 's/audit_post_bypass_status "\$pr_record_number" "\$sha" "\$description"/audit_post_bypass_status "\$pr_record_number" "\$(gh pr view "\$pr_record_number" --json headRefOid --jq .headRefOid)" "\$description"/')"
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  moved_head_after_record

  mgf_run_merge "gh pr merge 12 --squash" "$mutant"
  assert_allowed_silently
  # The real hook posts on local HEAD (the test above); the mutant posts on the
  # moved head, so that test's assertion is red against it.
  mgf_post_lines | grep -qF -- 'statuses/0123456789abcdef0123456789abcdef01234567'
}

@test "a rejected POST still allows the bypass and names the manual command on stderr" {
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  sed -i.bak 's/\*" -X POST "\*) exit 0 ;;/*" -X POST "*) exit 1 ;;/' "$MGF_STUB_DIRECTORY/bin/gh"
  grep -qF -- '" -X POST "*) exit 1' "$MGF_STUB_DIRECTORY/bin/gh"

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 1 ]
  grep -qF -- "description='skipped: out of scope'" <<<"$stderr" || return 1
}

# --- the marker path: the gate allows and post-audit-status.sh posts -----------
#
# A stale audit workflow and a legacy audit configuration on the base, the two
# shapes an adopter's tree can carry after the CI lane is gone. Neither may pull
# a same-repo pull request off the local path.

uat_004_fixture() {
  git -C "$REPO" checkout --quiet main
  mkdir -p "$REPO/.github/workflows"
  printf 'name: Code Review Audit\non: pull_request\n' > "$REPO/.github/workflows/code-review-audit.yml"
  [ -z "$1" ] || printf 'default_mode: %s\n' "$1" >> "$REPO/.gaia/audit-ci.yml"
  git -C "$REPO" add .github/workflows/code-review-audit.yml .gaia/audit-ci.yml
  git -C "$REPO" commit --quiet -m "stale audit lane"
  git -C "$REPO" checkout --quiet -B feature main
  mgf_commit "frontend/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "frontend/app/x.ts"
}

@test "UAT-004 fixture A (stale workflow, no default_mode): the marker allows the merge and post-audit-status.sh posts success" {
  local marker
  uat_004_fixture ''
  grep -q 'default_mode' "$REPO/.gaia/audit-ci.yml" && return 1
  marker="$(mgf_marker code-audit-frontend)"

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]

  run bash -c 'cd "$1" && bash "$2" "$3"' _ "$REPO" "$MGF_REPO_ROOT/.claude/hooks/post-audit-status.sh" "$marker"
  [ "$status" -eq 0 ]
  [ "$(mgf_post_count)" -eq 1 ]
  mgf_post_lines | grep -qF -- 'state=success' || return 1
  mgf_post_lines | grep -qF -- 'context=GAIA-Audit' || return 1
}

@test "UAT-004 fixture B (stale workflow, default_mode: ci): the marker allows the merge and post-audit-status.sh posts success" {
  local marker
  uat_004_fixture ci
  grep -qx 'default_mode: ci' "$REPO/.gaia/audit-ci.yml"
  marker="$(mgf_marker code-audit-frontend)"

  mgf_run_merge "gh pr merge 12 --squash"
  assert_allowed_silently
  [ "$(mgf_post_count)" -eq 0 ]

  run bash -c 'cd "$1" && bash "$2" "$3"' _ "$REPO" "$MGF_REPO_ROOT/.claude/hooks/post-audit-status.sh" "$marker"
  [ "$status" -eq 0 ]
  [ "$(mgf_post_count)" -eq 1 ]
  mgf_post_lines | grep -qF -- 'state=success' || return 1
  mgf_post_lines | grep -qF -- 'context=GAIA-Audit' || return 1
}

@test "UAT-004: the merge gate carries no self-modification bypass" {
  grep -nE 'check_self_mod_only_update_pr|self_mod_only' "$MGF_HOOK" && return 1
  true
}
