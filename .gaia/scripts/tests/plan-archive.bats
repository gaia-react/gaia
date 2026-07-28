#!/usr/bin/env bats
# Tests for `.gaia/scripts/plan-archive.sh`.
#
# Each test runs the script inside an isolated `git init`'d temp sandbox so
# its `git rev-parse --show-toplevel` resolves to the fixture root (not the
# GAIA repo root) and every reduce/delete touches only throwaway fixtures. The
# sandbox's own git-common-dir similarly resolves the representation gate's
# cost ledger to the sandbox's own .gaia/local/telemetry/cost.jsonl, never the
# real repo's.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid a bare `[[ ... ]]` (a false one is silently skipped on
# macOS's system bash 3.2). This suite uses `[ ... ]` and `grep -qF` for
# everything but each test's last statement.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../plan-archive.sh"
  [ -x "$SCRIPT" ] || skip "plan-archive.sh not executable"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"

  # Canonicalize via `pwd -P`: macOS resolves /tmp -> /private/tmp inside
  # `git rev-parse`, and the script derives its repo root the same way.
  # Absolute-path test arguments must match that resolved form byte-for-byte.
  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  # The PLAN-NNN merge stamp shells out to plan-ledger-update.sh, which
  # sources with-ledger-lock.sh from its own dir; both are copied here so a
  # PLAN-<digits> slug's stamp resolves instead of silently failing. The
  # representation gate sources cost-represented.sh + ledger-path-lib.sh at
  # their fixed repo-relative path, mirrored here the same way so the gate
  # resolves against the sandbox's own cost ledger instead of no-op'ing.
  # ledger-path-lib.sh now sources its own sibling main-root-lib.sh by
  # on-disk location, so that sibling is copied alongside it too.
  mkdir -p "$SANDBOX/.specify/extensions/gaia/lib"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/plan-ledger-update.sh" \
    "$SANDBOX/.specify/extensions/gaia/lib/plan-ledger-update.sh"
  cp "$REPO_ROOT/.specify/extensions/gaia/lib/with-ledger-lock.sh" \
    "$SANDBOX/.specify/extensions/gaia/lib/with-ledger-lock.sh"
  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$REPO_ROOT/.gaia/scripts/cost-represented.sh" \
    "$SANDBOX/.gaia/scripts/cost-represented.sh"
  cp "$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh" \
    "$SANDBOX/.gaia/scripts/ledger-path-lib.sh"
  cp "$REPO_ROOT/.gaia/scripts/main-root-lib.sh" \
    "$SANDBOX/.gaia/scripts/main-root-lib.sh"

  LEDGER="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  mkdir -p "$(dirname "$LEDGER")"
  : > "$LEDGER"
}

# Run the script with cwd inside the sandbox. Args pass through.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# copy_summary_verify: mirrors plan-archive.sh's own .gaia/scripts/
# summary-verify.sh call target inside the sandbox, so the spec-colocated
# consolidation gate delegates to the real verify-gate instead of falling
# back to a plain non-empty check. Tests that don't call this exercise the
# fallback path (summary-verify.sh absent from the sandbox).
copy_summary_verify() {
  cp "$REPO_ROOT/.gaia/scripts/summary-verify.sh" "$SANDBOX/.gaia/scripts/summary-verify.sh"
}

# seed_plan <rel_dir>: creates a plan folder (relative to $SANDBOX) with the
# canonical fixture set: SUMMARY.md (the consolidated artifact), PROGRESS.md
# (the live run ledger), KICKOFF.md, RUNNING, .work/x. Callers that need the
# representation gate to pass add a cost.json record afterward with
# write_cost_json.
seed_plan() {
  local dir="$SANDBOX/$1"
  mkdir -p "$dir/.work"
  echo "summary" > "$dir/SUMMARY.md"
  echo "progress" > "$dir/PROGRESS.md"
  echo "kickoff" > "$dir/KICKOFF.md"
  : > "$dir/RUNNING"
  echo "scratch" > "$dir/.work/x"
}

