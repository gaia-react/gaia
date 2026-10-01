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
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  TD="$TMP/tel"
  mkdir -p "$TD"
  U="$TD/usage.jsonl"
  L="$TD/links.jsonl"
  C="$TD/cost.jsonl"
  MEMO="$TD/usage-branch-memo.json"
  TRACE="$TMP/trace"
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
  chmod -R u+rwx "$TMP" 2>/dev/null || true
}

# ---------- fixtures ----------

seg() {
  printf '{"schema_version":1,"kind":"segment","key":"%s","session_id":"s1","inherit":false,"first_ts":"2026-09-30T12:00:00.000Z","last_ts":"2026-09-30T12:01:00.000Z","messages":1,"by_model":{"%s":{"fresh_input":1,"cache_write_5m":0,"cache_write_1h":0,"cache_read":0,"output":1}}}\n' "$1" "$2"
}
lnk() {
  printf '{"schema_version":1,"kind":"edge","child":"%s","parent":"%s","source":"link-command","ts":"2026-09-30T12:00:00Z","session_id":"s1"}\n' "$1" "$2"
}
cst() {
  printf '{"schema_version":1,"kind":"plan","spec_id":"%s","plan_id":null,"session_id":"s1","by_model":{},"git_branch":"%s"}\n' "$1" "$2"
}

# base_stores: raws in worktree spelling, a hashed key, a name with no parents,
# the default branch, the empty raw, and a link-only key.
base_stores() {
  {
    seg session:s1 m-one
    seg branch:fix/12-foo m-one
    seg branch:chore/update-deps m-two
  } >"$U"
  {
    lnk pr:5 branch:fix/12-foo
    lnk pr:6 branch:feat/3-link
  } >"$L"
  {
    cst SPEC-024 worktree-plan+spec-024-x
    cst SPEC-025 "has space"
    cst SPEC-026 main
    cst SPEC-027 ""
  } >"$C"
}

warm_all() { gaia_usage_memo_warm "$U" "$L" "$C"; }

# init_memo: stamp, a cold load of the (absent) memo, then a warm-up.
init_memo() {
  gaia_usage_memo_stamp
  gaia_usage_memo_load "$MEMO"
  warm_all
}

memo_get() { jq -r "$1" <<<"$GAIA_USAGE_MEMO"; }

last_trace() { tail -n 1 "$TRACE"; }

fsize() {
  local n
  n="$(wc -c <"$1")"
  printf '%s' "${n//[[:space:]]/}"
}

# subst_file <file> <old> <new>: replaces the first literal occurrence, failing
# when it is absent, so a mutant can never be a copy of the original. Values go
# through ENVIRON because awk -v would process the backslashes.
subst_file() {
  local before after
  before="$(cat "$1")"
  after="$(S_OLD="$2" S_NEW="$3" awk '
    BEGIN { o = ENVIRON["S_OLD"]; n = ENVIRON["S_NEW"] }
    !done && (i = index($0, o)) { $0 = substr($0, 1, i - 1) n substr($0, i + length(o)); done = 1 }
    { print }' "$1")"
  [ "$before" != "$after" ] || return 1
  printf '%s\n' "$after" >"$1"
}

# scratch_libs <dir>: the four libs the stamp reads, copied beside one another.
scratch_libs() {
  mkdir -p "$1"
  cp "$SCRIPTS/usage-lib.sh" "$SCRIPTS/usage-resolve-lib.sh" "$SCRIPTS/branch-name-lib.sh" "$SCRIPTS/usage-memo-lib.sh" "$1/"
}

# in_libs <interp> <libdir> <script> [arg...]: runs <script> in a child shell
# that has sourced the libs from <libdir>; the args are its $1, $2, ...
in_libs() {
  local sh="$1"
  shift
  "$sh" -c 'd="$1"; s="$2"; shift 2; source "$d/usage-lib.sh"; source "$d/usage-resolve-lib.sh"; source "$d/usage-memo-lib.sh"; eval "$s"' _ "$@"
}

# ---------- 1. stamp closure ----------

# closure <name>...: every function reachable from the names, to a fixed point,
# through the words of each `declare -f` body that `declare -F` knows.
closure() {
  local acc=$'\n' n w word changed=1
  for n in "$@"; do acc="$acc$n"$'\n'; done
  while [ "$changed" = 1 ]; do
    changed=0
    for w in $acc; do
      for word in $(declare -f "$w" | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | sort -u); do
        case "$acc" in *$'\n'"$word"$'\n'*) continue ;; esac
        declare -F "$word" >/dev/null 2>&1 || continue
        acc="$acc$word"$'\n'
        changed=1
      done
    done
  done
  printf '%s' "$acc" | sed '/^$/d' | sort
}

