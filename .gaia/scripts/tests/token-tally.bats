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
#     cost.md) render them in the machine's LOCAL zone (proven below under a
#     pinned TZ=UTC baseline and a TZ=JST-9 non-UTC conversion)
#
# Degradation fixtures (isolated trees):
#   single/    -> one usage line, valid ts       -> duration 0, available true
#   zero/      -> one timestamped non-usage line -> available false, null, buckets 0, partial false
#   malformed/ -> one usage line, unparseable ts -> available false, buckets 11/22/33/44, partial false
#
# Multi-model attribution (FC-1, SPEC-019 by_model): HAND-COMPUTED oracle,
# never derived by running the helper.
#   multimodel/ (session fixturemultimodel0001):
#     a1 claude-opus-4-8   fresh=100 cwrite=100(5m=40 /1h=60)  cread=1000 out=10
#     a2 claude-opus-4-8   fresh=200 cwrite=300(5m=0  /1h=300) cread=2000 out=20
#     a3 claude-sonnet-4-6 fresh=30  cwrite=30 (5m=10 /1h=20)  cread=3000 out=3
#     s1 <synthetic>       all zero -> excluded from by_model
#     a1 is streamed across 2 lines with an identical message.id (decoy proving
#     dedup runs BEFORE grouping-by-model).
#     by_model["claude-opus-4-8"]   = {fresh_input:300, cache_write_5m:40, cache_write_1h:360, cache_read:3000, output:30}
#     by_model["claude-sonnet-4-6"] = {fresh_input:30,  cache_write_5m:10, cache_write_1h:20,  cache_read:3000, output:3}
#     aggregate buckets = {fresh_input:330, cache_write:430, cache_read:6000, output:33}  total:6793
#   multimodel/splitless/ (session fixturemultimodelsplitless0001): one usage
#     line lacking the nested cache_creation object but a non-zero
#     cache_creation_input_tokens (500), proving the 1h fallback:
#     by_model["claude-sonnet-4-6"] = {cache_write_5m:0, cache_write_1h:500, ...},
#     reconciling to aggregate cache_write:500.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/token-tally.sh"
  FIX="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  ANCHOR="$FIX/projects"
  SESSION="fixturesession0001"
  MULTIMODEL="$FIX/multimodel/projects"
  MULTIMODEL_SPLITLESS="$FIX/multimodel/splitless/projects"
  BYAGENT="$FIX/byagent/projects"

  OUTDIR="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  # Git identity for the worktree sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# Run the helper against the anchor fixture with an ISOLATED ledger (never the
# machine's real .gaia/local/telemetry/cost.jsonl).
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

  # cost.md carries the same five figures.
  grep -q "| Fresh input | 100 |" "$OUTDIR/cost.md"
  grep -q "| Cache write | 1000 |" "$OUTDIR/cost.md"
  grep -q "| Cache read | 10000 |" "$OUTDIR/cost.md"
  grep -q "| Output | 10 |" "$OUTDIR/cost.md"
  grep -q "| \*\*Total\*\* | 11110 |" "$OUTDIR/cost.md"

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

# ---------- 5. cost.md content (UAT-001) ----------
@test "cost.md exists in --out-dir with all five figures (not empty/placeholder)" {
  run_anchor
  [ "$status" -eq 0 ]
  [ -f "$OUTDIR/cost.md" ]
  [ -s "$OUTDIR/cost.md" ]
  # all five figures present
  grep -q "100" "$OUTDIR/cost.md"
  grep -q "1000" "$OUTDIR/cost.md"
  grep -q "10000" "$OUTDIR/cost.md"
  grep -q " 10 " "$OUTDIR/cost.md"
  grep -q "11110" "$OUTDIR/cost.md"
}

