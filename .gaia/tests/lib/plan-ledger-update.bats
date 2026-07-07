#!/usr/bin/env bats
# Tests for `.specify/extensions/gaia/lib/plan-ledger-update.sh`, the plans-side
# mirror of `ledger-update.sh` (U3, plan-ledger-chokepoint). Single guarded
# mutation chokepoint for `.gaia/local/plans/ledger.json` rows after the
# initial `plan-allocator.sh` allocation.
#
# Does NOT use helpers/tmp-spec-repo.sh: that shared harness copies a fixed
# lib list that excludes plan-ledger-update.sh and seeds only the specs
# ledger. Instead, mirrors the self-copy sandbox pattern from
# `.gaia/scripts/tests/plan-archive.bats`: copy the script under test plus its
# runtime dep (with-ledger-lock.sh) into a sibling lib dir so the
# ${BASH_SOURCE[0]}-relative source resolves, and seed the plans ledger
# explicitly.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SRC_LIB="$REPO_ROOT/.specify/extensions/gaia/lib"
  [ -x "$SRC_LIB/plan-ledger-update.sh" ] || skip "plan-ledger-update.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"

  mkdir -p "$SANDBOX/.specify/extensions/gaia/lib"
  cp "$SRC_LIB/plan-ledger-update.sh" "$SANDBOX/.specify/extensions/gaia/lib/plan-ledger-update.sh"
  cp "$SRC_LIB/with-ledger-lock.sh" "$SANDBOX/.specify/extensions/gaia/lib/with-ledger-lock.sh"

  mkdir -p "$SANDBOX/.gaia/local/plans"
  cat > "$SANDBOX/.gaia/local/plans/ledger.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {
      "id": "PLAN-001",
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

_update() {
  bash "$SANDBOX/.specify/extensions/gaia/lib/plan-ledger-update.sh" "$SANDBOX" "$@"
}

_row_field() {
  local field="$1"
  jq -r --arg id "PLAN-001" --arg f "$field" \
    '.plans[] | select(.id == $id) | .[$f] // "null"' \
    "$SANDBOX/$LEDGER_REL"
}

@test "1: merged patch exits 0, sets status+merged_at, preserves other fields" {
  run _update PLAN-001 '{"status":"merged","merged_at":"2026-07-05T00:00:00Z"}'
  [ "$status" -eq 0 ]
  [ "$(_row_field status)" = "merged" ]
  [ "$(_row_field merged_at)" = "2026-07-05T00:00:00Z" ]
  [ "$(_row_field id)" = "PLAN-001" ]
  [ "$(_row_field allocated_at)" = "2026-01-01T00:00:00Z" ]
  [ "$(_row_field source)" = "allocated" ]
  [ "$(_row_field subject)" = "x" ]
}

@test "2: non-canonical status exits 6 and leaves status unchanged" {
  run _update PLAN-001 '{"status":"bogus"}'
  [ "$status" -eq 6 ]
  grep -qF "non-canonical status 'bogus'" <<<"$output"
  [ "$(_row_field status)" = "ready" ]
}

@test "3: status-less patch updates only the targeted field, status untouched" {
  run _update PLAN-001 '{"subject":"new subject"}'
  [ "$status" -eq 0 ]
  [ "$(_row_field subject)" = "new subject" ]
  [ "$(_row_field status)" = "ready" ]
}

@test "4: patch for a non-existent row exits 4 and mutates nothing" {
  before="$(cat "$SANDBOX/$LEDGER_REL")"
  run _update PLAN-999 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  [ "$(cat "$SANDBOX/$LEDGER_REL")" = "$before" ]
}

@test "5: malformed patch JSON exits 5" {
  run _update PLAN-001 'not json'
  [ "$status" -eq 5 ]
}

@test "6: ready, merged, and abandoned are all accepted" {
  for s in ready merged abandoned; do
    run _update PLAN-001 "{\"status\":\"$s\"}"
    [ "$status" -eq 0 ]
    [ "$(_row_field status)" = "$s" ]
  done
}

@test "6b: allocated, completed, and specified are all rejected with exit 6" {
  for s in allocated completed specified; do
    run _update PLAN-001 "{\"status\":\"$s\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$s'" <<<"$output"
  done
}

@test "7: wrong arg count exits 2" {
  run bash "$SANDBOX/.specify/extensions/gaia/lib/plan-ledger-update.sh" "$SANDBOX" PLAN-001
  [ "$status" -eq 2 ]
}
