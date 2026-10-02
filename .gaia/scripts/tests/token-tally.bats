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
#   the ledger records the raw UTC endpoints; the human surface (stdout)
#     renders them in the machine's LOCAL zone (proven below under a
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
#
# auditreview/ (session fixtureauditreview0001): the FC-2/FC-4 oracle for the
# adversarial-audit nesting and the phase-side double-count guard. Session
# contains a main transcript, two adversarial general-purpose sidecars (an
# audit's dispatched lenses), and a code-review-audit sidecar with one nested
# general-purpose sub-agent contained in its own span. HAND-COMPUTED:
#   main       fresh=1  cwrite=2   cread=3   out=4    ts 09:00:00
#   aud-a      fresh=10 cwrite=20  cread=30  out=40   ts 10:05:10 (general-purpose)
#   aud-b      fresh=11 cwrite=21  cread=31  out=41   ts 10:06:00 (general-purpose)
#   rev-a      fresh=100 cwrite=200 cread=300 out=400 ts 11:00:00 (code-review-audit, file tmin)
#   rev-b      fresh=13  cwrite=17  cread=19  out=23  ts 11:02:00 (code-review-audit, file tmax)
#   nest-a     fresh=2   cwrite=3   cread=5   out=7   ts 11:01:00 (general-purpose, nested inside rev's span)
#   session-wide totals (main+aud-a+aud-b+rev-a+rev-b+nest-a): fresh=137 cwrite=263 cread=388 out=515 total=1303
#   review window = [rev file tmin, tmax] = [11:00:00, 11:02:00] -> contains
#     rev-a, rev-b (the review's own file) and nest-a; excludes aud-a/aud-b/main.
#     review record: fresh=115 cwrite=220 cread=324 out=430 total=1089,
#     duration_seconds 120 (11:02:00-11:00:00), review_id "agent-rev0001".
#   phase buckets after excluding the review window (drops rev-a/rev-b/nest-a,
#     keeps main+aud-a+aud-b): fresh=22 cwrite=43 cread=64 out=85 total=214
#     (= session-wide total 1303 minus the review window's 1089 minus... no:
#     214 = 1+10+11 / 2+20+21 / 3+30+31 / 4+40+41, i.e. main+aud-a+aud-b only;
#     the double-count guard proves an --action execute row lands exactly here,
#     never 1303).
#   adversarial-audit breadcrumb window = [10:05:00, 10:07:00] -> contains
#     aud-a + aud-b only (both single-point tmin==tmax, trivially inside):
#     audit.adversarial.buckets fresh=21 cwrite=41 cread=61 out=81,
#     elapsed_seconds 50 (10:06:00-10:05:10). Each value <= the phase bucket
#     above (UAT-003). No `.message.model` anywhere in this fixture, so
#     by_model is always empty and every dollars figure is null by
#     construction (no rate-table fixture needed for this suite).
#   fixtures/token-tally/auditreview/cache/audit-window-SPEC-032.json: the spec
#     breadcrumb (session fixtureauditreview0001, intensity "standard").
#   fixtures/token-tally/auditreview/cache/audit-window-SPEC-032-plan.json: the
#     spec-derived plan breadcrumb, same window, lenses ["DP","CG","COV"], no
#     `intensity` key (UAT-005). Tests copy these into an isolated per-test
#     cache dir before running (the breadcrumb is consumed/deleted on read), so
#     the checked-in fixtures are never mutated.

setup() {
  # Isolate pricing from the developer's real rate table and the network.
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIRECTORY/token-tally.sh"
  FIXTURE_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/fixtures/token-tally" && pwd)"

  ANCHOR="$FIXTURE_DIRECTORY/projects"
  SESSION="fixturesession0001"
  MULTIMODEL="$FIXTURE_DIRECTORY/multimodel/projects"
  MULTIMODEL_SPLITLESS="$FIXTURE_DIRECTORY/multimodel/splitless/projects"
  BY_AGENT_PROJECTS="$FIXTURE_DIRECTORY/byagent/projects"

  OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/out"
  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"

  # Isolated, empty audit-window cache for spec/plan tallies. --action spec/plan
  # consume-on-tally a breadcrumb from --cache-dir (SPEC-032, audit-window-<id>
  # .json); an empty per-test dir keeps every such invocation off the real
  # .gaia/local/cache, which it would otherwise fall through to and DELETE a
  # developer's live breadcrumb when a fixture id matches. Add --cache-dir
  # "$CACHE" to every new spec/plan invocation that runs from the repo cwd. (The
  # SPEC-032 audit-nesting tests pass their own fixture $AUDIT_REVIEW_CACHE and are
  # unaffected; execute never reads a breadcrumb.)
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"

  # Git identity for the worktree sandbox (CI without a configured user).
  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"
}

# Run the helper against the anchor fixture with an ISOLATED ledger (never the
# machine's real .gaia/local/telemetry/cost.jsonl).
# shellcheck disable=SC2120  # "$@" forwards optional extra args; most call sites pass none by design
run_anchor() {
  run bash "$SCRIPT" \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER" "$@"
}

ledger_field() { jq -r "$1" "$LEDGER"; }

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
  [ "$(ledger_field '.buckets.fresh_input')" -eq 100 ]
  [ "$(ledger_field '.buckets.cache_write')" -eq 1000 ]
  [ "$(ledger_field '.buckets.cache_read')" -eq 10000 ]
  [ "$(ledger_field '.buckets.output')" -eq 10 ]
  [ "$(ledger_field '.total')" -eq 11110 ]

  # cost.json carries the same five figures under the execute key.
  [ "$(jq -r '.execute.buckets.fresh_input' "$OUTPUT_DIRECTORY/cost.json")" -eq 100 ]
  [ "$(jq -r '.execute.buckets.cache_write' "$OUTPUT_DIRECTORY/cost.json")" -eq 1000 ]
  [ "$(jq -r '.execute.buckets.cache_read' "$OUTPUT_DIRECTORY/cost.json")" -eq 10000 ]
  [ "$(jq -r '.execute.buckets.output' "$OUTPUT_DIRECTORY/cost.json")" -eq 10 ]
  [ "$(jq -r '.execute.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 11110 ]

  # UAT-004: every bucket non-zero and mutually distinct (kills hardcoded-zero,
  # single-collapsed-input, and wrong-field-mapping helpers).
  fresh_input_value="$(ledger_field '.buckets.fresh_input')"; cache_write_value="$(ledger_field '.buckets.cache_write')"
  cache_read_value="$(ledger_field '.buckets.cache_read')";  output_value="$(ledger_field '.buckets.output')"
  for bucket_value in "$fresh_input_value" "$cache_write_value" "$cache_read_value" "$output_value"; do [ "$bucket_value" -ne 0 ]; done
  [ "$fresh_input_value" -ne "$cache_write_value" ]; [ "$fresh_input_value" -ne "$cache_read_value" ]; [ "$fresh_input_value" -ne "$output_value" ]
  [ "$cache_write_value" -ne "$cache_read_value" ]; [ "$cache_write_value" -ne "$output_value" ]; [ "$cache_read_value" -ne "$output_value" ]
}

