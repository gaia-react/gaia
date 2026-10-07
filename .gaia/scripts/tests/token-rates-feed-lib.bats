#!/usr/bin/env bats
#
# Unit suite for .gaia/scripts/token-rates-feed-lib.sh: gaia_rates_heal, the
# bounded fetch of the public distributed table when the local rate table lacks
# a model the run priced, plus the guard that the default feed URL names a file
# tracked on main.
#
# Every test builds a throwaway state dir under $BATS_TEST_TMPDIR through the
# GAIA_RATES_STATE_DIRECTORY seam and calls gaia_rates_prepare then gaia_rates_heal in
# one shell (the libs keep per-process state). CI exports
# GAIA_RATES_FEED_DISABLE=1 workflow-wide, so setup unsets it: a test that wants
# the switch on sets it back. Most validation tests read the feed through a
# file:// URL, which reaches the same code as https; the TLS stub in
# fixtures/rates-feed/stub-lib.sh covers the network paths.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
FEED_LIBRARY="$REPO_ROOT/.gaia/scripts/token-rates-feed-lib.sh"
FIXTURES="$BATS_TEST_DIRNAME/fixtures/rates-feed"

setup() {
  # shellcheck disable=SC1091
  source "$FIXTURES/stub-lib.sh"
  unset GAIA_RATES_FEED_DISABLE GAIA_RATES_FEED_URL
  FIXREPO="$BATS_TEST_TMPDIR/repo"
  STATE="$BATS_TEST_TMPDIR/state"
  LOCAL="$STATE/token-rates.json"
  BASE="$STATE/token-rates.base.json"
  FEED_STATE_FILE="$STATE/token-rates.feed-state.json"
  ERROR_FILE="$BATS_TEST_TMPDIR/err"
  mkdir -p "$FIXREPO/.gaia/scripts" "$STATE"
  cat >"$FIXREPO/.gaia/scripts/token-rates.json" <<'JSON'
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": {
    "claude-opus-5": [ { "input": 5, "output": 25 } ],
    "claude-sonnet-5": [ { "input": 2, "output": 10 } ],
    "claude-old-1": [ { "input": 1, "output": 5, "effective_through": "2020-01-01" } ]
  }
}
JSON
  export GAIA_RATES_STATE_DIRECTORY="$STATE"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/.gaia/scripts/token-pricing-lib.sh"
  heal_exit_status=0
}

teardown() {
  rates_stub_stop
}

# ---------- helpers ----------

prepare_local() {
  gaia_rates_prepare "" "$FIXREPO" || return 1
  [[ "$GAIA_RATES_MODE" == "local" ]] || return 1
}

# Run heal in this shell; its exit status lands in $heal_exit_status, its stderr in $ERROR_FILE.
heal() {
  heal_exit_status=0
  gaia_rates_heal "$1" 2>"$ERROR_FILE" || heal_exit_status=$?
}

# A second process: the per-process attempt and warning latches reset.
new_process() {
  _GAIA_RATES_FEED_TRIED=0
  _GAIA_RATES_FEED_WARNED=0
}

start_stub() {
  rates_stub_start_or_skip tls "$@"
}

# feed_file <json> : write a feed body and point the override at it via file://.
feed_file() {
  printf '%s' "$1" >"$BATS_TEST_TMPDIR/feed.json"
  export GAIA_RATES_FEED_URL="file://$BATS_TEST_TMPDIR/feed.json"
}

# fixture_body <key>...: a feed body carrying only those rows of feed-rows.json.
fixture_body() {
  jq -c '{models: (.models | with_entries(select(.key as $model_key | $ARGS.positional | index($model_key))))}' \
    "$FIXTURES/feed-rows.json" --args "$@"
}

local_row() {
  jq -c --arg model "$1" '.models[$model]' "$LOCAL"
}

base_row() {
  jq -c --arg model "$1" '.models[$model]' "$BASE"
}

local_has() {
  jq -e --arg model "$1" '.models | has($model)' "$LOCAL" >/dev/null
}

state_failed_at() {
  jq -r '.failed_at' "$FEED_STATE_FILE"
}

