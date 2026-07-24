#!/usr/bin/env bats
# End-to-end: a refusal must brief its own repair.
#
# This suite stages the exact situation that dead-ends the merge protocol. A
# dispatched Code Audit Team member reviews the content, finds real defects,
# and withholds its clearance. The orchestrator then gets nothing back: the
# member's returned text does not reliably route back to it, so everything the
# operator can act on has to already be on disk.
#
# A refusal is absolute and is retired only by its author, either by a repair
# that rotates the digest or by an explicit --supersede-refusal. An orchestrator
# that cannot learn what was refused can legitimately do neither: it can guess
# at an edit, which rotates the digest and buys a fresh refusal, or it can
# supersede with a reason it is not in a position to state. Re-dispatching is
# the only move that feels legitimate, and it returns the same empty hand every
# time. That is a loop, not an unlucky run, and this suite is the thing that
# keeps it closed.
#
# Every test below runs against the REAL scripts, with the member's returned
# text DELIBERATELY DISCARDED (a token-free stand-in), so nothing can pass by
# reading a channel the protocol cannot rely on.
#
# The three assertions the round-trip has to make:
#   1. the report artifact exists, with file and line populated
#   2. the carry-forward ledger is written
#   3. the classifier answers "refused", not "noop"
#
# Assertion style (.claude/rules/bats-assertions.md): macOS's system bash 3.2
# does not fail a @test on a false bare `[[ ]]` that is not the last command,
# so non-final checks use POSIX `[ ]`, `grep -q`, or an explicit `return 1`, and
# an absence assertion is written as `<bad-case> && return 1`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  FINDINGS_WRITER="$THIS_DIR/../audit-write-findings.sh"
  CLEARANCE_WRITER="$THIS_DIR/../audit-write-clearance.sh"
  CLASSIFIER="$THIS_DIR/../audit-noop-detect.sh"
  DIGEST_LIB="$THIS_DIR/../../../.claude/hooks/lib/audit-digest.sh"
  [ -x "$FINDINGS_WRITER" ] || skip "audit-write-findings.sh not executable"
  [ -x "$CLEARANCE_WRITER" ] || skip "audit-write-clearance.sh not executable"
  [ -x "$CLASSIFIER" ] || skip "audit-noop-detect.sh not executable"
  [ -f "$DIGEST_LIB" ] || skip "audit-digest.sh not present"
  command -v jq >/dev/null 2>&1 || skip "jq required"

  MEMBER="code-audit-maintainer-shell"

  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/.gaia" "$ROOT/.claude/hooks"
  printf '1.6.1\n' > "$ROOT/.gaia/VERSION"
  git -C "$ROOT" init --quiet --initial-branch=main
  git -C "$ROOT" config user.email "test@example.com"
  git -C "$ROOT" config user.name "Test"
  git -C "$ROOT" config commit.gpgsign false
  printf '#!/usr/bin/env bash\necho base\n' > "$ROOT/.claude/hooks/guard.sh"
  git -C "$ROOT" add .gaia/VERSION .claude/hooks/guard.sh
  git -C "$ROOT" commit --quiet -m "base"
  BASE="$(git -C "$ROOT" rev-parse HEAD)"

  # The work under review, on its own branch: the audit key's branch half is a
  # real discriminator rather than trivially "main".
  git -C "$ROOT" checkout --quiet -b "fix/guard-holes"
  printf '#!/usr/bin/env bash\necho widened\n' > "$ROOT/.claude/hooks/guard.sh"
  git -C "$ROOT" add .claude/hooks/guard.sh
  git -C "$ROOT" commit --quiet -m "widen the guard"
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"

  AUDIT_DIR="$ROOT/.gaia/local/audit"
  # gaia_key_slug percent-encodes "/" as "%2F". Spelled out rather than derived,
  # so a change to the key rule fails here instead of agreeing with itself.
  TAG="${BASE}.fix%2Fguard-holes"
  SIDECAR="$AUDIT_DIR/${TAG}.${MEMBER}.findings.json"
  LEDGER="$AUDIT_DIR/${TAG}.rerun.json"

  DIGEST="$(bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$DIGEST_LIB" "$ROOT" "$MEMBER")"
  [ -n "$DIGEST" ] || skip "cannot derive a member digest in the fixture"
  MARKER="$AUDIT_DIR/${DIGEST}.${MEMBER}.ok"
  REFUSAL="$AUDIT_DIR/${DIGEST}.${MEMBER}.refused"

  # What the orchestrator actually receives. A member dispatched as a background
  # teammate routes no report back, so the only thing that arrives is an idle
  # notice. Every assertion below has to survive this being useless.
  RETURN_TEXT="$BATS_TEST_TMPDIR/return.txt"
  printf 'Agent is idle.\n' > "$RETURN_TEXT"
}

