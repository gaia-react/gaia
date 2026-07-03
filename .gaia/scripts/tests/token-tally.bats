#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/token-tally.sh (SPEC-013 task-tally-helper).
#
# The anchor fixture under fixtures/token-tally/ is the non-circular oracle
# (UAT-006): its per-bucket sums and duration window are HAND-COMPUTED below,
# never derived by running the helper.
#
# Anchor fixture (session fixturesession0001), hand-computed:
#   messages (deduped by message.id): m1 (main, streamed 3x -> counted once),
#     m2 (main), m3 (agent-0001 sidecar), m4 (agent-0002 sidecar)
#     m1 usage: fresh=10  cwrite=100  cread=1000  out=1
#     m2 usage: fresh=20  cwrite=200  cread=2000  out=2
#     m3 usage: fresh=30  cwrite=300  cread=3000  out=3
#     m4 usage: fresh=40  cwrite=400  cread=4000  out=4
#   expected buckets: fresh=100  cwrite=1000  cread=10000  out=10   total=11110
#     (four non-zero, mutually distinct -> UAT-004; hardcoded-zero / collapsed /
#      wrong-field-mapping helpers all fail)
#   main-only sub-sum   (m1+m2) = 30 / 300 / 3000 / 3   -> 3333
#   sidecar-only sub-sum(m3+m4) = 70 / 700 / 7000 / 7   -> 7777   (total >= this)
#   naive UNDEDUPED total would count m1 3x -> 11110 + 2*1111 = 13332 (!= 11110)
#   the agent-0001.meta.json decoy carries usage 999999 in every field; it must
#     be ignored (the agent-*.jsonl glob excludes it).
#
# Duration (PL-001), hand-computed over the usage-bearing lines only:
#   started_at 2026-07-02T17:00:00.000Z (m1 first streaming line, GLOBAL MIN)
#   ended_at   2026-07-02T17:02:05.000Z (m4 in a SIDECAR,        GLOBAL MAX)
#   duration_seconds 125   duration_available true   human "2m5s"
#   decoys excluded: user line 16:59:30 (before min), pr-link 17:10:00 (after max)
#   regression traps: all-lines->630s, main-only->30s, deduped-min->124s
#   the ledger records the raw UTC endpoints; the human surfaces (stdout,
#     tokens.md) render them in the machine's LOCAL zone (proven below under a
#     pinned TZ=UTC baseline and a TZ=JST-9 non-UTC conversion)
#
# Degradation fixtures (isolated trees):
#   single/    -> one usage line, valid ts       -> duration 0, available true
#   zero/      -> one timestamped non-usage line -> available false, null, buckets 0, partial false
#   malformed/ -> one usage line, unparseable ts -> available false, buckets 11/22/33/44, partial false

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-tally.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  ANCHOR="$FIX/projects"
  SESSION="fixturesession0001"

  OUTDIR="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  # Git identity for the worktree sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# Run the helper against the anchor fixture with an ISOLATED ledger (never the
# machine's real .gaia/local/telemetry/tokens.jsonl).
run_anchor() {
  run bash "$SCRIPT" \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER" "$@"
}

led() { jq -r "$1" "$LEDGER"; }

