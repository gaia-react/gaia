#!/usr/bin/env bats
#
# Robustness of the usage-readout memo (SPEC-089): deleting, corrupting,
# version-invalidating, racing or failing to write the memo, and holding the
# ledger lock, all print the pre-change bytes with an empty stderr. Every case
# compares the working tree's readout with the pre-change one pinned at
# e4b57e23 over the same committed fixture stores, and reads the memo trace
# (GAIA_USAGE_MEMO_TRACE) to prove which path ran.
#
# A guard-red case builds a scratch copy of the changed tree with one
# substitution (`mutate` fails unless it matched exactly once) and proves the
# comparison fails against it, so a green run is evidence the guard can fail.
# The scratch copies are never the shipped scripts.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-memo-robust.bats
#
# The jq filters and JSON rows are single-quoted on purpose: their `$` names
# belong to jq. `status` and the harness variables come from sourced files.
# shellcheck disable=SC2016,SC2154,SC2034

bats_require_minimum_version 1.5.0

# How long the held-lock case keeps the ledger lock. The stale-lock reclaim
# threshold is 30 s, so a longer hold would let the lock lib reclaim it.
LOCK_HOLD_SECS=15

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/usage-memo-env.sh
  . "$BATS_TEST_DIRNAME/helpers/usage-memo-env.sh"
  umemo_setup
  umemo_load_store identity
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state"
  export GAIA_RATES_FEED_DISABLE=1
  export GAIA_USAGE_MEMO_TRACE="$BATS_TEST_TMPDIR/trace"
  : >"$GAIA_USAGE_MEMO_TRACE"
  PROBES="$UM_FX/identity/probes.json"
  ROBUST="$UM_FX/robust"
  MEMO="$UM_TD/usage-branch-memo.json"
  # The default probe is the first multi_root one: it prints several initiative
  # lines, so a wrong derive entry on its key changes the figures.
  PR="$(jq -r '[.probes[] | select(.category == "multi_root")][0].pr' "$PROBES")"
  KEY="$(jq -r '[.probes[] | select(.category == "multi_root")][0].key' "$PROBES")"
  RAW="$(jq -r '[.probes[] | select(.category == "multi_root")][0].raw' "$PROBES")"
  case "$PR$KEY$RAW" in *null* | "") return 1 ;; esac
  WRONG_REF="issue:9999"
}