# ---------- 5b. Planning + Execution sections coexist in one cost.md ----------
# /gaia-plan and the KICKOFF git-op hook both write the plan folder's cost.md.
# The plan-authoring and plan-execution costs must live in independent sections
# of the SAME file: never overwriting each other, never summed. Planning uses the
# single-line fixture (total 562); Execution uses the anchor (total 11110), so a
# clobbered-vs-preserved or a summed regression is unambiguous.
@test "plan then execute: cost.md keeps independent Planning + Execution sections (no overwrite, no sum)" {
  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "fixturesingle0001" \
    --projects-root "$FIX/single/projects" --ledger "$BATS_TEST_TMPDIR/l-plan.jsonl"
  [ "$status" -eq 0 ]
  grep -q "^## Planning$" "$OUTDIR/cost.md"
  grep -q "| \*\*Total\*\* | 562 |" "$OUTDIR/cost.md"

  # Execution tally into the SAME out-dir must add a section, not replace the file.
  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/l-exec.jsonl"
  [ "$status" -eq 0 ]

  # Both sections present, Planning before Execution.
  grep -q "^## Planning$" "$OUTDIR/cost.md"
  grep -q "^## Execution$" "$OUTDIR/cost.md"
  pln="$(grep -n '^## Planning$' "$OUTDIR/cost.md" | cut -d: -f1)"
  exn="$(grep -n '^## Execution$' "$OUTDIR/cost.md" | cut -d: -f1)"
  [ "$pln" -lt "$exn" ]

  # Planning total intact at 562 (NOT overwritten); Execution total is 11110.
  plan_slice="$(awk '/^## Planning$/{p=1;next} /^## Execution$/{p=0} p' "$OUTDIR/cost.md")"
  exec_slice="$(awk '/^## Execution$/{e=1;next} e' "$OUTDIR/cost.md")"
  [[ "$plan_slice" == *"| **Total** | 562 |"* ]]
  [[ "$exec_slice" == *"| **Total** | 11110 |"* ]]

  # No summed figure anywhere (562 + 11110 = 11672 must never appear).
  ! grep -q "11672" "$OUTDIR/cost.md"
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

  [ "$(grep -c '^## Planning$' "$OUTDIR/cost.md")" -eq 1 ]
  [ "$(grep -c '^## Execution$' "$OUTDIR/cost.md")" -eq 1 ]
  grep -q "| \*\*Total\*\* | 562 |" "$OUTDIR/cost.md"
  grep -q "| \*\*Total\*\* | 11110 |" "$OUTDIR/cost.md"
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
  [ "$(jq -r '.kind' "$BATS_TEST_TMPDIR/durable.jsonl")" = "plan" ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/durable.jsonl")" = "SPEC-013" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/durable.jsonl")" = "null" ]
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
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
  [ "$(jq -r '.total' "$MAIN/.gaia/local/telemetry/cost.jsonl")" -eq 11110 ]
  # ... and NOT under the worktree.
  [ ! -f "$WT/.gaia/local/telemetry/cost.jsonl" ]

  # Ledger survives worktree removal (UAT-008 durability).
  git -C "$MAIN" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
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

  # cost.md marker present
  grep -q "_Partial:" "$OUTDIR/cost.md"
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

  # cost.md elapsed line (below the total row, not a table row)
  grep -q "^\*\*Elapsed (first to last model turn):\*\* 2m5s (2026-07-02 17:00:00 UTC to 2026-07-02 17:02:05 UTC)$" "$OUTDIR/cost.md"
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
  grep -q "^\*\*Elapsed (first to last model turn):\*\* 2m5s (2026-07-03 02:00:00 JST to 2026-07-03 02:02:05 JST)$" "$OUTDIR/cost.md"
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

# ---------- 14. Multi-model attribution (FC-1, SPEC-019) ----------
@test "multimodel: by_model attributes each model, sentinel excluded" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTDIR" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(led '.by_model | keys | join(",")')" = "claude-opus-4-8,claude-sonnet-4-6" ]
  [ "$(led '.by_model["<synthetic>"]')" = "null" ]

  [ "$(led '.by_model["claude-opus-4-8"].fresh_input')" -eq 300 ]
  [ "$(led '.by_model["claude-opus-4-8"].cache_write_5m')" -eq 40 ]
  [ "$(led '.by_model["claude-opus-4-8"].cache_write_1h')" -eq 360 ]
  [ "$(led '.by_model["claude-opus-4-8"].cache_read')" -eq 3000 ]
  [ "$(led '.by_model["claude-opus-4-8"].output')" -eq 30 ]

  [ "$(led '.by_model["claude-sonnet-4-6"].fresh_input')" -eq 30 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].cache_write_5m')" -eq 10 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].cache_write_1h')" -eq 20 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].cache_read')" -eq 3000 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].output')" -eq 3 ]
}

