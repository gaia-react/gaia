#!/usr/bin/env bats
# Tests for `.gaia/scripts/plan-archive.sh`.
#
# Each test runs the script inside an isolated `git init`'d temp sandbox so
# its `git rev-parse --show-toplevel` resolves to the fixture root (not the
# GAIA repo root) and every reduce/delete touches only throwaway fixtures. The
# sandbox's own git-common-dir similarly resolves the usage-ledger gate to the
# sandbox's own .gaia/local/telemetry/usage.jsonl, never the real repo's.
#
# The gate is `usage.sh represented`: a plan folder is reduced or deleted only
# when the usage ledger holds the close it needs, and is kept (with one stdout
# keep line naming the recovery command) when it does not.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../plan-archive.sh"
  [ -x "$SCRIPT" ] || skip "plan-archive.sh not executable"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  # copy_usage_gate + seed_close_row.
  . "$REPO_ROOT/.gaia/tests/lib/helpers/usage-gate.sh"

  # Canonicalize via `pwd -P`: macOS resolves /tmp -> /private/tmp inside
  # `git rev-parse`, and the script derives its repo root the same way.
  # Absolute-path test arguments must match that resolved form byte-for-byte.
  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"
  git -C "$SANDBOX" init --quiet

  install_scripts "$SANDBOX"

  TELEMETRY="$SANDBOX/.gaia/local/telemetry"
  mkdir -p "$TELEMETRY"
  : > "$TELEMETRY/usage.jsonl"
}

# install_scripts <root>: the PLAN-NNN merge stamp shells out to
# ledger-update.sh, which sources ledger-lib.sh and with-ledger-lock.sh from
# its own dir; all are copied so a PLAN-<digits> slug's stamp resolves instead
# of silently failing. The gate sources main-root-lib.sh at its fixed
# repo-relative path and runs usage.sh from there, mirrored the same way.
install_scripts() {
  local root="$1"
  mkdir -p "$root/.gaia/scripts/spec"
  cp "$REPO_ROOT/.gaia/scripts/spec/ledger-update.sh" \
    "$root/.gaia/scripts/spec/ledger-update.sh"
  cp "$REPO_ROOT/.gaia/scripts/spec/ledger-lib.sh" \
    "$root/.gaia/scripts/spec/ledger-lib.sh"
  cp "$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh" \
    "$root/.gaia/scripts/ledger-path-lib.sh"
  copy_usage_gate "$REPO_ROOT" "$root"
}

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

# seed_plan <relative_directory>: creates a plan folder (relative to $SANDBOX) with the
# canonical fixture set: SUMMARY.md (the consolidated artifact), PROGRESS.md
# (the live run ledger), KICKOFF.md, RUNNING, .work/x. Callers that need the
# gate to pass add a close row afterward with seed_close.
seed_plan() {
  local plan_directory="$SANDBOX/$1"
  mkdir -p "$plan_directory/.work"
  echo "summary" > "$plan_directory/SUMMARY.md"
  echo "progress" > "$plan_directory/PROGRESS.md"
  echo "kickoff" > "$plan_directory/KICKOFF.md"
  : > "$plan_directory/RUNNING"
  echo "scratch" > "$plan_directory/.work/x"
}

# seed_close <ref> <workflow>: appends the close binding row `usage.sh
# record` writes to the sandbox's usage ledger. plan-archive.sh resolves that
# ledger itself from the main checkout (never a flag passed to the script).
seed_close() {
  seed_close_row "$TELEMETRY" "$1" "$2"
}

# assert_deleted <absolute_directory>: the dir (and everything under it) is gone.
assert_deleted() {
  [ ! -e "$1" ]
}

# stub_usage_script: replaces the sandbox's usage.sh with one that logs every
# invocation to $SANDBOX/usage-calls.log and exits 1 (no run recorded).
stub_usage_script() {
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >> \"$SANDBOX/usage-calls.log\""
    echo 'exit 1'
  } > "$SANDBOX/.gaia/scripts/usage.sh"
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
  jq -r --arg id "$id" --arg field "$field" \
    '.plans[] | select(.id == $id) | .[$field] // "null"' \
    "$SANDBOX/.gaia/local/plans/ledger.json"
}

# --- 1. Spec-less PLAN-NNN reduce, ledger stamped merged --------------------