teardown() {
  [ -n "${UM_TD:-}" ] || return 0
  chmod u+rwx "$UM_TD" 2>/dev/null || true
  chmod u+rw "$UM_TD"/*.jsonl 2>/dev/null || true
}

# --- runners -----------------------------------------------------------------

nrun() { local o="$1" e="$2"; shift 2; _umemo_run "$UM_NEW" "$o" "$e" "$@"; }
orun() { local o="$1" e="$2"; shift 2; _umemo_run "$UM_OLD" "$o" "$e" "$@"; }

N_OUT="" N_ERR="" O_OUT="" O_ERR=""
_paths() {
  N_OUT="$BATS_TEST_TMPDIR/n.out" N_ERR="$BATS_TEST_TMPDIR/n.err"
  O_OUT="$BATS_TEST_TMPDIR/o.out" O_ERR="$BATS_TEST_TMPDIR/o.err"
}

# assert_figures <subcommand> <file>: the output carries the figures a degenerate
# output would lack, so the byte comparison cannot pass over nothing.
assert_figures() {
  if [ "$1" = pr ]; then
    assert_priced "$2"
  else
    grep -qE 'est\. (cost \(USD\): )?\$' "$2" || { printf 'no dollar figure in %s:\n%s\n' "$2" "$(cat "$2")" >&2; return 1; }
  fi
}

# check_same <args...>: u_new with a fresh trace, then u_old, over the stores as
# they stand. Both exit 0, the output is priced, stdout is byte-identical, and
# u_new's stderr is empty. Leaves the captures in $N_OUT, $N_ERR, $O_OUT.
check_same() {
  local rn=0 ro=0
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  nrun "$N_OUT" "$N_ERR" "$@" || rn=$?
  orun "$O_OUT" "$O_ERR" "$@" || ro=$?
  [ "$rn" = 0 ] && [ "$ro" = 0 ] || { printf 'exit status: new %s, old %s\n' "$rn" "$ro" >&2; return 1; }
  assert_figures "$1" "$N_OUT" || return 1
  assert_same "$O_OUT" "$N_OUT" || return 1
  if [ -s "$N_ERR" ]; then printf 'u_new printed on stderr:\n%s\n' "$(cat "$N_ERR")" >&2; return 1; fi
  return 0
}

# --- trace -------------------------------------------------------------------

# trace_has <line> [file]: the trace holds that exact line.
trace_has() { grep -qxF -- "$1" "${2:-$GAIA_USAGE_MEMO_TRACE}"; }

assert_trace() {
  trace_has "$@" && return 0
  printf 'the trace lacks the line "%s":\n%s\n' "$1" "$(cat "${2:-$GAIA_USAGE_MEMO_TRACE}")" >&2
  return 1
}

assert_trace_matches() {
  grep -qE -- "$1" "$GAIA_USAGE_MEMO_TRACE" && return 0
  printf 'no trace line matches %s:\n%s\n' "$1" "$(cat "$GAIA_USAGE_MEMO_TRACE")" >&2
  return 1
}

assert_no_trace() {
  if grep -qE -- "$1" "$GAIA_USAGE_MEMO_TRACE"; then
    printf 'the trace holds a line matching %s:\n%s\n' "$1" "$(cat "$GAIA_USAGE_MEMO_TRACE")" >&2
    return 1
  fi
  return 0
}

# --- memo --------------------------------------------------------------------

warm() {
  nrun "$BATS_TEST_TMPDIR/warm.out" "$BATS_TEST_TMPDIR/warm.err" pr "${1:-$PR}" || return 1
  [ -f "$MEMO" ] || { printf 'warm-up left no memo\n' >&2; return 1; }
}

h16() { bash -c '. "$1/.gaia/scripts/usage-lib.sh" && _gaia_usage_hash16 "$2"' _ "$UM_NEW" "$1"; }

# memo_rewrite <body-filter> <keep|stamp> <fix|keep>: rewrites the memo with the
# jq filter applied to its body, optionally another stamp, and either a
# recomputed sum or the old one.
memo_rewrite() {
  local filter="$1" stamp="$2" sums="$3" hdr body nbody nstamp nsum
  hdr="$(sed -n 1p "$MEMO")"
  body="$(sed -n 2p "$MEMO")"
  nbody="$(jq -c "$filter" <<<"$body")" || return 1
  nstamp="$(jq -r '.stamp' <<<"$hdr")"
  [ "$stamp" = keep ] || nstamp="$stamp"
  if [ "$sums" = fix ]; then nsum="$(h16 "$nbody")"; else nsum="$(jq -r '.sum' <<<"$hdr")"; fi
  printf '{"schema_version":1,"stamp":"%s","sum":"%s"}\n%s\n' "$nstamp" "$nsum" "$nbody" >"$MEMO"
}

memo_body() { sed -n 2p "$MEMO"; }

# --- scratch copies of the changed tree --------------------------------------

_occurs() {
  local t="$1" o="$2" r
  r="${t//"$o"/}"
  printf '%s' "$(((${#t} - ${#r}) / ${#o}))"
}

# mutate <file> <old> <new>: replaces the one occurrence of <old>. Fails unless
# <old> occurs exactly once before and not at all after, so a mutant that no
# longer applies cannot test the shipped code instead.
mutate() {
  local f="$1" old="$2" new="$3" text out
  text="$(cat "$f"; printf x)"
  text="${text%x}"
  [ "$(_occurs "$text" "$old")" = 1 ] || { printf 'mutate: %s: the text to replace occurs %s times, want 1:\n%s\n' "$f" "$(_occurs "$text" "$old")" "$old" >&2; return 1; }
  out="${text%%"$old"*}$new${text#*"$old"}"
  [ "$(_occurs "$out" "$old")" = 0 ] || { printf 'mutate: %s: the old text survives the substitution\n' "$f" >&2; return 1; }
  [ "$out" != "$text" ] || { printf 'mutate: %s: the substitution changed nothing\n' "$f" >&2; return 1; }
  printf '%s' "$out" >"$f"
}

# make_tree <name>: a scratch copy of the changed tree; sets $MUT.
make_tree() {
  MUT="$BATS_TEST_TMPDIR/tree-$1"
  rm -rf "$MUT"
  cp -R "$UM_NEW" "$MUT"
}

LIB=.gaia/scripts/usage-memo-lib.sh

mrun() { local tree="$1" o="$2" e="$3"; shift 3; _umemo_run "$tree" "$o" "$e" "$@"; }

# differs <a> <b>: the files are not byte-identical.
differs() { if cmp -s "$1" "$2"; then return 1; fi; return 0; }

# --- 1. memo damage ----------------------------------------------------------

@test "damage: a deleted, emptied or garbled memo reads cold and prints the pre-change bytes" {
  warm
  rm -f "$MEMO"
  check_same pr "$PR"
  assert_trace "path=cold reason=missing"

  : >"$MEMO"
  check_same pr "$PR"
  assert_trace "path=cold reason=unreadable"

  printf 'this is not json\nnor is this\n' >"$MEMO"
  check_same pr "$PR"
  assert_trace_matches '^path=cold reason=(unreadable|schema)$'

  # The readout rewrote a good memo each time.
  check_same pr "$PR"
  assert_trace "path=warm"
}

@test "damage: a stale stamp over a wrong derive entry is never trusted, for pr, initiative and reconcile" {
  local root bad="$BATS_TEST_TMPDIR/memo.bad"
  warm
  root="$(jq -r --arg k "$KEY" '.derive[$k][0]' <<<"$(memo_body)")"
  [ -n "$root" ] && [ "$root" != null ] || { printf 'the probe key has no derive entry\n' >&2; return 1; }
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REF\"]" 0000000000000000 fix
  cp "$MEMO" "$bad"

  check_same pr "$PR"
  assert_trace "path=cold reason=stamp"
  cp "$bad" "$MEMO"
  check_same initiative "$root"
  assert_trace "path=cold reason=stamp"
  cp "$bad" "$MEMO"
  check_same reconcile
  assert_trace "path=cold reason=stamp"
}

@test "damage, guard red: a copy that skips the stamp comparison trusts the wrong derive entry" {
  local root bad="$BATS_TEST_TMPDIR/memo.bad"
  warm
  root="$(jq -r --arg k "$KEY" '.derive[$k][0]' <<<"$(memo_body)")"
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REF\"]" 0000000000000000 fix
  cp "$MEMO" "$bad"
  _paths
  orun "$O_OUT" "$O_ERR" pr "$PR"
  grep -qF "[initiative $root " "$O_OUT"

  make_tree stamp
  mutate "$MUT/$LIB" '[ "$stamp_h" != "$_gaia_usage_memo_stamp" ]' 'false'
  : >"$GAIA_USAGE_MEMO_TRACE"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$PR"
  assert_trace "path=warm"
  assert_priced "$N_OUT"
  differs "$O_OUT" "$N_OUT"
  grep -qF "[initiative $WRONG_REF " "$N_OUT"
}

# --- 2. checksum self-check --------------------------------------------------

@test "checksum: a derive entry edited without recomputing the sum reads cold and prints the pre-change bytes" {
  warm
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REF\"]" keep keep
  check_same pr "$PR"
  assert_trace "path=cold reason=sum"
}

@test "checksum, guard red: a copy that skips the sum comparison trusts the edited derive entry" {
  warm
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REF\"]" keep keep
  _paths
  orun "$O_OUT" "$O_ERR" pr "$PR"
  make_tree sum
  mutate "$MUT/$LIB" '[ "$(_gaia_usage_hash16 "$body" 2>/dev/null)" != "$sum_h" ]' 'false'
  : >"$GAIA_USAGE_MEMO_TRACE"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$PR"
  assert_trace "path=warm"
  assert_priced "$N_OUT"
  differs "$O_OUT" "$N_OUT"
  grep -qF "[initiative $WRONG_REF " "$N_OUT"
}

# --- 3. escaped key backstop -------------------------------------------------

@test "escaped key: a branch spelled with a JSON escape is found by the coverage check, once" {
  local row before="$BATS_TEST_TMPDIR/before.out"
  # The decoded git_branch is the probe's own raw, so the cost row's spec edge
  # lands on the probe's key; the escape hides it from the warm-up grep.
  row='{"schema_version":1,"kind":"execute","spec_id":"SPEC-503","plan_id":null,"plan_slug":null,"session_id":"s-esc","total":1000,"seq":0,"final":true,"git_branch":"'"${RAW//\//\\/}"'","ts":"2026-09-29T10:00:00Z","session_cwd":"/work/repo"}'
  warm
  cp "$BATS_TEST_TMPDIR/warm.out" "$before"
  jq -e --arg r "$RAW" '.bmap[$r] == null' <<<"$(memo_body)" >/dev/null
  printf '%s\n' "$row" >>"$UM_TD/cost.jsonl"
  grep -qF "${RAW//\//\\/}" "$UM_TD/cost.jsonl"

  check_same pr "$PR"
  differs "$before" "$N_OUT"
  assert_trace "rerun=miss raws=1 bkeys=0 models=0"
  jq -e --arg r "$RAW" --arg k "$KEY" '.bmap[$r].key == $k' <<<"$(memo_body)" >/dev/null

  check_same pr "$PR"
  assert_no_trace '^rerun=miss'
  assert_trace "path=warm"

  rm -f "$MEMO"
  check_same pr "$PR"
  assert_trace "rerun=miss raws=1 bkeys=0 models=0"
}

# --- 4. torn and rewritten stores --------------------------------------------

@test "stores: a torn final line is left for the next read, and a rewrite inside the hashed head scans in full" {
  local l="$UM_TD/links.jsonl" c="$UM_TD/cost.jsonl" size0 off0 hn0 torn i
  torn='{"schema_version":1,"kind":"edge","child":"'"$KEY"'","parent":"research:torn-extra","source":"link-command","ts":"2026-09-29T00:00:00Z","session_id":null,"sidechain":false'
  warm
  check_same pr "$PR"
  cp "$N_OUT" "$BATS_TEST_TMPDIR/base.out"
  size0="$(wc -c <"$l" | tr -d '[:space:]')"

  printf '%s' "$torn" >>"$l"
  check_same pr "$PR"
  assert_trace "path=warm"
  [ "$(jq -r '.stores.l.off' <<<"$(memo_body)")" = "$size0" ]
  cmp -s "$BATS_TEST_TMPDIR/base.out" "$N_OUT"

  printf '}\n' >>"$l"
  check_same pr "$PR"
  differs "$BATS_TEST_TMPDIR/base.out" "$N_OUT"
  grep -qF '[initiative research:torn-extra ' "$N_OUT"
  [ "$(jq -r '.stores.l.off' <<<"$(memo_body)")" = "$(wc -c <"$l" | tr -d '[:space:]')" ]

  # A cut below the recorded hashed head, regrown past the recorded offset with
  # different rows.
  off0="$(jq -r '.stores.c.off' <<<"$(memo_body)")"
  hn0="$(jq -r '.stores.c.hn' <<<"$(memo_body)")"
  [ "$hn0" -gt 0 ]
  head -n 2 "$c" >"$BATS_TEST_TMPDIR/cost.cut"
  [ "$(wc -c <"$BATS_TEST_TMPDIR/cost.cut" | tr -d '[:space:]')" -lt "$hn0" ]
  cp "$BATS_TEST_TMPDIR/cost.cut" "$c"
  i=0
  while [ "$(wc -c <"$c" | tr -d '[:space:]')" -le "$off0" ]; do
    printf '{"schema_version":1,"kind":"execute","spec_id":"SPEC-503","plan_id":null,"plan_slug":null,"session_id":"s-rw%s","total":1000,"seq":0,"final":true,"git_branch":"%s","ts":"2026-09-26T10:00:00Z","session_cwd":"/work/repo"}\n' "$i" "$RAW" >>"$c"
    i=$((i + 1))
  done
  check_same pr "$PR"
  assert_trace "scan=full store=c reason=head"
  check_same reconcile

  # A plain shrink below the recorded offset.
  head -n 1 "$c" >"$BATS_TEST_TMPDIR/cost.cut"
  cp "$BATS_TEST_TMPDIR/cost.cut" "$c"
  check_same pr "$PR"
  assert_trace "scan=full store=c reason=shrunk"

  # The same sequence under a memo-deleted u_new matches u_old too.
  rm -f "$MEMO"
  check_same pr "$PR"
}

# --- 5. unwritable telemetry dir ---------------------------------------------

@test "unwritable: a telemetry dir that cannot be written still reads, silently, and leaves no memo or temp" {
  chmod a-w "$UM_TD"
  if touch "$UM_TD/.write-probe" 2>/dev/null; then
    rm -f "$UM_TD/.write-probe"
    printf 'the telemetry dir is still writable (running as root?); the case would pass vacuously\n' >&2
    return 1
  fi
  check_same pr "$PR"
  assert_trace "write=fail"
  assert_no_trace '^write=ok'
  [ ! -e "$MEMO" ]
  [ -z "$(find "$UM_TD" -maxdepth 1 -name '.usage-branch-memo.tmp.*')" ]
}

# --- 6. concurrent cold readouts ---------------------------------------------

@test "concurrent: simultaneous cold readouts all print the pre-change bytes, and the next one reads warm" {
  local prs=(2305 2302 2307 2314 2401 2410) p i=0 pids=()
  rm -f "$MEMO"
  for p in "${prs[@]}"; do
    ( nrun "$BATS_TEST_TMPDIR/c$i.out" "$BATS_TEST_TMPDIR/c$i.err" pr "$p" ) >/dev/null 2>&1 3>&- &
    pids[i]=$!
    i=$((i + 1))
  done
  for p in "${pids[@]}"; do wait "$p"; done
  i=0
  for p in "${prs[@]}"; do
    orun "$BATS_TEST_TMPDIR/co.out" "$BATS_TEST_TMPDIR/co.err" pr "$p"
    assert_priced "$BATS_TEST_TMPDIR/c$i.out"
    assert_same "$BATS_TEST_TMPDIR/co.out" "$BATS_TEST_TMPDIR/c$i.out"
    [ ! -s "$BATS_TEST_TMPDIR/c$i.err" ] || { printf 'pr %s printed on stderr:\n%s\n' "$p" "$(cat "$BATS_TEST_TMPDIR/c$i.err")" >&2; return 1; }
    i=$((i + 1))
  done
  [ "$i" -ge 4 ]
  [ -z "$(find "$UM_TD" -maxdepth 1 -name '.usage-branch-memo.tmp.*')" ]
  check_same pr "$PR"
  assert_trace "path=warm"
}

# --- 7. held lock and a mid-read append --------------------------------------

@test "lock: a readout started while the ledger lock is held finishes first; a copy that saves under the lock waits for it" {
  local t0 elapsed rel
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECS=60
  rm -f "$MEMO"
  mkdir "$UM_TD/specs.lock.d"
  t0=$SECONDS
  ( sleep "$LOCK_HOLD_SECS"; rmdir "$UM_TD/specs.lock.d" ) >/dev/null 2>&1 3>&- &
  rel=$!

  check_same pr "$PR"
  elapsed=$((SECONDS - t0))
  [ -d "$UM_TD/specs.lock.d" ]
  [ "$elapsed" -lt 10 ]
  assert_trace "write=ok"
  [ -f "$MEMO" ]

  # Guard red, in the same hold window: a copy whose save takes the ledger lock
  # waits out the hold, so the bound above is not a property of a fast machine.
  make_tree lock
  mutate "$MUT/$LIB" 'gaia_usage_memo_save() {' '_gaia_usage_memo_save_inner() {'
  printf '%s\n' \
    'gaia_usage_memo_save() {' \
    "  . \"$MUT/.specify/extensions/gaia/lib/with-ledger-lock.sh\"" \
    '  with_ledger_lock "${1%/*}" _gaia_usage_memo_save_inner "$1"' \
    '}' >>"$MUT/$LIB"
  rm -f "$MEMO"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$PR"
  elapsed=$((SECONDS - t0))
  [ "$elapsed" -ge "$((LOCK_HOLD_SECS - 3))" ]
  assert_priced "$N_OUT"
  assert_same "$O_OUT" "$N_OUT"
  wait "$rel"
}

@test "seam: rows appended between the warm-up and the parse are found by the coverage check" {
  local first="$BATS_TEST_TMPDIR/seam.out"
  warm
  export UMEMO_SEAM_TD="$UM_TD" GAIA_USAGE_MEMO_SEAM="$ROBUST/seam-append.sh"
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  nrun "$N_OUT" "$N_ERR" pr 2501
  unset GAIA_USAGE_MEMO_SEAM
  grep -qF '"session_id":"s-seam"' "$UM_TD/usage.jsonl"
  assert_trace "rerun=miss raws=0 bkeys=1 models=0"
  [ ! -s "$N_ERR" ]
  assert_priced "$N_OUT"
  grep -qF '[initiative issue:2330 ' "$N_OUT"
  cp "$N_OUT" "$first"

  # The post-append stores read the same cold and under the pre-change scripts.
  rm -f "$MEMO"
  check_same pr 2501
  assert_same "$first" "$N_OUT"
}

# --- 8. transitive helper edit -----------------------------------------------

@test "helper edit: a change to a function the derivation reaches invalidates the memo stamp" {
  local pr key edited="$BATS_TEST_TMPDIR/edited.out"
  pr="$(jq -r '[.probes[] | select((.key // "") | startswith("branch:plan/spec-"))][0].pr' "$PROBES")"
  key="$(jq -r '[.probes[] | select((.key // "") | startswith("branch:plan/spec-"))][0].key' "$PROBES")"
  case "$pr$key" in *null* | "") return 1 ;; esac
  _paths
  warm "$pr"
  jq -e --arg k "$key" '.derive[$k] | length > 0' <<<"$(memo_body)" >/dev/null

  make_tree helper
  mutate "$MUT/.gaia/scripts/branch-name-lib.sh" 'unit="SPEC-${lead}"' 'unit="SPEC-9${lead}"'
  : >"$GAIA_USAGE_MEMO_TRACE"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$pr"
  assert_trace "path=cold reason=stamp"
  assert_priced "$N_OUT"
  cp "$N_OUT" "$edited"

  rm -f "$MEMO"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$pr"
  assert_same "$edited" "$N_OUT"
  _paths
  orun "$O_OUT" "$O_ERR" pr "$pr"
  differs "$O_OUT" "$edited"
}

# --- local rate mode (9, 12) -------------------------------------------------

LX=claude-xray-1
LY=claude-yray-1

# The model entry in the flusher's key order, and in another order that the
# warm-up grep does not match.
_flusher() { printf '"%s":{"fresh_input":1000000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":100000}' "$1"; }
_reordered() { printf '"%s":{"output":100000,"fresh_input":1000000,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0}' "$1"; }

# append_segment <variant>: a segment on the probe's key priced under models the
# local table lacks. A: X, visible to the warm-up. B: X, visible only to the
# coverage check. C: Y visible to the warm-up and X only to the coverage check,
# so the first rate load attempts the feed for Y alone.
append_segment() {
  local by
  case "$1" in
    A) by="{$(_flusher "$LX")}" ;;
    B) by="{$(_reordered "$LX")}" ;;
    C) by="{$(_flusher "$LY"),$(_reordered "$LX")}" ;;
    *) return 1 ;;
  esac
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"s-xm","inherit":false,"first_ts":"2026-09-12T16:00:00Z","last_ts":"2026-09-12T16:00:00Z","messages":2,"by_model":%s}\n' \
    "$KEY" "$by" >>"$UM_TD/usage.jsonl"
}

# lrun <tree> <out> <err> <state-dir> <args...>: local rate mode. No --rate-table
# override, the feed enabled and pointed at the stub, and a rates state dir of
# the caller's choosing (the heal writes the local table, so each tree has its
# own).
lrun() {
  local tree="$1" out="$2" err="$3" state="$4" rc=0
  shift 4
  env -u GAIA_RATES_FEED_DISABLE GAIA_RATES_STATE_DIR="$state" GAIA_RATES_FEED_URL="file://$STUB" \
    bash "$tree/.gaia/scripts/usage.sh" "$@" --main-root "$UM_MAIN" --telemetry-dir "$UM_TD" \
    --projects-root "$UM_PROJ" >"$out" 2>"$err" || rc=$?
  return "$rc"
}

# local_scenario <variant> <tree> <state-name>: warms the memo under the shipped
# tree over the committed stores, appends the variant's segment, and reads it
# with <tree> and, over a fresh copy of the same local table, with the
# pre-change scripts. Leaves the captures in $N_OUT $N_ERR $O_OUT $O_ERR and the
# warm-up's output in $BASE_OUT.
local_scenario() {
  local variant="$1" tree="$2" sname="$3"
  _paths
  BASE_OUT="$BATS_TEST_TMPDIR/base.out"
  STUB="$BATS_TEST_TMPDIR/feed.json"
  mkdir -p "$UM_MAIN/.gaia/scripts"
  cp "$UM_RATES" "$UM_MAIN/.gaia/scripts/token-rates.json"
  cp "$ROBUST/feed-stub.json" "$STUB"
  rm -rf "$BATS_TEST_TMPDIR/rates-$sname" "$BATS_TEST_TMPDIR/rates-old"
  lrun "$UM_NEW" "$BASE_OUT" "$BATS_TEST_TMPDIR/base.err" "$BATS_TEST_TMPDIR/rates-$sname" pr "$PR"
  assert_priced "$BASE_OUT"
  append_segment "$variant"
  : >"$GAIA_USAGE_MEMO_TRACE"
  lrun "$tree" "$N_OUT" "$N_ERR" "$BATS_TEST_TMPDIR/rates-$sname" pr "$PR"
  lrun "$UM_OLD" "$O_OUT" "$O_ERR" "$BATS_TEST_TMPDIR/rates-old" pr "$PR"
}

# assert_healed: the model's segment is priced and the output is the pre-change
# one, with nothing on stderr and no lower-bound marker.
assert_healed() {
  assert_priced "$N_OUT"
  assert_priced "$O_OUT"
  if grep -qF 'unpriced model(s)' "$O_OUT"; then printf 'the pre-change run left a model unpriced, so the fixture proves nothing:\n%s\n' "$(cat "$O_OUT")" >&2; return 1; fi
  if grep -qF 'unpriced model(s)' "$N_OUT"; then printf 'the readout marks a model unpriced:\n%s\n' "$(cat "$N_OUT")" >&2; return 1; fi
  differs "$BASE_OUT" "$N_OUT"
  assert_same "$O_OUT" "$N_OUT"
  if [ -s "$N_ERR" ]; then printf 'the readout printed on stderr:\n%s\n' "$(cat "$N_ERR")" >&2; return 1; fi
  return 0
}

@test "local rates: a model the warm-up grep sees is healed to the pre-change figure" {
  local_scenario A "$UM_NEW" shipped
  assert_healed
  assert_no_trace '^rerun=miss'
}

@test "local rates: a model only the coverage check finds is healed in a fresh child" {
  local_scenario B "$UM_NEW" shipped
  assert_healed
  assert_trace "rerun=miss raws=0 bkeys=0 models=1"
  assert_trace "rates=reload"
}

@test "local rates: a second missing model after a first heal that already fetched is healed too" {
  local_scenario C "$UM_NEW" shipped
  assert_healed
  assert_trace "rerun=miss raws=0 bkeys=0 models=1"
  assert_trace "rates=reload"
}

@test "local rates, guard red: a copy that reloads rates in-process leaves the second model unpriced" {
  make_tree inproc
  mutate "$MUT/$LIB" '2) rates="$(gaia_usage_memo_rates_fresh "$dir" "$table" "$main")" || return 1 ;;' \
    '2) usage_rates_load "$table" "$main" "$(gaia_usage_memo_models)"; rates="$USAGE_RATES" ;;'
  local_scenario C "$MUT" inproc
  assert_priced "$O_OUT"
  assert_priced "$N_OUT"
  differs "$O_OUT" "$N_OUT"
  grep -qF "unpriced model(s) $LX" "$N_OUT"
}

# --- 10. cross-shell warmth --------------------------------------------------

@test "shells: one memo stays warm across bash 3.2 and bash 5" {
  local sh3="" sh5="" s v seq=() i=0 out="$BATS_TEST_TMPDIR/sh.out" err="$BATS_TEST_TMPDIR/sh.err"
  for s in /bin/bash /usr/bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
    [ -x "$s" ] || continue
    v="$("$s" -c 'printf %s "${BASH_VERSINFO[0]}"')"
    case "$v" in
      3) [ -n "$sh3" ] || sh3="$s" ;;
      [5-9]) [ -n "$sh5" ] || sh5="$s" ;;
    esac
  done
  if [ -n "$sh3" ] && [ -n "$sh5" ]; then
    seq=("$sh5" "$sh3" "$sh5" "$sh3")
  elif [ -n "$sh5" ]; then
    seq=("$sh5" "$sh5")
    printf '# only bash 5 (%s) on this host; the cross-shell sequence ran under it alone\n' "$sh5" >&3
  elif [ -n "$sh3" ]; then
    seq=("$sh3" "$sh3")
    printf '# only bash 3 (%s) on this host; the cross-shell sequence ran under it alone\n' "$sh3" >&3
  else
    printf 'no bash 3 or bash 5 found\n' >&2
    return 1
  fi
  _paths
  orun "$O_OUT" "$O_ERR" pr "$PR"
  rm -f "$MEMO"
  for s in "${seq[@]}"; do
    : >"$GAIA_USAGE_MEMO_TRACE"
    "$s" "$UM_NEW/.gaia/scripts/usage.sh" pr "$PR" --main-root "$UM_MAIN" --telemetry-dir "$UM_TD" \
      --rate-table "$UM_RATES" --projects-root "$UM_PROJ" >"$out" 2>"$err"
    assert_priced "$out"
    assert_same "$O_OUT" "$out"
    [ ! -s "$err" ] || { printf '%s printed on stderr:\n%s\n' "$s" "$(cat "$err")" >&2; return 1; }
    if [ "$i" = 0 ]; then assert_trace "path=cold reason=missing"; else assert_trace "path=warm"; fi
    i=$((i + 1))
  done
}

# --- 11. error fallback stderr -----------------------------------------------

# forced_failure_tree <name>: a copy whose single-parse jq cannot compile, so the
# memo path fails with no coverage miss and the readout takes the fallback.
forced_failure_tree() {
  make_tree "$1"
  mutate "$MUT/$LIB" 'def usage_present($urows; $links; $cost):' 'def usage_present(($urows; $links; $cost):'
}

@test "fallback: an unreadable links store prints the pre-change error, status and bytes" {
  local rn=0 ro=0
  chmod 000 "$UM_TD/links.jsonl"
  if cat "$UM_TD/links.jsonl" >/dev/null 2>&1; then
    printf 'links.jsonl is still readable (running as root?); the case would pass vacuously\n' >&2
    return 1
  fi
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  nrun "$N_OUT" "$N_ERR" pr "$PR" || rn=$?
  orun "$O_OUT" "$O_ERR" pr "$PR" || ro=$?
  [ -s "$O_ERR" ]
  [ "$rn" = "$ro" ]
  assert_same "$O_OUT" "$N_OUT"
  assert_same "$O_ERR" "$N_ERR"
  assert_trace "fallback=legacy"
}

@test "fallback: a single-parse jq that fails prints the pre-change bytes with an empty stderr" {
  forced_failure_tree jqfail
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$PR"
  orun "$O_OUT" "$O_ERR" pr "$PR"
  assert_priced "$N_OUT"
  assert_same "$O_OUT" "$N_OUT"
  assert_same "$O_ERR" "$N_ERR"
  [ ! -s "$N_ERR" ]
  assert_trace "fallback=legacy"
}

@test "fallback, guard red: a copy whose single-parse jq does not discard stderr prints jq's error" {
  forced_failure_tree jqerr
  mutate "$MUT/$LIB" $'$filter end end" \\\n      2>/dev/null' '$filter end end"'
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  mrun "$MUT" "$N_OUT" "$N_ERR" pr "$PR"
  orun "$O_OUT" "$O_ERR" pr "$PR"
  assert_trace "fallback=legacy"
  assert_same "$O_OUT" "$N_OUT"
  [ -s "$N_ERR" ]
  differs "$O_ERR" "$N_ERR"
}

# --- 12. legacy fallback in local rate mode ----------------------------------

@test "fallback, local rates: a failed single parse after a first heal still prices the second model" {
  forced_failure_tree jqfail
  local_scenario C "$MUT" fallback
  assert_healed
  assert_trace "fallback=legacy"
}

# --- 13. memo model superset -------------------------------------------------

@test "models superset: a model only a non-schema line names is dropped from the memo, with a rate reload" {
  local row z=claude-zeta-1
  row='{"schema_version":2,"kind":"segment","key":"session:s-z","session_id":"s-z","inherit":false,"first_ts":"2026-09-30T00:00:00Z","last_ts":"2026-09-30T00:00:00Z","messages":1,"by_model":{"'"$z"'":{"fresh_input":10,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":5}}}'
  warm
  cp "$MEMO" "$BATS_TEST_TMPDIR/memo.warm"
  printf '%s\n' "$row" >>"$UM_TD/usage.jsonl"

  # Guard red first, from the warm memo: a gap that ignores models_extra finds
  # no miss, so the trace line the shipped copy writes is absent.
  make_tree extra
  mutate "$MUT/$LIB" '($memo.models - $present.models) as $mx' '[] as $mx'
  : >"$GAIA_USAGE_MEMO_TRACE"
  mrun "$MUT" "$BATS_TEST_TMPDIR/m.out" "$BATS_TEST_TMPDIR/m.err" pr "$PR"
  jq -e --arg z "$z" '.models | index($z) != null' <<<"$(memo_body)" >/dev/null
  assert_no_trace '^rerun=miss'
  cp "$BATS_TEST_TMPDIR/memo.warm" "$MEMO"

  check_same pr "$PR"
  assert_trace "rerun=miss raws=0 bkeys=0 models=1"
  assert_trace "rates=reload"
  jq -e --arg z "$z" '.models | index($z) == null' <<<"$(memo_body)" >/dev/null

  check_same pr "$PR"
  assert_no_trace '^rerun=miss'
}
