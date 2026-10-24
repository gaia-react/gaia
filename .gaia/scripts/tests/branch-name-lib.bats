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
#   9. lockstep: the kind minted outside bash still carries the table's prefix,
#      and the wiki CLI's own pattern still reads the wiki name bash mints
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
    "cleanse/plan-1|maintenance plan-1" \
    "debt/spec-1|drain unknown" \
    "cleanse/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "codify/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "fitness/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "residue/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "deps/2026-10-03-1200|maintenance 2026-10-03-1200" \
    "update/v2.0.0-2026-10-03-1200|maintenance v2.0.0-2026-10-03-1200" \
    "release/v1.4.0|maintenance v1.4.0" \
    "wiki/2026-10-15-0532|maintenance 2026-10-15-0532" \
    "forensics/123-some-class|maintenance 123-some-class" \
    "chore/fix-typo|adhoc unknown" \
    "wiki/notes|adhoc unknown" \
    "wiki/2026-10-03-14-30|adhoc unknown" \
    "wiki/2026-10-03-143|adhoc unknown" \
    "wiki/2026-10-03-1432-notes|adhoc unknown" \
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
  [ -z "$(gaia_branch_members "feat/plan-024-x")" ]
  [ -z "$(gaia_branch_members "worktree-fix+spec-012-x")" ]
  [ -z "$(gaia_branch_members "main")" ]
}

@test "spec-number: a SPEC plan branch prints its number without padding, anything else prints nothing" {
  [ "$(gaia_branch_spec_number "feat/spec-005-x")" = "5" ]
  [ "$(gaia_branch_spec_number "worktree-feat+spec-120")" = "120" ]
  [ "$(gaia_branch_spec_number "feat/spec-000")" = "0" ]
  [ -z "$(gaia_branch_spec_number "feat/plan-012-x")" ]
  [ -z "$(gaia_branch_spec_number "spec-005-x")" ]
}

@test "spec-number: a type-prefixed SPEC plan branch prints its number, a type-prefixed plan-NNN branch prints nothing" {
  [ "$(gaia_branch_spec_number "refactor/spec-005-x")" = "5" ]
  [ "$(gaia_branch_spec_number "docs/spec-007-cards")" = "7" ]
  [ "$(gaia_branch_spec_number "worktree-fix+spec-012-x")" = "12" ]
  [ -z "$(gaia_branch_spec_number "feat/plan-024-x")" ]
  [ -z "$(gaia_branch_spec_number "feat/spec-notes")" ]
}

