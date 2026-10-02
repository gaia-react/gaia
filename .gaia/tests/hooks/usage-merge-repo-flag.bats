#!/usr/bin/env bats
#
# Bats suite for the foreign-repository half of .gaia/scripts/usage-merge.sh's
# operand scan: a `-R`/`--repo` flag, or a PR URL naming a repository other
# than the local origin's, leaves no resolvable operand, so the hook never
# reads the LOCAL repository's pull request of the same number. Split from
# usage-merge.bats to keep that suite under the file-size budget; the shared
# setup lives in helpers/usage-merge-env.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/usage-merge-repo-flag.bats

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/usage-merge-env.sh"
  # shellcheck disable=SC2034  # read by build_repo in the helper
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
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
  {
    segment_row branch:fix/foo s74 2026-09-23T09:00:00Z 400000 40000
  } >"$TELEMETRY_DIRECTORY/usage.jsonl"
  gh_view 45 45 fix/foo MERGED 2026-09-25T02:00:00Z
}

# No merge row and no pr edge for 45, no block naming it, and the local PR 45
# never read through gh.
assert_foreign_ignored() {
  [ "$status" -eq 0 ]
  lacks "pr:45"
  lacks "tokens:"
  [ ! -f "$TELEMETRY_DIRECTORY/links.jsonl" ] || [ "$(merge_rows 45)" -eq 0 ] || return 1
  [ ! -f "$TELEMETRY_DIRECTORY/links.jsonl" ] || ! grep -q '"pr:45"' "$TELEMETRY_DIRECTORY/links.jsonl" || return 1
  [ ! -f "$GH_STUB_DIRECTORY/argv.log" ] || ! grep -q 'pr view 45' "$GH_STUB_DIRECTORY/argv.log" || return 1
}

@test "a repo flag after the number leaves no resolvable operand" {
  run_merge "gh pr merge 45 --repo x/y"
  assert_foreign_ignored
}

@test "a repo flag before the number leaves no resolvable operand" {
  run_merge "gh pr merge --repo x/y 45"
  assert_foreign_ignored
}

@test "-R before the number leaves no resolvable operand" {
  run_merge "gh pr merge -R x/y 45"
  assert_foreign_ignored
}

@test "--repo=value leaves no resolvable operand" {
  run_merge "gh pr merge --repo=x/y 45"
  assert_foreign_ignored
}

@test "a PR URL for another repository leaves no resolvable operand" {
  git -C "$REPO" remote add origin https://github.com/o/r.git
  run_merge "gh pr merge https://github.com/x/y/pull/45"
  assert_foreign_ignored
}

@test "a PR URL with no origin remote counts as foreign" {
  run_merge "gh pr merge https://github.com/o/r/pull/45"
  assert_foreign_ignored
}

@test "a PR URL for the origin repository still resolves, https and ssh remotes" {
  # The stub answers a URL operand from view.json.
  cp "$GH_STUB_DIRECTORY/view-45.json" "$GH_STUB_DIRECTORY/view.json"
  git -C "$REPO" remote add origin git@github.com:O/R.git
  run_merge "gh pr merge https://github.com/o/r/pull/45"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:45 branch:fix/foo"
  [ "$(merge_rows 45)" -eq 1 ]
  git -C "$REPO" remote set-url origin https://github.com/o/r.git
  run_merge "gh pr merge https://github.com/o/r/pull/45"
  has_line "[PR cost] pr:45 branch:fix/foo"
  [ "$(merge_rows 45)" -eq 2 ]
  # The stub's view.json fallback answers an operand-less read too, so the
  # operand itself must have reached gh.
  [ "$(grep -c '^pr view https://github.com/o/r/pull/45 ' "$GH_STUB_DIRECTORY/argv.log")" -eq 2 ]
}

# ---------- A merge aimed at another repository is terminal ----------
#
# The current branch has its own pull request 12, which an operand-less
# `gh pr view` would answer. Every foreign spelling must leave that answer
# unread: no block, no merge row, no edge, no `pr view` call at all.

use_feature_branch() {
  git -C "$REPO" checkout -q -b feat/cur
  gh_view none 12 feat/cur "$1" "${2:-}"
}

# argv_has <pattern>: the gh stub's argv log holds a line matching the pattern.
argv_has() { [ -f "$GH_STUB_DIRECTORY/argv.log" ] && grep -q -- "$1" "$GH_STUB_DIRECTORY/argv.log"; }

# no_trace_of_12: neither a merge row nor a pr edge was written for PR 12.
no_trace_of_12() {
  [ -f "$TELEMETRY_DIRECTORY/links.jsonl" ] || return 0
  [ "$(merge_rows 12)" -eq 0 ] || return 1
  grep -q '"pr:12"' "$TELEMETRY_DIRECTORY/links.jsonl" && return 1
  return 0
}