@test "multimodel: per-model buckets reconcile to the aggregate" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTDIR" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # Reconciliation invariant (FC-1): Σ per-model == aggregate buckets.
  [ "$(led '([.by_model[].fresh_input] | add) == .buckets.fresh_input')" = "true" ]
  [ "$(led '([.by_model[] | (.cache_write_5m + .cache_write_1h)] | add) == .buckets.cache_write')" = "true" ]
  [ "$(led '([.by_model[].cache_read] | add) == .buckets.cache_read')" = "true" ]
  [ "$(led '([.by_model[].output] | add) == .buckets.output')" = "true" ]
}

@test "multimodel: cache-write TTL split captured per model" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTDIR" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(led '.by_model["claude-opus-4-8"].cache_write_5m')" -eq 40 ]
  [ "$(led '.by_model["claude-opus-4-8"].cache_write_1h')" -eq 360 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].cache_write_5m')" -eq 10 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].cache_write_1h')" -eq 20 ]

  # 5m + 1h summed across models equals the aggregate cache_write bucket.
  [ "$(led '(([.by_model[].cache_write_5m] | add) + ([.by_model[].cache_write_1h] | add)) == .buckets.cache_write')" = "true" ]
}

@test "split-less usage falls back to 1h and still reconciles" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTDIR" --session-id "fixturemultimodelsplitless0001" \
    --projects-root "$MULTIMODEL_SPLITLESS" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(led '.by_model["claude-sonnet-4-6"].cache_write_5m')" -eq 0 ]
  [ "$(led '.by_model["claude-sonnet-4-6"].cache_write_1h')" -eq 500 ]
  [ "$(led '.buckets.cache_write')" -eq 500 ]
}

@test "legacy-shaped (model-less) session omits by_model" {
  run_anchor
  [ "$status" -eq 0 ]
  [ "$(led '.by_model')" = "null" ]
  [ "$(led '.total')" -eq 11110 ]
}

# ---------- 15. Shared ledger-path lib (FC-1) ----------
@test "ledger-path-lib: resolves cost.jsonl, honors override, fails without git; token-tally sources it" {
  LIB="$SCRIPT_DIR/ledger-path-lib.sh"
  [ -f "$LIB" ]

  # override is echoed verbatim
  got="$(bash -c '. "$1"; gaia_resolve_ledger_path "/x/y/cost.jsonl"' _ "$LIB")"
  [ "$got" = "/x/y/cost.jsonl" ]

  # inside a real git repo -> a main-checkout cost.jsonl path
  repo="$BATS_TEST_TMPDIR/librepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  got2="$(bash -c 'cd "$1" && . "$2"; gaia_resolve_ledger_path ""' _ "$repo" "$LIB")"
  case "$got2" in
    */.gaia/local/telemetry/cost.jsonl) : ;;
    *) echo "unexpected ledger path: $got2" >&2; return 1 ;;
  esac

  # outside any git repo -> non-zero, no output
  nongit="$BATS_TEST_TMPDIR/nongit"
  mkdir -p "$nongit"
  run bash -c 'cd "$1" && . "$2"; gaia_resolve_ledger_path ""' _ "$nongit" "$LIB"
  [ "$status" -ne 0 ]

  # token-tally.sh sources the lib rather than inlining the derivation
  grep -qF 'ledger-path-lib.sh' "$SCRIPT"
  if grep -qF 'telemetry/cost.jsonl' "$SCRIPT"; then
    echo "token-tally.sh still inlines the ledger derivation" >&2
    return 1
  fi
}

