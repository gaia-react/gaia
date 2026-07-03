#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (this suite uses `run --separate-stderr`, added in 1.5).
bats_require_minimum_version 1.5.0
#
# Bats suite for .gaia/scripts/token-rollup.sh (SPEC-017 task-rollup-reader).
#
# Every fixture ledger under fixtures/token-rollup/ is a HAND-AUTHORED oracle:
# expected sums/spans are computed by hand in the comments below, never by
# running the reader first and copying its output.
#
# Fixture inventory + hand-computed oracles:
#
#   dedup-lower.jsonl (SPEC-201, one session "sess1", 3 execute rows)
#     r1 total=1000000 partial:false
#     r2 total=1400000 NO partial key at all (missing -> non-partial/final)
#     r3 total=900000  partial:true, LATER ended_at, LOWER total
#     non-partial pool = {r1, r2}; winner = max total = r2 (1400000, dur 700).
#     Proves: (a) a later partial row cannot LOWER the session's figure
#     (UAT-004), (b) a record with no `partial` key is treated as final and
#     CAN be the winner (directive 2).
#
#   dedup-inflate.jsonl (SPEC-202, one session "sess1", 2 execute rows)
#     r1 total=700000  partial:false, dur 400
#     r2 total=1200000 partial:true (HIGHEST total, latest ended_at)
#     non-partial pool = {r1}; winner = r1 (700000). Proves a partial row
#     cannot INFLATE the session's figure even when it has the max total
#     (the other half of UAT-004's success criterion).
#
#   dedup-tiebreak.jsonl (SPEC-203, one session "sess1", 2 execute rows)
#     r1 total=500000 ended_at 10:00 dur=100 (both non-partial)
#     r2 total=500000 ended_at 11:00 dur=200
#     equal totals -> tiebreak on latest ended_at -> r2 wins. Elapsed 200s
#     (3m20s) proves r2 won, not r1's 100s (1m40s).
#
#   dedup-all-partial.jsonl (SPEC-204, one session "sess1", 2 execute rows,
#   BOTH partial:true) -- extra coverage of the frozen algorithm's fallback
#   branch (no non-partial row at all -> pool = all rows, session flagged
#   partial). Winner = max total = 500000 (dur 250, 4m10s); partial marker
#   must appear.
#
#   cross-session.jsonl (SPEC-210, execute only, two sessions)
#     sess-s1 (halted): r1 total=1000000 dur=600, r2 total=1500000 dur=1200
#       (last pre-halt row, no `partial` key on either row) -> dedup = r2.
#     sess-s2 (resumed later): r3 total=2000000 dur=900,
#       r4 total=2600000 dur=1500 (final merge) -> dedup = r4.
#     execute total = 1500000 + 2600000 = 4100000 (UAT-003: sum across
#       sessions, not S2 alone; UAT-005: halted session's last row included,
#       no non-final/status field anywhere in the fixture).
#     elapsed = 1200 + 1500 = 2700s = 45m0s (UAT-008: sum of each session's
#       OWN active span). The WRONG naive calc, max(ended_at) - min(started_at)
#       = 2026-04-01T14:25:00 - 2026-04-01T09:50:00 = 4h35m = 16500s, is a
#       different number (2700 != 16500) -- a regression trap for that bug.
#     No spec/plan rows exist for SPEC-210 at all, so this fixture doubles as
#       the "missing action never errors" case: only execute + Total render.
#
#   full-cycle.jsonl (SPEC-220: one spec, one plan, one execute row, plus one
#   UNRELATED SPEC-999 execute row to prove spec_id filtering)
#     spec    buckets 1000/2000/30000/4000 total=37000  dur=600  (10m0s)
#     plan    buckets 1100/2100/31000/4100 total=38300  dur=700  (11m40s)
#     execute buckets 1200/2200/32000/4200 total=39600  dur=800  (13m20s)
#     grand total = 37000+38300+39600 = 114900; grand elapsed =
#       600+700+800 = 2100s = 35m0s; grand buckets = 3300/6300/93000/12300
#       (each sums to 114900, cross-checking the per-record bucket sums too).
#     The noise row's total (39999996) must NOT appear anywhere in the output.
#
#   spec-less.jsonl (feature key = a plan slug, not a SPEC-NNN id; plan +
#   execute only, no spec row)
#     plan total=370 dur=60 (1m0s); execute total=407 dur=90 (1m30s)
#     grand total=777; elapsed=150s=2m30s; buckets 21/42/630/84 (sum 777).
#     UAT-007: no spec line renders, exit 0, no error.
#
#   corrupt.jsonl (SPEC-230: one spec row, one PLAIN-TEXT bad line, one plan
#   row; no execute row)
#     spec total=5000 dur=60 (1m0s); plan total=6000 dur=90 (1m30s)
#     grand total = 11000; elapsed = 150s = 2m30s. UAT-010: the bad line is
#     skipped, not fatal; the good rows still roll up exactly; a corrupt
#     marker is appended; exit 0.
#
#   unavailable-elapsed.jsonl (SPEC-250: one execute row, duration_available
#   false / duration_seconds null, but a REAL total)
#     total=8000, buckets 1000/2000/4000/1000 (sums to 8000). Both the
#     execute line and the Total line must render "unavailable" for elapsed,
#     never a fabricated "0s"; the buckets still show the real numbers; the
#     partial marker is appended (elapsed unavailable is a lower-bound signal).

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-rollup.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-rollup" && pwd)"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# ---------- 1. UAT-004 (lower) + directive 2 (missing `partial` is final) ----------
@test "dedup-lower: later partial row with a lower total cannot lower the winner; missing partial key can win" {
  run bash "$SCRIPT" --spec-id SPEC-201 --ledger "$FIX/dedup-lower.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute:   1,400,000   (elapsed 11m40s)"* ]]
  [[ "$output" == *"Total:     1,400,000   (elapsed 11m40s)"* ]]
  [[ "$output" != *"900,000"* ]]
}

