#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/archived-backlog-migrate.sh (the one-time,
# human-gated, fail-closed removal of the archived spec/plan backlog).
#
# Each test runs the real script inside an isolated `git init`'d temp sandbox
# with an isolated --ledger and isolated id-ledgers, never the machine's real
# telemetry. The script sources its siblings (cost-represented.sh,
# ledger-path-lib.sh) from their real repo-relative location and operates on the
# sandbox passed as <repo_root>, so isolation is total (they are read-only pure
# helpers). This mirrors cost-backfill.bats, which runs the real script against a
# sandbox repo_root the same way.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` (a false one is silently skipped on macOS's
# system bash 3.2). This suite uses `[ ... ]` and `grep -qF` for everything but
# the test's last statement.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../archived-backlog-migrate.sh"
  [ -x "$SCRIPT" ] || skip "archived-backlog-migrate.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"

  SPECS_LEDGER="$SANDBOX/.gaia/local/specs/ledger.json"
  PLANS_LEDGER="$SANDBOX/.gaia/local/plans/ledger.json"
  mkdir -p "$(dirname "$SPECS_LEDGER")" "$(dirname "$PLANS_LEDGER")"
  printf '{"version":1,"specs":[]}\n' > "$SPECS_LEDGER"
  printf '{"version":1,"plans":[]}\n' > "$PLANS_LEDGER"
}

run_migrate() {
  bash "$SCRIPT" "$SANDBOX" --ledger "$LEDGER"
}

run_migrate_confirm() {
  bash "$SCRIPT" "$SANDBOX" --confirm --ledger "$LEDGER"
}

# seed_cost_md <rel_dir_under_sandbox>: writes stdin heredoc to <dir>/cost.md.
seed_cost_md() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir"
  cat > "$dir/cost.md"
}

# A single `## <heading>` section in token-tally render_tally_body's shape.
section() {
  local heading="$1" fresh="$2" cwrite="$3" cread="$4" output="$5" session="$6"
  local total=$((fresh + cwrite + cread + output))
  printf '## %s\n\n' "$heading"
  printf '| Bucket | Tokens |\n| --- | --- |\n'
  printf '| Fresh input | %s |\n' "$fresh"
  printf '| Cache write | %s |\n' "$cwrite"
  printf '| Cache read | %s |\n' "$cread"
  printf '| Output | %s |\n' "$output"
  printf '| **Total** | %s |\n\n' "$total"
  printf '**Elapsed (first to last model turn):** 1h0m0s (2026-07-05 10:00:00 JST to 2026-07-05 11:00:00 JST)\n\n'
  printf '**Est. cost (USD):** $1.23\n\n'
  if [ -n "$session" ]; then
    printf 'Session `%s` · generated 2026-07-05T10:00:00Z\n' "$session"
  fi
}

# add_row <kind> <attr_field> <attr_val> <session> <fresh> <cwrite> <cread> <output>
# Appends one cost.jsonl row mirroring the token-tally / backfill schema. An empty
# <session> yields session_id:null; total is the bucket sum.
add_row() {
  local kind="$1" field="$2" val="$3" sid="$4"
  local fresh="$5" cwrite="$6" cread="$7" output="$8"
  jq -cn \
    --arg kind "$kind" --arg field "$field" --arg val "$val" --arg sid "$sid" \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {
      schema_version: 1,
      kind: $kind,
      spec_id: null, plan_id: null, plan_slug: null,
      session_id: (if $sid == "" then null else $sid end),
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output),
      seq: 0, final: true, source: "test"
    } | .[$field] = $val
  ' >> "$LEDGER"
}

# add_spec_ledger_row <id> <status>: appends a specs/ledger.json identity row.
add_spec_ledger_row() {
  local id="$1" status="$2" tmp
  tmp="$(mktemp "${BATS_TEST_TMPDIR}/specledger.XXXXXX")"
  jq --arg id "$id" --arg status "$status" \
    '.specs += [{"id": $id, "status": $status, "merged_at": "2026-07-05T00:00:00Z"}]' \
    "$SPECS_LEDGER" > "$tmp" && mv "$tmp" "$SPECS_LEDGER"
}

# add_plan_ledger_row <id> <status>: appends a plans/ledger.json identity row.
add_plan_ledger_row() {
  local id="$1" status="$2" tmp
  tmp="$(mktemp "${BATS_TEST_TMPDIR}/planledger.XXXXXX")"
  jq --arg id "$id" --arg status "$status" \
    '.plans += [{"id": $id, "status": $status, "completed_at": "2026-07-05T00:00:00Z"}]' \
    "$PLANS_LEDGER" > "$tmp" && mv "$tmp" "$PLANS_LEDGER"
}