# ---------- 1. UAT-006 exact sums + UAT-004 non-zero, distinct ----------
@test "anchor: exact per-bucket sums across main + sidecars (UAT-006/UAT-004)" {
  run_anchor
  [ "$status" -eq 0 ]

  # stdout carries the four buckets + total.
  [[ "$output" == *"Fresh input:  100"* ]]
  [[ "$output" == *"Cache write:  1000"* ]]
  [[ "$output" == *"Cache read:   10000"* ]]
  [[ "$output" == *"Output:       10"* ]]
  [[ "$output" == *"Total:        11110"* ]]

  # Ledger record carries the same five figures.
  [ "$(led '.buckets.fresh_input')" -eq 100 ]
  [ "$(led '.buckets.cache_write')" -eq 1000 ]
  [ "$(led '.buckets.cache_read')" -eq 10000 ]
  [ "$(led '.buckets.output')" -eq 10 ]
  [ "$(led '.total')" -eq 11110 ]

  # tokens.md carries the same five figures.
  grep -q "| Fresh input | 100 |" "$OUTDIR/tokens.md"
  grep -q "| Cache write | 1000 |" "$OUTDIR/tokens.md"
  grep -q "| Cache read | 10000 |" "$OUTDIR/tokens.md"
  grep -q "| Output | 10 |" "$OUTDIR/tokens.md"
  grep -q "| \*\*Total\*\* | 11110 |" "$OUTDIR/tokens.md"

  # UAT-004: every bucket non-zero and mutually distinct (kills hardcoded-zero,
  # single-collapsed-input, and wrong-field-mapping helpers).
  f="$(led '.buckets.fresh_input')"; w="$(led '.buckets.cache_write')"
  r="$(led '.buckets.cache_read')";  o="$(led '.buckets.output')"
  for v in "$f" "$w" "$r" "$o"; do [ "$v" -ne 0 ]; done
  [ "$f" -ne "$w" ]; [ "$f" -ne "$r" ]; [ "$f" -ne "$o" ]
  [ "$w" -ne "$r" ]; [ "$w" -ne "$o" ]; [ "$r" -ne "$o" ]
}

# ---------- 2. Dedup (documented) ----------
@test "anchor: dedups streamed message.id (output=10 deduped, not 12 naive)" {
  run_anchor
  [ "$status" -eq 0 ]
  # m1 is streamed 3x with identical usage; deduped output is 1+2+3+4 = 10.
  # A naive per-line sum would count m1 three times -> output 12, total 13332.
  [ "$(led '.buckets.output')" -eq 10 ]
  [ "$(led '.total')" -eq 11110 ]
  [ "$(led '.total')" -ne 13332 ]
}

# ---------- 3. Sidecar inclusion (UAT-003) ----------
@test "anchor: total includes sidecars (>= sidecar-only, > main-only)" {
  run_anchor
  [ "$status" -eq 0 ]
  total="$(led '.total')"
  # hand-computed sub-sums: main-only 3333, sidecar-only 7777
  [ "$total" -ge 7777 ]   # >= sidecar-only sum (UAT-003)
  [ "$total" -gt 3333 ]   # strictly > main-only sum -> sidecars contributed
  [ "$total" -eq 11110 ]  # = 3333 + 7777
}

# ---------- 4. agent-*.meta.json excluded ----------
@test "meta.json sibling is never read (adding one does not change the tally)" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  sub="$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$BATS_TEST_TMPDIR/l1.jsonl"
  [ "$status" -eq 0 ]
  before="$(jq -r '.total' "$BATS_TEST_TMPDIR/l1.jsonl")"

  # Add a second .meta.json full of usage; the glob must still ignore it.
  printf '%s\n' '{"type":"assistant","uuid":"x","message":{"id":"meta2","usage":{"input_tokens":999999,"cache_creation_input_tokens":999999,"cache_read_input_tokens":999999,"output_tokens":999999}}}' \
    > "$sub/agent-9999.meta.json"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$BATS_TEST_TMPDIR/l2.jsonl"
  [ "$status" -eq 0 ]
  after="$(jq -r '.total' "$BATS_TEST_TMPDIR/l2.jsonl")"

  [ "$before" -eq 11110 ]
  [ "$after" -eq "$before" ]
}

# ---------- 5. tokens.md content (UAT-001) ----------
@test "tokens.md exists in --out-dir with all five figures (not empty/placeholder)" {
  run_anchor
  [ "$status" -eq 0 ]
  [ -f "$OUTDIR/tokens.md" ]
  [ -s "$OUTDIR/tokens.md" ]
  # all five figures present
  grep -q "100" "$OUTDIR/tokens.md"
  grep -q "1000" "$OUTDIR/tokens.md"
  grep -q "10000" "$OUTDIR/tokens.md"
  grep -q " 10 " "$OUTDIR/tokens.md"
  grep -q "11110" "$OUTDIR/tokens.md"
}

