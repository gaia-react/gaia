#!/usr/bin/env bats
#
# Bats suite for the dollar-cost figure SPEC-022 adds to every cost.json record
# token-tally.sh writes (the `spec`/`plan`/`execute` keyed sidecar's `dollars`
# and `rate_table_id` fields, same value as the central ledger row).
# Every fixture below is either REUSED from an existing suite (never re-derived
# here) or a HAND-AUTHORED oracle: expected dollar figures are computed by hand
# in the comments, then cross-checked once against the real jq pipeline (the
# lesson from token-cost-e2e.bats: a silently-guarded jq pipeline can mask a
# wrong answer).
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. Follows the
# token-cost-e2e.bats reference pattern.
#
# Fixtures:
#
#   fixtures/token-tally/multimodel/projects (session fixturemultimodel0001,
#     REUSED). by_model, hand-computed (see token-tally.bats):
#       claude-opus-4-8:   fresh=300 cw5m=40  cw1h=360 cread=3000 output=30
#       claude-sonnet-4-6: fresh=30  cw5m=10  cw1h=20  cread=3000 output=3
#     aggregate total=6793.
#
#   fixtures/token-tally/projects (session fixturesession0001, REUSED). A
#     legacy, model-less transcript -> BY_MODEL={} -> dollars null (no
#     attribution). Buckets 100/1000/10000/10, total 11110 -- all hand-computed
#     in token-tally.bats, never re-derived here.
#
#   fixtures/token-cost-e2e/rates.json (REUSED): opus input 500/output 2500,
#     sonnet input 300/output 1500. Against the multimodel by_model:
#       opus:    (300*500 + 40*500*1.25 + 360*500*2.0 + 3000*500*0.1 + 30*2500) / 1e6 = 0.76
#       sonnet:  (30*300  + 10*300*1.25 + 20*300*2.0  + 3000*300*0.1 + 3*1500)  / 1e6 = 0.11925
#       combined = 0.87925 (the raw `dollars` figure the record carries, unrounded)
#
#   fixtures/token-tally-price/rates-missing-sonnet.json (AUTHORED): only
#     claude-opus-4-8 (same 500/2500 as the e2e table) + cache_multipliers, no
#     sonnet row -> opus prices to 0.76 alone (sonnet's tokens are simply
#     excluded from the sum; the record has no field naming the unpriced model).
#
#   fixtures/token-tally-price/rates-missing-both.json (AUTHORED): a well-formed
#     table naming only claude-haiku-4-5, so BOTH of the multimodel run's models
#     are unpriced. The two-model case is what pins the join separator; a
#     one-model list renders identically under any separator.
#
#   fixtures/token-tally-price/rates-intro.json / rates-sticker.json
#     (AUTHORED, UAT-008): each model an array of TWO windows -- an intro row
#     (double the e2e rate: opus 1000/5000, sonnet 600/3000) followed by a
#     sticker row at the e2e rate (opus 500/2500, sonnet 300/1500,
#     effective_through: null). The two files are IDENTICAL except the
#     intro row's effective_through: rates-intro.json dates it "2099-12-31"
#     (after any real TS -- intro wins), rates-sticker.json dates it
#     "2000-01-01" (before any real TS -- intro is filtered out, sticker
#     wins). Because the input/output rate scales linearly, doubling both
#     doubles the raw dollar total: intro 1.7585, sticker 0.87925 (verified
#     directly against the real GAIA_PRICING_JQ_DEFS/priced_row).

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-tally.sh"
  FIX_TALLY="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"
  FIX_E2E="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-cost-e2e" && pwd)"
  FIX_PRICE="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally-price" && pwd)"

  MULTIMODEL="$FIX_TALLY/multimodel/projects"
  LEGACY="$FIX_TALLY/projects"
  RATES_E2E="$FIX_E2E/rates.json"
  RATES_MISSING_SONNET="$FIX_PRICE/rates-missing-sonnet.json"
  RATES_MISSING_BOTH="$FIX_PRICE/rates-missing-both.json"
  RATES_INTRO="$FIX_PRICE/rates-intro.json"
  RATES_STICKER="$FIX_PRICE/rates-sticker.json"

  OUTDIR="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  # Isolated, empty audit-window cache. --action spec/plan consume-on-tally a
  # breadcrumb from --cache-dir (SPEC-032, audit-window-<id>.json); an empty
  # per-test dir keeps the tally off the real .gaia/local/cache, which it would
  # otherwise fall through to and DELETE a developer's live breadcrumb when a
  # fixture id (SPEC-013/SPEC-022) matches the SPEC/PLAN they are mid-audit on.
  # Add --cache-dir "$CACHE" to every new spec/plan invocation (execute never
  # reads a breadcrumb).
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# ---------- 1. UAT-001/UAT-004: priced on all three cost.json keys ----------
@test "UAT-001/UAT-004: multimodel + e2e rates prices 0.87925 via cost.json on plan/execute/spec, token record intact" {
  for action in plan execute spec; do
    out="$BATS_TEST_TMPDIR/out-$action"
    ledger="$BATS_TEST_TMPDIR/ledger-$action.jsonl"
    if [ "$action" = "spec" ]; then
      run bash "$SCRIPT" --action spec --spec-id SPEC-022 \
        --out-dir "$out" --session-id fixturemultimodel0001 \
        --projects-root "$MULTIMODEL" --ledger "$ledger" --rate-table "$RATES_E2E" \
        --cache-dir "$CACHE"
    else
      run bash "$SCRIPT" --action "$action" --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
        --out-dir "$out" --session-id fixturemultimodel0001 \
        --projects-root "$MULTIMODEL" --ledger "$ledger" --rate-table "$RATES_E2E" \
        --cache-dir "$CACHE"
    fi
    [ "$status" -eq 0 ]

    sc="$out/cost.json"
    [ "$(jq -r ".${action}.dollars" "$sc")" = "0.87925" ]
    rtid="$(jq -r ".${action}.rate_table_id" "$sc")"
    case "$rtid" in sha256:*) : ;; *) echo "bad rate_table_id: $rtid" >&2; return 1 ;; esac

    # Existing token record unchanged: buckets, total, duration.
    [ "$(jq -r ".${action}.total" "$sc")" -eq 6793 ]
    [ "$(jq -r ".${action}.duration_available" "$sc")" = "true" ]
  done
}

