#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/cost-backfill.sh (the one-off archived
# cost.md -> cost.jsonl backfill).
#
# Each test runs the script inside an isolated `git init`'d temp sandbox with
# an isolated --ledger, never the machine's real ledger. Fixture cost.md
# bodies are hand-authored, mirroring the real archived shapes this repo's
# own history produces (a rich section with dollars + duration, a section
# with no Est. cost line, a section with the italic "unavailable" marker, a
# `## Total` grand-sum that must never be emitted).
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` (a false one is silently skipped on
# macOS's system bash 3.2). This suite uses `jq -e` (own exit code) and `[
# ... ]`/grep for everything but the test's last statement.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../cost-backfill.sh"
  ROLLUP="$THIS_DIR/../token-rollup.sh"
  [ -x "$SCRIPT" ] || skip "cost-backfill.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"
}

run_backfill() {
  bash "$SCRIPT" "$SANDBOX" --ledger "$LEDGER"
}

# seed_cost_md <rel_dir_under_sandbox> <heredoc content via stdin>
seed_cost_md() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir"
  cat > "$dir/cost.md"
}

ledger_row_count() {
  wc -l < "$LEDGER" | tr -d ' '
}

# row_field <jq-select-filter> <field>: prints the field from the single
# ledger row matching the select filter (fails loudly if not exactly one).
row_field() {
  local select_filter="$1" field="$2"
  jq -n -e -r "
    [inputs | select($select_filter)] as \$rows
    | if (\$rows | length) != 1 then error(\"expected 1 row, got \" + (\$rows|length|tostring)) else \$rows[0].$field end
  " "$LEDGER"
}

# --- 1. Phase-to-row mapping on a rich section -------------------------------

@test "rich SPEC section: dollars, duration, session_id, ts, no by_model, source backfill" {
  seed_cost_md ".gaia/local/specs/archived/SPEC-023" <<'EOF'
# Cost: SPEC-023

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 32513 |
| Cache write | 1874816 |
| Cache read | 29720686 |
| Output | 461952 |
| **Total** | 32089967 |

**Elapsed (first to last model turn):** 3h5m45s (2026-07-04 19:29:15 JST to 2026-07-04 22:35:00 JST)

**Est. cost (USD):** $24.86

Session `f8e50835-df02-44cc-989d-e8a9b71c6c28` · generated 2026-07-04T13:35:18Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(ledger_row_count)" -eq 1 ]

  [ "$(row_field 'true' 'kind')" = "spec" ]
  [ "$(row_field 'true' 'spec_id')" = "SPEC-023" ]
  [ "$(row_field 'true' 'plan_id')" = "null" ]
  [ "$(row_field 'true' 'session_id')" = "f8e50835-df02-44cc-989d-e8a9b71c6c28" ]
  [ "$(row_field 'true' 'ts')" = "2026-07-04T13:35:18Z" ]
  [ "$(row_field 'true' 'duration_seconds')" -eq 11145 ]
  [ "$(row_field 'true' 'dollars')" = "24.86" ]
  [ "$(row_field 'true' 'source')" = "backfill" ]
  [ "$(row_field 'true' 'started_at')" = "null" ]
  [ "$(row_field 'true' 'ended_at')" = "null" ]
  [ "$(row_field 'true' 'buckets.fresh_input')" -eq 32513 ]
  [ "$(row_field 'true' 'buckets.cache_write')" -eq 1874816 ]
  [ "$(row_field 'true' 'buckets.cache_read')" -eq 29720686 ]
  [ "$(row_field 'true' 'buckets.output')" -eq 461952 ]
  [ "$(row_field 'true' 'total')" -eq 32089967 ]
  has_by_model="$(jq 'has("by_model")' "$LEDGER")"
  [ "$has_by_model" = "false" ]
}

# --- 2. `## Total` is never emitted ------------------------------------------

@test "## Total is never emitted: SPEC + Total fixture yields exactly one row" {
  seed_cost_md ".gaia/local/specs/archived/SPEC-018" <<'EOF'
# Cost: SPEC-018

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 2 |
| Cache read | 3 |
| Output | 4 |
| **Total** | 10 |

**Elapsed (first to last model turn):** 51m51s (2026-07-03 19:55:07 JST to 2026-07-03 20:46:58 JST)

Session `1c57e1df-de25-49cc-9991-9d839e1335f5` · generated 2026-07-03T11:47:05Z

## Total

_Est. cost (USD): unavailable (no section carries a priced figure)._

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 2 |
| Cache read | 3 |
| Output | 4 |
| **Total** | 10 |
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(ledger_row_count)" -eq 1 ]
  no_total_kind="$(jq -n -e '[inputs | select(.kind == "total")] | length' "$LEDGER")"
  [ "$no_total_kind" -eq 0 ]
}

# --- 3. Duration reverse-parse ------------------------------------------------

@test "duration reverse-parse: 34m50s -> 2090 and 45s -> 45" {
  seed_cost_md ".gaia/local/specs/archived/SPEC-022" <<'EOF'
# Cost: SPEC-022

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 1 |
| **Total** | 4 |

**Elapsed (first to last model turn):** 34m50s (2026-07-04 10:50:45 JST to 2026-07-04 11:25:35 JST)

Session `4ef4acc6-6bd1-4fef-978b-a28e0ff5f5b4` · generated 2026-07-04T02:25:39Z

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 1 |
| **Total** | 4 |

**Elapsed (first to last model turn):** 45s (2026-07-04 11:27:55 JST to 2026-07-04 11:28:40 JST)

Session `a49273c1-0eaa-49b8-b9e4-904509d72ab2` · generated 2026-07-04T03:03:04Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(ledger_row_count)" -eq 2 ]
  [ "$(row_field '.kind == "spec"' 'duration_seconds')" -eq 2090 ]
  [ "$(row_field '.kind == "plan"' 'duration_seconds')" -eq 45 ]
}

# --- 4. Missing / italic Est. cost line -> dollars: null ----------------------

@test "missing Est. cost line -> dollars null" {
  seed_cost_md ".gaia/local/specs/archived/SPEC-019" <<'EOF'
# Cost: SPEC-019

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 1 |
| **Total** | 4 |

**Elapsed (first to last model turn):** 43m26s (2026-07-03 22:39:32 JST to 2026-07-03 23:22:58 JST)

Session `57012258-1d06-4711-b483-dc7b4d45fdf5` · generated 2026-07-03T14:23:10Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(row_field 'true' 'dollars')" = "null" ]
}

@test "italic unavailable Est. cost marker -> dollars null (not a real figure)" {
  seed_cost_md ".gaia/local/specs/archived/SPEC-017" <<'EOF'
# Cost: SPEC-017

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 1 |
| Cache write | 1 |
| Cache read | 1 |
| Output | 1 |
| **Total** | 4 |

**Elapsed (first to last model turn):** 51m51s (2026-07-03 19:55:07 JST to 2026-07-03 20:46:58 JST)

_Est. cost (USD): unavailable (no section carries a priced figure)._

Session `1c57e1df-de25-49cc-9991-9d839e1335f5` · generated 2026-07-03T11:47:05Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(row_field 'true' 'dollars')" = "null" ]
}

# --- 5. Slug folder attribution -----------------------------------------------

@test "slug folder: plan_slug set, spec_id and plan_id null" {
  seed_cost_md ".gaia/local/plans/archived/cache-consolidation" <<'EOF'
# Cost: cache-consolidation / cache-consolidation

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 77523 |
| Cache write | 578313 |
| Cache read | 10960588 |
| Output | 141096 |
| **Total** | 11757520 |

**Elapsed (first to last model turn):** 51m7s (2026-07-04 17:07:52 JST to 2026-07-04 17:58:59 JST)

**Est. cost (USD):** $13.58

Session `5c46a8d7-472c-4eba-b97b-26c8be8cc90c` · generated 2026-07-04T08:59:10Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(row_field 'true' 'plan_slug')" = "cache-consolidation" ]
  [ "$(row_field 'true' 'plan_id')" = "null" ]
  [ "$(row_field 'true' 'spec_id')" = "null" ]
}

# --- 6. SPEC folder attribution -----------------------------------------------

@test "SPEC folder: spec_id set, plan_id null" {
  seed_cost_md ".gaia/local/specs/archived/SPEC-018" <<'EOF'
# Cost: SPEC-018

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 185300 |
| Cache write | 892605 |
| Cache read | 10213662 |
| Output | 242818 |
| **Total** | 11534385 |

**Elapsed (first to last model turn):** 49m56s (2026-07-03 21:01:41 JST to 2026-07-03 21:51:37 JST)

Session `4942ad2c-3e56-41a2-87e5-78e52e1a132a` · generated 2026-07-03T12:51:52Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(row_field 'true' 'spec_id')" = "SPEC-018" ]
  [ "$(row_field 'true' 'plan_id')" = "null" ]
}

# --- 7. Idempotency (UAT-007) -------------------------------------------------

@test "idempotent: SPEC-023 Execution deduped against a native row, second run adds zero" {
  # Seed a native execute row already on the ledger for SPEC-023, matching
  # the fixture's ## Execution session_id.
  printf '%s\n' '{"schema_version":1,"kind":"execute","spec_id":"SPEC-023","plan_id":null,"plan_slug":null,"session_id":"3158fe6d-4480-42d3-8e70-1c4ecbfc2057","buckets":{"fresh_input":1,"cache_write":1,"cache_read":1,"output":1},"total":4,"dollars":1.0,"started_at":null,"ended_at":null,"duration_seconds":1,"duration_available":true,"ts":"2026-07-04T17:07:59Z","source":"native","seq":0,"final":true}' >> "$LEDGER"

  seed_cost_md ".gaia/local/specs/archived/SPEC-023" <<'EOF'
# Cost: SPEC-023

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 32513 |
| Cache write | 1874816 |
| Cache read | 29720686 |
| Output | 461952 |
| **Total** | 32089967 |

**Elapsed (first to last model turn):** 3h5m45s (2026-07-04 19:29:15 JST to 2026-07-04 22:35:00 JST)

**Est. cost (USD):** $24.86

Session `f8e50835-df02-44cc-989d-e8a9b71c6c28` · generated 2026-07-04T13:35:18Z

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 73336 |
| Cache write | 2927591 |
| Cache read | 52877177 |
| Output | 303814 |
| **Total** | 56181918 |

**Elapsed (first to last model turn):** 1h6m7s (2026-07-05 01:01:52 JST to 2026-07-05 02:07:59 JST)

**Est. cost (USD):** $35.62

Session `3158fe6d-4480-42d3-8e70-1c4ecbfc2057` · generated 2026-07-04T17:07:59Z
EOF

  run run_backfill
  [ "$status" -eq 0 ]
  # native row + one new backfilled ## SPEC row; ## Execution deduped against native.
  count_after_run1="$(ledger_row_count)"
  [ "$count_after_run1" -eq 2 ]
  backfilled_kind="$(jq -n -e -r '[inputs | select(.source == "backfill")][0].kind' "$LEDGER")"
  [ "$backfilled_kind" = "spec" ]

  run run_backfill
  [ "$status" -eq 0 ]
  count_after_run2="$(ledger_row_count)"
  [ "$count_after_run2" -eq "$count_after_run1" ]
}

# --- 8. Planning -> plan, Execution -> execute mapping -----------------------

@test "## Planning maps to kind:plan and ## Execution maps to kind:execute" {
  seed_cost_md ".gaia/local/plans/archived/plan-nnn-numbering" <<'EOF'
# Cost: plan-nnn-numbering / plan-nnn-numbering

## Planning

| Bucket | Tokens |
| --- | --- |
| Fresh input | 132888 |
| Cache write | 796328 |
| Cache read | 5903192 |
| Output | 132213 |
| **Total** | 6964621 |

**Elapsed (first to last model turn):** 1h14m44s (2026-07-04 15:33:25 JST to 2026-07-04 16:48:09 JST)

**Est. cost (USD):** $12.90

Session `f5cbc987-69d4-4033-9f26-d50f4d04caee` · generated 2026-07-04T07:48:21Z

## Execution

| Bucket | Tokens |
| --- | --- |
| Fresh input | 40831 |
| Cache write | 530333 |
| Cache read | 8493465 |
| Output | 93201 |
| **Total** | 9157830 |

**Elapsed (first to last model turn):** 25m23s (2026-07-04 17:32:48 JST to 2026-07-04 17:58:11 JST)

**Est. cost (USD):** $8.48

Session `2888aca4-a5d5-4fdb-b487-7fbacb6e4d2e` · generated 2026-07-04T08:58:16Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]
  [ "$(ledger_row_count)" -eq 2 ]
  [ "$(row_field '.session_id == "f5cbc987-69d4-4033-9f26-d50f4d04caee"' 'kind')" = "plan" ]
  [ "$(row_field '.session_id == "2888aca4-a5d5-4fdb-b487-7fbacb6e4d2e"' 'kind')" = "execute" ]
}

# --- 9. Inertness to token-rollup.sh ------------------------------------------

@test "token-rollup.sh tolerates a backfilled row with no by_model" {
  [ -x "$ROLLUP" ] || skip "token-rollup.sh not executable"
  seed_cost_md ".gaia/local/specs/archived/SPEC-023" <<'EOF'
# Cost: SPEC-023

## SPEC

| Bucket | Tokens |
| --- | --- |
| Fresh input | 32513 |
| Cache write | 1874816 |
| Cache read | 29720686 |
| Output | 461952 |
| **Total** | 32089967 |

**Elapsed (first to last model turn):** 3h5m45s (2026-07-04 19:29:15 JST to 2026-07-04 22:35:00 JST)

**Est. cost (USD):** $24.86

Session `f8e50835-df02-44cc-989d-e8a9b71c6c28` · generated 2026-07-04T13:35:18Z
EOF
  run run_backfill
  [ "$status" -eq 0 ]

  run bash "$ROLLUP" --spec-id "SPEC-023" --ledger "$LEDGER"
  [ "$status" -eq 0 ]
}
