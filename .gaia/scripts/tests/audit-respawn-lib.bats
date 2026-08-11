#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/audit-respawn-lib.sh: the shared
# ledger helper for the audit re-spawn measurement instrument. Three
# consumers depend on this file (the oracle's breadcrumb writer, the
# retention sweep, and the attribution query), so this suite is the one
# place their shared contract is proven.
#
# What it proves, in the section order below:
#   1. source-time purity, no side effects
#   2. gaia_respawn_ledger_path, the path join and the empty-root refusal
#   3. gaia_respawn_record: creates the parent dir, appends, newline-terminated
#   4. the record's JSON shape and exact key order
#   5. `cleared` normalization, a JSON boolean on every input
#   6. double-quote escaping in the free-form `branch` field
#   7. a slash in `branch` round-trips unchanged, no transformation
#   8. empty fields round-trip as "", never a placeholder
#   9. fail-open silence: no stdout/stderr on any failure path
#   10. fail-open under `set -euo pipefail`: the caller's next command still runs
#   11. gaia_respawn_retention_days: default-then-floor
#   12. gaia_respawn_max_records: default-then-floor
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/audit-respawn-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# Every expected value below is written as a literal: an assertion that
# recomputes the derivation in its own body would be testing its own
# arithmetic.

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/audit-respawn-lib.sh"
  # shellcheck disable=SC1090
  source "$LIB"
  command -v jq >/dev/null 2>&1 || skip "jq required"
}

# a_record [cleared]: appends one record with fixed, distinguishable field
# values to a fresh "$BATS_TEST_TMPDIR/l.jsonl" and prints the path.
a_record() {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl"
  gaia_respawn_record "$ledger" "2026-08-01T12:34:56Z" "spec-063-foo" \
    "1111111111111111111111111111111111111111" \
    "2222222222222222222222222222222222222222" \
    "code-audit-frontend" \
    "3333333333333333333333333333333333333333333333333333333333333333" \
    "${1:-true}"
  printf '%s' "$ledger"
}

# ========== 1. source-time purity ==========

@test "criterion 1: sourcing the lib is silent at source time and creates no file" {
  local scratch="$BATS_TEST_TMPDIR/purity"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && . '$LIB' && echo ok"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  [ -z "$(ls -A "$scratch")" ]
}

@test "structural: sourcing the lib defines the four public functions" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_respawn_ledger_path >/dev/null
    type gaia_respawn_record >/dev/null
    type gaia_respawn_retention_days >/dev/null
    type gaia_respawn_max_records >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ========== 2. gaia_respawn_ledger_path ==========

@test "criterion 2: the ledger path joins root, .gaia/local, and the relative constant" {
  run gaia_respawn_ledger_path /tmp/x
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/x/.gaia/local/telemetry/audit-respawn.jsonl" ]
}

