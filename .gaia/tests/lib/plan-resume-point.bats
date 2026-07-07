#!/usr/bin/env bats
# Independent-oracle tests for .gaia/scripts/plan-resume-point.sh.
#
# plan-resume-point.sh computes a git-arbitrated resume point for a GAIA
# plan: for each PROGRESS.md phase block it proves the recorded Commit: sha
# is an ancestor of a given ref, echoes the first-gap phase (or M+1 when all
# phases are complete) on line 1, followed by zero or more
# `COMPLETE <n> <short-sha>` lines for the verified-complete phases, and
# always exits 0.
#
# This suite is built ONLY from the frozen contract in
# .gaia/local/specs/SPEC-027/plan/README.md and the per-UAT echo table; it
# does not read the helper's implementation. Fixtures are real git repos
# with real commits (no mocked git): non-ancestor fixtures move the branch
# away with `git reset --hard`, and the worktree-HEAD fixture uses a real
# second branch. Assertions follow .claude/rules/bats-assertions.md
# (bash-3.2-safe): no bare `[[ ]]` as a non-final assertion.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../scripts/plan-resume-point.sh"
  REPO="$(mktemp -d -t gaia-resume-XXXXXX)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  PLAN="$REPO/plan"
  mkdir -p "$PLAN"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

# Make a commit on the current branch of $REPO, echo its short-sha.
_commit() {
  echo "$1" >> "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit --quiet -m "$1"
  git -C "$REPO" rev-parse --short HEAD
}

# Invoke the real helper. Git context is $REPO; plan dir is $PLAN. Extra
# args (e.g. --phases 3, --branch wt) are passed through.
_run_helper() {
  run bash "$SCRIPT" --git-dir "$REPO" --plan-dir "$PLAN" "$@"
}

# --- 001a / 001b: constant-stub defeat pair ----------------------------------
# Structurally similar fixtures that MUST yield different Line-1 values, so
# a helper that echoes a constant fails one of the two.

