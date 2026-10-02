#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/usage-memo-lib.sh: the branch-derivation
# memo's version stamp, load and self-check, tail warm-up, gap merge, save,
# reap, and coverage jq.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/usage-memo-lib.bats
#
# Expected values are literals, hand-spelled in the test, so a regression in
# the library cannot be mirrored by the assertion that checks it.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  TELEMETRY_DIRECTORY="$TEMPORARY_DIRECTORY/tel"
  mkdir -p "$TELEMETRY_DIRECTORY"
  USAGE_STORE="$TELEMETRY_DIRECTORY/usage.jsonl"
  LINKS_STORE="$TELEMETRY_DIRECTORY/links.jsonl"
  COST_STORE="$TELEMETRY_DIRECTORY/cost.jsonl"
  MEMO="$TELEMETRY_DIRECTORY/usage-branch-memo.json"
  TRACE="$TEMPORARY_DIRECTORY/trace"
  : >"$TRACE"
  export GAIA_USAGE_MEMO_TRACE="$TRACE"
  unset GAIA_USAGE_MEMO_SEAM
  # shellcheck disable=SC1091
  source "$SCRIPTS/usage-lib.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/usage-resolve-lib.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/usage-memo-lib.sh"
}

teardown() {
  chmod -R u+rwx "$TEMPORARY_DIRECTORY" 2>/dev/null || true
}

# ---------- fixtures ----------

segment_row() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"s1","inherit":false,"first_ts":"2026-09-30T12:00:00.000Z","last_ts":"2026-09-30T12:01:00.000Z","messages":1,"by_model":{"%s":{"fresh_input":1,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":1}}}\n' "$1" "$2"
}
link_row() {
  printf '{"schema_version":1,"kind":"edge","child":"%s","parent":"%s","source":"link-command","ts":"2026-09-30T12:00:00Z","session_id":"s1"}\n' "$1" "$2"
}
cost_row() {
  printf '{"schema_version":1,"kind":"plan","spec_id":"%s","plan_id":null,"session_id":"s1","by_model":{},"git_branch":"%s"}\n' "$1" "$2"
}

# base_stores: raws in worktree spelling, a hashed key, a name with no parents,
# the default branch, the empty raw, and a link-only key.
base_stores() {
  {
    segment_row session:s1 m-one
    segment_row branch:fix/12-foo m-one
    segment_row branch:chore/update-deps m-two
  } >"$USAGE_STORE"
  {
    link_row pr:5 branch:fix/12-foo
    link_row pr:6 branch:feat/3-link
  } >"$LINKS_STORE"
  {
    cost_row SPEC-024 worktree-plan+spec-024-x
    cost_row SPEC-025 "has space"
    cost_row SPEC-026 main
    cost_row SPEC-027 ""
  } >"$COST_STORE"
}

warm_all() { gaia_usage_memo_warm "$USAGE_STORE" "$LINKS_STORE" "$COST_STORE"; }

# init_memo: stamp, a cold load of the (absent) memo, then a warm-up.
init_memo() {
  gaia_usage_memo_stamp
  gaia_usage_memo_load "$MEMO"
  warm_all
}

memo_get() { jq -r "$1" <<<"$GAIA_USAGE_MEMO"; }

last_trace() { tail -n 1 "$TRACE"; }

file_size() {
  local byte_count
  byte_count="$(wc -c <"$1")"
  printf '%s' "${byte_count//[[:space:]]/}"
}

# subst_file <file> <old> <new>: replaces the first literal occurrence, failing
# when it is absent, so a mutant can never be a copy of the original. Values go
# through ENVIRON because awk -v would process the backslashes.
subst_file() {
  local before after
  before="$(cat "$1")"
  after="$(S_OLD="$2" S_NEW="$3" awk '
    BEGIN { old_text = ENVIRON["S_OLD"]; new_text = ENVIRON["S_NEW"] }
    !done && (match_position = index($0, old_text)) { $0 = substr($0, 1, match_position - 1) new_text substr($0, match_position + length(old_text)); done = 1 }
    { print }' "$1")"
  [ "$before" != "$after" ] || return 1
  printf '%s\n' "$after" >"$1"
}

# scratch_libraries <dir>: the four libs the stamp reads, copied beside one another.
scratch_libraries() {
  mkdir -p "$1"
  cp "$SCRIPTS/usage-lib.sh" "$SCRIPTS/usage-resolve-lib.sh" "$SCRIPTS/branch-name-lib.sh" "$SCRIPTS/usage-memo-lib.sh" "$1/"
}

# in_libraries <interp> <libdir> <script> [arg...]: runs <script> in a child shell
# that has sourced the libs from <libdir>; the args are its $1, $2, ...
in_libraries() {
  local shell_path="$1"
  shift
  "$shell_path" -c 'library_directory="$1"; script_text="$2"; shift 2; source "$library_directory/usage-lib.sh"; source "$library_directory/usage-resolve-lib.sh"; source "$library_directory/usage-memo-lib.sh"; eval "$script_text"' _ "$@"
}

# ---------- 1. stamp closure ----------

# closure <name>...: every function reachable from the names, to a fixed point,
# through the words of each `declare -f` body that `declare -F` knows.
closure() {
  local reachable_names=$'\n' seed_name visiting_name word changed=1
  for seed_name in "$@"; do reachable_names="$reachable_names$seed_name"$'\n'; done
  while [ "$changed" = 1 ]; do
    changed=0
    for visiting_name in $reachable_names; do
      for word in $(declare -f "$visiting_name" | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sort -u); do
        case "$reachable_names" in *$'\n'"$word"$'\n'*) continue ;; esac
        declare -F "$word" >/dev/null 2>&1 || continue
        reachable_names="$reachable_names$word"$'\n'
        changed=1
      done
    done
  done
  printf '%s' "$reachable_names" | sed '/^$/d' | sort
}