# write_cost_json <abs_dir> <fresh> <cwrite> <cread> <output>: writes a
# cost.json sidecar with one execute-phase record, the shape
# cost-represented.sh's sidecar parser expects. Every plan folder in this
# suite archives post-execution, so the kind is always "execute".
write_cost_json() {
  local dir="$1" fresh="$2" cwrite="$3" cread="$4" output="$5"
  jq -cn \
    --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
    --argjson cread "$cread" --argjson output "$output" '
    {execute: {
      kind: "execute",
      session_id: null,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output)
    }}
  ' > "$dir/cost.json"
}

# seed_cost_row <kind> <field> <val> <session> <fresh> <cwrite> <cread> <output>
# Appends one row (token-tally/backfill schema) directly to the sandbox's
# real cost ledger. plan-archive.sh resolves that path itself via
# gaia_resolve_ledger_path (never a --ledger override), so this writes
# straight to $LEDGER rather than threading a path through the script.
seed_cost_row() {
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

# assert_deleted <abs_dir>: the dir (and everything under it) is gone.
assert_deleted() {
  [ ! -e "$1" ]
}

# seed_plans_ledger <plan-row-json>: writes a one-row plans ledger at the
# sandbox's canonical .gaia/local/plans/ledger.json path.
seed_plans_ledger() {
  local row_json="$1"
  mkdir -p "$SANDBOX/.gaia/local/plans"
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<EOF
{
  "version": 1,
  "plans": [
    $row_json
  ]
}
EOF
}

# plan_row_field <plan_id> <field>: reads a field off <plan_id>'s row in the
# sandbox's plans ledger ("null" if absent).
plan_row_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg f "$field" \
    '.plans[] | select(.id == $id) | .[$f] // "null"' \
    "$SANDBOX/.gaia/local/plans/ledger.json"
}

# --- 1. Spec-less PLAN-NNN reduce, ledger stamped merged --------------------

@test "spec-less PLAN-NNN: represented cost -> reduced to SUMMARY.md + cost.json, RUNNING/PROGRESS.md gone, ledger stamped merged" {
  seed_plan ".gaia/local/plans/PLAN-005"
  write_cost_json "$SANDBOX/.gaia/local/plans/PLAN-005" 10 1 1 2
  seed_cost_row execute plan_id PLAN-005 "" 10 1 1 2
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-005"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-005" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-005/SUMMARY.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-005/cost.json" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-005/RUNNING" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-005/PROGRESS.md" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-005/KICKOFF.md" ]
  [ "$(plan_row_field PLAN-005 status)" = "merged" ]
  [ -n "$(plan_row_field PLAN-005 merged_at)" ]
  grep -qF "Reduced plan folder to SUMMARY.md + cost.json" <<<"$output"
}

# --- 2. Colocated plan delete, parent untouched (UAT-005) -------------------

@test "colocated plan: parent SPEC SUMMARY.md present + represented cost -> plan/ deleted, parent SPEC folder and SPEC.md untouched" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  echo "spec body" > "$SANDBOX/.gaia/local/specs/SPEC-005/SPEC.md"
  echo "# SPEC-005" > "$SANDBOX/.gaia/local/specs/SPEC-005/SUMMARY.md"
  write_cost_json "$SANDBOX/.gaia/local/specs/SPEC-005/plan" 5 0 0 1
  seed_cost_row execute spec_id SPEC-005 "" 5 0 0 1
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-005/plan"
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-005" ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-005/SPEC.md" ]
  grep -qF "Deleted plan folder: .gaia/local/specs/SPEC-005/plan" <<<"$output"
}

# --- 3. Colocated plan-2 revision, same delete semantics --------------------

@test "colocated plan-2 revision: parent SPEC SUMMARY.md present + represented cost -> deleted, parent untouched" {
  seed_plan ".gaia/local/specs/SPEC-005/plan-2"
  echo "# SPEC-005" > "$SANDBOX/.gaia/local/specs/SPEC-005/SUMMARY.md"
  write_cost_json "$SANDBOX/.gaia/local/specs/SPEC-005/plan-2" 3 0 0 1
  seed_cost_row execute spec_id SPEC-005 "" 3 0 0 1
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan-2"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-005/plan-2"
  grep -qF "Deleted plan folder: .gaia/local/specs/SPEC-005/plan-2" <<<"$output"
}

# --- 3b. DEF-07 fail-closed consolidation gate: no parent SUMMARY.md -> kept