# ---------- 2. Dedup (documented) ----------
@test "anchor: dedups streamed message.id (output=10 deduped, not 12 naive)" {
  run_anchor
  [ "$status" -eq 0 ]
  # m1 is streamed 3x with identical usage; deduped output is 1+2+3+4 = 10.
  # A naive per-line sum would count m1 three times -> output 12, total 13332.
  [ "$(ledger_field '.buckets.output')" -eq 10 ]
  [ "$(ledger_field '.total')" -eq 11110 ]
  [ "$(ledger_field '.total')" -ne 13332 ]
}

# ---------- 3. Sidecar inclusion (UAT-003) ----------
@test "anchor: total includes sidecars (>= sidecar-only, > main-only)" {
  run_anchor
  [ "$status" -eq 0 ]
  total="$(ledger_field '.total')"
  # hand-computed sub-sums: main-only 3333, sidecar-only 7777
  [ "$total" -ge 7777 ]   # >= sidecar-only sum (UAT-003)
  [ "$total" -gt 3333 ]   # strictly > main-only sum -> sidecars contributed
  [ "$total" -eq 11110 ]  # = 3333 + 7777
}

# ---------- 4. agent-*.meta.json excluded ----------
@test "meta.json sibling is never read (adding one does not change the tally)" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  subagents_directory="$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$BATS_TEST_TMPDIR/l1.jsonl"
  [ "$status" -eq 0 ]
  before="$(jq -r '.total' "$BATS_TEST_TMPDIR/l1.jsonl")"

  # Add a second .meta.json full of usage; the glob must still ignore it.
  printf '%s\n' '{"type":"assistant","uuid":"x","message":{"id":"meta2","usage":{"input_tokens":999999,"cache_creation_input_tokens":999999,"cache_read_input_tokens":999999,"output_tokens":999999}}}' \
    > "$subagents_directory/agent-9999.meta.json"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$BATS_TEST_TMPDIR/l2.jsonl"
  [ "$status" -eq 0 ]
  after="$(jq -r '.total' "$BATS_TEST_TMPDIR/l2.jsonl")"

  [ "$before" -eq 11110 ]
  [ "$after" -eq "$before" ]
}

# ---------- 4b. workflow sidecars (subagents/workflows/wf_<id>/) are tallied ----------
# A Workflow run writes its agents one level deeper than a plain Agent dispatch.
# m5 (fresh=50 cwrite=500 cread=5000 out=5, 5555) sits inside the anchor's span,
# so the total moves 11110 -> 16665 and the duration stays 125s. Its meta.json
# sibling names the agentType bucket, and the journal.jsonl decoy (usage 999999)
# must stay out, exactly like the plain-sidecar meta.json decoy.
@test "workflow sidecars under subagents/workflows/wf_*/ are tallied" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  workflow_directory="$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents/workflows/wf_fixture0001"
  mkdir -p "$workflow_directory"
  printf '%s\n' '{"type":"assistant","uuid":"u-m5-a","timestamp":"2026-07-02T17:01:00.000Z","message":{"id":"m5","role":"assistant","usage":{"input_tokens":50,"cache_creation_input_tokens":500,"cache_read_input_tokens":5000,"output_tokens":5}}}' \
    > "$workflow_directory/agent-0005.jsonl"
  printf '%s\n' '{"agentType":"workflow-subagent"}' > "$workflow_directory/agent-0005.meta.json"
  printf '%s\n' '{"type":"assistant","uuid":"j","message":{"id":"journal1","usage":{"input_tokens":999999,"cache_creation_input_tokens":999999,"cache_read_input_tokens":999999,"output_tokens":999999}}}' \
    > "$workflow_directory/journal.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.partial')" = "false" ]
  [ "$(ledger_field '.total')" -eq 16665 ]
  [ "$(ledger_field '.duration_seconds')" -eq 125 ]
  [ "$(ledger_field '.by_agent_type["workflow-subagent"].fresh_input')" -eq 50 ]
}