# reach_set: the closure from the derivation entry points plus every stamped
# memo-lib function, after branch-name-lib.sh is loaded.
reach_set() {
  local function_name entries="gaia_usage_branch_map gaia_usage_derive_map _gaia_usage_branch_parents"
  for function_name in $GAIA_USAGE_MEMO_FUNCTIONS; do
    case "$function_name" in *memo*) entries="$entries $function_name" ;; esac
  done
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh
  # shellcheck disable=SC2086  # a space-separated name list, split on purpose
  closure $entries
}

# closure_missing <function_names>: the reachable names <function_names> does not carry.
closure_missing() {
  local reachable_name
  for reachable_name in $(reach_set); do
    case " $1 " in *" $reachable_name "*) ;; *) printf '%s\n' "$reachable_name" ;; esac
  done
}

@test "stamp closure: every function reachable from the derivation entry points is stamped" {
  local missing reach function_name
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh
  reach="$(reach_set)"
  [ "$(printf '%s\n' "$reach" | wc -l | tr -d ' ')" -gt 10 ]
  case $'\n'"$reach"$'\n' in *$'\n'_gaia_branch_set_class$'\n'*) ;; *) return 1 ;; esac
  missing="$(closure_missing "$GAIA_USAGE_MEMO_FUNCTIONS")"
  [ -z "$missing" ] || { printf 'reachable but unstamped:\n%s\n' "$missing" >&2; return 1; }
  # Every stamped name is a defined function, so a rename cannot hide in the list.
  for function_name in $GAIA_USAGE_MEMO_FUNCTIONS; do
    declare -F "$function_name" >/dev/null || { printf 'stamped but undefined: %s\n' "$function_name" >&2; return 1; }
  done
}

@test "stamp closure guard red: a list missing one reachable name is reported" {
  local trimmed missing
  trimmed=" $GAIA_USAGE_MEMO_FUNCTIONS "
  trimmed="${trimmed/ _gaia_branch_set_class / }"
  [ "$trimmed" != " $GAIA_USAGE_MEMO_FUNCTIONS " ]
  missing="$(closure_missing "$trimmed")"
  [ "$missing" = "_gaia_branch_set_class" ]
}

# ---------- 2-4. stamp ----------

stamp_in() { in_libraries "${2:-$BASH}" "$1" 'gaia_usage_memo_stamp; printf "%s %s" "$_gaia_usage_memo_stamp_exit_status" "$_gaia_usage_memo_stamp"'; }

@test "stamp sensitivity: a stamped function's body changes it, an unstamped one's does not" {
  local base edited other
  scratch_libraries "$TEMPORARY_DIRECTORY/libs-a"
  base="$(stamp_in "$TEMPORARY_DIRECTORY/libs-a")"
  case "$base" in "0 "*) ;; *) return 1 ;; esac
  scratch_libraries "$TEMPORARY_DIRECTORY/libs-b"
  subst_file "$TEMPORARY_DIRECTORY/libs-b/branch-name-lib.sh" 'local normalized_name mode="adhoc"' 'local normalized_name mode="adhoc2"'
  edited="$(stamp_in "$TEMPORARY_DIRECTORY/libs-b")"
  [ "$edited" != "$base" ]
  scratch_libraries "$TEMPORARY_DIRECTORY/libs-c"
  subst_file "$TEMPORARY_DIRECTORY/libs-c/usage-lib.sh" 'if [ -n "${GAIA_TALLY_PROJECTS_ROOT:-}" ]; then' 'if [ -n "${GAIA_TALLY_PROJECTS_ROOT:-}" ] && :; then'
  other="$(stamp_in "$TEMPORARY_DIRECTORY/libs-c")"
  [ "$other" = "$base" ]
}