assert_nothing_touched() {
  [ "$status" -eq 0 ] || return 1
  lacks "[PR cost]" || return 1
  lacks "pr:12" || return 1
  lacks "pr:45" || return 1
  if [ -f "$TELEMETRY_DIRECTORY/links.jsonl" ]; then
    [ "$(jq -s '[.[] | select(.kind == "merge")] | length' "$TELEMETRY_DIRECTORY/links.jsonl")" -eq 0 ] || return 1
    grep -q '"pr:' "$TELEMETRY_DIRECTORY/links.jsonl" && return 1
  fi
  argv_has '^pr view' && return 1
  return 0
}

foreign_spellings() {
  printf '%s\n' \
    "gh pr merge --repo x/y 45" \
    "gh pr merge 45 --repo x/y" \
    "gh pr merge -R x/y 45" \
    "gh pr merge 45 -R x/y" \
    "gh pr merge -Rx/y 45" \
    "gh pr merge --repo=x/y 45" \
    "gh pr merge --repo x/y" \
    "gh pr merge --squash --repo x/y" \
    "gh pr merge feat/cur --repo x/y" \
    "gh pr merge --repo o/r 45" \
    "gh pr merge --subject 45 --repo x/y" \
    "gh pr merge https://github.com/x/y/pull/45" \
    "gh pr merge https://github.com/x/y/pull/45 --squash"
}

run_foreign_spellings() {
  local foreign_command
  git -C "$REPO" remote add origin https://github.com/o/r.git
  while IFS= read -r foreign_command; do
    rm -f "$GH_STUB_DIRECTORY/argv.log"
    run_merge "$foreign_command"
    assert_nothing_touched || { printf 'failed for: %s\n%s\n' "$foreign_command" "$output" >&2; return 1; }
  done < <(foreign_spellings)
  # A multi-line body ahead of the flag cannot hide it.
  rm -f "$GH_STUB_DIRECTORY/argv.log"
  run_merge $'gh pr merge 45 --body "line one\nline two" --repo x/y'
  assert_nothing_touched
}

@test "a foreign merge on a feature branch with an OPEN PR 12 reads and prints nothing" {
  use_feature_branch OPEN
  run_foreign_spellings
}

@test "a foreign merge on a feature branch whose PR 12 is MERGED writes no row and no edge" {
  use_feature_branch MERGED 2026-09-25T02:00:00Z
  run_foreign_spellings
}

@test "control: no operand on a feature branch still resolves that branch's PR" {
  use_feature_branch OPEN
  run_merge "gh pr merge --squash"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:12 branch:feat/cur"
  argv_has '^pr view --json'
}

@test "control: no operand on a feature branch whose PR is MERGED records the merge" {
  use_feature_branch MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:12 branch:feat/cur"
  [ "$(merge_rows 12)" -eq 1 ]
}

@test "a branch-name operand resolves that branch's PR, never the current branch's" {
  use_feature_branch MERGED 2026-09-25T02:00:00Z
  gh_view mybranch 77 mybranch MERGED 2026-09-26T02:00:00Z
  run_merge "gh pr merge mybranch --squash"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:77 branch:mybranch"
  [ "$(merge_rows 77)" -eq 1 ]
  [ "$(merge_rows 12)" -eq 0 ]
  argv_has '^pr view mybranch '
  argv_has '^pr view --json' && return 1
  true
}

@test "a branch-name operand that gh cannot answer never falls back to the current branch" {
  use_feature_branch MERGED 2026-09-25T02:00:00Z
  run_merge "gh pr merge ghostbranch"
  [ "$status" -eq 0 ]
  lacks "pr:12"
  no_trace_of_12
  argv_has '^pr view ghostbranch '
  argv_has '^pr view --json' && return 1
  true
}

@test "an operand the scan cannot read never reads the current branch's PR" {
  use_feature_branch MERGED 2026-09-25T02:00:00Z
  run_merge 'gh pr merge $(echo 45)'
  [ "$status" -eq 0 ]
  lacks "pr:12"
  no_trace_of_12
  argv_has '^pr view' && return 1
  # A multi-line body cuts the statement inside a quote, hiding the operand.
  rm -f "$GH_STUB_DIRECTORY/argv.log"
  run_merge $'gh pr merge --body "line one\nline two" 45'
  [ "$status" -eq 0 ]
  lacks "pr:12"
  no_trace_of_12
  argv_has '^pr view' && return 1
  true
}

