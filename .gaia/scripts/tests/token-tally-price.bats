#!/usr/bin/env bats
#
# Bats suite for the dollar-cost line SPEC-022 adds to every tokens.md section
# token-tally.sh renders (`## Planning`, `## Execution`, the single spec doc).
# Every fixture below is either REUSED from an existing suite (never re-derived
# here) or a HAND-AUTHORED oracle: expected dollar figures are computed by hand
# in the comments, then cross-checked once against the real jq pipeline (the
# lesson from token-cost-e2e.bats: a silently-guarded jq pipeline can mask a
# wrong answer).
#
# Assertion style: bash-3.2-safe (grep -qF / `[ ... ]` / explicit `return 1`),
# per .claude/rules/bats-assertions.md and the token-cost-e2e.bats reference
# pattern -- no bare `[[ ... ]]` for anything but the test's final command.
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
#     legacy, model-less transcript -> BY_MODEL={} -> "per-model attribution
#     unavailable". Buckets 100/1000/10000/10, total 11110, elapsed 125s/2m5s
#     (TMIN 2026-07-02T17:00:00.000Z / TMAX 2026-07-02T17:02:05.000Z), partial
#     false -- all hand-computed in token-tally.bats, never re-derived here.
#
#   fixtures/token-cost-e2e/rates.json (REUSED): opus input 500/output 2500,
#     sonnet input 300/output 1500. Against the multimodel by_model:
#       opus:    (300*500 + 40*500*1.25 + 360*500*2.0 + 3000*500*0.1 + 30*2500) / 1e6 = 0.76
#       sonnet:  (30*300  + 10*300*1.25 + 20*300*2.0  + 3000*300*0.1 + 3*1500)  / 1e6 = 0.11925
#       combined = 0.87925 -> $0.88 (equal to neither model alone)
#
#   fixtures/token-tally-price/rates-missing-sonnet.json (AUTHORED): only
#     claude-opus-4-8 (same 500/2500 as the e2e table) + cache_multipliers, no
#     sonnet row -> opus prices to $0.76 alone, sonnet lands in `.unpriced`.
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
#     doubles the raw dollar total:
#       intro:   opus 0.76*2=1.52, sonnet 0.11925*2=0.2385 -> 1.7585 -> $1.76
#       sticker: opus 0.76,        sonnet 0.11925          -> 0.87925 -> $0.88
#     (verified directly against the real GAIA_PRICING_JQ_DEFS/priced_row, not
#     just hand math -- see the dev notes for the exact jq invocation).

assert_file_has() {
  # assert_file_has <needle> <file>
  grep -qF -- "$1" "$2"
}

refute_file_has() {
  # refute_file_has <needle> <file>
  if grep -qF -- "$1" "$2"; then
    echo "unexpected match in $2: $1" >&2
    return 1
  fi
}

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
  RATES_INTRO="$FIX_PRICE/rates-intro.json"
  RATES_STICKER="$FIX_PRICE/rates-sticker.json"

  OUTDIR="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# ---------- 1. UAT-001/UAT-004: priced on all three surfaces ----------
@test "UAT-001/UAT-004: multimodel + e2e rates prices \$0.88 on plan/execute/spec, token render intact" {
  for action in plan execute spec; do
    out="$BATS_TEST_TMPDIR/out-$action"
    ledger="$BATS_TEST_TMPDIR/ledger-$action.jsonl"
    if [ "$action" = "spec" ]; then
      run bash "$SCRIPT" --action spec --spec-id SPEC-022 \
        --out-dir "$out" --session-id fixturemultimodel0001 \
        --projects-root "$MULTIMODEL" --ledger "$ledger" --rate-table "$RATES_E2E"
    else
      run bash "$SCRIPT" --action "$action" --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
        --out-dir "$out" --session-id fixturemultimodel0001 \
        --projects-root "$MULTIMODEL" --ledger "$ledger" --rate-table "$RATES_E2E"
    fi
    [ "$status" -eq 0 ]

    md="$out/tokens.md"
    assert_file_has '**Est. cost (USD):** $0.88' "$md"
    refute_file_has '$0.76' "$md"
    refute_file_has '$0.12' "$md"

    # Existing token render unchanged: bucket Total row, elapsed line, footer.
    assert_file_has '| **Total** | 6793 |' "$md"
    assert_file_has '**Elapsed (first to last model turn):**' "$md"
    assert_file_has 'generated' "$md"
  done
}