# stage_refusal: what a refusing member does, in the order its remit specifies.
# Step 0 writes the report of record; the refusal is recorded after it, with the
# same base, so the refusal write can derive the carry-forward ledger from it.
stage_refusal() {
  bash "$FINDINGS_WRITER" \
    --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings - >/dev/null <<'JSON'
[
  {"finding_class":"holistic/secret-exposure","severity":"error",
   "path":".claude/hooks/guard.sh","line":113,
   "title":"the expansion-then-path arm admits arbitrary trailing text",
   "failure_mode":"once a separator follows the closing brace the tail is unbounded over the character set a literal secret uses, so a live token assigned behind one is allowed through",
   "verified_by":"ran the hook on the braced-expansion fixture at base and at HEAD: base denies, HEAD allows",
   "suggested_fix":"bound each trailing segment so a token-length run exceeds the bound, keeping the ordinary path case"},
  {"finding_class":"holistic/swallowed-error","severity":"warning",
   "path":".claude/hooks/guard.sh","line":59,
   "title":"a trailing shell comment defeats the value extraction",
   "failure_mode":"the extraction strips quotes but nothing past the value, so the rest of the line becomes the value and no allowlist arm matches, denying an ordinary secret-free export",
   "verified_by":"ran the hook on an export carrying a trailing comment: base allows, HEAD denies",
   "suggested_fix":"strip a trailing comment and any trailing operator clause before the allowlist runs"}
]
JSON
  bash "$CLEARANCE_WRITER" \
    --root "$ROOT" --member "$MEMBER" --provenance refused --base "$BASE" >/dev/null
}

# classify: the no-op classifier, exactly as the workflow page calls it.
classify() {
  bash "$CLASSIFIER" --shape audit-team-member \
    --path "$RETURN_TEXT" --marker "$MARKER" "$@"
}

# =============================================================================
# The round-trip: all three assertions in one test, because the point is that
# they hold TOGETHER. Any one of them alone still leaves the operator stuck.
# =============================================================================

