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
#   7. round trip: every minted name reads back as its own kind and validates
#   8. branch listing across local and remote-tracking refs, fail-open on an
#      unreadable ref store
#   9. lockstep: the kinds minted outside bash still carry the table's prefix
#  10. no creation site spells a GAIA branch literal instead of minting it
#  11. validate: what it accepts, what it refuses, and that it never fails open
#  12. every `name <kind>` call in the instruction surface mints
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/branch-name-lib.bats
#
# Every expected value is a literal, so a regression in the derivation cannot
# be mirrored by the assertion that checks it.

bats_require_minimum_version 1.5.0

setup() {
  LIBRARY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/branch-name-lib.sh"
  REPO_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
  # shellcheck disable=SC1090
  source "$LIBRARY"
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
  local name="$1"
  printf 'worktree-%s' "${name//\//+}"
}

# ========== 1. source-time purity ==========

@test "sourcing has no side effects: succeeds under set -u with PATH empty outside a repository" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIBRARY' && echo sourced-ok"
  [ "$status" -eq 0 ]
  [ "$output" = "sourced-ok" ]
  [ -z "$(ls -A "$scratch")" ]
}

# ========== 2. worktree normalization ==========

@test "normalize strips one worktree- prefix and turns every + into /" {
  [ "$(gaia_branch_normalize "worktree-debt+42-fix")" = "debt/42-fix" ]
  [ "$(gaia_branch_normalize "worktree-fix+tool+x")" = "fix/tool/x" ]
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
    "feat/plan-024-x|plan plan-024" \
    "feat/plan-024|plan plan-024" \
    "fix/spec-012|plan SPEC-012" \
    "docs/spec-007-cards|plan SPEC-007" \
    "wiki/spec-003-notes|plan SPEC-003" \
    "feat/planning-notes|adhoc unknown" \
    "feat/plan-x|adhoc unknown" \
    "feat/spec-|adhoc unknown" \
    "feat/a/spec-1|adhoc unknown" \
    "Feat/plan-1|adhoc unknown" \
    "audit/plan-1|maintenance plan-1" \
    "debt/spec-1|drain unknown" \
    "audit/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "harden/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "fitness/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "residue/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "deps/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "update/v2.0.0-2026-10-03-1200|maintenance v2.0.0-2026-10-03-1200" \
    "release/v1.4.0|maintenance v1.4.0" \
    "wiki/sync-2026-09-20-abc1234|maintenance sync-2026-09-20-abc1234" \
    "forensics/123-some-class|maintenance 123-some-class" \
    "chore/update-deps-2026-09-20-1200|maintenance update-deps-2026-09-20-1200" \
    "wiki-sync/2026-09-20-abc1234|maintenance 2026-09-20-abc1234" \
    "chore/fix-typo|adhoc unknown" \
    "wiki/notes|adhoc unknown" \
    "wiki/2026-10-03-14-30|adhoc unknown" \
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

@test "table: a type-prefixed plan branch classifies exactly as the legacy plan/ spelling of the same unit" {
  local pair
  for pair in "feat/plan-024-x plan/plan-024-x" "fix/spec-012 plan/spec-012" "docs/spec-007-cards plan/spec-007-cards" \
    "refactor/plan-5 plan/plan-5"; do
    [ "$(gaia_branch_classify "${pair%% *}")" = "$(gaia_branch_classify "${pair#* }")" ] || {
      echo "pair '$pair' classifies differently" >&2
      return 1
    }
  done
}

@test "the type-prefixed plan arm can fail: a lib without it classifies feat/plan-024-x as adhoc" {
  local scratch_library="$BATS_TEST_TMPDIR/branch-name-lib-no-plan-arm.sh"
  sed 's#^    \[a-z\]\*/spec-\* | \[a-z\]\*/plan-\*)$#    zz-never-matches/*)#' "$LIBRARY" >"$scratch_library"
  cmp -s "$LIBRARY" "$scratch_library" && return 1
  run bash -c ". '$scratch_library' && gaia_branch_classify feat/plan-024-x"
  [ "$status" -eq 0 ]
  [ "$output" = "adhoc unknown" ]
}

@test "table: mode never leaves the closed vocabulary, and classify never fails" {
  local branch mode
  for branch in "" "-" "/" "debt/" "plan/" "chore/" "a+b" "worktree-" "日本/語"; do
    run gaia_branch_classify "$branch"
    [ "$status" -eq 0 ]
    mode="${output%% *}"
    case "$mode" in
      drain | plan | maintenance | adhoc) ;;
      *)
        echo "branch '$branch': mode '$mode' is outside the vocabulary" >&2
        return 1
        ;;
    esac
  done
}

# ========== 4. retired spellings ==========

@test "retired spellings classify as adhoc: GAIA no longer mints them" {
  local branch
  for branch in spec-005-cards plan-012 chore-deps harden-marker audit-roster; do
    expect_classify "$branch" "adhoc unknown"
  done
}

# ========== 5. readers built on the table ==========

