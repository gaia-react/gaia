#!/usr/bin/env bash
# Records transcript usage into the usage ledger (usage.jsonl): one `segment`
# row per run of same-key assistant usage, `binding` rows for research writes
# and workflow starts, and one `cursor` row per committed file. Attribution is
# not decided here; readers resolve it at read time.
#
#   usage-flush.sh --session <sid> [--transcript <path>] [--finished-main]
#   usage-flush.sh --sweep [--self-session <sid>]
#   common: [--projects-root <dir>] [--main-root <dir>] [--telemetry-dir <dir>] [--ledger <cost.jsonl>]
#
# Contract with the hooks that call it: always exits 0, prints nothing on
# stdout, diagnostics on stderr. `--finished-main` asserts the session's main
# transcript is quiescent up to its current size (Stop and the merge hook fire
# only after the issuing message is complete), which lets the trailing message
# group commit instead of waiting for its final duplicate line.
#
# Counted-once invariant: every usage message lands in exactly one segment at
# its final value. It rests on four mechanisms that only hold together:
#   - holdback: the last message's group is not committed until the file is
#     known finished, because streaming writes the same message id again with
#     a larger output_tokens;
#   - the per (session, role) high-water mark: a relocated copy, a truncated
#     and rewritten file, or a reparse after a lost race counts nothing twice;
#   - compare-and-swap: a commit aborts when another flusher committed a cursor
#     for the same (session, role) since this one read the ledger;
#   - per-file commits: a sweep killed midway loses only its uncommitted file.
#
# Knobs: GAIA_USAGE_LIVE_SECS (300, a sweep treats a newer file as still being
# written), GAIA_USAGE_SIDECAR_QUIET_SECS (60, the same for a sidecar in
# session mode), GAIA_USAGE_SWEEP_BUDGET_SECS (240, a sweep starts no new file
# after this; the next SessionStart resumes from the committed cursors).
# Test seams, unset in production: GAIA_USAGE_TEST_BARRIER=<path> touches
# <path>.parsed after each file's parse and waits (10 s at most) for <path>
# before taking the lock; GAIA_USAGE_DEBUG_HOLD=1 reports each commit's lock
# hold time on stderr.