# ---------- 5. cost.json content (UAT-001) ----------
@test "cost.json exists in --out-dir with all five figures (not empty/placeholder)" {
  run_anchor
  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_DIRECTORY/cost.json" ]
  [ -s "$OUTPUT_DIRECTORY/cost.json" ]
  # all five figures present under the execute key
  [ "$(jq -r '.execute.buckets.fresh_input' "$OUTPUT_DIRECTORY/cost.json")" -eq 100 ]
  [ "$(jq -r '.execute.buckets.cache_write' "$OUTPUT_DIRECTORY/cost.json")" -eq 1000 ]
  [ "$(jq -r '.execute.buckets.cache_read' "$OUTPUT_DIRECTORY/cost.json")" -eq 10000 ]
  [ "$(jq -r '.execute.buckets.output' "$OUTPUT_DIRECTORY/cost.json")" -eq 10 ]
  [ "$(jq -r '.execute.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 11110 ]
}

# ---------- 5b. plan + execute keys coexist in one cost.json ----------
# /gaia-plan and the KICKOFF git-op hook both write the plan folder's cost.json.
# The plan-authoring and plan-execution costs must live in independent keys of
# the SAME file: never overwriting each other, never summed. Planning uses the
# single-line fixture (total 562); Execution uses the anchor (total 11110), so a
# clobbered-vs-preserved or a summed regression is unambiguous.
@test "plan then execute: cost.json keeps independent plan + execute keys (no overwrite, no sum)" {
  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturesingle0001" \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$BATS_TEST_TMPDIR/l-plan.jsonl" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.plan.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 562 ]
  [ "$(jq -r '.execute // "absent"' "$OUTPUT_DIRECTORY/cost.json")" = "absent" ]

  before="$(jq -c '.plan' "$OUTPUT_DIRECTORY/cost.json")"

  # Execution tally into the SAME out-dir must add a key, not replace the file.
  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/l-exec.jsonl"
  [ "$status" -eq 0 ]

  # Both keys present; plan is byte-unchanged, execute reflects its own tally.
  after="$(jq -c '.plan' "$OUTPUT_DIRECTORY/cost.json")"
  [ "$before" = "$after" ]
  [ "$(jq -r '.execute.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 11110 ]

  # No summed figure anywhere (562 + 11110 = 11672 must never appear).
  grep -qF "11672" <(jq -c '.' "$OUTPUT_DIRECTORY/cost.json") && return 1
  return 0
}

# The git-op hook re-runs the execute tally on every orchestrator commit, so the
# execute key is rewritten repeatedly; that must not disturb the plan key
# written once upstream, and the file stays a two-key object (no duplication).
@test "repeated execute writes preserve the plan key and never duplicate keys" {
  run bash "$SCRIPT" --action plan --spec-id SPEC-013 --plan-slug my-plan \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturesingle0001" \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$BATS_TEST_TMPDIR/lp.jsonl" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  for _ in 1 2 3; do
    run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug my-plan \
      --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/le.jsonl"
    [ "$status" -eq 0 ]
  done

  [ "$(jq -r 'keys | sort | join(",")' "$OUTPUT_DIRECTORY/cost.json")" = "execute,plan" ]
  [ "$(jq -r '.plan.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 562 ]
  [ "$(jq -r '.execute.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 11110 ]
}

# ---------- 6. Ledger keyed + durable (UAT-005) ----------
@test "ledger record is valid JSON, keyed, and survives out-dir (plan folder) deletion" {
  run bash "$SCRIPT" \
    --action plan --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/durable.jsonl" \
    --cache-dir "$CACHE"
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
  rm -rf "$OUTPUT_DIRECTORY"
  [ -f "$BATS_TEST_TMPDIR/durable.jsonl" ]
  [ "$(jq -r '.total' "$BATS_TEST_TMPDIR/durable.jsonl")" -eq 11110 ]
}

# ---------- 7. Ledger -> main checkout under a worktree (UAT-008) ----------
# Uses the REAL default ledger resolution (no --ledger), entirely inside a
# throwaway tmp git repo, so the "real" ledger is the tmp repo's, not the machine's.
@test "worktree run writes the ledger to the main checkout, not the worktree" {
  MAIN="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/main"
  WORKTREE="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" commit --allow-empty -q -m "init"
  git -C "$MAIN" worktree add -q "$WORKTREE" -b "feature/kickoff"

  run bash -c "cd '$WORKTREE' && bash '$SCRIPT' \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir '$WORKTREE/out' --session-id '$SESSION' --projects-root '$ANCHOR'"
  [ "$status" -eq 0 ]

  # Ledger landed in the MAIN checkout ...
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
  [ "$(jq -r '.total' "$MAIN/.gaia/local/telemetry/cost.jsonl")" -eq 11110 ]
  # ... and NOT under the worktree.
  [ ! -f "$WORKTREE/.gaia/local/telemetry/cost.jsonl" ]

  # Ledger survives worktree removal (UAT-008 durability).
  git -C "$MAIN" worktree remove --force "$WORKTREE" 2>/dev/null || rm -rf "$WORKTREE"
  [ -f "$MAIN/.gaia/local/telemetry/cost.jsonl" ]
}

# ---------- 8. Graceful degradation (UAT-007) ----------
@test "non-existent session: exit 0, partial, buckets 0, marker in all surfaces" {
  run bash "$SCRIPT" \
    --action spec --spec-id SPEC-013 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "no-such-session-9999" \
    --projects-root "$ANCHOR" --ledger "$LEDGER" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  # stdout marker + zero buckets
  [[ "$output" == *"(partial: figures are a lower bound"* ]]
  [[ "$output" == *"Total:        0"* ]]

  # ledger partial:true, buckets 0
  [ "$(ledger_field '.partial')" = "true" ]
  [ "$(ledger_field '.total')" -eq 0 ]

  # cost.json carries the same partial:true marker (same $rec as the ledger)
  [ "$(jq -r '.spec.partial' "$OUTPUT_DIRECTORY/cost.json")" = "true" ]
}

@test "malformed sidecar line: exit 0, partial, still tallies the readable files" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  subagents_directory="$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents"
  # A NEW sidecar whose line is not valid JSON: it must flip partial and
  # contribute nothing, while the good main + sidecars still sum to 11110.
  printf '%s\n' 'this is not json {{{' > "$subagents_directory/agent-0009.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.partial')" = "true" ]
  [ "$(ledger_field '.total')" -eq 11110 ]   # readable files still tallied, nothing fabricated
}

@test "empty session id (no --session-id, unset env): exit 0, partial, no crash" {
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" \
    --action spec --spec-id SPEC-013 \
    --out-dir "$OUTPUT_DIRECTORY" --projects-root "$ANCHOR" --ledger "$LEDGER" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.partial')" = "true" ]
  [ "$(ledger_field '.total')" -eq 0 ]
}

# ---------- 10. Elapsed exact span (PL-001) ----------
# The ledger records the raw UTC endpoints (timezone-independent); the human
# surfaces render them in the machine's LOCAL zone. Pinned to TZ=UTC here so the
# local display is deterministic (UTC clock, labelled UTC); the conversion to a
# non-UTC zone is proven in the next test.
@test "anchor: elapsed span 125s/2m5s, ledger raw UTC, human surfaces local (TZ=UTC)" {
  run env TZ=UTC bash "$SCRIPT" \
    --action execute --spec-id SPEC-013 --plan-slug spec-013-token-accounting \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # ledger: raw UTC endpoints (durable machine record)
  [ "$(ledger_field '.duration_seconds')" -eq 125 ]
  [ "$(ledger_field '.duration_available')" = "true" ]
  [ "$(ledger_field '.started_at')" = "2026-07-02T17:00:00.000Z" ]
  [ "$(ledger_field '.ended_at')" = "2026-07-02T17:02:05.000Z" ]

  # stdout pinned human format + LOCAL window (kills 0, ms=125000, all-lines=630s,
  # main-only=30s, deduped-min=124s). TZ=UTC -> local clock == UTC, labelled UTC.
  grep -qF "Elapsed:      2m5s  (first to last model turn: 2026-07-02 17:00:00 UTC to 2026-07-02 17:02:05 UTC)" <<<"$output"

  # cost.json carries the raw UTC endpoints under the execute key (no
  # human-rendered duration string; that surface is stdout-only).
  [ "$(jq -r '.execute.started_at' "$OUTPUT_DIRECTORY/cost.json")" = "2026-07-02T17:00:00.000Z" ]
  [ "$(jq -r '.execute.ended_at' "$OUTPUT_DIRECTORY/cost.json")" = "2026-07-02T17:02:05.000Z" ]
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
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # ledger unchanged: raw UTC, span unchanged
  [ "$(ledger_field '.started_at')" = "2026-07-02T17:00:00.000Z" ]
  [ "$(ledger_field '.ended_at')" = "2026-07-02T17:02:05.000Z" ]
  [ "$(ledger_field '.duration_seconds')" -eq 125 ]

  # human surfaces: +0900 local, crossing midnight into 2026-07-03
  grep -qF "first to last model turn: 2026-07-03 02:00:00 JST to 2026-07-03 02:02:05 JST" <<<"$output"
  grep -qF "Elapsed:      2m5s" <<<"$output"

  # cost.json keeps the raw UTC endpoints regardless of TZ (no local rendering
  # in the sidecar; that is stdout-only).
  [ "$(jq -r '.execute.started_at' "$OUTPUT_DIRECTORY/cost.json")" = "2026-07-02T17:00:00.000Z" ]
  [ "$(jq -r '.execute.ended_at' "$OUTPUT_DIRECTORY/cost.json")" = "2026-07-02T17:02:05.000Z" ]
}

