#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (this suite uses `run --separate-stderr`).
bats_require_minimum_version 1.5.0
#
# Bats suite for `.gaia/scripts/token-tally.sh --action review` (SPEC-032
# FC-3/FC-4): standalone code-review-audit cost records, counted exactly once
# and never folded into any phase total.
#
# Reuses two fixtures, both hand-computed (never derived by running the
# helper -- see token-tally.bats's header comment for the full oracle):
#
#   fixtures/token-tally/auditreview/projects (session fixtureauditreview0001)
#     A code-review-audit sidecar (agent-rev0001, two usage lines spanning
#     11:00:00-11:02:00) with one nested general-purpose sub-agent (nest-a,
#     11:01:00, contained in that span) plus a main transcript and two
#     unrelated adversarial-audit sidecars outside the review's window.
#     Review record (rev-a + rev-b + nest-a): fresh=115 cwrite=220 cread=324
#     output=430 total=1089, duration_seconds=120, review_id "agent-rev0001".
#
#   fixtures/token-tally/projects (session fixturesession0001, the anchor
#     fixture from token-tally.bats) carries NO code-review-audit sidecar at
#     all -- the "nothing to record" no-op case.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): non-final
# assertions avoid bare `[[ ... ]]` and `!`-negation; this suite uses
# `[ ... ]`, `jq -e` + explicit status checks, and explicit `return 1`.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-tally.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  AR="$FIX/auditreview/projects"
  AR_SESSION="fixtureauditreview0001"
  ANCHOR="$FIX/projects"
  ANCHOR_SESSION="fixturesession0001"

  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  # Isolated, empty audit-window cache. The one --action spec tally below
  # consume-on-tally a breadcrumb from --cache-dir (SPEC-032, audit-window-<id>
  # .json); an empty per-test dir keeps it off the real .gaia/local/cache, which
  # it would otherwise fall through to and DELETE a developer's live
  # audit-window-SPEC-032.json. (--action review never reads a breadcrumb.)
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

led() { jq -r "$1" "$LEDGER"; }

# ---------- 1. UAT-006/008: associated review record, full field set ----------
@test "1: --action review --spec-id associates the record and carries the full FC-3 field set" {
  run bash "$SCRIPT" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ -f "$LEDGER" ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]

  [ "$(led '.schema_version')" -eq 1 ]
  [ "$(led '.kind')" = "review" ]
  [ "$(led '.spec_id')" = "SPEC-032" ]
  [ "$(led '.plan_id')" = "null" ]
  [ "$(led '.plan_slug')" = "null" ]
  [ "$(led '.source')" = "code-review-audit" ]
  [ "$(led '.review_id')" = "agent-rev0001" ]
  [ "$(led '.session_id')" = "$AR_SESSION" ]

  # hand-computed: rev-a + rev-b + nest-a
  [ "$(led '.buckets.fresh_input')" -eq 115 ]
  [ "$(led '.buckets.cache_write')" -eq 220 ]
  [ "$(led '.buckets.cache_read')" -eq 324 ]
  [ "$(led '.buckets.output')" -eq 430 ]
  [ "$(led '.total')" -eq 1089 ]
  [ "$(led '.duration_seconds')" -eq 120 ]
  [ "$(led '.duration_available')" = "true" ]
  [ "$(led '.started_at')" = "2026-08-01T11:00:00.000Z" ]
  [ "$(led '.ended_at')" = "2026-08-01T11:02:00.000Z" ]

  # full schema-1 field set the dashboard's strict parser requires.
  for f in buckets final kind seq session_id total ts; do
    run jq -e --arg f "$f" 'has($f)' "$LEDGER"
    [ "$status" -eq 0 ]
  done
  [ "$(led '.seq')" -eq 0 ]
  [ "$(led '.final')" = "true" ]

  # never folded into any phase record: this run never invoked spec/plan/
  # execute, so the ledger's one and only row is the review row itself
  # (already asserted above: wc -l == 1, .kind == "review").
}