# ---------- 16. spec doc: schema_version, ## SPEC section, no legacy md (AC2) ----------
@test "spec: schema_version 1, kind spec, seq 0/final, cost.md ## SPEC section, only cost.md written" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$OUTDIR" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(led '.schema_version')" -eq 1 ]
  [ "$(led '.kind')" = "spec" ]
  [ "$(led '.spec_id')" = "SPEC-013" ]
  [ "$(led '.plan_id')" = "null" ]
  [ "$(led '.seq')" -eq 0 ]
  [ "$(led '.final')" = "true" ]

  grep -qF '# Cost: SPEC-013' "$OUTDIR/cost.md"
  grep -qF '## SPEC' "$OUTDIR/cost.md"
  grep -qF '| **Total** | 11110 |' "$OUTDIR/cost.md"

  # cost.md is the ONLY markdown written (no legacy-named sibling remains)
  [ -f "$OUTDIR/cost.md" ]
  [ "$(ls "$OUTDIR"/*.md | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------- 17. spec_id XOR plan_id -- the single source-of-truth gate (AC3) ----------
# Both the plan.md step-4.8 caller edit (DOCS) and the execute-hook routing
# (WRITE-HOOKS) rely on this CLI behavior, so it is asserted explicitly across
# BOTH the plan and execute kinds: a SPEC-* key -> spec_id, a PLAN-* key ->
# plan_id, never both.
@test "spec_id XOR plan_id across plan and execute kinds; no record carries both" {
  # spec-derived plan: --spec-id SPEC-* -> spec_id set, plan_id null
  run bash "$SCRIPT" --action plan --spec-id SPEC-023 --plan-slug p \
    --out-dir "$OUTDIR/sd-plan" --session-id fixturesingle0001 \
    --projects-root "$FIX/single/projects" --ledger "$BATS_TEST_TMPDIR/sd-plan.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' "$BATS_TEST_TMPDIR/sd-plan.jsonl")" = "plan" ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sd-plan.jsonl")" = "SPEC-023" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sd-plan.jsonl")" = "null" ]

  # spec-less plan: --plan-id PLAN-* -> plan_id set, spec_id null
  run bash "$SCRIPT" --action plan --plan-id PLAN-007 --plan-slug p \
    --out-dir "$OUTDIR/sl-plan" --session-id fixturesingle0001 \
    --projects-root "$FIX/single/projects" --ledger "$BATS_TEST_TMPDIR/sl-plan.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' "$BATS_TEST_TMPDIR/sl-plan.jsonl")" = "plan" ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sl-plan.jsonl")" = "null" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sl-plan.jsonl")" = "PLAN-007" ]

  # spec-derived execute
  run bash "$SCRIPT" --action execute --spec-id SPEC-023 --plan-slug p \
    --out-dir "$OUTDIR/sd-exec" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/sd-exec.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sd-exec.jsonl")" = "SPEC-023" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sd-exec.jsonl")" = "null" ]

  # spec-less execute
  run bash "$SCRIPT" --action execute --plan-id PLAN-007 --plan-slug p \
    --out-dir "$OUTDIR/sl-exec" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/sl-exec.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sl-exec.jsonl")" = "null" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sl-exec.jsonl")" = "PLAN-007" ]

  # invariant: never both ids set on any of the four records
  for f in sd-plan sl-plan sd-exec sl-exec; do
    both="$(jq -r 'select(.spec_id != null and .plan_id != null) | "BOTH"' "$BATS_TEST_TMPDIR/$f.jsonl")"
    [ -z "$both" ]
  done
}

# ---------- 18. by_agent_type sidecar attribution + reconcile-by-equality (AC5) ----------
# The byagent fixture (session fixturebyagent0001) is a HAND-COMPUTED oracle:
#   main transcript mMain   fresh=10 cwrite=100 cread=1000 out=1
#   sidecar researcher mA   fresh=20 cwrite=200 cread=2000 out=2  (agent-0001.meta.json agentType=researcher)
#   sidecar planner    mB   fresh=40 cwrite=400 cread=4000 out=4  (agent-0002.meta.json agentType=planner)
#   aggregate buckets       fresh=70 cwrite=700 cread=7000 out=7  total=7777
@test "by_agent_type: each sidecar's agentType is a bucket; collapsed sum reconciles to buckets" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-023 --plan-slug ba \
    --out-dir "$OUTDIR" --session-id fixturebyagent0001 \
    --projects-root "$BYAGENT" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # one bucket per sidecar agentType, plus the main-transcript bucket
  [ "$(led '.by_agent_type | keys | join(",")')" = "main,planner,researcher" ]
  [ "$(led '.by_agent_type.researcher.fresh_input')" -eq 20 ]
  [ "$(led '.by_agent_type.planner.fresh_input')" -eq 40 ]
  [ "$(led '.by_agent_type.main.fresh_input')" -eq 10 ]

  # reconcile-by-equality: collapse 5m+1h -> cache_write; Sigma buckets == aggregate.
  [ "$(led '([.by_agent_type[].fresh_input] | add) == .buckets.fresh_input')" = "true" ]
  [ "$(led '([.by_agent_type[] | (.cache_write_5m + .cache_write_1h)] | add) == .buckets.cache_write')" = "true" ]
  [ "$(led '([.by_agent_type[].cache_read] | add) == .buckets.cache_read')" = "true" ]
  [ "$(led '([.by_agent_type[].output] | add) == .buckets.output')" = "true" ]
}

