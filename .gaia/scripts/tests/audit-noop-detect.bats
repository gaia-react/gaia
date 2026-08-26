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
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../audit-noop-detect.sh"
  [ -x "$SCRIPT" ] || skip "audit-noop-detect.sh not executable"
  FIX="$THIS_DIR/fixtures/audit-noop"
}

# Usage errors (exit 2)

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

# spec-selfreview-file (file-backed)

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

# spec-findings-file (file-backed) -- covers both 7a lens and completeness critic

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

# spec-verdict-file (file-backed) -- covers both 7b refuter and the
# completeness-critic refuter (identical shape)

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

# applier-summary (return-conformance) -- optional --audit-md companion check

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

# plan-findings (return-conformance)

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

# cra-specialist (return-conformance)

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

@test "cra-specialist: large (>64KB) finding block with an early Location token is still REAL, not a pipefail/SIGPIPE misclassification" {
  large="$BATS_TEST_TMPDIR/large-specialist-finding.txt"
  {
    printf -- '- **Category**: correctness\n'
    # shellcheck disable=SC2016  # literal backticks are the finding-location
    # token under test, not a command substitution.
    printf -- '- **Location**: `app/foo.ts:42`\n'
    printf -- '- **Issue**: a real finding near the front of a large report.\n'
    # Pad well past a pipe buffer (64KB) so a `printf | grep -q` pipe would
    # SIGPIPE the writer under `pipefail` before the file is fully consumed.
    for _ in $(seq 1 1000); do
      printf '%s\n' "padding padding padding padding padding padding padding padding padding padding"
    done
  } > "$large"
  [ "$(wc -c < "$large" | tr -d ' ')" -gt 65536 ]
  run "$SCRIPT" --shape cra-specialist --path "$large"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

# cra-refuter (return-conformance)

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

@test "cra-refuter: large (>64KB) content with an early verdict token is still REAL, not a pipefail/SIGPIPE misclassification" {
  large="$BATS_TEST_TMPDIR/large-refuter-verdict.txt"
  {
    printf 'STANDS\n'
    printf -- '- the finding stands on re-review; padding follows.\n'
    # Pad well past a pipe buffer (64KB) so a `printf | grep -q` pipe would
    # SIGPIPE the writer under `pipefail` before the file is fully consumed.
    for _ in $(seq 1 1000); do
      printf '%s\n' "padding padding padding padding padding padding padding padding padding padding"
    done
  } > "$large"
  [ "$(wc -c < "$large" | tr -d ' ')" -gt 65536 ]
  run "$SCRIPT" --shape cra-refuter --path "$large"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

# audit-team-member (return-conformance, optional --marker companion check)

# A writer-produced EARNED clearance short-circuits to real regardless of the
# --path content. Marker EXISTENCE alone no longer suffices: the body must be a
# writer-shaped earned clearance whose `digest` equals the filename key (an
# empty or legacy body falls through, covered below).
@test "audit-team-member: writer-produced EARNED --marker is REAL regardless of --path content" {
  marker="$BATS_TEST_TMPDIR/marker.ok"
  # Filename key is "marker" (stem up to the first dot), so the body digest
  # must equal it for clearance_acceptable.
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-frontend","provenance":"earned","digest":"marker","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' > "$marker"
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

# audit-team-member: the marker short-circuit fires ONLY on a writer-produced
# EARNED clearance whose body digest equals the filename key. A refused
# artifact (distinct filename, never handed as the .ok marker), a
# legacy/hand-written body, and no marker all fall through to the content
# inspection, which on text carrying neither a backticked path:line token nor
# "Remaining in-scope:" is noop.

# _noop_digest: a fixed, deterministic 64-hex string (the new-scheme filename
# key shape), built with printf repetition rather than hand-counted so it can
# never silently drift off 64 characters.
_noop_digest() {
  printf 'ab%.0s' $(seq 1 32)
}

# Write a writer-shaped schema-3 clearance for DIGEST at PATH with PROVENANCE
# (earned|refused), member code-audit-frontend.
_noop_write_clearance() {
  local path="$1" digest="$2" prov="$3"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-frontend","provenance":"%s","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$prov" "$digest" > "$path"
}

@test "audit-team-member: writer-produced EARNED marker + token-free text is REAL" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  _noop_write_clearance "$marker" "$digest" earned
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: writer-produced EARNED specialist marker (<digest>.<member>.ok) is REAL" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.code-audit-maintainer-shell.ok"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-maintainer-shell","provenance":"earned","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":false}\n' "$digest" > "$marker"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: a REFUSED marker (no earned .ok) + token-free text is REFUSED, not NO-OP" {
  digest="$(_noop_digest)"
  # Only the refusal artifact exists; the agent's .ok marker path is absent,
  # which is exactly what a member that reviewed fully and withheld clearance
  # leaves behind. The refusal is proof of life: classifying it NO-OP spends
  # the protocol's single hardened re-dispatch on a member that was never
  # broken and reports the wrong diagnosis to the operator.
  _noop_write_clearance "$BATS_TEST_TMPDIR/${digest}.refused" "$digest" refused
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "audit-team-member: a specialist's REFUSED marker (<digest>.<member>.refused) is REFUSED" {
  digest="$(_noop_digest)"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-maintainer-shell","provenance":"refused","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' "$digest" > "$BATS_TEST_TMPDIR/${digest}.code-audit-maintainer-shell.refused"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.code-audit-maintainer-shell.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "audit-team-member: a refusal attributed to ANOTHER member does not settle this member's run" {
  digest="$(_noop_digest)"
  # The body names a different member than the filename does, so it is not a
  # writer-shaped refusal for THIS dispatch. Identity binding matters here for
  # the same reason it does on the findings sidecar: one member's artifact must
  # never vouch for another's.
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-frontend","provenance":"refused","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' "$digest" > "$BATS_TEST_TMPDIR/${digest}.code-audit-maintainer-shell.refused"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.code-audit-maintainer-shell.ok"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: a legacy-bodied .refused does not settle the run (existence alone never authorizes)" {
  digest="$(_noop_digest)"
  # No .digest / .member / .provenance fields: not writer-shaped, so the
  # refusal arm declines it and the run falls through to content inspection,
  # matching what the earned arm already demands of a legacy marker.
  printf '{"sha":"deadbeef","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","audited_at":"2026-01-01T00:00:00Z"}\n' > "$BATS_TEST_TMPDIR/${digest}.refused"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.ok"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: a REFUSED marker with NO findings sidecar is still REFUSED, never retried as a no-op" {
  digest="$(_noop_digest)"
  # The lost-report gate deliberately does not apply to a refusal. Re-dispatching
  # a refusing member returns the identical empty hand, and that loop is the
  # failure this arm exists to end.
  _noop_write_clearance "$BATS_TEST_TMPDIR/${digest}.refused" "$digest" refused
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$BATS_TEST_TMPDIR/${digest}.ok" \
    --findings "$BATS_TEST_TMPDIR/absent.findings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "audit-team-member: a refusal beside a same-digest earned marker classifies REFUSED (refusal-first precedence)" {
  digest="$(_noop_digest)"
  # The crash window in the supersede path leaves both markers on disk. The
  # merge gate checks the refusal family first; this classifier agrees.
  _noop_write_clearance "$BATS_TEST_TMPDIR/${digest}.ok" "$digest" earned
  _noop_write_clearance "$BATS_TEST_TMPDIR/${digest}.refused" "$digest" refused
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.ok"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "audit-team-member: no marker at all + token-free text is NO-OP (unregressed)" {
  digest="$(_noop_digest)"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.ok"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: legacy-bodied marker + token-free text is NO-OP (existence no longer authorizes real)" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  printf '{"sha":"deadbeef","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","audited_at":"2026-01-01T00:00:00Z"}\n' > "$marker"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$marker"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: large (>64KB) blocking-dirty report with an early Location token is still REAL, not a pipefail/SIGPIPE misclassification" {
  large="$BATS_TEST_TMPDIR/large-finding.txt"
  {
    printf '### Critical Issues (Must Fix)\n'
    # shellcheck disable=SC2016  # literal backticks are the finding-location
    # token under test, not a command substitution.
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

# Cross-cutting: exit-code-is-the-boolean contract, purity

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

# audit-team-member --findings: LOST-REPORT detection.
#
# A member that completes, writes a valid earned marker, and whose report never
# reaches the orchestrator is otherwise indistinguishable from a clean pass:
# marker-presence alone classifies the dispatch REAL, suppresses the one-shot
# retry, and leaves a green gate with zero visible findings. The findings
# sidecar is the member's durable report of record, so when the caller names
# it, the marker short-circuit requires BOTH. Omitting --findings preserves the
# marker-only behavior for the default member and for a run whose base sha did
# not resolve (which writes no sidecar at all).

# _noop_write_findings <path> [json]: a member's findings sidecar. Defaults to
# the clean-pass shape, an EMPTY findings array, which is a real record.
_noop_write_findings() {
  local path="$1" body="${2:-}"
  if [ -z "$body" ]; then
    body='{"schema":1,"member":"code-audit-frontend","findings":[]}'
  fi
  printf '%s\n' "$body" > "$path"
}

@test "audit-team-member: EARNED marker + present findings sidecar is REAL" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  findings="$BATS_TEST_TMPDIR/base.code-audit-frontend.findings.json"
  _noop_write_clearance "$marker" "$digest" earned
  _noop_write_findings "$findings"
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$marker" --findings "$findings"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: LOST REPORT, EARNED marker + ABSENT findings sidecar is NO-OP" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  _noop_write_clearance "$marker" "$digest" earned
  # The marker is valid and the return carries no finding token: exactly the
  # shape of a member whose report was lost in transit.
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$marker" --findings "$BATS_TEST_TMPDIR/never-written.findings.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: EARNED marker + malformed findings sidecar is NO-OP" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  findings="$BATS_TEST_TMPDIR/malformed.findings.json"
  _noop_write_clearance "$marker" "$digest" earned
  # Present but not a findings record: `.findings` is not an array.
  _noop_write_findings "$findings" '{"schema":1,"member":"code-audit-frontend"}'
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$marker" --findings "$findings"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: BACK-COMPAT, omitting --findings keeps the marker-only short-circuit" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  _noop_write_clearance "$marker" "$digest" earned
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: a findings sidecar attributed to ANOTHER member is NO-OP" {
  # The orchestrator hand-builds one sidecar path per dispatched member, and
  # those paths differ only by the member infix. A shape-only check would let
  # member A's sidecar vouch for member B's lost report, which is the very
  # failure this gate closes, so the predicate binds to the audited member.
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.code-audit-maintainer-shell.ok"
  findings="$BATS_TEST_TMPDIR/base.mismatched.findings.json"
  printf '{"version":"1.6.1","schema":3,"member":"code-audit-maintainer-shell","provenance":"earned","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":false}\n' \
    "$digest" > "$marker"

  # A sibling member's sidecar must not satisfy the shell member's gate.
  _noop_write_findings "$findings" '{"schema":1,"member":"code-audit-frontend","findings":[]}'
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$marker" --findings "$findings"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # A sidecar carrying no member attribution at all is equally unacceptable.
  _noop_write_findings "$findings" '{"schema":1,"findings":[]}'
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$marker" --findings "$findings"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # The correctly-attributed sidecar still passes: no false negative.
  _noop_write_findings "$findings" '{"schema":1,"member":"code-audit-maintainer-shell","findings":[]}'
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$marker" --findings "$findings"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member: jq absent, the findings gate degrades to existence, not to blanket acceptance" {
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  findings="$BATS_TEST_TMPDIR/jqless.code-audit-frontend.findings.json"
  _noop_write_clearance "$marker" "$digest" earned
  _noop_write_findings "$findings"

  # Shim PATH rather than an empty one: the script's `#!/usr/bin/env bash`
  # shebang and its basename/cat/grep calls all resolve through PATH, so
  # emptying it fails the run at exec time (127) and tests nothing. Symlink in
  # exactly what the script needs and deliberately leave jq out.
  shim="$BATS_TEST_TMPDIR/nojq-bin"
  mkdir -p "$shim"
  for _c in bash basename cat grep dirname; do
    _p="$(command -v "$_c" 2>/dev/null)" || continue
    ln -sf "$_p" "$shim/$_c"
  done
  if PATH="$shim" command -v jq >/dev/null 2>&1; then
    skip "jq still resolvable through the shim PATH"
  fi

  # Present sidecar: the marker arm's own jq-absent degradation applies.
  run env PATH="$shim" "$SCRIPT" --shape audit-team-member \
    --path "$FIX/shared/reminder-echo.txt" --marker "$marker" --findings "$findings"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "real" ] || return 1

  # ABSENT sidecar must still be a lost report even with no jq to parse it:
  # the degradation is to existence, never to skipping the gate.
  run env PATH="$shim" "$SCRIPT" --shape audit-team-member \
    --path "$FIX/shared/reminder-echo.txt" --marker "$marker" \
    --findings "$BATS_TEST_TMPDIR/never-written-jqless.findings.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member: absent marker + present findings sidecar falls through to content inspection" {
  findings="$BATS_TEST_TMPDIR/orphan.code-audit-frontend.findings.json"
  _noop_write_findings "$findings"
  # A sidecar cannot stand in for the marker: token-free text is still NO-OP.
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" \
    --marker "$BATS_TEST_TMPDIR/does-not-exist.ok" --findings "$findings"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # ...and a real finding token in the return still classifies REAL.
  run "$SCRIPT" --shape audit-team-member --path "$FIX/audit-team-member/finding-block.txt" \
    --marker "$BATS_TEST_TMPDIR/does-not-exist.ok" --findings "$findings"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

# audit-team-member --findings-root/--findings-since: the RESOLVE arm of the
# same lost-report gate.
#
# The named-path arm above requires the caller to know where the sidecar will
# land. It cannot: the key's base half is the shared pull-request-wide base,
# which advances one stamp per cleared round, so a path computed once is absent
# from the second round on and the gate reads a healthy round as a lost report.
# These tests pin the two properties that make resolution a replacement rather
# than a relaxation: it finds a sidecar under a base no caller could have named,
# and it still refuses a sidecar that is not THIS round's.
#
# _noop_resolve_repo: a git tree on a branch whose slug needs percent-encoding
# (the `/` is the case that would silently straddle a key boundary unencoded),
# with an empty audit store. `symbolic-ref` rather than `init -b` so the branch
# is set without needing a commit or a git new enough for `-b`.
_noop_resolve_repo() {
  local root="$1" branch="${2:-debt/1537-example}"
  mkdir -p "$root/.gaia/local/audit"
  git -C "$root" init -q
  git -C "$root" symbolic-ref HEAD "refs/heads/$branch"
}

# _noop_resolve_sidecar_at <root> <base-sha> <slug> <member> [json]: write a
# sidecar under one specific key. The base sha is a parameter precisely because
# the production value is unpredictable.
_noop_resolve_sidecar_at() {
  local root="$1" base="$2" slug="$3" member="$4" body="${5:-}"
  if [ -z "$body" ]; then
    body="{\"schema\":1,\"member\":\"${member}\",\"findings\":[]}"
  fi
  printf '%s\n' "$body" > "$root/.gaia/local/audit/${base}.${slug}.${member}.findings.json"
}

# _noop_resolve_marker <root> <digest> <member>: the member's earned marker.
_noop_resolve_marker() {
  local root="$1" digest="$2" member="$3"
  printf '{"version":"1.6.1","schema":3,"member":"%s","provenance":"earned","digest":"%s","tree":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","sha":"deadbeef","audited_at":"2026-01-01T00:00:00Z","sidecar":true}\n' \
    "$member" "$digest" > "$root/.gaia/local/audit/${digest}.${member}.ok"
}

@test "audit-team-member resolve arm: a sidecar under a base the caller never named is REAL" {
  root="$BATS_TEST_TMPDIR/resolve-real"
  _noop_resolve_repo "$root"
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  stamp="$BATS_TEST_TMPDIR/resolve-real.stamp"
  : > "$stamp"
  sleep 1
  # A base sha bearing no relation to anything the caller could compute: this
  # is the round-two-onward case that makes the named-path arm read absent.
  _noop_resolve_sidecar_at "$root" 9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f \
    'debt%2F1537-example' code-audit-maintainer-shell
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member resolve arm: only a PREVIOUS round's sidecar is NO-OP" {
  root="$BATS_TEST_TMPDIR/resolve-stale"
  _noop_resolve_repo "$root"
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  # Written BEFORE the wave stamp: a leftover from an earlier round, which is
  # what the pre-clear used to remove when the path was predictable. Resolution
  # alone would return it newest-wins and vouch for a report that never landed.
  _noop_resolve_sidecar_at "$root" 1111111111111111111111111111111111111111 \
    'debt%2F1537-example' code-audit-maintainer-shell
  sleep 1
  stamp="$BATS_TEST_TMPDIR/resolve-stale.stamp"
  : > "$stamp"
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # Non-vacuity control, sampling one mutation on purpose: the same tree with
  # this round's write landing after the stamp classifies REAL, so the NO-OP
  # above is the freshness test firing and not the arm failing to resolve at all.
  sleep 1
  _noop_resolve_sidecar_at "$root" 2222222222222222222222222222222222222222 \
    'debt%2F1537-example' code-audit-maintainer-shell
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member resolve arm: resolving nothing is a lost report, not an absent request" {
  root="$BATS_TEST_TMPDIR/resolve-empty"
  _noop_resolve_repo "$root"
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  stamp="$BATS_TEST_TMPDIR/resolve-empty.stamp"
  : > "$stamp"
  # An empty store must NOT fall back to the marker-only short-circuit: that
  # would make the gate disappear in exactly the runs it exists for.
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "audit-team-member resolve arm: another member's and another branch's sidecars do not answer" {
  root="$BATS_TEST_TMPDIR/resolve-identity"
  _noop_resolve_repo "$root"
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  stamp="$BATS_TEST_TMPDIR/resolve-identity.stamp"
  : > "$stamp"
  sleep 1

  # Fresh, on this branch, but a sibling member's: the member half of the glob
  # is literal, so it is not even a candidate.
  _noop_resolve_sidecar_at "$root" 3333333333333333333333333333333333333333 \
    'debt%2F1537-example' code-audit-maintainer-node
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # Fresh, this member, but another branch's: the audit store is shared across
  # worktrees, so the branch half is what keeps one tree out of another's gate.
  _noop_resolve_sidecar_at "$root" 4444444444444444444444444444444444444444 \
    'other%2Fbranch' code-audit-maintainer-shell
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # Right filename, wrong attribution inside: the `.member` check still binds
  # identity after resolution, exactly as it does on the named-path arm.
  _noop_resolve_sidecar_at "$root" 5555555555555555555555555555555555555555 \
    'debt%2F1537-example' code-audit-maintainer-shell \
    '{"schema":1,"member":"code-audit-maintainer-node","findings":[]}'
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # ...and the correctly-attributed one still passes: no false negative.
  _noop_resolve_sidecar_at "$root" 6666666666666666666666666666666666666666 \
    'debt%2F1537-example' code-audit-maintainer-shell
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member resolve arm: a sibling's NEWER sidecar does not shadow this member's own" {
  # The identity binding is two-layered, and this pins the outer one. If the
  # glob's member half were a wildcard, the newest-wins walk would select the
  # sibling's file, the `.member` check inside would reject it, and the round
  # would classify NO-OP with this member's report sitting on disk the whole
  # time -- a false lost report that spends the one hardened re-dispatch. The
  # content check alone cannot prevent that, because by the time it runs the
  # wrong file has already won the walk.
  root="$BATS_TEST_TMPDIR/resolve-shadow"
  _noop_resolve_repo "$root"
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  stamp="$BATS_TEST_TMPDIR/resolve-shadow.stamp"
  : > "$stamp"
  sleep 1

  _noop_resolve_sidecar_at "$root" 7777777777777777777777777777777777777777 \
    'debt%2F1537-example' code-audit-maintainer-shell
  sleep 1
  # Co-dispatched sibling, same wave, finishing later.
  _noop_resolve_sidecar_at "$root" 8888888888888888888888888888888888888888 \
    'debt%2F1537-example' code-audit-maintainer-node

  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member resolve arm: an unresolvable branch half fails closed" {
  # The resolve arm's branch half can legitimately fail to resolve: a detached
  # HEAD answers with nothing, and so does a checkout where the key lib is
  # missing. Both are documented as yielding no resolution, which the gate then
  # reads as a lost report. That direction is the safe one and it is what the
  # caller is told to avoid by omitting the pair when the branch will not
  # resolve, but nothing pinned it: a refactor that let either path fall back to
  # the marker-only short-circuit would make the gate disappear with the suite
  # still green.
  root="$BATS_TEST_TMPDIR/resolve-detached"
  _noop_resolve_repo "$root"
  git -C "$root" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m x
  git -C "$root" checkout -q --detach
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  stamp="$BATS_TEST_TMPDIR/resolve-detached.stamp"
  : > "$stamp"
  sleep 1
  # A sidecar that IS on disk and IS fresh: the only thing standing between it
  # and a REAL verdict is the unresolvable branch half.
  _noop_resolve_sidecar_at "$root" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    'debt%2F1537-example' code-audit-maintainer-shell
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # Non-vacuity control, sampling the one mutation that matters: reattaching the
  # branch resolves the same sidecar and classifies REAL, so the NO-OP above is
  # the branch half failing and not the sidecar being unreadable.
  git -C "$root" checkout -q -B 'debt/1537-example'
  run "$SCRIPT" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]

  # The second path to the same fail-closed outcome: the key lib is missing, so
  # gaia_branch_slug is never defined and the `command -v` guard declines before
  # any branch is read. The tree is still on the resolvable branch and the
  # sidecar is the one that just classified REAL, so the lib's absence is the
  # only variable.
  #
  # A scratch tree rather than a function override, because the script sources
  # both libs from its own on-disk location at call time and would clobber an
  # override in this body. The CLEARANCE lib has to come along: without it the
  # earned-marker arm can never reach REAL on any input, so the run would print
  # noop whatever the findings gate decided and this arm would assert nothing.
  # Reproduce the layout the script's two relative sources expect, and omit
  # exactly one file.
  local bare="$BATS_TEST_TMPDIR/no-keylib"
  mkdir -p "$bare/.gaia/scripts" "$bare/.claude/hooks"
  cp "$SCRIPT" "$bare/.gaia/scripts/audit-noop-detect.sh"
  cp -R "$THIS_DIR/../../../.claude/hooks/lib" "$bare/.claude/hooks/lib"
  [ -f "$bare/.claude/hooks/lib/audit-clearance.sh" ] || return 1
  [ -f "$bare/.gaia/scripts/audit-key-lib.sh" ] && return 1

  run bash "$bare/.gaia/scripts/audit-noop-detect.sh" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]

  # ...and the same scratch tree WITH the key lib restored classifies REAL, so
  # the noop above is the missing lib and not the relocation.
  cp "$THIS_DIR/../audit-key-lib.sh" "$bare/.gaia/scripts/audit-key-lib.sh"
  run bash "$bare/.gaia/scripts/audit-noop-detect.sh" --shape audit-team-member \
    --marker "$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok" \
    --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "audit-team-member resolve arm: every half-passed form of the pair is a usage error" {
  root="$BATS_TEST_TMPDIR/resolve-usage"
  _noop_resolve_repo "$root"
  digest="$(_noop_digest)"
  _noop_resolve_marker "$root" "$digest" code-audit-maintainer-shell
  marker="$root/.gaia/local/audit/${digest}.code-audit-maintainer-shell.ok"
  stamp="$BATS_TEST_TMPDIR/resolve-usage.stamp"
  : > "$stamp"
  named="$BATS_TEST_TMPDIR/resolve-usage.findings.json"
  _noop_write_findings "$named"

  # Each of these degrades the gate rather than erroring if it is let through,
  # so every one fails closed at argument time.
  run "$SCRIPT" --shape audit-team-member --marker "$marker" \
    --findings "$named" --findings-root "$root" --findings-since "$stamp"
  [ "$status" -eq 2 ]

  run "$SCRIPT" --shape audit-team-member --marker "$marker" \
    --findings "$named" --findings-since "$stamp"
  [ "$status" -eq 2 ]

  run "$SCRIPT" --shape audit-team-member --marker "$marker" --findings-root "$root"
  [ "$status" -eq 2 ]

  run "$SCRIPT" --shape audit-team-member --marker "$marker" --findings-since "$stamp"
  [ "$status" -eq 2 ]

  # An absent stamp would make bash's `-nt` accept every sidecar on disk.
  run "$SCRIPT" --shape audit-team-member --marker "$marker" \
    --findings-root "$root" --findings-since "$BATS_TEST_TMPDIR/never-stamped"
  [ "$status" -eq 2 ]

  run "$SCRIPT" --shape audit-team-member --marker "$marker" \
    --findings-root "$BATS_TEST_TMPDIR/not-a-root" --findings-since "$stamp"
  [ "$status" -eq 2 ]
}

@test "audit-team-member: --path is optional, and --path or --marker is required" {
  # An orchestrator that polls artifacts holds no captured return to pass. It
  # must not have to fabricate an empty file, which classifies NO-OP and burns
  # the one hardened re-dispatch on a member that was never broken.
  digest="$(_noop_digest)"
  marker="$BATS_TEST_TMPDIR/${digest}.ok"
  _noop_write_clearance "$marker" "$digest" earned
  run "$SCRIPT" --shape audit-team-member --marker "$marker"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]

  # With neither, there is nothing on disk to read at all.
  run "$SCRIPT" --shape audit-team-member
  [ "$status" -eq 2 ]

  # Every other shape still requires --path.
  run "$SCRIPT" --shape spec-findings-file
  [ "$status" -eq 2 ]
}

# agent-report-file: the generic file-backed report contract for a dispatch
# composed at the point of need.
#
# The shape separates "the agent wrote nothing" from "the agent wrote an empty
# answer", so an empty report is REAL for the same reason spec-findings-file's
# empty findings array is. Without that separation an absent report is
# indistinguishable from a clean result, and the likeliest reading of a missing
# report is the one a caller must not draw, so the failure is biased toward
# false confidence (gaia-react/gaia#1409).
#
# The count assertions pin the same collapse one level down: existence-plus-
# parses alone was not sufficient in the field, because a truncated write
# parses fine and reads as a real result. Only the caller knows its own
# denominator, so only the caller can assert it.

@test "agent-report-file: top-level array is REAL" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: EMPTY top-level array is REAL (an empty answer is a real result)" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-empty-array.json"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: --report-key names the container holding the array" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-keyed.json" \
    --report-key verdicts
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: EMPTY --report-key array is REAL" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-keyed-empty.json" \
    --report-key verdicts
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: absent path is NO-OP" {
  run "$SCRIPT" --shape agent-report-file --path "$BATS_TEST_TMPDIR/never-written.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: malformed JSON is NO-OP" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/malformed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: a parsing scalar is NO-OP (parses, but is not a report container)" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/scalar.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: an object without the named key is NO-OP" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/wrong-key.json" \
    --report-key verdicts
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: an object with no --report-key is NO-OP (the top level must be the array)" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-keyed.json"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: harness-reminder-echo return is NO-OP" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/shared/reminder-echo.txt"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# --expect-count / --min-count: the caller's own denominator

@test "agent-report-file: --expect-count matching the array length is REAL" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count 3
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: a SHORT report under --expect-count is NO-OP (a truncated write parses fine)" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count 18
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: a LONG report over --expect-count is NO-OP (exact means exact)" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count 2
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "agent-report-file: --expect-count 0 accepts a deliberate empty answer" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-empty-array.json" \
    --expect-count 0
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: --expect-count applies through --report-key" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-keyed.json" \
    --report-key verdicts --expect-count 3
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: --min-count met is REAL" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --min-count 3
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: --min-count exceeded is REAL (a floor is not a ceiling)" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --min-count 1
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

@test "agent-report-file: --min-count unmet is NO-OP" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-empty-array.json" \
    --min-count 1
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# Usage errors specific to the count assertions

@test "usage error: --expect-count and --min-count together exits 2" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count 3 --min-count 1
  [ "$status" -eq 2 ]
}

@test "usage error: a non-integer --expect-count exits 2, never a silent permanent no-op" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count three
  [ "$status" -eq 2 ]
}

@test "usage error: a negative --min-count exits 2" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --min-count -1
  [ "$status" -eq 2 ]
}

@test "agent-report-file: the count flags are ignored for other shapes (no crash, no false gate)" {
  run "$SCRIPT" --shape spec-findings-file --path "$FIX/spec-findings/real-empty.json" \
    --expect-count 18
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}

# An EMPTY count is a usage error, never a silently dropped assertion. A caller
# interpolating an unset variable passes one, and gating on the value rather
# than on the flag's presence reads that as "no count asked for": the predicate
# collapses back to existence-plus-parses and a truncated report classifies
# REAL, which is precisely what the flag exists to prevent. It is the fail-open
# direction, so it is pinned in both flags and against a short report.

@test "usage error: an EMPTY --expect-count exits 2, never a silently dropped assertion" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count ""
  [ "$status" -eq 2 ]
}

@test "usage error: an EMPTY --min-count exits 2, never a silently dropped assertion" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --min-count ""
  [ "$status" -eq 2 ]
}

@test "usage error: a trailing --expect-count with no value exits 2" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count
  [ "$status" -eq 2 ]
}

@test "usage error: an EMPTY count is rejected by name, not by a generic fallthrough" {
  # The 3-element fixture satisfies no honest denominator of 18, so an empty
  # count must not launder it into a REAL. Asserting the message names the
  # offending flag is what separates this from the pre-existing
  # unrecognized-argument path, which also exits 2.
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count ""
  [ "$status" -eq 2 ]
  assert_contains "--expect-count must be a non-negative integer"
}

@test "usage error: both count flags passed EMPTY still trip mutual exclusion" {
  run "$SCRIPT" --shape agent-report-file --path "$FIX/agent-report/real-array.json" \
    --expect-count "" --min-count ""
  [ "$status" -eq 2 ]
}
