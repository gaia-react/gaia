#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/branch-name-lib.sh, the single owner of
# how GAIA names the branches it creates and how a branch name is read back.
#
# What it proves, in the section order below:
#   1. source-time purity, no side effects and no external command
#   2. the worktree spelling normalizes back to the requested name
#   3. the convention table, every row, in both spellings
#   4. the retired spellings no longer classify as GAIA work
#   5. members and spec-number, the two readers built on the table
#   6. minting: every kind, its argument errors, and the 64-byte cap
#   7. round trip: every minted name reads back as its own kind
#   8. branch listing across local and remote-tracking refs
#   9. lockstep: the kinds minted outside bash still carry the table's prefix
#  10. no creation site spells a GAIA branch literal instead of minting it
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/branch-name-lib.bats
#
# Every expected value is a literal, so a regression in the derivation cannot
# be mirrored by the assertion that checks it.

bats_require_minimum_version 1.5.0

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/branch-name-lib.sh"
  REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  # shellcheck disable=SC1090
  source "$LIB"
}

# expect_classify <branch> <mode unit>
expect_classify() {
  local got
  got="$(gaia_branch_classify "$1")"
  [ "$got" = "$2" ] || {
    printf "classify '%s': got '%s', want '%s'\n" "$1" "$got" "$2" >&2
    return 1
  }
}

# worktree_spelling <name>: the branch EnterWorktree({name}) puts a worktree on.
worktree_spelling() {
  local n="$1"
  printf 'worktree-%s' "${n//\//+}"
}

# ========== 1. source-time purity ==========

@test "sourcing has no side effects: succeeds under set -u with PATH empty outside a repository" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIB' && echo sourced-ok"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced-ok" ]
  [ -z "$(ls -A "$scratch")" ]
}

# ========== 2. worktree normalization ==========

@test "normalize strips one worktree- prefix and turns every + into /" {
  [ "$(gaia_branch_normalize "worktree-debt+42-fix")" = "debt/42-fix" ]
  [ "$(gaia_branch_normalize "worktree-gaia-ci+tool+x")" = "gaia-ci/tool/x" ]
  [ "$(gaia_branch_normalize "worktree-worktree-a")" = "worktree-a" ]
  [ "$(gaia_branch_normalize "debt/42-fix")" = "debt/42-fix" ]
}

# ========== 3. the convention table ==========

@test "table: every row yields its own mode and unit, in the plain and the worktree spelling" {
  local row branch want
  for row in \
    "debt/41-42-47-batch|drain 41-42-47" \
    "debt/2159-reconcile-worktree-claim|drain 2159" \
    "debt/2159|drain 2159" \
    "debt/no-number|drain unknown" \
    "debt/12-foo-batch|drain 12" \
    "plan/spec-005-cards-layout|plan SPEC-005" \
    "plan/spec-005|plan SPEC-005" \
    "plan/plan-012-execution|plan plan-012" \
    "plan/cards-layout|plan unknown" \
    "chore/update-deps-2026-09-20-1200|maintenance update-deps-2026-09-20-1200" \
    "release/v1.4.0|maintenance v1.4.0" \
    "wiki-sync/2026-09-20-abc1234|maintenance 2026-09-20-abc1234" \
    "gaia-ci/pnpm-audit/20260920-120000|maintenance pnpm-audit/20260920-120000" \
    "main|adhoc unknown" \
    "fix/some-thing|adhoc unknown" \
    "feat/new-thing|adhoc unknown" \
    "docs/readme|adhoc unknown"; do
    branch="${row%%|*}"
    want="${row#*|}"
    expect_classify "$branch" "$want"
    expect_classify "$(worktree_spelling "$branch")" "$want"
  done
}

@test "table: mode never leaves the closed vocabulary, and classify never fails" {
  local b mode
  for b in "" "-" "/" "debt/" "plan/" "chore/" "a+b" "worktree-" "日本/語"; do
    run gaia_branch_classify "$b"
    [ "$status" -eq 0 ]
    mode="${output%% *}"
    case "$mode" in
      drain | plan | maintenance | adhoc) ;;
      *)
        echo "branch '$b': mode '$mode' is outside the vocabulary" >&2
        return 1
        ;;
    esac
  done
}

# ========== 4. retired spellings ==========

@test "retired spellings classify as adhoc: GAIA no longer mints them" {
  local b
  for b in spec-005-cards plan-012 chore-deps harden/marker harden-marker audit-roster; do
    expect_classify "$b" "adhoc unknown"
  done
}