# ---------- 11. Max in a sidecar (documents sidecar inclusion) ----------
@test "removing the sidecar holding the global max shortens the reported span" {
  cp -R "$ANCHOR" "$BATS_TEST_TMPDIR/projcopy"
  rm -f "$BATS_TEST_TMPDIR/projcopy/proj-hash-a/$SESSION/subagents/agent-0002.jsonl"

  run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug slug \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$BATS_TEST_TMPDIR/projcopy" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
  # global max was 17:02:05 (agent-0002); removing it leaves m3 (agent-0001) at
  # 17:01:00 as the new max -> span 60s < 125s.
  [ "$(ledger_field '.duration_seconds')" -eq 60 ]
  [ "$(ledger_field '.ended_at')" = "2026-07-02T17:01:00.000Z" ]
}

# ---------- 12. Single / zero ----------
@test "single usage line: duration 0, available true" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-000 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturesingle0001" \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$LEDGER" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.duration_seconds')" -eq 0 ]
  [ "$(ledger_field '.duration_available')" = "true" ]
  [ "$(ledger_field '.total')" -eq 562 ]
}

@test "zero usage lines (timestamped non-usage only): unavailable/null, buckets 0, partial false" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-000 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturezero0001" \
    --projects-root "$FIXTURE_DIRECTORY/zero/projects" --ledger "$LEDGER" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.duration_available')" = "false" ]
  [ "$(ledger_field '.duration_seconds')" = "null" ]
  [ "$(ledger_field '.total')" -eq 0 ]
  [ "$(ledger_field '.partial')" = "false" ]
  [[ "$output" == *"Elapsed:      unavailable (no readable turn timestamps)"* ]]
}

# ---------- 13. Malformed timestamp + flag independence ----------
@test "malformed extremal timestamp: unavailable, buckets intact, partial false (flag independence)" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-000 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturemalformed0001" \
    --projects-root "$FIXTURE_DIRECTORY/malformed/projects" --ledger "$LEDGER" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  # duration unavailable ...
  [ "$(ledger_field '.duration_available')" = "false" ]
  [ "$(ledger_field '.duration_seconds')" = "null" ]
  [ "$(ledger_field '.started_at')" = "null" ]
  [ "$(ledger_field '.ended_at')" = "null" ]

  # ... while the four buckets equal their hand-computed sums and partial is FALSE.
  # Only this case falsifies a helper that conflates partial with duration_available.
  [ "$(ledger_field '.partial')" = "false" ]
  [ "$(ledger_field '.buckets.fresh_input')" -eq 11 ]
  [ "$(ledger_field '.buckets.cache_write')" -eq 22 ]
  [ "$(ledger_field '.buckets.cache_read')" -eq 33 ]
  [ "$(ledger_field '.buckets.output')" -eq 44 ]
}

# ---------- 14. Multi-model attribution (FC-1, SPEC-019) ----------
@test "multimodel: by_model attributes each model, sentinel excluded" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(ledger_field '.by_model | keys | join(",")')" = "claude-opus-4-8,claude-sonnet-4-6" ]
  [ "$(ledger_field '.by_model["<synthetic>"]')" = "null" ]

  [ "$(ledger_field '.by_model["claude-opus-4-8"].fresh_input')" -eq 300 ]
  [ "$(ledger_field '.by_model["claude-opus-4-8"].cache_write_5m')" -eq 40 ]
  [ "$(ledger_field '.by_model["claude-opus-4-8"].cache_write_1h')" -eq 360 ]
  [ "$(ledger_field '.by_model["claude-opus-4-8"].cache_read')" -eq 3000 ]
  [ "$(ledger_field '.by_model["claude-opus-4-8"].output')" -eq 30 ]

  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].fresh_input')" -eq 30 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_write_5m')" -eq 10 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_write_1h')" -eq 20 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_read')" -eq 3000 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].output')" -eq 3 ]
}

@test "multimodel: per-model buckets reconcile to the aggregate" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # Reconciliation invariant (FC-1): Σ per-model == aggregate buckets.
  [ "$(ledger_field '([.by_model[].fresh_input] | add) == .buckets.fresh_input')" = "true" ]
  [ "$(ledger_field '([.by_model[] | (.cache_write_5m + .cache_write_1h)] | add) == .buckets.cache_write')" = "true" ]
  [ "$(ledger_field '([.by_model[].cache_read] | add) == .buckets.cache_read')" = "true" ]
  [ "$(ledger_field '([.by_model[].output] | add) == .buckets.output')" = "true" ]
}

@test "multimodel: cache-write TTL split captured per model" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturemultimodel0001" \
    --projects-root "$MULTIMODEL" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(ledger_field '.by_model["claude-opus-4-8"].cache_write_5m')" -eq 40 ]
  [ "$(ledger_field '.by_model["claude-opus-4-8"].cache_write_1h')" -eq 360 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_write_5m')" -eq 10 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_write_1h')" -eq 20 ]

  # 5m + 1h summed across models equals the aggregate cache_write bucket.
  [ "$(ledger_field '(([.by_model[].cache_write_5m] | add) + ([.by_model[].cache_write_1h] | add)) == .buckets.cache_write')" = "true" ]
}

@test "split-less usage falls back to 1h and still reconciles" {
  run bash "$SCRIPT" --action execute --spec-id SPEC-019 --plan-slug spec-019-dollar-cost \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "fixturemultimodelsplitless0001" \
    --projects-root "$MULTIMODEL_SPLITLESS" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_write_5m')" -eq 0 ]
  [ "$(ledger_field '.by_model["claude-sonnet-4-6"].cache_write_1h')" -eq 500 ]
  [ "$(ledger_field '.buckets.cache_write')" -eq 500 ]
}

@test "legacy-shaped (model-less) session omits by_model" {
  run_anchor
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.by_model')" = "null" ]
  [ "$(ledger_field '.total')" -eq 11110 ]
}

# ---------- 15. Shared ledger-path lib (FC-1) ----------
@test "ledger-path-lib: resolves cost.jsonl, honors override, fails without git; token-tally sources it" {
  LIBRARY_FILE="$SCRIPT_DIRECTORY/ledger-path-lib.sh"
  [ -f "$LIBRARY_FILE" ]

  # override is echoed verbatim
  got="$(bash -c '. "$1"; gaia_resolve_ledger_path "/x/y/cost.jsonl"' _ "$LIBRARY_FILE")"
  [ "$got" = "/x/y/cost.jsonl" ]

  # inside a real git repo -> a main-checkout cost.jsonl path
  repo="$BATS_TEST_TMPDIR/librepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  repo_ledger_path="$(bash -c 'cd "$1" && . "$2"; gaia_resolve_ledger_path ""' _ "$repo" "$LIBRARY_FILE")"
  case "$repo_ledger_path" in
    */.gaia/local/telemetry/cost.jsonl) : ;;
    *) echo "unexpected ledger path: $repo_ledger_path" >&2; return 1 ;;
  esac
  # Differential oracle, exact match: the shared resolver behind this function
  # physically resolves (pwd -P), so the expected side must too, or this drifts
  # on a $BATS_TEST_TMPDIR under a symlinked component (e.g. macOS /var).
  repo_absolute_path="$(cd "$repo" && pwd -P)"
  [ "$repo_ledger_path" = "$repo_absolute_path/.gaia/local/telemetry/cost.jsonl" ]

  # outside any git repo -> non-zero, no output
  nongit="$BATS_TEST_TMPDIR/nongit"
  mkdir -p "$nongit"
  run bash -c 'cd "$1" && . "$2"; gaia_resolve_ledger_path ""' _ "$nongit" "$LIBRARY_FILE"
  [ "$status" -ne 0 ]

  # token-tally.sh sources the lib rather than inlining the derivation
  grep -qF 'ledger-path-lib.sh' "$SCRIPT"
  if grep -qF 'telemetry/cost.jsonl' "$SCRIPT"; then
    echo "token-tally.sh still inlines the ledger derivation" >&2
    return 1
  fi
}