@test "stamp shell independence: bash 3.2 and bash 5 compute the same stamp" {
  local shell_path seen="" first="" got shell_count=0
  for shell_path in /bin/bash "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$shell_path" ] || continue
    case " $seen " in *" $shell_path "*) continue ;; esac
    seen="$seen $shell_path"
    got="$(stamp_in "$SCRIPTS" "$shell_path")"
    case "$got" in "0 "*) ;; *) return 1 ;; esac
    if [ -z "$first" ]; then first="$got"; fi
    [ "$got" = "$first" ]
    shell_count=$((shell_count + 1))
  done
  [ "$shell_count" -ge 1 ]
  printf '# stamp shell independence covered %s shell(s):%s\n' "$shell_count" "$seen" >&3
}

@test "stamp unavailable: a stamped name that extracts empty returns 1, and save writes nothing" {
  scratch_libraries "$TEMPORARY_DIRECTORY/libs-d"
  subst_file "$TEMPORARY_DIRECTORY/libs-d/branch-name-lib.sh" 'gaia_branch_members() {' 'gaia_branch_members_renamed() {'
  run in_libraries "$BASH" "$TEMPORARY_DIRECTORY/libs-d" 'gaia_usage_memo_stamp; echo "rc=$? sr=$_gaia_usage_memo_stamp_exit_status"; GAIA_USAGE_MEMO="{}"; gaia_usage_memo_save "$1/memo.json"' "$TELEMETRY_DIRECTORY"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=1 sr=1" ]
  [ "$(last_trace)" = "write=skip" ]
  [ ! -e "$TELEMETRY_DIRECTORY/memo.json" ]
  [ -z "$(find "$TELEMETRY_DIRECTORY" -name '.usage-branch-memo.tmp.*')" ]
}

# ---------- 5. load reasons ----------

# write_memo <header> <body>: a memo file whose sum is the body's real one.
write_memo() { printf '%s\n%s\n' "$1" "$2" >"$MEMO"; }

valid_header() {
  local body="$1"
  # shellcheck disable=SC2154  # set by gaia_usage_memo_stamp
  printf '{"schema_version":1,"stamp":"%s","sum":"%s"}' "$_gaia_usage_memo_stamp" "$(_gaia_usage_hash16 "$body")"
}

do_load() {
  : >"$TRACE"
  gaia_usage_memo_load "$MEMO"
}
load_reason() {
  do_load
  last_trace
}

@test "load: each cold reason is produced by a memo crafted for it, and a valid memo loads warm" {
  local body='{"bmap":{},"derive":{},"models":[],"stores":{}}' first_model
  gaia_usage_memo_stamp
  rm -f "$MEMO"
  [ "$(load_reason)" = "path=cold reason=missing" ]
  : >"$MEMO"
  [ "$(load_reason)" = "path=cold reason=unreadable" ]
  printf '%s\n' "$(valid_header "$body")" >"$MEMO"
  [ "$(load_reason)" = "path=cold reason=unreadable" ]
  write_memo 'not json' "$body"
  [ "$(load_reason)" = "path=cold reason=schema" ]
  write_memo '{"schema_version":2,"stamp":"x","sum":"y"}' "$body"
  [ "$(load_reason)" = "path=cold reason=schema" ]
  write_memo "$(printf '{"schema_version":1,"stamp":"0000000000000000","sum":"%s"}' "$(_gaia_usage_hash16 "$body")")" "$body"
  [ "$(load_reason)" = "path=cold reason=stamp" ]
  write_memo "$(printf '{"schema_version":1,"stamp":"%s","sum":"0000000000000000"}' "$_gaia_usage_memo_stamp")" "$body"
  [ "$(load_reason)" = "path=cold reason=sum" ]
  body='{"bmap":{},"derive":{},"models":5,"stores":{}}'
  write_memo "$(valid_header "$body")" "$body"
  [ "$(load_reason)" = "path=cold reason=shape" ]
  body='{"bmap":{"x":{"norm":"x"}},"derive":{},"models":[],"stores":{}}'
  write_memo "$(valid_header "$body")" "$body"
  [ "$(load_reason)" = "path=cold reason=shape" ]
  body='{"bmap":{},"derive":{},"models":[],"stores":{"u":{"path":"p","off":-1,"hn":0,"head":"h"}}}'
  write_memo "$(valid_header "$body")" "$body"
  [ "$(load_reason)" = "path=cold reason=shape" ]
  body='{"bmap":{"a":{"norm":"a","key":null}},"derive":{"k":["p"]},"models":["m"],"stores":{"u":{"path":"p","off":0,"hn":0,"head":"h"}}}'
  write_memo "$(valid_header "$body")" "$body"
  do_load
  [ "$(last_trace)" = "path=warm" ]
  [ "$GAIA_USAGE_MEMO_STATE" = warm ]
  [ "$GAIA_USAGE_MEMO" = "$body" ]
  first_model="$(jq -r '.models[0]' <<<"$GAIA_USAGE_MEMO")"
  [ "$first_model" = m ]
}

