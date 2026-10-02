#!/usr/bin/env bats
# Unit suite for token-rates-local-lib.sh (seed, sync, corrupt recovery). Every
# test runs against a temp git repo; nothing touches the developer's .gaia/local.
# RATES_TEST_LIBRARY_DIRECTORY points the suite at a scratch copy of the scripts dir, which
# is how the edited-row guard is proven able to fail.

setup() {
  LIBRARY_DIRECTORY="${RATES_TEST_LIBRARY_DIRECTORY:-$BATS_TEST_DIRNAME/..}"
  LIBRARY="$LIBRARY_DIRECTORY/token-pricing-lib.sh"
  REPO="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/repo"
  mkdir -p "$REPO/.gaia/scripts"
  git init -q "$REPO"
  DISTRIBUTED_TABLE="$REPO/.gaia/scripts/token-rates.json"
  cat >"$DISTRIBUTED_TABLE" <<'JSON'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": {
    "claude-opus-5":     [ { "input": 5,  "output": 25 } ],
    "claude-opus-4-6":   [ { "input": 5,  "output": 25 } ],
    "claude-sonnet-5":   [ { "input": 2,  "output": 10 } ],
    "claude-haiku-4-5":  [ { "input": 1,  "output": 5 } ]
  }
}
JSON
  STATE="$REPO/.gaia/local/telemetry"
  LOCAL="$STATE/token-rates.json"
  BASE="$STATE/token-rates.base.json"
  COPY="$STATE/token-rates.dist.json"
}

# Runs gaia_rates_prepare in a fresh shell inside the repo. Prints
# MODE|TABLE|DIR|rc on stdout; the lib's own stderr goes to $(ERROR_FILE_PATH).
ERROR_FILE_PATH() { printf '%s' "$BATS_TEST_TMPDIR/err"; }
prepare_rates() {
  (
    cd "$REPO" || exit 9
    bash -c 'source "$1"; shift; gaia_rates_prepare "$@"; exit_status=$?
      printf "%s|%s|%s|%s\n" "$GAIA_RATES_MODE" "$GAIA_RATES_TABLE" "$GAIA_RATES_DIRECTORY" "$exit_status"' \
      _ "$LIBRARY" "$@"
  ) 2>"$(ERROR_FILE_PATH)"
}

# Edit a JSON file in place with a jq filter.
edit_json_file() {
  local file="$1" filter="$2"
  jq "$filter" "$file" >"$file.new" && mv "$file.new" "$file"
}

row() { jq -c --arg model "$2" '.models[$model]' "$1"; }

@test "override mode short-circuits: no state dir, nothing written" {
  run prepare_rates /somewhere/table.json
  [ "$status" -eq 0 ]
  [ "$output" = "override|/somewhere/table.json||0" ]
  [ ! -e "$REPO/.gaia/local" ]
}

@test "seed: local is byte-identical, base is JSON-equal, byte copy is byte-identical" {
  run prepare_rates ""
  [ "$status" -eq 0 ]
  [ "$output" = "local|$LOCAL|$STATE|0" ]
  cmp "$LOCAL" "$DISTRIBUTED_TABLE"
  cmp "$COPY" "$DISTRIBUTED_TABLE"
  jq -e --slurpfile distributed_table "$DISTRIBUTED_TABLE" '. == $distributed_table[0]' "$BASE" >/dev/null
}

@test "prepare prints nothing to stdout and nothing to stderr on a clean seed" {
  run bash -c 'cd "$1" && source "$2" && gaia_rates_prepare "" ' _ "$REPO" "$LIBRARY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$(ERROR_FILE_PATH)" ]
}

