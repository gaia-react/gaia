#!/usr/bin/env bats
#
# Bats suite for .claude/hooks/pr-merge-cost.sh, the PostToolUse hook on
# `gh pr merge`: arming, the jq-absent marker, the unavailable marker when
# usage-merge.sh fails, the hard error on a missing library, and the per-PR
# block passing through. The block's own contents are usage-merge.bats's and
# usage-merge-audit-line.bats's.
#
# Every test builds a tmp git repo holding copies of the hook, the libraries it
# sources and the usage scripts at their repo-relative paths (the shared
# helpers/usage-merge-env.sh), so the hook runs with cwd = that repo and never
# reads the live telemetry. Arming cases swap usage-merge.sh for a stub that
# prints one fixed line, so a printed line means the hook armed.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/pr-merge-cost.bats

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/usage-merge-env.sh"
  # shellcheck disable=SC2034  # read by build_repo in the helper
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  HOOK_SOURCE="$SOURCE_ROOT/.claude/hooks/pr-merge-cost.sh"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state" GAIA_RATES_FEED_DISABLE=1
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECONDS GAIA_USAGE_MERGE_CAP_SECONDS GAIA_USAGE_RENDER_CAP_SECONDS
  export GAIA_LEDGER_LOCK_POLL_SECONDS=0.1
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  GH_STUB_DIRECTORY="$TEMPORARY_DIRECTORY/ghstub"
  mkdir -p "$GH_STUB_DIRECTORY" "$TEMPORARY_DIRECTORY/bin"
  export GH_STUB_DIRECTORY
  make_stubs
  export PATH="$TEMPORARY_DIRECTORY/bin:$PATH"
  build_repo
}

# stub_usage_merge <exit-code>: usage-merge.sh prints one fixed line, then exits.
stub_usage_merge() {
  printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf "STUB BLOCK\\n"\nexit %s\n' "$1" >"$REPO/.gaia/scripts/usage-merge.sh"
}

# run_hook_split <command>: the real hook with stdout and stderr kept apart.
run_hook_split() {
  run --separate-stderr bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "$1")" "$REPO/.claude/hooks/pr-merge-cost.sh"
}

# run_nojq <hook> <command>: the hook under a PATH that carries cat and grep
# and no jq.
run_nojq() {
  local directory="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$directory"
  ln -sf "$(command -v cat)" "$directory/cat"
  ln -sf "$(command -v grep)" "$directory/grep"
  run bash -c 'printf %s "$1" | PATH="$2" /bin/bash "$3"' _ "$(payload_for "$2")" "$directory" "$1"
}

@test "the hook file is executable" {
  [ -x "$HOOK_SOURCE" ]
}

@test "an armed merge prints the per-PR block the real usage-merge.sh renders, and never a cycle roll-up" {
  {
    segment_row branch:fix/foo s74 2026-09-23T09:00:00Z 400000 40000
  } >"$TELEMETRY_DIRECTORY/usage.jsonl"
  gh_view 103 103 fix/foo MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge 103 --squash"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:103 branch:fix/foo"
  has_line "  tokens: 440,000 (fresh 400,000, cache write 0, cache read 0, output 40,000)"
  lacks "[cycle cost at merge]"
}

@test "non-merge commands print nothing and exit 0" {
  stub_usage_merge 0
  run_merge "git commit -m x"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_merge "gh pr view 7"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a payload that is not JSON prints nothing and exits 0" {
  stub_usage_merge 0
  run bash -c 'cd "$1" && printf %s "not json" | bash "$2"' _ "$REPO" "$REPO/.claude/hooks/pr-merge-cost.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a merge aimed at another repository does nothing: no gh read, no output" {
  gh_view 45 45 fix/foo MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge 45 --repo other/project"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$GH_STUB_DIRECTORY/argv.log" ]
}