@test "load guard red: a derive entry edited without recomputing the sum loads cold on the sum" {
  base_stores
  init_memo
  gaia_usage_memo_save "$MEMO"
  [ "$(load_reason)" = "path=warm" ]
  subst_file "$MEMO" '"spec:SPEC-024"' '"spec:SPEC-025"'
  do_load
  [ "$(last_trace)" = "path=cold reason=sum" ]
  [ "$GAIA_USAGE_MEMO_STATE" = cold ]
  [ "$GAIA_USAGE_MEMO" = '{"bmap":{},"derive":{},"models":[],"stores":{}}' ]
}

# ---------- 6. warm-up tail ----------

wrap_derivations() {
  eval "orig_branch_map$(declare -f gaia_usage_branch_map | sed '1s/^gaia_usage_branch_map//')"
  eval "orig_derive_map$(declare -f gaia_usage_derive_map | sed '1s/^gaia_usage_derive_map//')"
  gaia_usage_branch_map() { printf '%s\n' "$@" >>"$TEMPORARY_DIRECTORY/bmap.args"; orig_branch_map "$@"; }
  gaia_usage_derive_map() { printf '%s\n' "$@" >>"$TEMPORARY_DIRECTORY/derive.args"; orig_derive_map "$@"; }
  : >"$TEMPORARY_DIRECTORY/bmap.args"
  : >"$TEMPORARY_DIRECTORY/derive.args"
}

@test "warm-up tail: appended rows derive exactly the new raw, key, and model, and the offset advances" {
  base_stores
  init_memo
  [ "$(memo_get '.bmap | keys | join(",")')" = ",has space,main,worktree-plan+spec-024-x" ]
  [ "$(memo_get '.models | join(",")')" = "m-one,m-two" ]
  gaia_usage_memo_save "$MEMO"
  gaia_usage_memo_load "$MEMO"
  wrap_derivations
  segment_row branch:topic/77-new m-three >>"$USAGE_STORE"
  cost_row SPEC-090 worktree-plan+spec-090-q >>"$COST_STORE"
  : >"$TRACE"
  warm_all
  [ "$(cat "$TEMPORARY_DIRECTORY/bmap.args")" = "worktree-plan+spec-090-q" ]
  [ "$(cat "$TEMPORARY_DIRECTORY/derive.args")" = $'branch:plan/spec-090-q\nbranch:topic/77-new' ]
  [ "$(memo_get '.derive["branch:topic/77-new"] | length')" = 0 ]
  [ "$(memo_get '.derive["branch:plan/spec-090-q"] | join(",")')" = "spec:SPEC-090" ]
  [ "$(memo_get '.models | join(",")')" = "m-one,m-three,m-two" ]
  [ "$(memo_get '.stores.u.off')" = "$(file_size "$USAGE_STORE")" ]
  [ "$(memo_get '.stores.c.off')" = "$(file_size "$COST_STORE")" ]
  [ "$(memo_get '.stores.l.off')" = "$(file_size "$LINKS_STORE")" ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]
  grep -qF 'scan=full' "$TRACE" && return 1
  true
}

@test "warm-up tail: a torn final line is not consumed until it is complete" {
  base_stores
  init_memo
  local size
  size="$(file_size "$USAGE_STORE")"
  printf '{"schema_version":1,"kind":"segment","key":"branch:torn/1-x"' >>"$USAGE_STORE"
  warm_all
  [ "$(memo_get '.stores.u.off')" = "$size" ]
  [ "$(memo_get '.derive | has("branch:torn/1-x")')" = false ]
  printf ',"by_model":{"m-torn":{"fresh_input":1}}}\n' >>"$USAGE_STORE"
  warm_all
  [ "$(memo_get '.stores.u.off')" = "$(file_size "$USAGE_STORE")" ]
  [ "$(memo_get '.derive | has("branch:torn/1-x")')" = true ]
  [ "$(memo_get '.models | index("m-torn") != null')" = true ]
}

@test "warm-up: every model of a multi-model segment is picked up, and a model that needs an escape is left to the coverage check" {
  base_stores
  printf '{"schema_version":1,"kind":"segment","key":"session:s2","session_id":"s2","inherit":false,"first_ts":"2026-09-30T12:00:00.000Z","messages":1,"by_model":{"m-a":{"fresh_input":1,"output":1},"m-b":{"fresh_input":2,"output":1},"m-c":{"fresh_input":3,"output":1},"m\\"q":{"fresh_input":4,"output":1}}}\n' >>"$USAGE_STORE"
  init_memo
  [ "$(memo_get '.models | join(",")')" = "m-a,m-b,m-c,m-one,m-two" ]
}

# ---------- 7. full-scan triggers ----------

@test "full scan: a changed store path traces path" {
  base_stores
  init_memo
  cp "$USAGE_STORE" "$TEMPORARY_DIRECTORY/usage-moved.jsonl"
  : >"$TRACE"
  gaia_usage_memo_warm "$TEMPORARY_DIRECTORY/usage-moved.jsonl" "$LINKS_STORE" "$COST_STORE"
  [ "$(cat "$TRACE")" = "scan=full store=u reason=path" ]
}

