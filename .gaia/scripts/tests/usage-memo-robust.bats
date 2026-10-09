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
LOCK_HOLD_SECONDS=15

setup() {
  # shellcheck source=.gaia/scripts/tests/helpers/usage-memo-env.sh
  . "$BATS_TEST_DIRNAME/helpers/usage-memo-env.sh"
  umemo_setup
  umemo_load_store identity
  export GAIA_USAGE_MEMO_TRACE="$BATS_TEST_TMPDIR/trace"
  : >"$GAIA_USAGE_MEMO_TRACE"
  PROBES="$UM_FIXTURES/identity/probes.json"
  ROBUST="$UM_FIXTURES/robust"
  MEMO="$UM_TELEMETRY_DIRECTORY/usage-branch-memo.json"
  # The default probe is the first multi_root one: it prints several initiative
  # lines, so a wrong derive entry on its key changes the figures.
  PR="$(jq -r '[.probes[] | select(.category == "multi_root")][0].pr' "$PROBES")"
  KEY="$(jq -r '[.probes[] | select(.category == "multi_root")][0].key' "$PROBES")"
  RAW="$(jq -r '[.probes[] | select(.category == "multi_root")][0].raw' "$PROBES")"
  case "$PR$KEY$RAW" in *null* | "") return 1 ;; esac
  WRONG_REFERENCE="issue:9999"
}