set_state() {
  printf '%s' "$1" >"$FEED_STATE_FILE"
}

feed_body_leftovers() {
  find "$STATE" -maxdepth 1 -name '.token-rates.feed-body.tmp.*' | wc -l | tr -d ' '
}

stderr_lines() {
  grep -c '^token-pricing:' "$ERROR_FILE" || true
}

# The row assertions the C6 tests share.
assert_row_rejected() {
  local key="$1" before
  prepare_local
  feed_file "$(fixture_body "$key")"
  before="$BATS_TEST_TMPDIR/local.before"
  cp "$LOCAL" "$before"
  heal "[\"$key\"]"
  [[ "$heal_exit_status" -eq 1 ]] || { echo "heal_exit_status=$heal_exit_status, expected 1 for $key" >&2; return 1; }
  cmp -s "$before" "$LOCAL" || { echo "local table changed for $key" >&2; return 1; }
  if local_has "$key"; then echo "$key was written" >&2; return 1; fi
  # The same response still heals a valid neighbour.
  new_process
  rm -f "$FEED_STATE_FILE"
  feed_file "$(fixture_body claude-good-1 "$key")"
  heal "[\"claude-good-1\",\"$key\"]"
  [[ "$heal_exit_status" -eq 0 ]] || { echo "neighbour did not heal (heal_exit_status=$heal_exit_status) for $key" >&2; return 1; }
  local_has claude-good-1 || return 1
  if local_has "$key"; then echo "$key was written beside a valid row" >&2; return 1; fi
  return 0
}

# ---------- heal: the accepted path ----------

@test "heal adds a valid row with the feed mark, mirrors it into the base, and returns 0" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(rates_stub_count)" = "1" ]
  [ "$(local_row claude-opus-6)" = '[{"input":7,"output":35,"source":"feed"}]' ]
  [ "$(base_row claude-opus-6)" = '[{"input":7,"output":35,"source":"feed"}]' ]
}

@test "heal leaves the distributed rows, the cache multipliers, and unrequested feed models alone" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(local_row claude-opus-5)" = '[{"input":5,"output":25}]' ]
  jq -e '.cache_multipliers == {"read":0.1,"write_5m":1.25,"write_1h":2}' "$LOCAL" >/dev/null
  if local_has claude-sonnet-6; then return 1; fi
  true
}

@test "heal sends one plain GET: the request line and the default curl headers only" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(cat "$RATES_STUB_REQUESTS")" = "GET /gaia-react/gaia/main/.gaia/scripts/token-rates.json HTTP/1.1" ]
  # Host, User-Agent, Accept and nothing that names a model or the caller.
  [ "$(awk '{print $2}' "$RATES_STUB_HEADERS" | sort | tr '\n' ' ')" = "Accept: Host: User-Agent: " ]
  if grep -qi 'opus' "$RATES_STUB_HEADERS"; then return 1; fi
  true
}

@test "heal accepts a file:// override and prices a row from it" {
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(local_row claude-opus-6)" = '[{"input":7,"output":35,"source":"feed"}]' ]
}

@test "heal accepts a window whose effective_through is in the future and a mixed expired-plus-current row" {
  prepare_local
  feed_file "$(fixture_body claude-future-window claude-mixed-windows)"
  heal '["claude-future-window","claude-mixed-windows"]'
  [ "$heal_exit_status" -eq 0 ]
  local_has claude-future-window
  local_has claude-mixed-windows
  [ "$(local_row claude-mixed-windows | jq -c 'map(.source)')" = '["feed","feed"]' ]
}

@test "heal writes the base row even when the base file was missing" {
  prepare_local
  rm -f "$BASE"
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(base_row claude-opus-6)" = '[{"input":7,"output":35,"source":"feed"}]' ]
}

@test "heal removes its body temp file after a success and after a failure" {
  prepare_local
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(feed_body_leftovers)" = "0" ]
  new_process
  feed_file 'not json'
  heal '["claude-newer-1"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(feed_body_leftovers)" = "0" ]
}

# ---------- C6 row validation: one test per rule ----------

@test "C6 rejects a negative input rate" {
  assert_row_rejected claude-bad-neg-input
}