# reach_set: the closure from the derivation entry points plus every stamped
# memo-lib function, after branch-name-lib.sh is loaded.
reach_set() {
  local n entries="gaia_usage_branch_map gaia_usage_derive_map _gaia_usage_branch_parents"
  for n in $GAIA_USAGE_MEMO_FNS; do
    case "$n" in *memo*) entries="$entries $n" ;; esac
  done
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh
  # shellcheck disable=SC2086  # a space-separated name list, split on purpose
  closure $entries
}

# closure_missing <fnlist>: the reachable names <fnlist> does not carry.
closure_missing() {
  local n
  for n in $(reach_set); do
    case " $1 " in *" $n "*) ;; *) printf '%s\n' "$n" ;; esac
  done
}

@test "stamp closure: every function reachable from the derivation entry points is stamped" {
  local missing reach n
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh
  reach="$(reach_set)"
  [ "$(printf '%s\n' "$reach" | wc -l | tr -d ' ')" -gt 10 ]
  case $'\n'"$reach"$'\n' in *$'\n'_gaia_branch_set_class$'\n'*) ;; *) return 1 ;; esac
  missing="$(closure_missing "$GAIA_USAGE_MEMO_FNS")"
  [ -z "$missing" ] || { printf 'reachable but unstamped:\n%s\n' "$missing" >&2; return 1; }
  # Every stamped name is a defined function, so a rename cannot hide in the list.
  for n in $GAIA_USAGE_MEMO_FNS; do
    declare -F "$n" >/dev/null || { printf 'stamped but undefined: %s\n' "$n" >&2; return 1; }
  done
}

@test "stamp closure guard red: a list missing one reachable name is reported" {
  local trimmed missing
  trimmed=" $GAIA_USAGE_MEMO_FNS "
  trimmed="${trimmed/ _gaia_branch_set_class / }"
  [ "$trimmed" != " $GAIA_USAGE_MEMO_FNS " ]
  missing="$(closure_missing "$trimmed")"
  [ "$missing" = "_gaia_branch_set_class" ]
}

# ---------- 2-4. stamp ----------

stamp_in() { in_libs "${2:-$BASH}" "$1" 'gaia_usage_memo_stamp; printf "%s %s" "$_gaia_usage_memo_stamp_rc" "$_gaia_usage_memo_stamp"'; }

@test "stamp sensitivity: a stamped function's body changes it, an unstamped one's does not" {
  local base edited other
  scratch_libs "$TMP/libs-a"
  base="$(stamp_in "$TMP/libs-a")"
  case "$base" in "0 "*) ;; *) return 1 ;; esac
  scratch_libs "$TMP/libs-b"
  subst_file "$TMP/libs-b/branch-name-lib.sh" 'local nb mode="adhoc"' 'local nb mode="adhoc2"'
  edited="$(stamp_in "$TMP/libs-b")"
  [ "$edited" != "$base" ]
  scratch_libs "$TMP/libs-c"
  subst_file "$TMP/libs-c/usage-lib.sh" 'if [ -n "${GAIA_TALLY_PROJECTS_ROOT:-}" ]; then' 'if [ -n "${GAIA_TALLY_PROJECTS_ROOT:-}" ] && :; then'
  other="$(stamp_in "$TMP/libs-c")"
  [ "$other" = "$base" ]
}

@test "stamp shell independence: bash 3.2 and bash 5 compute the same stamp" {
  local sh seen="" first="" got n=0
  for sh in /bin/bash "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$sh" ] || continue
    case " $seen " in *" $sh "*) continue ;; esac
    seen="$seen $sh"
    got="$(stamp_in "$SCRIPTS" "$sh")"
    case "$got" in "0 "*) ;; *) return 1 ;; esac
    if [ -z "$first" ]; then first="$got"; fi
    [ "$got" = "$first" ]
    n=$((n + 1))
  done
  [ "$n" -ge 1 ]
  printf '# stamp shell independence covered %s shell(s):%s\n' "$n" "$seen" >&3
}

