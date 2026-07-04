#!/usr/bin/env bats
# Tests for plan-allocator.sh: allocates PLAN-NNN ids for spec-less one-off
# plans from the local, gitignored .gaia/local/plans/ledger.json ledger.
# Local-only (no git requirement, no remote reservation, no network); the
# union of ledger ids + on-disk PLAN-* folders (live + archived) is the sole
# collision authority. Modeled on the invoked-script idiom in
# spec-ledger-status.bats: plain run/$status/$output, no bats-support/assert
# libs, per-test temp repo via helpers/tmp-spec-repo.sh.

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    rm -rf "$REPO"
  fi
}

_alloc() {
  bash "$REPO/.specify/extensions/gaia/lib/plan-allocator.sh" "$@"
}

@test "1: fresh run seeds ledger + returns PLAN-001" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-001" ]
  [ -f "$REPO/.gaia/local/plans/ledger.json" ]
  [ "$(jq -r '.version' "$REPO/.gaia/local/plans/ledger.json")" = "1" ]
  [ "$(jq -r '.plans | length' "$REPO/.gaia/local/plans/ledger.json")" -eq 1 ]
  [ "$(jq -r '.plans[0].id' "$REPO/.gaia/local/plans/ledger.json")" = "PLAN-001" ]
}

@test "2: second call returns PLAN-002 with the exact row shape" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  run _alloc next "$REPO" "my subject"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-002" ]

  ledger="$REPO/.gaia/local/plans/ledger.json"
  [ "$(jq -r '.plans[1].id' "$ledger")" = "PLAN-002" ]
  [ "$(jq -r '.plans[1].source' "$ledger")" = "allocated" ]
  [ "$(jq -r '.plans[1].subject' "$ledger")" = "my subject" ]
  [ "$(jq -c '.plans[1] | keys_unsorted' "$ledger")" = '["id","allocated_at","source","subject"]' ]

  # 2-space indent, trailing newline (jq's default output).
  grep -qF '  "version"' "$ledger"
  [ "$(tail -c1 "$ledger" | wc -l)" -eq 1 ]
}

@test "3a: multiline subject stores only the first line" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  run _alloc next "$REPO" "$(printf 'first line\nsecond line')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.plans[0].subject' "$REPO/.gaia/local/plans/ledger.json")" = "first line" ]
}

@test "3b: a >100-char subject is stored truncated to exactly 100 chars" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  long="$(printf 'a%.0s' $(seq 1 150))"
  run _alloc next "$REPO" "$long"
  [ "$status" -eq 0 ]
  stored="$(jq -r '.plans[0].subject' "$REPO/.gaia/local/plans/ledger.json")"
  [ "${#stored}" -eq 100 ]
}

@test "3c: empty/absent subject falls back to the allocated id" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.plans[0].subject' "$REPO/.gaia/local/plans/ledger.json")" = "PLAN-001" ]
}

@test "4a: a live on-disk PLAN-050 folder is consumed; next allocates PLAN-051" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  mkdir -p "$REPO/.gaia/local/plans/PLAN-050"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-051" ]
}

@test "4b: an archived-only PLAN-050 folder is still consumed; next allocates PLAN-051" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  mkdir -p "$REPO/.gaia/local/plans/archived/PLAN-050"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-051" ]
}

@test "5a: PLAN-999 folder expands to 4 digits with no leading zero" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  mkdir -p "$REPO/.gaia/local/plans/PLAN-999"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-1000" ]
}

@test "5b: a leading-zero legacy PLAN-018 folder counts as 18 (base-10, not octal)" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  mkdir -p "$REPO/.gaia/local/plans/PLAN-018"
  run _alloc next "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "PLAN-019" ]
}

@test "6: concurrent next calls (forced mkdir fallback) yield two distinct ids" {
  REPO="$("$HELPERS/tmp-spec-repo.sh")"
  rm -f "$REPO"/out.* "$REPO/start.flag"

  for i in 1 2; do
    bash -c '
      repo="$1"; idx="$2"
      until [ -f "$repo/start.flag" ]; do :; done
      GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 bash "$repo/.specify/extensions/gaia/lib/plan-allocator.sh" next "$repo" > "$repo/out.$idx" 2>/dev/null
    ' _ "$REPO" "$i" &
  done
  touch "$REPO/start.flag"
  wait

  a="$(cat "$REPO/out.1")"
  b="$(cat "$REPO/out.2")"
  [ "$a" != "$b" ]
  ids="$(printf '%s\n%s\n' "$a" "$b" | sort)"
  [ "$ids" = "$(printf 'PLAN-001\nPLAN-002\n')" ]
  [ "$(jq -r '.plans | length' "$REPO/.gaia/local/plans/ledger.json")" -eq 2 ]
}