# ---------- 16. spec doc: schema_version, spec key, no legacy md (AC2) ----------
@test "spec: schema_version 1, kind spec, seq 0/final, cost.json keyed by spec, only cost.json written" {
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$LEDGER" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  [ "$(ledger_field '.schema_version')" -eq 1 ]
  [ "$(ledger_field '.kind')" = "spec" ]
  [ "$(ledger_field '.spec_id')" = "SPEC-013" ]
  [ "$(ledger_field '.plan_id')" = "null" ]
  [ "$(ledger_field '.seq')" -eq 0 ]
  [ "$(ledger_field '.final')" = "true" ]

  [ "$(jq -r '.spec.kind' "$OUTPUT_DIRECTORY/cost.json")" = "spec" ]
  [ "$(jq -r '.spec.spec_id' "$OUTPUT_DIRECTORY/cost.json")" = "SPEC-013" ]
  [ "$(jq -r '.spec.total' "$OUTPUT_DIRECTORY/cost.json")" -eq 11110 ]

  # FC-1 acceptance shape (UAT-001): kind, spec_id, session_id present, buckets
  # shaped, total present, all under the top-level `spec` key.
  run jq -e '.spec | (.kind=="spec") and (.spec_id=="SPEC-013") and (.session_id!=null) and (.buckets|has("fresh_input")) and has("total")' "$OUTPUT_DIRECTORY/cost.json"
  [ "$status" -eq 0 ]

  # cost.json is the ONLY sidecar written (no legacy cost.md sibling remains)
  [ -f "$OUTPUT_DIRECTORY/cost.json" ]
  [ ! -f "$OUTPUT_DIRECTORY/cost.md" ]
}

# ---------- 17. spec_id XOR plan_id -- the single source-of-truth gate (AC3) ----------
# Both the plan.md step-4.8 caller edit (DOCS) and the execute-hook routing
# (WRITE-HOOKS) rely on this CLI behavior, so it is asserted explicitly across
# BOTH the plan and execute kinds: a SPEC-* key -> spec_id, a PLAN-* key ->
# plan_id, never both.
@test "spec_id XOR plan_id across plan and execute kinds; no record carries both" {
  # spec-derived plan: --spec-id SPEC-* -> spec_id set, plan_id null
  run bash "$SCRIPT" --action plan --spec-id SPEC-023 --plan-slug p \
    --out-dir "$OUTPUT_DIRECTORY/sd-plan" --session-id fixturesingle0001 \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$BATS_TEST_TMPDIR/sd-plan.jsonl" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' "$BATS_TEST_TMPDIR/sd-plan.jsonl")" = "plan" ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sd-plan.jsonl")" = "SPEC-023" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sd-plan.jsonl")" = "null" ]

  # spec-less plan: --plan-id PLAN-* -> plan_id set, spec_id null
  run bash "$SCRIPT" --action plan --plan-id PLAN-007 --plan-slug p \
    --out-dir "$OUTPUT_DIRECTORY/sl-plan" --session-id fixturesingle0001 \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$BATS_TEST_TMPDIR/sl-plan.jsonl" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind' "$BATS_TEST_TMPDIR/sl-plan.jsonl")" = "plan" ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sl-plan.jsonl")" = "null" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sl-plan.jsonl")" = "PLAN-007" ]

  # spec-derived execute
  run bash "$SCRIPT" --action execute --spec-id SPEC-023 --plan-slug p \
    --out-dir "$OUTPUT_DIRECTORY/sd-exec" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/sd-exec.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sd-exec.jsonl")" = "SPEC-023" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sd-exec.jsonl")" = "null" ]

  # spec-less execute
  run bash "$SCRIPT" --action execute --plan-id PLAN-007 --plan-slug p \
    --out-dir "$OUTPUT_DIRECTORY/sl-exec" --session-id "$SESSION" \
    --projects-root "$ANCHOR" --ledger "$BATS_TEST_TMPDIR/sl-exec.jsonl"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec_id' "$BATS_TEST_TMPDIR/sl-exec.jsonl")" = "null" ]
  [ "$(jq -r '.plan_id' "$BATS_TEST_TMPDIR/sl-exec.jsonl")" = "PLAN-007" ]

  # invariant: never both ids set on any of the four records
  for ledger_name in sd-plan sl-plan sd-exec sl-exec; do
    both="$(jq -r 'select(.spec_id != null and .plan_id != null) | "BOTH"' "$BATS_TEST_TMPDIR/$ledger_name.jsonl")"
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
    --out-dir "$OUTPUT_DIRECTORY" --session-id fixturebyagent0001 \
    --projects-root "$BY_AGENT_PROJECTS" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # one bucket per sidecar agentType, plus the main-transcript bucket
  [ "$(ledger_field '.by_agent_type | keys | join(",")')" = "main,planner,researcher" ]
  [ "$(ledger_field '.by_agent_type.researcher.fresh_input')" -eq 20 ]
  [ "$(ledger_field '.by_agent_type.planner.fresh_input')" -eq 40 ]
  [ "$(ledger_field '.by_agent_type.main.fresh_input')" -eq 10 ]

  # reconcile-by-equality: collapse 5m+1h -> cache_write; Sigma buckets == aggregate.
  [ "$(ledger_field '([.by_agent_type[].fresh_input] | add) == .buckets.fresh_input')" = "true" ]
  [ "$(ledger_field '([.by_agent_type[] | (.cache_write_5m + .cache_write_1h)] | add) == .buckets.cache_write')" = "true" ]
  [ "$(ledger_field '([.by_agent_type[].cache_read] | add) == .buckets.cache_read')" = "true" ]
  [ "$(ledger_field '([.by_agent_type[].output] | add) == .buckets.output')" = "true" ]
}

