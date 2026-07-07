#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/ledger-status-migrate.sh (the one-time,
# idempotent, best-effort status-vocabulary migration for the specs and plans
# ledgers).
#
# Each test runs the real script against an isolated sandbox repo_root, never
# the machine's real .gaia/local ledgers. The script sources with-ledger-lock.sh
# from its real repo-relative location, a pure, read-only mutex-function
# definition with no side effects of its own, so isolation stays total while
# still exercising the real lock path. This mirrors archived-backlog-migrate.bats,
# which runs its script against a sandbox repo_root the same way.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# assertions avoid bare `[[ ... ]]` (a false one is silently skipped on macOS's
# system bash 3.2). This suite uses `[ ... ]` for everything but each test's
# last statement.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../ledger-status-migrate.sh"
  [ -x "$SCRIPT" ] || skip "ledger-status-migrate.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"

  SPECS_LEDGER="$SANDBOX/.gaia/local/specs/ledger.json"
  PLANS_LEDGER="$SANDBOX/.gaia/local/plans/ledger.json"
  mkdir -p "$(dirname "$SPECS_LEDGER")" "$(dirname "$PLANS_LEDGER")"
}

run_migrate() {
  bash "$SCRIPT" "$SANDBOX"
}

# write_specs_ledger / write_plans_ledger: write stdin JSON to the sandbox ledger.
write_specs_ledger() {
  cat > "$SPECS_LEDGER"
}

write_plans_ledger() {
  cat > "$PLANS_LEDGER"
}

# --- 1. specs: status map, unified values pass through unchanged ------------

@test "specs: specified -> ready, merged unchanged, draft unchanged" {
  write_specs_ledger <<'EOF'
{"version":1,"specs":[
  {"id":"SPEC-001","status":"specified"},
  {"id":"SPEC-002","status":"merged","merged_at":"2026-01-01T00:00:00Z"},
  {"id":"SPEC-003","status":"draft"}
]}
EOF

  run run_migrate
  [ "$status" -eq 0 ]

  [ "$(jq -r '.specs[] | select(.id=="SPEC-001") | .status' "$SPECS_LEDGER")" = "ready" ]
  [ "$(jq -r '.specs[] | select(.id=="SPEC-002") | .status' "$SPECS_LEDGER")" = "merged" ]
  [ "$(jq -r '.specs[] | select(.id=="SPEC-003") | .status' "$SPECS_LEDGER")" = "draft" ]
}

# --- 2. plans: completed/completed_at rename, source untouched --------------

@test "plans: completed + completed_at -> merged + merged_at, completed_at absent, source byte-unchanged" {
  write_plans_ledger <<'EOF'
{"version":1,"plans":[
  {"id":"PLAN-001","status":"completed","completed_at":"2026-01-01T00:00:00Z","source":"allocated"}
]}
EOF

  run run_migrate
  [ "$status" -eq 0 ]

  [ "$(jq -r '.plans[0].status' "$PLANS_LEDGER")" = "merged" ]
  [ "$(jq -r '.plans[0].merged_at' "$PLANS_LEDGER")" = "2026-01-01T00:00:00Z" ]
  [ "$(jq -r '.plans[0] | has("completed_at")' "$PLANS_LEDGER")" = "false" ]
  [ "$(jq -r '.plans[0].source' "$PLANS_LEDGER")" = "allocated" ]
}

# --- 3. plans: allocated -> ready, source value-blind-rewrite guard ---------

@test "plans: allocated -> ready, source: allocated preserved" {
  write_plans_ledger <<'EOF'
{"version":1,"plans":[
  {"id":"PLAN-002","status":"allocated","source":"allocated"}
]}
EOF

  run run_migrate
  [ "$status" -eq 0 ]

  [ "$(jq -r '.plans[0].status' "$PLANS_LEDGER")" = "ready" ]
  [ "$(jq -r '.plans[0].source' "$PLANS_LEDGER")" = "allocated" ]
}

# --- 4. no plan row keeps completed_at; every merged row has merged_at ------

@test "no plan row retains completed_at after migration; every merged row has merged_at" {
  write_plans_ledger <<'EOF'
{"version":1,"plans":[
  {"id":"PLAN-001","status":"completed","completed_at":"2026-01-01T00:00:00Z","source":"allocated"},
  {"id":"PLAN-002","status":"archived","completed_at":"2026-02-01T00:00:00Z","source":"allocated"},
  {"id":"PLAN-003","status":"merged","merged_at":"2026-03-01T00:00:00Z","source":"allocated"}
]}
EOF

  run run_migrate
  [ "$status" -eq 0 ]

  jq -e '[.plans[] | select(has("completed_at"))] | length == 0' "$PLANS_LEDGER"
  jq -e '[.plans[] | select(.status == "merged" and (.merged_at | length) > 0)] | length == 3' "$PLANS_LEDGER"
}

# --- 5. idempotent: second run is a byte-identical no-op --------------------

@test "idempotent: running twice leaves both ledgers byte-identical on the second run" {
  write_specs_ledger <<'EOF'
{"version":1,"specs":[
  {"id":"SPEC-001","status":"specified"},
  {"id":"SPEC-002","status":"in-progress"}
]}
EOF
  write_plans_ledger <<'EOF'
{"version":1,"plans":[
  {"id":"PLAN-001","status":"completed","completed_at":"2026-01-01T00:00:00Z","source":"allocated"},
  {"id":"PLAN-002","status":"archived","source":"allocated"}
]}
EOF

  run run_migrate
  [ "$status" -eq 0 ]

  local specs_snapshot plans_snapshot
  specs_snapshot="$(mktemp "${BATS_TEST_TMPDIR}/specs-snap.XXXXXX")"
  plans_snapshot="$(mktemp "${BATS_TEST_TMPDIR}/plans-snap.XXXXXX")"
  cp "$SPECS_LEDGER" "$specs_snapshot"
  cp "$PLANS_LEDGER" "$plans_snapshot"

  run run_migrate
  [ "$status" -eq 0 ]

  diff "$specs_snapshot" "$SPECS_LEDGER"
  diff "$plans_snapshot" "$PLANS_LEDGER"
}

# --- 6. missing ledgers: silent no-op, always exits 0 ------------------------

@test "no ledgers present: exits 0, prints nothing" {
  run run_migrate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
