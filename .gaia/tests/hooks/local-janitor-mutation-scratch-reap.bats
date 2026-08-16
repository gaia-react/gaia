#!/usr/bin/env bats
#
# Sweep #5 of local-janitor.sh, the mutation-scratch arm: age-reap the
# per-member working copies a Code Audit Team member takes when it needs real
# bytes on disk (.gaia/scripts/audit-scratch-dir.sh, registry entry
# `audit-mutation-scratch`).
#
# The member releases its own directory when it finishes, so this arm is a
# backstop for the copies a member died before releasing. Each one is a whole
# working tree, which is why an unbounded accumulation is worth an arm at all.
#
# The behaviour worth pinning is the DEPTH the arm reaps at. It reaps the
# children of mutation-scratch/, never the parent: the parent's mtime moves
# every time any member mints or releases a child, so a gate on the parent
# would leave an aged-out copy unreapable for as long as any sibling stayed
# active. The "keeps a fresh sibling" and "an active sibling does not shield"
# tests below are the two halves of that.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Run under bash 5:
#   source .gaia/scripts/bats5.sh && bats5 .gaia/tests/hooks/local-janitor-mutation-scratch-reap.bats

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
  [ -f "$HOOK_ABS" ] || skip "local-janitor.sh missing"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

make_repo() {
  REPO=$(mktemp -d -t gaia-janitor-mut-scratch-XXXXXX)
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  echo init > "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  SCRATCH="$REPO/.gaia/local/cache/mutation-scratch"
  mkdir -p "$SCRATCH"
}

# seed_copy <name> <days-old>: a scratch working copy with a plausible file in
# it, back-dated so the arm's age gate is exercised for real. `touch -t` with
# an explicit stamp, never `touch -d` (GNU-only) or `date -v` (BSD-only), per
# the project's cross-platform rule.
seed_copy() {
  local name="$1" days="$2" stamp
  mkdir -p "$SCRATCH/$name"
  echo mutated > "$SCRATCH/$name/tree"
  stamp="$(jq -rn --argjson n "$days" '(now - ($n * 86400)) | strftime("%Y%m%d%H%M")')"
  touch -t "$stamp" "$SCRATCH/$name/tree" "$SCRATCH/$name"
}

@test "sweep 5: a scratch copy past the retention window is reaped" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 20
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH/abc123.work.code-audit-frontend" ] && return 1
  true
}

@test "sweep 5: a scratch copy within the retention window is kept" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 2
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$SCRATCH/abc123.work.code-audit-frontend" ]
  grep -qF -- "mutated" "$SCRATCH/abc123.work.code-audit-frontend/tree"
}

@test "sweep 5: an active sibling does not shield an aged-out copy" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 20
  seed_copy "abc123.work.code-audit-maintainer-shell" 1
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH/abc123.work.code-audit-frontend" ] && return 1
  [ -d "$SCRATCH/abc123.work.code-audit-maintainer-shell" ]
}

@test "sweep 5: the mutation-scratch parent itself is never reaped" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 20
  touch -t "$(jq -rn '(now - (60 * 86400)) | strftime("%Y%m%d%H%M")')" "$SCRATCH"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$SCRATCH" ]
}

@test "sweep 5: an absent mutation-scratch dir is a silent no-op" {
  make_repo
  rm -rf "$SCRATCH"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH" ] && return 1
  true
}