# ---------- 19. git_branch + project identity (AC6) ----------
# Real default resolution inside throwaway git repos, so `project` reflects each
# repo's own origin remote. The https and ssh forms of ONE repo normalize to the
# same id; a different repo (different owner) differs.
@test "every record carries git_branch + project; same remote shares id, distinct remotes differ" {
  make_repo() {
    git -C "$1" init -q
    git -C "$1" remote add origin "$2"
    git -C "$1" commit --allow-empty -q -m init
  }
  run_project() {
    # Deliberately no --cache-dir: this cd's into a fresh make_repo'd git repo, so
    # token-tally.sh derives its cache from THAT repo's git-common-dir, never the
    # real .gaia/local/cache. Isolated by construction.
    ( cd "$1" && bash "$SCRIPT" --action spec --spec-id SPEC-013 \
        --out-dir "$1/out" --session-id fixturesingle0001 \
        --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$1/cost.jsonl" >/dev/null 2>&1 )
    jq -r '.project' "$1/cost.jsonl"
  }
  mkdir -p "$BATS_TEST_TMPDIR/rhttps" "$BATS_TEST_TMPDIR/rssh" "$BATS_TEST_TMPDIR/rother"
  make_repo "$BATS_TEST_TMPDIR/rhttps" "https://github.com/acme/widgets.git"
  make_repo "$BATS_TEST_TMPDIR/rssh"   "git@github.com:acme/widgets.git"
  make_repo "$BATS_TEST_TMPDIR/rother" "https://github.com/other/widgets.git"

  HTTPS_PROJECT_ID="$(run_project "$BATS_TEST_TMPDIR/rhttps")"
  SSH_PROJECT_ID="$(run_project "$BATS_TEST_TMPDIR/rssh")"
  OTHER_PROJECT_ID="$(run_project "$BATS_TEST_TMPDIR/rother")"

  case "$HTTPS_PROJECT_ID" in sha256:*) : ;; *) echo "bad project id: $HTTPS_PROJECT_ID" >&2; return 1 ;; esac
  [ "$HTTPS_PROJECT_ID" = "$SSH_PROJECT_ID" ]     # https and ssh forms of one repo -> one id
  [ "$HTTPS_PROJECT_ID" != "$OTHER_PROJECT_ID" ]    # a different repo -> a different id

  # git_branch recorded (the repo's committed default branch)
  branch_name="$(jq -r '.git_branch' "$BATS_TEST_TMPDIR/rhttps/cost.jsonl")"
  [ -n "$branch_name" ]
  [ "$branch_name" != "null" ]
}

# ---------- 20. seq/final over repeated execute writes (AC7) ----------
@test "three execute writes: seq 0,1,2, only the last final:true, final row is cumulative" {
  SEQUENCE_LEDGER="$BATS_TEST_TMPDIR/seq.jsonl"
  for _ in 1 2 3; do
    run bash "$SCRIPT" --action execute --spec-id SPEC-013 --plan-slug s \
      --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$SEQUENCE_LEDGER"
    [ "$status" -eq 0 ]
  done

  [ "$(wc -l < "$SEQUENCE_LEDGER" | tr -d ' ')" -eq 3 ]
  [ "$(jq -r '.seq' "$SEQUENCE_LEDGER" | tr '\n' ',')" = "0,1,2," ]
  [ "$(jq -c 'select(.final == true)' "$SEQUENCE_LEDGER" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(jq -r 'select(.final == true).seq' "$SEQUENCE_LEDGER")" -eq 2 ]
  # the final:true row is the true cumulative total (no per-commit overcount)
  [ "$(jq -r 'select(.final == true).total' "$SEQUENCE_LEDGER")" -eq 11110 ]
}

# ---------- 21. cutover: fresh cost.jsonl, old ledger moved aside (AC8) ----------
@test "cutover: first cost.jsonl append moves tokens.jsonl aside; second run does not re-trigger" {
  cutover_directory="$BATS_TEST_TMPDIR/cut"
  mkdir -p "$cutover_directory"
  printf '%s\n' '{"schema_version":0,"legacy":"row"}' > "$cutover_directory/tokens.jsonl"

  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$cutover_directory/out" --session-id fixturesingle0001 \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$cutover_directory/cost.jsonl" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]

  # old ledger moved to .bak (never read, never deleted); fresh cost.jsonl holds
  # ONLY the new schema_version-1 row, no mixed-vintage legacy row
  [ -f "$cutover_directory/tokens.jsonl.bak" ]
  [ "$(jq -r '.legacy' "$cutover_directory/tokens.jsonl.bak")" = "row" ]
  [ ! -f "$cutover_directory/tokens.jsonl" ]
  [ "$(wc -l < "$cutover_directory/cost.jsonl" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.schema_version' "$cutover_directory/cost.jsonl")" -eq 1 ]
  [ "$(jq -r '.legacy // "absent"' "$cutover_directory/cost.jsonl")" = "absent" ]

  # second run must NOT re-trigger the rename (idempotent once cost.jsonl exists)
  printf '%s\n' '{"stray":"do-not-move"}' > "$cutover_directory/tokens.jsonl"
  run bash "$SCRIPT" --action spec --spec-id SPEC-013 \
    --out-dir "$cutover_directory/out" --session-id fixturesingle0001 \
    --projects-root "$FIXTURE_DIRECTORY/single/projects" --ledger "$cutover_directory/cost.jsonl" \
    --cache-dir "$CACHE"
  [ "$status" -eq 0 ]
  [ -f "$cutover_directory/tokens.jsonl" ]
  [ "$(jq -r '.stray' "$cutover_directory/tokens.jsonl")" = "do-not-move" ]
  [ "$(wc -l < "$cutover_directory/cost.jsonl" | tr -d ' ')" -eq 2 ]
}

# ---------- 22. session_cwd (U1): live $PWD, never --out-dir/--ledger (UAT-001) ----------
@test "22: session_cwd captures the live working directory, diverging from out-dir and ledger dir" {
  # Canonicalize up front (cd && pwd, no -P) so the expected value matches the
  # tally's own $PWD byte-for-byte even if $BATS_TEST_TMPDIR resolves through a
  # /tmp -> /private/tmp symlink on macOS.
  work_directory_raw="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$work_directory_raw"
  work_directory="$(cd "$work_directory_raw" && pwd)"

  ( cd "$work_directory" && bash "$SCRIPT" \
      --action execute --spec-id SPEC-013 --plan-slug s \
      --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$LEDGER" )

  got="$(jq -r 'select(.spec_id=="SPEC-013") | .session_cwd' "$LEDGER" | tail -1)"
  [ "$got" = "$work_directory" ] || return 1
  # Pin the worktree divergence UAT-001 rests on: session_cwd is the LIVE cwd,
  # never the out-dir or the ledger's directory (both resolve to the main
  # checkout in worktree mode). $work_directory is deliberately distinct from both.
  [ "$got" != "$OUTPUT_DIRECTORY" ] || return 1
  [ "$got" != "$(dirname "$LEDGER")" ] || return 1
}

@test "22b: session_cwd forward-encodes cleanly (/ and . -> -, no / or . survive)" {
  work_directory_raw="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$work_directory_raw"
  work_directory="$(cd "$work_directory_raw" && pwd)"

  ( cd "$work_directory" && bash "$SCRIPT" \
      --action execute --spec-id SPEC-013 --plan-slug s \
      --out-dir "$OUTPUT_DIRECTORY" --session-id "$SESSION" \
      --projects-root "$ANCHOR" --ledger "$LEDGER" )

  got="$(jq -r 'select(.spec_id=="SPEC-013") | .session_cwd' "$LEDGER" | tail -1)"
  encoded_session_cwd="$(printf '%s' "$got" | tr './' '-')"
  case "$encoded_session_cwd" in
    *[./]*) echo "forward-encoded session_cwd still contains / or .: $encoded_session_cwd" >&2; return 1 ;;
  esac
}