@test "C6 rejects a non-numeric input rate" {
  assert_row_rejected claude-bad-string-input
}

@test "C6 rejects a window missing its output rate" {
  assert_row_rejected claude-bad-missing-output
}

@test "C6 rejects a window carrying an unknown key" {
  assert_row_rejected claude-bad-extra-key
}

@test "C6 rejects a feed row that already carries the source key" {
  assert_row_rejected claude-bad-source-key
}

@test "C6 rejects a cache_read_multiplier above 1" {
  assert_row_rejected claude-bad-multiplier
}

@test "C6 rejects a null cache_read_multiplier" {
  assert_row_rejected claude-bad-null-multiplier
}

@test "C6 rejects an effective_through in the wrong format" {
  assert_row_rejected claude-bad-date-format
}

@test "C6 rejects a non-string effective_through" {
  assert_row_rejected claude-bad-date-type
}

@test "C6 rejects a row whose every window has expired" {
  assert_row_rejected claude-bad-expired
}

@test "C6 rejects an empty window array" {
  assert_row_rejected claude-bad-empty-array
}

@test "C6 rejects a row that is not an array" {
  assert_row_rejected claude-bad-not-array
}

@test "C6 rejects a window that is not an object" {
  assert_row_rejected claude-bad-element
}

@test "C6 rejects an infinite input rate" {
  assert_row_rejected claude-bad-huge
}

@test "C6 tests cover every claude-bad row the fixture carries" {
  local fixture_row_count tested_row_count
  fixture_row_count="$(jq '[.models | keys[] | select(startswith("claude-bad-"))] | length' "$FIXTURES/feed-rows.json")"
  tested_row_count="$(grep -c '^@test "C6 rejects' "$BATS_TEST_FILENAME")"
  [ "$fixture_row_count" -gt 0 ]
  [ "$fixture_row_count" -eq "$tested_row_count" ]
}

@test "C6 never writes a model id outside the claude- namespace or with upper-case, whatever the feed offers" {
  prepare_local
  feed_file "$(fixture_body claude-good-1 claude-Bad-Upper gpt-5)"
  heal '["claude-good-1","claude-Bad-Upper","gpt-5"]'
  [ "$heal_exit_status" -eq 0 ]
  local_has claude-good-1
  if local_has claude-Bad-Upper; then return 1; fi
  if local_has gpt-5; then return 1; fi
  true
}

@test "C6 heals every valid row in a response that mixes valid and invalid rows" {
  local bad_ids ids expected
  prepare_local
  bad_ids="$(jq -c '[.models | keys[] | select(startswith("claude-bad-"))]' "$FIXTURES/feed-rows.json")"
  [ "$(jq 'length' <<<"$bad_ids")" -ge 14 ]
  ids="$(jq -c '. + ["claude-good-1","claude-future-window","claude-mixed-windows"]' <<<"$bad_ids")"
  feed_file "$(jq -c . "$FIXTURES/feed-rows.json")"
  heal "$ids"
  [ "$heal_exit_status" -eq 0 ]
  expected='["claude-future-window","claude-good-1","claude-mixed-windows"]'
  [ "$(jq -c --argjson ids "$ids" '[.models | keys[] | select(. as $model_key | $ids | index($model_key))] | sort' "$LOCAL")" = "$expected" ]
}

@test "a model the feed does not price is recorded as not found and the table is untouched" {
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  heal '["claude-preview-9"]'
  [ "$heal_exit_status" -eq 1 ]
  cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL"
  [ "$(jq -r '.failed_at' "$FEED_STATE_FILE")" = "null" ]
  jq -e '.not_found["claude-preview-9"] | type == "number"' "$FEED_STATE_FILE" >/dev/null
}

# ---------- C5 early exits: zero requests ----------

@test "no request when the mode is not local" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  GAIA_RATES_MODE="readonly"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
}

@test "no request in override mode" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  cp "$FIXREPO/.gaia/scripts/token-rates.json" "$BATS_TEST_TMPDIR/override.json"
  gaia_rates_prepare "$BATS_TEST_TMPDIR/override.json" "$FIXREPO"
  [ "$GAIA_RATES_MODE" = "override" ]
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
}

