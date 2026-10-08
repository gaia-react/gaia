#!/usr/bin/env bats
#
# usage.sh loads every library at top level, unconditionally, before
# subcommand dispatch, and a missing one is fatal: the run exits non-zero with
# one stderr line naming the file, so a readout never prints figures computed
# without it. The static check reads usage.sh's own source lines; the runtime
# check deletes each library from a scratch copy of the scripts directory.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-library-load.bats
#
# The sed and grep patterns name usage.sh's own `$` text, so they are
# single-quoted on purpose.
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  MAIN="$TEMPORARY_DIRECTORY/main"
  mkdir -p "$MAIN/.gaia/local/telemetry"
  git -C "$MAIN" init -q -b main
  export GAIA_RATES_FEED_DISABLE=1 GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/rates-state"
  unset CLAUDE_CODE_SESSION_ID
}

# The libraries usage.sh sources, read from its own source lines.
sourced_libraries() {
  sed -nE 's|^\. "\$_usage_script_directory/([a-z-]+\.sh)".*|\1|p' "$1"
}

# source_line_violations <usage.sh>: one line per source line that is indented
# (inside a function or a branch), guarded by a file test, silenced into
# success, or placed after the subcommand dispatch.
source_line_violations() {
  local file="$1" dispatch_line line_number line_text
  dispatch_line="$(grep -n '^case "\$SUBCOMMAND" in' "$file" | cut -d: -f1)"
  [ -n "$dispatch_line" ] || { printf 'no subcommand dispatch found\n'; return 0; }
  while IFS= read -r line_number_and_text; do
    line_number="${line_number_and_text%%:*}" line_text="${line_number_and_text#*:}"
    case "$line_text" in [[:space:]]*) printf '%s: indented\n' "$line_number" ;; esac
    case "$line_text" in *'|| true'*) printf '%s: silenced\n' "$line_number" ;; esac
    case "$line_text" in *'[ -f'* | *'test -f'*) printf '%s: guarded\n' "$line_number" ;; esac
    [ "$line_number" -lt "$dispatch_line" ] || printf '%s: after dispatch\n' "$line_number"
  done < <(grep -nE '(^|[;&|])[[:space:]]*(\.|source)[[:space:]]+["'\''$/]' "$file")
}

@test "every library source line sits at top level, unconditional and unsilenced, before dispatch" {
  local libraries
  libraries="$(sourced_libraries "$SCRIPTS/usage.sh")"
  [ "$(printf '%s\n' "$libraries" | grep -c .)" -ge 5 ]
  printf '%s\n' "$libraries" | grep -qxF usage-memo-lib.sh
  printf '%s\n' "$libraries" | grep -qxF token-pricing-lib.sh
  run source_line_violations "$SCRIPTS/usage.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "guard red: a guarded, a silenced and a function-level source line are each reported" {
  local mutant="$TEMPORARY_DIRECTORY/usage.sh"
  sed -e 's|^\(\. "\$_usage_script_directory/usage-memo-lib.sh"\).*|[ -f "$_usage_script_directory/usage-memo-lib.sh" ] \&\& \1|' \
    -e 's|^\(\. "\$_usage_script_directory/token-pricing-lib.sh"\).*|\1 2>/dev/null \|\| true|' \
    -e 's|^_keys() {|_late_load() {\n  . "$_usage_script_directory/usage-memo-lib.sh"\n}\n_keys() {|' \
    "$SCRIPTS/usage.sh" >"$mutant"
  cmp -s "$SCRIPTS/usage.sh" "$mutant" && return 1
  run source_line_violations "$mutant"
  grep -qE ': guarded$' <<<"$output"
  grep -qE ': silenced$' <<<"$output"
  grep -qE ': indented$' <<<"$output"
}

@test "a library missing from the scripts directory stops the run with one stderr line naming it" {
  local library scratch seen=0
  while IFS= read -r library; do
    scratch="$TEMPORARY_DIRECTORY/scripts-${library%.sh}"
    mkdir -p "$scratch/spec"
    cp "$SCRIPTS"/*.sh "$SCRIPTS"/*.json "$scratch/"
    cp "$SCRIPTS/spec/with-ledger-lock.sh" "$scratch/spec/"
    rm "$scratch/$library"
    run --separate-stderr bash "$scratch/usage.sh" initiative spec:SPEC-001 --main-root "$MAIN"
    [ "$status" -ne 0 ] || { printf 'without %s the run exited 0\n' "$library" >&2; return 1; }
    [ -z "$output" ] || { printf 'without %s the run printed:\n%s\n' "$library" "$output" >&2; return 1; }
    [ "$stderr" = "usage: cannot load $scratch/$library" ] || { printf 'without %s stderr was:\n%s\n' "$library" "$stderr" >&2; return 1; }
    seen=$((seen + 1))
  done < <(sourced_libraries "$SCRIPTS/usage.sh")
  [ "$seen" -ge 5 ]
}
