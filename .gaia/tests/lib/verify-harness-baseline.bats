#!/usr/bin/env bats
#
# Tests for .gaia/tests/verify-harness.sh's merge-base comparison, push mode
# and pass record, and for the read-only pass-record helper
# .gaia/tests/helpers/verify-pass-record.sh. Fixtures come from
# .gaia/tests/lib/helpers/verify-harness-fixture.sh; its stubs and fixture
# suites log the toplevel each run happened in, which is how a case tells a
# merge-base re-run in a temporary worktree from a run in the fixture itself.
#
# VERIFY_HARNESS_SOURCE_DIRECTORY points the fixture at a scratch copy of the
# runner and its helpers, which is how a mutant runs without touching the
# working files.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/verify-harness-baseline.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/lib/helpers/verify-harness-fixture.sh"
}

fixture() {
  vhf_init "$@" || return 1
  PATH="$VHF_SHIM:$PATH"
  cd "$VHF_ROOT" || return 1
}

run_runner() {
  run bash "$VHF_ROOT/.gaia/tests/verify-harness.sh" "$@"
}

has() {
  grep -qF -- "$1" <<<"$output" && return 0
  printf 'expected output to contain: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

lacks() {
  grep -qF -- "$1" <<<"$output" || return 0
  printf 'expected output not to contain: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

has_line() {
  grep -qE -- "$1" <<<"$output" && return 0
  printf 'expected a line matching: %s\n--- output ---\n%s\n' "$1" "$output" >&2
  return 1
}

no_fail_line() {
  grep -qE '^FAIL  ' <<<"$output" || return 0
  printf 'expected no FAIL line\n--- output ---\n%s\n' "$output" >&2
  return 1
}

# block_after <line prefix>: the indented lines following the first output
# line that starts with the prefix.
block_after() {
  awk -v prefix="$1" '
    found && /^  / { print; next }
    found { exit }
    index($0, prefix) == 1 { found = 1 }
  ' <<<"$output"
}

worktree_count() {
  vhf_git worktree list --porcelain | grep -c '^worktree '
}

source_pass_record_helper() {
  # shellcheck source=/dev/null
  . "$VHF_ROOT/.gaia/tests/helpers/verify-pass-record.sh"
}

@test "a clean branch run prints a line per check, writes the record and creates no base worktree" {
  fixture
  printf 'x two\n' >src/x-input.txt
  vhf_commit "a change the x suite names"
  vhf_main_change upstream.txt "upstream" "a commit on main after the branch point"
  run_runner branch
  [ "$status" -eq 0 ]
  local label
  for label in shell-lint 'release-scrub leak check' 01-files-present 03-marker-strip 'bats whole-tree' 'bats selected'; do
    has_line "^PASS  $label \\([0-9]+s\\)$"
  done
  has_line '^TOTAL [0-9]+s$'
  [ "$(vhf_log_entries shell-lint)" = "$VHF_ROOT" ]
  [ "$(vhf_log_entries build-staging)" = "$VHF_ROOT" ]
  [ "$(vhf_log_entries 01-files-present)" = "$VHF_ROOT" ]
  [ "$(vhf_log_entries 03-marker-strip)" = "$VHF_ROOT" ]
  [ -f "$VHF_RECORD" ]
  [ "$(jq -r .head "$VHF_RECORD")" = "$(vhf_git rev-parse HEAD)" ]
  source_pass_record_helper
  run gaia_verify_pass_record_check "$VHF_ROOT" feat/verify "$(vhf_git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  lacks 'PRE-EXISTING'
  [ "$(worktree_count)" -eq 1 ]
  [ -z "$(awk -F'|' -v root="$VHF_ROOT" '$NF != root' "$VERIFY_FIXTURE_LOG")" ]
}

@test "the staleness line names the merge base and how far origin/main is ahead of it" {
  fixture
  vhf_main_change upstream.txt "upstream" "a commit on main after the branch point"
  run_runner branch
  [ "$status" -eq 0 ]
  local merge_base behind
  merge_base="$(vhf_git merge-base refs/remotes/origin/main HEAD)"
  behind="$(vhf_git rev-list --count "$merge_base..refs/remotes/origin/main")"
  [ "$behind" -eq 1 ]
  has "BASE  merge base $(vhf_git rev-parse --short "$merge_base") ($(vhf_git log -1 --format=%cs "$merge_base")), $behind commit(s) behind refs/remotes/origin/main"
}

@test "a failure main already has is pre-existing, a new one fails, and fixing it writes the record" {
  fixture --no-branch
  vhf_control whole-one "broken on main"
  vhf_commit "main breaks the whole-tree suite"
  vhf_branch
  vhf_control x-input "broken on the branch"
  vhf_commit "the branch breaks the x suite"
  run_runner branch
  [ "$status" -eq 1 ]
  has_line '^PRE-EXISTING  bats whole-tree: also fails on merge base [0-9a-f]+; main is red \([0-9]+s\)$'
  block_after 'PRE-EXISTING  bats whole-tree' | grep -qF 'suites/whole.bats: whole one'
  has_line '^FAIL  bats selected \([0-9]+s\)$'
  block_after 'FAIL  bats selected' | grep -qF 'suites/x.bats: x input'
  has '  reproduce: bash .gaia/scripts/bats5.sh suites/x.bats < /dev/null'
  [ ! -e "$VHF_RECORD" ]

  vhf_control x-input ""
  vhf_commit "the branch fixes the x suite"
  run_runner branch
  [ "$status" -eq 0 ]
  has_line '^PRE-EXISTING  bats whole-tree: also fails on merge base [0-9a-f]+; main is red'
  no_fail_line
  [ "$(jq -r .head "$VHF_RECORD")" = "$(vhf_git rev-parse HEAD)" ]
  [ "$(jq -c .preexisting "$VHF_RECORD")" = '["bats whole-tree"]' ]
}

@test "a new failing test in a suite main already fails is reported, not masked" {
  fixture --no-branch
  vhf_control whole-one "broken on main"
  vhf_commit "main breaks one whole-tree test"
  vhf_branch
  vhf_add_test suites/whole.bats two
  vhf_control whole-two "broken on the branch"
  vhf_commit "the branch adds a second failing test to the same suite"
  run_runner branch
  [ "$status" -eq 1 ]
  block_after 'PRE-EXISTING  bats whole-tree' | grep -qxF '  suites/whole.bats: whole one'
  block_after 'PRE-EXISTING  bats whole-tree' | grep -qF 'whole two' && return 1
  has_line '^FAIL  bats whole-tree \([0-9]+s\)$'
  block_after 'FAIL  bats whole-tree' | grep -qxF '  suites/whole.bats: whole two'
  # The base re-run ran only the failing names, in the base worktree.
  [ "$(vhf_suite_runs_elsewhere suites/whole.bats "$VHF_ROOT")" = "whole one" ]
  [ ! -e "$VHF_RECORD" ]
}

@test "a distribution failure only HEAD has is new, and its base re-run happens in a worktree" {
  fixture
  vhf_control 03-marker-strip "$(printf '  - Source has marker block but staged counterpart missing: .claude/hooks/x.sh\nFAIL  03-marker-strip.sh: 1 marker-bearing file(s) not stripped')"
  vhf_commit "a marker failure on the branch only"
  run_runner branch
  [ "$status" -eq 1 ]
  has_line '^FAIL  03-marker-strip \([0-9]+s\)$'
  has '.claude/hooks/x.sh'
  has '  reproduce: bash .gaia/tests/distribution/03-marker-strip.sh'
  lacks 'PRE-EXISTING'
  local base_root
  base_root="$(vhf_log_entries 03-marker-strip | grep -vxF "$VHF_ROOT")"
  [ -n "$base_root" ]
  [ ! -e "$base_root" ]
  [ "$(worktree_count)" -eq 1 ]
}

@test "push mode shows a failure main already has as pre-existing and lets the push through" {
  fixture --no-branch
  vhf_control 01-files-present "$(printf '  - Manifest claims paths missing from staging tree:\n  -   frontend/app/gone.ts\nFAIL  01-files-present.sh: 1 manifest path(s) missing from staging')"
  vhf_commit "main breaks 01"
  vhf_branch
  printf 'page two\n' >frontend/app/page.txt
  vhf_commit "an unrelated branch change"
  run_runner push "$(vhf_git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  has_line '^PRE-EXISTING  01-files-present: also fails on merge base [0-9a-f]+; main is red \([0-9]+s\)$'
  no_fail_line
  lacks 'shell-lint'
  lacks 'bats'
}

@test "push mode verifies the pushed commit in a worktree, not the dirty tree" {
  fixture
  vhf_control 03-marker-strip "  - broken in the older commit"
  vhf_commit "an older commit failing 03"
  local older_sha
  older_sha="$(vhf_git rev-parse HEAD)"
  vhf_control 03-marker-strip ""
  vhf_commit "the fix"
  vhf_control 01-files-present "  - an uncommitted edit that would fail 01"

  run_runner push "$(vhf_git rev-parse HEAD)"
  [ "$status" -eq 0 ]
  [ -n "$(vhf_log_entries 01-files-present)" ]
  vhf_log_entries 01-files-present | grep -qxF "$VHF_ROOT" && return 1
  [ "$(worktree_count)" -eq 1 ]

  : >"$VERIFY_FIXTURE_LOG"
  run_runner push "$older_sha"
  [ "$status" -eq 1 ]
  has_line '^FAIL  03-marker-strip \([0-9]+s\)$'
  has "  reproduce: git checkout --detach $older_sha && bash .gaia/tests/distribution/03-marker-strip.sh"
  vhf_log_entries 03-marker-strip | grep -qxF "$VHF_ROOT" && return 1
  [ "$(worktree_count)" -eq 1 ]
}

@test "push mode labels each check with its short sha when several commits are pushed" {
  fixture
  local first_sha second_sha
  first_sha="$(vhf_git rev-parse HEAD)"
  printf 'page two\n' >frontend/app/page.txt
  vhf_commit "a second commit"
  second_sha="$(vhf_git rev-parse HEAD)"
  run_runner push "$first_sha" "$second_sha" "$second_sha"
  [ "$status" -eq 0 ]
  has_line "^PASS  01-files-present @$(vhf_git rev-parse --short "$first_sha") \\([0-9]+s\\)$"
  has_line "^PASS  01-files-present @$(vhf_git rev-parse --short "$second_sha") \\([0-9]+s\\)$"
  [ "$(grep -c '^PASS  01-files-present' <<<"$output")" -eq 2 ]
}

@test "a branch run removes a stale pass record before it runs" {
  fixture
  mkdir -p "${VHF_RECORD%/*}"
  printf '{"schema":1,"branch":"feat/verify","head":"%s","written_at":"x","skipped":[],"preexisting":[]}\n' \
    "$(vhf_git rev-parse HEAD)" >"$VHF_RECORD"
  vhf_control 01-files-present "  - a new failure"
  vhf_commit "a failing commit"
  run_runner branch
  [ "$status" -eq 1 ]
  [ ! -e "$VHF_RECORD" ]
}

@test "the read-only helper answers match, absence, another head, corruption and a missing jq" {
  fixture
  source_pass_record_helper
  local head_sha other_sha record farm
  head_sha="$(vhf_git rev-parse HEAD)"
  other_sha="0123456789abcdef0123456789abcdef01234567"
  record="$(gaia_verify_pass_record_path "$VHF_ROOT" feat/verify)"
  [ "$record" = "$VHF_RECORD" ]

  run gaia_verify_pass_record_check "$VHF_ROOT" feat/verify "$head_sha"
  [ "$status" -eq 1 ]

  mkdir -p "${record%/*}"
  printf '{"schema":1,"branch":"feat/verify","head":"%s","written_at":"x","skipped":[],"preexisting":[]}\n' "$head_sha" >"$record"
  run gaia_verify_pass_record_check "$VHF_ROOT" feat/verify "$head_sha"
  [ "$status" -eq 0 ]

  run gaia_verify_pass_record_check "$VHF_ROOT" feat/verify "$other_sha"
  [ "$status" -eq 2 ]
  [ "$output" = "$head_sha" ]

  farm="$(vhf_path_without jq)"
  PATH="$farm" run gaia_verify_pass_record_check "$VHF_ROOT" feat/verify "$head_sha"
  [ "$status" -eq 6 ]

  local corrupt
  for corrupt in 'not json' \
    '{"schema":2,"head":"'"$head_sha"'"}' \
    '{"schema":1,"head":"not-a-sha"}' \
    '{"schema":1}' \
    '[1,2]' \
    '{"schema":1,"head":"'"$head_sha"'"} {"schema":1,"head":"'"$head_sha"'"}'; do
    printf '%s\n' "$corrupt" >"$record"
    run gaia_verify_pass_record_check "$VHF_ROOT" feat/verify "$head_sha"
    [ "$status" -eq 5 ] || { printf 'record [%s] returned %s\n' "$corrupt" "$status" >&2; return 1; }
  done
}

@test "sourcing the read-only helper defines no writer and runs nothing" {
  run env PATH=/nonexistent /bin/bash -c '. "$1" && declare -F' _ "$REPO_ROOT/.gaia/tests/helpers/verify-pass-record.sh"
  [ "$status" -eq 0 ]
  grep -qx 'declare -f gaia_verify_pass_record_check' <<<"$output"
  grep -qx 'declare -f gaia_verify_pass_record_path' <<<"$output"
  grep -qiE 'write|remove' <<<"$output" && return 1
  [ "$(grep -c '^declare -f ' <<<"$output")" -eq 2 ]
}