# ---------- 2. UAT-004 (inflate direction) ----------
@test "dedup-inflate: a partial row with the HIGHEST total cannot inflate the winner" {
  run bash "$SCRIPT" --spec-id SPEC-202 --ledger "$FIX/dedup-inflate.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute:   700,000   (elapsed 6m40s)"* ]]
  [[ "$output" == *"Total:     700,000   (elapsed 6m40s)"* ]]
  [[ "$output" != *"1,200,000"* ]]
}

# ---------- 3. Tiebreak: equal totals, latest ended_at wins ----------
@test "dedup-tiebreak: equal-total non-partial rows break on latest ended_at" {
  run bash "$SCRIPT" --spec-id SPEC-203 --ledger "$FIX/dedup-tiebreak.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute:   500,000   (elapsed 3m20s)"* ]]
  [[ "$output" != *"1m40s"* ]]
}

# ---------- 4. All-partial session (fallback pool branch) ----------
@test "dedup-all-partial: a session with only partial rows falls back to max-total and flags partial" {
  run bash "$SCRIPT" --spec-id SPEC-204 --ledger "$FIX/dedup-all-partial.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute:   500,000   (elapsed 4m10s)"* ]]
  [[ "$output" == *"(partial: some ledger input was unreadable or lacked timing"* ]]
}

# ---------- 5. UAT-003 cross-session sum + UAT-005 halted-session inclusion ----------
@test "cross-session: execute total sums deduped contributions from two sessions, including the halted one" {
  run bash "$SCRIPT" --spec-id SPEC-210 --ledger "$FIX/cross-session.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute:   4,100,000   (elapsed 45m0s)"* ]]
  [[ "$output" == *"Total:     4,100,000   (elapsed 45m0s)"* ]]
  # regression trap: must NOT be the naive idle-gap-inclusive span (UAT-008)
  [[ "$output" != *"16500"* ]]
  [[ "$output" != *"4h35m"* ]]
}

# ---------- 6. Missing action never errors (reuses cross-session: execute-only feature) ----------
@test "cross-session: no spec/plan rows for the feature -> only execute + Total render, no crash" {
  run bash "$SCRIPT" --spec-id SPEC-210 --ledger "$FIX/cross-session.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\n  spec:'* ]]
  [[ "$output" != *$'\n  plan:'* ]]
}

# ---------- 7. UAT-006 full render: spec + plan + execute + Total + buckets ----------
@test "full-cycle: renders spec/plan/execute/Total with correct grand buckets, unrelated feature excluded" {
  run bash "$SCRIPT" --spec-id SPEC-220 --ledger "$FIX/full-cycle.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spec:       37,000   (elapsed 10m0s)"* ]]
  [[ "$output" == *"plan:       38,300   (elapsed 11m40s)"* ]]
  [[ "$output" == *"execute:    39,600   (elapsed 13m20s)"* ]]
  [[ "$output" == *"Total:     114,900   (elapsed 35m0s)"* ]]
  [[ "$output" == *"Fresh input:   3,300"* ]]
  [[ "$output" == *"Cache write:   6,300"* ]]
  [[ "$output" == *"Cache read:   93,000"* ]]
  [[ "$output" == *"Output:       12,300"* ]]
  # the unrelated SPEC-999 noise row must never leak into this feature's roll-up
  [[ "$output" != *"39,999,996"* ]]
}