# ---------- 2. UAT-005: unpriced model marker ----------
@test "UAT-005: rate table missing sonnet -> opus-only price + unpriced-model marker naming sonnet" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" --rate-table "$RATES_MISSING_SONNET"
  [ "$status" -eq 0 ]

  md="$OUTDIR/tokens.md"
  assert_file_has '**Est. cost (USD):** $0.76' "$md"
  assert_file_has '_Lower bound: unpriced model(s) claude-sonnet-4-6._' "$md"
  refute_file_has 'synthetic' "$md"
}

# ---------- 3. UAT-006: legacy model-less session ----------
@test "UAT-006: legacy model-less session -> per-model attribution unavailable, token render intact, exit 0" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$OUTDIR" --session-id fixturesession0001 \
    --projects-root "$LEGACY" --ledger "$LEDGER" --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]

  md="$OUTDIR/tokens.md"
  assert_file_has '_Est. cost (USD): unavailable (per-model attribution unavailable)._' "$md"
  assert_file_has '| **Total** | 11110 |' "$md"
  assert_file_has '**Elapsed (first to last model turn):**' "$md"
}

# ---------- 4. UAT-007: rate table unreadable ----------
@test "UAT-007: --rate-table nonexistent -> rate table unreadable marker, token render intact, exit 0" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER" \
    --rate-table "$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 0 ]

  md="$OUTDIR/tokens.md"
  assert_file_has '_Est. cost (USD): unavailable (rate table unreadable)._' "$md"
  assert_file_has '| **Total** | 6793 |' "$md"
}

# ---------- 5. UAT-008: effective-dated selection (intro vs sticker) ----------
@test "UAT-008: effective-dated selection -- intro rate and sticker rate both price, and differ" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$BATS_TEST_TMPDIR/out-intro" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-intro.jsonl" \
    --rate-table "$RATES_INTRO"
  [ "$status" -eq 0 ]
  assert_file_has '**Est. cost (USD):** $1.76' "$BATS_TEST_TMPDIR/out-intro/tokens.md"

  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$BATS_TEST_TMPDIR/out-sticker" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-sticker.jsonl" \
    --rate-table "$RATES_STICKER"
  [ "$status" -eq 0 ]
  assert_file_has '**Est. cost (USD):** $0.88' "$BATS_TEST_TMPDIR/out-sticker/tokens.md"

  # Neither figure leaks into the other table's render (proves genuine
  # effective-dated selection, not two independently-different tables).
  refute_file_has '$1.76' "$BATS_TEST_TMPDIR/out-sticker/tokens.md"
  refute_file_has '$0.88' "$BATS_TEST_TMPDIR/out-intro/tokens.md"
}

# ---------- 6. UAT-009: sibling section copied byte-for-byte ----------
@test "UAT-009: sibling section survives the OTHER section's rewrite byte-for-byte (legacy sibling, then feature-era sibling)" {
  # Arm 1: a LEGACY (pre-feature-shaped) Planning section, hand-crafted with
  # no cost line -- exactly the render_tally_body shape before SPEC-022
  # (bucket table + elapsed line + footer, nothing else).
  out1="$BATS_TEST_TMPDIR/out-legacy-sibling"
  mkdir -p "$out1"
  cat > "$out1/tokens.md" <<'EOF'
# Token cost: SPEC-022 / spec-022-dollar-cost

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 5 |
| Cache write | 6 |
| Cache read | 7 |
| Output | 8 |
| **Total** | 26 |

_Elapsed: unavailable (no readable turn timestamps)._

Session `legacysession0001` · generated 2020-01-01T00:00:00Z
EOF
  plan_slice_before="$(awk '/^## Planning$/{p=1;next} /^## Execution$/{p=0} p' "$out1/tokens.md")"

  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$out1" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-legacy-sibling.jsonl" \
    --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]

  plan_slice_after="$(awk '/^## Planning$/{p=1;next} /^## Execution$/{p=0} p' "$out1/tokens.md")"
  [ "$plan_slice_before" = "$plan_slice_after" ]

  exec_slice="$(awk '/^## Execution$/{p=1;next} p' "$out1/tokens.md")"
  printf '%s\n' "$exec_slice" | grep -qF '**Est. cost (USD):** $0.88'

  pln="$(grep -n '^## Planning$' "$out1/tokens.md" | cut -d: -f1)"
  exn="$(grep -n '^## Execution$' "$out1/tokens.md" | cut -d: -f1)"
  [ "$pln" -lt "$exn" ]

  # Arm 2: a FEATURE-ERA Planning sibling (written by the current script, so
  # it already carries its own cost line) must ALSO survive the Execution
  # rewrite byte-for-byte.
  out2="$BATS_TEST_TMPDIR/out-feature-sibling"
  run bash "$SCRIPT" --action plan --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$out2" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-feature-sibling-plan.jsonl" \
    --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]
  plan2_before="$(awk '/^## Planning$/{p=1;next} /^## Execution$/{p=0} p' "$out2/tokens.md")"
  printf '%s\n' "$plan2_before" | grep -qF '**Est. cost (USD):** $0.88'

  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$out2" --session-id fixturemultimodel0001 \
    --projects-root "$MULTIMODEL" --ledger "$BATS_TEST_TMPDIR/ledger-feature-sibling-exec.jsonl" \
    --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]
  plan2_after="$(awk '/^## Planning$/{p=1;next} /^## Execution$/{p=0} p' "$out2/tokens.md")"
  [ "$plan2_before" = "$plan2_after" ]
}