@test "spec-less PLAN-NNN: recorded run -> reduced to SUMMARY.md alone, RUNNING/PROGRESS.md gone, ledger stamped merged" {
  seed_plan ".gaia/local/plans/PLAN-005"
  seed_close plan:PLAN-005 gaia-plan
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-005"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-005" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-005/SUMMARY.md" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-005/RUNNING" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-005/PROGRESS.md" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-005/KICKOFF.md" ]
  [ "$(find "$SANDBOX/.gaia/local/plans/PLAN-005" -mindepth 1 | wc -l | tr -d ' ')" = "1" ]
  [ "$(plan_row_field PLAN-005 status)" = "merged" ]
  [ -n "$(plan_row_field PLAN-005 merged_at)" ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap)" <<<"$output"
}

@test "spec-less PLAN-NNN reduce removes a legacy sidecar left in the folder" {
  seed_plan ".gaia/local/plans/PLAN-008"
  # Built from parts: a folder written by an older release holds this file, and
  # the reduce must clear it with everything else.
  echo "{}" > "$SANDBOX/.gaia/local/plans/PLAN-008/cost"".json"
  seed_close plan:PLAN-008 gaia-plan
  run run_in_sandbox ".gaia/local/plans/PLAN-008"
  [ "$status" -eq 0 ]
  [ "$(find "$SANDBOX/.gaia/local/plans/PLAN-008" -mindepth 1 | wc -l | tr -d ' ')" = "1" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-008/SUMMARY.md" ]
}

# --- 2. Colocated plan delete, parent untouched -----------------------------

@test "colocated plan: parent SPEC SUMMARY.md present + gaia-plan close -> plan/ deleted, parent SPEC folder and SPEC.md untouched" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  echo "spec body" > "$SANDBOX/.gaia/local/specs/SPEC-005/SPEC.md"
  echo "# SPEC-005" > "$SANDBOX/.gaia/local/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-plan
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-005/plan"
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-005" ]
  [ -f "$SANDBOX/.gaia/local/specs/SPEC-005/SPEC.md" ]
  grep -qF "Deleted plan folder: .gaia/local/specs/SPEC-005/plan" <<<"$output"
  grep -qF "the usage ledger holds the run record" <<<"$output"
}

# --- 3. Colocated plan-2 revision, same delete semantics --------------------

@test "colocated plan-2 revision: parent SPEC SUMMARY.md present + gaia-plan close -> deleted, parent untouched" {
  seed_plan ".gaia/local/specs/SPEC-005/plan-2"
  echo "# SPEC-005" > "$SANDBOX/.gaia/local/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-plan
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan-2"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-005/plan-2"
  grep -qF "Deleted plan folder: .gaia/local/specs/SPEC-005/plan-2" <<<"$output"
}

@test "colocated plans: one gaia-plan close for the spec ref clears both plan and plan-2" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  seed_plan ".gaia/local/specs/SPEC-005/plan-2"
  echo "# SPEC-005" > "$SANDBOX/.gaia/local/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-plan
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-005/plan"
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan-2"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-005/plan-2"
}

# --- 3a. Wrong workflow does not clear the gate -----------------------------

@test "colocated plan: only a gaia-spec close for the spec ref -> kept with the gaia-plan keep line" {
  seed_plan ".gaia/local/specs/SPEC-005/plan"
  echo "# SPEC-005" > "$SANDBOX/.gaia/local/specs/SPEC-005/SUMMARY.md"
  seed_close spec:SPEC-005 gaia-spec
  run run_in_sandbox ".gaia/local/specs/SPEC-005/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-005/plan" ]
  [ "$output" = "Kept .gaia/local/specs/SPEC-005/plan: no gaia-plan run recorded for spec:SPEC-005; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record spec:SPEC-005 --workflow gaia-plan --start <iso>" ]
}

# --- 3b. Fail-closed consolidation gate: no parent SUMMARY.md -> kept --------

@test "colocated plan: parent SPEC has no consolidated SUMMARY.md yet -> plan/ kept (fail-closed consolidation gate)" {
  seed_plan ".gaia/local/specs/SPEC-020/plan"
  echo "spec body" > "$SANDBOX/.gaia/local/specs/SPEC-020/SPEC.md"
  seed_close spec:SPEC-020 gaia-plan
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
  seed_close spec:SPEC-021 gaia-plan
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
  seed_close spec:SPEC-022 gaia-plan
  run run_in_sandbox ".gaia/local/specs/SPEC-022/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-022/plan" ]
  grep -qF "Retained plan" <<<"$output"
}

# --- 4. Legacy slug: no usage ref, always kept, represented never called -----