@test "full scan: a store rewritten so its first bytes differ traces head and rebuilds the models" {
  base_stores
  init_memo
  {
    segment_row branch:other/2-y m-other
    segment_row branch:other/3-z m-other
    segment_row branch:other/4-z m-other
    segment_row branch:other/5-z m-other
  } >"$USAGE_STORE"
  [ "$(file_size "$USAGE_STORE")" -ge "$(memo_get '.stores.u.off')" ]
  : >"$TRACE"
  warm_all
  [ "$(cat "$TRACE")" = "scan=full store=u reason=head" ]
  [ "$(memo_get '.models | join(",")')" = "m-other" ]
}

@test "full scan: a shrunk store traces shrunk, and a full scan of usage rebuilds the models" {
  base_stores
  init_memo
  segment_row branch:only/1-x m-solo >"$USAGE_STORE"
  [ "$(file_size "$USAGE_STORE")" -lt "$(memo_get '.stores.u.off')" ]
  : >"$TRACE"
  warm_all
  [ "$(cat "$TRACE")" = "scan=full store=u reason=shrunk" ]
  [ "$(memo_get '.models | join(",")')" = "m-solo" ]
}

@test "full scan: growth past a small prefix does not force one, and the head covers the new size" {
  base_stores
  init_memo
  [ "$(memo_get '.stores.u.hn')" -lt 4096 ]
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do segment_row "branch:grow/$i-x" m-one >>"$USAGE_STORE"; done
  : >"$TRACE"
  warm_all
  grep -qF 'scan=full' "$TRACE" && return 1
  [ "$(memo_get '.stores.u.hn')" = 4096 ]
  : >"$TRACE"
  segment_row branch:grow/99-x m-one >>"$USAGE_STORE"
  warm_all
  grep -qF 'scan=full' "$TRACE" && return 1
  [ "$(memo_get '.derive | has("branch:grow/99-x")')" = true ]
  [ "$(memo_get '.stores.u.hn')" = 4096 ]
}

# ---------- 8. save ----------

inode_of() { ls -i "$1" | awk '{print $1}'; }

@test "save: every save replaces the file, the temp matches the registered glob, and none remains" {
  base_stores
  init_memo
  mktemp() { printf '%s\n' "$*" >>"$TEMPORARY_DIRECTORY/mktemp.log"; command mktemp "$@"; }
  gaia_usage_memo_save "$MEMO"
  local inode_before_first_save inode_after_second_save
  inode_before_first_save="$(inode_of "$MEMO")"
  segment_row branch:more/1-x m-one >>"$USAGE_STORE"
  warm_all
  gaia_usage_memo_save "$MEMO"
  inode_after_second_save="$(inode_of "$MEMO")"
  [ "$inode_before_first_save" != "$inode_after_second_save" ]
  [ "$(head -n 1 "$TEMPORARY_DIRECTORY/mktemp.log")" = "$TELEMETRY_DIRECTORY/.usage-branch-memo.tmp.XXXXXX" ]
  [ -z "$(find "$TELEMETRY_DIRECTORY" -name '.usage-branch-memo.tmp.*')" ]
  [ "$(last_trace)" = "write=ok" ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 0 ]
  [ "$(wc -l <"$MEMO" | tr -d ' ')" = 2 ]
  # Guard red: an in-place write keeps the inode, so the comparison above can fail.
  local inode_before_in_place_write
  inode_before_in_place_write="$(inode_of "$MEMO")"
  printf '%s\n' "$(cat "$MEMO")" >"$MEMO"
  [ "$(inode_of "$MEMO")" = "$inode_before_in_place_write" ]
}

@test "save: an unwritable directory prints nothing, leaves no temp, and returns 0" {
  base_stores
  init_memo
  chmod a-w "$TELEMETRY_DIRECTORY"
  if touch "$TELEMETRY_DIRECTORY/probe" 2>/dev/null; then
    chmod u+w "$TELEMETRY_DIRECTORY"
    printf 'directory is still writable (running as root?)\n' >&2
    return 1
  fi
  local save_output exit_status=0
  save_output="$(gaia_usage_memo_save "$MEMO" 2>"$TEMPORARY_DIRECTORY/err")" || exit_status=$?
  chmod u+w "$TELEMETRY_DIRECTORY"
  [ "$exit_status" -eq 0 ]
  [ -z "$save_output" ]
  [ ! -s "$TEMPORARY_DIRECTORY/err" ]
  [ ! -e "$MEMO" ]
  [ -z "$(find "$TELEMETRY_DIRECTORY" -name '.usage-branch-memo.tmp.*')" ]
  [ "$(last_trace)" = "write=fail" ]
}

# ---------- 9. reap ----------

