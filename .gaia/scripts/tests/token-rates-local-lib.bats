#!/usr/bin/env bats
# Unit suite for token-rates-local-lib.sh (seed, sync, corrupt recovery). Every
# test runs against a temp git repo; nothing touches the developer's .gaia/local.
# RATES_TEST_LIB_DIR points the suite at a scratch copy of the scripts dir, which
# is how the edited-row guard is proven able to fail.

setup() {
  LIB_DIR="${RATES_TEST_LIB_DIR:-$BATS_TEST_DIRNAME/..}"
  LIB="$LIB_DIR/token-pricing-lib.sh"
  REPO="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/repo"
  mkdir -p "$REPO/.gaia/scripts"
  git init -q "$REPO"
  DIST="$REPO/.gaia/scripts/token-rates.json"
  cat >"$DIST" <<'JSON'
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
# MODE|TABLE|DIR|rc on stdout; the lib's own stderr goes to $ERR.
ERR() { printf '%s' "$BATS_TEST_TMPDIR/err"; }
prep() {
  (
    cd "$REPO" || exit 9
    bash -c 'source "$1"; shift; gaia_rates_prepare "$@"; rc=$?
      printf "%s|%s|%s|%s\n" "$GAIA_RATES_MODE" "$GAIA_RATES_TABLE" "$GAIA_RATES_DIR" "$rc"' \
      _ "$LIB" "$@"
  ) 2>"$(ERR)"
}

# Edit a JSON file in place with a jq filter.
jedit() {
  local file="$1" filter="$2"
  jq "$filter" "$file" >"$file.new" && mv "$file.new" "$file"
}

row() { jq -c --arg m "$2" '.models[$m]' "$1"; }

@test "override mode short-circuits: no state dir, nothing written" {
  run prep /somewhere/table.json
  [ "$status" -eq 0 ]
  [ "$output" = "override|/somewhere/table.json||0" ]
  [ ! -e "$REPO/.gaia/local" ]
}

@test "seed: local is byte-identical, base is JSON-equal, byte copy is byte-identical" {
  run prep ""
  [ "$status" -eq 0 ]
  [ "$output" = "local|$LOCAL|$STATE|0" ]
  cmp "$LOCAL" "$DIST"
  cmp "$COPY" "$DIST"
  jq -e --slurpfile d "$DIST" '. == $d[0]' "$BASE" >/dev/null
}

@test "prepare prints nothing to stdout and nothing to stderr on a clean seed" {
  run bash -c 'cd "$1" && source "$2" && gaia_rates_prepare "" ' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$(ERR)" ]
}

@test "second call in one shell returns the cached result without touching disk" {
  run bash -c '
    cd "$1" || exit 9
    source "$2"
    gaia_rates_prepare "" || exit 8
    first="$GAIA_RATES_TABLE"
    rm -rf "$1/.gaia/local"
    gaia_rates_prepare ""; rc=$?
    [ "$rc" -eq 0 ] || exit 7
    [ "$GAIA_RATES_TABLE" = "$first" ] || exit 6
    [ ! -e "$1/.gaia/local" ] || exit 5
    printf ok
  ' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "GAIA_RATES_STATE_DIR replaces the state dir; the distributed source stays main's" {
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/alt"
  run prep ""
  [ "$output" = "local|$BATS_TEST_TMPDIR/alt/token-rates.json|$BATS_TEST_TMPDIR/alt|0" ]
  cmp "$BATS_TEST_TMPDIR/alt/token-rates.json" "$DIST"
  [ ! -e "$REPO/.gaia/local" ]
}

@test "sync: unedited row that the distributed table changed is replaced, base follows" {
  prep "" >/dev/null
  jedit "$DIST" '.models["claude-opus-5"][0].input = 6'
  run prep ""
  [ "$status" -eq 0 ]
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":6,"output":25}]' ]
  [ "$(row "$BASE" claude-opus-5)" = '[{"input":6,"output":25}]' ]
}

@test "sync: unedited row absent from the new distributed table is kept" {
  prep "" >/dev/null
  jedit "$DIST" 'del(.models["claude-opus-4-6"])'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-4-6)" = '[{"input":5,"output":25}]' ]
  [ "$(row "$BASE" claude-opus-4-6)" = '[{"input":5,"output":25}]' ]
}

@test "sync guard: an edited row survives a distributed change, base takes the distributed value" {
  prep "" >/dev/null
  jedit "$LOCAL" '.models["claude-sonnet-5"][0].input = 9'
  jedit "$DIST" '.models["claude-sonnet-5"][0].input = 3'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-sonnet-5)" = '[{"input":9,"output":10}]' ]
  [ "$(row "$BASE" claude-sonnet-5)" = '[{"input":3,"output":10}]' ]
}