@test "23: session_cwd is still emitted (set to the run cwd) on the degraded path" {
  work_directory_raw="$BATS_TEST_TMPDIR/wd"
  mkdir -p "$work_directory_raw"
  work_directory="$(cd "$work_directory_raw" && pwd)"

  # missing/unresolvable session id -> partial run, record still built.
  # Deliberately no --cache-dir: this cd's into a non-repo tmpdir, so
  # git-common-dir resolution fails and token-tally.sh leaves CACHE_DIRECTORY empty,
  # skipping the breadcrumb block entirely. Never touches the real cache.
  run bash -c "cd '$work_directory' && bash '$SCRIPT' \
    --action spec --spec-id SPEC-013 \
    --out-dir '$OUTPUT_DIRECTORY' --session-id no-such-session-9999 \
    --projects-root '$ANCHOR' --ledger '$LEDGER'"
  [ "$status" -eq 0 ]
  [ "$(ledger_field '.partial')" = "true" ]
  [ "$(ledger_field '.session_cwd')" = "$work_directory" ]
}

# 24. FC-2 adversarial-audit nesting + FC-4 double-count guard (SPEC-032)
# All tests below use the auditreview/ fixture (see the header comment). Every
# test copies the checked-in breadcrumb fixture(s) into an isolated per-test
# cache dir first: the phase tally consumes (deletes) a matched breadcrumb, so
# running directly against the checked-in fixture would mutate it in place.

setup_auditreview() {
  AUDIT_REVIEW_PROJECTS="$FIXTURE_DIRECTORY/auditreview/projects"
  AUDIT_REVIEW_SESSION="fixtureauditreview0001"
  AUDIT_REVIEW_CACHE_SOURCE="$FIXTURE_DIRECTORY/auditreview/cache"
  AUDIT_REVIEW_CACHE="$BATS_TEST_TMPDIR/ar-cache"
  mkdir -p "$AUDIT_REVIEW_CACHE"
}

@test "24.1: spec action nests audit.adversarial identically on ledger row and cost.json sidecar (UAT-001/002)" {
  setup_auditreview
  cp "$AUDIT_REVIEW_CACHE_SOURCE/audit-window-SPEC-032.json" "$AUDIT_REVIEW_CACHE/"

  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]

  # phase totals: hand-computed 22/43/64/85/214 (main + aud-a + aud-b only;
  # the review window is excluded even though this fixture has no review
  # action running, proving the exclusion is unconditional on the phase path).
  [ "$(ledger_field '.buckets.fresh_input')" -eq 22 ]
  [ "$(ledger_field '.buckets.cache_write')" -eq 43 ]
  [ "$(ledger_field '.buckets.cache_read')" -eq 64 ]
  [ "$(ledger_field '.buckets.output')" -eq 85 ]
  [ "$(ledger_field '.total')" -eq 214 ]

  # audit.adversarial: hand-computed 21/41/61/81, elapsed 50, full lens set,
  # intensity present (spec).
  [ "$(ledger_field '.audit.adversarial.buckets.fresh_input')" -eq 21 ]
  [ "$(ledger_field '.audit.adversarial.buckets.cache_write')" -eq 41 ]
  [ "$(ledger_field '.audit.adversarial.buckets.cache_read')" -eq 61 ]
  [ "$(ledger_field '.audit.adversarial.buckets.output')" -eq 81 ]
  [ "$(ledger_field '.audit.adversarial.elapsed_seconds')" -eq 50 ]
  [ "$(ledger_field '.audit.adversarial.dollars')" = "null" ]
  [ "$(ledger_field '.audit.adversarial.intensity')" = "standard" ]
  [ "$(ledger_field '.audit.adversarial.lenses | sort | join(",")')" = "COV,FG,RT,TST" ]

  # identical on the cost.json sidecar's .spec value (UAT-001). Both sides use
  # `jq -c` (never the shared `ledger_field()` helper's `-r`, which pretty-prints an
  # object instead of leaving it compact) so the comparison is byte-exact.
  sidecar="$OUTPUT_DIRECTORY/cost.json"
  ledger_audit="$(jq -c '.audit' "$LEDGER")"
  sidecar_audit="$(jq -c '.spec.audit' "$sidecar")"
  [ "$ledger_audit" = "$sidecar_audit" ]

  # the breadcrumb is consumed (deleted) once the phase tally has read it.
  [ ! -f "$AUDIT_REVIEW_CACHE/audit-window-SPEC-032.json" ]
}

@test "24.2: UAT-003 subset invariant -- every audit bucket <= the phase bucket, phase total unaffected" {
  setup_auditreview
  cp "$AUDIT_REVIEW_CACHE_SOURCE/audit-window-SPEC-032.json" "$AUDIT_REVIEW_CACHE/"

  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]

  [ "$(ledger_field '.audit.adversarial.buckets.fresh_input <= .buckets.fresh_input')" = "true" ]
  [ "$(ledger_field '.audit.adversarial.buckets.cache_write <= .buckets.cache_write')" = "true" ]
  [ "$(ledger_field '.audit.adversarial.buckets.cache_read <= .buckets.cache_read')" = "true" ]
  [ "$(ledger_field '.audit.adversarial.buckets.output <= .buckets.output')" = "true" ]

  # the phase total is the same 214 whether or not the audit key is present
  # (it is never summed into total/buckets/dollars).
  [ "$(ledger_field '.total')" -eq 214 ]
}

@test "24.3: plan action (spec-derived) nests audit.adversarial with no intensity key (UAT-005)" {
  setup_auditreview
  cp "$AUDIT_REVIEW_CACHE_SOURCE/audit-window-SPEC-032-plan.json" "$AUDIT_REVIEW_CACHE/"

  run bash "$SCRIPT" --action plan --spec-id SPEC-032 --plan-slug spec-032-audit-cost \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]

  [ "$(ledger_field '.buckets.fresh_input')" -eq 22 ]
  [ "$(ledger_field '.total')" -eq 214 ]

  [ "$(ledger_field '.audit.adversarial.buckets.fresh_input')" -eq 21 ]
  [ "$(ledger_field '.audit.adversarial.buckets.output')" -eq 81 ]
  [ "$(ledger_field '.audit.adversarial.elapsed_seconds')" -eq 50 ]
  [ "$(ledger_field '.audit.adversarial.lenses | sort | join(",")')" = "CG,COV,DP" ]

  # plan audits carry no intensity key at all (UAT-005), not a null value.
  run jq -e '.audit.adversarial | has("intensity")' "$LEDGER"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]

  [ ! -f "$AUDIT_REVIEW_CACHE/audit-window-SPEC-032-plan.json" ]
}