@test "second call in one shell returns the cached result without touching disk" {
  run bash -c '
    cd "$1" || exit 9
    source "$2"
    gaia_rates_prepare "" || exit 8
    first="$GAIA_RATES_TABLE"
    rm -rf "$1/.gaia/local"
    gaia_rates_prepare ""; exit_status=$?
    [ "$exit_status" -eq 0 ] || exit 7
    [ "$GAIA_RATES_TABLE" = "$first" ] || exit 6
    [ ! -e "$1/.gaia/local" ] || exit 5
    printf ok
  ' _ "$REPO" "$LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "GAIA_RATES_STATE_DIRECTORY replaces the state dir; the distributed source stays main's" {
  export GAIA_RATES_STATE_DIRECTORY="$BATS_TEST_TMPDIR/alt"
  run prepare_rates ""
  [ "$output" = "local|$BATS_TEST_TMPDIR/alt/token-rates.json|$BATS_TEST_TMPDIR/alt|0" ]
  cmp "$BATS_TEST_TMPDIR/alt/token-rates.json" "$DISTRIBUTED_TABLE"
  [ ! -e "$REPO/.gaia/local" ]
}

@test "sync: unedited row that the distributed table changed is replaced, base follows" {
  prepare_rates "" >/dev/null
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-opus-5"][0].input = 6'
  run prepare_rates ""
  [ "$status" -eq 0 ]
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":6,"output":25}]' ]
  [ "$(row "$BASE" claude-opus-5)" = '[{"input":6,"output":25}]' ]
}

@test "sync: unedited row absent from the new distributed table is kept" {
  prepare_rates "" >/dev/null
  edit_json_file "$DISTRIBUTED_TABLE" 'del(.models["claude-opus-4-6"])'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-4-6)" = '[{"input":5,"output":25}]' ]
  [ "$(row "$BASE" claude-opus-4-6)" = '[{"input":5,"output":25}]' ]
}

@test "sync guard: an edited row survives a distributed change, base takes the distributed value" {
  prepare_rates "" >/dev/null
  edit_json_file "$LOCAL" '.models["claude-sonnet-5"][0].input = 9'
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-sonnet-5"][0].input = 3'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-sonnet-5)" = '[{"input":9,"output":10}]' ]
  [ "$(row "$BASE" claude-sonnet-5)" = '[{"input":3,"output":10}]' ]
}

@test "sync: edited row absent from the new distributed table is kept, base unchanged" {
  prepare_rates "" >/dev/null
  edit_json_file "$LOCAL" '.models["claude-haiku-4-5"][0].input = 7'
  edit_json_file "$DISTRIBUTED_TABLE" 'del(.models["claude-haiku-4-5"])'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-haiku-4-5)" = '[{"input":7,"output":5}]' ]
  [ "$(row "$BASE" claude-haiku-4-5)" = '[{"input":1,"output":5}]' ]
}

@test "sync: a row with no base row counts as edited and takes the distributed base" {
  prepare_rates "" >/dev/null
  edit_json_file "$BASE" 'del(.models["claude-sonnet-5"])'
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-sonnet-5"][0].input = 4'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-sonnet-5)" = '[{"input":2,"output":10}]' ]
  [ "$(row "$BASE" claude-sonnet-5)" = '[{"input":4,"output":10}]' ]
}

@test "sync: a model only in the distributed table is added to local and base" {
  prepare_rates "" >/dev/null
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-new-1"] = [{"input": 8, "output": 40}]'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-new-1)" = '[{"input":8,"output":40}]' ]
  [ "$(row "$BASE" claude-new-1)" = '[{"input":8,"output":40}]' ]
}

@test "sync: a deleted local row stays deleted until a sync adds it back" {
  prepare_rates "" >/dev/null
  edit_json_file "$LOCAL" 'del(.models["claude-opus-4-6"])'
  prepare_rates "" >/dev/null
  jq -e '.models | has("claude-opus-4-6") | not' "$LOCAL" >/dev/null
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-opus-5"][0].input = 6'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-4-6)" = '[{"input":5,"output":25}]' ]
}

@test "sync: key order and whitespace differences alone do not make a row edited" {
  prepare_rates "" >/dev/null
  jq -c '.models["claude-opus-5"] = [{output: 25, input: 5}]' "$LOCAL" >"$LOCAL.new"
  mv "$LOCAL.new" "$LOCAL"
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-opus-5"][0].input = 6'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":6,"output":25}]' ]
}