# UAT-005
@test "UAT-005: rate table missing sonnet -> opus-only dollars via cost.json" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" --rate-table "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]

  # dollars prices only the rated model (opus, 0.76); the unpriced-model NAME
  # marker (sonnet) lived only in the deleted render_tally_body markdown and
  # has no cost.json field to assert (see Deviations from plan).
  [ "$(jq -r '.execute.dollars' "$OUTDIR/cost.json")" = "0.76" ]
}

# ---------- 3. UAT-006: legacy model-less session ----------
@test "UAT-006: legacy model-less session -> dollars null (no attribution), token record intact, exit 0" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$OUTDIR" --session-id fixturesession0001 \
    --projects-root "$LEGACY" --ledger "$LEDGER" --rate-table "$RATES_E2E" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  sc="$OUTDIR/cost.json"
  [ "$(jq -r '.spec.dollars' "$sc")" = "null" ]
  [ "$(jq -r '.spec.rate_table_id' "$sc")" = "null" ]
  [ "$(jq -r '.spec.total' "$sc")" -eq 11110 ]
}

# ---------- 4. UAT-007: rate table unreadable ----------
@test "UAT-007: --rate-table nonexistent -> dollars null, token record intact, exit 0" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" \
    --rate-table "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]

  sc="$OUTDIR/cost.json"
  [ "$(jq -r '.execute.dollars' "$sc")" = "null" ]
  [ "$(jq -r '.execute.total' "$sc")" -eq 6793 ]
}

# ---------- 5. UAT-008: effective-dated selection (intro vs sticker) ----------
@test "UAT-008: effective-dated selection -- intro rate and sticker rate both price via cost.json, and differ" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$BATS_TEST_TMPDIR/out-intro" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-intro.jsonl" \
    --rate-table "$RATES_INTRO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.execute.dollars' "$BATS_TEST_TMPDIR/out-intro/cost.json")" = "1.7585" ]

  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$BATS_TEST_TMPDIR/out-sticker" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-sticker.jsonl" \
    --rate-table "$RATES_STICKER"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.execute.dollars' "$BATS_TEST_TMPDIR/out-sticker/cost.json")" = "0.87925" ]

  # Distinct rate tables -> distinct rate_table_id (proves genuine effective-
  # dated selection against each table's own identity, not a shared figure).
  intro_id="$(jq -r '.execute.rate_table_id' "$BATS_TEST_TMPDIR/out-intro/cost.json")"
  sticker_id="$(jq -r '.execute.rate_table_id' "$BATS_TEST_TMPDIR/out-sticker/cost.json")"
  [ "$intro_id" != "$sticker_id" ]
}