@test "reap: a temp older than 60 s is removed, a fresh one and an unrelated name are kept" {
  : >"$TELEMETRY_DIRECTORY/.usage-branch-memo.tmp.OLD123"
  touch -t 202001010000 "$TELEMETRY_DIRECTORY/.usage-branch-memo.tmp.OLD123"
  : >"$TELEMETRY_DIRECTORY/.usage-branch-memo.tmp.NEW123"
  : >"$TELEMETRY_DIRECTORY/.usage-other.tmp.OLD123"
  touch -t 202001010000 "$TELEMETRY_DIRECTORY/.usage-other.tmp.OLD123"
  gaia_usage_memo_reap "$TELEMETRY_DIRECTORY"
  [ ! -e "$TELEMETRY_DIRECTORY/.usage-branch-memo.tmp.OLD123" ]
  [ -e "$TELEMETRY_DIRECTORY/.usage-branch-memo.tmp.NEW123" ]
  [ -e "$TELEMETRY_DIRECTORY/.usage-other.tmp.OLD123" ]
  [ "$(last_trace)" = "reap=1" ]
  : >"$TRACE"
  gaia_usage_memo_reap "$TELEMETRY_DIRECTORY"
  [ ! -s "$TRACE" ]
}

# ---------- 10. coverage jq ----------

# cover <memo-json> <keys-json>: the gap, the restricted-keys edges, and the
# full-keys edges, computed over the fixture stores.
cover() {
  jq -nc --rawfile usage_store "$USAGE_STORE" --rawfile links_store "$LINKS_STORE" --rawfile cost_store "$COST_STORE" --argjson memo "$1" --argjson keys "$2" --arg default_branch main \
    "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MEMO_JQ"'
    usage_rows($usage_store) as $usage_records | usage_rows($links_store) as $links | usage_rows($cost_store) as $cost
    | usage_present($usage_records; $links; $cost) as $present
    | usage_memo_gap($present; $memo) as $gap
    | usage_memo_keys($present; $memo; $default_branch) as $memo_keys
    | {present: $present, gap: $gap, restricted_edges: usage_edges($links; $cost; $memo_keys), full_edges: usage_edges($links; $cost; $keys), memo_keys: $memo_keys}'
}

@test "coverage jq: the restricted keys give today's edges, and a covering memo has no gap" {
  base_stores
  init_memo
  local keys cover_output
  keys="$(gaia_usage_keys_json "$TEMPORARY_DIRECTORY/nogit" "$USAGE_STORE" "$LINKS_STORE" "$COST_STORE")"
  cover_output="$(cover "$GAIA_USAGE_MEMO" "$keys")"
  [ "$(jq -c '.gap' <<<"$cover_output")" = null ]
  [ "$(jq '.restricted_edges | length' <<<"$cover_output")" -ge 4 ]
  [ "$(jq '.restricted_edges == .full_edges' <<<"$cover_output")" = true ]
  [ "$(jq -c '.present.raws' <<<"$cover_output")" = '["","has space","main","worktree-plan+spec-024-x"]' ]
  [ "$(jq -c --argjson store_keys "$keys" '.present.models == $store_keys.models and .present.raws == ($store_keys.bmap | keys)' <<<"$cover_output")" = true ]
  [ "$(jq -c '.memo_keys.models' <<<"$cover_output")" = '["m-one","m-two"]' ]
  # Every non-empty memo derive entry the stores name is in the restricted keys.
  [ "$(jq -c '.memo_keys.derive | keys' <<<"$cover_output")" = '["branch:feat/3-link","branch:fix/12-foo","branch:plan/spec-024-x"]' ]
}

@test "coverage jq: the gap names exactly what the memo lacks, in each direction" {
  base_stores
  init_memo
  local keys memo cover_output
  keys="$(gaia_usage_keys_json "$TEMPORARY_DIRECTORY/nogit" "$USAGE_STORE" "$LINKS_STORE" "$COST_STORE")"
  memo="$(jq -c 'del(.bmap["worktree-plan+spec-024-x"])' <<<"$GAIA_USAGE_MEMO")"
  cover_output="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$cover_output")" = '{"raws":["worktree-plan+spec-024-x"],"bkeys":[],"models":[],"models_extra":[]}' ]
  memo="$(jq -c 'del(.derive["branch:plan/spec-024-x"])' <<<"$GAIA_USAGE_MEMO")"
  cover_output="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$cover_output")" = '{"raws":[],"bkeys":["branch:plan/spec-024-x"],"models":[],"models_extra":[]}' ]
  memo="$(jq -c 'del(.derive["branch:feat/3-link"]) | .models = ["m-one"]' <<<"$GAIA_USAGE_MEMO")"
  cover_output="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$cover_output")" = '{"raws":[],"bkeys":["branch:feat/3-link"],"models":["m-two"],"models_extra":[]}' ]
  memo="$(jq -c '.models += ["ghost-model"]' <<<"$GAIA_USAGE_MEMO")"
  cover_output="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$cover_output")" = '{"raws":[],"bkeys":[],"models":[],"models_extra":["ghost-model"]}' ]
  GAIA_USAGE_MEMO="$memo"
  gaia_usage_memo_merge_gap "$(jq -c '.gap' <<<"$cover_output")"
  [ "$(memo_get '.models | join(",")')" = "m-one,m-two" ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]
}