@test "sync: unedited cache_multipliers follow the distributed table" {
  prepare_rates "" >/dev/null
  edit_json_file "$DISTRIBUTED_TABLE" '.cache_multipliers.read = 0.2'
  prepare_rates "" >/dev/null
  [ "$(jq -c '.cache_multipliers.read' "$LOCAL")" = "0.2" ]
}

@test "sync: edited cache_multipliers are kept, base takes the distributed value" {
  prepare_rates "" >/dev/null
  edit_json_file "$LOCAL" '.cache_multipliers.read = 0.3'
  edit_json_file "$DISTRIBUTED_TABLE" '.cache_multipliers.read = 0.2'
  prepare_rates "" >/dev/null
  [ "$(jq -c '.cache_multipliers.read' "$LOCAL")" = "0.3" ]
  [ "$(jq -c '.cache_multipliers.read' "$BASE")" = "0.2" ]
}

@test "sync: a missing base keeps every local row and records a base" {
  prepare_rates "" >/dev/null
  rm "$BASE"
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-opus-5"][0].input = 6'
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":5,"output":25}]' ]
  [ -s "$BASE" ]
  [ "$(row "$BASE" claude-opus-5)" = '[{"input":6,"output":25}]' ]
}

@test "sync: a merged table equal to the distributed one writes the distributed bytes verbatim" {
  prepare_rates "" >/dev/null
  jq '.models["claude-opus-5"][0].input = 6' "$DISTRIBUTED_TABLE" | sed 's/^  /\t/' >"$DISTRIBUTED_TABLE.new"
  mv "$DISTRIBUTED_TABLE.new" "$DISTRIBUTED_TABLE"
  prepare_rates "" >/dev/null
  cmp "$LOCAL" "$DISTRIBUTED_TABLE"
  cmp "$COPY" "$DISTRIBUTED_TABLE"
}

@test "sync: an interrupted sync (local written, base and byte copy stale) converges" {
  prepare_rates "" >/dev/null
  cp "$BASE" "$BATS_TEST_TMPDIR/base.stale"
  cp "$COPY" "$BATS_TEST_TMPDIR/copy.stale"
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-opus-5"][0].input = 6'
  prepare_rates "" >/dev/null
  cp "$BATS_TEST_TMPDIR/base.stale" "$BASE"
  cp "$BATS_TEST_TMPDIR/copy.stale" "$COPY"
  prepare_rates "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":6,"output":25}]' ]
  [ "$(row "$BASE" claude-opus-5)" = '[{"input":6,"output":25}]' ]
  cmp "$COPY" "$DISTRIBUTED_TABLE"
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.after"
  prepare_rates "" >/dev/null
  cmp "$LOCAL" "$BATS_TEST_TMPDIR/local.after"
}

# Shared body: corrupt the local table with the bytes in $1, re-seed, check the
# preserved copy and the single stderr line.
corrupt_case() {
  prepare_rates "" >/dev/null
  printf '%s' "$1" >"$LOCAL"
  prepare_rates "" >/dev/null
  [ "$(wc -l <"$(ERROR_FILE_PATH)" | tr -d ' ')" = "1" ]
  local preserved
  preserved="$(sed -n 's/.*preserved as \(.*\); re-seeded$/\1/p' "$(ERROR_FILE_PATH)")"
  [ -n "$preserved" ]
  [ -e "$preserved" ]
  [ "$(cat "$preserved")" = "$1" ]
  cmp "$LOCAL" "$DISTRIBUTED_TABLE"
}

@test "corrupt local: zero bytes is preserved and re-seeded" {
  corrupt_case ""
}

@test "corrupt local: invalid JSON is preserved and re-seeded" {
  corrupt_case '{not json'
}

@test "corrupt local: valid JSON without a models object is preserved and re-seeded" {
  corrupt_case '{"models": []}'
}