# --- 1. UAT-009 default dry-run no-op ----------------------------------------

@test "UAT-009 default dry-run: deletes nothing, prints a manifest, cost.jsonl byte-identical" {
  add_plan_ledger_row PLAN-005 completed
  {
    printf '# Cost: PLAN-005\n\n'
    section Planning 10 20 30 40 sess-a
    section Execution 12 24 36 48 sess-a
  } | seed_cost_md .gaia/local/plans/archived/PLAN-005
  add_row plan plan_id PLAN-005 sess-a 10 20 30 40
  add_row execute plan_id PLAN-005 sess-a 12 24 36 48

  mkdir -p "$SANDBOX/.gaia/local/plans/archived/cache-consolidation"
  printf 'summary\n' > "$SANDBOX/.gaia/local/plans/archived/cache-consolidation/SUMMARY.md"

  local ledger_before
  ledger_before="$(cksum < "$LEDGER")"

  run run_migrate
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # PLAN-005 is eligible (DELETE) but the default run must not delete it.
  grep -qF -- "$(printf 'archived/PLAN-005\tDELETE')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/plans/archived/PLAN-005" ]
  [ -d "$SANDBOX/.gaia/local/plans/archived/cache-consolidation" ]

  local ledger_after
  ledger_after="$(cksum < "$LEDGER")"
  [ "$ledger_before" = "$ledger_after" ]
}

# --- 2. UAT-008 represented -> deleted under --confirm -----------------------

@test "UAT-008 represented PLAN folder: manifest DELETE, removed under --confirm, cost.jsonl untouched" {
  add_plan_ledger_row PLAN-006 completed
  {
    printf '# Cost: PLAN-006\n\n'
    section Planning 10 20 30 40 sess-b
    section Execution 12 24 36 48 sess-b
  } | seed_cost_md .gaia/local/plans/archived/PLAN-006
  add_row plan plan_id PLAN-006 sess-b 10 20 30 40
  add_row execute plan_id PLAN-006 sess-b 12 24 36 48

  local ledger_before
  ledger_before="$(cksum < "$LEDGER")"

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/PLAN-006\tDELETE')" <<<"$output"

  local ledger_after
  ledger_after="$(cksum < "$LEDGER")"
  [ "$ledger_before" = "$ledger_after" ]
  [ ! -d "$SANDBOX/.gaia/local/plans/archived/PLAN-006" ]
}

@test "merged SPEC folder with represented cost: DELETE, removed under --confirm" {
  add_spec_ledger_row SPEC-020 merged
  {
    printf '# Cost: SPEC-020\n\n'
    section SPEC 10 20 30 40 sess-h
  } | seed_cost_md .gaia/local/specs/archived/SPEC-020
  add_row spec spec_id SPEC-020 sess-h 10 20 30 40

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/SPEC-020\tDELETE')" <<<"$output"
  [ ! -d "$SANDBOX/.gaia/local/specs/archived/SPEC-020" ]
}

# --- 3. UAT-008 unrepresented / unparseable -> BLOCKED ----------------------

@test "UAT-008 value-mismatched phase: BLOCKED, survives --confirm" {
  add_plan_ledger_row PLAN-007 completed
  {
    printf '# Cost: PLAN-007\n\n'
    section Execution 999 1 1 1 sess-c
  } | seed_cost_md .gaia/local/plans/archived/PLAN-007
  add_row execute plan_id PLAN-007 sess-c 12 24 36 48

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/PLAN-007\tBLOCKED')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/plans/archived/PLAN-007" ]
}

@test "UAT-008 unparseable phase (non-numeric bucket): BLOCKED reason unparseable, survives --confirm" {
  add_plan_ledger_row PLAN-011 completed
  {
    printf '# Cost: PLAN-011\n\n'
    printf '## Execution\n\n'
    printf '| Bucket | Tokens |\n| --- | --- |\n'
    printf '| Fresh input | n/a |\n'
    printf '| Cache write | 200 |\n'
    printf '| Cache read | 300 |\n'
    printf '| Output | 400 |\n'
    printf '| **Total** | 900 |\n\n'
    printf 'Session `sess-x` · generated 2026-07-05T10:00:00Z\n'
  } | seed_cost_md .gaia/local/plans/archived/PLAN-011
  add_row execute plan_id PLAN-011 sess-x 100 200 300 400

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/PLAN-011\tBLOCKED\t0\t1\tunparseable')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/plans/archived/PLAN-011" ]
}

# --- 4. UAT-008 dry-run manifest columns -------------------------------------