# ---------- 7. UAT-010: unparseable sidecar flips partial ----------
@test "UAT-010: unparseable sidecar flips partial -- both the existing partial marker and the cost-floor marker render, priced figure intact" {
  cp -R "$MULTIMODEL" "$BATS_TEST_TMPDIR/mmcopy"
  sub="$BATS_TEST_TMPDIR/mmcopy/proj-hash-mm/fixturemultimodel0001/subagents"
  mkdir -p "$sub"
  printf '%s\n' 'this is not json {{{' > "$sub/agent-0009.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-022 --plan-slug spec-022-dollar-cost \
    --out-dir "$OUTDIR" --session-id fixturemultimodel0001 \
    --projects-root "$BATS_TEST_TMPDIR/mmcopy" --ledger "$LEDGER" --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]

  md="$OUTDIR/tokens.md"
  assert_file_has '_Partial: one or more transcript inputs were missing or unparseable; figures are a lower bound._' "$md"
  assert_file_has '**Est. cost (USD):** $0.88' "$md"
  assert_file_has '_Lower bound: some transcript inputs were unreadable; cost is a floor._' "$md"
}

# ---------- 8. UAT-011: byte-identity of the existing lines (full-output diff) ----------
# token-tally.bats is 100% grep -q / substring (33 substring asserts, zero
# equality checks), so it tolerates a whitespace perturbation of an untouched
# line and cannot itself serve as the byte-identity oracle. This test proves
# the cost block is the ONLY additive insertion by comparing against a
# hand-computed golden render of the pre-feature lines (same technique as
# token-price.bats's `expected_prefix` golden literals), not a live git-show
# of a moving HEAD -- once this phase merges, HEAD:token-tally.sh IS the
# post-feature script, so diffing against "git show HEAD" would stop proving
# anything the moment this lands.
@test "UAT-011: cost block is the ONLY additive insertion -- existing lines are byte-identical" {
  run env TZ=UTC bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$OUTDIR" --session-id fixturesession0001 \
    --projects-root "$LEGACY" --ledger "$LEDGER" --rate-table "$RATES_E2E"
  [ "$status" -eq 0 ]

  actual="$(cat "$OUTDIR/tokens.md")"

  # The generation stamp is inherently non-deterministic (real `date -u` at
  # run time); capture the REAL footer line as rendered and reuse it verbatim
  # in the golden expectation, so this proves byte-identity of every OTHER
  # line without pinning wall-clock time.
  footer_line="$(printf '%s\n' "$actual" | tail -n1)"
  case "$footer_line" in
    'Session `fixturesession0001`'*) : ;;
    *) echo "unexpected footer line: $footer_line" >&2; return 1 ;;
  esac

  # Hand-computed pre-feature render (token-tally.bats's anchor fixture
  # derivation: buckets 100/1000/10000/10, total 11110, elapsed 125s/2m5s,
  # TZ=UTC endpoints, partial false -- no partial marker, no cost block).
  golden=$'# Token cost: spec SPEC-013\n\n| Bucket | Tokens |\n| --- | --- |\n| Fresh input | 100 |\n| Cache write | 1000 |\n| Cache read | 10000 |\n| Output | 10 |\n| **Total** | 11110 |\n\n**Elapsed (first to last model turn):** 2m5s (2026-07-02 17:00:00 UTC to 2026-07-02 17:02:05 UTC)\n\n'"$footer_line"

  # Strip the additive cost block (the degrade marker line plus its own
  # trailing blank line) to recover what the pre-feature render would have
  # produced; everything else must diff empty against the golden literal.
  stripped="$(printf '%s' "$actual" | awk '
    /^_Est\. cost \(USD\): unavailable \(per-model attribution unavailable\)\._$/ { skip = 2 }
    skip > 0 { skip--; next }
    { print }
  ')"

  if ! diff <(printf '%s\n' "$golden") <(printf '%s\n' "$stripped"); then
    echo "byte-identity mismatch: existing lines changed beyond the additive cost block" >&2
    return 1
  fi
}
