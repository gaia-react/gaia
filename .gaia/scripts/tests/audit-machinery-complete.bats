#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-machinery-complete.sh, the gate-machinery
# completeness check. Under per-member digest keying, an unlisted gate-machinery
# file is a fail-open (a change to it rotates no member's key), so the check
# asserts every file in the hardcoded lockstep consumer set is matched by
# audit_path_is_machinery, and turns any gap into a caught error.
#
# Assertion style (.claude/rules/bats-assertions.md): non-final checks use POSIX
# `[ ]`, `grep -q`, or an explicit `|| return 1`, never a bare `[[ ]]`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CHECK="$REPO_ROOT/.gaia/scripts/audit-machinery-complete.sh"
  MACHINERY_LIB="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  [ -f "$CHECK" ] || skip "audit-machinery-complete.sh not present"
}

# ---------------------------------------------------------------------------
# Positive: against the intended final machinery list, the check exits 0.
# ---------------------------------------------------------------------------

@test "positive: the completeness check passes against the committed machinery list" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative: remove a gate file's entry from AUDIT_MACHINERY_PATHS in a sandbox
# copy and prove the check names it and exits non-zero. post-audit-status.sh is
# chosen because it is covered ONLY by its exact entry (no `/**` prefix also
# covers .claude/hooks/*.sh), so removing that one line makes it unmatched.
# ---------------------------------------------------------------------------

@test "negative: a gate file removed from AUDIT_MACHINERY_PATHS is named and exits non-zero" {
  SB="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SB/.gaia/scripts" "$SB/.claude/hooks/lib"
  cp "$CHECK" "$SB/.gaia/scripts/audit-machinery-complete.sh"
  chmod +x "$SB/.gaia/scripts/audit-machinery-complete.sh"
  # A machinery lib with the post-audit-status.sh exact entry stripped.
  grep -v 'post-audit-status.sh' "$MACHINERY_LIB" > "$SB/.claude/hooks/lib/audit-machinery.sh"

  run bash "$SB/.gaia/scripts/audit-machinery-complete.sh"
  [ "$status" -ne 0 ]

  # The unmatched file is named on stderr (bats `run` captures stdout only).
  err="$(bash "$SB/.gaia/scripts/audit-machinery-complete.sh" 2>&1 1>/dev/null || true)"
  grep -qF "post-audit-status.sh" <<<"$err"
}

# ---------------------------------------------------------------------------
# Fail-closed on an unloadable machinery lib: a sandbox copy with no lib/ at all
# cannot classify, so it must exit non-zero, never falsely pass.
# ---------------------------------------------------------------------------

@test "fail-closed: a copy with no machinery lib exits non-zero" {
  SB="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$SB/.gaia/scripts"
  cp "$CHECK" "$SB/.gaia/scripts/audit-machinery-complete.sh"
  chmod +x "$SB/.gaia/scripts/audit-machinery-complete.sh"
  run bash "$SB/.gaia/scripts/audit-machinery-complete.sh"
  [ "$status" -ne 0 ]
}
