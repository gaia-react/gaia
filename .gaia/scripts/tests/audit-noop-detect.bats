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

@test "cra-specialist: large (>64KB) finding block with an early Location token is still REAL, not a pipefail/SIGPIPE misclassification" {
  large="$BATS_TEST_TMPDIR/large-specialist-finding.txt"
  {
    printf -- '- **Category**: correctness\n'
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

# ---------------------------------------------------------------------------
# audit-team-member (return-conformance, optional --marker companion check)
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# audit-team-member: the marker short-circuit fires ONLY on a writer-produced
# EARNED clearance whose body digest equals the filename key. A refused
# artifact (distinct filename, never handed as the .ok marker), a
# legacy/hand-written body, and no marker all fall through to the content
# inspection, which on text carrying neither a backticked path:line token nor
# "Remaining in-scope:" is noop.
# ---------------------------------------------------------------------------

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

@test "audit-team-member: a REFUSED marker (no earned .ok) + token-free text is NO-OP" {
  digest="$(_noop_digest)"
  # Only the refusal artifact exists; the agent's .ok marker path is absent, so
  # the short-circuit is never handed a writer-produced earned marker.
  _noop_write_clearance "$BATS_TEST_TMPDIR/${digest}.refused" "$digest" refused
  run "$SCRIPT" --shape audit-team-member --path "$FIX/shared/reminder-echo.txt" --marker "$BATS_TEST_TMPDIR/${digest}.ok"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
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

# ---------------------------------------------------------------------------
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
# ---------------------------------------------------------------------------

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