@test "members: a single, a batch, and a worktree batch print their issues, anything else prints nothing" {
  [ "$(gaia_branch_members "debt/2159-slug")" = "2159" ]
  [ "$(gaia_branch_members "debt/41-42-47-batch" | tr '\n' ' ')" = "41 42 47 " ]
  [ "$(gaia_branch_members "worktree-debt+41-42-batch" | tr '\n' ' ')" = "41 42 " ]
  [ -z "$(gaia_branch_members "debt/no-number")" ]
  [ -z "$(gaia_branch_members "plan/spec-005-x")" ]
  [ -z "$(gaia_branch_members "feat/plan-024-x")" ]
  [ -z "$(gaia_branch_members "worktree-fix+spec-012-x")" ]
  [ -z "$(gaia_branch_members "main")" ]
}

@test "spec-number: a SPEC plan branch prints its number without padding, anything else prints nothing" {
  [ "$(gaia_branch_spec_number "plan/spec-005-x")" = "5" ]
  [ "$(gaia_branch_spec_number "worktree-plan+spec-120")" = "120" ]
  [ "$(gaia_branch_spec_number "plan/spec-000")" = "0" ]
  [ -z "$(gaia_branch_spec_number "plan/plan-012-x")" ]
  [ -z "$(gaia_branch_spec_number "spec-005-x")" ]
}

@test "spec-number: a type-prefixed SPEC plan branch prints its number, a type-prefixed plan-NNN branch prints nothing" {
  [ "$(gaia_branch_spec_number "refactor/spec-005-x")" = "5" ]
  [ "$(gaia_branch_spec_number "docs/spec-007-cards")" = "7" ]
  [ "$(gaia_branch_spec_number "worktree-fix+spec-012-x")" = "12" ]
  [ "$(gaia_branch_spec_number "plan/spec-005-x")" = "5" ]
  [ -z "$(gaia_branch_spec_number "feat/plan-024-x")" ]
  [ -z "$(gaia_branch_spec_number "feat/spec-notes")" ]
}

# plan_type_in <library> <branch>: the plan-type output of the library copy at <library>.
plan_type_in() {
  run bash -c ". '$1' && gaia_branch_plan_type '$2'"
}

@test "plan-type: a type-prefixed plan branch prints its type, in either spelling" {
  [ "$(gaia_branch_plan_type "feat/plan-024-x")" = "feat" ]
  [ "$(gaia_branch_plan_type "fix/spec-012")" = "fix" ]
  [ "$(gaia_branch_plan_type "docs/spec-007-cards")" = "docs" ]
  [ "$(gaia_branch_plan_type "worktree-fix+spec-012-x")" = "fix" ]
  [ "$(bash "$LIBRARY" plan-type feat/plan-024-x)" = "feat" ]
}

@test "plan-type: legacy plan/ branches, hand-named branches, workflow branches and non-plan names print nothing" {
  local branch
  for branch in plan/plan-023-conventional-commits-naming plan/spec-005-x worktree-plan+spec-005 feat/planning-notes \
    feat/new-thing debt/12-spec-1 audit/plan-1 release/v1.0.0 main ""; do
    run gaia_branch_plan_type "$branch"
    [ "$status" -eq 0 ] || { echo "branch '$branch': status $status" >&2; return 1; }
    [ -z "$output" ] || { echo "branch '$branch': printed '$output'" >&2; return 1; }
  done
}

@test "the plan-type test can fail: a lib that prints nothing for a type-prefixed plan branch is reported" {
  local scratch_library="$BATS_TEST_TMPDIR/branch-name-lib-no-plan-type.sh"
  sed 's#^  \[ "\$_gaia_branch_mode" = "plan" \] || return 0$#  return 0#' "$LIBRARY" >"$scratch_library"
  cmp -s "$LIBRARY" "$scratch_library" && return 1
  plan_type_in "$scratch_library" feat/plan-024-x
  [ "$status" -eq 0 ]
  [ "$output" != "feat" ]
}

@test "the plan-type legacy exclusion can fail: a lib that drops it prints plan for plan/spec-005-x" {
  local scratch_library="$BATS_TEST_TMPDIR/branch-name-lib-legacy-type.sh"
  plan_type_in "$LIBRARY" plan/spec-005-x
  [ -z "$output" ]
  sed 's#^  \[ "\${_gaia_branch_normalized_name%%/\*}" != "plan" \] || return 0$#  :#' "$LIBRARY" >"$scratch_library"
  cmp -s "$LIBRARY" "$scratch_library" && return 1
  plan_type_in "$scratch_library" plan/spec-005-x
  [ "$output" = "plan" ]
}

# ========== 6. minting ==========