@test "colocated plan: parent SPEC has no consolidated SUMMARY.md yet -> plan/ kept (fail-closed consolidation gate)" {
  seed_plan ".gaia/local/specs/SPEC-020/plan"
  echo "spec body" > "$SANDBOX/.gaia/local/specs/SPEC-020/SPEC.md"
  write_cost_json "$SANDBOX/.gaia/local/specs/SPEC-020/plan" 5 0 0 1
  seed_cost_row execute spec_id SPEC-020 "" 5 0 0 1
  run run_in_sandbox ".gaia/local/specs/SPEC-020/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-020/plan" ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-020/plan/PROGRESS.md" ]
  grep -qF "Retained plan" <<<"$output"
}

# --- 3c. Real summary-verify.sh delegation: well-formed SUMMARY.md -> deleted

@test "colocated plan: real summary-verify.sh present + well-formed parent SUMMARY.md -> plan/ deleted" {
  copy_summary_verify
  seed_plan ".gaia/local/specs/SPEC-021/plan"
  echo "spec body" > "$SANDBOX/.gaia/local/specs/SPEC-021/SPEC.md"
  cat > "$SANDBOX/.gaia/local/specs/SPEC-021/SUMMARY.md" <<'EOF'
---
wiki_promote_default: ask
wiki_promote_targets: [decisions]
---
# SPEC-021

Consolidated body.
EOF
  write_cost_json "$SANDBOX/.gaia/local/specs/SPEC-021/plan" 2 0 0 1
  seed_cost_row execute spec_id SPEC-021 "" 2 0 0 1
  run run_in_sandbox ".gaia/local/specs/SPEC-021/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-021/plan"
  grep -qF "Deleted plan folder: .gaia/local/specs/SPEC-021/plan" <<<"$output"
}

# --- 3d. Real summary-verify.sh delegation: malformed SUMMARY.md -> kept ----

@test "colocated plan: real summary-verify.sh present + malformed parent SUMMARY.md -> plan/ kept" {
  copy_summary_verify
  seed_plan ".gaia/local/specs/SPEC-022/plan"
  echo "spec body" > "$SANDBOX/.gaia/local/specs/SPEC-022/SPEC.md"
  echo "not well-formed" > "$SANDBOX/.gaia/local/specs/SPEC-022/SUMMARY.md"
  write_cost_json "$SANDBOX/.gaia/local/specs/SPEC-022/plan" 2 0 0 1
  seed_cost_row execute spec_id SPEC-022 "" 2 0 0 1
  run run_in_sandbox ".gaia/local/specs/SPEC-022/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-022/plan" ]
  grep -qF "Retained plan" <<<"$output"
}

# --- 4. No cost.md at all: nothing to lose, deletes outright ----------------

@test "plan with no cost.md: gate has nothing to lose -> deleted outright" {
  mkdir -p "$SANDBOX/.gaia/local/plans/bare/.work"
  echo "kickoff" > "$SANDBOX/.gaia/local/plans/bare/KICKOFF.md"
  : > "$SANDBOX/.gaia/local/plans/bare/RUNNING"
  echo "scratch" > "$SANDBOX/.gaia/local/plans/bare/.work/x"
  run run_in_sandbox ".gaia/local/plans/bare"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/plans/bare"
  [ ! -e "$SANDBOX/.gaia/local/plans/archived" ]
}

# --- 5. Representation gate blocks: unrepresented cost.json -> retained -----

@test "representation gate blocks: unrepresented cost.json -> folder retained, not reduced" {
  seed_plan ".gaia/local/plans/PLAN-006"
  write_cost_json "$SANDBOX/.gaia/local/plans/PLAN-006" 10 1 1 2
  # No matching ledger row seeded: the section cannot be represented.
  seed_plans_ledger '{"id":"PLAN-006","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-006" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-006/cost.json" ]
  grep -qF "Retained plan" <<<"$output"
}

# --- 6. Ledger stamp still applies even when the gate blocks the reduce -----

@test "PLAN-NNN slug: ledger stamp still applies even when the representation gate blocks the reduce" {
  seed_plan ".gaia/local/plans/PLAN-007"
  write_cost_json "$SANDBOX/.gaia/local/plans/PLAN-007" 10 1 1 2
  seed_plans_ledger '{"id":"PLAN-007","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-007"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-007" ]
  [ "$(plan_row_field PLAN-007 status)" = "merged" ]
  [ -n "$(plan_row_field PLAN-007 merged_at)" ]
  grep -qF "Retained plan" <<<"$output"
}