@test "criterion 2: an empty root prints nothing and returns 1" {
  run gaia_respawn_ledger_path ""
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ========== 3. gaia_respawn_record: creation, append, newline termination ==========

@test "criterion 3: a fresh call creates the parent directory and writes exactly one line" {
  local ledger="$BATS_TEST_TMPDIR/fresh/nested/l.jsonl"
  [ ! -e "$BATS_TEST_TMPDIR/fresh" ]
  gaia_respawn_record "$ledger" ts br h m mem dig true
  [ -f "$ledger" ]
  [ "$(wc -l <"$ledger" | tr -d ' ')" = "1" ]
}

@test "criterion 3: a second call appends a second line" {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl"
  gaia_respawn_record "$ledger" ts1 br h m mem dig1 true
  gaia_respawn_record "$ledger" ts2 br h m mem dig2 false
  [ "$(wc -l <"$ledger" | tr -d ' ')" = "2" ]
  grep -qF '"digest":"dig1"' "$ledger" || return 1
  grep -qF '"digest":"dig2"' "$ledger" || return 1
}

@test "criterion 3: the file ends with a newline and has no blank lines" {
  local ledger
  ledger="$(a_record)"
  gaia_respawn_record "$ledger" ts2 br h m mem dig2 false
  [ "$(tail -c1 "$ledger" | od -An -tx1 | tr -d ' ')" = "0a" ]
  grep -q '^$' "$ledger" && return 1
  return 0
}

# ========== 4. JSON shape and exact key order ==========

@test "criterion 4: the written line parses under jq and its keys are in the contracted order" {
  local ledger line
  ledger="$(a_record)"
  line="$(head -n1 "$ledger")"
  echo "$line" | jq -e . >/dev/null
  [ "$(echo "$line" | jq -r 'keys_unsorted | join(",")')" = "schema,ts,branch,head,merge_base,member,digest,cleared" ]
}

# ========== 5. cleared normalization ==========

@test "criterion 5: cleared true emits the JSON boolean true" {
  local ledger line
  ledger="$(a_record true)"
  line="$(head -n1 "$ledger")"
  [ "$(echo "$line" | jq -r '.cleared')" = "true" ]
}

@test "criterion 5: cleared false, empty, and TRUE all emit the JSON boolean false" {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl" line v
  gaia_respawn_record "$ledger" ts br h m mem dig false
  gaia_respawn_record "$ledger" ts br h m mem dig ""
  gaia_respawn_record "$ledger" ts br h m mem dig TRUE
  while IFS= read -r line; do
    v="$(echo "$line" | jq -r '.cleared')"
    [ "$v" = "false" ] || return 1
  done <"$ledger"
}

# ========== 6. double-quote escaping ==========

@test "criterion 6: a branch containing a double quote still parses and round-trips" {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl" line
  gaia_respawn_record "$ledger" ts 'a"b' h m mem dig true
  line="$(head -n1 "$ledger")"
  echo "$line" | jq -e . >/dev/null
  [ "$(echo "$line" | jq -r '.branch')" = 'a"b' ]
}

@test "criterion 6c: a member containing a backslash still parses and round-trips" {
  # The roster parser preserves a backslash, and a trailing one would escape
  # the closing quote, emitting a line no reader can parse. The sweep keeps
  # what it cannot classify, so that record would never be reaped.
  local ledger="$BATS_TEST_TMPDIR/l.jsonl" line
  gaia_respawn_record "$ledger" ts br h m 'code-audit-x\' dig true
  line="$(head -n1 "$ledger")"
  echo "$line" | jq -e . >/dev/null
  [ "$(echo "$line" | jq -r '.member')" = 'code-audit-x\' ]
}

@test "criterion 6b: a member containing a double quote still parses and round-trips" {
  # `member` comes from the hand-authored roster, which no charset guard
  # constrains. An unescaped quote would emit a line no JSON reader can parse,
  # and the prune sweep keeps what it cannot classify, so one malformed record
  # would outlive every retention bound the sweep exists to enforce.
  local ledger="$BATS_TEST_TMPDIR/l.jsonl" line
  gaia_respawn_record "$ledger" ts br h m 'a"b' dig true
  line="$(head -n1 "$ledger")"
  echo "$line" | jq -e . >/dev/null
  [ "$(echo "$line" | jq -r '.member')" = 'a"b' ]
}

# ========== 7. slash round-trip ==========

@test "criterion 7: a branch containing a slash round-trips unchanged" {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl" line
  gaia_respawn_record "$ledger" ts 'feat/x' h m mem dig true
  line="$(head -n1 "$ledger")"
  [ "$(echo "$line" | jq -r '.branch')" = "feat/x" ]
}

# ========== 8. empty fields round-trip as "" ==========

@test "criterion 8: empty branch, head, merge_base, and digest round-trip as empty strings" {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl" line
  gaia_respawn_record "$ledger" ts "" "" "" mem "" true
  line="$(head -n1 "$ledger")"
  echo "$line" | jq -e . >/dev/null
  [ "$(echo "$line" | jq -r '.branch')" = "" ]
  [ "$(echo "$line" | jq -r '.head')" = "" ]
  [ "$(echo "$line" | jq -r '.merge_base')" = "" ]
  [ "$(echo "$line" | jq -r '.digest')" = "" ]
}

# ========== 9. fail-open silence ==========

@test "criterion 9: an empty ledger path returns 0 and writes nothing to stdout or stderr" {
  run gaia_respawn_record "" ts br h m mem dig true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "criterion 9: an empty member returns 0, writes nothing, and creates no file" {
  local ledger="$BATS_TEST_TMPDIR/l.jsonl"
  run gaia_respawn_record "$ledger" ts br h m "" dig true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ledger" ]
}

@test "criterion 9: an uncreatable parent directory returns 0 and writes nothing" {
  local blocker="$BATS_TEST_TMPDIR/blocker"
  touch "$blocker"
  run gaia_respawn_record "$blocker/sub/l.jsonl" ts br h m mem dig true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ========== 10. fail-open under set -euo pipefail ==========

@test "criterion 10: none of the three failure cases abort a caller running set -euo pipefail" {
  local blocker="$BATS_TEST_TMPDIR/blocker"
  touch "$blocker"
  run bash -c "
    set -euo pipefail
    . '$LIB'
    gaia_respawn_record '' ts br h m mem dig true
    echo after-empty-ledger
    gaia_respawn_record '$BATS_TEST_TMPDIR/l.jsonl' ts br h m '' dig true
    echo after-empty-member
    gaia_respawn_record '$blocker/sub/l.jsonl' ts br h m mem dig true
    echo after-mkdir-fail
  "
  [ "$status" -eq 0 ]
  grep -qF "after-empty-ledger" <<<"$output" || return 1
  grep -qF "after-empty-member" <<<"$output" || return 1
  grep -qF "after-mkdir-fail" <<<"$output" || return 1
}

# ========== 11. gaia_respawn_retention_days: default-then-floor ==========

@test "criterion 11: unset, an override above the floor, and an override below the floor" {
  [ "$(gaia_respawn_retention_days)" = "90" ]
  [ "$(GAIA_AUDIT_RESPAWN_RETENTION_DAYS=120 bash -c ". '$LIB'; gaia_respawn_retention_days")" = "120" ]
  [ "$(GAIA_AUDIT_RESPAWN_RETENTION_DAYS=10 bash -c ". '$LIB'; gaia_respawn_retention_days")" = "45" ]
}

@test "criterion 11: invalid overrides fall through to the default 90, never the floor" {
  local v
  for v in abc "" -5 12.5; do
    [ "$(GAIA_AUDIT_RESPAWN_RETENTION_DAYS="$v" bash -c ". '$LIB'; gaia_respawn_retention_days")" = "90" ] || return 1
  done
}

# ========== 12. gaia_respawn_max_records: default-then-floor ==========

@test "criterion 12: unset, an override above the floor, and an override below the floor" {
  [ "$(gaia_respawn_max_records)" = "20000" ]
  [ "$(GAIA_AUDIT_RESPAWN_MAX_RECORDS=50000 bash -c ". '$LIB'; gaia_respawn_max_records")" = "50000" ]
  [ "$(GAIA_AUDIT_RESPAWN_MAX_RECORDS=10 bash -c ". '$LIB'; gaia_respawn_max_records")" = "1000" ]
}

@test "criterion 11b: a leading-zero override is read in base 10 by the knob and by its consumers" {
  # `test` parses base 10 and `$(( ))` reads a leading zero as octal, so an
  # un-normalized `050` clears the 45-day floor compare as 50 and then reaches
  # a consumer's arithmetic as 40, shortening the window below the floor. `08`
  # and `09` are not octal at all and abort the consumer outright.
  [ "$(GAIA_AUDIT_RESPAWN_RETENTION_DAYS=050 bash -c ". '$LIB'; gaia_respawn_retention_days")" = "50" ]
  [ "$(GAIA_AUDIT_RESPAWN_RETENTION_DAYS=008 bash -c ". '$LIB'; gaia_respawn_retention_days")" = "45" ]
  [ "$(GAIA_AUDIT_RESPAWN_MAX_RECORDS=08000 bash -c ". '$LIB'; gaia_respawn_max_records")" = "8000" ]
  # The printed value must survive a consumer's arithmetic unchanged.
  local days
  days="$(GAIA_AUDIT_RESPAWN_RETENTION_DAYS=050 bash -c ". '$LIB'; gaia_respawn_retention_days")"
  [ "$(bash -c "echo \$(($days * 1))")" = "50" ]
}

@test "criterion 12: invalid overrides fall through to the default 20000, never the floor" {
  local v
  for v in abc ""; do
    [ "$(GAIA_AUDIT_RESPAWN_MAX_RECORDS="$v" bash -c ". '$LIB'; gaia_respawn_max_records")" = "20000" ] || return 1
  done
}
