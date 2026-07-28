#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/plan-reconcile.sh`, the plan-arm
# counterpart to `spec-reconcile.sh` (see spec-reconcile.bats for the spec
# arm). Orchestrator-driven: the caller already knows the merge is confirmed
# and the plan_id, so there is no gh/PR scan here, unlike the spec arm. Plan
# age anchors on `merged_at`, so this arm writes status "merged", not the
# retired "completed".
#
# Does NOT use helpers/tmp-spec-repo.sh: that shared harness seeds only the
# specs ledger and does not copy plan-ledger-update.sh. Mirrors the self-copy
# sandbox pattern from plan-ledger-update.bats instead: copy the script under
# test plus its runtime deps (plan-ledger-update.sh, with-ledger-lock.sh,
# ledger-path-lib.sh, main-root-lib.sh) into a sibling lib dir so the
# ${BASH_SOURCE[0]}-relative source resolves, `git init` the sandbox so
# plan-ledger-update.sh's main-checkout resolver (gaia_resolve_plans_dir) has
# a real repository to resolve against, and seed the plans ledger explicitly.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SRC_LIB="$REPO_ROOT/.specify/extensions/gaia/lib"
  SRC_SCRIPTS="$REPO_ROOT/.gaia/scripts"
  [ -x "$SRC_LIB/plan-reconcile.sh" ] || skip "plan-reconcile.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"

  git -C "$SANDBOX" init --quiet --initial-branch=main

  mkdir -p "$SANDBOX/.specify/extensions/gaia/lib"
  for s in plan-reconcile.sh plan-ledger-update.sh with-ledger-lock.sh; do
    cp "$SRC_LIB/$s" "$SANDBOX/.specify/extensions/gaia/lib/$s"
  done
  chmod +x "$SANDBOX/.specify/extensions/gaia/lib/plan-reconcile.sh" \
    "$SANDBOX/.specify/extensions/gaia/lib/plan-ledger-update.sh"

  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$SRC_SCRIPTS/ledger-path-lib.sh" "$SANDBOX/.gaia/scripts/ledger-path-lib.sh"
  cp "$SRC_SCRIPTS/main-root-lib.sh" "$SANDBOX/.gaia/scripts/main-root-lib.sh"

  mkdir -p "$SANDBOX/.gaia/local/plans"
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-005",
      "allocated_at": "2026-01-01T00:00:00Z",
      "source": "allocated",
      "subject": "x",
      "status": "ready"
    }
  ]
}
EOF
}

teardown() {
  if [ -n "${SANDBOX:-}" ]; then
    rm -rf "$SANDBOX"
  fi
}

LEDGER_REL=".gaia/local/plans/ledger.json"

_reconcile() {
  bash "$SANDBOX/.specify/extensions/gaia/lib/plan-reconcile.sh" "$SANDBOX" "$@"
}

_row_field() {
  local id="$1" field="$2"
  jq -r --arg id "$id" --arg f "$field" \
    '.plans[] | select(.id == $id) | .[$f] // "null"' \
    "$SANDBOX/$LEDGER_REL"
}

@test "1: ready PLAN-005 flips to merged with an ISO merged_at, exit 0" {
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  grep -qF "reconciled PLAN-005 -> merged" <<<"$output"
  [ "$(_row_field PLAN-005 status)" = "merged" ]
  case "$(_row_field PLAN-005 merged_at)" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
}

@test "1b: the flip does not depend on any plan folder existing" {
  # No PLAN-005 folder anywhere under the sandbox; the flip must still land.
  [ ! -d "$SANDBOX/.gaia/local/plans/PLAN-005" ]
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-005 status)" = "merged" ]
}

@test "2: idempotent; a second run re-stamps merged and exits 0" {
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  [ "$(_row_field PLAN-005 status)" = "merged" ]
}

@test "3: a non-PLAN-NNN id is a no-op, exits 0, leaves the ledger unchanged" {
  before="$(cat "$SANDBOX/$LEDGER_REL")"
  for id in cache-thing PLAN-x; do
    run _reconcile "$id"
    [ "$status" -eq 0 ]
  done
  after="$(cat "$SANDBOX/$LEDGER_REL")"
  [ "$before" = "$after" ]
}

@test "4a: a missing ledger exits 0 and creates nothing" {
  rm -f "$SANDBOX/$LEDGER_REL"
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/$LEDGER_REL" ]
}

@test "4b: a missing row exits 0 and leaves the ledger unchanged" {
  before="$(cat "$SANDBOX/$LEDGER_REL")"
  run _reconcile PLAN-999
  [ "$status" -eq 0 ]
  after="$(cat "$SANDBOX/$LEDGER_REL")"
  [ "$before" = "$after" ]
}

@test "5: the plans status vocabulary guard holds; plan-reconcile never writes the retired 'completed' status" {
  run _reconcile PLAN-005
  [ "$status" -eq 0 ]
  grep -qF -- "-> completed" <<<"$output" && return 1
  [ "$(_row_field PLAN-005 status)" = "merged" ]
}