@test "merge gap: derives the gap's raws and keys, and records the key a new raw implies" {
  base_stores
  init_memo
  GAIA_USAGE_MEMO_DIRTY=0
  gaia_usage_memo_merge_gap '{"raws":["worktree-plan+spec-055-gap"],"bkeys":["branch:fix/4-gapkey"],"models":["m-gap"],"models_extra":[]}'
  [ "$(memo_get '.bmap["worktree-plan+spec-055-gap"].key')" = "branch:plan/spec-055-gap" ]
  [ "$(memo_get '.derive["branch:plan/spec-055-gap"] | join(",")')" = "spec:SPEC-055" ]
  [ "$(memo_get '.derive["branch:fix/4-gapkey"] | join(",")')" = "issue:4" ]
  [ "$(memo_get '.models | index("m-gap") != null')" = true ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]
}

# ---------- 11. no lock ----------

@test "no lock: warm and save complete while the ledger lock is held" {
  base_stores
  export GAIA_LEDGER_LOCK_FORCE_FALLBACK=1
  mkdir "$TELEMETRY_DIRECTORY/specs.lock.d"
  local start_seconds end_seconds
  start_seconds="$(date +%s)"
  init_memo
  gaia_usage_memo_save "$MEMO"
  end_seconds="$(date +%s)"
  rmdir "$TELEMETRY_DIRECTORY/specs.lock.d"
  [ "$((end_seconds - start_seconds))" -le 3 ]
  [ -s "$MEMO" ]
  [ "$(last_trace)" = "write=ok" ]
}

# ---------- 12. escape-blind cost grep ----------

# escaped_absent <memo body>: true when neither spelling of the escaped raw is
# a bmap entry.
escaped_absent() {
  [ "$(jq 'has("plan/spec-030-esc") or has("plan\\/spec-030-esc")' <<<"$(jq -c .bmap <<<"$1")")" = false ]
}

escaped_stores() {
  {
    printf '{"schema_version":1,"kind":"plan","spec_id":"SPEC-030","git_branch":"plan\\/spec-030-esc"}\n'
    cost_row SPEC-031 worktree-plan+spec-031-ok
  } >"$COST_STORE"
  : >"$USAGE_STORE"
  : >"$LINKS_STORE"
}

@test "escape-blind grep: an escaped git_branch is left to the coverage check, a plain one is picked up" {
  escaped_stores
  grep -qF 'plan\/spec-030-esc' "$COST_STORE"
  init_memo
  [ "$(memo_get '.bmap | has("worktree-plan+spec-031-ok")')" = true ]
  escaped_absent "$GAIA_USAGE_MEMO"
}

@test "escape-blind grep guard red: a decoding cost grep puts the escaped raw into bmap, and the absence check fails on it" {
  escaped_stores
  scratch_libraries "$TEMPORARY_DIRECTORY/libs-e"
  subst_file "$TEMPORARY_DIRECTORY/libs-e/usage-memo-lib.sh" "grep -oE '\"git_branch\":\"[^\"\\\\]*\"'" "grep -oE '\"git_branch\":\"([^\"\\\\]|\\\\.)*\"'"
  subst_file "$TEMPORARY_DIRECTORY/libs-e/usage-memo-lib.sh" "r: [inputs]}'" "r: [inputs | (\"\\\"\" + . + \"\\\"\" | fromjson)]}'"
  local body
  body="$(in_libraries "$BASH" "$TEMPORARY_DIRECTORY/libs-e" 'gaia_usage_memo_stamp; gaia_usage_memo_load "$1/m.json"; gaia_usage_memo_warm "$2" "$3" "$4"; printf "%s" "$GAIA_USAGE_MEMO"' "$TELEMETRY_DIRECTORY" "$USAGE_STORE" "$LINKS_STORE" "$COST_STORE" 2>/dev/null)" || true
  [ -n "$body" ]
  if escaped_absent "$body"; then return 1; fi
  [ "$(jq 'has("plan/spec-030-esc")' <<<"$(jq -c .bmap <<<"$body")")" = true ]
}

# ---------- 13. dirty flag and stamp reuse ----------

@test "dirty flag: cold load 1, warm load 0, unchanged warm-up 0, appended warm-up 1, save 0" {
  base_stores
  gaia_usage_memo_stamp
  gaia_usage_memo_load "$MEMO"
  [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]
  warm_all
  gaia_usage_memo_save "$MEMO"
  [ "$GAIA_USAGE_MEMO_DIRTY" = 0 ]
  gaia_usage_memo_load "$MEMO"
  [ "$GAIA_USAGE_MEMO_STATE" = warm ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 0 ]
  warm_all
  [ "$GAIA_USAGE_MEMO_DIRTY" = 0 ]
  segment_row branch:dirty/1-x m-one >>"$USAGE_STORE"
  warm_all
  [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]
  gaia_usage_memo_save "$MEMO"
  [ "$GAIA_USAGE_MEMO_DIRTY" = 0 ]
}