# ---------- 5b. Planning + Execution sections coexist in one tokens.md ----------
# /gaia-plan and the KICKOFF git-op hook both write the plan folder's tokens.md.
# The plan-authoring and plan-execution costs must live in independent sections
# of the SAME file: never overwriting each other, never summed. Planning uses the
# single-line fixture (total 562); Execution uses the anchor (total 11110), so a
# clobbered-vs-preserved or a summed regression is unambiguous.
@test "plan then execute: tokens.md keeps independent Planning + Execution sections (no overwrite, no sum)" {
  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$FIX/single/projects" --ledger "$BATS_TEST_TMPDIR/l-plan.jsonl"
  [ "$status" -eq 0 ]
  grep -q "^## Planning$" "$OUTDIR/tokens.md"
  grep -q "| \*\*Total\*\* | 562 |" "$OUTDIR/tokens.md"

  # Execution tally into the SAME out-dir must add a section, not replace the file.
  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/l-exec.jsonl"
  [ "$status" -eq 0 ]

  # Both sections present, Planning before Execution.
  grep -q "^## Planning$" "$OUTDIR/tokens.md"
  grep -q "^## Execution$" "$OUTDIR/tokens.md"
  pln="$(grep -n '^## Planning$' "$OUTDIR/tokens.md" | cut -d: -f1)"
  exn="$(grep -n '^## Execution$' "$OUTDIR/tokens.md" | cut -d: -f1)"
  [ "$pln" -lt "$exn" ]

  # Planning total intact at 562 (NOT overwritten); Execution total is 11110.
  plan_slice="$(awk '/^## Planning$/{p=1;next} /^## Execution$/{p=0} p' "$OUTDIR/tokens.md")"
  exec_slice="$(awk '/^## Execution$/{e=1;next} e' "$OUTDIR/tokens.md")"
  [[ "$plan_slice" == *"| **Total** | 562 |"* ]]
  [[ "$exec_slice" == *"| **Total** | 11110 |"* ]]

  # No summed figure anywhere (562 + 11110 = 11672 must never appear).
  ! grep -q "11672" "$OUTDIR/tokens.md"
}

# The git-op hook re-runs the execute tally on every orchestrator commit, so the
# Execution section is rewritten repeatedly; that must not duplicate headings or
# disturb the Planning section written once upstream.
@test "repeated execute writes preserve the Planning section and never duplicate headings" {
  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$FIX/single/projects" --ledger "$BATS_TEST_TMPDIR/lp.jsonl"
  [ "$status" -eq 0 ]

  for n in 1 2 3; do
    run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug my-plan \
      --out-dir "$OUTDIR" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/le.jsonl"
    [ "$status" -eq 0 ]
  done

  [ "$(grep -c '^## Planning$' "$OUTDIR/tokens.md")" -eq 1 ]
  [ "$(grep -c '^## Execution$' "$OUTDIR/tokens.md")" -eq 1 ]
  grep -q "| \*\*Total\*\* | 562 |" "$OUTDIR/tokens.md"
  grep -q "| \*\*Total\*\* | 11110 |" "$OUTDIR/tokens.md"
}

# ---------- 6. Ledger keyed + durable (UAT-005) ----------
@test "ledger record is valid JSON, keyed, and survives out-dir (plan folder) deletion" {
  run bash "$SCRIPT" \
    --action plan --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/durable.jsonl"
  [ "$status" -eq 0 ]

  # exactly one valid JSON line with the right key fields
  [ "$(wc -l < "$BATS_TEST_TMPDIR/durable.jsonl")" -eq 1 ]
  run jq -e . "$BATS_TEST_TMPDIR/durable.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.action' "$BATS_TEST_TMPDIR/durable.jsonl")" = "plan" ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/durable.jsonl")" = "SPEC-013" ]
  [ "$(jq -r '.plan_slug' "$BATS_TEST_TMPDIR/durable.jsonl")" = "spec-013-token-accounting" ]
  [ "$(jq -r '.total' "$BATS_TEST_TMPDIR/durable.jsonl")" -eq 11110 ]

  # deleting the plan folder (out-dir) leaves the ledger record intact (UAT-005)
  rm -rf "$OUTDIR"
  [ -f "$BATS_TEST_TMPDIR/durable.jsonl" ]
  [ "$(jq -r '.total' "$BATS_TEST_TMPDIR/durable.jsonl")" -eq 11110 ]
}

