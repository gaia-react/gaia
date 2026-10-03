#!/usr/bin/env bats
#
# Suite for .gaia/scripts/context-checkpoint-lib.sh: the checkpoint line, the
# bands, the lower-only override, the context file writer and reader, and the
# session id guard.
#
# CONTEXT_LIBRARY_DIRECTORY points the suite at a scratch copy of the lib, which is how a
# mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/context-checkpoint-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY_DIRECTORY="${CONTEXT_LIBRARY_DIRECTORY:-$REPO_ROOT/.gaia/scripts}"
  # shellcheck source=/dev/null
  . "$LIBRARY_DIRECTORY/context-checkpoint-lib.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia/local/protected"
  SESSION_ID="12345678-1234-1234-1234-123456789abc"
}

write_settings() {
  printf '%s\n' "$1" >"$MAIN/.gaia/local/protected/checkpoint-override.json"
}

context_file() {
  gaia_context_file "$MAIN" "$SESSION_ID"
}

# put_context <json>: write a raw context file.
put_context() {
  local file_path
  file_path="$(context_file)"
  mkdir -p "${file_path%/*}"
  printf '%s' "$1" >"$file_path"
}

context_json() {
  printf '{"version":%s,"session_id":"%s","used_percentage":10,"used_tokens":100000,"context_window_size":1000000,"written_at":%s}' "$1" "$SESSION_ID" "$2"
}

@test "line: tokens cap on a large window" {
  run gaia_context_line 1000000 300000 50
  [ "$status" -eq 0 ]
  [ "$output" = "300000" ]
}

@test "line: percent cap on a small window" {
  run gaia_context_line 200000 300000 50
  [ "$output" = "100000" ]
}

@test "line: a lowered ask_tokens wins" {
  run gaia_context_line 1000000 200000 50
  [ "$output" = "200000" ]
}

@test "line: a non-numeric argument is rc 2" {
  run gaia_context_line abc 300000 50
  [ "$status" -eq 2 ]
  run gaia_context_line 1000000 "" 50
  [ "$status" -eq 2 ]
}

@test "bands: 1M window" {
  run gaia_context_bands 1000000 300000
  [ "$output" = "200000 300000 375000 450000" ]
}

@test "bands: 200K window" {
  run gaia_context_bands 200000 100000
  [ "$output" = "60000 100000 125000 150000" ]
}

@test "bands: yellow clamps to red" {
  run gaia_context_bands 1000000 200000
  [ "$output" = "200000 200000 250000 300000" ]
}

@test "bands: a bad argument is rc 2" {
  run gaia_context_bands 1000000 x
  [ "$status" -eq 2 ]
}

@test "override: no file reads the defaults" {
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

# write_old_override <json>: a file at the retired location, which nothing reads.
old_override_file() { printf '%s/.gaia/local/checkpoint-override.json\n' "$MAIN"; }

write_old_override() {
  printf '%s\n' "$1" >"$(old_override_file)"
}

@test "override: a file only at the retired location reads the defaults" {
  write_old_override '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a file only at protected/checkpoint-override.json is honoured" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":150000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "150000 50" ]
}

@test "override: with files at both locations only the protected one counts" {
  write_old_override '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":150000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "150000 50" ]
}

@test "red twin: a library reading the retired location honours the old file and ignores the new one" {
  mkdir -p "$BATS_TEST_TMPDIR/oldlib"
  sed 's#local/protected/checkpoint#local/checkpoint#' "$LIBRARY_DIRECTORY/context-checkpoint-lib.sh" >"$BATS_TEST_TMPDIR/oldlib/context-checkpoint-lib.sh"
  grep -qF 'local/protected/checkpoint' "$BATS_TEST_TMPDIR/oldlib/context-checkpoint-lib.sh" && return 1
  write_old_override '{"version":1,"context_checkpoint":{"ask_tokens":100000}}'
  run bash -c '. "$1" && gaia_context_override "$2"' _ "$BATS_TEST_TMPDIR/oldlib/context-checkpoint-lib.sh" "$MAIN"
  [ "$output" = "100000 50" ]
  rm -f "$(old_override_file)"
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":150000}}'
  run bash -c '. "$1" && gaia_context_override "$2"' _ "$BATS_TEST_TMPDIR/oldlib/context-checkpoint-lib.sh" "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a lower ask_tokens is honoured" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":200000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "200000 50" ]
}

@test "override: a raised ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":600000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a string ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":"abc"}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: zero ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":0}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: negative ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":-1}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: fractional ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":1.5}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a raised ask_window_pct reads as the default pct" {
  write_settings '{"version":1,"context_checkpoint":{"ask_window_pct":150}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a lowered ask_window_pct is honoured" {
  write_settings '{"version":1,"context_checkpoint":{"ask_window_pct":20}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 20" ]
}