@test "no request when every priced model is already in the local table" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["claude-opus-5","claude-sonnet-5"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
}

@test "no request for an id outside claude-, an invalid claude- id, or an empty list" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["gpt-5","claude-Upper-1","claude-a;b","claude-",""]'
  [ "$heal_exit_status" -eq 1 ]
  heal '[]'
  [ "$heal_exit_status" -eq 1 ]
  heal 'not json'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
}

@test "a present but expired row is not absent, so it triggers no request" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  local_has claude-old-1
  heal '["claude-old-1"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
}

@test "GAIA_RATES_FEED_DISABLE=1 sends no request and leaves the table alone" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  export GAIA_RATES_FEED_DISABLE=1
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
  cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL"
}

@test "GAIA_RATES_FEED_DISABLE=true is not the switch: the request still goes out" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  export GAIA_RATES_FEED_DISABLE=true
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(rates_stub_count)" = "1" ]
}

@test "a second call in the same process makes no second request" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["claude-preview-9"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "1" ]
  heal '["claude-preview-10"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "1" ]
}

@test "a rejected scheme sends no request and prints one line naming the sanitized scheme" {
  rates_stub_start_or_skip plain "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_PLAIN_URL"
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(wc -l <"$RATES_PLAIN_REQUESTS" | tr -d ' ')" = "0" ]
  [ "$(stderr_lines)" = "1" ]
  grep -qF "scheme 'http' not accepted" "$ERROR_FILE"
  if local_has claude-opus-6; then return 1; fi
  true
}

@test "a hostile scheme is stripped to [a-z0-9+.-] before it is printed, and a colon-less URL prints none" {
  prepare_local
  export GAIA_RATES_FEED_URL='FTP;$(touch pwned):x'
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(stderr_lines)" = "1" ]
  grep -qF "scheme 'ftptouchpwned' not accepted" "$ERROR_FILE"
  new_process
  export GAIA_RATES_FEED_URL='nonsense'
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  grep -qF "scheme 'none' not accepted" "$ERROR_FILE"
}

@test "an empty GAIA_RATES_FEED_URL falls back to the default URL, which is https" {
  prepare_local
  export GAIA_RATES_FEED_URL=""
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s"\ncat "%s"\n' "$BATS_TEST_TMPDIR/argv" "$FIXTURES/feed-valid.json" >"$shim/curl"
  chmod +x "$shim/curl"
  PATH="$shim:$PATH" heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(tail -1 "$BATS_TEST_TMPDIR/argv")" = "$GAIA_RATES_FEED_DEFAULT_URL" ]
}

@test "no curl on PATH: no request, one line, table untouched" {
  local bin="$BATS_TEST_TMPDIR/nocurl" tool
  mkdir -p "$bin"
  for tool in jq date tr cut mktemp rm dirname basename mv cp cat wc; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  prepare_local
  export GAIA_RATES_FEED_URL="file://$FIXTURES/feed-valid.json"
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal_exit_status=0
  PATH="$bin" gaia_rates_heal '["claude-opus-6"]' 2>"$ERROR_FILE" || heal_exit_status=$?
  [ "$heal_exit_status" -eq 1 ]
  [ "$(stderr_lines)" = "1" ]
  grep -qF "curl not found" "$ERROR_FILE"
  cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL"
}

@test "an active failure backoff sends no request, and an expired one does" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  set_state "{\"failed_at\": $(($(date +%s) - 100)), \"not_found\": {}}"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
  set_state "{\"failed_at\": $(($(date +%s) - 4000)), \"not_found\": {}}"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(rates_stub_count)" = "1" ]
  [ "$(state_failed_at)" = "null" ]
}

@test "a recent not_found entry for every absent model sends no request; one unrecorded model does" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  set_state "{\"failed_at\": null, \"not_found\": {\"claude-preview-9\": $(($(date +%s) - 100))}}"
  heal '["claude-preview-9"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "0" ]
  heal '["claude-preview-9","claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(rates_stub_count)" = "1" ]
}