@test "stamp unavailable: a stamped name that extracts empty returns 1, and save writes nothing" {
  scratch_libs "$TMP/libs-d"
  subst_file "$TMP/libs-d/branch-name-lib.sh" 'gaia_branch_members() {' 'gaia_branch_members_renamed() {'
  run in_libs "$BASH" "$TMP/libs-d" 'gaia_usage_memo_stamp; echo "rc=$? sr=$_gaia_usage_memo_stamp_rc"; GAIA_USAGE_MEMO="{}"; gaia_usage_memo_save "$1/memo.json"' "$TD"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=1 sr=1" ]
  [ "$(last_trace)" = "write=skip" ]
  [ ! -e "$TD/memo.json" ]
  [ -z "$(find "$TD" -name '.usage-branch-memo.tmp.*')" ]
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
  local body='{"bmap":{},"derive":{},"models":[],"stores":{}}' h
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
  h="$(jq -r '.models[0]' <<<"$GAIA_USAGE_MEMO")"
  [ "$h" = m ]
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
  gaia_usage_branch_map() { printf '%s\n' "$@" >>"$TMP/bmap.args"; orig_branch_map "$@"; }
  gaia_usage_derive_map() { printf '%s\n' "$@" >>"$TMP/derive.args"; orig_derive_map "$@"; }
  : >"$TMP/bmap.args"
  : >"$TMP/derive.args"
}

@test "warm-up tail: appended rows derive exactly the new raw, key, and model, and the offset advances" {
  base_stores
  init_memo
  [ "$(memo_get '.bmap | keys | join(",")')" = ",has space,main,worktree-plan+spec-024-x" ]
  [ "$(memo_get '.models | join(",")')" = "m-one,m-two" ]
  gaia_usage_memo_save "$MEMO"
  gaia_usage_memo_load "$MEMO"
  wrap_derivations
  seg branch:topic/77-new m-three >>"$U"
  cst SPEC-090 worktree-plan+spec-090-q >>"$C"
  : >"$TRACE"
  warm_all
  [ "$(cat "$TMP/bmap.args")" = "worktree-plan+spec-090-q" ]
  [ "$(cat "$TMP/derive.args")" = $'branch:plan/spec-090-q\nbranch:topic/77-new' ]
  [ "$(memo_get '.derive["branch:topic/77-new"] | length')" = 0 ]
  [ "$(memo_get '.derive["branch:plan/spec-090-q"] | join(",")')" = "spec:SPEC-090" ]
  [ "$(memo_get '.models | join(",")')" = "m-one,m-three,m-two" ]
  [ "$(memo_get '.stores.u.off')" = "$(fsize "$U")" ]
  [ "$(memo_get '.stores.c.off')" = "$(fsize "$C")" ]
  [ "$(memo_get '.stores.l.off')" = "$(fsize "$L")" ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]
  grep -qF 'scan=full' "$TRACE" && return 1
  true
}

@test "warm-up tail: a torn final line is not consumed until it is complete" {
  base_stores
  init_memo
  local size
  size="$(fsize "$U")"
  printf '{"schema_version":1,"kind":"segment","key":"branch:torn/1-x"' >>"$U"
  warm_all
  [ "$(memo_get '.stores.u.off')" = "$size" ]
  [ "$(memo_get '.derive | has("branch:torn/1-x")')" = false ]
  printf ',"by_model":{"m-torn":{"fresh_input":1}}}\n' >>"$U"
  warm_all
  [ "$(memo_get '.stores.u.off')" = "$(fsize "$U")" ]
  [ "$(memo_get '.derive | has("branch:torn/1-x")')" = true ]
  [ "$(memo_get '.models | index("m-torn") != null')" = true ]
}

@test "warm-up: every model of a multi-model segment is picked up, and a model that needs an escape is left to the coverage check" {
  base_stores
  printf '{"schema_version":1,"kind":"segment","key":"session:s2","session_id":"s2","inherit":false,"first_ts":"2026-09-30T12:00:00.000Z","messages":1,"by_model":{"m-a":{"fresh_input":1,"output":1},"m-b":{"fresh_input":2,"output":1},"m-c":{"fresh_input":3,"output":1},"m\\"q":{"fresh_input":4,"output":1}}}\n' >>"$U"
  init_memo
  [ "$(memo_get '.models | join(",")')" = "m-a,m-b,m-c,m-one,m-two" ]
}

# ---------- 7. full-scan triggers ----------

@test "full scan: a changed store path traces path" {
  base_stores
  init_memo
  cp "$U" "$TMP/usage-moved.jsonl"
  : >"$TRACE"
  gaia_usage_memo_warm "$TMP/usage-moved.jsonl" "$L" "$C"
  [ "$(cat "$TRACE")" = "scan=full store=u reason=path" ]
}