@test "sync: edited row absent from the new distributed table is kept, base unchanged" {
  prep "" >/dev/null
  jedit "$LOCAL" '.models["claude-haiku-4-5"][0].input = 7'
  jedit "$DIST" 'del(.models["claude-haiku-4-5"])'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-haiku-4-5)" = '[{"input":7,"output":5}]' ]
  [ "$(row "$BASE" claude-haiku-4-5)" = '[{"input":1,"output":5}]' ]
}

@test "sync: a row with no base row counts as edited and takes the distributed base" {
  prep "" >/dev/null
  jedit "$BASE" 'del(.models["claude-sonnet-5"])'
  jedit "$DIST" '.models["claude-sonnet-5"][0].input = 4'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-sonnet-5)" = '[{"input":2,"output":10}]' ]
  [ "$(row "$BASE" claude-sonnet-5)" = '[{"input":4,"output":10}]' ]
}

@test "sync: a model only in the distributed table is added to local and base" {
  prep "" >/dev/null
  jedit "$DIST" '.models["claude-new-1"] = [{"input": 8, "output": 40}]'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-new-1)" = '[{"input":8,"output":40}]' ]
  [ "$(row "$BASE" claude-new-1)" = '[{"input":8,"output":40}]' ]
}

@test "sync: a deleted local row stays deleted until a sync adds it back" {
  prep "" >/dev/null
  jedit "$LOCAL" 'del(.models["claude-opus-4-6"])'
  prep "" >/dev/null
  jq -e '.models | has("claude-opus-4-6") | not' "$LOCAL" >/dev/null
  jedit "$DIST" '.models["claude-opus-5"][0].input = 6'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-4-6)" = '[{"input":5,"output":25}]' ]
}

@test "sync: key order and whitespace differences alone do not make a row edited" {
  prep "" >/dev/null
  jq -c '.models["claude-opus-5"] = [{output: 25, input: 5}]' "$LOCAL" >"$LOCAL.new"
  mv "$LOCAL.new" "$LOCAL"
  jedit "$DIST" '.models["claude-opus-5"][0].input = 6'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":6,"output":25}]' ]
}

@test "sync: unedited cache_multipliers follow the distributed table" {
  prep "" >/dev/null
  jedit "$DIST" '.cache_multipliers.read = 0.2'
  prep "" >/dev/null
  [ "$(jq -c '.cache_multipliers.read' "$LOCAL")" = "0.2" ]
}

@test "sync: edited cache_multipliers are kept, base takes the distributed value" {
  prep "" >/dev/null
  jedit "$LOCAL" '.cache_multipliers.read = 0.3'
  jedit "$DIST" '.cache_multipliers.read = 0.2'
  prep "" >/dev/null
  [ "$(jq -c '.cache_multipliers.read' "$LOCAL")" = "0.3" ]
  [ "$(jq -c '.cache_multipliers.read' "$BASE")" = "0.2" ]
}

@test "sync: a missing base keeps every local row and records a base" {
  prep "" >/dev/null
  rm "$BASE"
  jedit "$DIST" '.models["claude-opus-5"][0].input = 6'
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":5,"output":25}]' ]
  [ -s "$BASE" ]
  [ "$(row "$BASE" claude-opus-5)" = '[{"input":6,"output":25}]' ]
}

@test "sync: a merged table equal to the distributed one writes the distributed bytes verbatim" {
  prep "" >/dev/null
  jq '.models["claude-opus-5"][0].input = 6' "$DIST" | sed 's/^  /\t/' >"$DIST.new"
  mv "$DIST.new" "$DIST"
  prep "" >/dev/null
  cmp "$LOCAL" "$DIST"
  cmp "$COPY" "$DIST"
}

@test "sync: an interrupted sync (local written, base and byte copy stale) converges" {
  prep "" >/dev/null
  cp "$BASE" "$BATS_TEST_TMPDIR/base.stale"
  cp "$COPY" "$BATS_TEST_TMPDIR/copy.stale"
  jedit "$DIST" '.models["claude-opus-5"][0].input = 6'
  prep "" >/dev/null
  cp "$BATS_TEST_TMPDIR/base.stale" "$BASE"
  cp "$BATS_TEST_TMPDIR/copy.stale" "$COPY"
  prep "" >/dev/null
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":6,"output":25}]' ]
  [ "$(row "$BASE" claude-opus-5)" = '[{"input":6,"output":25}]' ]
  cmp "$COPY" "$DIST"
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.after"
  prep "" >/dev/null
  cmp "$LOCAL" "$BATS_TEST_TMPDIR/local.after"
}