# ========== 5. readers built on the table ==========

@test "members: a single, a batch, and a worktree batch print their issues, anything else prints nothing" {
  [ "$(gaia_branch_members "debt/2159-slug")" = "2159" ]
  [ "$(gaia_branch_members "debt/41-42-47-batch" | tr '\n' ' ')" = "41 42 47 " ]
  [ "$(gaia_branch_members "worktree-debt+41-42-batch" | tr '\n' ' ')" = "41 42 " ]
  [ -z "$(gaia_branch_members "debt/no-number")" ]
  [ -z "$(gaia_branch_members "plan/spec-005-x")" ]
  [ -z "$(gaia_branch_members "main")" ]
}

@test "spec-number: a SPEC plan branch prints its number without padding, anything else prints nothing" {
  [ "$(gaia_branch_spec_number "plan/spec-005-x")" = "5" ]
  [ "$(gaia_branch_spec_number "worktree-plan+spec-120")" = "120" ]
  [ "$(gaia_branch_spec_number "plan/spec-000")" = "0" ]
  [ -z "$(gaia_branch_spec_number "plan/plan-012-x")" ]
  [ -z "$(gaia_branch_spec_number "spec-005-x")" ]
}

# ========== 6. minting ==========

@test "name: each kind mints its canonical shape" {
  [ "$(gaia_branch_name debt 2159 --slug "Reconcile: worktree CLAIM!")" = "debt/2159-reconcile-worktree-claim" ]
  [ "$(gaia_branch_name debt "#2159")" = "debt/2159" ]
  [ "$(gaia_branch_name debt 47 42 045)" = "debt/42-45-47-batch" ]
  [ "$(gaia_branch_name debt 42 42 --slug x)" = "debt/42-x" ]
  [ "$(gaia_branch_name plan SPEC-005 --slug "Cards layout")" = "plan/spec-005-cards-layout" ]
  [ "$(gaia_branch_name plan plan-012)" = "plan/plan-012" ]
  [ "$(gaia_branch_name release v1.4.0)" = "release/v1.4.0" ]
  [ "$(gaia_branch_name release 2.0.0-rc.1)" = "release/v2.0.0-rc.1" ]
}

@test "name: chore appends a UTC minute stamp" {
  run gaia_branch_name chore "Update deps"
  [ "$status" -eq 0 ]
  grep -qE '^chore/update-deps-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$' <<<"$output"
}

@test "name: a long slug is cut to keep the name within 64 bytes, never ending in a dash" {
  local long name
  long="$(printf 'word-%.0s' $(seq 30))"
  name="$(gaia_branch_name debt 12345 --slug "$long")"
  [ "${#name}" -le 64 ]
  case "$name" in *-) return 1 ;; esac
  grep -qE '^debt/12345-[a-z-]*[a-z]$' <<<"$name"
}

@test "name: every minted name is a valid EnterWorktree name" {
  local n
  for n in "$(gaia_branch_name debt 1 --slug "a b")" "$(gaia_branch_name debt 3 1 2)" \
    "$(gaia_branch_name plan spec-9 --slug z)" "$(gaia_branch_name chore t)" \
    "$(gaia_branch_name release 1.0.0)"; do
    [ "${#n}" -le 64 ]
    grep -qE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' <<<"$n"
  done
}

@test "name: a bad argument exits 2 with nothing on stdout and a reason on stderr" {
  local args
  for args in "" "bogus" "debt" "debt abc" "debt 1 --slug" "plan" "plan spec-x" \
    "plan feat-1" "plan spec-1 extra" "chore" "chore !!!" "release" "release 1.0+b"; do
    # shellcheck disable=SC2086
    run --separate-stderr gaia_branch_name $args
    [ "$status" -eq 2 ] || { echo "args '$args': status $status" >&2; return 1; }
    [ -z "$output" ] || { echo "args '$args': stdout '$output'" >&2; return 1; }
    grep -qF 'gaia_branch_name:' <<<"$stderr"
  done
}

@test "name: a batch too wide for 64 bytes is refused rather than cut" {
  run --separate-stderr gaia_branch_name debt 10001 10002 10003 10004 10005 10006 10007 10008 10009 10010 10011
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'longer than 64 bytes' <<<"$stderr"
}

# ========== 7. round trip ==========