@test "name: each kind mints its canonical shape" {
  [ "$(gaia_branch_name debt 2159 --slug "Reconcile: worktree CLAIM!")" = "debt/2159-reconcile-worktree-claim" ]
  [ "$(gaia_branch_name debt "#2159")" = "debt/2159" ]
  [ "$(gaia_branch_name debt 47 42 045)" = "debt/42-45-47-batch" ]
  [ "$(gaia_branch_name debt 42 42 --slug x)" = "debt/42-x" ]
  [ "$(gaia_branch_name plan SPEC-005 --type feat --slug "Cards layout")" = "feat/spec-005-cards-layout" ]
  [ "$(gaia_branch_name plan plan-012 --type docs)" = "docs/plan-012" ]
  [ "$(gaia_branch_name plan plan-024 --type feat --slug "type prefixed plans")" = "feat/plan-024-type-prefixed-plans" ]
  [ "$(gaia_branch_name plan spec-012 --slug x --type fix)" = "fix/spec-012-x" ]
  [ "$(gaia_branch_name release v1.4.0)" = "release/v1.4.0" ]
  [ "$(gaia_branch_name release 2.0.0-rc.1)" = "release/v2.0.0-rc.1" ]
}

@test "name: each argument-free maintenance kind appends a UTC minute stamp" {
  local kind
  for kind in audit harden fitness residue deps; do
    run --separate-stderr gaia_branch_name "$kind"
    [ "$status" -eq 0 ] || { echo "kind '$kind': status $status" >&2; return 1; }
    grep -qE "^${kind}/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}\$" <<<"$output" || {
      echo "kind '$kind': minted '$output'" >&2
      return 1
    }
  done
}

@test "name: update mints the version and a UTC minute stamp, with or without the leading v" {
  run gaia_branch_name update v2.0.0
  [ "$status" -eq 0 ]
  grep -qE '^update/v2\.0\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$' <<<"$output"
  run gaia_branch_name update 2.0.0
  [ "$status" -eq 0 ]
  grep -qE '^update/v2\.0\.0-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$' <<<"$output"
}

@test "name: update without a version exits 2" {
  run --separate-stderr gaia_branch_name update ''
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'gaia_branch_name:' <<<"$stderr"
}

@test "name: the retired chore kind exits 2 as an unknown kind with nothing on stdout" {
  run --separate-stderr gaia_branch_name chore x
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'unknown kind' <<<"$stderr"
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
  local minted_name
  for minted_name in "$(gaia_branch_name debt 1 --slug "a b")" "$(gaia_branch_name debt 3 1 2)" \
    "$(gaia_branch_name plan spec-9 --type fix --slug z)" "$(gaia_branch_name deps)" \
    "$(gaia_branch_name update v1.0.0)" "$(gaia_branch_name release 1.0.0)"; do
    [ "${#minted_name}" -le 64 ]
    grep -qE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' <<<"$minted_name"
  done
}

@test "name: a bad argument exits 2 with nothing on stdout and a reason on stderr" {
  local args
  for args in "" "bogus" "debt" "debt abc" "debt 1 --slug" "plan" "plan spec-x" \
    "plan feat-1 --type feat" "plan spec-1" "plan spec-1 --type" "plan spec-1 --type feat extra" "plan --type feat" "chore" "chore x" "audit extra" "harden extra" "fitness extra" \
    "residue extra" "deps extra" "update" "update 1.0+b" "release" "release 1.0+b"; do
    # shellcheck disable=SC2086
    run --separate-stderr gaia_branch_name $args
    [ "$status" -eq 2 ] || { echo "args '$args': status $status" >&2; return 1; }
    [ -z "$output" ] || { echo "args '$args': stdout '$output'" >&2; return 1; }
    grep -qF 'gaia_branch_name:' <<<"$stderr"
  done
}

@test "name: plan takes --type and --slug in either order" {
  [ "$(gaia_branch_name plan plan-024 --type feat --slug a-b)" = "feat/plan-024-a-b" ]
  [ "$(gaia_branch_name plan plan-024 --slug a-b --type feat)" = "feat/plan-024-a-b" ]
}

@test "name: plan without --type exits 2 with a usage line naming --type" {
  run --separate-stderr gaia_branch_name plan plan-024 --slug x
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF -- '--type' <<<"$stderr"
  grep -qF 'needs --type' <<<"$stderr"
}

@test "name: plan refuses a --type that is not lowercase letters or not a shared commit type" {
  local type
  for type in Feat feat1 fe-at "feat/x" zzz debt; do
    run --separate-stderr gaia_branch_name plan plan-024 --type "$type"
    [ "$status" -eq 2 ] || { echo "type '$type': status $status" >&2; return 1; }
    [ -z "$output" ] || { echo "type '$type': stdout '$output'" >&2; return 1; }
    grep -qF -- '--type' <<<"$stderr"
  done
  run --separate-stderr gaia_branch_name plan plan-024 --type zzz
  grep -qF 'use one of:' <<<"$stderr"
  grep -qF 'feat' <<<"$stderr"
}

@test "name: plan mints for every shared commit type" {
  local type checked=0 expected
  expected="$(jq '.types | length' "$REPO_ROOT/.gaia/conventional-commits.json")"
  while IFS= read -r type; do
    [ "$(gaia_branch_name plan spec-1 --type "$type")" = "$type/spec-1" ]
    checked=$((checked + 1))
  done < <(shared_types)
  [ "$expected" -gt 0 ]
  [ "$checked" -eq "$expected" ]
}

# bin_without_jq <directory>: a PATH directory holding only what minting a plan
# name needs, so jq is the one missing tool.
bin_without_jq() {
  local tool
  mkdir -p "$1"
  for tool in git tr sed; do
    ln -s "$(command -v "$tool")" "$1/$tool"
  done
}

@test "name: with jq absent plan still mints on the shape check alone, and still refuses a non-letter type" {
  local bin="$BATS_TEST_TMPDIR/bin-no-jq-mint"
  bin_without_jq "$bin"
  run env PATH="$bin" "$BASH" -c 'command -v jq'
  [ "$status" -eq 1 ]
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$LIBRARY' && gaia_branch_name plan plan-024 --type zzz --slug x"
  [ "$status" -eq 0 ]
  [ "$output" = "zzz/plan-024-x" ]
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$LIBRARY' && gaia_branch_name plan plan-024 --type Feat"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'lowercase letters' <<<"$stderr"
}

# plan_mint_in <directory> <args>: mint through the library copy under <directory>.
plan_mint_in() {
  run --separate-stderr bash -c ". '$1/.gaia/scripts/branch-name-lib.sh' && gaia_branch_name plan plan-024 $2"
}

@test "the plan mint guards can fail: a lib copy missing each one mints what the real lib refuses" {
  local directory="$BATS_TEST_TMPDIR/mint-twins" bin="$BATS_TEST_TMPDIR/bin-no-jq-twin"
  scratch_library "$directory"
  # Armed: the unmodified copy refuses all three bad calls.
  plan_mint_in "$directory" "--slug x"
  [ "$status" -eq 2 ]
  plan_mint_in "$directory" "--type zzz"
  [ "$status" -eq 2 ]
  # No membership check: an unknown lowercase type mints.
  sed 's#^      if _gaia_branch_load_types; then$#      if false; then#' "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  plan_mint_in "$directory" "--type zzz"
  [ "$status" -eq 0 ]
  [ "$output" = "zzz/plan-024" ]
  # No --type requirement: the usage line is gone.
  scratch_library "$directory"
  sed 's#^      \[ -n "\$type" \] || {$#      [ -n "x" ] || {#' "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  plan_mint_in "$directory" "--slug x"
  grep -qF 'needs --type' <<<"$stderr" && return 1
  # No shape check: with jq absent an uppercase type mints.
  scratch_library "$directory"
  sed 's#^        \*\[!a-z\]\*)$#        zz-never)#' "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  cmp -s "$LIBRARY" "$directory/.gaia/scripts/branch-name-lib.sh" && return 1
  bin_without_jq "$bin"
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$directory/.gaia/scripts/branch-name-lib.sh' && gaia_branch_name plan plan-024 --type Feat"
  [ "$status" -eq 0 ]
  [ "$output" = "Feat/plan-024" ]
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
    "plan spec-005 --type feat --slug cards|plan SPEC-005" \
    "plan plan-012 --type fix|plan plan-012" \
    "release 1.4.0|maintenance v1.4.0"; do
    # shellcheck disable=SC2086
    name="$(gaia_branch_name ${row%%|*})"
    want="${row#*|}"
    expect_classify "$name" "$want"
    expect_classify "$(worktree_spelling "$name")" "$want"
  done
  local kind
  for kind in audit harden fitness residue deps "update v2.0.0"; do
    # shellcheck disable=SC2086
    name="$(gaia_branch_name $kind)"
    [ "$(gaia_branch_classify "$name" | cut -d' ' -f1)" = "maintenance" ]
    [ "$(gaia_branch_classify "$(worktree_spelling "$name")" | cut -d' ' -f1)" = "maintenance" ]
    gaia_branch_validate "$name"
  done
}

# ========== 8. listing and ref readability ==========

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

# corrupt_packed_refs <repo>: a repository whose every ref read fails while
# `rev-parse --git-dir` keeps succeeding. Packing the refs and then appending a
# junk line is what splits those two apart.
corrupt_packed_refs() {
  local repo="$1"
  git init -q --initial-branch=main "$repo"
  git -C "$repo" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m init
  git -C "$repo" branch "debt/11-x"
  git -C "$repo" pack-refs --all
  printf 'this is not a ref line\n' >>"$repo/.git/packed-refs"
}

@test "list: stays fail-open on an unreadable ref store" {
  local repo="$BATS_TEST_TMPDIR/badrefs-list"
  corrupt_packed_refs "$repo"
  run gaia_branch_list "$repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ========== 9. lockstep with the kinds minted outside bash ==========

# quoted_prefix <file> <anchor-regex>: the text between the opening quote of the
# first matching line's literal and either the closing quote or the first `${`.
chain_prefix() {
  sed -nE "s/^const WIKI_CHAIN_BRANCH_PREFIX = '([^']*)';\$/\\1/p" "$1"
}

land_prefix() {
  sed -nE 's/^[[:space:]]*const branchName = `([^$`]*)\$\{.*$/\1/p' "$1"
}

forensics_prefix() {
  sed -nE 's/^[[:space:]]*branch="([^$"]*)\$\{ISSUE_NUMBER\}.*$/\1/p' "$1"
}

# prefix_conforms <prefix> <sample-suffix>: 0 when a name minted under <prefix>
# classifies maintenance and validates, the two readers CI and the usage ledger
# trust.
prefix_conforms() {
  local sample="$1$2" classified
  [ -n "$1" ] || return 1
  classified="$(gaia_branch_classify "$sample")"
  [ "${classified%% *}" = "maintenance" ] || return 1
  gaia_branch_validate "$sample" 2>/dev/null
}

@test "lockstep: the CLI wiki chain and sync-land mint one prefix, and it classifies and validates" {
  local chain_value land_value
  chain_value="$(chain_prefix "$REPO_ROOT/.gaia/cli/src/wiki/chain.ts")"
  land_value="$(land_prefix "$REPO_ROOT/.gaia/cli/src/wiki/sync-land.ts")"
  [ -n "$chain_value" ]
  [ "$chain_value" = "$land_value" ] || {
    printf 'chain.ts mints %s, sync-land.ts mints %s\n' "$chain_value" "$land_value" >&2
    return 1
  }
  prefix_conforms "$chain_value" "2026-09-20-abc1234"
  expect_classify "${chain_value}2026-09-20-abc1234" "maintenance sync-2026-09-20-abc1234"
}

@test "the wiki lockstep can fail: a source file with a different prefix literal is reported" {
  local scratch_chain="$BATS_TEST_TMPDIR/chain.ts" scratch_land="$BATS_TEST_TMPDIR/sync-land.ts"
  sed "s#WIKI_CHAIN_BRANCH_PREFIX = 'wiki/sync-'#WIKI_CHAIN_BRANCH_PREFIX = 'wiki-chain/'#" \
    "$REPO_ROOT/.gaia/cli/src/wiki/chain.ts" >"$scratch_chain"
  sed 's#const branchName = `wiki/sync-#const branchName = `wiki-land/#' \
    "$REPO_ROOT/.gaia/cli/src/wiki/sync-land.ts" >"$scratch_land"
  [ "$(chain_prefix "$scratch_chain")" = "wiki-chain/" ]
  [ "$(land_prefix "$scratch_land")" = "wiki-land/" ]
  [ "$(chain_prefix "$scratch_chain")" != "$(land_prefix "$scratch_land")" ]
  # A prefix the table does not know is refused by the same helper the real
  # lockstep calls.
  prefix_conforms "wiki-chain/" "2026-09-20-abc1234" && return 1
  true
}

@test "lockstep: forensics-triage.yml mints forensics/<issue>-<class>, and it classifies and validates" {
  local prefix
  prefix="$(forensics_prefix "$REPO_ROOT/.github/workflows/forensics-triage.yml")"
  [ "$prefix" = "forensics/" ]
  prefix_conforms "$prefix" "123-some-class"
  expect_classify "${prefix}123-some-class" "maintenance 123-some-class"
}

@test "the forensics lockstep can fail: a workflow with a different prefix literal is reported" {
  local scratch_workflow="$BATS_TEST_TMPDIR/forensics-triage.yml" prefix
  sed 's#branch="forensics/\${ISSUE_NUMBER}#branch="forensic-fix/${ISSUE_NUMBER}#' \
    "$REPO_ROOT/.github/workflows/forensics-triage.yml" >"$scratch_workflow"
  prefix="$(forensics_prefix "$scratch_workflow")"
  [ "$prefix" = "forensic-fix/" ]
  prefix_conforms "$prefix" "123-some-class" && return 1
  true
}

# The prefix is built at runtime so no removed-layer literal lands in the tree.
@test "a removed maintenance prefix falls through to the unrecognized class" {
  local prefix
  prefix="$(printf 'gaia%sci' -)"
  expect_classify "$prefix/tool/x" "adhoc unknown"
  expect_classify "$(worktree_spelling "$prefix/tool/x")" "adhoc unknown"
}

@test "the removed-prefix fall-through test can fail: a lib that still has the old arm classifies it maintenance" {
  local prefix scratch_library
  prefix="$(printf 'gaia%sci' -)"
  scratch_library="$BATS_TEST_TMPDIR/branch-name-lib-old-arm.sh"
  sed 's#wiki-sync/\* \\$#wiki-sync/* | PREFIX/* \\#' "$LIBRARY" | sed "s#PREFIX#$prefix#" > "$scratch_library"
  grep -qF -- "| $prefix/* " "$scratch_library"
  run bash -c ". '$scratch_library' && gaia_branch_classify '$prefix/t/x'"
  [ "$status" -eq 0 ]
  [ "$output" = "maintenance t/x" ]
}

# ========== 10. creation sites mint through the library ==========

# literal_hits <repo>: every tracked line under .claude and .specify that
# hands git or the harness a hand-spelled GAIA branch name. One definition, so
# the guard and its can-fail twin below read exactly the same patterns.
literal_hits() {
  local kinds='(debt|plan|chore|release|spec|harden|audit|fitness|residue|deps|update|forensics|wiki/sync)[-/]'
  git -C "$1" grep -nE \
    -e "(checkout -b|switch -c|branch -[mM]|worktree add( [^ ]+)* -[bB]) +\"?${kinds}" \
    -e 'BRANCH="(debt|plan|chore|release)/' \
    -e "EnterWorktree\\(\\{ *name: *\"${kinds}" \
    -- .claude .specify ':!**/*.bats' || true
}

@test "no instruction surface spells a GAIA branch literal for git to create" {
  # Every flow that cuts a branch or a worktree takes its name from
  # gaia_branch_name, so a literal name handed to git or to EnterWorktree is a
  # second copy of the convention waiting to drift.
  local hits
  hits="$(literal_hits "$REPO_ROOT")"
  [ -z "$hits" ] || {
    printf 'branch literals outside the library:\n%s\n' "$hits" >&2
    return 1
  }
}

@test "the no-literal guard can fail: every spelling it names is reported" {
  local repo="$BATS_TEST_TMPDIR/planted" hits line
  mkdir -p "$repo/.claude"
  git init -q "$repo"
  printf '%s\n' \
    'git checkout -b chore/update-deps-now' \
    'git switch -c "debt/1-x"' \
    'git worktree add -b plan/spec-001-x ../wt' \
    'BRANCH="release/v1"' \
    'EnterWorktree({name: "debt/2-y"})' \
    'git checkout -b "$BRANCH"' \
    'EnterWorktree({name: "<branch-name>"})' \
    'git checkout -b deps/2026-01-01-0000' \
    'git checkout -b update/v1' >"$repo/.claude/x.md"
  git -C "$repo" add .claude/x.md
  hits="$(literal_hits "$repo")"
  for line in 1 2 3 4 5 8 9; do
    grep -qF ".claude/x.md:$line:" <<<"$hits" || { echo "line $line not reported" >&2; return 1; }
  done
  # The minted and placeholder forms are the correct spellings, never hits.
  grep -qE '\.claude/x\.md:(6|7):' <<<"$hits" && return 1
  true
}

# ========== 11. validate ==========

# shared_types: the `types` of .gaia/conventional-commits.json, one per line.
shared_types() {
  jq -r '.types[]' "$REPO_ROOT/.gaia/conventional-commits.json"
}

# expect_valid <branch>
expect_valid() {
  run --separate-stderr gaia_branch_validate "$1"
  [ "$status" -eq 0 ] || {
    printf "validate '%s': status %s, stderr '%s'\n" "$1" "$status" "$stderr" >&2
    return 1
  }
}

# expect_invalid <branch>: exit 1 with exactly one non-empty stderr line.
expect_invalid() {
  run --separate-stderr gaia_branch_validate "$1"
  [ "$status" -eq 1 ] || {
    printf "validate '%s': status %s, want 1\n" "$1" "$status" >&2
    return 1
  }
  [ -n "$stderr" ] || { printf "validate '%s': empty stderr\n" "$1" >&2; return 1; }
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ] || {
    printf "validate '%s': stderr is not one line: %s\n" "$1" "$stderr" >&2
    return 1
  }
}

@test "validate accepts one canonical example per workflow kind" {
  local branch
  for branch in debt/42-fix-it debt/41-42-47-batch plan/spec-005-cards plan/plan-023-naming \
    audit/2026-10-03-1200 harden/2026-10-03-1200 fitness/2026-10-03-1200 residue/2026-10-03-1200 \
    deps/2026-10-03-1200 update/v2.0.0-2026-10-03-1200 release/v2.0.0 \
    wiki/sync-2026-09-20-abc1234 forensics/123-some-class; do
    expect_valid "$branch"
  done
}

@test "validate accepts every name the library mints" {
  local branch
  for branch in "$(gaia_branch_name debt 2159 --slug "reconcile claim")" "$(gaia_branch_name debt 3 1 2)" \
    "$(gaia_branch_name plan plan-023 --type feat --slug naming)" "$(gaia_branch_name audit)" "$(gaia_branch_name harden)" \
    "$(gaia_branch_name fitness)" "$(gaia_branch_name residue)" "$(gaia_branch_name deps)" \
    "$(gaia_branch_name update v2.0.0)" "$(gaia_branch_name release 2.0.0)"; do
    expect_valid "$branch"
  done
}

@test "validate accepts <type>/<issue>-<slug> and <type>/<slug> for every shared commit type" {
  local type checked=0 expected
  expected="$(jq '.types | length' "$REPO_ROOT/.gaia/conventional-commits.json")"
  while IFS= read -r type; do
    expect_valid "$type/123-some-slug"
    expect_valid "$type/some-slug"
    checked=$((checked + 1))
  done < <(shared_types)
  [ "$expected" -gt 0 ]
  [ "$checked" -eq "$expected" ]
}

@test "validate accepts <type>/plan-<nnn> and <type>/spec-<nnn> for every shared commit type" {
  local type checked=0 expected
  expected="$(jq '.types | length' "$REPO_ROOT/.gaia/conventional-commits.json")"
  while IFS= read -r type; do
    expect_valid "$type/plan-024-some-slug"
    expect_valid "$type/spec-012"
    checked=$((checked + 1))
  done < <(shared_types)
  [ "$expected" -gt 0 ]
  [ "$checked" -eq "$expected" ]
}

@test "validate keeps legacy plan/plan-<nnn> and plan/spec-<nnn> valid" {
  expect_valid plan/plan-023-conventional-commits-naming
  expect_valid plan/spec-005-cards
  expect_valid plan/spec-005
  expect_valid plan/plan-1
}

@test "validate refuses any other plan/ name, naming the type-prefixed fix" {
  local branch
  for branch in plan/whatever plan/cards-layout plan/spec plan/plan plan/spec-x plan/planning-notes; do
    expect_invalid "$branch"
    grep -qF '<type>/plan-<nnn>-<slug>' <<<"$stderr" || { echo "branch '$branch': fix not named: $stderr" >&2; return 1; }
  done
}

@test "the plan/ refusal can fail: a lib copy without the rule accepts plan/whatever" {
  local directory="$BATS_TEST_TMPDIR/no-plan-rule"
  scratch_library "$directory"
  validate_in "$directory" plan/whatever
  [ "$status" -eq 1 ]
  sed 's#^  if \[ "\$prefix" = "plan" \]; then$#  if false; then#' "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  cmp -s "$LIBRARY" "$directory/.gaia/scripts/branch-name-lib.sh" && return 1
  validate_in "$directory" plan/whatever
  [ "$status" -eq 0 ]
}

@test "validate accepts a mixed-case release version, a dependabot branch, and a legacy-style chore slug" {
  expect_valid release/v2.0.0-RC.1
  expect_valid update/v2.0.0-RC.1-2026-10-03-1200
  expect_valid dependabot/npm_and_yarn/Foo-1.2.3
  expect_valid chore/fix-typo
  expect_valid chore/update-deps-2026-09-20-1200
}

@test "validate refuses every malformed name with one stderr line and exit 1" {
  local long branch
  long="fix/$(printf 'a%.0s' $(seq 61))"
  [ "${#long}" -eq 65 ]
  for branch in feature/x Feat/x fix/x_y fix/ fix/-x fix/x- fix/a/b "$long" wiki-sync/2026-09-20-abc1234 \
    debt main 'debt(x)/y' '' fix/a..b fix/x.lock; do
    expect_invalid "$branch"
  done
}

@test "validate accepts the 64-byte boundary" {
  local exact
  exact="fix/$(printf 'a%.0s' $(seq 60))"
  [ "${#exact}" -eq 64 ]
  expect_valid "$exact"
}

@test "validate names the canonical name and the rename for a worktree spelling" {
  run --separate-stderr gaia_branch_validate worktree-plan+plan-023-x
  [ "$status" -eq 1 ]
  grep -qF 'plan/plan-023-x' <<<"$stderr"
  grep -qF 'branch -m' <<<"$stderr"
}

@test "validate accepts debt/<n>-slug though debt is not a commit type" {
  jq -e '.types | index("debt") | not' "$REPO_ROOT/.gaia/conventional-commits.json" >/dev/null
  expect_valid debt/2159-slug
}

# scratch_library <directory>: a copy of the library at <directory>/.gaia/scripts
# with the shared types file beside it, the layout validate reads relative to
# its own location.
scratch_library() {
  mkdir -p "$1/.gaia/scripts"
  cp "$LIBRARY" "$1/.gaia/scripts/branch-name-lib.sh"
  cp "$REPO_ROOT/.gaia/conventional-commits.json" "$1/.gaia/conventional-commits.json"
}

# validate_in <directory> <branch>: validate through the copy under <directory>.
validate_in() {
  run --separate-stderr bash -c ". '$1/.gaia/scripts/branch-name-lib.sh' && gaia_branch_validate '$2'"
}

@test "validate cannot decide when jq is missing: exit 2, never 0" {
  local bin="$BATS_TEST_TMPDIR/bin-without-jq"
  mkdir -p "$bin"
  ln -s "$(command -v git)" "$bin/git"
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$LIBRARY' && gaia_branch_validate fix/x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'jq' <<<"$stderr"
}

@test "validate cannot decide when the shared types file is unreadable: exit 2, never 0" {
  local directory="$BATS_TEST_TMPDIR/no-types"
  scratch_library "$directory"
  # Armed first: with the file present the same call is valid, so the 2 below
  # comes from the missing file and not from the scratch layout.
  validate_in "$directory" fix/x
  [ "$status" -eq 0 ]
  rm "$directory/.gaia/conventional-commits.json"
  validate_in "$directory" fix/x
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'cannot decide' <<<"$stderr"
}

@test "validate cannot decide when the shared types file holds no usable list" {
  local directory="$BATS_TEST_TMPDIR/bad-types" content
  scratch_library "$directory"
  for content in '{"types": []}' '{"types": "fix"}' '{"legacyTypes": ["debt"]}' 'not json'; do
    printf '%s' "$content" >"$directory/.gaia/conventional-commits.json"
    validate_in "$directory" fix/x
    [ "$status" -eq 2 ] || { echo "content '$content': status $status" >&2; return 1; }
  done
}

@test "validate reads the type set from the JSON: a copy without fix refuses fix/x and still accepts feat/x" {
  local directory="$BATS_TEST_TMPDIR/types-without-fix"
  scratch_library "$directory"
  jq 'del(.types[] | select(. == "fix"))' "$REPO_ROOT/.gaia/conventional-commits.json" >"$directory/.gaia/conventional-commits.json"
  jq -e '.types | index("fix") | not' "$directory/.gaia/conventional-commits.json" >/dev/null
  validate_in "$directory" fix/x
  [ "$status" -eq 1 ]
  [ -n "$stderr" ]
  validate_in "$directory" feat/x
  [ "$status" -eq 0 ]
}

# ========== 12. every `name <kind>` call mints ==========

# name_call_kinds <repo>: every kind named by a tracked `branch-name-lib.sh name
# <kind>` call under .claude and .specify, one per line, bats files excluded.
name_call_kinds() {
  git -C "$1" grep -hoE 'branch-name-lib\.sh name [a-z]+' -- .claude .specify ':!**/*.bats' \
    | awk '{ print $3 }' | LC_ALL=C sort -u || true
}

# placeholder_arguments <kind>: arguments that satisfy the kind's own validation.
placeholder_arguments() {
  case "$1" in
    debt) printf '1' ;;
    plan) printf 'spec-001 --type feat' ;;
    release | update) printf '1.0.0' ;;
  esac
}