@test "a not_found entry older than the backoff no longer suppresses the request" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  set_state "{\"failed_at\": null, \"not_found\": {\"claude-opus-6\": $(($(date +%s) - 4000))}}"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(rates_stub_count)" = "1" ]
}

@test "an unreadable feed state file is the empty state" {
  start_stub serve "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  set_state 'this is {not json'
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(rates_stub_count)" = "1" ]
}

# ---------- failure paths: failed_at set, table byte-identical ----------

assert_failed_untouched() {
  [[ "$heal_exit_status" -eq 1 ]] || { echo "heal_exit_status=$heal_exit_status, expected 1" >&2; return 1; }
  cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL" || { echo "local table changed" >&2; return 1; }
  [[ "$(state_failed_at)" =~ ^[0-9]+$ ]] || { echo "failed_at not an integer" >&2; return 1; }
  [[ "$(stderr_lines)" = "1" ]] || { echo "expected exactly one token-pricing line" >&2; return 1; }
  if grep -q 'claude-' "$ERROR_FILE"; then echo "a model id reached stderr" >&2; return 1; fi
  [[ "$(feed_body_leftovers)" = "0" ]] || { echo "body temp file left behind" >&2; return 1; }
  return 0
}

@test "a refused connection fails closed" {
  prepare_local
  local refuse_url
  refuse_url="$(rates_stub_refuse_url)"
  export GAIA_RATES_FEED_URL="$refuse_url"
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  assert_failed_untouched
}

@test "an HTTP 500 carrying a valid body fails closed" {
  start_stub status500 "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  assert_failed_untouched
  [ "$(rates_stub_count)" = "1" ]
}

@test "a non-JSON body fails closed" {
  start_stub nonjson
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  assert_failed_untouched
}

@test "a body with no models object fails closed" {
  start_stub nomodels
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  assert_failed_untouched
}

@test "an oversize body fails closed" {
  start_stub oversize
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  assert_failed_untouched
}

@test "an oversize file:// body fails closed even where curl declares no length" {
  prepare_local
  {
    printf '{"models":{"claude-opus-6":[{"input":7,"output":35}]},"pad":"'
    head -c 300000 /dev/zero | tr '\0' 'x'
    printf '"}'
  } >"$BATS_TEST_TMPDIR/big.json"
  export GAIA_RATES_FEED_URL="file://$BATS_TEST_TMPDIR/big.json"
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  heal '["claude-opus-6"]'
  assert_failed_untouched
}

@test "the lib enforces the size cap itself when curl does not" {
  local shim="$BATS_TEST_TMPDIR/shim-big"
  mkdir -p "$shim"
  {
    printf '{"models":{"claude-opus-6":[{"input":7,"output":35}]},"pad":"'
    head -c 300000 /dev/zero | tr '\0' 'x'
    printf '"}'
  } >"$BATS_TEST_TMPDIR/big-body.json"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$BATS_TEST_TMPDIR/big-body.json" >"$shim/curl"
  chmod +x "$shim/curl"
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  PATH="$shim:$PATH" heal '["claude-opus-6"]'
  assert_failed_untouched
}

@test "a failure starts the backoff: the next process sends no request" {
  start_stub status500 "$FIXTURES/feed-valid.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "1" ]
  new_process
  rates_stub_set_mode serve "$FIXTURES/feed-valid.json"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(rates_stub_count)" = "1" ]
  if local_has claude-opus-6; then return 1; fi
  true
}

@test "a stalled handshake or body costs no more than the bounded ceiling over a feed-disabled baseline" {
  local start_seconds first_end_seconds second_end_seconds baseline stalled mode
  start_stub stall-handshake
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  prepare_local
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  for mode in stall-handshake stall-body; do
    rates_stub_set_mode "$mode" "$FIXTURES/feed-valid.json"
    new_process
    rm -f "$FEED_STATE_FILE"
    export GAIA_RATES_FEED_DISABLE=1
    start_seconds="$(date +%s)"
    heal '["claude-opus-6"]'
    first_end_seconds="$(date +%s)"
    unset GAIA_RATES_FEED_DISABLE
    new_process
    heal '["claude-opus-6"]'
    second_end_seconds="$(date +%s)"
    baseline=$((first_end_seconds - start_seconds))
    stalled=$((second_end_seconds - first_end_seconds))
    [ "$heal_exit_status" -eq 1 ]
    [ "$((stalled - baseline))" -le 6 ]
    cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL"
  done
  [ "$(rates_stub_count)" = "2" ]
}