@test "UAT-008 dry-run manifest: {folder, phases verified, phases blocking} per folder" {
  add_plan_ledger_row PLAN-008 completed
  {
    printf '# Cost: PLAN-008\n\n'
    section Planning 10 20 30 40 sess-d
    section Execution 12 24 36 48 sess-d
  } | seed_cost_md .gaia/local/plans/archived/PLAN-008
  add_row plan plan_id PLAN-008 sess-d 10 20 30 40
  add_row execute plan_id PLAN-008 sess-d 12 24 36 48

  run run_migrate
  [ "$status" -eq 0 ]
  # column header present
  grep -qF -- "$(printf 'folder\tstatus\tverified\tblocking\treason')" <<<"$output"
  # PLAN-008: 2 phases verified, 0 blocking, eligible for deletion
  grep -qF -- "$(printf 'archived/PLAN-008\tDELETE\t2\t0\t')" <<<"$output"
  # dry-run still deletes nothing
  [ -d "$SANDBOX/.gaia/local/plans/archived/PLAN-008" ]
}

# --- 5. UAT-010 legacy free-form slug fail-closed ----------------------------

@test "UAT-010 legacy free-form slugs are NEEDS-DECISION, never deleted even with --confirm" {
  mkdir -p "$SANDBOX/.gaia/local/plans/archived/cache-consolidation"
  printf 'summary\n' > "$SANDBOX/.gaia/local/plans/archived/cache-consolidation/SUMMARY.md"
  {
    printf '# Cost: slug\n\n'
    section Planning 10 20 30 40 sess-e
  } | seed_cost_md .gaia/local/plans/archived/spec-021-git-tag-allocation

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/cache-consolidation\tNEEDS-DECISION')" <<<"$output"
  grep -qF -- "$(printf 'archived/spec-021-git-tag-allocation\tNEEDS-DECISION')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/plans/archived/cache-consolidation" ]
  [ -d "$SANDBOX/.gaia/local/plans/archived/spec-021-git-tag-allocation" ]
}

# --- 6. Pre-ledger / non-terminal SPEC fail-closed ---------------------------

@test "pre-ledger SPEC folder (no specs-ledger row) is NEEDS-DECISION, not deleted with --confirm" {
  {
    printf '# Cost: SPEC-003\n\n'
    section SPEC 10 20 30 40 sess-f
  } | seed_cost_md .gaia/local/specs/archived/SPEC-003

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/SPEC-003\tNEEDS-DECISION')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/specs/archived/SPEC-003" ]
}

@test "SPEC folder with a non-merged ledger row is NEEDS-DECISION, not deleted with --confirm" {
  add_spec_ledger_row SPEC-004 in-progress
  {
    printf '# Cost: SPEC-004\n\n'
    section SPEC 10 20 30 40 sess-i
  } | seed_cost_md .gaia/local/specs/archived/SPEC-004
  add_row spec spec_id SPEC-004 sess-i 10 20 30 40

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/SPEC-004\tNEEDS-DECISION')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/specs/archived/SPEC-004" ]
}

# --- 7. Needs-backfill -> BLOCKED (verify-only, DP-002/COV-001) --------------

@test "needs-backfill: a phase with no ledger row is BLOCKED (needs-backfill); cost.jsonl byte-identical in BOTH modes" {
  add_plan_ledger_row PLAN-009 completed
  {
    printf '# Cost: PLAN-009\n\n'
    section Planning 10 20 30 40 sess-g
  } | seed_cost_md .gaia/local/plans/archived/PLAN-009
  # No cost.jsonl row seeded for this phase: the vintage cost.md is unrepresented.

  local before
  before="$(cksum < "$LEDGER")"

  run run_migrate
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/PLAN-009\tBLOCKED')" <<<"$output"
  grep -qF -- "needs-backfill" <<<"$output"
  local after_dry
  after_dry="$(cksum < "$LEDGER")"
  [ "$before" = "$after_dry" ]

  run run_migrate_confirm
  [ "$status" -eq 0 ]
  grep -qF -- "$(printf 'archived/PLAN-009\tBLOCKED')" <<<"$output"
  [ -d "$SANDBOX/.gaia/local/plans/archived/PLAN-009" ]
  local after_confirm
  after_confirm="$(cksum < "$LEDGER")"
  [ "$before" = "$after_confirm" ]
}

# --- 8. Always exits 0, even with an empty backlog ---------------------------

@test "empty backlog: exits 0 and prints a zero summary" {
  run run_migrate
  [ "$status" -eq 0 ]
  grep -qF -- "delete=0 blocked=0 needs-decision=0" <<<"$output"
}