@test "full scan: a store rewritten so its first bytes differ traces head and rebuilds the models" {
  base_stores
  init_memo
  {
    seg branch:other/2-y m-other
    seg branch:other/3-z m-other
    seg branch:other/4-z m-other
    seg branch:other/5-z m-other
  } >"$U"
  [ "$(fsize "$U")" -ge "$(memo_get '.stores.u.off')" ]
  : >"$TRACE"
  warm_all
  [ "$(cat "$TRACE")" = "scan=full store=u reason=head" ]
  [ "$(memo_get '.models | join(",")')" = "m-other" ]
}

@test "full scan: a shrunk store traces shrunk, and a full scan of usage rebuilds the models" {
  base_stores
  init_memo
  seg branch:only/1-x m-solo >"$U"
  [ "$(fsize "$U")" -lt "$(memo_get '.stores.u.off')" ]
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
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do seg "branch:grow/$i-x" m-one >>"$U"; done
  : >"$TRACE"
  warm_all
  grep -qF 'scan=full' "$TRACE" && return 1
  [ "$(memo_get '.stores.u.hn')" = 4096 ]
  : >"$TRACE"
  seg branch:grow/99-x m-one >>"$U"
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
  mktemp() { printf '%s\n' "$*" >>"$TMP/mktemp.log"; command mktemp "$@"; }
  gaia_usage_memo_save "$MEMO"
  local i1 i2
  i1="$(inode_of "$MEMO")"
  seg branch:more/1-x m-one >>"$U"
  warm_all
  gaia_usage_memo_save "$MEMO"
  i2="$(inode_of "$MEMO")"
  [ "$i1" != "$i2" ]
  [ "$(head -n 1 "$TMP/mktemp.log")" = "$TD/.usage-branch-memo.tmp.XXXXXX" ]
  [ -z "$(find "$TD" -name '.usage-branch-memo.tmp.*')" ]
  [ "$(last_trace)" = "write=ok" ]
  [ "$GAIA_USAGE_MEMO_DIRTY" = 0 ]
  [ "$(wc -l <"$MEMO" | tr -d ' ')" = 2 ]
  # Guard red: an in-place write keeps the inode, so the comparison above can fail.
  local i3
  i3="$(inode_of "$MEMO")"
  printf '%s\n' "$(cat "$MEMO")" >"$MEMO"
  [ "$(inode_of "$MEMO")" = "$i3" ]
}

@test "save: an unwritable directory prints nothing, leaves no temp, and returns 0" {
  base_stores
  init_memo
  chmod a-w "$TD"
  if touch "$TD/probe" 2>/dev/null; then
    chmod u+w "$TD"
    printf 'directory is still writable (running as root?)\n' >&2
    return 1
  fi
  local out rc=0
  out="$(gaia_usage_memo_save "$MEMO" 2>"$TMP/err")" || rc=$?
  chmod u+w "$TD"
  [ "$rc" -eq 0 ]
  [ -z "$out" ]
  [ ! -s "$TMP/err" ]
  [ ! -e "$MEMO" ]
  [ -z "$(find "$TD" -name '.usage-branch-memo.tmp.*')" ]
  [ "$(last_trace)" = "write=fail" ]
}

# ---------- 9. reap ----------

@test "reap: a temp older than 60 s is removed, a fresh one and an unrelated name are kept" {
  : >"$TD/.usage-branch-memo.tmp.OLD123"
  touch -t 202001010000 "$TD/.usage-branch-memo.tmp.OLD123"
  : >"$TD/.usage-branch-memo.tmp.NEW123"
  : >"$TD/.usage-other.tmp.OLD123"
  touch -t 202001010000 "$TD/.usage-other.tmp.OLD123"
  gaia_usage_memo_reap "$TD"
  [ ! -e "$TD/.usage-branch-memo.tmp.OLD123" ]
  [ -e "$TD/.usage-branch-memo.tmp.NEW123" ]
  [ -e "$TD/.usage-other.tmp.OLD123" ]
  [ "$(last_trace)" = "reap=1" ]
  : >"$TRACE"
  gaia_usage_memo_reap "$TD"
  [ ! -s "$TRACE" ]
}

# ---------- 10. coverage jq ----------