@test "24.4: degrade -- absent breadcrumb omits .audit, phase record still written (UAT-009)" {
  setup_auditreview
  # AUDIT_REVIEW_CACHE is intentionally left empty: no breadcrumb for SPEC-032 exists.

  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]

  run jq -e 'has("audit")' "$LEDGER"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
  [ "$(ledger_field '.total')" -eq 214 ]
}

@test "24.5: degrade -- breadcrumb session_id mismatch omits .audit and still consumes the breadcrumb (UAT-009)" {
  setup_auditreview
  jq '.session_id = "some-other-session"' "$AUDIT_REVIEW_CACHE_SOURCE/audit-window-SPEC-032.json" \
    > "$AUDIT_REVIEW_CACHE/audit-window-SPEC-032.json"

  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]

  run jq -e 'has("audit")' "$LEDGER"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
  [ "$(ledger_field '.total')" -eq 214 ]
  [ ! -f "$AUDIT_REVIEW_CACHE/audit-window-SPEC-032.json" ]
}

@test "24.6: degrade -- a window catching zero sidecar activity omits .audit (never a zero-filled object)" {
  setup_auditreview
  jq '.started_at = "2099-01-01T00:00:00Z" | .ended_at = "2099-01-02T00:00:00Z"' \
    "$AUDIT_REVIEW_CACHE_SOURCE/audit-window-SPEC-032.json" > "$AUDIT_REVIEW_CACHE/audit-window-SPEC-032.json"

  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]

  run jq -e 'has("audit")' "$LEDGER"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
}

@test "24.7: double-count guard -- execute excludes the review window from phase buckets (AUDIT directive #3)" {
  setup_auditreview

  run bash "$SCRIPT" --action execute --spec-id SPEC-032 --plan-slug spec-032-audit-cost \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER"
  [ "$status" -eq 0 ]

  # hand-computed: main+aud-a+aud-b only (214), NEVER the session-wide 1303
  # (which would double-count the review sidecar's own spend).
  [ "$(ledger_field '.buckets.fresh_input')" -eq 22 ]
  [ "$(ledger_field '.buckets.cache_write')" -eq 43 ]
  [ "$(ledger_field '.buckets.cache_read')" -eq 64 ]
  [ "$(ledger_field '.buckets.output')" -eq 85 ]
  [ "$(ledger_field '.total')" -eq 214 ]
  [ "$(ledger_field '.total')" -ne 1303 ]

  # the FC-2 nesting gate is spec/plan only, never execute (the SPEC's own
  # words): no audit key at all, even though a breadcrumb-shaped fixture
  # exists for this same feature id.
  run jq -e 'has("audit")' "$LEDGER"
  [ "$status" -eq 1 ]
  [ "$output" = "false" ]
}

@test "24.8: back-compat -- a nested .spec.audit sidecar still passes cost_folder_represented" {
  setup_auditreview
  cp "$AUDIT_REVIEW_CACHE_SOURCE/audit-window-SPEC-032.json" "$AUDIT_REVIEW_CACHE/"

  run bash "$SCRIPT" --action spec --spec-id SPEC-032 \
    --out-dir "$OUTPUT_DIRECTORY" --session-id "$AUDIT_REVIEW_SESSION" \
    --projects-root "$AUDIT_REVIEW_PROJECTS" --ledger "$LEDGER" --cache-dir "$AUDIT_REVIEW_CACHE"
  [ "$status" -eq 0 ]
  run jq -e '.spec | has("audit")' "$OUTPUT_DIRECTORY/cost.json"
  [ "$status" -eq 0 ]

  GATE="$SCRIPT_DIRECTORY/cost-represented.sh"
  # shellcheck source=/dev/null
  . "$GATE"
  run cost_folder_represented "$OUTPUT_DIRECTORY" spec_id SPEC-032 "$LEDGER"
  [ "$status" -eq 0 ]
  grep -qF "$(printf 'spec\tREPRESENTED')" <<<"$output"
}

# 25. Task 3.5 differential oracle: compute_project_id's path fallback and the
# CACHE_DIRECTORY derivation now both resolve main_root through the shared resolver
# (.gaia/scripts/main-root-lib.sh) instead of hand-deriving it from
# git-common-dir. Both fixtures deliberately sit under $BATS_TEST_TMPDIR,
# which resolves through a symlinked component on macOS (/var -> private/var):
# the resolver physically resolves (pwd -P) where the old derivation used a
# plain pwd, so the expected-value side below canonicalizes with pwd -P too,
# the same fix applied to gh-artifact-lib.bats test 3.

@test "25.1: project id path-fallback (no origin remote) hashes the resolver's physically-resolved main_root" {
  repo="$BATS_TEST_TMPDIR/projrepo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" commit --allow-empty -q -m init

  repo_absolute_path="$(cd "$repo" && pwd -P)"
  expected_hash="$(printf '%s' "$repo_absolute_path" | shasum -a 256 | awk '{print substr($1,1,16)}')"

  run bash -c "cd '$repo' && bash '$SCRIPT' \
    --action spec --spec-id SPEC-013 \
    --out-dir '$repo/out' --session-id fixturesingle0001 \
    --projects-root '$FIXTURE_DIRECTORY/single/projects' --ledger '$repo/cost.jsonl' \
    --cache-dir '$repo/.gaia/local/cache'"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.project' "$repo/cost.jsonl")" = "path:$expected_hash" ]
}

@test "25.2: CACHE_DIRECTORY with no --cache-dir flag resolves through the shared resolver (FC-6 github breadcrumb)" {
  repo="$BATS_TEST_TMPDIR/cachedir-repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b feature/cache-dir-test
  git -C "$repo" commit --allow-empty -q -m init

  # Seed the FC-6 breadcrumb at the path the resolver derives:
  # <main_root>/.gaia/local/cache/gh-artifact-pr.<branch-slug>.json,
  # main_root == $repo here (an ordinary checkout, no worktree involved).
  # shellcheck source=/dev/null
  source "$SCRIPT_DIRECTORY/gh-artifact-lib.sh"
  breadcrumb_directory="$repo/.gaia/local/cache"
  mkdir -p "$breadcrumb_directory"
  gaia_gh_artifact_write "$(gaia_gh_artifact_path "$breadcrumb_directory" "feature/cache-dir-test")" \
    999 "acme/widgets" "feature/cache-dir-test" "$SESSION"

  # Deliberately no --cache-dir: token-tally.sh must derive it itself.
  run bash -c "cd '$repo' && bash '$SCRIPT' \
    --action execute --spec-id SPEC-013 --plan-slug s \
    --out-dir '$repo/out' --session-id '$SESSION' \
    --projects-root '$ANCHOR' --ledger '$repo/cost.jsonl'"
  [ "$status" -eq 0 ]

  [ "$(jq -r '.github.number' "$repo/cost.jsonl")" -eq 999 ]
  [ "$(jq -r '.github.repo' "$repo/cost.jsonl")" = "acme/widgets" ]
}