_uf_src="${BASH_SOURCE[0]:-$0}"
case "$_uf_src" in */*) UF_DIR="${_uf_src%/*}" ;; *) UF_DIR=. ;; esac

_uf_log() { printf 'usage-flush: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=usage-lib.sh
. "$UF_DIR/usage-lib.sh" 2>/dev/null || exit 0
gaia_usage_in_ci && exit 0
# shellcheck source=usage-parse-lib.sh
. "$UF_DIR/usage-parse-lib.sh" 2>/dev/null || exit 0

UF_SESSION="" UF_TRANSCRIPT="" UF_FINISHED_MAIN=false UF_SWEEP=0 UF_SELF=""
UF_PROJECTS="" UF_MAIN="" UF_TEL="" UF_COST="" UF_TEL_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --finished-main) UF_FINISHED_MAIN=true; shift; continue ;;
    --sweep) UF_SWEEP=1; shift; continue ;;
    --session | --transcript | --self-session | --projects-root | --main-root | --telemetry-dir | --ledger)
      [ $# -ge 2 ] || { _uf_log "missing value for ${1//[^A-Za-z0-9._=\/-]/?}"; exit 0; } ;;
    *) _uf_log "unknown argument: ${1//[^A-Za-z0-9._=\/-]/?}"; exit 0 ;;
  esac
  case "$1" in
    --session) UF_SESSION="$2" ;;
    --transcript) UF_TRANSCRIPT="$2" ;;
    --self-session) UF_SELF="$2" ;;
    --projects-root) UF_PROJECTS="$2" ;;
    --main-root) UF_MAIN="$2" ;;
    --telemetry-dir) UF_TEL="$2"; UF_TEL_GIVEN=1 ;;
    --ledger) UF_COST="$2" ;;
  esac
  shift 2
done

# A session id reaches filesystem globs, so it must match the session ref grammar.
_uf_valid_sid() { gaia_usage_valid_ref "session:$1"; }

if [ "$UF_SWEEP" = 1 ]; then
  [ -z "$UF_SESSION" ] || { _uf_log "--session and --sweep are exclusive"; exit 0; }
else
  _uf_valid_sid "$UF_SESSION" || { _uf_log "--session <sid> or --sweep is required"; exit 0; }
fi

if [ -n "$UF_MAIN" ]; then
  UF_MAIN="$(cd "$UF_MAIN" 2>/dev/null && pwd -P)" || exit 0
else
  UF_MAIN="$(gaia_usage_main_root)" || exit 0
fi
[ -n "$UF_MAIN" ] && [ -d "$UF_MAIN" ] || exit 0

_gaia_usage_load with_ledger_lock ../../.specify/extensions/gaia/lib/with-ledger-lock.sh || {
  _uf_log "with-ledger-lock.sh not found; nothing recorded"
  exit 0
}

[ -n "$UF_TEL" ] || UF_TEL="$(gaia_usage_telemetry_dir "$UF_MAIN")"
UF_TEL="${UF_TEL%/}"
if [ -z "$UF_COST" ]; then
  if [ "$UF_TEL_GIVEN" = 1 ]; then
    UF_COST="$UF_TEL/cost.jsonl"
  elif _gaia_usage_load gaia_resolve_ledger_path ledger-path-lib.sh; then
    UF_COST="$(gaia_resolve_ledger_path "" "$UF_MAIN")" || UF_COST=""
  fi
fi
[ -n "$UF_PROJECTS" ] || UF_PROJECTS="$(gaia_usage_projects_root "$UF_TRANSCRIPT")"
UF_PROJECTS="${UF_PROJECTS%/}"
UF_LEDGER="$UF_TEL/usage.jsonl"
UF_CACHE="$UF_TEL/usage-cursors.json"
UF_BATCH="$UF_TEL/.usage-batch.tmp.$$"
UF_DEFAULT="$(gaia_usage_default_branch "$UF_MAIN")"

UF_ROOTS_JSON="$({ printf '%s\n' "$UF_MAIN"; gaia_usage_tree_roots "$UF_MAIN"; } | jq -Rnc '[inputs | select(length > 0)] | unique')" || exit 0
UF_RROOTS_JSON="$(jq -nc --arg r "$UF_MAIN/.gaia/local/research/" '[$r]')" || exit 0
# The workflows whose start opens an attribution interval: /gaia-spec,
# /gaia-plan, and the maintenance commands token-tally.sh accepts for
# --action command (its closed --command set). Mirror that list here.
UF_STARTSET='["gaia-spec","gaia-plan","gaia-audit","gaia-debt","gaia-fitness","gaia-forensics","gaia-harden","gaia-residue","gaia-wiki"]'

UF_WORK="$(mktemp -d 2>/dev/null)" || exit 0
UF_SWEEP_LOCK="$UF_TEL/usage-sweep.lock.d"
UF_SWEEP_OWNED=0
UF_PRUNE=1
# shellcheck disable=SC2329  # invoked by the EXIT trap
_uf_cleanup() {
  rm -rf "$UF_WORK" 2>/dev/null
  rm -f "$UF_BATCH" 2>/dev/null
  if [ "$UF_SWEEP_OWNED" = 1 ]; then rmdir "$UF_SWEEP_LOCK" 2>/dev/null; fi
}
trap _uf_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# GNU stat takes -c and rejects -f as a format; BSD stat is the reverse.
if stat -c '%s' / >/dev/null 2>&1; then UF_STATF=-c UF_FMT='%s %Y' UF_FMTN='%Y %n'; else UF_STATF=-f UF_FMT='%z %m' UF_FMTN='%m %N'; fi
_uf_stat() { stat "$UF_STATF" "$UF_FMT" "$1" 2>/dev/null; }
_uf_fsize() {
  local s
  s="$(_uf_stat "$1")" || s=""
  s="${s%% *}"
  printf '%s' "${s:-0}"
}
# shellcheck disable=SC2329  # reached through _uf_commit_locked, which with_ledger_lock invokes
_uf_now() {
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s' "${EPOCHREALTIME/,/.}"; else date +%s; fi
}
# Bytes [start, end) of a file.
_uf_range() {
  [ "$3" -gt "$2" ] || return 0
  tail -c +"$(($2 + 1))" "$1" 2>/dev/null | head -c "$(($3 - $2))"
}
# Byte length of a file's complete lines: a trailing line with no newline is
# still being written and is left for the next read.
_uf_complete_bytes() {
  local total last partial=0
  total=$(($(wc -c <"$1")))
  last="$(tail -c 1 "$1")"
  if [ -n "$last" ]; then partial=$(($(tail -n 1 "$1" | wc -c))); fi
  printf '%s' "$((total - partial))"
}
# The ledger_bytes the cache was folded to, read from its fixed-order prefix,
# or rc 1 when the cache is absent or not in that shape (the caller rebuilds).
_uf_cache_lb() {
  local pre n
  [ -f "$UF_CACHE" ] || return 1
  pre="$(head -c 96 "$UF_CACHE" 2>/dev/null)" || return 1
  case "$pre" in '{"schema_version":1,"ledger_bytes":'[0-9]*) ;; *) return 1 ;; esac
  n="${pre#*\"ledger_bytes\":}"
  n="${n%%[!0-9]*}"
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Sets UF_N0 (ledger bytes read, at a line boundary), UF_COFF (this path's
# cursor offset, -1 for none), and UF_HW (the pair's high-water mark JSON).
_uf_load_state() {
  local path="$1" key="$2|$3" lb size cache out try=0
  while [ "$try" -lt 2 ]; do
    try=$((try + 1))
    size="$(_uf_fsize "$UF_LEDGER")"
    cache="$UF_CACHE"
    lb="$(_uf_cache_lb)" || lb=""
    if [ "$try" = 2 ] || [ -z "$lb" ] || [ "$lb" -gt "$size" ]; then lb=0 cache=/dev/null; fi
    _uf_range "$UF_LEDGER" "$lb" "$size" >"$UF_WORK/tail"
    UF_N0=$((lb + $(_uf_complete_bytes "$UF_WORK/tail")))
    out="$(grep -F '"kind":"cursor"' "$UF_WORK/tail" | jq -nrR --rawfile c "$cache" --arg p "$path" --arg k "$key" \
      "$GAIA_USAGE_FOLD_JQ"'
      (if $c == "" then {files: {}, pairs: {}} else base end) as $b
      | if $b == null then "rebuild"
        else fold($b)
          | "\(.files[$p].offset | if type == "number" then . else -1 end)\t\(.pairs[$k] // {hw_ts: null, hw_ids: []} | tojson)"
        end' 2>/dev/null)" || out=""
    case "$out" in "" | rebuild) continue ;; esac
    IFS=$'\t' read -r UF_COFF UF_HW <<<"$out"
    return 0
  done
  return 1
}

# Rc 0 when a cursor row for (session, role) landed in the ledger after byte n0.
# shellcheck disable=SC2329  # reached through _uf_commit_locked
_uf_cas_conflict() {
  _uf_range "$UF_LEDGER" "$3" "$4" | grep -F '"kind":"cursor"' |
    jq -neR --arg s "$1" --arg r "$2" \
      '[inputs | try fromjson catch null | objects | select(.kind == "cursor" and .session_id == $s and .role == $r)] | length > 0' \
      >/dev/null 2>&1
}

# Rewrites the cursor cache from the ledger (temp file then rename). Called
# only under the ledger lock, the cache's single writer.
# shellcheck disable=SC2329  # reached through _uf_commit_locked
_uf_write_cache() {
  local size="$1" prune="$2" lb cache="$UF_CACHE" tmp="$UF_TEL/.usage-cursors.tmp.$$" gone="$UF_WORK/gone" p try=0
  : >"$gone"
  while [ "$try" -lt 2 ]; do
    try=$((try + 1))
    lb="$(_uf_cache_lb)" || lb=""
    if [ "$try" = 2 ] || [ -z "$lb" ] || [ "$lb" -gt "$size" ]; then lb=0 cache=/dev/null; fi
    _uf_range "$UF_LEDGER" "$lb" "$size" | grep -F '"kind":"cursor"' |
      jq -ncR --rawfile c "$cache" --argjson lb "$size" "$GAIA_USAGE_FOLD_JQ"'
        (if $c == "" then {files: {}, pairs: {}} else base end) as $b
        | if $b == null then error("bad cache") else fold($b) end
        | {schema_version: 1, ledger_bytes: $lb, files, pairs}' >"$tmp" 2>/dev/null && break
  done
  [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
  if [ "$prune" = 1 ]; then
    while IFS= read -r p; do [ -e "$p" ] || printf '%s\n' "$p" >>"$gone"; done < <(jq -r '.files | keys[]' "$tmp" 2>/dev/null)
    if [ -s "$gone" ]; then
      jq -c --rawfile g "$gone" '($g | split("\n") | map(select(length > 0))) as $d | .files |= with_entries(select(.key as $k | $d | index([$k]) | not))' \
        "$tmp" >"$tmp.p" 2>/dev/null && mv -f "$tmp.p" "$tmp"
      rm -f "$tmp.p"
    fi
  fi
  mv -f "$tmp" "$UF_CACHE"
}

# Runs under with_ledger_lock. Holds the lock for one tail read, one append,
# and one cache rewrite; no transcript byte is read here. Stated bound: at most
# 2 s per commit, far under the lock's 30 s stale reclaim and the 10 s other
# writers wait by default. Never returns 75, so a 75 is always a lock timeout.
# shellcheck disable=SC2329  # invoked by with_ledger_lock
_uf_commit_locked() {
  local batch="$1" sid="$2" role="$3" n0="$4" prune="$5" t0 size newsize
  t0="$(_uf_now)"
  size="$(_uf_fsize "$UF_LEDGER")"
  if [ "$size" -gt "$n0" ] && _uf_cas_conflict "$sid" "$role" "$n0" "$size"; then return 3; fi
  cat "$batch" >>"$UF_LEDGER" || return 1
  newsize="$(_uf_fsize "$UF_LEDGER")"
  _uf_write_cache "$newsize" "$prune" || _uf_log "cursor cache not rewritten; the next run rebuilds it"
  if [ "${GAIA_USAGE_DEBUG_HOLD:-}" = 1 ]; then
    _uf_log "hold $(awk -v a="$t0" -v b="$(_uf_now)" 'BEGIN { printf "%.3f", b - a }')s"
  fi
  return 0
}

_uf_barrier() {
  local b="${GAIA_USAGE_TEST_BARRIER:-}" i=0
  [ -n "$b" ] || return 0
  : >"$b.parsed" 2>/dev/null
  while [ ! -e "$b" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# Parses one file's due range and writes the commit batch to UF_BATCH. Rc 1
# when there is nothing to commit.
_uf_prepare() {
  local f="$1" sid="$2" role="$3" size="$4" finished="$5" off complete nl hold pre suf noff rows b bmap
  local -a br=()
  _uf_load_state "$f" "$sid" "$role" || return 1
  off="$UF_COFF"
  [ "$off" -ge 0 ] || off=0
  [ "$size" -ne "$UF_COFF" ] || return 1
  # Truncated below its cursor: reread from the start; the high-water mark
  # drops what was already counted.
  [ "$size" -ge "$off" ] || off=0
  _uf_range "$f" "$off" "$size" >"$UF_WORK/chunk"
  complete="$(_uf_complete_bytes "$UF_WORK/chunk")"
  nl=$(($(wc -l <"$UF_WORK/chunk")))
  jq -nrR --argjson roots "$UF_ROOTS_JSON" --argjson rroots "$UF_RROOTS_JSON" --argjson startset "$UF_STARTSET" \
    --argjson nlines "$nl" "$GAIA_USAGE_PARSE_JQ" <"$UF_WORK/chunk" >"$UF_WORK/p1" 2>/dev/null || return 1
  head -n 1 "$UF_WORK/p1" >"$UF_WORK/ext"
  while IFS= read -r b; do br[${#br[@]}]="$b"; done < <(tail -n +2 "$UF_WORK/p1")
  bmap='{}'
  if [ "${#br[@]}" -gt 0 ]; then bmap="$(gaia_usage_branch_map "${br[@]}" 2>/dev/null)" || bmap='{}'; fi
  [ -n "$bmap" ] || bmap='{}'
  { grep -F -- "$sid" "$UF_COST"; grep -F -- "$sid" "$UF_LEDGER"; } >"$UF_WORK/splits" 2>/dev/null
  jq -nr --slurpfile ext "$UF_WORK/ext" --argjson bmap "$bmap" --arg default "$UF_DEFAULT" --arg fsid "$sid" \
    --argjson hw "$UF_HW" --argjson finished "$finished" --rawfile splitsraw "$UF_WORK/splits" \
    --arg path "$f" --arg role "$role" --argjson size "$size" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$GAIA_USAGE_SEGMENT_JQ" >"$UF_WORK/p2" 2>/dev/null || return 1
  { IFS= read -r hold; IFS= read -r pre; IFS= read -r suf; } <"$UF_WORK/p2"
  if [ "$hold" = null ]; then
    noff=$((off + complete))
  elif [ "$hold" -le 1 ]; then
    noff="$off"
  else
    noff=$((off + $(head -n "$((hold - 1))" "$UF_WORK/chunk" | wc -c)))
  fi
  rows=$(($(wc -l <"$UF_WORK/p2") - 3))
  if [ "$rows" -le 0 ]; then
    if [ "$UF_COFF" -lt 0 ] && [ "$noff" -eq 0 ]; then return 1; fi
    [ "$noff" -ne "$UF_COFF" ] || return 1
  fi
  mkdir -p "$UF_TEL" 2>/dev/null || return 1
  { tail -n +4 "$UF_WORK/p2"; printf '%s,"offset":%s,%s\n' "$pre" "$noff" "$suf"; } >"$UF_BATCH" || return 1
}

# At most 3 compare-and-swap attempts per file per run; a file that keeps
# losing the race is left for the next trigger.
_uf_flush_file() {
  local f="$1" sid="$2" role="$3" size="$4" finished="$5" attempt=0 rc
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    _uf_prepare "$f" "$sid" "$role" "$size" "$finished" || return 0
    _uf_barrier
    rc=0
    with_ledger_lock "$UF_TEL" _uf_commit_locked "$UF_BATCH" "$sid" "$role" "$UF_N0" "$UF_PRUNE" || rc=$?
    case "$rc" in
      0) UF_PRUNE=0; return 0 ;;
      3) _uf_log "another flusher committed ${role//[^A-Za-z0-9._-]/?} of ${sid//[^A-Za-z0-9._-]/?} first; reparsing" ;;
      75) _uf_log "ledger lock timed out; ${f//[^A-Za-z0-9._\/ -]/?} is left for the next trigger"; return 0 ;;
      *) _uf_log "commit failed for ${f//[^A-Za-z0-9._\/ -]/?}"; return 0 ;;
    esac
  done
  return 0
}

# Sets UF_SID and UF_ROLE from a transcript path.
_uf_identify() {
  local p="$1" s b
  case "$p" in
    */subagents/*)
      s="${p%%/subagents/*}"
      UF_SID="${s##*/}"
      UF_ROLE="subagents/${p#"$s"/subagents/}"
      ;;
    *)
      b="${p##*/}"
      UF_SID="${b%.jsonl}"
      UF_ROLE=main
      ;;
  esac
}

