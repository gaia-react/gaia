#!/usr/bin/env bats
# Tests for `.gaia/scripts/audit-noop-detect.sh` (SPEC-025 plan, FC-1/FC-2).
#
# The helper is the deterministic kernel of the adversarial-audit no-op
# guard: given a caller `--shape` and the on-disk `--path` (a file-backed
# expected output, or a captured thin return), it prints `real`/`noop` and
# exits 0/1 accordingly, or 2 on a usage error. This suite covers every
# FC-2 shape's REAL fixture and its absent/malformed/reminder-echo fixture
# (UAT-001/UAT-007), plus the `--audit-md` companion check and the usage-
# error paths.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so non-final substring/prefix checks
# below use `grep -qF` via the `assert_contains` helper, not `[[ ]]`.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../audit-noop-detect.sh"
  [ -x "$SCRIPT" ] || skip "audit-noop-detect.sh not executable"
  FIX="$THIS_DIR/fixtures/audit-noop"
}

# ---------------------------------------------------------------------------
# Usage errors (exit 2)
# ---------------------------------------------------------------------------

@test "usage error: unknown --shape exits 2" {
  run "$SCRIPT" --shape not-a-real-shape --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 2 ]
}

@test "usage error: missing --path exits 2" {
  run "$SCRIPT" --shape cra-refuter
  [ "$status" -eq 2 ]
}

@test "usage error: missing --shape exits 2" {
  run "$SCRIPT" --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 2 ]
}

@test "usage error: no arguments exits 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# spec-selfreview-file (file-backed)
# ---------------------------------------------------------------------------