@test "corrupt local: a second corruption never overwrites the first preserved copy" {
  prepare_rates "" >/dev/null
  printf 'first-corruption' >"$LOCAL"
  prepare_rates "" >/dev/null
  printf 'second-corruption' >"$LOCAL"
  prepare_rates "" >/dev/null
  local corrupt_copy_count
  corrupt_copy_count="$(find "$STATE" -name 'token-rates.json.corrupt.*' | wc -l | tr -d ' ')"
  [ "$corrupt_copy_count" = "2" ]
  grep -lq 'first-corruption' "$STATE"/token-rates.json.corrupt.*
  grep -lq 'second-corruption' "$STATE"/token-rates.json.corrupt.*
}

@test "corrupt local: copies are pruned to the 5 newest" {
  prepare_rates "" >/dev/null
  local i
  for i in 1 2 3 4 5 6 7; do
    printf 'old-%s' "$i" >"$STATE/token-rates.json.corrupt.100000000$i.AAAAAA"
  done
  printf 'fresh-corruption' >"$LOCAL"
  prepare_rates "" >/dev/null
  local corrupt_copy_count
  corrupt_copy_count="$(find "$STATE" -name 'token-rates.json.corrupt.*' | wc -l | tr -d ' ')"
  [ "$corrupt_copy_count" = "5" ]
  grep -lq 'fresh-corruption' "$STATE"/token-rates.json.corrupt.*
  [ ! -e "$STATE/token-rates.json.corrupt.1000000001.AAAAAA" ]
  [ -e "$STATE/token-rates.json.corrupt.1000000007.AAAAAA" ]
}

@test "readonly: an unresolvable main root prices the tree's own table, writes nothing" {
  local bare="$BATS_TEST_TMPDIR/bare.git" worktree_path="$BATS_TEST_TMPDIR/wt" commit_id
  git init -q --bare "$bare"
  # CI runners carry no git identity, and commit-tree refuses without one.
  commit_id="$(GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com" \
    GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com" \
    git -C "$bare" commit-tree "$(git -C "$bare" hash-object -t tree /dev/null)" -m x)"
  git -C "$bare" update-ref refs/heads/main "$commit_id"
  git -C "$bare" worktree add -q "$worktree_path" main
  mkdir -p "$worktree_path/.gaia/scripts"
  cp "$DISTRIBUTED_TABLE" "$worktree_path/.gaia/scripts/token-rates.json"
  worktree_path="$(cd "$worktree_path" && pwd -P)"
  run bash -c 'cd "$1" && source "$2" && gaia_rates_prepare ""; exit_status=$?
    printf "%s|%s|%s|%s\n" "$GAIA_RATES_MODE" "$GAIA_RATES_TABLE" "$GAIA_RATES_DIRECTORY" "$exit_status"' _ "$worktree_path" "$LIBRARY"
  [ "$status" -eq 0 ]
  [ "$output" = "readonly|$worktree_path/.gaia/scripts/token-rates.json||0" ]
  [ ! -e "$worktree_path/.gaia/local" ]
}

@test "unwritable state dir falls back to readonly on the main distributed table" {
  mkdir -p "$STATE"
  chmod 500 "$STATE"
  run prepare_rates ""
  chmod 700 "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = "readonly|$DISTRIBUTED_TABLE||0" ]
}

@test "no distributed table and no local table: returns 1 with no table" {
  rm "$DISTRIBUTED_TABLE"
  run prepare_rates ""
  [ "$output" = "|||1" ]
}

@test "an unreadable distributed table leaves a readable local table priced as is" {
  prepare_rates "" >/dev/null
  printf '{bad' >"$DISTRIBUTED_TABLE"
  run prepare_rates ""
  [ "$output" = "local|$LOCAL|$STATE|0" ]
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":5,"output":25}]' ]
}

@test "temp files are same-directory dotfiles and none are left behind" {
  prepare_rates "" >/dev/null
  edit_json_file "$DISTRIBUTED_TABLE" '.models["claude-opus-5"][0].input = 6'
  prepare_rates "" >/dev/null
  local leftover_count
  leftover_count="$(find "$STATE" -name '.token-rates*.tmp.*' | wc -l | tr -d ' ')"
  [ "$leftover_count" = "0" ]
}
