#!/usr/bin/env bats
#
# Start and close binding pairing (usage_intervals in usage-resolve-lib.sh):
# per session and workflow, a recovery close claims its own start first, then
# every other close claims the latest remaining start at or before it when
# that start is unclaimed. Expected intervals are literals.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-pairing.bats
#
# The jq programs are single-quoted on purpose: their `$` names are jq's.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVE_LIBRARY="$SCRIPTS/usage-resolve-lib.sh"
}

start_row() {
  printf '{"schema_version":1,"kind":"binding","type":"start","session_id":"%s","ts":"%s","workflow":"%s","source":"%s"}\n' "$1" "$2" "$3" "${4:-transcript}"
}

# close_row <sid> <ts> <ref> <workflow> [start_ts]
close_row() {
  if [ -n "${5:-}" ]; then
    printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"%s","workflow":"%s","source":"record-command","start_ts":"%s"}\n' "$1" "$2" "$3" "$4" "$5"
  else
    printf '{"schema_version":1,"kind":"binding","type":"close","session_id":"%s","ts":"%s","ref":"%s","workflow":"%s","source":"record-command"}\n' "$1" "$2" "$3" "$4"
  fi
}

# intervals [resolve lib]: the intervals usage_intervals pairs from the rows on
# stdin, one "<session> <t0> <t1> <key>" line each, sorted.
intervals() {
  bash -c '. "$1/usage-lib.sh" && . "$2" || exit 9
    jq -sr "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'\'' usage_intervals(.)[] | "\(.session_id) \(.t0 | todate) \(.t1 | todate) \(.key)"'\'' | LC_ALL=C sort' \
    _ "$SCRIPTS" "${1:-$RESOLVE_LIBRARY}"
}

newer_start_rows() {
  start_row s1 2026-10-01T10:00:00Z gaia-spec
  start_row s1 2026-10-01T10:10:00Z gaia-spec
  close_row s1 2026-10-01T10:20:00Z spec:SPEC-301 gaia-spec
}

@test "a newer start supersedes an older unclaimed one: the close pairs with the later start and the earlier is never claimed" {
  run intervals < <(newer_start_rows)
  [ "$status" -eq 0 ]
  [ "$output" = "s1 2026-10-01T10:10:00Z 2026-10-01T10:20:00Z spec:SPEC-301" ]
}

@test "a second close whose latest start is already claimed pairs with nothing" {
  run intervals < <(newer_start_rows; close_row s1 2026-10-01T10:30:00Z spec:SPEC-302 gaia-spec)
  [ "$status" -eq 0 ]
  [ "$output" = "s1 2026-10-01T10:10:00Z 2026-10-01T10:20:00Z spec:SPEC-301" ]
}

@test "two runs each closed after their own start pair with their own start" {
  run intervals < <(
    start_row s1 2026-10-01T10:00:00Z gaia-spec
    close_row s1 2026-10-01T10:05:00Z spec:SPEC-301 gaia-spec
    start_row s1 2026-10-01T10:10:00Z gaia-spec
    close_row s1 2026-10-01T10:15:00Z spec:SPEC-302 gaia-spec
  )
  [ "$status" -eq 0 ]
  [ "$output" = $'s1 2026-10-01T10:00:00Z 2026-10-01T10:05:00Z spec:SPEC-301\ns1 2026-10-01T10:10:00Z 2026-10-01T10:15:00Z spec:SPEC-302' ]
}

@test "a recovery close claims its own start inside a live run, which a later plain close still pairs with" {
  run intervals < <(
    start_row s1 2026-10-01T10:00:00Z gaia-spec record-command
    start_row s1 2026-10-01T10:10:00Z gaia-spec
    close_row s1 2026-10-01T10:20:00Z spec:SPEC-301 gaia-spec 2026-10-01T10:00:00Z
    close_row s1 2026-10-01T10:30:00Z spec:SPEC-302 gaia-spec
  )
  [ "$status" -eq 0 ]
  [ "$output" = $'s1 2026-10-01T10:00:00Z 2026-10-01T10:20:00Z spec:SPEC-301\ns1 2026-10-01T10:10:00Z 2026-10-01T10:30:00Z spec:SPEC-302' ]
}

@test "a recovery close whose start is missing pairs with nothing and leaves the live start for the next close" {
  run intervals < <(
    start_row s1 2026-10-01T10:10:00Z gaia-spec
    close_row s1 2026-10-01T10:20:00Z spec:SPEC-301 gaia-spec 2026-10-01T10:00:00Z
    close_row s1 2026-10-01T10:30:00Z spec:SPEC-302 gaia-spec
  )
  [ "$status" -eq 0 ]
  [ "$output" = "s1 2026-10-01T10:10:00Z 2026-10-01T10:30:00Z spec:SPEC-302" ]
}

@test "pairing never crosses a workflow or a session, and a close before any start opens nothing" {
  run intervals < <(
    close_row s1 2026-10-01T09:00:00Z spec:SPEC-300 gaia-spec
    start_row s1 2026-10-01T10:00:00Z gaia-spec
    start_row s1 2026-10-01T10:05:00Z gaia-plan
    close_row s1 2026-10-01T10:20:00Z spec:SPEC-301 gaia-spec
    close_row s2 2026-10-01T10:25:00Z plan:PLAN-040 gaia-plan
    close_row s1 2026-10-01T10:30:00Z plan:PLAN-041 gaia-plan
  )
  [ "$status" -eq 0 ]
  [ "$output" = $'s1 2026-10-01T10:00:00Z 2026-10-01T10:20:00Z spec:SPEC-301\ns1 2026-10-01T10:05:00Z 2026-10-01T10:30:00Z plan:PLAN-041' ]
}

@test "a close whose ref fails the grammar claims its start but opens no interval" {
  run intervals < <(
    start_row s1 2026-10-01T10:00:00Z gaia-spec
    close_row s1 2026-10-01T10:20:00Z spec:SPEC-1 gaia-spec
    close_row s1 2026-10-01T10:30:00Z spec:SPEC-302 gaia-spec
  )
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guard red: an earliest-unclaimed copy pairs the close with the older start" {
  local mutant="$BATS_TEST_TMPDIR/usage-resolve-lib.sh"
  sed 's/| (\[\$remaining\[\] | select(\._t <= \$close\._t)\] | last) as \$start/| ([$remaining[] | select(._t <= $close._t and ($claimed[._i | tostring] | not))] | first) as $start/' \
    "$RESOLVE_LIBRARY" >"$mutant"
  cmp -s "$RESOLVE_LIBRARY" "$mutant" && return 1
  run intervals "$mutant" < <(newer_start_rows)
  [ "$status" -eq 0 ]
  [ "$output" = "s1 2026-10-01T10:00:00Z 2026-10-01T10:20:00Z spec:SPEC-301" ]
}