# ---------- 19. git_branch + project identity (AC6) ----------
# Real default resolution inside throwaway git repos, so `project` reflects each
# repo's own origin remote. The https and ssh forms of ONE repo normalize to the
# same id; a different repo (different owner) differs.
@test "every record carries git_branch + project; same remote shares id, distinct remotes differ" {
  mkrepo() {
    git -C "$1" init -q
    git -C "$1" remote add origin "$2"
    git -C "$1" commit --allow-empty -q -m init
  }
  runproj() {
    ( cd "$1" && bash "$SCRIPT" --action spec --spec-id SPEC-013 \
        --out-dir "$1/out" --session-id fixturesingle0001 \
        --projects-root "$FIX/single/projects" --ledger "$1/cost.jsonl" >/dev/null 2>&1 )
    jq -r '.project' "$1/cost.jsonl"
  }
  mkdir -p "$BATS_TEST_TMPDIR/rhttps" "$BATS_TEST_TMPDIR/rssh" "$BATS_TEST_TMPDIR/rother"
  mkrepo "$BATS_TEST_TMPDIR/rhttps" "https://github.com/acme/widgets.git"
  mkrepo "$BATS_TEST_TMPDIR/rssh"   "git@github.com:acme/widgets.git"
  mkrepo "$BATS_TEST_TMPDIR/rother" "https://github.com/other/widgets.git"

  A="$(runproj "$BATS_TEST_TMPDIR/rhttps")"
  B="$(runproj "$BATS_TEST_TMPDIR/rssh")"
  C="$(runproj "$BATS_TEST_TMPDIR/rother")"

  case "$A" in sha256:*) : ;; *) echo "bad project id: $A" >&2; return 1 ;; esac
  [ "$A" = "$B" ]     # https and ssh forms of one repo -> one id
  [ "$A" != "$C" ]    # a different repo -> a different id

  # git_branch recorded (the repo's committed default branch)
  br="$(jq -r '.git_branch' "$BATS_TEST_TMPDIR/rhttps/cost.jsonl")"
  [ -n "$br" ]
  [ "$br" != "null" ]
}

# ---------- 20. seq/final over repeated execute writes (AC7) ----------
@test "three execute writes: seq 0,1,2, only the last final:true, final row is cumulative" {
  L="$BATS_TEST_TMPDIR/seq.jsonl"
  for n in 1 2 3; do
    run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug s \
      --out-dir "$OUTDIR" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$L"
    [ "$status" -eq 0 ]
  done

  [ "$(wc -l < "$L" | tr -d ' ')" -eq 3 ]
  [ "$(jq -r '.seq' "$L" | tr '\n' ',')" = "0,1,2," ]
  [ "$(jq -c 'select(.final == true)' "$L" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(jq -r 'select(.final == true).seq' "$L")" -eq 2 ]
  # the final:true row is the true cumulative total (no per-commit overcount)
  [ "$(jq -r 'select(.final == true).total' "$L")" -eq 11110 ]
}

