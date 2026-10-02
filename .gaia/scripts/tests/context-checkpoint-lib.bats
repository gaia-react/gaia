#!/usr/bin/env bats
#
# Suite for .gaia/scripts/context-checkpoint-lib.sh: the checkpoint line, the
# bands, the lower-only override, the context file writer and reader, and the
# session id guard.
#
# CTX_LIB_DIR points the suite at a scratch copy of the lib, which is how a
# mutant is run against it without touching the working file.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/context-checkpoint-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB_DIR="${CTX_LIB_DIR:-$REPO_ROOT/.gaia/scripts}"
  # shellcheck source=/dev/null
  . "$LIB_DIR/context-checkpoint-lib.sh"
  MAIN="$BATS_TEST_TMPDIR/main"
  mkdir -p "$MAIN/.gaia/local"
  SID="12345678-1234-1234-1234-123456789abc"
}

write_settings() {
  printf '%s\n' "$1" >"$MAIN/.gaia/local/settings.json"
}

ctx_file() {
  gaia_ctx_file "$MAIN" "$SID"
}

# put_ctx <json>: write a raw context file.
put_ctx() {
  local f
  f="$(ctx_file)"
  mkdir -p "${f%/*}"
  printf '%s' "$1" >"$f"
}

ctx_json() {
  printf '{"version":%s,"session_id":"%s","used_percentage":10,"used_tokens":100000,"context_window_size":1000000,"written_at":%s}' "$1" "$SID" "$2"
}

@test "line: tokens cap on a large window" {
  run gaia_ctx_line 1000000 300000 50
  [ "$status" -eq 0 ]
  [ "$output" = "300000" ]
}

@test "line: percent cap on a small window" {
  run gaia_ctx_line 200000 300000 50
  [ "$output" = "100000" ]
}

@test "line: a lowered ask_tokens wins" {
  run gaia_ctx_line 1000000 200000 50
  [ "$output" = "200000" ]
}

@test "line: a non-numeric argument is rc 2" {
  run gaia_ctx_line abc 300000 50
  [ "$status" -eq 2 ]
  run gaia_ctx_line 1000000 "" 50
  [ "$status" -eq 2 ]
}

@test "bands: 1M window" {
  run gaia_ctx_bands 1000000 300000
  [ "$output" = "200000 300000 375000 450000" ]
}

@test "bands: 200K window" {
  run gaia_ctx_bands 200000 100000
  [ "$output" = "60000 100000 125000 150000" ]
}

@test "bands: yellow clamps to red" {
  run gaia_ctx_bands 1000000 200000
  [ "$output" = "200000 200000 250000 300000" ]
}

@test "bands: a bad argument is rc 2" {
  run gaia_ctx_bands 1000000 x
  [ "$status" -eq 2 ]
}

@test "override: no file reads the defaults" {
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a lower ask_tokens is honoured" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":200000}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "200000 50" ]
}

@test "override: a raised ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":600000}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a string ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":"abc"}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: zero ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":0}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: negative ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":-1}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: fractional ask_tokens reads as the default" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":1.5}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a raised ask_window_pct reads as the default pct" {
  write_settings '{"version":1,"context_checkpoint":{"ask_window_pct":150}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a lowered ask_window_pct is honoured" {
  write_settings '{"version":1,"context_checkpoint":{"ask_window_pct":20}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 20" ]
}

@test "override: both fields raised read as the defaults" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":1000000,"ask_window_pct":100}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: version 2 reads as the defaults" {
  write_settings '{"version":2,"context_checkpoint":{"ask_tokens":100000}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: invalid JSON reads as the defaults" {
  write_settings '{not json'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: a non-object context_checkpoint reads as the defaults" {
  write_settings '{"version":1,"context_checkpoint":5}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "300000 50" ]
}

@test "override: lower-only guard, a raised override never becomes the effective value" {
  write_settings '{"version":1,"context_checkpoint":{"ask_tokens":900000,"ask_window_pct":90}}'
  run gaia_ctx_override "$MAIN"
  [ "$output" = "$GAIA_CTX_ASK_TOKENS_DEFAULT $GAIA_CTX_ASK_WINDOW_PCT_DEFAULT" ]
}

@test "override: red state, a lib with the cap comparison removed fails the lower-only guard" {
  local scratch="$BATS_TEST_TMPDIR/mutant"
  mkdir -p "$scratch"
  sed 's/ and \. <= \$d//' "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" >"$scratch/context-checkpoint-lib.sh"
  # The mutation must actually have changed the lib.
  ! cmp -s "$scratch/context-checkpoint-lib.sh" "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  run env CTX_LIB_DIR="$scratch" bash "$REPO_ROOT/.gaia/scripts/bats5.sh" \
    --filter 'override: lower-only guard' "$BATS_TEST_FILENAME" </dev/null
  [ "$status" -ne 0 ]
}