@test "round trip: every minted name classifies as its kind, and so does its worktree spelling" {
  local row name want
  for row in \
    "debt 2159 --slug fix-it|drain 2159" \
    "debt 3 1 2|drain 1-2-3" \
    "plan spec-005 --slug cards|plan SPEC-005" \
    "plan plan-012|plan plan-012" \
    "release 1.4.0|maintenance v1.4.0"; do
    # shellcheck disable=SC2086
    name="$(gaia_branch_name ${row%%|*})"
    want="${row#*|}"
    expect_classify "$name" "$want"
    expect_classify "$(worktree_spelling "$name")" "$want"
  done
  name="$(gaia_branch_name chore update-deps)"
  [ "$(gaia_branch_classify "$(worktree_spelling "$name")" | cut -d' ' -f1)" = "maintenance" ]
}

# ========== 8. listing ==========

@test "list: local and remote-tracking branches, remote prefix dropped, symbolic HEAD skipped" {
  local repo="$BATS_TEST_TMPDIR/repo"
  git init -q --initial-branch=main "$repo"
  git -C "$repo" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  git -C "$repo" branch "worktree-debt+7-x"
  git -C "$repo" update-ref refs/remotes/origin/debt/8-y HEAD
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run gaia_branch_list "$repo"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | LC_ALL=C sort | tr '\n' ' ')" = "debt/8-y main main worktree-debt+7-x " ]
}

@test "list: outside a repository prints nothing and returns 0" {
  run gaia_branch_list "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ========== 9. lockstep with the kinds minted outside bash ==========

@test "lockstep: the CLI still mints wiki-sync/ and the CI templates still mint gaia-ci/" {
  grep -qF "const WIKI_CHAIN_BRANCH_PREFIX = 'wiki-sync/';" "$REPO_ROOT/.gaia/cli/src/wiki/chain.ts"
  grep -qF 'const branchName = `wiki-sync/${' "$REPO_ROOT/.gaia/cli/src/wiki/sync-land.ts"
  local tmpl
  for tmpl in \
    .gaia/cli/src/automation/templates/workflows/partials/auto-merge.yml.tmpl \
    .gaia/cli/src/automation/templates/workflows/gaia-ci-pnpm-audit.yml.tmpl; do
    grep -qE 'branch="gaia-ci/\{\{tool_id\}\}/' "$REPO_ROOT/$tmpl" \
      || { echo "$tmpl no longer mints gaia-ci/{{tool_id}}/" >&2; return 1; }
  done
  expect_classify "wiki-sync/2026-09-20-abc1234" "maintenance 2026-09-20-abc1234"
  expect_classify "gaia-ci/t/x" "maintenance t/x"
}

# ========== 10. creation sites mint through the library ==========

@test "no instruction surface spells a GAIA branch literal for git to create" {
  # Every flow that cuts a branch takes its name from gaia_branch_name, so a
  # literal `checkout -b chore/...` (or `switch -c`, or a hand-assembled
  # BRANCH= value) is a second copy of the convention waiting to drift.
  local hits
  hits="$(git -C "$REPO_ROOT" grep -nE \
    -e '(checkout -b|switch -c|branch -[mM]) +"?(debt|plan|chore|release|spec|harden|audit)[-/]' \
    -e 'BRANCH="(debt|plan|chore|release)/' \
    -- .claude .specify ':!**/*.bats' || true)"
  [ -z "$hits" ] || {
    printf 'branch literals outside the library:\n%s\n' "$hits" >&2
    return 1
  }
}

@test "the no-literal guard can fail: a planted literal is reported" {
  local repo="$BATS_TEST_TMPDIR/planted"
  mkdir -p "$repo/.claude"
  git init -q "$repo"
  printf 'git checkout -b chore/update-deps-now\n' >"$repo/.claude/x.md"
  git -C "$repo" add .claude/x.md
  run git -C "$repo" grep -nE \
    -e '(checkout -b|switch -c|branch -[mM]) +"?(debt|plan|chore|release|spec|harden|audit)[-/]' \
    -- .claude
  [ "$status" -eq 0 ]
  grep -qF '.claude/x.md:1:' <<<"$output"
}

# ========== structural hygiene ==========

@test "portability: the readers agree under zsh, where zsh exists" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  run zsh -c "source '$LIB'; gaia_branch_classify worktree-debt+41-42-batch; gaia_branch_members worktree-debt+41-42-batch; gaia_branch_spec_number plan/spec-007-x"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "drain 41-42 41 42 7 " ]
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$LIB"
}

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  local code_lines
  code_lines="$(grep -vE '^[[:space:]]*#' "$LIB")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  true
}