@test "override: both fields raised read as the defaults" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":1000000,"ask_window_pct":100}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: version 2 reads as the defaults" {
  write_settings '{"version":2,"context_checkpoint":{"ask_tokens":100000}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: invalid JSON reads as the defaults" {
  write_settings '{not json'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a non-object context_checkpoint reads as the defaults" {
  write_settings '{"version":1,"context_checkpoint":5}'
  run gaia_context_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: lower-only guard, a raised override never becomes the effective value" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":900000,"ask_window_pct":90}}'
  run gaia_context_override "$MAIN"
  [ "$output" = "$GAIA_CONTEXT_ASK_TOKENS_DEFAULT $GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT" ]
}

@test "override: red state, a lib with the cap comparison removed fails the lower-only guard" {
  local scratch="$BATS_TEST_TMPDIR/mutant"
  mkdir -p "$scratch"
  sed 's/ and \. <= \$maximum//' "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" >"$scratch/context-checkpoint-lib.sh"
  # The mutation must actually have changed the lib.
  run cmp -s "$scratch/context-checkpoint-lib.sh" "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -ne 0 ]
  run env CONTEXT_LIBRARY_DIRECTORY="$scratch" bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter 'override: lower-only guard' "$BATS_TEST_FILENAME" </dev/null
  [ "$status" -ne 0 ]
}

@test "write then read: a fresh reading round-trips" {
  gaia_context_write "$MAIN" "$SESSION_ID" 25.5 255000 1000000 1700000000
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 0 ]
  [ "$output" = "fresh 255000 1000000" ]
  run jq -e '.version == 1 and .session_id == "'"$SESSION_ID"'" and .used_percentage == 25.5 and .used_tokens == 255000 and .context_window_size == 1000000 and .written_at == 1700000000' "$(context_file)"
  [ "$status" -eq 0 ]
  run find "$MAIN/.gaia/local/cache/shared/context" -name '*.tmp.*'
  [ -z "$output" ]
}

@test "write: non-integer tokens or window write nothing" {
  run gaia_context_write "$MAIN" "$SESSION_ID" 10 abc 1000000 1700000000
  [ "$status" -ne 0 ]
  run gaia_context_write "$MAIN" "$SESSION_ID" 10 100 1.5 1700000000
  [ "$status" -ne 0 ]
  [ ! -e "$(context_file)" ]
}

@test "read: missing is rc 1" {
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "missing" ]
}

@test "read: a 31 minute old reading is stale" {
  put_context "$(context_json 1 $((1700000000 - 1860)))"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "stale" ]
}

@test "read: a reading 10 minutes in the future is future" {
  put_context "$(context_json 1 $((1700000000 + 600)))"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "future" ]
}

@test "read: a small clock skew is still fresh" {
  put_context "$(context_json 1 $((1700000000 + 30)))"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 0 ]
  [ "$output" = "fresh 100000 1000000" ]
}

@test "read: garbage bytes are unparseable" {
  put_context 'garbage bytes {{{'
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "read: version 2 is unparseable" {
  put_context "$(context_json 2 1700000000)"
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "read: a non-integer field is unparseable" {
  put_context '{"version":1,"used_tokens":"x","context_window_size":1000000,"written_at":1700000000}'
  run gaia_context_read "$MAIN" "$SESSION_ID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "session id: a bad id is refused and creates no file" {
  local bad
  for bad in "../../etc" "" "12345678-1234-1234-1234-123456789ab"; do
    run gaia_context_file "$MAIN" "$bad"
    [ "$status" -ne 0 ]
    run gaia_context_write "$MAIN" "$bad" 10 100 1000000 1700000000
    [ "$status" -ne 0 ]
  done
  [ ! -e "$MAIN/.gaia/local/cache" ]
  [ ! -e "$MAIN/.gaia/etc" ]
}

@test "session id: a valid id passes" {
  gaia_context_is_session_id "$SESSION_ID"
}

@test "source: succeeds with an empty PATH and defines every function" {
  run env PATH= "$BASH" -c '. "$1"; for function_name in gaia_context_is_session_id gaia_context_file gaia_context_override gaia_context_line gaia_context_bands gaia_context_write gaia_context_read; do [ "$(type -t "$function_name")" = function ] || exit 1; done' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]
}

@test "source: double sourcing is harmless" {
  run "$BASH" -c '. "$1"; . "$1"; echo "$GAIA_CONTEXT_UNIT_ROUNDS"' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "constants: each numeric value is defined once and no function body inlines one" {
  local library="$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" value
  for value in 300000 200000; do
    [ "$(grep -c "$value" "$library")" = "1" ]
  done
  [ "$(grep -c '^GAIA_CONTEXT_ASK_WINDOW_PERCENT_DEFAULT=50$' "$library")" = "1" ]
  [ "$(grep -c '^GAIA_CONTEXT_YELLOW_WINDOW_PERCENT=30$' "$library")" = "1" ]
  # No numeric literal other than 100 / 0 / 1 / 2 in code lines past the constants block.
  run bash -c 'sed -n "/^_GAIA_CONTEXT_SKEW_SECONDS/,\$p" "$1" | grep -v "^ *#" | grep -nE "(^|[^0-9a-zA-Z_.-])(300000|200000|50|30)([^0-9]|$)"' _ "$library"
  [ "$status" -eq 1 ]
}