@test "a flag value that looks like a number never becomes the operand" {
  use_feature_branch OPEN
  local flag_spelling
  for flag_spelling in "--subject 99" "-t 99" "--body 99" "-b 99" "--match-head-commit 99" "-A 99" "--author-email 99"; do
    rm -f "$GH_STUB_DIRECTORY/argv.log"
    run_merge "gh pr merge $flag_spelling"
    [ "$status" -eq 0 ]
    has_line "[PR cost] pr:12 branch:feat/cur" || { printf 'failed for: %s\n' "$flag_spelling" >&2; return 1; }
    argv_has '^pr view 99' && return 1
    argv_has '^pr view --json' || return 1
  done
  rm -f "$GH_STUB_DIRECTORY/argv.log"
  run_merge "gh pr merge -t 99 45"
  argv_has '^pr view 45 '
  argv_has '^pr view 99' && return 1
  true
}

# ---------- a hostile branch name never reaches a runnable hint ----------

# slow_render <secs>: usage.sh becomes a stand-in whose `pr` readout sleeps
# before printing; every other subcommand runs the real script.
slow_render() {
  mv "$REPO/.gaia/scripts/usage.sh" "$REPO/.gaia/scripts/usage-real.sh"
  printf '#!/usr/bin/env bash\nif [ "${1-}" = pr ]; then sleep %s; printf "[PR cost] late\\n"; exit 0; fi\nexec bash "${BASH_SOURCE[0]%%/*}/usage-real.sh" "$@"\n' \
    "$1" >"$REPO/.gaia/scripts/usage.sh"
}

@test "an OPEN PR with a hostile headRefName prints a hashed --key and nothing shell-active" {
  gh_view 108 108 'x$(touch pwn)' OPEN ""
  run_merge "gh pr merge 108"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/pwn" ]
  lacks '$('
  lacks 'touch'
  grep -Eq 'link --merge 108 --key branch:%[0-9a-f]{16}\)$' <<<"$output"
}

@test "a hostile name with shell metacharacters is never printed raw" {
  gh_view 108 108 'x;rm-rf' OPEN ""
  run_merge "gh pr merge 108"
  [ "$status" -eq 0 ]
  lacks 'rm-rf'
  grep -Eq 'link --merge 108 --(key branch:%[0-9a-f]{16}|branch <branch>)\)$' <<<"$output"
}

@test "the render-timeout rerun line for a hostile current branch names a hashed key" {
  git -C "$REPO" checkout -q -b 'x$(touch-pwn)'
  slow_render 8
  export GAIA_USAGE_RENDER_CAP_SECONDS=1
  run_merge "gh pr merge"
  [ "$status" -eq 0 ]
  [ ! -e "$REPO/pwn" ]
  lacks '$('
  grep -Eqx '! readout timed out after 1s; rerun: bash \.gaia/scripts/usage\.sh pr --key branch:%[0-9a-f]{16}' <<<"$output"
}

@test "a safe branch still prints a usable recovery command" {
  gh_view 109 109 fix/foo OPEN ""
  run_merge "gh pr merge 109"
  [ "$status" -eq 0 ]
  grep -qF 'link --merge 109 --key branch:fix/foo)' <<<"$output"
}

@test "guards-must-fail: copies of the hint sites that print the raw branch leak a hostile name" {
  gh_view 108 108 'x$(touch pwn)' OPEN ""
  sed -i.bak 's|^    if \[\[ \$key =~ .*|    if false; then rerun_flags=""|; s|^    elif \[\[ \$raw_branch =~ .*|    elif true; then rerun_flags="--branch $raw_branch"|' "$REPO/.gaia/scripts/usage-render-lib.sh"
  grep -q 'elif true' "$REPO/.gaia/scripts/usage-render-lib.sh"
  run_merge "gh pr merge 108"
  grep -qF -- '--branch x$(touch pwn)' <<<"$output"

  cp "$SOURCE_ROOT/.gaia/scripts/usage-render-lib.sh" "$REPO/.gaia/scripts/usage-render-lib.sh"
  git -C "$REPO" checkout -q -b 'x$(touch-pwn)'
  slow_render 8
  export GAIA_USAGE_RENDER_CAP_SECONDS=1
  sed -i.bak 's|^    if \[\[ \$rerun_key =~ .*|    if false; then rerun_flags=""|; s|^    elif \[\[ \$branch =~ .*|    elif true; then rerun_flags="--branch $branch"|' "$REPO/.gaia/scripts/usage-merge.sh"
  grep -q 'elif true' "$REPO/.gaia/scripts/usage-merge.sh"
  run_merge "gh pr merge"
  grep -qF -- '--branch x$(touch-pwn)' <<<"$output"
}
