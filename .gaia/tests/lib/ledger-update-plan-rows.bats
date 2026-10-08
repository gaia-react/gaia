#!/usr/bin/env bats
# Tests for `.gaia/scripts/spec/ledger-update.sh` driven with PLAN- ids: the
# single guarded mutation chokepoint for `.gaia/local/plans/ledger.json` rows
# after the initial `plan-allocator.sh` allocation, plus the cross-kind
# routing, fail-closed probes and lock scope the merged script owns.
#
# Does NOT use helpers/tmp-spec-repo.sh: that shared harness seeds only the
# specs ledger. Instead, mirrors the self-copy sandbox pattern from
# `.gaia/scripts/tests/plan-archive.bats`: copy the script under test plus its
# runtime deps (ledger-lib.sh, with-ledger-lock.sh, ledger-path-lib.sh,
# main-root-lib.sh) into a sibling lib dir so the ${BASH_SOURCE[0]}-relative
# source resolves, `git init` the sandbox so the main-checkout resolver has a
# real repository to resolve against, and seed both ledgers explicitly.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  SOURCE_LIBRARY_DIRECTORY="$REPO_ROOT/.gaia/scripts/spec"
  SOURCE_SCRIPTS_DIRECTORY="$REPO_ROOT/.gaia/scripts"
  [ -x "$SOURCE_LIBRARY_DIRECTORY/ledger-update.sh" ] || skip "ledger-update.sh not executable"

  SANDBOX_RAW="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX_RAW" && pwd -P)"

  git -C "$SANDBOX" init --quiet --initial-branch=main

  mkdir -p "$SANDBOX/.gaia/scripts/spec"
  cp "$SOURCE_LIBRARY_DIRECTORY/ledger-update.sh" "$SANDBOX/.gaia/scripts/spec/ledger-update.sh"
  cp "$SOURCE_LIBRARY_DIRECTORY/ledger-lib.sh" "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
  cp "$SOURCE_LIBRARY_DIRECTORY/with-ledger-lock.sh" "$SANDBOX/.gaia/scripts/spec/with-ledger-lock.sh"

  mkdir -p "$SANDBOX/.gaia/scripts"
  cp "$SOURCE_SCRIPTS_DIRECTORY/ledger-path-lib.sh" "$SANDBOX/.gaia/scripts/ledger-path-lib.sh"
  cp "$SOURCE_SCRIPTS_DIRECTORY/main-root-lib.sh" "$SANDBOX/.gaia/scripts/main-root-lib.sh"

  mkdir -p "$SANDBOX/.gaia/local/plans" "$SANDBOX/.gaia/local/specs"
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
  cat > "$SANDBOX/.gaia/local/specs/ledger.json" <<'EOF'
{
  "version": 1,
  "specs": [
    {
      "id": "SPEC-001",
      "allocated_at": "2026-01-01T00:00:00Z",
      "subject": "y",
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

LEDGER_RELATIVE_PATH=".gaia/local/plans/ledger.json"
SPEC_LEDGER_RELATIVE_PATH=".gaia/local/specs/ledger.json"

_update() {
  bash "$SANDBOX/.gaia/scripts/spec/ledger-update.sh" "$SANDBOX" "$@"
}

_row_field() {
  local field="$1"
  jq -r --arg id "PLAN-001" --arg field_name "$field" \
    '.plans[] | select(.id == $id) | .[$field_name] // "null"' \
    "$SANDBOX/$LEDGER_RELATIVE_PATH"
}

_spec_row_field() {
  local field="$1"
  jq -r --arg id "SPEC-001" --arg field_name "$field" \
    '.specs[] | select(.id == $id) | .[$field_name] // "null"' \
    "$SANDBOX/$SPEC_LEDGER_RELATIVE_PATH"
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

@test "2b: draft is a spec-only status, rejected for a plan with the ledger untouched" {
  before="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  run _update PLAN-001 '{"status":"draft"}'
  [ "$status" -eq 6 ]
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before"
}

@test "3: status-less patch updates only the targeted field, status untouched" {
  run _update PLAN-001 '{"subject":"new subject"}'
  [ "$status" -eq 0 ]
  [ "$(_row_field subject)" = "new subject" ]
  [ "$(_row_field status)" = "ready" ]
}

@test "4: patch for a non-existent row exits 4 and mutates nothing" {
  before="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  run _update PLAN-999 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before"
}

@test "5: malformed patch JSON exits 5" {
  run _update PLAN-001 'not json'
  [ "$status" -eq 5 ]
}

@test "6: ready, merged, and abandoned are all accepted" {
  for status_name in ready merged abandoned; do
    run _update PLAN-001 "{\"status\":\"$status_name\"}"
    [ "$status" -eq 0 ]
    [ "$(_row_field status)" = "$status_name" ]
  done
}

@test "6b: allocated, completed, and specified are all rejected with exit 6" {
  for status_name in allocated completed specified; do
    run _update PLAN-001 "{\"status\":\"$status_name\"}"
    [ "$status" -eq 6 ]
    grep -qF "non-canonical status '$status_name'" <<<"$output"
  done
}

@test "7: wrong arg count exits 2" {
  run bash "$SANDBOX/.gaia/scripts/spec/ledger-update.sh" "$SANDBOX" PLAN-001
  [ "$status" -eq 2 ]
}

@test "8: a SPEC id patches the specs ledger and leaves the plans ledger alone" {
  before="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  run _update SPEC-001 '{"status":"draft"}'
  [ "$status" -eq 0 ]
  [ "$(_spec_row_field status)" = "draft" ]
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before"
}

@test "9: an id matching neither prefix exits 2 and writes nothing" {
  before_plans="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  before_specs="$(snapshot_file "$SANDBOX/$SPEC_LEDGER_RELATIVE_PATH")"
  for bad_id in FOO-1 plan-001 ""; do
    run _update "$bad_id" '{"status":"merged"}'
    [ "$status" -eq 2 ]
  done
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before_plans"
  assert_files_identical "$SANDBOX/$SPEC_LEDGER_RELATIVE_PATH" "$before_specs"
}

@test "10: a missing mutex library fails closed with exit 4 for a plan id" {
  rm "$SANDBOX/.gaia/scripts/spec/with-ledger-lock.sh"
  before="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "ledger-update: the shared ledger mutex is unusable" <<<"$output"
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before"
}

@test "10b: an unparseable mutex library fails closed with exit 4 for a plan id" {
  printf 'with_ledger_lock() { if then\n' > "$SANDBOX/.gaia/scripts/spec/with-ledger-lock.sh"
  before="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "ledger-update: the shared ledger mutex is unusable" <<<"$output"
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before"
}

@test "11: a missing or unparseable ledger-lib.sh fails closed with exit 4 for every id, even one matching neither prefix" {
  before_plans="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  before_specs="$(snapshot_file "$SANDBOX/$SPEC_LEDGER_RELATIVE_PATH")"
  for lib_state in missing unparseable; do
    if [ "$lib_state" = missing ]; then
      rm -f "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
    else
      printf 'gaia_ledger_kind_for_id() { if then\n' > "$SANDBOX/.gaia/scripts/spec/ledger-lib.sh"
    fi
    for ledger_id in PLAN-001 SPEC-001 FOO-1; do
      run _update "$ledger_id" '{"status":"merged"}'
      [ "$status" -eq 4 ]
      grep -qF "ledger-update: the shared ledger library is unusable" <<<"$output"
    done
  done
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before_plans"
  assert_files_identical "$SANDBOX/$SPEC_LEDGER_RELATIVE_PATH" "$before_specs"
}

@test "12: a plan update does not wait on a held specs lock" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.05
  mkdir "$SANDBOX/.gaia/local/specs/specs.lock.d"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 0 ]
  [ "$(_row_field status)" = "merged" ]
}

@test "12b: a held plans lock times a plan update out with exit 4 and no write" {
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=1 GAIA_LEDGER_LOCK_POLL_SECONDS=0.05 GAIA_LEDGER_LOCK_STALE_SECONDS=600
  mkdir "$SANDBOX/.gaia/local/plans/specs.lock.d"
  before="$(snapshot_file "$SANDBOX/$LEDGER_RELATIVE_PATH")"
  run _update PLAN-001 '{"status":"merged"}'
  [ "$status" -eq 4 ]
  grep -qF "could not acquire ledger lock" <<<"$output"
  assert_files_identical "$SANDBOX/$LEDGER_RELATIVE_PATH" "$before"
}