@test "spec-selfreview-file: bare top-level array is REAL" {
  run "$SCRIPT" --shape spec-selfreview-file --path "$FIX/spec-selfreview/real-array.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-selfreview-file: object with .findings array is REAL" {
  run "$SCRIPT" --shape spec-selfreview-file --path "$FIX/spec-selfreview/real-findings-obj.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-selfreview-file: wrong shape is NO-OP" {
  run "$SCRIPT" --shape spec-selfreview-file --path "$FIX/spec-selfreview/malformed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "spec-selfreview-file: absent path is NO-OP" {
  run "$SCRIPT" --shape spec-selfreview-file --path "$FIX/spec-selfreview/does-not-exist.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# ---------------------------------------------------------------------------
# spec-findings-file (file-backed) -- covers both 7a lens and completeness critic
# ---------------------------------------------------------------------------

@test "spec-findings-file: non-empty .findings array is REAL" {
  run "$SCRIPT" --shape spec-findings-file --path "$FIX/spec-findings/real.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-findings-file: EMPTY .findings array is REAL (a lens that found nothing still writes one)" {
  run "$SCRIPT" --shape spec-findings-file --path "$FIX/spec-findings/real-empty.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-findings-file: missing .findings key is NO-OP" {
  run "$SCRIPT" --shape spec-findings-file --path "$FIX/spec-findings/malformed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "spec-findings-file: absent path is NO-OP" {
  run "$SCRIPT" --shape spec-findings-file --path "$FIX/spec-findings/does-not-exist.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# ---------------------------------------------------------------------------
# spec-verdict-file (file-backed) -- covers both 7b refuter and the
# completeness-critic refuter (identical shape)
# ---------------------------------------------------------------------------

@test "spec-verdict-file: confirmed is REAL" {
  run "$SCRIPT" --shape spec-verdict-file --path "$FIX/spec-verdict/real-confirmed.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-verdict-file: partial is REAL" {
  run "$SCRIPT" --shape spec-verdict-file --path "$FIX/spec-verdict/real-partial.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-verdict-file: refuted is REAL" {
  run "$SCRIPT" --shape spec-verdict-file --path "$FIX/spec-verdict/real-refuted.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "spec-verdict-file: unrecognized verdict token is NO-OP" {
  run "$SCRIPT" --shape spec-verdict-file --path "$FIX/spec-verdict/malformed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "spec-verdict-file: absent path is NO-OP" {
  run "$SCRIPT" --shape spec-verdict-file --path "$FIX/spec-verdict/does-not-exist.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# ---------------------------------------------------------------------------
# applier-summary (return-conformance) -- optional --audit-md companion check
# ---------------------------------------------------------------------------

@test "applier-summary: .counts present is REAL" {
  run "$SCRIPT" --shape applier-summary --path "$FIX/applier-summary/real-counts.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "applier-summary: .folded present is REAL" {
  run "$SCRIPT" --shape applier-summary --path "$FIX/applier-summary/real-folded.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "applier-summary: neither .counts nor .folded is NO-OP" {
  run "$SCRIPT" --shape applier-summary --path "$FIX/applier-summary/malformed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "applier-summary: harness-reminder-echo return is NO-OP" {
  run "$SCRIPT" --shape applier-summary --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "applier-summary: --audit-md present + existing AUDIT.md is REAL" {
  run "$SCRIPT" --shape applier-summary --path "$FIX/applier-summary/real-counts.json" --audit-md "$FIX/applier-summary/AUDIT.md"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "applier-summary: --audit-md present but AUDIT.md missing is NO-OP" {
  run "$SCRIPT" --shape applier-summary --path "$FIX/applier-summary/real-counts.json" --audit-md "$FIX/applier-summary/does-not-exist.md"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "applier-summary: --audit-md is ignored for other shapes (no crash, no false gate)" {
  run "$SCRIPT" --shape plan-findings --path "$FIX/plan-findings/real.json" --audit-md "$FIX/applier-summary/does-not-exist.md"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

# ---------------------------------------------------------------------------
# plan-findings (return-conformance)
# ---------------------------------------------------------------------------

@test "plan-findings: .dimension + .findings array is REAL" {
  run "$SCRIPT" --shape plan-findings --path "$FIX/plan-findings/real.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "plan-findings: missing .findings is NO-OP" {
  run "$SCRIPT" --shape plan-findings --path "$FIX/plan-findings/malformed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "plan-findings: harness-reminder-echo return is NO-OP" {
  run "$SCRIPT" --shape plan-findings --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# ---------------------------------------------------------------------------
# cra-specialist (return-conformance)
# ---------------------------------------------------------------------------

@test "cra-specialist: exact 'No violations found.' sentinel is REAL (a legit clean result, never a no-op)" {
  run "$SCRIPT" --shape cra-specialist --path "$FIX/cra-specialist/clean.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "cra-specialist: markdown-bold backticked Location finding block is REAL (keys on the backtick token, not a bare 'Location:' substring)" {
  run "$SCRIPT" --shape cra-specialist --path "$FIX/cra-specialist/finding-block.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "cra-specialist: prose with neither sentinel nor finding token is NO-OP" {
  run "$SCRIPT" --shape cra-specialist --path "$FIX/cra-specialist/malformed.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "cra-specialist: harness-reminder-echo return is NO-OP" {
  run "$SCRIPT" --shape cra-specialist --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# ---------------------------------------------------------------------------
# cra-refuter (return-conformance)
# ---------------------------------------------------------------------------

@test "cra-refuter: STANDS is REAL" {
  run "$SCRIPT" --shape cra-refuter --path "$FIX/cra-refuter/stands.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "cra-refuter: prose with no verdict token is NO-OP" {
  run "$SCRIPT" --shape cra-refuter --path "$FIX/cra-refuter/malformed.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "cra-refuter: harness-reminder-echo return is NO-OP" {
  run "$SCRIPT" --shape cra-refuter --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# ---------------------------------------------------------------------------
# audit-team-member (return-conformance, optional --marker companion check)
# ---------------------------------------------------------------------------

@test "audit-team-member: --marker path exists is REAL regardless of --path content" {
  marker="$BATS_TEST_TMPDIR/marker.ok"
  : > "$marker"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: no marker, backticked Location finding is REAL" {
  run "$SCRIPT" --shape audit-team-member --path "$FIX/audit-team-member/finding-block.txt" --marker "$BATS_TEST_TMPDIR/does-not-exist.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: no marker, terse LOCAL return-contract preamble is REAL" {
  run "$SCRIPT" --shape audit-team-member --path "$FIX/audit-team-member/terse-return.txt" --marker "$BATS_TEST_TMPDIR/does-not-exist.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: no marker, harness-reminder-echo return is NO-OP" {
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: no marker, absent --path is NO-OP" {
  run "$SCRIPT" --shape audit-team-member --path "$BATS_TEST_TMPDIR/does-not-exist.txt" --marker "$BATS_TEST_TMPDIR/also-does-not-exist.ok"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: large (>64KB) blocking-dirty report with an early Location token is still REAL, not a pipefail/SIGPIPE misclassification" {
  large="$BATS_TEST_TMPDIR/large-finding.txt"
  {
    printf '### Critical Issues (Must Fix)\n'
    printf -- '- **Location**: `app/foo.ts:42`\n'
    printf -- '- **Issue**: a real finding near the front of a large report.\n'
    # Pad well past a pipe buffer (64KB) so a `printf | grep -q` pipe would
    # SIGPIPE the writer under `pipefail` before the file is fully consumed.
    for _ in $(seq 1 1000); do
      printf '%s\n' "padding padding padding padding padding padding padding padding padding padding"
    done
  } > "$large"
  [ "$(wc -c < "$large" | tr -d ' ')" -gt 65536 ]
  run "$SCRIPT" --shape audit-team-member --path "$large" --marker "$BATS_TEST_TMPDIR/does-not-exist.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

# ---------------------------------------------------------------------------
# Cross-cutting: exit-code-is-the-boolean contract, purity
# ---------------------------------------------------------------------------

@test "exit code is the boolean; stdout is human-readable only" {
  run "$SCRIPT" --shape cra-refuter --path "$FIX/cra-refuter/stands.txt"
  [ "$status" -eq 0 ]
  assert_contains "real"
}

@test "helper makes no writes: an empty cwd gains no new files after a run" {
  workdir="$BATS_TEST_TMPDIR/no-writes-check"
  mkdir -p "$workdir"
  before="$(find "$workdir" -mindepth 1 | wc -l | tr -d ' ')"
  ( cd "$workdir" && "$SCRIPT" --shape cra-refuter --path "$FIX/cra-refuter/stands.txt" >/dev/null )
  after="$(find "$workdir" -mindepth 1 | wc -l | tr -d ' ')"
  [ "$before" = "0" ]
  [ "$after" = "0" ]
}