# ---------- 7. Ledger -> main checkout under a worktree (UAT-008) ----------
# Uses the REAL default ledger resolution (no --ledger), entirely inside a
# throwaway tmp git repo, so the "real" ledger is the tmp repo's, not the machine's.
@test "worktree run writes the ledger to the main checkout, not the worktree" {
  MAIN="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/main"
  WT="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  git -C "$MAIN" worktree add -q "$WT" -b "feature/kickoff"

  run bash -c "cd '$WT' && bash '$SCRIPT' \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir '$WT/out' --session-id '$SESSION' --projects-root '$ANCHOR'"
  [ "$status" -eq 0 ]

  # Ledger landed in the MAIN checkout ...
  [ -f "$MAIN/.gaia/local/telemetry/tokens.jsonl" ]
  [ "$(jq -r '.total' "$MAIN/.gaia/local/telemetry/tokens.jsonl")" -eq 11110 ]
  # ... and NOT under the worktree.
  [ ! -f "$WT/.gaia/local/telemetry/tokens.jsonl" ]

  # Ledger survives worktree removal (UAT-008 durability).
  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  [ -f "$MAIN/.gaia/local/telemetry/tokens.jsonl" ]
}

# ---------- 8. Graceful degradation (UAT-007) ----------
@test "non-existent session: exit 0, partial, buckets 0, marker in all three surfaces" {
  run bash "$SCRIPT" \
    --action spec --spec-id SPEC-013 \
    --out-dir "$OUTDIR" --session-id "no-such-session-9999" \
    --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # stdout marker + zero buckets
  [[ "$output" == *"(partial: figures are a lower bound"* ]]
  [[ "$output" == *"Total:        0"* ]]

  # ledger partial:true, buckets 0
  [ "$(led '.partial')" = "true" ]
  [ "$(led '.total')" -eq 0 ]

  # tokens.md marker present
  grep -q "_Partial:" "$OUTDIR/tokens.md"
}

@test "malformed sidecar line: exit 0, partial, still tallies the readable files" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  sub="$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents"
  # A NEW sidecar whose line is not valid JSON: it must flip partial and
  # contribute nothing, while the good main + sidecars still sum to 11110.
  printf '%s\n' 'this is not json {{{' > "$sub/agent-0009.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(led '.partial')" = "true" ]
  [ "$(led '.total')" -eq 11110 ]   # readable files still tallied, nothing fabricated
}

@test "empty session id (no --session-id, unset env): exit 0, partial, no crash" {
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" \
    --action spec --spec-id SPEC-013 \
    --out-dir "$OUTDIR" --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(led '.partial')" = "true" ]
  [ "$(led '.total')" -eq 0 ]
}

# ---------- 10. Elapsed exact span (PL-001) ----------
# The ledger records the raw UTC endpoints (timezone-independent); the human
# surfaces render them in the machine's LOCAL zone. Pinned to TZ=UTC here so the
# local display is deterministic (UTC clock, labelled UTC); the conversion to a
# non-UTC zone is proven in the next test.
@test "anchor: elapsed span 125s/2m5s, ledger raw UTC, human surfaces local (TZ=UTC)" {
  run env TZ=UTC bash "$SCRIPT" \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # ledger: raw UTC endpoints (durable machine record)
  [ "$(led '.duration_seconds')" -eq 125 ]
  [ "$(led '.duration_available')" = "true" ]
  [ "$(led '.started_at')" = "2026-07-02T17:00:00.000Z" ]
  [ "$(led '.ended_at')" = "2026-07-02T17:02:05.000Z" ]

  # stdout pinned human format + LOCAL window (kills 0, ms=125000, all-lines=630s,
  # main-only=30s, deduped-min=124s). TZ=UTC -> local clock == UTC, labelled UTC.
  [[ "$output" == *"Elapsed:      2m5s  (first to last model turn: 2026-07-02 17:00:00 UTC to 2026-07-02 17:02:05 UTC)"* ]]

  # tokens.md elapsed line (below the total row, not a table row)
  grep -q "^\*\*Elapsed (first to last model turn):\*\* 2m5s (2026-07-02 17:00:00 UTC to 2026-07-02 17:02:05 UTC)$" "$OUTDIR/tokens.md"
}