@test "gh pr merge mentioned only inside heredoc body prose: not matched" {
  stub_usage_merge 0
  run_merge $'cat <<EOF\nPlease remember to gh pr merge later.\nEOF'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gh pr merge mentioned inside a quoted string: not matched" {
  stub_usage_merge 0
  run_merge 'echo "remember to gh pr merge later"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the positive control arms, the heredoc-body payload does not, and the same payload past the arming bound arms again" {
  stub_usage_merge 0
  run_merge "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  has_line "STUB BLOCK"

  run_merge $'cat > /tmp/notes.txt <<EOF\ngh pr merge 7\nEOF'
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local pad over_limit_command
  pad=$(printf 'x%.0s' $(seq 1 16400))
  over_limit_command=$'cat > /tmp/notes.txt <<EOF\n'"$pad"$'\ngh pr merge 7\nEOF'
  [ "${#over_limit_command}" -gt 16384 ] || return 1
  run_merge "$over_limit_command"
  [ "$status" -eq 0 ]
  has_line "STUB BLOCK"
}

@test "a quoted verb in the first command and a multi-statement command both arm" {
  stub_usage_merge 0
  run_merge 'gh pr "merge" 7'
  [ "$status" -eq 0 ]
  has_line "STUB BLOCK"
  run_merge "echo start && gh pr merge 7"
  [ "$status" -eq 0 ]
  has_line "STUB BLOCK"
}

@test "a usage-merge.sh that exits 3 yields exactly one unavailable line naming the rerun command" {
  stub_usage_merge 3
  run_merge "gh pr merge 7 --squash"
  [ "$status" -eq 0 ]
  has_line "STUB BLOCK"
  [ "$(grep -c '^\[PR cost\] unavailable' <<<"$output")" -eq 1 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 3; rerun: bash .gaia/scripts/usage.sh pr 7"
}

@test "the unavailable line names the current branch when the command carries no number, and a placeholder for a hostile branch name" {
  stub_usage_merge 3
  git -C "$REPO" checkout -q -b fix/numberless
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 3; rerun: bash .gaia/scripts/usage.sh pr --branch fix/numberless"
  git -C "$REPO" checkout -q -b 'fix/a;touch$IFS/pwn'
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  has_line "[PR cost] unavailable: usage-merge.sh exited 3; rerun: bash .gaia/scripts/usage.sh pr --branch <branch>"
  [ ! -e "$REPO/pwn" ]
}

@test "a missing hook-payload.sh exits non-zero and stderr names it" {
  rm "$REPO/.claude/hooks/lib/hook-payload.sh"
  run_hook_split "gh pr merge 7"
  [ "$status" -ne 0 ]
  grep -qF "hook-payload.sh" <<<"$stderr"
}

@test "a missing verb-arming.sh exits non-zero and stderr names it" {
  rm "$REPO/.claude/hooks/lib/verb-arming.sh"
  run_hook_split "gh pr merge 7"
  [ "$status" -ne 0 ]
  grep -qF "verb-arming.sh" <<<"$stderr"
}

@test "jq absent: an armed merge prints the inactive marker and exits 0; a non-merge prints nothing" {
  run_nojq "$REPO/.claude/hooks/pr-merge-cost.sh" "gh pr merge 101"
  [ "$status" -eq 0 ]
  [ "$output" = "usage tracking inactive: jq not found" ]
  run_nojq "$REPO/.claude/hooks/pr-merge-cost.sh" "gh pr view 101"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guards-must-fail: a copy of the hook without the raw-grep branch stays silent for the same merge payload" {
  local mutant="$BATS_TEST_TMPDIR/hook-noraw.sh"
  sed 's/^  if grep -Eq .*<<<"$payload"; then$/  if false; then/' "$REPO/.claude/hooks/pr-merge-cost.sh" >"$mutant"
  cmp -s "$REPO/.claude/hooks/pr-merge-cost.sh" "$mutant" && return 1
  run_nojq "$mutant" "gh pr merge 101"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guards-must-fail: a copy of the hook that never prints the unavailable marker stays silent when usage-merge.sh fails" {
  stub_usage_merge 3
  sed '/unavailable: usage-merge.sh exited/d' "$REPO/.claude/hooks/pr-merge-cost.sh" >"$REPO/.claude/hooks/pr-merge-cost-mutant.sh"
  cmp -s "$REPO/.claude/hooks/pr-merge-cost.sh" "$REPO/.claude/hooks/pr-merge-cost-mutant.sh" && return 1
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$(payload_for "gh pr merge 7")" "$REPO/.claude/hooks/pr-merge-cost-mutant.sh"
  [ "$status" -eq 0 ]
  grep -qF "unavailable" <<<"$output" && return 1
  true
}