@test "001a: P1 and P2 ancestors, no P3 block -> resume 3, COMPLETE 1 and 2" {
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: $sha2

_No notes._
EOF
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha2" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "001b: only a P1 block present and ancestor -> resume 2, COMPLETE 1 only" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._
EOF
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- 002: non-ancestor via branch reset --------------------------------------

@test "002: P1 ancestor, P2 non-ancestor after branch reset -> resume 2, COMPLETE 1 only" {
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  git -C "$REPO" reset --hard --quiet HEAD~1
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: $sha2

_No notes._
EOF
  _run_helper --phases 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- 009: missing / empty / malformed ledger ---------------------------------

@test "009a: neither PROGRESS.md nor SUMMARY.md -> resume 1, no COMPLETE lines" {
  _commit p1 >/dev/null
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "009b: empty PROGRESS.md -> resume 1, no COMPLETE lines" {
  _commit p1 >/dev/null
  : > "$PLAN/PROGRESS.md"
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "009c: malformed/garbage PROGRESS.md -> resume 1, no COMPLETE lines" {
  _commit p1 >/dev/null
  cat > "$PLAN/PROGRESS.md" <<'EOF'
this is not a valid summary file
random garbage text
no phase headings anywhere in here
EOF
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${#lines[@]}" -eq 1 ]
}

# --- 009d: legacy live SUMMARY.md fallback (no PROGRESS.md present) ---------
# A plan folder crossing the rename boundary mid-run has only the legacy
# live ledger; the helper falls back to it and resumes at the same integer
# it would from an equivalent PROGRESS.md fixture (test 013).

@test "009d: legacy-only SUMMARY.md (no PROGRESS.md), P1 ancestor -> resume 2, COMPLETE 1" {
  sha1=$(_commit p1)
  cat > "$PLAN/SUMMARY.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._
EOF
  _run_helper --phases 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- 010: all phases ancestors ------------------------------------------------

@test "010: P1 P2 P3 all ancestors -> resume 4, COMPLETE 1 2 3" {
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  sha3=$(_commit p3)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: $sha2

_No notes._

## Phase 3, Third
Commit: $sha3

_No notes._
EOF
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "4" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha2" ]
  [ "${lines[3]}" = "COMPLETE 3 $sha3" ]
  [ "${#lines[@]}" -eq 4 ]
}

# --- 011: HALTED block superseded by a later completion (last-block-wins) ---

@test "011: HALTED Phase 2 block superseded by a later completion block -> resume 3, COMPLETE 1 2" {
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second (HALTED)

Ran out of budget before finishing.

## Phase 2, Second
Commit: $sha2

_No notes._
EOF
  _run_helper --phases 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha2" ]
  [ "${#lines[@]}" -eq 3 ]
}

# --- 012a-c: per-block ambiguity (P2 unverifiable, P1 still counts) ---------

@test "012a: P2 block has no Commit anchor (first content line is prose) -> resume 2, COMPLETE 1 only" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second

This block has no Commit anchor, just prose as the first content line.
EOF
  _run_helper --phases 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "012b: P2 Commit is not a valid sha token -> resume 2, COMPLETE 1 only" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: not-a-sha

_No notes._
EOF
  _run_helper --phases 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "012c: P2 Commit is a well-formed but non-existent sha -> resume 2, COMPLETE 1 only" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: 0000000000000000000000000000000000000000

_No notes._
EOF
  _run_helper --phases 2
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- 012d: unresolvable git context is a GLOBAL condition -------------------
# With --git-dir at a non-repo, every ancestry check fails, including P1's.
# Distinct from 012a-c (per-block ambiguity, where P1 still verifies).

@test "012d: --git-dir at a non-repo makes every ancestry check fail, incl. P1 -> resume 1, no COMPLETE lines" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._
EOF
  NONREPO="$(mktemp -d -t gaia-resume-nonrepo-XXXXXX)"
  run bash "$SCRIPT" --git-dir "$NONREPO" --plan-dir "$PLAN" --phases 2
  rm -rf "$NONREPO"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${#lines[@]}" -eq 1 ]
}

# --- 013: canonical single-phase block --------------------------------------

@test "013: canonical block (Commit is the first content line), ancestor -> resume 2, COMPLETE 1" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._
EOF
  _run_helper --phases 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- 014: number-bounded match (Phase 3 must never match Phase 30) ---------

@test "014: P1 P2 ancestors, P3 non-ancestor, plus a Phase 30 ancestor block never counted as P3 -> resume 3, COMPLETE 1 2" {
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  sha3=$(_commit p3)
  git -C "$REPO" reset --hard --quiet HEAD~1
  sha30=$(_commit p30)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: $sha2

_No notes._

## Phase 3, Third
Commit: $sha3

_No notes._

## Phase 30, Thirtieth
Commit: $sha30

_No notes._
EOF
  _run_helper --phases 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha2" ]
  [ "${#lines[@]}" -eq 3 ]
  ! grep -qF -- "COMPLETE 3 " <<<"$output"
}

# --- 015: delimiter-agnostic parse (dash form) ------------------------------
# The doc-grep style guard that both plan.md and the concept page use the
# comma form is Phase 2's job; this asserts only that the parser itself
# resolves a dash-form heading.

@test "015: dash-form heading (## Phase 1 - X) parses the same as comma form -> resume 2, COMPLETE 1" {
  sha1=$(_commit p1)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1 - First
Commit: $sha1

_No notes._
EOF
  _run_helper --phases 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${#lines[@]}" -eq 2 ]
}

# --- 016 / 016b / 016c: worktree-HEAD discriminator -------------------------
# Proves the ancestry check runs against --branch, not main HEAD.

@test "016: P1 Commit reachable only from the wt branch -> --branch wt resume 2, COMPLETE 1" {
  _commit base
  git -C "$REPO" checkout --quiet -b wt
  wtsha=$(_commit wt-only)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $wtsha

_No notes._
EOF
  _run_helper --branch wt --phases 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "2" ]
  [ "${lines[1]}" = "COMPLETE 1 $wtsha" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "016b: P1 Commit absent from wt HEAD -> --branch wt resume 1, no COMPLETE" {
  _commit base
  git -C "$REPO" checkout --quiet -b wt
  git -C "$REPO" checkout --quiet main
  mainsha=$(_commit main-only)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $mainsha

_No notes._
EOF
  _run_helper --branch wt --phases 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "016c: same wtsha fixture but --branch main -> resume 1 (ref matters, discriminator)" {
  _commit base
  git -C "$REPO" checkout --quiet -b wt
  wtsha=$(_commit wt-only)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $wtsha

_No notes._
EOF
  _run_helper --branch main --phases 1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1" ]
  [ "${#lines[@]}" -eq 1 ]
}

# --- 019: no --phases -> first gap beyond recorded blocks, never all-complete

@test "019: no --phases flag, P1 P2 ancestors -> resume 3, COMPLETE 1 2 (never an all-complete signal)" {
  sha1=$(_commit p1)
  sha2=$(_commit p2)
  cat > "$PLAN/PROGRESS.md" <<EOF
## Phase 1, First
Commit: $sha1

_No notes._

## Phase 2, Second
Commit: $sha2

_No notes._
EOF
  run bash "$SCRIPT" --git-dir "$REPO" --plan-dir "$PLAN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "3" ]
  [ "${lines[1]}" = "COMPLETE 1 $sha1" ]
  [ "${lines[2]}" = "COMPLETE 2 $sha2" ]
  [ "${#lines[@]}" -eq 3 ]
}