# ---------- 2. UAT-007/COV-001: ad-hoc review, no partial ----------
@test "2: --action review with no --spec-id/--plan-id/--out-dir is not marked partial (COV-001)" {
  run bash "$SCRIPT" --action review \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(led '.spec_id')" = "null" ]
  [ "$(led '.plan_id')" = "null" ]
  [ "$(led '.source')" = "code-review-audit" ]
  [ "$(led '.partial')" = "false" ]

  # no cost.json sidecar is ever written for a review (not phase-keyed).
  [ ! -f "$BATS_TEST_TMPDIR/cost.json" ]
}

# ---------- 3. Dedup: counted exactly once across repeat runs ----------
@test "3: running --action review twice on the same session writes the row exactly once" {
  run bash "$SCRIPT" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]

  run bash "$SCRIPT" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]
  [ "$(led '.total')" -eq 1089 ]
}

@test "3b: dedup is idempotent across two different callers (Stop-hook vs gh-pr-merge trigger)" {
  # First call associates a spec id (the Stop-hook trigger); the second call
  # (the gh-pr-merge trigger) passes a DIFFERENT association, simulating two
  # independent triggers racing to record the same review run. The dedup key
  # is review_id alone, so the second call must skip, not double-record or
  # overwrite with a different association.
  run bash "$SCRIPT" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --action review --plan-id PLAN-999 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "$LEDGER" | tr -d ' ')" -eq 1 ]
  [ "$(led '.spec_id')" = "SPEC-032" ]
  [ "$(led '.plan_id')" = "null" ]
}

# ---------- 4. No-op when the session has no code-review-audit run ----------
@test "4: --action review on a session with no code-review-audit sidecar writes nothing, exits 0" {
  run bash "$SCRIPT" --action review \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ ! -f "$LEDGER" ]
  grep -qF "no code-review-audit run in session" <<<"$output"
}

# ---------- 5. stdout stays reserved for the phase tally block ----------
@test "5: --action review never writes to stdout; diagnostics land on stderr" {
  run bash "$SCRIPT" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF "Cost (" <<<"$output" && return 1

  run --separate-stderr bash "$SCRIPT" --action review \
    --session-id "$ANCHOR_SESSION" --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/l2.jsonl"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF "no code-review-audit run in session" <<<"$stderr"
}

# ---------- 6. Back-compat: token-rollup.sh ignores kind:"review" rows ----------
@test "6: back-compat -- token-rollup.sh's kind filter excludes a review row from a feature's totals" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$BATS_TEST_TMPDIR/out" --session-id "$AR_SESSION" \
    --projects-root "$AR" --ledger "$LEDGER" --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  spec_total="$(led '.total')"

  run bash "$SCRIPT" --action review --spec-id SPEC-032 \
    --session-id "$AR_SESSION" --projects-root "$AR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  ROLLUP="$SCRIPT_DIR/token-rollup.sh"
  run bash "$ROLLUP" --spec-id SPEC-032 --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # the rollup's spec total reflects ONLY the spec row (214); the review row's
  # much larger total (1089, commified "1,089") must never leak into it.
  grep -qF "  spec:" <<<"$output"
  spec_line="$(grep '  spec:' <<<"$output")"
  case "$spec_line" in
    *"$spec_total"*) : ;;
    *) echo "rollup spec line missing expected total $spec_total: $spec_line" >&2; return 1 ;;
  esac

  # the review row's total (1089, commified "1,089") must never leak in. An
  # `if`-guarded positive match, not `grep ... && return 1`: as the test's
  # LAST statement, a bare `&&` chain would let grep's own non-zero ("no
  # match", the GOOD case) become the test's exit status and fail a passing
  # test (`.claude/rules/bats-assertions.md`).
  if grep -qF "1,089" <<<"$output"; then
    echo "review total leaked into the rollup output" >&2
    return 1
  fi
}