# ---------- R10 refresh ----------

@test "an unedited feed-marked row is refreshed from a later feed response" {
  prepare_local
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  new_process
  rm -f "$FEED_STATE_FILE"
  feed_file '{"models":{"claude-opus-6":[{"input":8,"output":40}]}}'
  heal '["claude-opus-6","claude-zzz-1"]'
  [ "$heal_exit_status" -eq 0 ]
  [ "$(local_row claude-opus-6)" = '[{"input":8,"output":40,"source":"feed"}]' ]
  [ "$(base_row claude-opus-6)" = '[{"input":8,"output":40,"source":"feed"}]' ]
}

@test "an edited feed-marked row is not refreshed" {
  local edited
  prepare_local
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  edited="$(jq -c '.models["claude-opus-6"][0].input = 99' "$LOCAL")"
  printf '%s' "$edited" >"$LOCAL"
  new_process
  rm -f "$FEED_STATE_FILE"
  feed_file '{"models":{"claude-opus-6":[{"input":8,"output":40}]}}'
  heal '["claude-opus-6","claude-zzz-1"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(jq -c '.models["claude-opus-6"][0].input' "$LOCAL")" = "99" ]
}

@test "a distributed (unmarked) row is never rewritten by the feed" {
  prepare_local
  feed_file '{"models":{"claude-opus-5":[{"input":1,"output":1}]}}'
  heal '["claude-zzz-1"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(local_row claude-opus-5)" = '[{"input":5,"output":25}]' ]
}

@test "a refresh with an invalid feed row leaves the marked row as it was" {
  prepare_local
  feed_file "$(cat "$FIXTURES/feed-valid.json")"
  heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  new_process
  rm -f "$FEED_STATE_FILE"
  feed_file '{"models":{"claude-opus-6":[{"input":-8,"output":40}]}}'
  heal '["claude-opus-6","claude-zzz-1"]'
  [ "$heal_exit_status" -eq 1 ]
  [ "$(local_row claude-opus-6)" = '[{"input":7,"output":35,"source":"feed"}]' ]
}

# ---------- argv ----------

make_curl_shim() {
  SHIM="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$SHIM"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s"\ncat "%s"\n' \
    "$BATS_TEST_TMPDIR/argv" "$FIXTURES/feed-valid.json" >"$SHIM/curl"
  chmod +x "$SHIM/curl"
}

@test "curl runs with exactly the pinned flags and the default URL when no override is set" {
  local argv
  make_curl_shim
  prepare_local
  PATH="$SHIM:$PATH" heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  argv="$(tr '\n' ' ' <"$BATS_TEST_TMPDIR/argv")"
  [ "$argv" = "-q -fsS --proto =https --connect-timeout 2 --max-time 4 --max-filesize 262144 $GAIA_RATES_FEED_DEFAULT_URL " ]
  grep -qx -- '-q' "$BATS_TEST_TMPDIR/argv"
  grep -qx -- '-fsS' "$BATS_TEST_TMPDIR/argv"
  grep -qx -- '=https' "$BATS_TEST_TMPDIR/argv"
  grep -qx -- '2' "$BATS_TEST_TMPDIR/argv"
  grep -qx -- '4' "$BATS_TEST_TMPDIR/argv"
  grep -qx -- '262144' "$BATS_TEST_TMPDIR/argv"
  # Absent: follow redirects, headers, user agent, body, output file, query string.
  grep -qx -- '-L' "$BATS_TEST_TMPDIR/argv" && return 1
  grep -qx -- '-H' "$BATS_TEST_TMPDIR/argv" && return 1
  grep -qx -- '-A' "$BATS_TEST_TMPDIR/argv" && return 1
  grep -qx -- '-d' "$BATS_TEST_TMPDIR/argv" && return 1
  grep -qx -- '-o' "$BATS_TEST_TMPDIR/argv" && return 1
  grep -qF -- '?' "$BATS_TEST_TMPDIR/argv" && return 1
  true
}