@test "write then read: a fresh reading round-trips" {
  gaia_ctx_write "$MAIN" "$SID" 25.5 255000 1000000 1700000000
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 0 ]
  [ "$output" = "fresh 255000 1000000" ]
  run jq -e '.version == 1 and .session_id == "'"$SID"'" and .used_percentage == 25.5 and .used_tokens == 255000 and .context_window_size == 1000000 and .written_at == 1700000000' "$(ctx_file)"
  [ "$status" -eq 0 ]
  run find "$MAIN/.gaia/local/cache/shared/context" -name '*.tmp.*'
  [ -z "$output" ]
}

@test "write: non-integer tokens or window write nothing" {
  run gaia_ctx_write "$MAIN" "$SID" 10 abc 1000000 1700000000
  [ "$status" -ne 0 ]
  run gaia_ctx_write "$MAIN" "$SID" 10 100 1.5 1700000000
  [ "$status" -ne 0 ]
  [ ! -e "$(ctx_file)" ]
}

@test "read: missing is rc 1" {
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "missing" ]
}

@test "read: a 31 minute old reading is stale" {
  put_ctx "$(ctx_json 1 $((1700000000 - 1860)))"
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "stale" ]
}

@test "read: a reading 10 minutes in the future is future" {
  put_ctx "$(ctx_json 1 $((1700000000 + 600)))"
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "future" ]
}

@test "read: a small clock skew is still fresh" {
  put_ctx "$(ctx_json 1 $((1700000000 + 30)))"
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 0 ]
  [ "$output" = "fresh 100000 1000000" ]
}

@test "read: garbage bytes are unparseable" {
  put_ctx 'garbage bytes {{{'
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "read: version 2 is unparseable" {
  put_ctx "$(ctx_json 2 1700000000)"
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "read: a non-integer field is unparseable" {
  put_ctx '{"version":1,"used_tokens":"x","context_window_size":1000000,"written_at":1700000000}'
  run gaia_ctx_read "$MAIN" "$SID" 1700000000
  [ "$status" -eq 1 ]
  [ "$output" = "unparseable" ]
}

@test "session id: a bad id is refused and creates no file" {
  local bad
  for bad in "../../etc" "" "12345678-1234-1234-1234-123456789ab"; do
    run gaia_ctx_file "$MAIN" "$bad"
    [ "$status" -ne 0 ]
    run gaia_ctx_write "$MAIN" "$bad" 10 100 1000000 1700000000
    [ "$status" -ne 0 ]
  done
  [ ! -e "$MAIN/.gaia/local/cache" ]
  [ ! -e "$MAIN/.gaia/etc" ]
}

@test "session id: a valid id passes" {
  gaia_ctx_is_session_id "$SID"
}

@test "source: succeeds with an empty PATH and defines every function" {
  run env PATH= "$BASH" -c '. "$1"; for f in gaia_ctx_is_session_id gaia_ctx_file gaia_ctx_override gaia_ctx_line gaia_ctx_bands gaia_ctx_write gaia_ctx_read; do [ "$(type -t "$f")" = function ] || exit 1; done' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]
}

@test "source: double sourcing is harmless" {
  run "$BASH" -c '. "$1"; . "$1"; echo "$GAIA_CTX_UNIT_ROUNDS"' _ "$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "constants: each numeric value is defined once and no function body inlines one" {
  local lib="$REPO_ROOT/.gaia/scripts/context-checkpoint-lib.sh" v
  for v in 300000 200000; do
    [ "$(grep -c "$v" "$lib")" = "1" ]
  done
  [ "$(grep -c '^GAIA_CTX_ASK_WINDOW_PCT_DEFAULT=50$' "$lib")" = "1" ]
  [ "$(grep -c '^GAIA_CTX_YELLOW_WINDOW_PCT=30$' "$lib")" = "1" ]
  # No numeric literal other than 100 / 0 / 1 / 2 in code lines past the constants block.
  run bash -c 'sed -n "/^_GAIA_CTX_SKEW_SECONDS/,\$p" "$1" | grep -v "^ *#" | grep -nE "(^|[^0-9a-zA-Z_.-])(300000|200000|50|30)([^0-9]|$)"' _ "$lib"
  [ "$status" -eq 1 ]
}
