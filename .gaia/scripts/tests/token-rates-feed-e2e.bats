#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (this suite uses `run --separate-stderr`).
bats_require_minimum_version 1.5.0
#
# End-to-end suite for the rates-feed heal: token-tally.sh (--action command and
# --action review) and token-rollup.sh, driven as real processes against a
# machine-local rate table, with the feed served by the TLS stub in
# fixtures/rates-feed/stub-lib.sh, a file:// URL, or a curl shim. One test per
# UAT of the self-healing rate table; the test name leads with the UAT id.
#
# Conventions. Every test builds a temp git repo with the repository's real
# .gitignore and a distributed table (fixtures/rates-feed-e2e/dist-table.json)
# committed at .gaia/scripts/token-rates.json, and runs the real scripts from
# inside it. setup() points GAIA_RATES_STATE_DIR at a per-test dir and sets
# GAIA_RATES_FEED_DISABLE=1, so no test reaches the network by accident; a test
# that expects a request calls feed_on, which unsets the variable (CI exports
# =1 workflow-wide) and sets GAIA_RATES_FEED_URL. The one test that leaves the
# URL unset (UAT-019) puts a curl shim first on PATH. Every request goes to
# 127.0.0.1, a file:// URL, or the shim.
#
# Every zero-request assertion is paired with a run that records exactly one
# request against the same stub, so a zero cannot come from a stub that never
# counts.
#
# Hand-computed oracle (rates are $ per million tokens; the fixtures carry no
# cache tokens, so only input and output price):
#
#   dist-table.json       claude-opus-5 5/25, claude-haiku-5 1/5
#   feed-opus6.json       claude-opus-6 7/35
#   feed-opus67.json      claude-opus-6 7/35, claude-opus-7 9/45
#   feed-corrected.json   claude-opus-6 8/40, claude-opus-6-1 8/40, claude-opus-7 9/45
#
#   projects-opus6   one claude-opus-6 turn, 1,000,000 in / 100,000 out
#                    = 7 + 3.5 = $10.50, ~1.1M tokens
#   projects-opus7   one claude-opus-7 turn, same tokens; at 9/45 = 9 + 4.5 = $13.50
#   projects-preview9 one claude-preview-9 turn, same tokens (no table prices it)
#   projects-mixed   claude-opus-5 1,000,000 in / 200,000 out = 5 + 5 = $10.00
#                    plus the opus-6 turn above = $20.50, ~2.3M tokens
#   projects-review  two code-audit-frontend sidecars (rev0001, rev0002), each
#                    holding the mixed pair of turns: $20.50 with opus-6 priced,
#                    $10.00 without it
#   ledger-opus67    one execute row (SPEC-290) whose by_model is the opus-6 and
#                    opus-7 turns above: 10.5 + 13.5 = $24.00
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md (explicit
# `|| return 1` on every assertion, no `!`-negation off the last line).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/.gaia/scripts"
TALLY="$SCRIPTS/token-tally.sh"
ROLLUP="$SCRIPTS/token-rollup.sh"
FX="$BATS_TEST_DIRNAME/fixtures/rates-feed-e2e"
STUBLIB="$BATS_TEST_DIRNAME/fixtures/rates-feed/stub-lib.sh"

OPUS6_MARKER='(lower bound: unpriced model(s) claude-opus-6)'
PREVIEW9_MARKER='(lower bound: unpriced model(s) claude-preview-9)'
BOTH_MARKER='(lower bound: unpriced model(s) claude-opus-6, claude-opus-7)'

setup() {
  # shellcheck source=fixtures/rates-feed/stub-lib.sh
  source "$STUBLIB"
  unset GAIA_RATES_FEED_URL
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  use_state "$GAIA_RATES_STATE_DIR"

  LEDGER="$BATS_TEST_TMPDIR/ledger.jsonl"
  REVLEDGER="$BATS_TEST_TMPDIR/review-ledger.jsonl"
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  FIXREPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$FIXREPO/.gaia/scripts"
  git -C "$FIXREPO" init -q
  cp "$REPO_ROOT/.gitignore" "$FIXREPO/.gitignore"
  cp "$FX/dist-table.json" "$FIXREPO/.gaia/scripts/token-rates.json"
  git -C "$FIXREPO" add -A
  git -C "$FIXREPO" commit -q -m "fixture: distributed table"
  cd "$FIXREPO" || return 1
}

teardown() {
  rates_stub_stop
}

# ---------- helpers ----------

# Point every state path at <dir>; the seam variable is what the scripts read.
use_state() {
  STATE="$1"
  LOCAL="$STATE/token-rates.json"
  BASE="$STATE/token-rates.base.json"
  FSTATE="$STATE/token-rates.feed-state.json"
  export GAIA_RATES_STATE_DIR="$STATE"
}

feed_on() {
  unset GAIA_RATES_FEED_DISABLE
  export GAIA_RATES_FEED_URL="$1"
}

start_stub() {
  rates_stub_start_or_skip tls "$@"
}

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

# Seeds the local table, base, and distributed byte copy from the fixture repo,
# the way the first priced run does, without pricing anything.
seed_state() {
  bash -c '. "$1"; gaia_rates_prepare "" "$2"' _ "$SCRIPTS/token-pricing-lib.sh" "$FIXREPO" \
    || return 1
  [[ -f "$LOCAL" && -f "$BASE" ]] || return 1
}

# table_id <file>: the rate_table_id the lib computes over that file's bytes.
table_id() {
  bash -c '. "$1"; gaia_rate_table_id "$2"' _ "$SCRIPTS/token-pricing-lib.sh" "$1"
}

# jq_edit <file> <filter> [jq args...]: rewrite a JSON file in place.
jq_edit() {
  local file="$1" filter="$2" tmp
  shift 2
  tmp="$file.edit"
  jq "$@" "$filter" "$file" >"$tmp" && mv "$tmp" "$file"
}

set_feed_state() {
  printf '%s' "$1" >"$FSTATE"
}

# tally <projects-dir> <session> [extra args]: one `--action command` run.
tally() {
  local proj="$1" sess="$2"
  shift 2
  run --separate-stderr bash "$TALLY" --action command --command gaia-audit \
    --session-id "$sess" --projects-root "$FX/$proj" --ledger "$LEDGER" \
    --cache-dir "$CACHE" "$@"
}

# shellcheck disable=SC2120 # the extra args are optional; most callers pass none
tally_opus6() {
  tally projects-opus6 e2eopus60001 "$@"
}

review_tally() {
  run --separate-stderr bash "$TALLY" --action review \
    --session-id e2ereview0001 --projects-root "$FX/projects-review" \
    --ledger "$REVLEDGER" --cache-dir "$CACHE"
}

rollup() {
  run --separate-stderr bash "$ROLLUP" --spec-id SPEC-290 --ledger "$FX/ledger-opus67.jsonl"
}

out_has() {
  grep -qF -- "$1" <<<"$output"
}

err_lines() {
  grep -c -- "$1" <<<"$stderr" || true
}

feed_lines() {
  grep -c '^token-pricing:' <<<"$stderr" || true
}

local_has() {
  jq -e --arg m "$1" '.models | has($m)' "$LOCAL" >/dev/null
}

last_ledger() {
  tail -n 1 "$LEDGER"
}

# A priced command line: the hand-computed figure, no unpriced-model marker, no
# `unavailable`, and a ledger row with a non-null non-zero `dollars`, no
# `unpriced`. Args: <printed figure, e.g. $10.50> <ledger dollars, e.g. 10.5>.
assert_priced_command() {
  [ "$status" -eq 0 ] || { echo "status=$status" >&2; return 1; }
  out_has "$1" || { echo "no $1 in: $output" >&2; return 1; }
  out_has 'lower bound' && { echo "marker in: $output" >&2; return 1; }
  out_has 'unavailable' && { echo "unavailable in: $output" >&2; return 1; }
  last_ledger | jq -e --argjson d "$2" \
    '.dollars == $d and .dollars != 0 and (has("unpriced") | not)' >/dev/null \
    || { echo "ledger row not priced: $(last_ledger)" >&2; return 1; }
  return 0
}

# The lower-bound run: exit 0 and the marker on stdout.
assert_marked() {
  [ "$status" -eq 0 ] || { echo "status=$status" >&2; return 1; }
  out_has "$1" || { echo "no marker $1 in: $output" >&2; return 1; }
  return 0
}

# ---------- UAT-006 ----------

@test "UAT-006: one request heals claude-opus-6 into the local table and the same run is a priced line" {
  start_stub serve "$FX/feed-opus6.json"
  feed_on "$RATES_STUB_URL"
  tally projects-mixed e2emixed0001
  # $20.50 = opus-5 $10.00 + opus-6 $10.50, so the figure includes opus-6's share.
  assert_priced_command '$20.50' 20.5 || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1
  jq -e --slurpfile f "$FX/feed-opus6.json" \
    '.models["claude-opus-6"] == ($f[0].models["claude-opus-6"] | map(. + {source: "feed"}))' \
    "$LOCAL" >/dev/null || { echo "local row: $(jq -c '.models["claude-opus-6"]' "$LOCAL")" >&2; return 1; }
  [ "$(last_ledger | jq -r '.rate_table_id')" = "$(table_id "$LOCAL")" ] || return 1
  true
}

# ---------- UAT-007 ----------

@test "UAT-007: a model the feed does not price stays a lower bound and refetches nothing within the hour" {
  start_stub serve "$FX/feed-opus6.json"
  feed_on "$RATES_STUB_URL"
  tally projects-preview9 e2epreview90001
  assert_marked "$PREVIEW9_MARKER" || return 1
  tally projects-preview9 e2epreview90001
  assert_marked "$PREVIEW9_MARKER" || return 1
  [ "$(rates_stub_count)" = "1" ] || { echo "requests: $(rates_stub_count)" >&2; return 1; }
  true
}

# ---------- UAT-008 ----------

# uat008_case <stub mode>: a feed that fails one way, starting from no feed
# state. Exit 0, the marker, the local table byte-identical, and a stalling case
# within 6 s of a feed-disabled run of the same fixture.
uat008_case() {
  local mode="$1" base_t0 base_t1 t0 t1 baseline elapsed
  start_stub "$mode" "$FX/feed-opus6.json"
  seed_state || return 1
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"

  base_t0="$(now_ms)"
  tally_opus6
  base_t1="$(now_ms)"
  baseline=$((base_t1 - base_t0))
  assert_marked "$OPUS6_MARKER" || return 1

  feed_on "$RATES_STUB_URL"
  rm -f "$FSTATE"
  t0="$(now_ms)"
  tally_opus6
  t1="$(now_ms)"
  elapsed=$((t1 - t0))

  assert_marked "$OPUS6_MARKER" || return 1
  cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL" || { echo "local table changed" >&2; return 1; }
  # The request happened: the case exercised the failure path, not the opt-out.
  [ "$(rates_stub_count)" = "1" ] || { echo "requests: $(rates_stub_count)" >&2; return 1; }
  [ $((elapsed - baseline)) -le 6000 ] || { echo "elapsed ${elapsed}ms vs baseline ${baseline}ms" >&2; return 1; }
  true
}

@test "UAT-008: a refused connection leaves the table byte-identical and the readout a lower bound" {
  local url
  start_stub serve "$FX/feed-opus6.json"
  url="$(rates_stub_refuse_url)" || return 1
  seed_state || return 1
  cp "$LOCAL" "$BATS_TEST_TMPDIR/local.before"
  feed_on "$url"
  rm -f "$FSTATE"
  tally_opus6
  assert_marked "$OPUS6_MARKER" || return 1
  cmp -s "$BATS_TEST_TMPDIR/local.before" "$LOCAL" || return 1
  # No listener sees the attempt, so the feed state is where it shows.
  jq -e '.failed_at | type == "number"' "$FSTATE" >/dev/null || return 1
  true
}

@test "UAT-008: a handshake that completes and then never writes is bounded" {
  uat008_case stall-handshake
}

@test "UAT-008: headers followed by a stalled body are bounded" {
  uat008_case stall-body
}

@test "UAT-008: an HTTP 500 whose body is a valid table is not used" {
  uat008_case status500
}

@test "UAT-008: a non-JSON body is not used" {
  uat008_case nonjson
}

@test "UAT-008: JSON without a models object is not used" {
  uat008_case nomodels
}

@test "UAT-008: a body over 262144 bytes is not used" {
  uat008_case oversize
}

# ---------- UAT-009 ----------

@test "UAT-009: GAIA_RATES_FEED_DISABLE=1 makes no request on any path; unset or =true it does" {
  local plain_count
  start_stub serve "$FX/feed-opus6.json"
  export GAIA_RATES_FEED_URL="$RATES_STUB_URL"
  # GAIA_RATES_FEED_DISABLE=1 stays exported from setup.

  tally_opus6
  assert_marked "$OPUS6_MARKER" || return 1

  review_tally
  [ "$status" -eq 0 ] || return 1
  # The review path prints no readout; the written row is it. $10.00 is the
  # opus-5 turn alone, so opus-6's $10.50 share is excluded and named.
  jq -s -e 'length == 2 and all(.[]; .dollars == 10 and .unpriced == ["claude-opus-6"])' \
    "$REVLEDGER" >/dev/null || { cat "$REVLEDGER" >&2; return 1; }

  rollup
  assert_marked "$BOTH_MARKER" || return 1

  [ "$(rates_stub_count)" = "0" ] || { echo "requests while opted out: $(rates_stub_count)" >&2; return 1; }

  unset GAIA_RATES_FEED_DISABLE
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  [ "$(rates_stub_count)" = "1" ] || { echo "requests unset: $(rates_stub_count)" >&2; return 1; }

  # Only the exact value 1 opts out: `true` leaves the feed on. A fresh state
  # dir, so the model is absent again.
  use_state "$BATS_TEST_TMPDIR/rates-state-true"
  export GAIA_RATES_FEED_DISABLE=true
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  plain_count="$(rates_stub_count)"
  [ "$plain_count" = "2" ] || { echo "requests with =true: $plain_count" >&2; return 1; }
  true
}

# ---------- UAT-010 ----------

@test "UAT-010: an invalid claude-opus-6 row is never written, in each of the eleven shapes" {
  local cases name count fails="" before
  cases="$(jq -r 'keys[]' "$FX/invalid-rows.json")"
  count="$(printf '%s\n' "$cases" | grep -c .)"
  # The SPEC names eleven invalid-row shapes; a short read of the fixture must
  # fail here, not quietly drive a subset.
  [ "$count" -eq 11 ] || { echo "invalid-rows.json has $count cases, expected 11" >&2; return 1; }

  start_stub serve "$FX/feed-opus6.json"

  # Control: the same path with a valid row does heal, so a rejection below is
  # the validator's, not a dead stub or URL.
  use_state "$BATS_TEST_TMPDIR/rates-state-control"
  feed_on "$RATES_STUB_URL"
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  local_has claude-opus-6 || return 1

  for name in $cases; do
    jq -c --arg n "$name" '{models: {"claude-opus-6": .[$n]}}' "$FX/invalid-rows.json" \
      >"$BATS_TEST_TMPDIR/body-$name.json"
    rates_stub_set_mode serve "$BATS_TEST_TMPDIR/body-$name.json"
    use_state "$BATS_TEST_TMPDIR/rates-state-$name"
    before="$(rates_stub_count)"
    tally_opus6
    if [ "$status" -ne 0 ]; then fails="$fails $name(status=$status)"; continue; fi
    out_has "$OPUS6_MARKER" || { fails="$fails $name(no-marker)"; continue; }
    if local_has claude-opus-6; then fails="$fails $name(row-written)"; continue; fi
    [ "$(($(rates_stub_count) - before))" -eq 1 ] || fails="$fails $name(no-request)"
  done
  if [ -n "$fails" ]; then
    echo "failing cases:$fails" >&2
    return 1
  fi
  true
}

# ---------- UAT-016 ----------

@test "UAT-016: the request is one plain GET with default headers only, whatever .curlrc says" {
  local home path names bad fixp projid
  start_stub serve "$FX/feed-opus6.json"
  feed_on "$RATES_STUB_URL"
  home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  printf 'header = "X-Leak: 1"\n' >"$home/.curlrc"
  export HOME="$home"

  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1

  path="/${RATES_STUB_URL#*://*/}"
  [ "$(head -n 1 "$RATES_STUB_REQS")" = "GET $path HTTP/1.1" ] \
    || { echo "request line: $(head -n 1 "$RATES_STUB_REQS")" >&2; return 1; }

  names="$(awk '{n = $2; sub(/:$/, "", n); print n}' "$RATES_STUB_HDRS" | sort -u)"
  [ -n "$names" ] || { echo "no headers logged" >&2; return 1; }
  bad="$(printf '%s\n' "$names" | grep -v -x -e Host -e User-Agent -e Accept || true)"
  [ -z "$bad" ] || { echo "unexpected headers: $bad" >&2; return 1; }
  grep -qi 'x-leak' "$RATES_STUB_HDRS" && return 1
  # No request body: no Content-Length, or a zero one.
  if grep -qi '^[0-9]* content-length:' "$RATES_STUB_HDRS"; then
    grep -i '^[0-9]* content-length:' "$RATES_STUB_HDRS" | grep -qv ': 0$' && return 1
  fi

  fixp="$(cd "$FIXREPO" && pwd -P)"
  projid="$(last_ledger | jq -r '.project')"
  [ -n "$projid" ] && [ "$projid" != "null" ] || { echo "no project id in ledger row" >&2; return 1; }
  grep -qF -- "$FIXREPO" "$RATES_STUB_HDRS" && return 1
  grep -qF -- "$fixp" "$RATES_STUB_HDRS" && return 1
  grep -qF -- "$projid" "$RATES_STUB_HDRS" && return 1
  true
}

# ---------- UAT-019 ----------

@test "UAT-019: with no URL override the shipped default URL is fetched once with the pinned curl argv" {
  local shim="$BATS_TEST_TMPDIR/shim" argv="$BATS_TEST_TMPDIR/curl-argv" default_url joined arg
  mkdir -p "$shim"
  cat >"$shim/curl" <<'SHIM'
#!/bin/sh
echo '--CALL--' >>"$SHIM_ARGV"
printf '%s\n' "$@" >>"$SHIM_ARGV"
cat "$SHIM_BODY"
SHIM
  chmod +x "$shim/curl"
  export SHIM_ARGV="$argv" SHIM_BODY="$FX/feed-opus6.json"
  export PATH="$shim:$PATH"
  unset GAIA_RATES_FEED_URL GAIA_RATES_FEED_DISABLE
  default_url="$(bash -c '. "$1"; printf %s "$GAIA_RATES_FEED_DEFAULT_URL"' _ "$SCRIPTS/token-pricing-lib.sh")"
  [ -n "$default_url" ] || return 1

  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1

  [ "$(grep -c -x -e '--CALL--' "$argv")" = "1" ] || { cat "$argv" >&2; return 1; }
  [ "$(tail -n 1 "$argv")" = "$default_url" ] || { echo "last arg: $(tail -n 1 "$argv")" >&2; return 1; }
  joined=" $(grep -v -x -e '--CALL--' "$argv" | tr '\n' ' ')"
  for arg in ' -q ' ' -fsS ' ' --proto =https ' ' --connect-timeout 2 ' ' --max-time 4 ' ' --max-filesize 262144 '; do
    grep -qF -- "$arg" <<<"$joined" || { echo "missing '$arg' in:$joined" >&2; return 1; }
  done
  for arg in -L --location -H --header -A --user-agent -d --data --data-raw -o --output; do
    grep -qx -e "$arg" "$argv" && { echo "forbidden argument $arg" >&2; return 1; }
  done
  grep -qF '?' "$argv" && { echo "query string in argv" >&2; return 1; }
  true
}

# ---------- UAT-020 ----------

# scheme_refused <scheme>: the run above used a URL scheme the lib refuses,
# while a live plain-HTTP listener logs anything that reaches it.
scheme_refused() {
  local scheme="$1"
  [ "$status" -eq 0 ] || return 1
  out_has "$OPUS6_MARKER" || return 1
  [ "$(err_lines "scheme '$scheme'")" = "1" ] \
    || { echo "stderr: $stderr" >&2; return 1; }
  if local_has claude-opus-6; then return 1; fi
  [ "$(wc -l <"$RATES_PLAIN_REQS" | tr -d ' ')" = "0" ] || return 1
  # Control: the listener does log a request when one is made.
  curl -fsS "$RATES_PLAIN_URL" >/dev/null || return 1
  [ "$(wc -l <"$RATES_PLAIN_REQS" | tr -d ' ')" = "1" ] || return 1
  true
}

@test "UAT-020: an http:// URL makes no request and names the scheme once" {
  rates_stub_start_or_skip plain "$FX/feed-opus6.json"
  feed_on "$RATES_PLAIN_URL"
  tally_opus6
  scheme_refused http
}

@test "UAT-020: an ftp:// URL makes no request and names the scheme once" {
  rates_stub_start_or_skip plain "$FX/feed-opus6.json"
  feed_on "ftp://127.0.0.1:1/token-rates.json"
  tally_opus6
  scheme_refused ftp
}

@test "UAT-020: a file:// URL of a fixture table heals and prices" {
  feed_on "file://$FX/feed-opus6.json"
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  local_has claude-opus-6 || return 1
}

# ---------- UAT-021 ----------

@test "UAT-021: a refused feed backs off for the hour, then retries once and heals" {
  local url b0 b1 t0 t1 baseline elapsed
  start_stub serve "$FX/feed-opus6.json"
  url="$(rates_stub_refuse_url)" || return 1

  b0="$(now_ms)"
  tally_opus6
  b1="$(now_ms)"
  baseline=$((b1 - b0))
  assert_marked "$OPUS6_MARKER" || return 1

  # Run 1: one attempt, seen through the feed state (nothing listens).
  feed_on "$url"
  if [ -f "$FSTATE" ]; then
    jq -e '.failed_at == null' "$FSTATE" >/dev/null || return 1
  fi
  tally_opus6
  assert_marked "$OPUS6_MARKER" || return 1
  jq -e '.failed_at | type == "number"' "$FSTATE" >/dev/null || return 1

  # Run 2: within the hour, the stub now serves, and still no request.
  feed_on "$RATES_STUB_URL"
  t0="$(now_ms)"
  tally_opus6
  t1="$(now_ms)"
  elapsed=$((t1 - t0))
  assert_marked "$OPUS6_MARKER" || return 1
  [ "$(rates_stub_count)" = "0" ] || return 1
  [ $((elapsed - baseline)) -lt 1000 ] || { echo "elapsed ${elapsed}ms vs baseline ${baseline}ms" >&2; return 1; }

  # Run 3: the record backdated past the hour: exactly one request, healed.
  jq_edit "$FSTATE" '.failed_at -= 7200' || return 1
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1
  local_has claude-opus-6 || return 1
}

# ---------- UAT-022 ----------

@test "UAT-022: a stale not-found record refetches, and a fresh one does not block a different model" {
  local now
  start_stub serve "$FX/feed-opus6.json"
  feed_on "$RATES_STUB_URL"
  now="$(date +%s)"

  # Backdated record, claude-preview-9 transcript: one request.
  seed_state || return 1
  set_feed_state "{\"failed_at\":null,\"not_found\":{\"claude-preview-9\":$((now - 7200))}}"
  tally projects-preview9 e2epreview90001
  assert_marked "$PREVIEW9_MARKER" || return 1
  [ "$(rates_stub_count)" = "1" ] || { echo "requests: $(rates_stub_count)" >&2; return 1; }

  # Fresh record, claude-opus-6 transcript: one more request, and it heals.
  use_state "$BATS_TEST_TMPDIR/rates-state-fresh"
  seed_state || return 1
  set_feed_state "{\"failed_at\":null,\"not_found\":{\"claude-preview-9\":$now}}"
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  [ "$(rates_stub_count)" = "2" ] || { echo "requests: $(rates_stub_count)" >&2; return 1; }
  local_has claude-opus-6 || return 1
}

# ---------- UAT-023 ----------

@test "UAT-023: a present but expired row is not absent: no request, still a lower bound, row unchanged" {
  local row_before
  start_stub serve "$FX/feed-opus6.json"
  feed_on "$RATES_STUB_URL"
  seed_state || return 1
  jq_edit "$LOCAL" '.models["claude-opus-6"] = [{"input": 7, "output": 35, "effective_through": "2020-01-01"}]' || return 1
  row_before="$(jq -c '.models["claude-opus-6"]' "$LOCAL")"

  tally_opus6
  assert_marked "$OPUS6_MARKER" || return 1
  tally_opus6
  assert_marked "$OPUS6_MARKER" || return 1
  [ "$(rates_stub_count)" = "0" ] || { echo "requests: $(rates_stub_count)" >&2; return 1; }
  [ "$(jq -c '.models["claude-opus-6"]' "$LOCAL")" = "$row_before" ] || return 1

  # Control: with the row absent the same setup makes exactly one request.
  use_state "$BATS_TEST_TMPDIR/rates-state-absent"
  tally_opus6
  assert_priced_command '$10.50' 10.5 || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1
}

# ---------- UAT-024 ----------

@test "UAT-024: a feed refresh replaces an unedited fed row, spares an edited one, and adds the new model" {
  start_stub serve "$FX/feed-corrected.json"
  feed_on "$RATES_STUB_URL"
  seed_state || return 1
  # claude-opus-6 still equals its base; claude-opus-6-1 was edited (input 6 vs
  # the base's 5).
  jq_edit "$LOCAL" '.models["claude-opus-6"] = [{"input": 7, "output": 35, "source": "feed"}]
    | .models["claude-opus-6-1"] = [{"input": 6, "output": 30, "source": "feed"}]' || return 1
  jq_edit "$BASE" '.models["claude-opus-6"] = [{"input": 7, "output": 35, "source": "feed"}]
    | .models["claude-opus-6-1"] = [{"input": 5, "output": 25, "source": "feed"}]' || return 1

  tally projects-opus7 e2eopus70001
  # $13.50 = 1,000,000 * 9 / 1e6 + 100,000 * 45 / 1e6.
  assert_priced_command '$13.50' 13.5 || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1

  local corrected='[{"input":8,"output":40,"source":"feed"}]'
  [ "$(jq -c '.models["claude-opus-6"]' "$LOCAL")" = "$corrected" ] || return 1
  [ "$(jq -c '.models["claude-opus-6"]' "$BASE")" = "$corrected" ] || return 1
  [ "$(jq -c '.models["claude-opus-6-1"]' "$LOCAL")" = '[{"input":6,"output":30,"source":"feed"}]' ] || return 1
  [ "$(jq -c '.models["claude-opus-7"]' "$LOCAL")" = '[{"input":9,"output":45,"source":"feed"}]' ] || return 1
}

# ---------- UAT-029 ----------

@test "UAT-029: the roll-up heals both models once and prices the ledger row" {
  start_stub serve "$FX/feed-opus67.json"
  feed_on "$RATES_STUB_URL"
  rollup
  [ "$status" -eq 0 ] || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1
  local_has claude-opus-6 || return 1
  local_has claude-opus-7 || return 1
  out_has '$24.00' || { echo "$output" >&2; return 1; }
  out_has 'unpriced model' && { echo "$output" >&2; return 1; }
  true
}

@test "UAT-029: the roll-up over a refused feed exits 0 and names both models" {
  local url
  url="$(rates_stub_refuse_url)" || return 1
  feed_on "$url"
  rollup
  assert_marked "$BOTH_MARKER" || return 1
  jq -e '.failed_at | type == "number"' "$FSTATE" >/dev/null || return 1
  true
}

@test "UAT-029: the roll-up over an HTTP 500 exits 0 and names both models" {
  start_stub status500 "$FX/feed-opus67.json"
  feed_on "$RATES_STUB_URL"
  rollup
  assert_marked "$BOTH_MARKER" || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1
  if local_has claude-opus-6; then return 1; fi
  true
}

# ---------- UAT-030 ----------

@test "UAT-030: a healed review run writes priced rows against the post-heal table" {
  start_stub serve "$FX/feed-opus6.json"
  feed_on "$RATES_STUB_URL"
  review_tally
  [ "$status" -eq 0 ] || return 1
  [ "$(rates_stub_count)" = "1" ] || return 1
  local_has claude-opus-6 || return 1
  jq -s -e --arg id "$(table_id "$LOCAL")" \
    'length == 2 and all(.[]; .dollars == 20.5 and (has("unpriced") | not) and .rate_table_id == $id)' \
    "$REVLEDGER" >/dev/null || { cat "$REVLEDGER" >&2; return 1; }
}

@test "UAT-030: a review run over a refused feed exits 0 and its rows name claude-opus-6" {
  local url
  url="$(rates_stub_refuse_url)" || return 1
  feed_on "$url"
  review_tally
  [ "$status" -eq 0 ] || return 1
  jq -s -e 'length == 2 and all(.[]; .unpriced == ["claude-opus-6"])' \
    "$REVLEDGER" >/dev/null || { cat "$REVLEDGER" >&2; return 1; }
}

# ---------- UAT-031 ----------

@test "UAT-031: with no curl on PATH the run exits 0 as a lower bound with at most one feed line" {
  local farm="$BATS_TEST_TMPDIR/farm" tool path
  mkdir -p "$farm"
  for tool in bash sh env git jq awk sed grep tr cut cat cp mv rm mkdir mktemp dirname basename \
    date cmp wc sort head tail uname readlink ls find touch chmod sleep shasum sha256sum ln tee expr; do
    path="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$path" ] && [ -x "$path" ] && ln -sf "$path" "$farm/$tool"
  done
  # Control: the farm really has no curl.
  PATH="$farm" command -v curl >/dev/null 2>&1 && return 1
  unset GAIA_RATES_FEED_DISABLE GAIA_RATES_FEED_URL

  run --separate-stderr env PATH="$farm" "$farm/bash" "$TALLY" --action command --command gaia-audit \
    --session-id e2eopus60001 --projects-root "$FX/projects-opus6" --ledger "$LEDGER" --cache-dir "$CACHE"
  assert_marked "$OPUS6_MARKER" || return 1
  grep -qi -e 'feed' -e 'curl' <<<"$output" && { echo "feed text on stdout: $output" >&2; return 1; }
  [ "$(feed_lines)" -le 1 ] || { echo "stderr: $stderr" >&2; return 1; }
  true
}