@test "legacy free-form slug: kept with the no-usage-ref keep line, usage.sh represented never called" {
  mkdir -p "$SANDBOX/.gaia/local/plans/bare/.work"
  echo "kickoff" > "$SANDBOX/.gaia/local/plans/bare/KICKOFF.md"
  : > "$SANDBOX/.gaia/local/plans/bare/RUNNING"
  echo "scratch" > "$SANDBOX/.gaia/local/plans/bare/.work/x"
  stub_usage_script
  run run_in_sandbox ".gaia/local/plans/bare"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/bare" ]
  [ -f "$SANDBOX/.gaia/local/plans/bare/KICKOFF.md" ]
  [ ! -e "$SANDBOX/usage-calls.log" ]
  [ "$output" = "Kept .gaia/local/plans/bare: legacy plan folder with no usage ref; remove it by hand once its record is no longer needed" ]
}

# --- 5. Gate blocks: no close row -> kept with the recovery command ----------

@test "gate blocks: no close row for the plan -> folder kept, keep line names the ref and the recovery command" {
  seed_plan ".gaia/local/plans/PLAN-006"
  seed_plans_ledger '{"id":"PLAN-006","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-006" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-006/PROGRESS.md" ]
  [ "$output" = "Kept .gaia/local/plans/PLAN-006: no gaia-plan run recorded for plan:PLAN-006; outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-006 --workflow gaia-plan --start <iso>" ]
}

@test "gate blocks: a gaia-spec close for the plan ref does not clear it" {
  seed_plan ".gaia/local/plans/PLAN-006"
  seed_close plan:PLAN-006 gaia-spec
  run run_in_sandbox ".gaia/local/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-006/PROGRESS.md" ]
  grep -qF "no gaia-plan run recorded for plan:PLAN-006" <<<"$output"
}

@test "gate blocks: usage.jsonl missing -> folder kept, keep line names the ledger path" {
  seed_plan ".gaia/local/plans/PLAN-006"
  rm -f "$TELEMETRY/usage.jsonl"
  run run_in_sandbox ".gaia/local/plans/PLAN-006"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-006/PROGRESS.md" ]
  [ "$output" = "Kept .gaia/local/plans/PLAN-006: usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for plan:PLAN-006; once it reads, outside a live gaia-plan run, record it: bash .gaia/scripts/usage.sh record plan:PLAN-006 --workflow gaia-plan --start <iso>" ]
}

@test "gate blocks: colocated plan with usage.jsonl missing -> kept, keep line names the spec ref" {
  seed_plan ".gaia/local/specs/SPEC-007/plan"
  echo "# SPEC-007" > "$SANDBOX/.gaia/local/specs/SPEC-007/SUMMARY.md"
  rm -f "$TELEMETRY/usage.jsonl"
  run run_in_sandbox ".gaia/local/specs/SPEC-007/plan"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/specs/SPEC-007/plan" ]
  grep -qF "usage ledger missing or unreadable (.gaia/local/telemetry/usage.jsonl) for spec:SPEC-007" <<<"$output"
}

# --- 6. Ledger stamp still applies even when the gate blocks the reduce ------

@test "PLAN-NNN slug: ledger stamp still applies even when the usage-ledger gate blocks the reduce" {
  seed_plan ".gaia/local/plans/PLAN-007"
  seed_plans_ledger '{"id":"PLAN-007","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-007"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-007" ]
  [ "$(plan_row_field PLAN-007 status)" = "merged" ]
  [ -n "$(plan_row_field PLAN-007 merged_at)" ]
  grep -qF "Kept .gaia/local/plans/PLAN-007" <<<"$output"
}

# --- 7. Legacy free-form slug: no ledger-stamp attempt ----------------------

@test "legacy free-form slug: no ledger-stamp attempt, folder kept" {
  seed_plan ".gaia/local/plans/cache-consolidation"
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/cache-consolidation"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/cache-consolidation" ]
  # Unrelated PLAN-005 row is untouched, proving no stray stamp fired.
  [ "$(plan_row_field PLAN-005 status)" = "allocated" ]
}

# --- 8. Spec-colocated plan: deletion never stamps any plans-ledger row -----

@test "spec-colocated plan: deletion never stamps any plans-ledger row" {
  seed_plan ".gaia/local/specs/SPEC-006/plan"
  echo "# SPEC-006" > "$SANDBOX/.gaia/local/specs/SPEC-006/SUMMARY.md"
  seed_close spec:SPEC-006 gaia-plan
  seed_plans_ledger '{"id":"PLAN-005","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  ledger_before="$(snapshot_file "$SANDBOX/.gaia/local/plans/ledger.json")"
  run run_in_sandbox ".gaia/local/specs/SPEC-006/plan"
  [ "$status" -eq 0 ]
  assert_deleted "$SANDBOX/.gaia/local/specs/SPEC-006/plan"
  assert_files_identical "$SANDBOX/.gaia/local/plans/ledger.json" "$ledger_before"
}