teardown() {
  [ -n "${UM_TELEMETRY_DIRECTORY:-}" ] || return 0
  chmod u+rwx "$UM_TELEMETRY_DIRECTORY" 2>/dev/null || true
  chmod u+rw "$UM_TELEMETRY_DIRECTORY"/*.jsonl 2>/dev/null || true
}

# --- runners -----------------------------------------------------------------

run_new_tree() { local output_file="$1" error_file="$2"; shift 2; _umemo_run "$UM_NEW" "$output_file" "$error_file" "$@"; }
run_old_tree() { local output_file="$1" error_file="$2"; shift 2; _umemo_run "$UM_OLD" "$output_file" "$error_file" "$@"; }

NEW_OUTPUT_FILE="" NEW_ERROR_FILE="" OLD_OUTPUT_FILE="" OLD_ERROR_FILE=""
_paths() {
  NEW_OUTPUT_FILE="$BATS_TEST_TMPDIR/n.out" NEW_ERROR_FILE="$BATS_TEST_TMPDIR/n.err"
  OLD_OUTPUT_FILE="$BATS_TEST_TMPDIR/o.out" OLD_ERROR_FILE="$BATS_TEST_TMPDIR/o.err"
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
# u_new's stderr is empty. Leaves the captures in $NEW_OUTPUT_FILE, $NEW_ERROR_FILE, $OLD_OUTPUT_FILE.
check_same() {
  local new_exit_status=0 old_exit_status=0
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_new_tree "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" "$@" || new_exit_status=$?
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" "$@" || old_exit_status=$?
  [ "$new_exit_status" = 0 ] && [ "$old_exit_status" = 0 ] || { printf 'exit status: new %s, old %s\n' "$new_exit_status" "$old_exit_status" >&2; return 1; }
  assert_figures "$1" "$NEW_OUTPUT_FILE" || return 1
  assert_same "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE" || return 1
  if [ -s "$NEW_ERROR_FILE" ]; then printf 'u_new printed on stderr:\n%s\n' "$(cat "$NEW_ERROR_FILE")" >&2; return 1; fi
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
  run_new_tree "$BATS_TEST_TMPDIR/warm.out" "$BATS_TEST_TMPDIR/warm.err" pr "${1:-$PR}" || return 1
  [ -f "$MEMO" ] || { printf 'warm-up left no memo\n' >&2; return 1; }
}

hash16() { bash -c '. "$1/.gaia/scripts/usage-lib.sh" && _gaia_usage_hash16 "$2"' _ "$UM_NEW" "$1"; }

# memo_rewrite <body-filter> <keep|stamp> <fix|keep>: rewrites the memo with the
# jq filter applied to its body, optionally another stamp, and either a
# recomputed sum or the old one.
memo_rewrite() {
  local filter="$1" stamp="$2" sums="$3" header body new_body new_stamp new_sum
  header="$(sed -n 1p "$MEMO")"
  body="$(sed -n 2p "$MEMO")"
  new_body="$(jq -c "$filter" <<<"$body")" || return 1
  new_stamp="$(jq -r '.stamp' <<<"$header")"
  [ "$stamp" = keep ] || new_stamp="$stamp"
  if [ "$sums" = fix ]; then new_sum="$(hash16 "$new_body")"; else new_sum="$(jq -r '.sum' <<<"$header")"; fi
  printf '{"schema_version":1,"stamp":"%s","sum":"%s"}\n%s\n' "$new_stamp" "$new_sum" "$new_body" >"$MEMO"
}

memo_body() { sed -n 2p "$MEMO"; }

# --- scratch copies of the changed tree --------------------------------------

_occurs() {
  local haystack="$1" needle="$2" remainder
  remainder="${haystack//"$needle"/}"
  printf '%s' "$(((${#haystack} - ${#remainder}) / ${#needle}))"
}

# mutate <file> <old> <new>: replaces the one occurrence of <old>. Fails unless
# <old> occurs exactly once before and not at all after, so a mutant that no
# longer applies cannot test the shipped code instead.
mutate() {
  local file="$1" old="$2" new="$3" text mutated_text
  text="$(cat "$file"; printf x)"
  text="${text%x}"
  [ "$(_occurs "$text" "$old")" = 1 ] || { printf 'mutate: %s: the text to replace occurs %s times, want 1:\n%s\n' "$file" "$(_occurs "$text" "$old")" "$old" >&2; return 1; }
  mutated_text="${text%%"$old"*}$new${text#*"$old"}"
  [ "$(_occurs "$mutated_text" "$old")" = 0 ] || { printf 'mutate: %s: the old text survives the substitution\n' "$file" >&2; return 1; }
  [ "$mutated_text" != "$text" ] || { printf 'mutate: %s: the substitution changed nothing\n' "$file" >&2; return 1; }
  printf '%s' "$mutated_text" >"$file"
}

# make_tree <name>: a scratch copy of the changed tree; sets $MUTANT_TREE.
make_tree() {
  MUTANT_TREE="$BATS_TEST_TMPDIR/tree-$1"
  rm -rf "$MUTANT_TREE"
  cp -R "$UM_NEW" "$MUTANT_TREE"
}

LIBRARY=.gaia/scripts/usage-memo-lib.sh

run_mutant_tree() { local tree="$1" output_file="$2" error_file="$3"; shift 3; _umemo_run "$tree" "$output_file" "$error_file" "$@"; }

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
  root="$(jq -r --arg derive_key "$KEY" '.derive[$derive_key][0]' <<<"$(memo_body)")"
  [ -n "$root" ] && [ "$root" != null ] || { printf 'the probe key has no derive entry\n' >&2; return 1; }
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REFERENCE\"]" 0000000000000000 fix
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
  root="$(jq -r --arg derive_key "$KEY" '.derive[$derive_key][0]' <<<"$(memo_body)")"
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REFERENCE\"]" 0000000000000000 fix
  cp "$MEMO" "$bad"
  _paths
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$PR"
  grep -qF "[initiative $root " "$OLD_OUTPUT_FILE"

  make_tree stamp
  mutate "$MUTANT_TREE/$LIBRARY" '[ "$stamp_hash" != "$_gaia_usage_memo_stamp" ]' 'false'
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$PR"
  assert_trace "path=warm"
  assert_priced "$NEW_OUTPUT_FILE"
  differs "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE"
  grep -qF "[initiative $WRONG_REFERENCE " "$NEW_OUTPUT_FILE"
}

# --- 2. checksum self-check --------------------------------------------------

@test "checksum: a derive entry edited without recomputing the sum reads cold and prints the pre-change bytes" {
  warm
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REFERENCE\"]" keep keep
  check_same pr "$PR"
  assert_trace "path=cold reason=sum"
}

@test "checksum, guard red: a copy that skips the sum comparison trusts the edited derive entry" {
  warm
  memo_rewrite ".derive[\"$KEY\"] = [\"$WRONG_REFERENCE\"]" keep keep
  _paths
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$PR"
  make_tree sum
  mutate "$MUTANT_TREE/$LIBRARY" '[ "$(_gaia_usage_hash16 "$body" 2>/dev/null)" != "$sum_hash" ]' 'false'
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$PR"
  assert_trace "path=warm"
  assert_priced "$NEW_OUTPUT_FILE"
  differs "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE"
  grep -qF "[initiative $WRONG_REFERENCE " "$NEW_OUTPUT_FILE"
}

# --- 3. escaped key backstop -------------------------------------------------

@test "escaped key: a branch spelled with a JSON escape is found by the coverage check, once" {
  local row before="$BATS_TEST_TMPDIR/before.out" escaped_parent="branch:fix/2999-escparent"
  # An edge from the probe's key to a branch no store names, whose name implies
  # issue:2999; the escaped slash hides that branch from the warm-up grep.
  row='{"schema_version":1,"kind":"edge","child":"'"$KEY"'","parent":"'"${escaped_parent//\//\\/}"'","source":"link-command","ts":"2026-09-29T10:00:00Z","session_id":null,"sidechain":false}'
  warm
  cp "$BATS_TEST_TMPDIR/warm.out" "$before"
  jq -e --arg key "$escaped_parent" '.derive[$key] == null' <<<"$(memo_body)" >/dev/null
  printf '%s\n' "$row" >>"$UM_TELEMETRY_DIRECTORY/links.jsonl"
  grep -qF "${escaped_parent//\//\\/}" "$UM_TELEMETRY_DIRECTORY/links.jsonl"

  check_same pr "$PR"
  differs "$before" "$NEW_OUTPUT_FILE"
  grep -qF '[initiative issue:2999 ' "$NEW_OUTPUT_FILE"
  assert_trace "rerun=miss bkeys=1 models=0"
  jq -e --arg key "$escaped_parent" '.derive[$key] == ["issue:2999"]' <<<"$(memo_body)" >/dev/null

  check_same pr "$PR"
  assert_no_trace '^rerun=miss'
  assert_trace "path=warm"

  rm -f "$MEMO"
  check_same pr "$PR"
  assert_trace "rerun=miss bkeys=1 models=0"
}

# --- 4. torn and rewritten stores --------------------------------------------

@test "stores: a torn final line is left for the next read, and a rewrite inside the hashed head scans in full" {
  local links_store="$UM_TELEMETRY_DIRECTORY/links.jsonl" initial_size initial_offset initial_head_length torn i
  torn='{"schema_version":1,"kind":"edge","child":"'"$KEY"'","parent":"research:torn-extra","source":"link-command","ts":"2026-09-29T00:00:00Z","session_id":null,"sidechain":false'
  warm
  check_same pr "$PR"
  cp "$NEW_OUTPUT_FILE" "$BATS_TEST_TMPDIR/base.out"
  initial_size="$(wc -c <"$links_store" | tr -d '[:space:]')"

  printf '%s' "$torn" >>"$links_store"
  check_same pr "$PR"
  assert_trace "path=warm"
  [ "$(jq -r '.stores.l.off' <<<"$(memo_body)")" = "$initial_size" ]
  cmp -s "$BATS_TEST_TMPDIR/base.out" "$NEW_OUTPUT_FILE"

  printf '}\n' >>"$links_store"
  check_same pr "$PR"
  differs "$BATS_TEST_TMPDIR/base.out" "$NEW_OUTPUT_FILE"
  grep -qF '[initiative research:torn-extra ' "$NEW_OUTPUT_FILE"
  [ "$(jq -r '.stores.l.off' <<<"$(memo_body)")" = "$(wc -c <"$links_store" | tr -d '[:space:]')" ]

  # A same-length rewrite inside the recorded hashed head: the size stays at
  # the recorded offset, so only the head hash can notice it.
  initial_offset="$(jq -r '.stores.l.off' <<<"$(memo_body)")"
  initial_head_length="$(jq -r '.stores.l.hn' <<<"$(memo_body)")"
  [ "$initial_head_length" -gt 0 ]
  sed '1s/"source":"gh-pr-create"/"source":"link-command"/' "$links_store" >"$BATS_TEST_TMPDIR/links.rewritten"
  differs "$links_store" "$BATS_TEST_TMPDIR/links.rewritten"
  cp "$BATS_TEST_TMPDIR/links.rewritten" "$links_store"
  [ "$(wc -c <"$links_store" | tr -d '[:space:]')" -ge "$initial_offset" ]
  check_same pr "$PR"
  assert_trace "scan=full store=l reason=head"
  check_same reconcile

  # A plain shrink below the recorded offset.
  head -n 1 "$links_store" >"$BATS_TEST_TMPDIR/links.cut"
  cp "$BATS_TEST_TMPDIR/links.cut" "$links_store"
  check_same reconcile
  assert_trace "scan=full store=l reason=shrunk"

  # The same sequence under a memo-deleted u_new matches u_old too.
  rm -f "$MEMO"
  check_same reconcile
}

# --- 5. unwritable telemetry dir ---------------------------------------------

@test "unwritable: a telemetry dir that cannot be written still reads, silently, and leaves no memo or temp" {
  chmod a-w "$UM_TELEMETRY_DIRECTORY"
  if touch "$UM_TELEMETRY_DIRECTORY/.write-probe" 2>/dev/null; then
    rm -f "$UM_TELEMETRY_DIRECTORY/.write-probe"
    printf 'the telemetry dir is still writable (running as root?); the case would pass vacuously\n' >&2
    return 1
  fi
  check_same pr "$PR"
  assert_trace "write=fail"
  assert_no_trace '^write=ok'
  [ ! -e "$MEMO" ]
  [ -z "$(find "$UM_TELEMETRY_DIRECTORY" -maxdepth 1 -name '.usage-branch-memo.tmp.*')" ]
}

# --- 6. concurrent cold readouts ---------------------------------------------

@test "concurrent: simultaneous cold readouts all print the pre-change bytes, and the next one reads warm" {
  local prs=(2305 2302 2307 2314 2401 2410) pr_number background_pid i=0 pids=()
  rm -f "$MEMO"
  for pr_number in "${prs[@]}"; do
    ( run_new_tree "$BATS_TEST_TMPDIR/c$i.out" "$BATS_TEST_TMPDIR/c$i.err" pr "$pr_number" ) >/dev/null 2>&1 3>&- &
    pids[i]=$!
    i=$((i + 1))
  done
  for background_pid in "${pids[@]}"; do wait "$background_pid"; done
  i=0
  for pr_number in "${prs[@]}"; do
    run_old_tree "$BATS_TEST_TMPDIR/co.out" "$BATS_TEST_TMPDIR/co.err" pr "$pr_number"
    assert_priced "$BATS_TEST_TMPDIR/c$i.out"
    assert_same "$BATS_TEST_TMPDIR/co.out" "$BATS_TEST_TMPDIR/c$i.out"
    [ ! -s "$BATS_TEST_TMPDIR/c$i.err" ] || { printf 'pr %s printed on stderr:\n%s\n' "$pr_number" "$(cat "$BATS_TEST_TMPDIR/c$i.err")" >&2; return 1; }
    i=$((i + 1))
  done
  [ "$i" -ge 4 ]
  [ -z "$(find "$UM_TELEMETRY_DIRECTORY" -maxdepth 1 -name '.usage-branch-memo.tmp.*')" ]
  check_same pr "$PR"
  assert_trace "path=warm"
}

# --- 7. held lock and a mid-read append --------------------------------------

@test "lock: a readout started while the ledger lock is held finishes first; a copy that saves under the lock waits for it" {
  local started_seconds elapsed releaser_pid
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1 GAIA_LEDGER_LOCK_TIMEOUT_SECONDS=60
  rm -f "$MEMO"
  mkdir "$UM_TELEMETRY_DIRECTORY/specs.lock.d"
  started_seconds=$SECONDS
  ( sleep "$LOCK_HOLD_SECONDS"; rmdir "$UM_TELEMETRY_DIRECTORY/specs.lock.d" ) >/dev/null 2>&1 3>&- &
  releaser_pid=$!

  check_same pr "$PR"
  elapsed=$((SECONDS - started_seconds))
  [ -d "$UM_TELEMETRY_DIRECTORY/specs.lock.d" ]
  [ "$elapsed" -lt 10 ]
  assert_trace "write=ok"
  [ -f "$MEMO" ]

  # Guard red, in the same hold window: a copy whose save takes the ledger lock
  # waits out the hold, so the bound above is not a property of a fast machine.
  make_tree lock
  mutate "$MUTANT_TREE/$LIBRARY" 'gaia_usage_memo_save() {' '_gaia_usage_memo_save_inner() {'
  printf '%s\n' \
    'gaia_usage_memo_save() {' \
    "  . \"$MUTANT_TREE/.gaia/scripts/spec/with-ledger-lock.sh\"" \
    '  with_ledger_lock "${1%/*}" _gaia_usage_memo_save_inner "$1"' \
    '}' >>"$MUTANT_TREE/$LIBRARY"
  rm -f "$MEMO"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$PR"
  elapsed=$((SECONDS - started_seconds))
  [ "$elapsed" -ge "$((LOCK_HOLD_SECONDS - 3))" ]
  assert_priced "$NEW_OUTPUT_FILE"
  assert_same "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE"
  wait "$releaser_pid"
}

@test "seam: rows appended between the warm-up and the parse are found by the coverage check" {
  local first="$BATS_TEST_TMPDIR/seam.out"
  warm
  export UMEMO_SEAM_TELEMETRY_DIRECTORY="$UM_TELEMETRY_DIRECTORY" GAIA_USAGE_MEMO_SEAM="$ROBUST/seam-append.sh"
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_new_tree "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr 2501
  unset GAIA_USAGE_MEMO_SEAM
  grep -qF '"session_id":"s-seam"' "$UM_TELEMETRY_DIRECTORY/usage.jsonl"
  assert_trace "rerun=miss bkeys=1 models=0"
  [ ! -s "$NEW_ERROR_FILE" ]
  assert_priced "$NEW_OUTPUT_FILE"
  grep -qF '[initiative issue:2330 ' "$NEW_OUTPUT_FILE"
  cp "$NEW_OUTPUT_FILE" "$first"

  # The post-append stores read the same cold and under the pre-change scripts.
  rm -f "$MEMO"
  check_same pr 2501
  assert_same "$first" "$NEW_OUTPUT_FILE"
}

# --- 8. transitive helper edit -----------------------------------------------

@test "helper edit: a change to a function the derivation reaches invalidates the memo stamp" {
  local pr key edited="$BATS_TEST_TMPDIR/edited.out"
  pr="$(jq -r '[.probes[] | select((.key // "") | startswith("branch:plan/spec-"))][0].pr' "$PROBES")"
  key="$(jq -r '[.probes[] | select((.key // "") | startswith("branch:plan/spec-"))][0].key' "$PROBES")"
  case "$pr$key" in *null* | "") return 1 ;; esac
  _paths
  warm "$pr"
  jq -e --arg derive_key "$key" '.derive[$derive_key] | length > 0' <<<"$(memo_body)" >/dev/null

  make_tree helper
  # The newline and indentation pick the legacy plan/ arm the probed key takes;
  # the type-prefixed plan arm repeats the assignment at a deeper indent.
  mutate "$MUTANT_TREE/.gaia/scripts/branch-name-lib.sh" $'\n              unit="SPEC-${lead}"' $'\n              unit="SPEC-9${lead}"'
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$pr"
  assert_trace "path=cold reason=stamp"
  assert_priced "$NEW_OUTPUT_FILE"
  cp "$NEW_OUTPUT_FILE" "$edited"

  rm -f "$MEMO"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$pr"
  assert_same "$edited" "$NEW_OUTPUT_FILE"
  _paths
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$pr"
  differs "$OLD_OUTPUT_FILE" "$edited"
}

# --- 10. cross-shell warmth --------------------------------------------------

@test "shells: one memo stays warm across bash 3.2 and bash 5" {
  local bash3_path="" bash5_path="" shell_path major_version shell_sequence=() i=0 output_file="$BATS_TEST_TMPDIR/sh.out" error_file="$BATS_TEST_TMPDIR/sh.err"
  for shell_path in /bin/bash /usr/bin/bash /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
    [ -x "$shell_path" ] || continue
    major_version="$("$shell_path" -c 'printf %s "${BASH_VERSINFO[0]}"')"
    case "$major_version" in
      3) [ -n "$bash3_path" ] || bash3_path="$shell_path" ;;
      [5-9]) [ -n "$bash5_path" ] || bash5_path="$shell_path" ;;
    esac
  done
  if [ -n "$bash3_path" ] && [ -n "$bash5_path" ]; then
    shell_sequence=("$bash5_path" "$bash3_path" "$bash5_path" "$bash3_path")
  elif [ -n "$bash5_path" ]; then
    shell_sequence=("$bash5_path" "$bash5_path")
    printf '# only bash 5 (%s) on this host; the cross-shell sequence ran under it alone\n' "$bash5_path" >&3
  elif [ -n "$bash3_path" ]; then
    shell_sequence=("$bash3_path" "$bash3_path")
    printf '# only bash 3 (%s) on this host; the cross-shell sequence ran under it alone\n' "$bash3_path" >&3
  else
    printf 'no bash 3 or bash 5 found\n' >&2
    return 1
  fi
  _paths
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$PR"
  rm -f "$MEMO"
  for shell_path in "${shell_sequence[@]}"; do
    : >"$GAIA_USAGE_MEMO_TRACE"
    "$shell_path" "$UM_NEW/.gaia/scripts/usage.sh" pr "$PR" --main-root "$UM_MAIN" --telemetry-dir "$UM_TELEMETRY_DIRECTORY" \
      --rate-table "$UM_RATES" --projects-root "$UM_PROJECTS_DIRECTORY" >"$output_file" 2>"$error_file"
    assert_priced "$output_file"
    assert_same "$OLD_OUTPUT_FILE" "$output_file"
    [ ! -s "$error_file" ] || { printf '%s printed on stderr:\n%s\n' "$shell_path" "$(cat "$error_file")" >&2; return 1; }
    if [ "$i" = 0 ]; then assert_trace "path=cold reason=missing"; else assert_trace "path=warm"; fi
    i=$((i + 1))
  done
}

# --- 11. error fallback stderr -----------------------------------------------

# forced_failure_tree <name>: a copy whose single-parse jq cannot compile, so the
# memo path fails with no coverage miss and the readout takes the fallback.
forced_failure_tree() {
  make_tree "$1"
  mutate "$MUTANT_TREE/$LIBRARY" 'def usage_present($usage_records; $links):' 'def usage_present(($usage_records; $links):'
}

@test "fallback: an unreadable links store prints the pre-change error, status and bytes" {
  local new_exit_status=0 old_exit_status=0
  chmod 000 "$UM_TELEMETRY_DIRECTORY/links.jsonl"
  if cat "$UM_TELEMETRY_DIRECTORY/links.jsonl" >/dev/null 2>&1; then
    printf 'links.jsonl is still readable (running as root?); the case would pass vacuously\n' >&2
    return 1
  fi
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_new_tree "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$PR" || new_exit_status=$?
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$PR" || old_exit_status=$?
  [ -s "$OLD_ERROR_FILE" ]
  [ "$new_exit_status" = "$old_exit_status" ]
  assert_same "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE"
  # jq names the failing option in its message: the pinned baseline spells it l, the working tree links_store.
  sed 's/--rawfile links_store /--rawfile l /' "$NEW_ERROR_FILE" >"$NEW_ERROR_FILE.normalized"
  assert_same "$OLD_ERROR_FILE" "$NEW_ERROR_FILE.normalized"
  assert_trace "fallback=legacy"
}

@test "fallback: a single-parse jq that fails prints the pre-change bytes with an empty stderr" {
  forced_failure_tree jqfail
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$PR"
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$PR"
  assert_priced "$NEW_OUTPUT_FILE"
  assert_same "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE"
  assert_same "$OLD_ERROR_FILE" "$NEW_ERROR_FILE"
  [ ! -s "$NEW_ERROR_FILE" ]
  assert_trace "fallback=legacy"
}

@test "fallback, guard red: a copy whose single-parse jq does not discard stderr prints jq's error" {
  forced_failure_tree jqerr
  mutate "$MUTANT_TREE/$LIBRARY" $'$filter end end" \\\n      2>/dev/null' '$filter end end"'
  _paths
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_mutant_tree "$MUTANT_TREE" "$NEW_OUTPUT_FILE" "$NEW_ERROR_FILE" pr "$PR"
  run_old_tree "$OLD_OUTPUT_FILE" "$OLD_ERROR_FILE" pr "$PR"
  assert_trace "fallback=legacy"
  assert_same "$OLD_OUTPUT_FILE" "$NEW_OUTPUT_FILE"
  [ -s "$NEW_ERROR_FILE" ]
  differs "$OLD_ERROR_FILE" "$NEW_ERROR_FILE"
}

# --- 13. a memo too large for one argument -----------------------------------

# A body past 1 MiB is over both limits a memo on argv would hit: Linux refuses
# any single argument over 128 KiB, and macOS refuses a whole command line over
# 1 MiB. The padding is derive entries for branch keys no store names, which no view
# reads. The sum is hashed in a subshell rather than a child bash, whose argv
# would hit the very limit under test.
@test "large memo: a body over the argument limits still reads warm and prints the pre-change bytes" {
  local header body size sum
  warm
  header="$(sed -n 1p "$MEMO")"
  body="$(memo_body | jq -c '.derive += ([range(0; 6000)] | map({key: "branch:pad/\(.)-\("x" * 160)", value: []}) | from_entries)')"
  size="${#body}"
  [ "$size" -gt 1048576 ] || { printf 'the padded body is %s bytes, want over 1048576\n' "$size" >&2; return 1; }
  sum="$(. "$UM_NEW/.gaia/scripts/usage-lib.sh" && _gaia_usage_hash16 "$body")"
  [ -n "$sum" ]
  printf '{"schema_version":1,"stamp":"%s","sum":"%s"}\n%s\n' "$(jq -r '.stamp' <<<"$header")" "$sum" "$body" >"$MEMO"

  check_same pr "$PR"
  assert_trace "path=warm"
  assert_no_trace '^(path=cold|fallback=legacy)'
  [ "$(memo_body | wc -c | tr -d '[:space:]')" -gt 1048576 ]
}

# --- 14. memo model superset -------------------------------------------------

@test "models superset: a model only a non-schema line names is dropped from the memo" {
  local row zeta_model=claude-zeta-1
  row='{"schema_version":2,"kind":"segment","key":"session:s-z","session_id":"s-z","inherit":false,"first_ts":"2026-09-30T00:00:00Z","last_ts":"2026-09-30T00:00:00Z","messages":1,"by_model":{"'"$zeta_model"'":{"fresh_input":10,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":5}}}'
  warm
  cp "$MEMO" "$BATS_TEST_TMPDIR/memo.warm"
  printf '%s\n' "$row" >>"$UM_TELEMETRY_DIRECTORY/usage.jsonl"

  # Guard red first, from the warm memo: a gap that ignores models_extra finds
  # no miss, so the trace line the shipped copy writes is absent.
  make_tree extra
  mutate "$MUTANT_TREE/$LIBRARY" '($memo.models - $present.models) as $extra_models' '[] as $extra_models'
  : >"$GAIA_USAGE_MEMO_TRACE"
  run_mutant_tree "$MUTANT_TREE" "$BATS_TEST_TMPDIR/m.out" "$BATS_TEST_TMPDIR/m.err" pr "$PR"
  jq -e --arg zeta_model "$zeta_model" '.models | index($zeta_model) != null' <<<"$(memo_body)" >/dev/null
  assert_no_trace '^rerun=miss'
  cp "$BATS_TEST_TMPDIR/memo.warm" "$MEMO"

  check_same pr "$PR"
  assert_trace "rerun=miss bkeys=0 models=1"
  jq -e --arg zeta_model "$zeta_model" '.models | index($zeta_model) == null' <<<"$(memo_body)" >/dev/null

  check_same pr "$PR"
  assert_no_trace '^rerun=miss'
}
