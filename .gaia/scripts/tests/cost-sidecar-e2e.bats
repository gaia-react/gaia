#!/usr/bin/env bats
#
# End-to-end round-trip oracle for SPEC-029 (Phase 2 of the cost-sidecar plan).
# Phase 1 built the write half (token-tally.sh emits FC-1's cost.json sidecar)
# and the read half (cost-represented.sh reroutes its delete gate to the
# sidecar) independently, each verified against hand-authored fixtures. This
# suite is the ONE test that chains the REAL token-tally.sh into the REAL
# cost_folder_represented, so a field-name / bucket-name / key drift between
# the two halves fails loudly here instead of surfacing later as a silent
# fail-open. Mirrors token-cost-e2e.bats (tally -> rollup); read it as the
# model for this file's shape.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` and `!`-negation (both silently skip a
# false case under bash 3.2 / set -e). This suite uses `[ ... ]`, the
# assert_contains/refute_contains helpers, and explicit `return 1`.
#
# Fixtures (both reused from .gaia/scripts/tests/fixtures/token-tally/,
# authored for token-tally.bats, never re-derived here):
#   single/     (session fixturesingle0001) one usage line, fresh=5 cwrite=50
#     cread=500 output=7 -> total 562. Used for the spec-action tests.
#   multimodel/ (session fixturemultimodel0001) claude-opus-4-8 and
#     claude-sonnet-4-6, aggregate total 6793. Used as the execute half of the
#     plan+execute round-trip, so a clobbered-vs-preserved plan key is obvious.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

refute_contains() {
  if grep -qF -- "$1" <<<"$output"; then
    echo "unexpected match: $1" >&2
    return 1
  fi
}

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TALLY="$SCRIPT_DIR/token-tally.sh"
  GATE="$SCRIPT_DIR/cost-represented.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  SINGLE="$FIX/single/projects"
  MULTIMODEL="$FIX/multimodel/projects"

  OUTDIR="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/cost.jsonl"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# ---------- 1. Sidecar shape from a real tally (UAT-001) ----------
@test "spec action: real tally writes a well-shaped cost.json sidecar, no cost.md" {
  run bash "$TALLY" --action spec --spec-id SPEC-X \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$SINGLE" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ -f "$OUTDIR/cost.json" ]
  [ ! -f "$OUTDIR/cost.md" ]

  jq -e '.spec.kind=="spec" and .spec.spec_id=="SPEC-X"
    and (.spec.buckets|has("fresh_input")) and (.spec|has("total"))' "$OUTDIR/cost.json"
}

# ---------- 2. Round-trip pass (UAT-003) ----------
@test "spec action: gate passes when the real sidecar matches the real ledger row" {
  run bash "$TALLY" --action spec --spec-id SPEC-X \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$SINGLE" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # shellcheck source=/dev/null
  . "$GATE"
  run cost_folder_represented "$OUTDIR" spec_id SPEC-X "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "$(printf 'spec\tREPRESENTED')"
}

# ---------- 3. Round-trip block: mutated bucket, then unparseable (UAT-004) ----------
@test "spec action: gate blocks on a mutated bucket and on unparseable JSON" {
  run bash "$TALLY" --action spec --spec-id SPEC-X \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$SINGLE" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # shellcheck source=/dev/null
  . "$GATE"

  # Mutate one bucket so the sidecar record no longer matches the appended
  # ledger row (its total shifts too, so neither match branch can save it).
  mutated="$(jq '.spec.buckets.output += 1' "$OUTDIR/cost.json")"
  printf '%s' "$mutated" >"$OUTDIR/cost.json"
  run cost_folder_represented "$OUTDIR" spec_id SPEC-X "$LEDGER"
  [ "$status" -ne 0 ]
  assert_contains "$(printf 'spec\tBLOCKING\tno matching ledger row')"

  # A cost.json that is present but not valid JSON is unparseable -> blocking.
  printf 'not json' >"$OUTDIR/cost.json"
  run cost_folder_represented "$OUTDIR" spec_id SPEC-X "$LEDGER"
  [ "$status" -ne 0 ]
  assert_contains "$(printf 'unparseable\tBLOCKING\tunparseable cost.json')"
}

# ---------- 4. Plan sibling preservation round-trip (UAT-002) ----------
@test "plan then execute: gate passes for both sidecar keys, plan key byte-unchanged" {
  run bash "$TALLY" --action plan --plan-id PLAN-X --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$SINGLE" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  before="$(jq -c '.plan' "$OUTDIR/cost.json")"

  run bash "$TALLY" --action execute --plan-id PLAN-X --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  after="$(jq -c '.plan' "$OUTDIR/cost.json")"
  [ "$before" = "$after" ]
  [ "$(jq -r 'keys | sort | join(",")' "$OUTDIR/cost.json")" = "execute,plan" ]

  # shellcheck source=/dev/null
  . "$GATE"
  run cost_folder_represented "$OUTDIR" plan_slug my-plan "$LEDGER"
  [ "$status" -eq 0 ]
  assert_contains "$(printf 'plan\tREPRESENTED')"
  assert_contains "$(printf 'execute\tREPRESENTED')"
  refute_contains 'BLOCKING'
}