# --- 9. Best-effort: a missing ledger row for the stamp never blocks reduce -

@test "PLAN-NNN with no matching ledger row: stamp is a no-op but reduce still proceeds" {
  seed_plan ".gaia/local/plans/PLAN-999"
  seed_close plan:PLAN-999 gaia-plan
  seed_plans_ledger '{"id":"PLAN-001","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-999"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/.gaia/local/plans/PLAN-999" ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-999/SUMMARY.md" ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-999/RUNNING" ]
}

# --- 9b. Spec-less PLAN-NNN with no SUMMARY.md yet: kept, not reduced ------

@test "spec-less PLAN-NNN with no SUMMARY.md yet: kept intact, not reduced (fail-closed consolidation gate)" {
  local plan_directory="$SANDBOX/.gaia/local/plans/PLAN-010"
  mkdir -p "$plan_directory/.work"
  echo "progress" > "$plan_directory/PROGRESS.md"
  : > "$plan_directory/RUNNING"
  seed_close plan:PLAN-010 gaia-plan
  seed_plans_ledger '{"id":"PLAN-010","allocated_at":"2026-01-01T00:00:00Z","source":"allocated","subject":"x","status":"allocated"}'
  run run_in_sandbox ".gaia/local/plans/PLAN-010"
  [ "$status" -eq 0 ]
  [ -f "$plan_directory/PROGRESS.md" ]
  [ -f "$plan_directory/RUNNING" ]
  grep -qF "Retained plan (no consolidated SUMMARY.md yet)" <<<"$output"
}

# --- 9c. The gate reads the main checkout's ledger, not the cwd tree's -------

@test "linked worktree: the ledger under the main checkout, reached through --main-root, clears the gate" {
  local main_checkout worktree_directory
  main_checkout="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/main.XXXXXX")" && pwd -P)"
  git -C "$main_checkout" init --quiet
  git -C "$main_checkout" -c user.email=test@example.com -c user.name=Test -c commit.gpgsign=false \
    commit --quiet --no-verify --allow-empty -m init
  worktree_directory="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/wt.XXXXXX")" && pwd -P)/linked"
  git -C "$main_checkout" worktree add --quiet -b linked-branch "$worktree_directory"
  SANDBOX="$worktree_directory"
  install_scripts "$SANDBOX"
  seed_plan ".gaia/local/plans/PLAN-040"
  # The only usage ledger lives under the main checkout, outside the cwd tree.
  seed_close_row "$main_checkout/.gaia/local/telemetry" plan:PLAN-040 gaia-plan
  [ ! -e "$SANDBOX/.gaia/local/telemetry/usage.jsonl" ]

  run run_in_sandbox ".gaia/local/plans/PLAN-040"
  [ "$status" -eq 0 ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .gaia/local/plans/PLAN-040" <<<"$output"
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-040/PROGRESS.md" ]

  # A plan the main checkout's ledger does not record is kept: the answer
  # comes from that ledger, not from a default.
  seed_plan ".gaia/local/plans/PLAN-041"
  run run_in_sandbox ".gaia/local/plans/PLAN-041"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/.gaia/local/plans/PLAN-041/PROGRESS.md" ]
  grep -qF "no gaia-plan run recorded for plan:PLAN-041" <<<"$output"
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
  seed_plan ".gaia/local/plans/PLAN-030"
  seed_close plan:PLAN-030 gaia-plan
  run run_in_sandbox "$SANDBOX/.gaia/local/plans/PLAN-030"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-030/PROGRESS.md" ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .gaia/local/plans/PLAN-030" <<<"$output"
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

# --- 18. Well-formed slug with a single trailing slash still resolves ------------

@test "trailing slash on a well-formed slug still resolves correctly" {
  seed_plan ".gaia/local/plans/PLAN-031"
  seed_close plan:PLAN-031 gaia-plan
  run run_in_sandbox ".gaia/local/plans/PLAN-031/"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/.gaia/local/plans/PLAN-031/PROGRESS.md" ]
  grep -qF "Reduced plan folder to SUMMARY.md (kept for age-reap): .gaia/local/plans/PLAN-031" <<<"$output"
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