@test "curl runs with --proto =file for a file:// override" {
  local argv
  make_curl_shim
  prepare_local
  export GAIA_RATES_FEED_URL="file://$FIXTURES/feed-valid.json"
  PATH="$SHIM:$PATH" heal '["claude-opus-6"]'
  [ "$heal_exit_status" -eq 0 ]
  argv="$(tr '\n' ' ' <"$BATS_TEST_TMPDIR/argv")"
  [ "$argv" = "-q -fsS --proto =file --connect-timeout 2 --max-time 4 --max-filesize 262144 file://$FIXTURES/feed-valid.json " ]
}

# ---------- UAT-018: the default feed path names a tracked file ----------

# 0 only when the path after /gaia-react/gaia/main/ in the lib's default URL
# constant is a file tracked in this repository.
feed_path_tracked() {
  local library_file="$1" url path
  url="$(grep -E "^GAIA_RATES_FEED_DEFAULT_URL='" "$library_file" | head -1 | sed -E "s/^GAIA_RATES_FEED_DEFAULT_URL='([^']*)'.*/\\1/")"
  [[ -n "$url" ]] || return 1
  case "$url" in
    *"/gaia-react/gaia/main/"?*) ;;
    *) return 1 ;;
  esac
  path="${url#*/gaia-react/gaia/main/}"
  git -C "$REPO_ROOT" ls-files --error-unmatch -- "$path" >/dev/null 2>&1
}

@test "UAT-018: the default feed URL names a file tracked in the repository" {
  run feed_path_tracked "$FEED_LIBRARY"
  [ "$status" -eq 0 ]
}

@test "UAT-018: the guard fails when the constant names an untracked path" {
  local copy="$BATS_TEST_TMPDIR/feed-lib-untracked.sh"
  sed "s#/gaia-react/gaia/main/.gaia/scripts/token-rates.json#/gaia-react/gaia/main/.gaia/scripts/token-rates-never-tracked.json#" "$FEED_LIBRARY" >"$copy"
  grep -qF 'token-rates-never-tracked.json' "$copy"
  run feed_path_tracked "$copy"
  [ "$status" -eq 1 ]
}

@test "UAT-018: the guard fails when the distributed table has moved" {
  local copy="$BATS_TEST_TMPDIR/feed-lib-moved.sh"
  sed "s#/gaia-react/gaia/main/.gaia/scripts/token-rates.json#/gaia-react/gaia/main/.gaia/scripts/token-rates-moved.json#" "$FEED_LIBRARY" >"$copy"
  grep -qF 'token-rates-moved.json' "$copy"
  run feed_path_tracked "$copy"
  [ "$status" -eq 1 ]
}

@test "UAT-018: the guard fails when the constant is missing or names another repository" {
  local copy="$BATS_TEST_TMPDIR/feed-lib-missing.sh"
  grep -v '^GAIA_RATES_FEED_DEFAULT_URL=' "$FEED_LIBRARY" >"$copy"
  run feed_path_tracked "$copy"
  [ "$status" -eq 1 ]
  sed "s#/gaia-react/gaia/main/#/someone/else/main/#" "$FEED_LIBRARY" >"$copy"
  run feed_path_tracked "$copy"
  [ "$status" -eq 1 ]
}

# rates_stub_start_or_skip is what keeps a broken stub from reporting green: a
# skip reads as `ok`, so these pin the two arms that must fail instead.

@test "stub start fails, not skips, when the tools are present but the stub cannot start" {
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' >"$shim/openssl"
  chmod +x "$shim/openssl"
  PATH="$shim:$PATH" run rates_stub_start_or_skip tls serve "$FIXTURES/feed-valid.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not create the throwaway cert"* ]]
}

@test "stub start fails, not skips, on a CI runner missing a tool" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v python3)" "$bin/python3"
  GITHUB_ACTIONS=true PATH="$bin" run rates_stub_start_or_skip tls serve
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing on a CI runner"* ]]
}