# ---------- 21. cutover: fresh cost.jsonl, old ledger moved aside (AC8) ----------
@test "cutover: first cost.jsonl append moves tokens.jsonl aside; second run does not re-trigger" {
  dir="$BATS_TEST_TMPDIR/cut"
  mkdir -p "$dir"
  printf '%s\n' '{"schema_version":0,"legacy":"row"}' > "$dir/tokens.jsonl"

  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$dir/out" --session-id fixturesingle0001 \
    --projects-root "$FIX/single/projects" --ledger "$dir/cost.jsonl"
  [ "$status" -eq 0 ]

  # old ledger moved to .bak (never read, never deleted); fresh cost.jsonl holds
  # ONLY the new schema_version-1 row, no mixed-vintage legacy row
  [ -f "$dir/tokens.jsonl.bak" ]
  [ "$(jq -r '.legacy' "$dir/tokens.jsonl.bak")" = "row" ]
  [ ! -f "$dir/tokens.jsonl" ]
  [ "$(wc -l < "$dir/cost.jsonl" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.schema_version' "$dir/cost.jsonl")" -eq 1 ]
  [ "$(jq -r '.legacy // "absent"' "$dir/cost.jsonl")" = "absent" ]

  # second run must NOT re-trigger the rename (idempotent once cost.jsonl exists)
  printf '%s\n' '{"stray":"do-not-move"}' > "$dir/tokens.jsonl"
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$dir/out" --session-id fixturesingle0001 \
    --projects-root "$FIX/single/projects" --ledger "$dir/cost.jsonl"
  [ "$status" -eq 0 ]
  [ -f "$dir/tokens.jsonl" ]
  [ "$(jq -r '.stray' "$dir/tokens.jsonl")" = "do-not-move" ]
  [ "$(wc -l < "$dir/cost.jsonl" | tr -d ' ')" -eq 2 ]
}

# ---------- 22. session_cwd (U1): live $PWD, never --out-dir/--ledger (UAT-001) ----------
@test "22: session_cwd captures the live working directory, diverging from out-dir and ledger dir" {
  # Canonicalize up front (cd && pwd, no -P) so the expected value matches the
  # tally's own $PWD byte-for-byte even if $BATS_TEST_TMPDIR resolves through a
  # /tmp -> /private/tmp symlink on macOS.
  workdir_raw="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$workdir_raw"
  workdir="$(cd "$workdir_raw" && pwd)"

  ( cd "$workdir" && bash "$SCRIPT" \
      --action execute --spec-id SPEC-013 --plan-slug s \
      --out-dir "$OUTDIR" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$LEDGER" )

  got="$(jq -r 'select(.spec_id=="SPEC-013") | .session_cwd' "$LEDGER" | tail -1)"
  [ "$got" = "$workdir" ] || return 1
  # Pin the worktree divergence UAT-001 rests on: session_cwd is the LIVE cwd,
  # never the out-dir or the ledger's directory (both resolve to the main
  # checkout in worktree mode). $workdir is deliberately distinct from both.
  [ "$got" != "$OUTDIR" ] || return 1
  [ "$got" != "$(dirname "$LEDGER")" ] || return 1
}

@test "22b: session_cwd forward-encodes cleanly (/ and . -> -, no / or . survive)" {
  workdir_raw="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$workdir_raw"
  workdir="$(cd "$workdir_raw" && pwd)"

  ( cd "$workdir" && bash "$SCRIPT" \
      --action execute --spec-id SPEC-013 --plan-slug s \
      --out-dir "$OUTDIR" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$LEDGER" )

  got="$(jq -r 'select(.spec_id=="SPEC-013") | .session_cwd' "$LEDGER" | tail -1)"
  enc="$(printf '%s' "$got" | tr './' '-')"
  case "$enc" in
    *[./]*) echo "forward-encoded session_cwd still contains / or .: $enc" >&2; return 1 ;;
  esac
}

@test "23: session_cwd is still emitted (set to the run cwd) on the degraded path" {
  workdir_raw="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$workdir_raw"
  workdir="$(cd "$workdir_raw" && pwd)"

  # missing/unresolvable session id -> partial run, record still built
  run bash -c "cd '$workdir' && bash '$SCRIPT' \
    --action spec --spec-id SPEC-013 \
    --out-dir '$OUTDIR' --session-id no-such-session-9999 \
    --projects-root '$ANCHOR' --ledger '$LEDGER'"
  [ "$status" -eq 0 ]
  [ "$(led '.partial')" = "true" ]
  [ "$(led '.session_cwd')" = "$workdir" ]
}