# ---------- 6. UAT-010: unparseable sidecar flips partial ----------
@test "UAT-010: unparseable sidecar flips partial, priced dollars intact via cost.json" {
  cp -R "$MULTIMODEL" "$BATS_TEST_TMPDIR/mmcopy"
  sub="$BATS_TEST_TMPDIR/mmcopy/proj-hash-mm/fixturemultimodel0001/subagents"
  mkdir -p "$sub"
  printf '%s\n' 'this is not json {{{' > "$sub/agent-0009.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$BATS_TEST_TMPDIR/mmcopy" --ledger "$LEDGER" --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]

  sc="$OUTDIR/cost.json"
  [ "$(jq -r '.execute.partial' "$sc")" = "true" ]
  [ "$(jq -r '.execute.dollars' "$sc")" = "0.87925" ]
}

# ================= #1088: unpriced-model surfacing =================
#
# `priced_row` already computes an `unpriced` array naming every claude-* model
# with no row in the rate table, and token-rollup.sh already prints it. The
# tally read only `.dollars` off the same object and discarded the rest, so the
# per-run line a maintainer actually reads was the one surface that could report
# a confidently wrong figure. The tests below pin the record field and both
# stdout shapes.

# ---------- 7 ----------
@test "#1088: an unpriced model is named on the record and in cost.json" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" --rate-table "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]

  # The dollars figure is unchanged (opus-only, 0.76) -- this adds a signal, it
  # does not alter the arithmetic.
  sc="$OUTDIR/cost.json"
  [ "$(jq -r '.execute.dollars' "$sc")" = "0.76" ]
  [ "$(jq -r '.execute.unpriced | join(",")' "$sc")" = "claude-sonnet-4-6" ]

  # Same field on the central ledger row, so a future audit finds affected rows
  # by field rather than by re-deriving which keys the table was missing.
  rec="$(tail -n 1 "$LEDGER")"
  [ "$(jq -r '.unpriced | join(",")' <<<"$rec")" = "claude-sonnet-4-6" ]
}

# ---------- 8 ----------
@test "#1088: a fully priced run carries no unpriced field (no false positive)" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.execute.dollars' "$OUTDIR/cost.json")" = "0.87925" ]
  jq -e '.execute | has("unpriced") | not' "$OUTDIR/cost.json" >/dev/null

  rec="$(tail -n 1 "$LEDGER")"
  jq -e 'has("unpriced") | not' >/dev/null 2>&1 <<<"$rec"
}

# ---------- 9 ----------
@test "#1088: --action command's one-line output marks the figure a lower bound" {
  run bash "$SCRIPT" --action command --command gaia-debt \
    --session-id fixturemultimodel0001 --projects-root "$MULTIMODEL" \
    --ledger "$LEDGER" --rate-table "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]

  # The detector keys on an unpriced MODEL, never on a $0.00 total: this run
  # prices to a plausible non-zero 0.76 and must still be marked.
  grep -qF -- 'unpriced model(s) claude-sonnet-4-6' <<<"$output"
  grep -qF -- '$0.76' <<<"$output"
}

# ---------- 10 ----------
@test "#1088: the multi-line cost block marks the figure a lower bound" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" --rate-table "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]

  grep -qF -- '(lower bound: unpriced model(s) claude-sonnet-4-6)' <<<"$output"
}

# ---------- 11 ----------
@test "#1088: two unpriced models are joined the way token-rollup.sh joins them" {
  run bash "$SCRIPT" --action command --command gaia-debt \
    --session-id fixturemultimodel0001 --projects-root "$MULTIMODEL" \
    --ledger "$LEDGER" --rate-table "$RATES_MISSING_BOTH"
  [ "$status" -eq 0 ]

  # ", ", the separator token-rollup.sh:305 joins its own list with. Under a bare
  # space the pair renders "claude-opus-4-8 claude-sonnet-4-6", which reads as a
  # single hyphenated name. Order follows by_model's key order via to_entries.
  grep -qF -- 'unpriced model(s) claude-opus-4-8, claude-sonnet-4-6' <<<"$output"

  # Neither model priced, so the figure really is $0.00 here -- and it is marked
  # because a MODEL was unpriced, which is the same reason a non-zero mixed run
  # gets marked. The signal does not come from the total.
  grep -qF -- '$0.00' <<<"$output"
}