@test "a staged refusal round-trips: report with file and line, ledger written, classifier says refused" {
  stage_refusal

  # 1. The report artifact exists, and it locates the defects.
  [ -f "$SIDECAR" ]
  [ "$(jq -r .member "$SIDECAR")" = "$MEMBER" ]
  [ "$(jq '.findings | length' "$SIDECAR")" = "2" ]
  # Every finding names a file and a line. Not "the first one does": a report
  # that locates half its findings is not a report.
  [ "$(jq '[.findings[] | select((.path | type) == "string" and (.path | length) > 0)] | length' "$SIDECAR")" = "2" ]
  [ "$(jq '[.findings[] | select((.line | type) == "number" and .line >= 1)] | length' "$SIDECAR")" = "2" ]
  [ "$(jq -r '.findings[0].path' "$SIDECAR")" = ".claude/hooks/guard.sh" ]
  [ "$(jq -r '.findings[0].line' "$SIDECAR")" = "113" ]

  # 2. The carry-forward ledger is written, keyed to the incremental base.
  [ -f "$LEDGER" ]
  [ "$(jq -r .base_sha "$LEDGER")" = "$BASE" ]
  [ "$(jq -r .branch "$LEDGER")" = "fix/guard-holes" ]
  [ "$(jq '.remaining | length' "$LEDGER")" = "2" ]

  # 3. The classifier answers refused, not noop. Exit 0 means "do not retry".
  run classify
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

# =============================================================================
# Each assertion again on its own, so a regression names itself instead of
# arriving as one failing composite.
# =============================================================================

@test "1. the report locates every finding and names its defect, evidence, and repair" {
  stage_refusal
  entry="$(jq -c '.findings[0]' "$SIDECAR")"
  grep -qF "arbitrary trailing text" <<<"$(jq -r .title <<<"$entry")"
  grep -qF "unbounded over the character set" <<<"$(jq -r .failure_mode <<<"$entry")"
  grep -qF "base denies, HEAD allows" <<<"$(jq -r .verified_by <<<"$entry")"
  grep -qF "bound each trailing segment" <<<"$(jq -r .suggested_fix <<<"$entry")"
  # The recurrence tally's own field is present too, defaulted from the path.
  [ "$(jq -r '.findings[0].area_tags[0]' "$SIDECAR")" = ".claude/hooks" ]
}

@test "1. a finding that cannot be located never reaches the report at all" {
  # The writer refuses the write rather than recording a thinner entry, which is
  # what makes assertion 1 an invariant instead of a hope.
  run bash "$FINDINGS_WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" --findings - <<'JSON'
[{"finding_class":"holistic/secret-exposure","severity":"error",
  "title":"something is wrong somewhere",
  "failure_mode":"unclear","verified_by":"read it","suggested_fix":"fix it"}]
JSON
  [ "$status" -eq 2 ]
  grep -qF "path must be" <<<"$output"
  [ -f "$SIDECAR" ] && return 1
  return 0
}

@test "2. the ledger carries the repair, not just the fact that something is open" {
  stage_refusal
  entry="$(jq -c '.remaining[0]' "$LEDGER")"
  [ "$(jq -r .member <<<"$entry")" = "$MEMBER" ]
  [ "$(jq -r .path <<<"$entry")" = ".claude/hooks/guard.sh" ]
  [ "$(jq -r .line <<<"$entry")" = "113" ]
  # The sidecar's severity scale is mapped onto the ledger's.
  [ "$(jq -r .severity <<<"$entry")" = "critical" ]
  [ "$(jq -r '.remaining[1].severity' "$LEDGER")" = "important" ]
  grep -qF "base denies, HEAD allows" <<<"$(jq -r .verified_by <<<"$entry")"
  grep -qF "bound each trailing segment" <<<"$(jq -r .suggested_fix <<<"$entry")"
  [ "$(jq -r .round "$LEDGER")" = "1" ]
  [ "$(jq -r .head_sha "$LEDGER")" = "$HEAD_SHA" ]
}

@test "3. the classifier never calls a refusal a no-op, even with the findings gate armed" {
  stage_refusal
  run classify --findings "$SIDECAR"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "3. the refusal is what settles it: with no refusal on disk the same inputs are a no-op" {
  # The control. Everything else is identical, so the verdict above cannot be
  # coming from the return text or from the sidecar's mere presence.
  bash "$FINDINGS_WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" \
    --findings - >/dev/null <<'JSON'
[{"finding_class":"holistic/secret-exposure","severity":"error",
  "path":".claude/hooks/guard.sh","line":113,"title":"t",
  "failure_mode":"f","verified_by":"v","suggested_fix":"s"}]
JSON
  [ -f "$SIDECAR" ]
  [ -f "$REFUSAL" ] && return 1
  run classify --findings "$SIDECAR"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

# =============================================================================
# The loop this closes: what the orchestrator can do with the artifacts alone.
# =============================================================================

@test "the operator can name every finding from artifacts alone, with the return discarded" {
  stage_refusal
  # The return text carries nothing: no location token, no report, nothing but
  # an idle notice. This is the recorded real-world case, not a pessimistic one.
  grep -qE '`[^`]+:[0-9]+`' "$RETURN_TEXT" && return 1
  # Everything needed to act is still reachable, from the ledger alone.
  brief="$(jq -r '.remaining[] | "\(.path):\(.line) \(.title) -- \(.suggested_fix)"' "$LEDGER")"
  [ "$(printf '%s\n' "$brief" | grep -c .)" = "2" ]
  grep -qF ".claude/hooks/guard.sh:113" <<<"$brief"
  grep -qF ".claude/hooks/guard.sh:59" <<<"$brief"
}

@test "the repair retires the refusal by rotating the digest, no supersede needed" {
  stage_refusal
  [ -f "$REFUSAL" ]
  # Repairing the finding edits a file the member owns, which rotates its digest
  # and invalidates the refusal with it. This is the legitimate exit from the
  # loop, and it is only reachable by an operator who learned what to repair.
  printf '#!/usr/bin/env bash\necho repaired\n' > "$ROOT/.claude/hooks/guard.sh"
  git -C "$ROOT" add .claude/hooks/guard.sh
  git -C "$ROOT" commit --quiet -m "bound the trailing segment"
  new_digest="$(bash -c '. "$1"; audit_member_digest "$2" "$3"' _ "$DIGEST_LIB" "$ROOT" "$MEMBER")"
  [ -n "$new_digest" ]
  [ "$new_digest" != "$DIGEST" ]
  # The stale refusal no longer answers for the new content: the classifier for
  # the fresh dispatch finds no refusal at its own key and falls through.
  run bash "$CLASSIFIER" --shape audit-team-member --path "$RETURN_TEXT" \
    --marker "$AUDIT_DIR/${new_digest}.${MEMBER}.ok"
  [ "$status" -eq 1 ]
  [ "$output" = "noop" ]
}

@test "a second round of the same refusal accumulates rather than resetting" {
  stage_refusal
  [ "$(jq -r .round "$LEDGER")" = "1" ]
  stage_refusal
  [ "$(jq -r .round "$LEDGER")" = "2" ]
  # A finding open since round 1 says so, which is how an operator sees that
  # re-dispatching changed nothing.
  [ "$(jq -r '.remaining[0].first_seen_round' "$LEDGER")" = "1" ]
  run classify --findings "$SIDECAR"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "a plain earned write never clears the refusal: the classifier still says refused" {
  stage_refusal
  bash "$FINDINGS_WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" \
    --findings - >/dev/null <<<'[]'
  bash "$CLEARANCE_WRITER" --root "$ROOT" --member "$MEMBER" \
    --provenance earned --base "$BASE" >/dev/null
  # Both markers sit on disk. The anti-gaming invariant is that a bare re-run
  # cannot retire a refusal, and the classifier agrees with the merge gate:
  # refusal-first, so re-running until it passes buys nothing.
  [ -f "$MARKER" ]
  [ -f "$REFUSAL" ]
  run classify --findings "$SIDECAR"
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "an explicit supersede retires the refusal and the spent ledger together" {
  stage_refusal
  [ -f "$LEDGER" ]
  # The other legitimate exit, for content that did not move: the member
  # re-audits, finds the blocker acknowledged, and says so in writing.
  bash "$FINDINGS_WRITER" --root "$ROOT" --member "$MEMBER" --base "$BASE" \
    --findings - >/dev/null <<<'[]'
  bash "$CLEARANCE_WRITER" --root "$ROOT" --member "$MEMBER" \
    --provenance earned --base "$BASE" \
    --supersede-refusal "operator acknowledged the unaddressed Important with a stated reason" >/dev/null
  [ -f "$REFUSAL" ] && return 1
  [ "$(jq -r '.supersedes.provenance' "$MARKER")" = "refused" ]
  # No member has anything left, so the ledger is spent and goes away.
  [ -f "$LEDGER" ] && return 1
  # Now, and only now, the dispatch classifies real: an earned marker plus its
  # report of record.
  run classify --findings "$SIDECAR"
  [ "$status" -eq 0 ]
  [ "$output" = "real" ]
}