@test "stamp reuse: load reads the stamp a prior call left, never computes it, and an unset result is unavailable" {
  base_stores
  init_memo
  gaia_usage_memo_save "$MEMO"
  eval "orig_hash16$(declare -f _gaia_usage_hash16 | sed '1s/^_gaia_usage_hash16//')"
  _gaia_usage_hash16() { printf '%.20s\n' "$1" >>"$TEMPORARY_DIRECTORY/hash.log"; orig_hash16 "$@"; }
  : >"$TEMPORARY_DIRECTORY/hash.log"
  : >"$TRACE"
  gaia_usage_memo_load "$MEMO"
  [ "$(last_trace)" = "path=warm" ]
  [ "$(wc -l <"$TEMPORARY_DIRECTORY/hash.log" | tr -d ' ')" = 1 ]
  grep -qF 'usage-branch-memo/1' "$TEMPORARY_DIRECTORY/hash.log" && return 1
  unset _gaia_usage_memo_stamp_exit_status
  [ "$(load_reason)" = "path=cold reason=stamp-unavailable" ]
}

# ---------- 14. seam ----------

@test "seam: runs the script when enabled, ignores its status, and does nothing when either gate is empty" {
  printf '#!/bin/sh\ntouch "%s/marker"\nexit 1\n' "$TEMPORARY_DIRECTORY" >"$TEMPORARY_DIRECTORY/seam.sh"
  export GAIA_USAGE_MEMO_SEAM="$TEMPORARY_DIRECTORY/seam.sh"
  local seam_output
  seam_output="$(gaia_usage_memo_seam 2>&1)"
  [ -z "$seam_output" ]
  [ -e "$TEMPORARY_DIRECTORY/marker" ]
  rm -f "$TEMPORARY_DIRECTORY/marker"
  BATS_TEST_TMPDIR='' gaia_usage_memo_seam
  if [ -e "$TEMPORARY_DIRECTORY/marker" ]; then return 1; fi
  GAIA_USAGE_MEMO_SEAM='' gaia_usage_memo_seam
  if [ -e "$TEMPORARY_DIRECTORY/marker" ]; then return 1; fi
  gaia_usage_memo_seam
  [ -e "$TEMPORARY_DIRECTORY/marker" ]
}

# ---------- 15. silence ----------

@test "silent stderr: every function stays quiet against broken inputs" {
  local error_file="$TEMPORARY_DIRECTORY/err" bad="$TEMPORARY_DIRECTORY/dir-as-store"
  mkdir "$bad"
  base_stores
  gaia_usage_memo_stamp 2>"$error_file"
  [ ! -s "$error_file" ]
  # An unreadable memo, and one whose body is not JSON.
  printf '%s\n%s\n' "$(valid_header 'not json')" 'not json' >"$MEMO"
  gaia_usage_memo_load "$MEMO" 2>"$error_file"
  [ ! -s "$error_file" ]
  [ "$GAIA_USAGE_MEMO_STATE" = cold ]
  chmod 000 "$MEMO"
  gaia_usage_memo_load "$MEMO" 2>"$error_file"
  [ ! -s "$error_file" ]
  chmod 600 "$MEMO"
  # A store path that is a directory, and one that does not exist.
  gaia_usage_memo_warm "$bad" "$TELEMETRY_DIRECTORY/absent-l" "$bad" 2>"$error_file"
  [ ! -s "$error_file" ]
  chmod 000 "$USAGE_STORE"
  gaia_usage_memo_warm "$USAGE_STORE" "$LINKS_STORE" "$COST_STORE" 2>"$error_file"
  [ ! -s "$error_file" ]
  chmod 600 "$USAGE_STORE"
  gaia_usage_memo_merge_gap 'not json' 2>"$error_file"
  [ ! -s "$error_file" ]
  GAIA_USAGE_MEMO='garbage'
  gaia_usage_memo_warm "$USAGE_STORE" "$LINKS_STORE" "$COST_STORE" 2>"$error_file"
  [ ! -s "$error_file" ]
  gaia_usage_memo_merge_gap '{"raws":["x"],"bkeys":[],"models":[],"models_extra":[]}' 2>"$error_file"
  [ ! -s "$error_file" ]
  gaia_usage_memo_save "$TEMPORARY_DIRECTORY/no-such-dir/memo.json" 2>"$error_file"
  [ ! -s "$error_file" ]
  gaia_usage_memo_reap "$TEMPORARY_DIRECTORY/no-such-dir" 2>"$error_file"
  [ ! -s "$error_file" ]
  GAIA_USAGE_MEMO_TRACE="$TEMPORARY_DIRECTORY/no-such-dir/trace" gaia_usage_memo_trace "x" 2>"$error_file"
  [ ! -s "$error_file" ]
  gaia_usage_memo_seam 2>"$error_file"
  [ ! -s "$error_file" ]
}
