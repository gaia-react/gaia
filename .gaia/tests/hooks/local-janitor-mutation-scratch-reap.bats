#!/usr/bin/env bats
#
# Sweep #5b of local-janitor.sh, the mutation-scratch arm: age-reap the
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
#
# `localtime` before `strftime` is load-bearing: jq's strftime formats in UTC
# while `touch -t` reads its argument in the machine's local timezone, so the
# bare form back-dates every seed by the local UTC offset. The margins here
# would absorb that, but the helper reads as a portable idiom worth copying,
# and a suite that copies it at a tighter margin would be wrong by up to a day.
seed_copy() {
  local name="$1" days="$2" stamp
  mkdir -p "$SCRATCH/$name"
  echo mutated > "$SCRATCH/$name/tree"
  stamp="$(jq -rn --argjson n "$days" '(now - ($n * 86400)) | localtime | strftime("%Y%m%d%H%M")')"
  touch -t "$stamp" "$SCRATCH/$name/tree" "$SCRATCH/$name"
}

@test "sweep 5b: a scratch copy past the retention window is reaped" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 20
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH/abc123.work.code-audit-frontend" ] && return 1
  true
}

@test "sweep 5b: a scratch copy within the retention window is kept" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 2
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$SCRATCH/abc123.work.code-audit-frontend" ]
  grep -qF -- "mutated" "$SCRATCH/abc123.work.code-audit-frontend/tree"
}

@test "sweep 5b: an active sibling does not shield an aged-out copy" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 20
  seed_copy "abc123.work.code-audit-maintainer-shell" 1
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH/abc123.work.code-audit-frontend" ] && return 1
  [ -d "$SCRATCH/abc123.work.code-audit-maintainer-shell" ]
}

@test "sweep 5b: the mutation-scratch parent itself is never reaped" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 20
  touch -t "$(jq -rn '(now - (60 * 86400)) | localtime | strftime("%Y%m%d%H%M")')" "$SCRATCH"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$SCRATCH" ]
}

@test "sweep 5b: GAIA_MUTATION_SCRATCH_RETENTION_DAYS shortens the window" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 3
  cd "$REPO"
  GAIA_MUTATION_SCRATCH_RETENTION_DAYS=1 run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # Kept at the 14-day default; reaped at 1.
  [ -e "$SCRATCH/abc123.work.code-audit-frontend" ] && return 1
  true
}

@test "sweep 5b: a non-numeric retention override falls back to the default" {
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 3
  cd "$REPO"
  GAIA_MUTATION_SCRATCH_RETENTION_DAYS=banana run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$SCRATCH/abc123.work.code-audit-frontend" ]
}

@test "sweep 5b: a zero retention override clamps to the one-day floor" {
  # Never to zero: a floor of 0 would reap a copy a live member minted moments
  # earlier if a session happened to start mid-audit.
  make_repo
  seed_copy "abc123.work.code-audit-frontend" 0
  cd "$REPO"
  GAIA_MUTATION_SCRATCH_RETENTION_DAYS=0 run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$SCRATCH/abc123.work.code-audit-frontend" ]
}

@test "sweep 5b: an absent mutation-scratch dir is a silent no-op" {
  make_repo
  rm -rf "$SCRATCH"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH" ] && return 1
  # The SILENT half, not just the no-op half. No member has ever minted here
  # on the overwhelming majority of machines, so this is the ordinary state,
  # and find would otherwise write `No such file or directory` to the stderr
  # this session hook shares with sweep #9's real reporting channel. bats
  # folds stderr into $output, and the janitor is otherwise quiet on this
  # minimal fixture.
  [ -z "$output" ]
}
