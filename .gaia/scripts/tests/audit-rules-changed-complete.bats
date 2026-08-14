#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-rules-changed-complete.sh, the two-tier
# reset-predicate completeness check. A global-rules file silently missing
# from AUDIT_GLOBAL_RULES_PATHS fails in the UNDER-resetting direction: a
# member's stale anchor from before that file changed is trusted as sound
# coverage when it is not. Assertion 3 is the one that can catch a file
# nobody classified anywhere, because it walks the machinery set from the
# outside rather than re-checking the same hardcoded lists assertions 1 and 2
# use.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CHECK="$REPO_ROOT/.gaia/scripts/audit-rules-changed-complete.sh"
  RULES_LIB="$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh"
  MACHINERY_LIB="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  [ -f "$CHECK" ] || skip "audit-rules-changed-complete.sh not present"
}

# make_sandbox <dir>: a git-initialized fixture repo carrying an unmodified
# copy of the check and both libraries, ready for a test to mutate one file
# before running. git ls-files needs a real repository since assertion 3
# walks the tracked-file set.
make_sandbox() {
  local sb="$1"
  mkdir -p "$sb/.gaia/scripts" "$sb/.claude/hooks/lib"
  cp "$CHECK" "$sb/.gaia/scripts/audit-rules-changed-complete.sh"
  chmod +x "$sb/.gaia/scripts/audit-rules-changed-complete.sh"
  cp "$RULES_LIB" "$sb/.claude/hooks/lib/audit-rules-changed.sh"
  cp "$MACHINERY_LIB" "$sb/.claude/hooks/lib/audit-machinery.sh"
  git -C "$sb" init -q
  git -C "$sb" add -A
}

@test "positive: the completeness check passes against the committed tree" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "assertion 1 reds: a library whose literal drops a path the lockstep list names" {
  SB="$BATS_TEST_TMPDIR/sandbox-a1"
  make_sandbox "$SB"
  grep -v '^\.gaia/VERSION$' "$RULES_LIB" > "$SB/.claude/hooks/lib/audit-rules-changed.sh"
  git -C "$SB" add -A

  run bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB"
  [ "$status" -ne 0 ]

  err="$(bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB" 2>&1 1>/dev/null || true)"
  grep -qF "not matched by audit_path_is_global_rule: .gaia/VERSION" <<<"$err"
}

@test "assertion 2 reds: a machinery list that drops a path the global list names" {
  SB="$BATS_TEST_TMPDIR/sandbox-a2"
  make_sandbox "$SB"
  grep -v '^\.gaia/VERSION$' "$MACHINERY_LIB" > "$SB/.claude/hooks/lib/audit-machinery.sh"
  git -C "$SB" add -A

  run bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB"
  [ "$status" -ne 0 ]

  err="$(bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB" 2>&1 1>/dev/null || true)"
  grep -qF "not covered by audit_path_is_machinery: .gaia/VERSION" <<<"$err"
}

@test "assertion 3 reds: a machinery file classified nowhere is named" {
  SB="$BATS_TEST_TMPDIR/sandbox-a3-missing"
  make_sandbox "$SB"
  # Swept in as machinery by the .claude/hooks/lib/** prefix entry, and
  # present in none of the global, member, or merely-shared literals.
  printf '#!/usr/bin/env bash\n' > "$SB/.claude/hooks/lib/audit-unclassified-example.sh"
  git -C "$SB" add -A

  run bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB"
  [ "$status" -ne 0 ]

  err="$(bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB" 2>&1 1>/dev/null || true)"
  grep -qF "classified by none of global, member, or merely-shared: .claude/hooks/lib/audit-unclassified-example.sh" <<<"$err"
}

@test "assertion 3 reds: a path in both the global and merely-shared literals is an overlap" {
  SB="$BATS_TEST_TMPDIR/sandbox-a3-overlap"
  make_sandbox "$SB"
  mkdir -p "$SB/.claude/hooks"
  printf '#!/usr/bin/env bash\n' > "$SB/.claude/hooks/local-janitor.sh"
  # local-janitor.sh is already an exact entry in AUDIT_MACHINERY_PATHS and in
  # the check's own AUDIT_MERELY_SHARED_PATHS; adding it inside the
  # AUDIT_GLOBAL_RULES_PATHS heredoc too makes it classified by both tiers at
  # once. The insert must land before the heredoc's own EOF terminator, not
  # merely at the end of the file, or the literal is untouched.
  awk '{print} /^\.claude\/rules\/pr-merge\.md$/{print ".claude/hooks/local-janitor.sh"}' \
    "$RULES_LIB" > "$SB/.claude/hooks/lib/audit-rules-changed.sh"
  git -C "$SB" add -A

  run bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB"
  [ "$status" -ne 0 ]

  err="$(bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB" 2>&1 1>/dev/null || true)"
  grep -qF "more than one tier (overlap): .claude/hooks/local-janitor.sh" <<<"$err"
}

# The partition check's counters all live inside its read loop, and the loop
# reads from a process substitution whose failure `pipefail` cannot see, so a
# broken tracked-file walk would leave assertion 3 vacuously passing while the
# two assertions above still reported normally. An untracked sandbox is the
# cheapest way to drive the walk to zero rows without breaking git itself.
@test "fail-closed: a tracked-file walk yielding no rows is an error, not a clean partition" {
  SB="$BATS_TEST_TMPDIR/norows"
  mkdir -p "$SB/.gaia/scripts" "$SB/.claude/hooks/lib"
  cp "$CHECK" "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  chmod +x "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  cp "$RULES_LIB" "$SB/.claude/hooks/lib/audit-rules-changed.sh"
  cp "$MACHINERY_LIB" "$SB/.claude/hooks/lib/audit-machinery.sh"
  # Initialized but nothing staged, so `ls-files` is legitimately empty.
  git -C "$SB" init -q

  run bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh" "$SB"
  [ "$status" -ne 0 ]
  grep -qF -- "scanned nothing" <<<"$output"
}

@test "fail-closed: a copy with neither library exits non-zero" {
  SB="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$SB/.gaia/scripts"
  cp "$CHECK" "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  chmod +x "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  run bash "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  [ "$status" -ne 0 ]
}

@test "distinct exit code: no repo_root argument and not a git repository" {
  SB="$BATS_TEST_TMPDIR/norepo"
  mkdir -p "$SB/.gaia/scripts" "$SB/.claude/hooks/lib"
  cp "$CHECK" "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  chmod +x "$SB/.gaia/scripts/audit-rules-changed-complete.sh"
  cp "$RULES_LIB" "$SB/.claude/hooks/lib/audit-rules-changed.sh"
  cp "$MACHINERY_LIB" "$SB/.claude/hooks/lib/audit-machinery.sh"

  run bash -c 'cd "$1" && exec bash .gaia/scripts/audit-rules-changed-complete.sh' -- "$SB"
  [ "$status" -eq 2 ]
}