# ---------- 10b. Endpoints render in the machine's LOCAL zone (owner request) ----------
# Under a fixed non-UTC, non-DST zone (JST = UTC+9, POSIX "JST-9" so no tzdata is
# required), the human surfaces show the endpoints converted to local time,
# crossing midnight (17:00Z -> next-day 02:00 JST), while the ledger still stores
# the raw UTC. Proves the display applies the system zone rather than hardcoding
# UTC, and that the span (125s) is timezone-independent.
@test "human surfaces render endpoints in the local zone; ledger stays UTC (TZ=JST-9)" {
  run env TZ=JST-9 bash "$SCRIPT" \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # ledger unchanged: raw UTC, span unchanged
  [ "$(led '.started_at')" = "2026-07-02T17:00:00.000Z" ]
  [ "$(led '.ended_at')" = "2026-07-02T17:02:05.000Z" ]
  [ "$(led '.duration_seconds')" -eq 125 ]

  # human surfaces: +0900 local, crossing midnight into 2026-07-03
  [[ "$output" == *"first to last model turn: 2026-07-03 02:00:00 JST to 2026-07-03 02:02:05 JST"* ]]
  [[ "$output" == *"Elapsed:      2m5s"* ]]
  grep -q "^\*\*Elapsed (first to last model turn):\*\* 2m5s (2026-07-03 02:00:00 JST to 2026-07-03 02:02:05 JST)$" "$OUTDIR/tokens.md"
}

# ---------- 11. Max in a sidecar (documents sidecar inclusion) ----------
@test "removing the sidecar holding the global max shortens the reported span" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  rm -f "$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents/agent-0002.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  # global max was 17:02:05 (agent-0002); removing it leaves m3 (agent-0001) at
  # 17:01:00 as the new max -> span 60s < 125s.
  [ "$(led '.duration_seconds')" -eq 60 ]
  [ "$(led '.ended_at')" = "2026-07-02T17:01:00.000Z" ]
}

# ---------- 12. Single / zero ----------
@test "single usage line: duration 0, available true" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-000 \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$FIX/single/projects" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(led '.duration_seconds')" -eq 0 ]
  [ "$(led '.duration_available')" = "true" ]
  [ "$(led '.total')" -eq 562 ]
}

@test "zero usage lines (timestamped non-usage only): unavailable/null, buckets 0, partial false" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-000 \
    --out-dir "$OUTDIR" --session-id "fixturezero0001" \
    --projects-root "$FIX/zero/projects" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(led '.duration_available')" = "false" ]
  [ "$(led '.duration_seconds')" = "null" ]
  [ "$(led '.total')" -eq 0 ]
  [ "$(led '.partial')" = "false" ]
  [[ "$output" == *"Elapsed:      unavailable (no readable turn timestamps)"* ]]
}

# ---------- 13. Malformed timestamp + flag independence ----------
@test "malformed extremal timestamp: unavailable, buckets intact, partial false (flag independence)" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-000 \
    --out-dir "$OUTDIR" --session-id "fixturemalformed0001" \
    --projects-root "$FIX/malformed/projects" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # duration unavailable ...
  [ "$(led '.duration_available')" = "false" ]
  [ "$(led '.duration_seconds')" = "null" ]
  [ "$(led '.started_at')" = "null" ]
  [ "$(led '.ended_at')" = "null" ]

  # ... while the four buckets equal their hand-computed sums and partial is FALSE.
  # Only this case falsifies a helper that conflates partial with duration_available.
  [ "$(led '.partial')" = "false" ]
  [ "$(led '.buckets.fresh_input')" -eq 11 ]
  [ "$(led '.buckets.cache_write')" -eq 22 ]
  [ "$(led '.buckets.cache_read')" -eq 33 ]
  [ "$(led '.buckets.output')" -eq 44 ]
}