# unmintable_kinds <repo>: the kinds a call names that the library refuses.
unmintable_kinds() {
  local kind
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    # shellcheck disable=SC2046
    bash "$LIBRARY" name "$kind" $(placeholder_arguments "$kind") >/dev/null 2>&1 || printf '%s\n' "$kind"
  done < <(name_call_kinds "$1")
}

@test "every branch-name-lib.sh name call in the instruction surface names a kind that mints" {
  local kinds kind unmintable
  kinds="$(name_call_kinds "$REPO_ROOT")"
  # A short read would leave the loop green over a subset: every kind a bash
  # flow mints must have been found.
  for kind in debt plan release audit harden fitness residue deps update; do
    grep -qx "$kind" <<<"$kinds" || { echo "no call site found for kind '$kind'" >&2; return 1; }
  done
  unmintable="$(unmintable_kinds "$REPO_ROOT")"
  [ -z "$unmintable" ] || { printf 'calls name a kind the library refuses: %s\n' "$unmintable" >&2; return 1; }
}

@test "the call-site guard can fail: a planted name chore call is reported" {
  local repo="$BATS_TEST_TMPDIR/planted-call"
  mkdir -p "$repo/.claude"
  git init -q "$repo"
  printf '%s\n' 'bash .gaia/scripts/branch-name-lib.sh name chore x' \
    'bash .gaia/scripts/branch-name-lib.sh name audit' >"$repo/.claude/x.md"
  git -C "$repo" add .claude/x.md
  [ "$(name_call_kinds "$repo" | tr '\n' ' ')" = "audit chore " ]
  [ "$(unmintable_kinds "$repo")" = "chore" ]
}

# ========== structural hygiene ==========

@test "portability: the readers agree under zsh, where zsh exists" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  run zsh -c "source '$LIBRARY'; gaia_branch_classify worktree-debt+41-42-batch; gaia_branch_members worktree-debt+41-42-batch; gaia_branch_spec_number plan/spec-007-x; gaia_branch_classify feat/plan-024-x; gaia_branch_spec_number docs/spec-007-x; gaia_branch_plan_type worktree-fix+spec-012-x"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "drain 41-42 41 42 7 plan plan-024 7 fix " ]
}

@test "portability: validate's data-free checks agree under zsh, where zsh exists" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  local script="dependabot/a/b; echo \$?; gaia_branch_validate worktree-plan+plan-023-x 2>/dev/null; echo \$?; gaia_branch_validate Feat/x 2>/dev/null; echo \$?; gaia_branch_validate fix/a/b 2>/dev/null; echo \$?; gaia_branch_validate fix/-x 2>/dev/null; echo \$?"
  run zsh -c "source '$LIBRARY'; gaia_branch_validate $script"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tr '\n' ' ')" = "0 1 1 1 1 " ]
}