# cover <memo-json> <keys-json>: the gap, the restricted-keys edges, and the
# full-keys edges, computed over the fixture stores.
cover() {
  jq -nc --rawfile u "$U" --rawfile l "$L" --rawfile c "$C" --argjson memo "$1" --argjson keys "$2" --arg def main \
    "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MEMO_JQ"'
    usage_rows($u) as $ur | usage_rows($l) as $ln | usage_rows($c) as $co
    | usage_present($ur; $ln; $co) as $p
    | usage_memo_gap($p; $memo) as $gap
    | usage_memo_keys($p; $memo; $def) as $mk
    | {present: $p, gap: $gap, e1: usage_edges($ln; $co; $mk), e2: usage_edges($ln; $co; $keys), mk: $mk}'
}

@test "coverage jq: the restricted keys give today's edges, and a covering memo has no gap" {
  base_stores
  init_memo
  local keys out
  keys="$(gaia_usage_keys_json "$TMP/nogit" "$U" "$L" "$C")"
  out="$(cover "$GAIA_USAGE_MEMO" "$keys")"
  [ "$(jq -c '.gap' <<<"$out")" = null ]
  [ "$(jq '.e1 | length' <<<"$out")" -ge 4 ]
  [ "$(jq '.e1 == .e2' <<<"$out")" = true ]
  [ "$(jq -c '.present.raws' <<<"$out")" = '["","has space","main","worktree-plan+spec-024-x"]' ]
  [ "$(jq -c --argjson k "$keys" '.present.models == $k.models and .present.raws == ($k.bmap | keys)' <<<"$out")" = true ]
  [ "$(jq -c '.mk.models' <<<"$out")" = '["m-one","m-two"]' ]
  # Every non-empty memo derive entry the stores name is in the restricted keys.
  [ "$(jq -c '.mk.derive | keys' <<<"$out")" = '["branch:feat/3-link","branch:fix/12-foo","branch:plan/spec-024-x"]' ]
}

@test "coverage jq: the gap names exactly what the memo lacks, in each direction" {
  base_stores
  init_memo
  local keys memo out
  keys="$(gaia_usage_keys_json "$TMP/nogit" "$U" "$L" "$C")"
  memo="$(jq -c 'del(.bmap["worktree-plan+spec-024-x"])' <<<"$GAIA_USAGE_MEMO")"
  out="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$out")" = '{"raws":["worktree-plan+spec-024-x"],"bkeys":[],"models":[],"models_extra":[]}' ]
  memo="$(jq -c 'del(.derive["branch:plan/spec-024-x"])' <<<"$GAIA_USAGE_MEMO")"
  out="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$out")" = '{"raws":[],"bkeys":["branch:plan/spec-024-x"],"models":[],"models_extra":[]}' ]
  memo="$(jq -c 'del(.derive["branch:feat/3-link"]) | .models = ["m-one"]' <<<"$GAIA_USAGE_MEMO")"
  out="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$out")" = '{"raws":[],"bkeys":["branch:feat/3-link"],"models":["m-two"],"models_extra":[]}' ]
  memo="$(jq -c '.models += ["ghost-model"]' <<<"$GAIA_USAGE_MEMO")"
  out="$(cover "$memo" "$keys")"
  [ "$(jq -c '.gap' <<<"$out")" = '{"raws":[],"bkeys":[],"models":[],"models_extra":["ghost-model"]}' ]
  GAIA_USAGE_MEMO="$memo"
  gaia_usage_memo_merge_gap "$(jq -c '.gap' <<<"$out")"
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
  mkdir "$TD/specs.lock.d"
  local t0 t1
  t0="$(date +%s)"
  init_memo
  gaia_usage_memo_save "$MEMO"
  t1="$(date +%s)"
  rmdir "$TD/specs.lock.d"
  [ "$((t1 - t0))" -le 3 ]
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
    cst SPEC-031 worktree-plan+spec-031-ok
  } >"$C"
  : >"$U"
  : >"$L"
}

@test "escape-blind grep: an escaped git_branch is left to the coverage check, a plain one is picked up" {
  escaped_stores
  grep -qF 'plan\/spec-030-esc' "$C"
  init_memo
  [ "$(memo_get '.bmap | has("worktree-plan+spec-031-ok")')" = true ]
  escaped_absent "$GAIA_USAGE_MEMO"
}