_uf_age_ok() { [ $(($(date +%s) - $1)) -ge "$2" ]; }

_uf_session() {
  local d f st size mtime fin
  local -a files=()
  _uf_add() {
    local x
    [ -f "$1" ] || return 0
    for x in ${files[@]+"${files[@]}"}; do [ "$x" = "$1" ] && return 0; done
    files[${#files[@]}]="$1"
  }
  case "$UF_TRANSCRIPT" in *.jsonl) _uf_add "$UF_TRANSCRIPT" ;; esac
  local -a cands=()
  while IFS= read -r d; do cands[${#cands[@]}]="$d"; done < <(gaia_usage_candidate_dirs "$UF_PROJECTS" "$UF_MAIN")
  for d in ${cands[@]+"${cands[@]}"}; do _uf_add "$d/$UF_SESSION.jsonl"; done
  for d in ${cands[@]+"${cands[@]}"}; do
    for f in "$d/$UF_SESSION"/subagents/agent-*.jsonl; do _uf_add "$f"; done
  done
  for d in ${cands[@]+"${cands[@]}"}; do
    for f in "$d/$UF_SESSION"/subagents/workflows/*/agent-*.jsonl; do _uf_add "$f"; done
  done
  for f in ${files[@]+"${files[@]}"}; do
    st="$(_uf_stat "$f")" || continue
    size="${st%% *}" mtime="${st##* }"
    _uf_identify "$f"
    [ "$UF_SID" = "$UF_SESSION" ] || continue
    if [ "$UF_ROLE" = main ]; then
      fin="$UF_FINISHED_MAIN"
    elif _uf_age_ok "$mtime" "${GAIA_USAGE_SIDECAR_QUIET_SECS:-60}"; then
      fin=true
    else
      fin=false
    fi
    _uf_flush_file "$f" "$UF_SESSION" "$UF_ROLE" "$size" "$fin"
  done
}

_uf_sweep() {
  local start line size path m mp fin budget="${GAIA_USAGE_SWEEP_BUDGET_SECS:-240}" age
  local -a sizes=() paths=() mt=()
  mkdir -p "$UF_TEL" 2>/dev/null || return 0
  if ! mkdir "$UF_SWEEP_LOCK" 2>/dev/null; then
    m="$(stat "$UF_STATF" "${UF_FMT#* }" "$UF_SWEEP_LOCK" 2>/dev/null)" || return 0
    age=$(($(date +%s) - m))
    # A sweep killed without its EXIT trap leaves the dir behind; past the
    # budget plus a margin no live sweep can still own it.
    [ "$age" -gt $((budget + 60)) ] || return 0
    rm -rf "$UF_SWEEP_LOCK" 2>/dev/null
    mkdir "$UF_SWEEP_LOCK" 2>/dev/null || return 0
  fi
  UF_SWEEP_OWNED=1
  start="$(date +%s)"
  while IFS=$'\t' read -r size _ path; do
    [ -n "$path" ] || continue
    sizes[${#sizes[@]}]="$size"
    paths[${#paths[@]}]="$path"
  done < <(gaia_usage_due_files "$UF_PROJECTS" "$UF_MAIN" "$UF_TEL")
  [ "${#paths[@]}" -gt 0 ] || return 0
  # One batched stat for the due files' mtimes; a file that vanished since the
  # enumeration has no line and reads as live.
  while IFS= read -r line; do mt[${#mt[@]}]="$line"; done < <(printf '%s\0' ${paths[@]+"${paths[@]}"} | xargs -0 stat "$UF_STATF" "$UF_FMTN" 2>/dev/null)
  local i=0 j=0
  while [ "$i" -lt "${#paths[@]}" ]; do
    [ $(($(date +%s) - start)) -lt "$budget" ] || { _uf_log "sweep budget spent; the next sweep resumes"; break; }
    path="${paths[$i]}" size="${sizes[$i]}" m=""
    if [ "$j" -lt "${#mt[@]}" ]; then
      mp="${mt[$j]#* }"
      if [ "$mp" = "$path" ]; then m="${mt[$j]%% *}"; j=$((j + 1)); fi
    fi
    i=$((i + 1))
    _uf_identify "$path"
    _uf_valid_sid "$UF_SID" || continue
    fin=false
    if [ "$UF_SID" != "$UF_SELF" ] && [ -n "$m" ] && _uf_age_ok "$m" "${GAIA_USAGE_LIVE_SECS:-300}"; then fin=true; fi
    _uf_flush_file "$path" "$UF_SID" "$UF_ROLE" "$size" "$fin"
  done
}

if [ "$UF_SWEEP" = 1 ]; then _uf_sweep; else _uf_session; fi
exit 0