@test "plan-number: every plan spelling prints its number without padding, anything else prints nothing" {
  [ "$(gaia_branch_plan_number "feat/plan-031-x")" = "31" ]
  [ "$(gaia_branch_plan_number "worktree-feat+plan-007-x")" = "7" ]
  [ "$(gaia_branch_plan_number "feat/plan-000")" = "0" ]
  [ "$(gaia_branch_plan_number "fix/plan-0100-cards")" = "100" ]
  [ -z "$(gaia_branch_plan_number "feat/spec-005-x")" ]
  [ -z "$(gaia_branch_plan_number "feat/plan-notes")" ]
  [ -z "$(gaia_branch_plan_number "main")" ]
  [ "$(bash "$LIBRARY" plan-number feat/plan-031-x)" = "31" ]
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

@test "plan-type: hand-named branches, workflow branches and non-plan names print nothing" {
  local branch
  for branch in feat/planning-notes \
    feat/new-thing debt/12-spec-1 cleanse/plan-1 release/v1.0.0 main ""; do
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
  for kind in cleanse codify fitness residue deps wiki; do
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

@test "name: the renamed audit and harden kinds exit 2 as unknown kinds naming the replacements" {
  local retired_kind
  for retired_kind in audit harden; do
    run --separate-stderr gaia_branch_name "$retired_kind"
    [ "$status" -eq 2 ] || { echo "kind '$retired_kind': status $status" >&2; return 1; }
    [ -z "$output" ]
    grep -qF 'unknown kind' <<<"$stderr"
    grep -qF 'cleanse, codify' <<<"$stderr"
  done
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
    "plan feat-1 --type feat" "plan spec-1" "plan spec-1 --type" "plan spec-1 --type feat extra" "plan --type feat" "chore" "chore x" "cleanse extra" "codify extra" "fitness extra" \
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

# letters <count>: <count> lowercase a's.
letters() {
  printf '%*s' "$1" '' | tr ' ' a
}

# expect_adhoc_refused <args...>: `name adhoc <args>` exits 2, stdout empty, one reason on stderr.
expect_adhoc_refused() {
  run --separate-stderr gaia_branch_name adhoc "$@"
  [ "$status" -eq 2 ] || { printf "adhoc '%s': status %s, want 2\n" "$*" "$status" >&2; return 1; }
  [ -z "$output" ] || { printf "adhoc '%s': stdout '%s'\n" "$*" "$output" >&2; return 1; }
  [ -n "$stderr" ] || { printf "adhoc '%s': empty stderr\n" "$*" >&2; return 1; }
}

@test "name: adhoc mints <type>/<issue>-<slug>, takes its options in any order, and strips a leading # and zeros from the issue" {
  [ "$(gaia_branch_name adhoc --type fix --issue 12 --slug "Ad hoc lifecycle")" = "fix/12-ad-hoc-lifecycle" ]
  [ "$(gaia_branch_name adhoc --slug "Ad hoc lifecycle" --issue 12 --type fix)" = "fix/12-ad-hoc-lifecycle" ]
  [ "$(gaia_branch_name adhoc --slug "Ad hoc lifecycle" --type fix --issue 12)" = "fix/12-ad-hoc-lifecycle" ]
  [ "$(gaia_branch_name adhoc --type fix --issue '#0042' --slug "Ad hoc lifecycle")" = "fix/42-ad-hoc-lifecycle" ]
}

@test "name: adhoc without an issue mints <type>/<slug>" {
  [ "$(gaia_branch_name adhoc --type docs --slug "Readme typo")" = "docs/readme-typo" ]
}

@test "name: adhoc reduces uppercase and punctuation in the slug to lowercase kebab" {
  [ "$(gaia_branch_name adhoc --type feat --slug "  Add: The (New) Thing!! v2  ")" = "feat/add-the-new-thing-v2" ]
}

@test "name: adhoc mints for every shared commit type, and each name validates and reads as adhoc" {
  local type checked=0 expected name
  expected="$(jq '.types | length' "$REPO_ROOT/.gaia/conventional-commits.json")"
  while IFS= read -r type; do
    name="$(gaia_branch_name adhoc --type "$type" --slug "ad hoc x")"
    [ "$name" = "$type/ad-hoc-x" ] || { echo "type '$type': minted '$name'" >&2; return 1; }
    gaia_branch_validate "$name"
    [ "$(gaia_branch_classify "$name")" = "adhoc unknown" ] || { echo "type '$type': classified '$(gaia_branch_classify "$name")'" >&2; return 1; }
    name="$(gaia_branch_name adhoc --type "$type" --issue 9 --slug "ad hoc x")"
    [ "$name" = "$type/9-ad-hoc-x" ] || { echo "type '$type': minted '$name'" >&2; return 1; }
    gaia_branch_validate "$name"
    [ "$(gaia_branch_classify "$name")" = "adhoc unknown" ] || { echo "type '$type': classified '$(gaia_branch_classify "$name")'" >&2; return 1; }
    checked=$((checked + 1))
  done < <(shared_types)
  [ "$expected" -gt 0 ]
  [ "$checked" -eq "$expected" ]
}

@test "name: adhoc keeps the name within 64 bytes at the cap boundary, never ending in a dash" {
  local length name
  # `fix/` is 4 bytes and `fix/12-` is 7: slugs of 59, 60 and 61 land the
  # issue-less name at 63, 64 and 65 bytes; 56, 57 and 58 do for the issue form.
  for length in 59 60 61; do
    name="$(gaia_branch_name adhoc --type fix --slug "$(letters "$length")")"
    [ "${#name}" -le 64 ]
    [ "${#name}" -eq "$((4 + (length > 60 ? 60 : length)))" ] || { echo "length $length: '$name'" >&2; return 1; }
    git check-ref-format --branch "$name" >/dev/null
    grep -qE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' <<<"$name"
  done
  for length in 56 57 58; do
    name="$(gaia_branch_name adhoc --type fix --issue 12 --slug "$(letters "$length")")"
    [ "${#name}" -le 64 ]
    [ "${#name}" -eq "$((7 + (length > 57 ? 57 : length)))" ] || { echo "length $length: '$name'" >&2; return 1; }
    git check-ref-format --branch "$name" >/dev/null
    grep -qE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' <<<"$name"
  done
  # A hyphen exactly at the cut point is trimmed rather than left trailing.
  name="$(gaia_branch_name adhoc --type fix --slug "$(letters 59)-bbbb")"
  [ "$name" = "fix/$(letters 59)" ]
  name="$(gaia_branch_name adhoc --type fix --issue 12 --slug "$(letters 56)-bbbb")"
  [ "$name" = "fix/12-$(letters 56)" ]
  case "$name" in *-) return 1 ;; esac
  true
}

@test "name: adhoc exits 2 with nothing on stdout and a reason on stderr for every bad call" {
  expect_adhoc_refused --type feature --slug x
  expect_adhoc_refused --type Fix --slug x
  expect_adhoc_refused --type debt --slug x
  expect_adhoc_refused --slug x
  expect_adhoc_refused --slug x --type
  expect_adhoc_refused --type fix
  expect_adhoc_refused --type fix --slug
  expect_adhoc_refused --type fix --slug '!!!'
  expect_adhoc_refused --type fix --issue abc --slug x
  expect_adhoc_refused --type fix --issue --slug x
  expect_adhoc_refused --type fix --slug x extra
  expect_adhoc_refused
}

@test "name: adhoc refuses a slug that would read as another kind, and mints it once an issue number breaks the shape" {
  expect_adhoc_refused --type feat --slug "plan 3 x"
  grep -qF 'pick another slug' <<<"$stderr"
  grep -qF 'plan' <<<"$stderr"
  expect_adhoc_refused --type fix --slug "spec-12"

  [ "$(gaia_branch_name adhoc --type feat --issue 7 --slug "plan 3 x")" = "feat/7-plan-3-x" ]
  [ "$(gaia_branch_name adhoc --type fix --issue 7 --slug "spec-12")" = "fix/7-spec-12" ]
  [ "$(gaia_branch_name adhoc --type wiki --issue 7 --slug "sync x")" = "wiki/7-sync-x" ]
  local name
  for name in feat/7-plan-3-x fix/7-spec-12 wiki/7-sync-x; do
    [ "$(gaia_branch_classify "$name")" = "adhoc unknown" ]
  done
}

@test "name: with jq absent adhoc still mints on the shape check alone, and still refuses a non-letter type and the legacy debt type" {
  local bin="$BATS_TEST_TMPDIR/bin-no-jq-adhoc"
  bin_without_jq "$bin"
  run env PATH="$bin" "$BASH" -c 'command -v jq'
  [ "$status" -eq 1 ]
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$LIBRARY' && gaia_branch_name adhoc --type fix --slug x"
  [ "$status" -eq 0 ]
  [ "$output" = "fix/x" ]
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$LIBRARY' && gaia_branch_name adhoc --type Fix --slug x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'lowercase letters' <<<"$stderr"
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$LIBRARY' && gaia_branch_name adhoc --type debt --slug x"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  grep -qF 'debt' <<<"$stderr"
}

# adhoc_mint_in <directory> <args>: mint an ad-hoc name through the library copy under <directory>.
adhoc_mint_in() {
  run --separate-stderr bash -c ". '$1/.gaia/scripts/branch-name-lib.sh' && gaia_branch_name adhoc $2"
}

@test "the adhoc mint guards can fail: a lib copy missing each one mints what the real lib refuses" {
  local directory="$BATS_TEST_TMPDIR/adhoc-twins" bin="$BATS_TEST_TMPDIR/bin-no-jq-adhoc-twin"
  scratch_library "$directory"
  # Armed: the unmodified copy refuses all three bad calls.
  adhoc_mint_in "$directory" "--type feat --slug 'plan 3 x'"
  [ "$status" -eq 2 ]
  adhoc_mint_in "$directory" "--type zzz --slug x"
  [ "$status" -eq 2 ]
  bin_without_jq "$bin"
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$directory/.gaia/scripts/branch-name-lib.sh' && gaia_branch_name adhoc --type debt --slug x"
  [ "$status" -eq 2 ]

  # No classification check: the plan-shaped name mints.
  sed 's#^      if \[ "\$_gaia_branch_mode" != "adhoc" \] || \[ "\$_gaia_branch_unit" != "unknown" \]; then$#      if false; then#' "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  cmp -s "$LIBRARY" "$directory/.gaia/scripts/branch-name-lib.sh" && return 1
  adhoc_mint_in "$directory" "--type feat --slug 'plan 3 x'"
  [ "$status" -eq 0 ]
  [ "$output" = "feat/plan-3-x" ]

  # No type membership check: an unknown lowercase type mints.
  scratch_library "$directory"
  sed 's#^      if _gaia_branch_load_types; then$#      if false; then#' "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  cmp -s "$LIBRARY" "$directory/.gaia/scripts/branch-name-lib.sh" && return 1
  adhoc_mint_in "$directory" "--type zzz --slug x"
  [ "$status" -eq 0 ]
  [ "$output" = "zzz/x" ]

  # No legacy debt refusal: with jq absent the debt type mints a drain-shaped name
  # (the classification check is also gone, since it would catch it).
  scratch_library "$directory"
  sed -e 's#^        debt)$#        zz-never)#' \
    -e 's#^      if \[ "\$_gaia_branch_mode" != "adhoc" \] || \[ "\$_gaia_branch_unit" != "unknown" \]; then$#      if false; then#' \
    "$LIBRARY" >"$directory/.gaia/scripts/branch-name-lib.sh"
  cmp -s "$LIBRARY" "$directory/.gaia/scripts/branch-name-lib.sh" && return 1
  run --separate-stderr env PATH="$bin" "$BASH" -c ". '$directory/.gaia/scripts/branch-name-lib.sh' && gaia_branch_name adhoc --type debt --slug x"
  [ "$status" -eq 0 ]
  [ "$output" = "debt/x" ]
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
    "adhoc --type fix --issue 12 --slug cards|adhoc unknown" \
    "adhoc --type docs --slug readme-typo|adhoc unknown" \
    "release 1.4.0|maintenance v1.4.0"; do
    # shellcheck disable=SC2086
    name="$(gaia_branch_name ${row%%|*})"
    want="${row#*|}"
    expect_classify "$name" "$want"
    expect_classify "$(worktree_spelling "$name")" "$want"
  done
  local kind
  for kind in cleanse codify fitness residue deps wiki "update v2.0.0"; do
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

# chain_pattern <file>: the CLI's wiki branch regex literal, rewritten as an
# extended regex grep reads (`\d` to `[0-9]`, `\/` to `/`).
chain_pattern() {
  sed -nE 's#^const WIKI_CHAIN_BRANCH_PATTERN = /(.*)/u;$#\1#p' "$1" \
    | sed -e 's#\\d#[0-9]#g' -e 's#\\/#/#g'
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

@test "lockstep: the CLI wiki chain pattern reads the wiki name bash mints" {
  local pattern name
  pattern="$(chain_pattern "$REPO_ROOT/.gaia/cli/src/wiki/chain.ts")"
  [ -n "$pattern" ]
  name="$(gaia_branch_name wiki)"
  grep -qE -- "$pattern" <<<"$name"
  prefix_conforms "wiki/" "2026-09-20-1432"
}

@test "the wiki lockstep can fail: a source file with a different pattern rejects the minted name" {
  local scratch_chain="$BATS_TEST_TMPDIR/chain.ts" pattern
  sed 's#WIKI_CHAIN_BRANCH_PATTERN = /^wiki\\/#WIKI_CHAIN_BRANCH_PATTERN = /^wiki-chain\\/#' \
    "$REPO_ROOT/.gaia/cli/src/wiki/chain.ts" >"$scratch_chain"
  pattern="$(chain_pattern "$scratch_chain")"
  [ -n "$pattern" ]
  grep -qE -- "$pattern" <<<"$(gaia_branch_name wiki)" && return 1
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
  sed 's#forensics/\* \\$#forensics/* | PREFIX/* \\#' "$LIBRARY" | sed "s#PREFIX#$prefix#" > "$scratch_library"
  grep -qF -- "| $prefix/* " "$scratch_library"
  run bash -c ". '$scratch_library' && gaia_branch_classify '$prefix/t/x'"
  [ "$status" -eq 0 ]
  [ "$output" = "maintenance t/x" ]
}

# ========== 10. creation sites mint through the library ==========

# literal_hits <repo>: every tracked line under .claude and .gaia/scripts/spec that
# hands git or the harness a hand-spelled GAIA branch name. One definition, so
# the guard and its can-fail twin below read exactly the same patterns.
literal_hits() {
  local kinds='(debt|plan|chore|release|spec|codify|cleanse|fitness|residue|deps|update|forensics|wiki/sync|wiki/[0-9]{4})[-/]'
  git -C "$1" grep -nE \
    -e "(checkout -b|switch -c|branch -[mM]|worktree add( [^ ]+)* -[bB]) +\"?${kinds}" \
    -e 'BRANCH="(debt|plan|chore|release)/' \
    -e "EnterWorktree\\(\\{ *name: *\"${kinds}" \
    -- .claude .gaia/scripts/spec ':!**/*.bats' || true
}

# bats test_tags=whole-tree
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
    'git checkout -b update/v1' \
    'git checkout -b wiki/2026-10-15-0532' >"$repo/.claude/x.md"
  git -C "$repo" add .claude/x.md
  hits="$(literal_hits "$repo")"
  for line in 1 2 3 4 5 8 9 10; do
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
  for branch in debt/42-fix-it debt/41-42-47-batch fix/spec-005-cards feat/plan-023-naming \
    cleanse/2026-10-03-1200 codify/2026-10-03-1200 fitness/2026-10-03-1200 residue/2026-10-03-1200 \
    deps/2026-10-03-1200 update/v2.0.0-2026-10-03-1200 release/v2.0.0 \
    wiki/2026-10-15-0532 forensics/123-some-class; do
    expect_valid "$branch"
  done
}

@test "validate accepts every name the library mints" {
  local branch
  for branch in "$(gaia_branch_name debt 2159 --slug "reconcile claim")" "$(gaia_branch_name debt 3 1 2)" \
    "$(gaia_branch_name plan plan-023 --type feat --slug naming)" "$(gaia_branch_name cleanse)" "$(gaia_branch_name codify)" \
    "$(gaia_branch_name fitness)" "$(gaia_branch_name residue)" "$(gaia_branch_name deps)" "$(gaia_branch_name wiki)" \
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

@test "validate accepts a mixed-case release version, a dependabot branch, and a chore slug" {
  expect_valid release/v2.0.0-RC.1
  expect_valid update/v2.0.0-RC.1-2026-10-03-1200
  expect_valid dependabot/npm_and_yarn/Foo-1.2.3
  expect_valid chore/fix-typo
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
  run --separate-stderr gaia_branch_validate worktree-feat+plan-023-x
  [ "$status" -eq 1 ]
  grep -qF 'feat/plan-023-x' <<<"$stderr"
  grep -qF 'branch -m' <<<"$stderr"
}

@test "validate never suggests a prefix-less rename for a worktree spelling: it asks for a <type>/ prefix" {
  expect_invalid worktree-camelcase-default-casing
  grep -qF 'branch -m worktree-camelcase-default-casing <type>/camelcase-default-casing' <<<"$stderr"
  grep -qF 'fix/camelcase-default-casing' <<<"$stderr"
  grep -qF 'branch -m worktree-camelcase-default-casing camelcase-default-casing' <<<"$stderr" && return 1
  # Every concrete name the message offers must pass the validator itself.
  expect_valid fix/camelcase-default-casing
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
# <kind>` call under .claude and .gaia/scripts/spec, one per line, bats files excluded.
name_call_kinds() {
  git -C "$1" grep -hoE 'branch-name-lib\.sh name [a-z]+' -- .claude .gaia/scripts/spec ':!**/*.bats' \
    | awk '{ print $3 }' | LC_ALL=C sort -u || true
}

# placeholder_arguments <kind>: arguments that satisfy the kind's own validation.
placeholder_arguments() {
  case "$1" in
    debt) printf '1' ;;
    plan) printf 'spec-001 --type feat' ;;
    release | update) printf '1.0.0' ;;
    adhoc) printf -- '--type fix --slug x' ;;
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

# bats test_tags=whole-tree
@test "every branch-name-lib.sh name call in the instruction surface names a kind that mints" {
  local kinds kind unmintable
  kinds="$(name_call_kinds "$REPO_ROOT")"
  # A short read would leave the loop green over a subset: every kind a bash
  # flow mints must have been found.
  for kind in debt plan adhoc release cleanse codify fitness residue deps wiki update; do
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
    'bash .gaia/scripts/branch-name-lib.sh name cleanse' >"$repo/.claude/x.md"
  git -C "$repo" add .claude/x.md
  [ "$(name_call_kinds "$repo" | tr '\n' ' ')" = "chore cleanse " ]
  [ "$(unmintable_kinds "$repo")" = "chore" ]
}

@test "the call-site guard finds a planted adhoc call and reports it unmintable only when the placeholder arm is missing" {
  local repo="$BATS_TEST_TMPDIR/planted-adhoc-call"
  mkdir -p "$repo/.claude"
  git init -q "$repo"
  printf '%s\n' 'bash .gaia/scripts/branch-name-lib.sh name adhoc --type fix --slug "a b"' >"$repo/.claude/x.md"
  git -C "$repo" add .claude/x.md
  [ "$(name_call_kinds "$repo")" = "adhoc" ]
  [ -z "$(unmintable_kinds "$repo")" ]
  # Red twin: this suite's own placeholder_arguments with the adhoc arm removed
  # leaves `name adhoc` running with no arguments, which the library refuses.
  local twin="$BATS_TEST_TMPDIR/placeholder-twin.sh"
  sed -n '/^placeholder_arguments() {$/,/^}$/p' "$BATS_TEST_FILENAME" | grep -v '^    adhoc) ' >"$twin"
  [ "$(grep -c 'adhoc' "$twin")" -eq 0 ]
  [ "$(grep -c 'release | update' "$twin")" -eq 1 ]
  # shellcheck disable=SC1090
  source "$twin"
  [ "$(unmintable_kinds "$repo")" = "adhoc" ]
}

# ========== structural hygiene ==========

@test "portability: the readers agree under zsh, where zsh exists" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not available"
  run zsh -c "source '$LIBRARY'; gaia_branch_classify worktree-debt+41-42-batch; gaia_branch_members worktree-debt+41-42-batch; gaia_branch_spec_number fix/spec-007-x; gaia_branch_classify feat/plan-024-x; gaia_branch_spec_number docs/spec-007-x; gaia_branch_plan_type worktree-fix+spec-012-x"
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