@test "escape-blind grep guard red: a decoding cost grep puts the escaped raw into bmap, and the absence check fails on it" {
  escaped_stores
  scratch_libs "$TMP/libs-e"
  subst_file "$TMP/libs-e/usage-memo-lib.sh" "grep -oE '\"git_branch\":\"[^\"\\\\]*\"'" "grep -oE '\"git_branch\":\"([^\"\\\\]|\\\\.)*\"'"
  subst_file "$TMP/libs-e/usage-memo-lib.sh" "r: [inputs]}'" "r: [inputs | (\"\\\"\" + . + \"\\\"\" | fromjson)]}'"
  local body
  body="$(in_libs "$BASH" "$TMP/libs-e" 'gaia_usage_memo_stamp; gaia_usage_memo_load "$1/m.json"; gaia_usage_memo_warm "$2" "$3" "$4"; printf "%s" "$GAIA_USAGE_MEMO"' "$TD" "$U" "$L" "$C" 2>/dev/null)" || true
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
  seg branch:dirty/1-x m-one >>"$U"
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
  _gaia_usage_hash16() { printf '%.20s\n' "$1" >>"$TMP/hash.log"; orig_hash16 "$@"; }
  : >"$TMP/hash.log"
  : >"$TRACE"
  gaia_usage_memo_load "$MEMO"
  [ "$(last_trace)" = "path=warm" ]
  [ "$(wc -l <"$TMP/hash.log" | tr -d ' ')" = 1 ]
  grep -qF 'usage-branch-memo/1' "$TMP/hash.log" && return 1
  unset _gaia_usage_memo_stamp_rc
  [ "$(load_reason)" = "path=cold reason=stamp-unavailable" ]
}

# ---------- 14. seam ----------

@test "seam: runs the script when enabled, ignores its status, and does nothing when either gate is empty" {
  printf '#!/bin/sh\ntouch "%s/marker"\nexit 1\n' "$TMP" >"$TMP/seam.sh"
  export GAIA_USAGE_MEMO_SEAM="$TMP/seam.sh"
  local out
  out="$(gaia_usage_memo_seam 2>&1)"
  [ -z "$out" ]
  [ -e "$TMP/marker" ]
  rm -f "$TMP/marker"
  BATS_TEST_TMPDIR='' gaia_usage_memo_seam
  if [ -e "$TMP/marker" ]; then return 1; fi
  GAIA_USAGE_MEMO_SEAM='' gaia_usage_memo_seam
  if [ -e "$TMP/marker" ]; then return 1; fi
  gaia_usage_memo_seam
  [ -e "$TMP/marker" ]
}

# ---------- 15. silence ----------

@test "silent stderr: every function stays quiet against broken inputs" {
  local err="$TMP/err" bad="$TMP/dir-as-store"
  mkdir "$bad"
  base_stores
  gaia_usage_memo_stamp 2>"$err"
  [ ! -s "$err" ]
  # An unreadable memo, and one whose body is not JSON.
  printf '%s\n%s\n' "$(valid_header 'not json')" 'not json' >"$MEMO"
  gaia_usage_memo_load "$MEMO" 2>"$err"
  [ ! -s "$err" ]
  [ "$GAIA_USAGE_MEMO_STATE" = cold ]
  chmod 000 "$MEMO"
  gaia_usage_memo_load "$MEMO" 2>"$err"
  [ ! -s "$err" ]
  chmod 600 "$MEMO"
  # A store path that is a directory, and one that does not exist.
  gaia_usage_memo_warm "$bad" "$TD/absent-l" "$bad" 2>"$err"
  [ ! -s "$err" ]
  chmod 000 "$U"
  gaia_usage_memo_warm "$U" "$L" "$C" 2>"$err"
  [ ! -s "$err" ]
  chmod 600 "$U"
  gaia_usage_memo_merge_gap 'not json' 2>"$err"
  [ ! -s "$err" ]
  GAIA_USAGE_MEMO='garbage'
  gaia_usage_memo_warm "$U" "$L" "$C" 2>"$err"
  [ ! -s "$err" ]
  gaia_usage_memo_merge_gap '{"raws":["x"],"bkeys":[],"models":[],"models_extra":[]}' 2>"$err"
  [ ! -s "$err" ]
  gaia_usage_memo_save "$TMP/no-such-dir/memo.json" 2>"$err"
  [ ! -s "$err" ]
  gaia_usage_memo_reap "$TMP/no-such-dir" 2>"$err"
  [ ! -s "$err" ]
  GAIA_USAGE_MEMO_TRACE="$TMP/no-such-dir/trace" gaia_usage_memo_trace "x" 2>"$err"
  [ ! -s "$err" ]
  gaia_usage_memo_seam 2>"$err"
  [ ! -s "$err" ]
}