# --- 7. Legacy free-form slug: no ledger-stamp attempt ----------------------

@test "legacy free-form slug: no ledger-stamp attempt, represented cost -> deleted" {
  seed_plan ".gaia/local/plans/cache-consolidation"
  write_cost_json "$SANDBOX/.gaia/local/plans/cache-consolidation" 4 0 0 0
  seed_cost_row execute plan_slug cache-consolidation "" 4 0 0 0
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/cache-consolidation"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/plans/cache-consolidation"
  # Unrelated PLAN-005 row is untouched, proving no stray stamp fired.
  [ "$(plan_row_field PLAN-005 status)" = "allocated" ]
}

# --- 8. Spec-colocated plan: deletion never stamps any plans-ledger row -----

@test "spec-colocated plan: deletion never stamps any plans-ledger row" {
  seed_plan ".gaia/local/specs/SPEC-006/plan"
  echo "# SPEC-006" > "$SANDBOX/.gaia/local/specs/SPEC-006/SUMMARY.md"
  write_cost_json "$SANDBOX/.gaia/local/specs/SPEC-006/plan" 2 0 0 0
  seed_cost_row execute spec_id SPEC-006 "" 2 0 0 0
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  ledger_before="$(cat "$SANDBOX/.gaia/local/plans/ledger.json")"
  run run_in_sandbox ".gaia/local/specs/SPEC-006/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-006/plan"
  [ "$(cat "$SANDBOX/.gaia/local/plans/ledger.json")" = "$ledger_before" ]
}

# --- 9. Best-effort: a missing ledger row for the stamp never blocks reduce -

@test "PLAN-NNN with no matching ledger row: stamp is a no-op but reduce still proceeds" {
  seed_plan ".gaia/local/plans/PLAN-999"
  write_cost_json "$SANDBOX/.gaia/local/plans/PLAN-999" 1 0 0 0
  seed_cost_row execute plan_id PLAN-999 "" 1 0 0 0
  seed_plans_ledger '{"id":"PLAN-001","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-999"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-999" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-999/SUMMARY.md" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-999/RUNNING" ]
}

# --- 9b. Spec-less PLAN-NNN with no SUMMARY.md yet: kept, not reduced ------

@test "spec-less PLAN-NNN with no SUMMARY.md yet: kept intact, not reduced (fail-closed consolidation gate)" {
  local dir="$SANDBOX/.gaia/local/plans/PLAN-010"
  mkdir -p "$dir/.work"
  echo "progress" > "$dir/PROGRESS.md"
  : > "$dir/RUNNING"
  write_cost_json "$dir" 3 0 0 0
  seed_cost_row execute plan_id PLAN-010 "" 3 0 0 0
  seed_plans_ledger '{"id":"PLAN-010","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-010"
  [ "$status" -eq 0 ]
  [ -f "$dir/PROGRESS.md" ]
  [ -f "$dir/RUNNING" ]
  grep -qF "Retained plan (no consolidated SUMMARY.md yet)" <<<"$output"
}

# --- 10. Refuse operating inside the archived/ tree -------------------------

@test "refuses .gaia/local/plans/archived/<slug> (nested-under-archived guard)" {
  seed_plan ".gaia/local/plans/archived/foo"
  run run_in_sandbox ".gaia/local/plans/archived/foo"
  [ "$status" -eq 0 ]
  # Untouched: every seeded entry still present, nothing pruned or deleted.
  [ -f "$SANDBOX/.gaia/local/plans/archived/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/archived/foo/RUNNING" ]
  [ -f "$SANDBOX/.gaia/local/plans/archived/foo/.work/x" ]
  grep -qF "refusing" <<<"$output"
}

# --- 11. Refuse out-of-shape relative path ----------------------------------

@test "refuses a relative path outside .gaia/local" {
  mkdir -p "$SANDBOX/some/other/dir"
  : > "$SANDBOX/some/other/dir/file"
  run run_in_sandbox "some/other/dir"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/some/other/dir/file" ]
  grep -qF "refusing" <<<"$output"
}

# --- 12. Non-existent input --------------------------------------------------