# ---------- 8. UAT-007 spec-less plan omits the spec line ----------
@test "spec-less: plan-slug feature key with no spec row omits the spec line" {
  run bash "$SCRIPT" --spec-id spec-less-slug-example --ledger "$FIX/spec-less.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\n  spec:'* ]]
  [[ "$output" == *"plan:      370   (elapsed 1m0s)"* ]]
  [[ "$output" == *"execute:   407   (elapsed 1m30s)"* ]]
  [[ "$output" == *"Total:     777   (elapsed 2m30s)"* ]]
}

# ---------- 9. UAT-010 corrupt line tolerated ----------
@test "corrupt: one unparseable line among good rows is skipped, not fatal; good rows still sum" {
  run bash "$SCRIPT" --spec-id SPEC-230 --ledger "$FIX/corrupt.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spec:       5,000   (elapsed 1m0s)"* ]]
  [[ "$output" == *"plan:       6,000   (elapsed 1m30s)"* ]]
  [[ "$output" == *"Total:     11,000   (elapsed 2m30s)"* ]]
  [[ "$output" == *"(partial: some ledger input was unreadable or lacked timing"* ]]
}

# ---------- 10. Unknown feature key ----------
@test "unknown feature key: no records line, exit 0, no crash" {
  run bash "$SCRIPT" --spec-id NOPE-999 --ledger "$FIX/full-cycle.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "Cycle cost (NOPE-999): no ledger records found." ]
}

# ---------- 11. Missing ledger file ----------
@test "missing ledger file: no records line, exit 0, no crash" {
  run bash "$SCRIPT" --spec-id SPEC-999 --ledger "$FIX/does-not-exist.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "Cycle cost (SPEC-999): no ledger records found." ]
}

# ---------- 12. Missing --spec-id degrades gracefully ----------
@test "missing --spec-id: exit 0, degrades to an empty readout, no crash" {
  run --separate-stderr bash "$SCRIPT" --ledger "$FIX/full-cycle.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "Cycle cost (): no ledger records found." ]
}

# ---------- 13. UAT-009 default ledger resolves to the main checkout under a worktree ----------
@test "no --ledger: resolves the main checkout's ledger from inside a linked worktree" {
  MAIN="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/main"
  WT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  git -C "$MAIN" worktree add -q "$WT" -b "feature/kickoff"

  mkdir -p "$MAIN/.gaia/local/telemetry"
  cp "$FIX/dedup-lower.jsonl" "$MAIN/.gaia/local/telemetry/tokens.jsonl"

  run bash -c "cd '$WT' && bash '$SCRIPT' --spec-id SPEC-201"
  [ "$status" -eq 0 ]
  # if the reader mis-resolved to the worktree (which has no ledger at all),
  # this would read "no ledger records found" instead of the real total.
  [[ "$output" == *"execute:   1,400,000   (elapsed 11m40s)"* ]]

  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
}

# ---------- 14. Always exit 0 / diagnostics on stderr, not stdout ----------
@test "diagnostics go to stderr, not stdout, even when input is corrupt or --spec-id is missing" {
  run --separate-stderr bash "$SCRIPT" --ledger "$FIX/full-cycle.jsonl"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"token-rollup: missing --spec-id"* ]]
  [[ "$output" != *"token-rollup:"* ]]

  run --separate-stderr bash "$SCRIPT" --spec-id SPEC-230 --ledger "$FIX/corrupt.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" != *"token-rollup:"* ]]
}

# ---------- 15. Never-fabricate: unavailable elapsed renders "unavailable", never "0s" ----------
@test "unavailable-elapsed: real totals render but elapsed shows 'unavailable', never a fabricated 0s" {
  run bash "$SCRIPT" --spec-id SPEC-250 --ledger "$FIX/unavailable-elapsed.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"execute:   8,000   (elapsed unavailable)"* ]]
  [[ "$output" == *"Total:     8,000   (elapsed unavailable)"* ]]
  [[ "$output" != *"elapsed 0s"* ]]
  [[ "$output" == *"Fresh input:  1,000"* ]]
  [[ "$output" == *"Cache write:  2,000"* ]]
  [[ "$output" == *"Cache read:   4,000"* ]]
  [[ "$output" == *"Output:       1,000"* ]]
  [[ "$output" == *"(partial: some ledger input was unreadable or lacked timing"* ]]
}