# Shared body: corrupt the local table with the bytes in $1, re-seed, check the
# preserved copy and the single stderr line.
corrupt_case() {
  prep "" >/dev/null
  printf '%s' "$1" >"$LOCAL"
  prep "" >/dev/null
  [ "$(wc -l <"$(ERR)" | tr -d ' ')" = "1" ]
  local preserved
  preserved="$(sed -n 's/.*preserved as \(.*\); re-seeded$/\1/p' "$(ERR)")"
  [ -n "$preserved" ]
  [ -e "$preserved" ]
  [ "$(cat "$preserved")" = "$1" ]
  cmp "$LOCAL" "$DIST"
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
  prep "" >/dev/null
  printf 'first-corruption' >"$LOCAL"
  prep "" >/dev/null
  printf 'second-corruption' >"$LOCAL"
  prep "" >/dev/null
  local n
  n="$(find "$STATE" -name 'token-rates.json.corrupt.*' | wc -l | tr -d ' ')"
  [ "$n" = "2" ]
  grep -lq 'first-corruption' "$STATE"/token-rates.json.corrupt.*
  grep -lq 'second-corruption' "$STATE"/token-rates.json.corrupt.*
}

@test "corrupt local: copies are pruned to the 5 newest" {
  prep "" >/dev/null
  local i
  for i in 1 2 3 4 5 6 7; do
    printf 'old-%s' "$i" >"$STATE/token-rates.json.corrupt.100000000$i.AAAAAA"
  done
  printf 'fresh-corruption' >"$LOCAL"
  prep "" >/dev/null
  local n
  n="$(find "$STATE" -name 'token-rates.json.corrupt.*' | wc -l | tr -d ' ')"
  [ "$n" = "5" ]
  grep -lq 'fresh-corruption' "$STATE"/token-rates.json.corrupt.*
  [ ! -e "$STATE/token-rates.json.corrupt.1000000001.AAAAAA" ]
  [ -e "$STATE/token-rates.json.corrupt.1000000007.AAAAAA" ]
}

@test "readonly: an unresolvable main root prices the tree's own table, writes nothing" {
  local bare="$BATS_TEST_TMPDIR/bare.git" wt="$BATS_TEST_TMPDIR/wt" c
  git init -q --bare "$bare"
  c="$(git -C "$bare" commit-tree "$(git -C "$bare" hash-object -t tree /dev/null)" -m x)"
  git -C "$bare" update-ref refs/heads/main "$c"
  git -C "$bare" worktree add -q "$wt" main
  mkdir -p "$wt/.gaia/scripts"
  cp "$DIST" "$wt/.gaia/scripts/token-rates.json"
  wt="$(cd "$wt" && pwd -P)"
  run bash -c 'cd "$1" && source "$2" && gaia_rates_prepare ""; rc=$?
    printf "%s|%s|%s|%s\n" "$GAIA_RATES_MODE" "$GAIA_RATES_TABLE" "$GAIA_RATES_DIR" "$rc"' _ "$wt" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "readonly|$wt/.gaia/scripts/token-rates.json||0" ]
  [ ! -e "$wt/.gaia/local" ]
}

@test "unwritable state dir falls back to readonly on the main distributed table" {
  mkdir -p "$STATE"
  chmod 500 "$STATE"
  run prep ""
  chmod 700 "$STATE"
  [ "$status" -eq 0 ]
  [ "$output" = "readonly|$DIST||0" ]
}

@test "no distributed table and no local table: returns 1 with no table" {
  rm "$DIST"
  run prep ""
  [ "$output" = "|||1" ]
}

@test "an unreadable distributed table leaves a readable local table priced as is" {
  prep "" >/dev/null
  printf '{bad' >"$DIST"
  run prep ""
  [ "$output" = "local|$LOCAL|$STATE|0" ]
  [ "$(row "$LOCAL" claude-opus-5)" = '[{"input":5,"output":25}]' ]
}

@test "temp files are same-directory dotfiles and none are left behind" {
  prep "" >/dev/null
  jedit "$DIST" '.models["claude-opus-5"][0].input = 6'
  prep "" >/dev/null
  local n
  n="$(find "$STATE" -name '.token-rates*.tmp.*' | wc -l | tr -d ' ')"
  [ "$n" = "0" ]
}