@test "non-existent plan_dir: exit 0, stderr note, no side effects" {
  run run_in_sandbox ".gaia/local/plans/ghost"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/archived" ]
  grep -qF "does not exist" <<<"$output"
}

# --- 13. Absolute-under-repo normalizes -------------------------------------

@test "absolute path under repo root normalizes to the same end-state" {
  seed_plan ".gaia/local/plans/foo"
  write_cost_json "$SANDBOX/.gaia/local/plans/foo" 2 0 0 1
  seed_cost_row execute plan_slug foo "" 2 0 0 1
  run run_in_sandbox "$SANDBOX/.gaia/local/plans/foo"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/plans/foo"
  grep -qF "Deleted plan folder: .gaia/local/plans/foo" <<<"$output"
}

# --- 14. Absolute-outside-repo refuses ----------------------------------------

@test "absolute path outside repo root refuses" {
  OUTSIDE_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/outside.XXXXXX")"
  OUTSIDE="$(cd "$OUTSIDE_RAW" && pwd -P)"
  mkdir -p "$OUTSIDE/plan"
  : > "$OUTSIDE/plan/SUMMARY.md"
  run run_in_sandbox "$OUTSIDE/plan"
  [ "$status" -eq 0 ]
  [ -f "$OUTSIDE/plan/SUMMARY.md" ]
  grep -qF "refusing" <<<"$output"
}

# --- 15. Refuse "." slug (would resolve to plans/ itself, mass-deleting siblings) --

@test "refuses .gaia/local/plans/. (mass-delete guard)" {
  seed_plan ".gaia/local/plans/foo"
  mkdir -p "$SANDBOX/.gaia/local/plans/bar"
  : > "$SANDBOX/.gaia/local/plans/bar/marker"
  run run_in_sandbox ".gaia/local/plans/."
  [ "$status" -eq 0 ]
  # Untouched: sibling plan folders inside plans/ survive.
  [ -f "$SANDBOX/.gaia/local/plans/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/foo/.work/x" ]
  [ -f "$SANDBOX/.gaia/local/plans/bar/marker" ]
  grep -qF "refusing" <<<"$output"
}

# --- 16. Refuse ".." slug (would resolve to .gaia/local, mass-deleting plans+specs) -

@test "refuses .gaia/local/plans/.. (mass-delete guard)" {
  seed_plan ".gaia/local/plans/foo"
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  run run_in_sandbox ".gaia/local/plans/.."
  [ "$status" -eq 0 ]
  # Untouched: sibling trees under .gaia/local survive.
  [ -f "$SANDBOX/.gaia/local/plans/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-005/plan/KICKOFF.md" ]
  grep -qF "refusing" <<<"$output"
}

# --- 17. Refuse doubled trailing slash (empty slug, same mass-delete guard) --------

@test "refuses .gaia/local/plans// (doubled trailing slash / empty slug)" {
  seed_plan ".gaia/local/plans/foo"
  mkdir -p "$SANDBOX/.gaia/local/plans/bar"
  : > "$SANDBOX/.gaia/local/plans/bar/marker"
  run run_in_sandbox ".gaia/local/plans//"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/plans/foo/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plans/bar/marker" ]
  grep -qF "refusing" <<<"$output"
}

# --- 18. Well-formed slug with a single trailing slash still deletes correctly -----

@test "trailing slash on a well-formed slug still deletes correctly" {
  seed_plan ".gaia/local/plans/foo"
  write_cost_json "$SANDBOX/.gaia/local/plans/foo" 2 0 0 1
  seed_cost_row execute plan_slug foo "" 2 0 0 1
  run run_in_sandbox ".gaia/local/plans/foo/"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/plans/foo"
  grep -qF "Deleted plan folder: .gaia/local/plans/foo" <<<"$output"
}

# --- 19. Refuse specs-arm path escape via ".." spec segment ------------------------

@test "refuses .gaia/local/specs/../plan (spec-part path escape)" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  mkdir -p "$SANDBOX/.gaia/local/plan"
  : > "$SANDBOX/.gaia/local/plan/escaped-marker"
  run run_in_sandbox ".gaia/local/specs/../plan"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-005/plan/KICKOFF.md" ]
  [ -f "$SANDBOX/.gaia/local/plan/escaped-marker" ]
  grep -qF "refusing" <<<"$output"
}
