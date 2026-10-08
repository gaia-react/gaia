#!/usr/bin/env bash
# Records transcript usage into the usage ledger (usage.jsonl): one `segment`
# row per run of same-key assistant usage, `binding` rows for research writes
# and workflow starts, and one `cursor` row per committed file. Attribution is
# not decided here; readers resolve it at read time.
#
#   usage-flush.sh --session <sid> [--transcript <path>] [--finished-main] [--all-sidecars-finished]
#   usage-flush.sh --sweep [--self-session <sid>]
#   common: [--projects-root <dir>] [--main-root <dir>] [--telemetry-dir <dir>]
#
# Contract with the hooks that call it: exits 0 and prints nothing on stdout,
# diagnostics on stderr. The one exception is a missing or unparseable library
# (usage-lib.sh, usage-parse-lib.sh), which exits non-zero with one stderr line
# naming the file; the hooks launch it detached or discard its status.
# `--finished-main` asserts the session's main transcript is quiescent up to its
# current size (Stop and the merge hook fire only after the issuing message is
# complete), which lets the trailing message group commit instead of waiting for
# its final duplicate line. `--all-sidecars-finished` asserts the same for every
# sidecar of a session run, so no sidecar waits out the quiet window; a sweep
# ignores it.
#
# Every segment row carries agent_type (main, the sidecar's meta agentType, or
# unknown) and, for a sidecar, agent_id. A close binding row in the ledger ends
# an attribution interval, so it splits segments like a declare binding.
#
# Counted-once invariant: every usage message lands in exactly one segment at
# its final value. It rests on four mechanisms that only hold together:
#   - holdback: the last message's group is not committed until the file is
#     known finished, because streaming writes the same message id again with
#     a larger output_tokens;
#   - the per (session, role) high-water mark: a relocated copy, a truncated
#     and rewritten file, or a reparse after a lost race counts nothing twice;
#   - compare-and-swap: a commit aborts when another flusher committed a cursor
#     for the same (session, role), or a close binding for the session, since
#     this one read the ledger;
#   - per-file commits: a sweep killed midway loses only its uncommitted file.
#
# Knobs: GAIA_USAGE_LIVE_SECONDS (300, a sweep treats a newer file as still being
# written), GAIA_USAGE_SIDECAR_QUIET_SECONDS (60, the same for a sidecar in
# session mode), GAIA_USAGE_SWEEP_BUDGET_SECONDS (240, a sweep starts no new file
# after this; the next SessionStart resumes from the committed cursors).
# Test seams, unset in production: GAIA_USAGE_TEST_BARRIER=<path> touches
# <path>.parsed after each file's parse and waits (10 s at most) for <path>
# before taking the lock; GAIA_USAGE_DEBUG_HOLD=1 reports each commit's lock
# hold time on stderr.

_uf_script_path="${BASH_SOURCE[0]:-$0}"
case "$_uf_script_path" in */*) UF_SCRIPT_DIRECTORY="${_uf_script_path%/*}" ;; *) UF_SCRIPT_DIRECTORY=. ;; esac

_uf_log() { printf 'usage-flush: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=usage-lib.sh
. "$UF_SCRIPT_DIRECTORY/usage-lib.sh" 2>/dev/null || { _uf_log "cannot load $UF_SCRIPT_DIRECTORY/usage-lib.sh"; exit 1; }
gaia_usage_in_ci && exit 0
# shellcheck source=usage-parse-lib.sh
. "$UF_SCRIPT_DIRECTORY/usage-parse-lib.sh" 2>/dev/null || { _uf_log "cannot load $UF_SCRIPT_DIRECTORY/usage-parse-lib.sh"; exit 1; }

UF_SESSION="" UF_TRANSCRIPT="" UF_FINISHED_MAIN=false UF_ALL_SIDECARS_FINISHED=0 UF_SWEEP=0 UF_SELF=""
UF_PROJECTS="" UF_MAIN="" UF_TELEMETRY_DIRECTORY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --finished-main) UF_FINISHED_MAIN=true; shift; continue ;;
    --all-sidecars-finished) UF_ALL_SIDECARS_FINISHED=1; shift; continue ;;
    --sweep) UF_SWEEP=1; shift; continue ;;
    --session | --transcript | --self-session | --projects-root | --main-root | --telemetry-dir)
      [ $# -ge 2 ] || { _uf_log "missing value for ${1//[^A-Za-z0-9._=\/-]/?}"; exit 0; } ;;
    *) _uf_log "unknown argument: ${1//[^A-Za-z0-9._=\/-]/?}"; exit 0 ;;
  esac
  case "$1" in
    --session) UF_SESSION="$2" ;;
    --transcript) UF_TRANSCRIPT="$2" ;;
    --self-session) UF_SELF="$2" ;;
    --projects-root) UF_PROJECTS="$2" ;;
    --main-root) UF_MAIN="$2" ;;
    --telemetry-dir) UF_TELEMETRY_DIRECTORY="$2" ;;
  esac
  shift 2
done

# A session id reaches filesystem globs, so it must match the session ref grammar.
_uf_valid_session_id() { gaia_usage_valid_reference "session:$1"; }

if [ "$UF_SWEEP" = 1 ]; then
  [ -z "$UF_SESSION" ] || { _uf_log "--session and --sweep are exclusive"; exit 0; }
else
  _uf_valid_session_id "$UF_SESSION" || { _uf_log "--session <sid> or --sweep is required"; exit 0; }
fi

if [ -n "$UF_MAIN" ]; then
  UF_MAIN="$(cd "$UF_MAIN" 2>/dev/null && pwd -P)" || exit 0
else
  UF_MAIN="$(gaia_usage_main_root)" || exit 0
fi
[ -n "$UF_MAIN" ] && [ -d "$UF_MAIN" ] || exit 0

_gaia_usage_load with_ledger_lock spec/with-ledger-lock.sh || {
  _uf_log "with-ledger-lock.sh not found; nothing recorded"
  exit 0
}

[ -n "$UF_TELEMETRY_DIRECTORY" ] || UF_TELEMETRY_DIRECTORY="$(gaia_usage_telemetry_directory "$UF_MAIN")"
UF_TELEMETRY_DIRECTORY="${UF_TELEMETRY_DIRECTORY%/}"
[ -n "$UF_PROJECTS" ] || UF_PROJECTS="$(gaia_usage_projects_root "$UF_TRANSCRIPT")"
UF_PROJECTS="${UF_PROJECTS%/}"
UF_LEDGER="$UF_TELEMETRY_DIRECTORY/usage.jsonl"
UF_CACHE="$UF_TELEMETRY_DIRECTORY/usage-cursors.json"
UF_BATCH="$UF_TELEMETRY_DIRECTORY/.usage-batch.tmp.$$"
UF_DEFAULT="$(gaia_usage_default_branch "$UF_MAIN")"

UF_ROOTS_JSON="$({ printf '%s\n' "$UF_MAIN"; gaia_usage_tree_roots "$UF_MAIN"; } | jq -Rnc '[inputs | select(length > 0)] | unique')" || exit 0
UF_RESEARCH_ROOTS_JSON="$(jq -nc --arg research_root "$UF_MAIN/.gaia/local/research/" '[$research_root]')" || exit 0
# The workflows whose start opens an attribution interval and whose run
# `usage.sh record` closes: GAIA_USAGE_START_SET in usage-lib.sh.

UF_WORK="$(mktemp -d 2>/dev/null)" || exit 0
UF_SWEEP_LOCK="$UF_TELEMETRY_DIRECTORY/usage-sweep.lock.d"
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
if stat -c '%s' / >/dev/null 2>&1; then UF_STAT_FLAG=-c UF_STAT_FORMAT='%s %Y' UF_STAT_FORMAT_WITH_NAME='%Y %n'; else UF_STAT_FLAG=-f UF_STAT_FORMAT='%z %m' UF_STAT_FORMAT_WITH_NAME='%m %N'; fi
_uf_stat() { stat "$UF_STAT_FLAG" "$UF_STAT_FORMAT" "$1" 2>/dev/null; }
_uf_file_size() {
  local size_field
  size_field="$(_uf_stat "$1")" || size_field=""
  size_field="${size_field%% *}"
  printf '%s' "${size_field:-0}"
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
_uf_cache_ledger_bytes() {
  local cache_prefix ledger_bytes
  [ -f "$UF_CACHE" ] || return 1
  cache_prefix="$(head -c 96 "$UF_CACHE" 2>/dev/null)" || return 1
  case "$cache_prefix" in '{"schema_version":1,"ledger_bytes":'[0-9]*) ;; *) return 1 ;; esac
  ledger_bytes="${cache_prefix#*\"ledger_bytes\":}"
  ledger_bytes="${ledger_bytes%%[!0-9]*}"
  [ -n "$ledger_bytes" ] || return 1
  printf '%s' "$ledger_bytes"
}

# Sets UF_LEDGER_BYTES_READ (ledger bytes read, at a line boundary), UF_CURSOR_OFFSET (this path's
# cursor offset, -1 for none), and UF_HIGH_WATER_MARK (the pair's high-water mark JSON).
_uf_load_state() {
  local path="$1" key="$2|$3" ledger_bytes size cache fold_output try=0
  while [ "$try" -lt 2 ]; do
    try=$((try + 1))
    size="$(_uf_file_size "$UF_LEDGER")"
    cache="$UF_CACHE"
    ledger_bytes="$(_uf_cache_ledger_bytes)" || ledger_bytes=""
    if [ "$try" = 2 ] || [ -z "$ledger_bytes" ] || [ "$ledger_bytes" -gt "$size" ]; then ledger_bytes=0 cache=/dev/null; fi
    _uf_range "$UF_LEDGER" "$ledger_bytes" "$size" >"$UF_WORK/tail"
    UF_LEDGER_BYTES_READ=$((ledger_bytes + $(_uf_complete_bytes "$UF_WORK/tail")))
    fold_output="$(grep -F '"kind":"cursor"' "$UF_WORK/tail" | jq -nrR --rawfile cache_text "$cache" --arg transcript_path "$path" --arg pair_key "$key" \
      "$GAIA_USAGE_FOLD_JQ"'
      (if $cache_text == "" then {files: {}, pairs: {}} else base end) as $cache_base
      | if $cache_base == null then "rebuild"
        else fold($cache_base)
          | "\(.files[$transcript_path].offset | if type == "number" then . else -1 end)\t\(.pairs[$pair_key] // {hw_ts: null, hw_ids: []} | tojson)"
        end' 2>/dev/null)" || fold_output=""
    case "$fold_output" in "" | rebuild) continue ;; esac
    IFS=$'\t' read -r UF_CURSOR_OFFSET UF_HIGH_WATER_MARK <<<"$fold_output"
    return 0
  done
  return 1
}

# Rc 0 when a cursor row for (session, role) landed in the ledger after byte ledger_bytes_read.
# A compare-and-swap conflict is also a close binding for the session that
# prepare did not see (_uf_closes_changed): prepare reads the split points
# outside the lock, so a close appended since would otherwise be invisible and a
# committed segment could straddle it.
# shellcheck disable=SC2329  # reached through _uf_commit_locked
_uf_cas_conflict() {
  _uf_range "$UF_LEDGER" "$3" "$4" | grep -F '"kind":"cursor"' |
    jq -neR --arg session_id "$1" --arg role "$2" \
      '[inputs | try fromjson catch null | objects | select(.kind == "cursor" and .session_id == $session_id and .role == $role)] | length > 0' \
      >/dev/null 2>&1
}

# The session's close binding rows currently in the ledger, sorted.
# shellcheck disable=SC2329  # reached through _uf_closes_changed
_uf_session_closes() {
  grep -F -- "$1" "$UF_LEDGER" 2>/dev/null | grep -F '"type":"close"' | sort
}

# Rc 0 when the session's close rows differ from the set prepare used.
# shellcheck disable=SC2329  # reached through _uf_commit_locked
_uf_closes_changed() {
  ! _uf_session_closes "$1" | cmp -s - "$UF_WORK/closes"
}

# Rewrites the cursor cache from the ledger (temp file then rename). Called
# only under the ledger lock, the cache's single writer.
# shellcheck disable=SC2329  # reached through _uf_commit_locked
_uf_write_cache() {
  local size="$1" prune="$2" ledger_bytes cache="$UF_CACHE" temporary_cache_file="$UF_TELEMETRY_DIRECTORY/.usage-cursors.tmp.$$" gone="$UF_WORK/gone" cached_path try=0
  : >"$gone"
  while [ "$try" -lt 2 ]; do
    try=$((try + 1))
    ledger_bytes="$(_uf_cache_ledger_bytes)" || ledger_bytes=""
    if [ "$try" = 2 ] || [ -z "$ledger_bytes" ] || [ "$ledger_bytes" -gt "$size" ]; then ledger_bytes=0 cache=/dev/null; fi
    _uf_range "$UF_LEDGER" "$ledger_bytes" "$size" | grep -F '"kind":"cursor"' |
      jq -ncR --rawfile cache_text "$cache" --argjson ledger_bytes "$size" "$GAIA_USAGE_FOLD_JQ"'
        (if $cache_text == "" then {files: {}, pairs: {}} else base end) as $cache_base
        | if $cache_base == null then error("bad cache") else fold($cache_base) end
        | {schema_version: 1, ledger_bytes: $ledger_bytes, files, pairs}' >"$temporary_cache_file" 2>/dev/null && break
  done
  [ -s "$temporary_cache_file" ] || { rm -f "$temporary_cache_file"; return 1; }
  if [ "$prune" = 1 ]; then
    while IFS= read -r cached_path; do [ -e "$cached_path" ] || printf '%s\n' "$cached_path" >>"$gone"; done < <(jq -r '.files | keys[]' "$temporary_cache_file" 2>/dev/null)
    if [ -s "$gone" ]; then
      jq -c --rawfile gone_paths "$gone" '($gone_paths | split("\n") | map(select(length > 0))) as $gone_list | .files |= with_entries(select(.key as $cached_path | $gone_list | index([$cached_path]) | not))' \
        "$temporary_cache_file" >"$temporary_cache_file.p" 2>/dev/null && mv -f "$temporary_cache_file.p" "$temporary_cache_file"
      rm -f "$temporary_cache_file.p"
    fi
  fi
  mv -f "$temporary_cache_file" "$UF_CACHE"
}

# Runs under with_ledger_lock. Holds the lock for one tail read, one append,
# and one cache rewrite; no transcript byte is read here. Stated bound: at most
# 2 s per commit, far under the lock's 30 s stale reclaim and the 10 s other
# writers wait by default. Never returns 75, so a 75 is always a lock timeout.
# shellcheck disable=SC2329  # invoked by with_ledger_lock
_uf_commit_locked() {
  local batch="$1" session_id="$2" role="$3" ledger_bytes_read="$4" prune="$5" commit_started_at size newsize
  commit_started_at="$(_uf_now)"
  size="$(_uf_file_size "$UF_LEDGER")"
  if [ "$size" -gt "$ledger_bytes_read" ]; then
    if _uf_cas_conflict "$session_id" "$role" "$ledger_bytes_read" "$size"; then return 3; fi
    if _uf_closes_changed "$session_id"; then return 3; fi
  fi
  cat "$batch" >>"$UF_LEDGER" || return 1
  newsize="$(_uf_file_size "$UF_LEDGER")"
  _uf_write_cache "$newsize" "$prune" || _uf_log "cursor cache not rewritten; the next run rebuilds it"
  if [ "${GAIA_USAGE_DEBUG_HOLD:-}" = 1 ]; then
    _uf_log "hold $(awk -v started_at="$commit_started_at" -v ended_at="$(_uf_now)" 'BEGIN { printf "%.3f", ended_at - started_at }')s"
  fi
  return 0
}

_uf_barrier() {
  local barrier_path="${GAIA_USAGE_TEST_BARRIER:-}" i=0
  [ -n "$barrier_path" ] || return 0
  : >"$barrier_path.parsed" 2>/dev/null
  while [ ! -e "$barrier_path" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# Sets UF_AGENT_TYPE and UF_AGENT_ID for a transcript. A sidecar's type is the
# agentType of the agent-<id>.meta.json beside it, read for the whole session in
# one jq pass the first time any of its sidecars is prepared (one jq per meta
# costs seconds on a session with dozens); a missing, unreadable or oddly
# spelled meta reads as unknown. The map is a newline-led string so the lookup
# stays in bash and exact.
UF_META_SESSIONS=$'\n' UF_META_MAP=$'\n'
_uf_load_metas() {
  local session_directory="$1" meta_file meta_output
  local -a meta_files=()
  case "$UF_META_SESSIONS" in *$'\n'"$session_directory"$'\n'*) return 0 ;; esac
  UF_META_SESSIONS="$UF_META_SESSIONS$session_directory"$'\n'
  for meta_file in "$session_directory"/subagents/agent-*.meta.json "$session_directory"/subagents/workflows/*/agent-*.meta.json; do
    if [ -f "$meta_file" ]; then meta_files[${#meta_files[@]}]="$meta_file"; fi
  done
  [ "${#meta_files[@]}" -gt 0 ] || return 0
  meta_output="$(jq -nr '[inputs | select(type == "object")
      | "\(input_filename | sub("\\.meta\\.json\\z"; ".jsonl"))\t\(.agentType | if type == "string" and test("\\A[A-Za-z0-9._:-]+\\z") then . else "unknown" end)\n"]
    | join("")' "${meta_files[@]}" 2>/dev/null)" || meta_output=""
  UF_META_MAP="$UF_META_MAP$meta_output"
}
_uf_agent_fields() {
  local transcript_file="$1" role="$2" file_name rest
  UF_AGENT_TYPE=main UF_AGENT_ID=""
  [ "$role" != main ] || return 0
  file_name="${transcript_file##*/}"
  file_name="${file_name#agent-}"
  UF_AGENT_ID="${file_name%.jsonl}"
  _uf_load_metas "${transcript_file%%/subagents/*}"
  UF_AGENT_TYPE=unknown
  case "$UF_META_MAP" in
    *$'\n'"$transcript_file"$'\t'*)
      rest="${UF_META_MAP#*$'\n'"$transcript_file"$'\t'}"
      UF_AGENT_TYPE="${rest%%$'\n'*}"
      ;;
  esac
}

# Parses one file's due range and writes the commit batch to UF_BATCH. Rc 1
# when there is nothing to commit.
_uf_prepare() {
  local transcript_file="$1" session_id="$2" role="$3" size="$4" finished="$5" offset complete line_count hold cursor_row_prefix cursor_row_suffix new_offset rows raw_branch branch_map
  local -a raw_branches=()
  _uf_load_state "$transcript_file" "$session_id" "$role" || return 1
  offset="$UF_CURSOR_OFFSET"
  [ "$offset" -ge 0 ] || offset=0
  [ "$size" -ne "$UF_CURSOR_OFFSET" ] || return 1
  # Truncated below its cursor: reread from the start; the high-water mark
  # drops what was already counted.
  [ "$size" -ge "$offset" ] || offset=0
  _uf_range "$transcript_file" "$offset" "$size" >"$UF_WORK/chunk"
  complete="$(_uf_complete_bytes "$UF_WORK/chunk")"
  line_count=$(($(wc -l <"$UF_WORK/chunk")))
  jq -nrR --argjson roots "$UF_ROOTS_JSON" --argjson research_roots "$UF_RESEARCH_ROOTS_JSON" --argjson startset "$GAIA_USAGE_START_SET" \
    --argjson line_count "$line_count" "$GAIA_USAGE_PARSE_JQ" <"$UF_WORK/chunk" >"$UF_WORK/p1" 2>/dev/null || return 1
  head -n 1 "$UF_WORK/p1" >"$UF_WORK/ext"
  while IFS= read -r raw_branch; do raw_branches[${#raw_branches[@]}]="$raw_branch"; done < <(tail -n +2 "$UF_WORK/p1")
  branch_map='{}'
  if [ "${#raw_branches[@]}" -gt 0 ]; then branch_map="$(gaia_usage_branch_map "${raw_branches[@]}" 2>/dev/null)" || branch_map='{}'; fi
  [ -n "$branch_map" ] || branch_map='{}'
  grep -F -- "$session_id" "$UF_LEDGER" >"$UF_WORK/session_rows" 2>/dev/null
  grep -F '"type":"close"' "$UF_WORK/session_rows" 2>/dev/null | sort >"$UF_WORK/closes"
  _uf_agent_fields "$transcript_file" "$role"
  jq -nr --slurpfile extraction "$UF_WORK/ext" --argjson branch_map "$branch_map" --arg default "$UF_DEFAULT" --arg file_session_id "$session_id" \
    --argjson high_water_mark "$UF_HIGH_WATER_MARK" --argjson finished "$finished" --rawfile splitsraw "$UF_WORK/session_rows" \
    --arg path "$transcript_file" --arg role "$role" --arg agent_type "$UF_AGENT_TYPE" --arg agent_id "$UF_AGENT_ID" --argjson size "$size" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$GAIA_USAGE_SEGMENT_JQ" >"$UF_WORK/p2" 2>/dev/null || return 1
  { IFS= read -r hold; IFS= read -r cursor_row_prefix; IFS= read -r cursor_row_suffix; } <"$UF_WORK/p2"
  if [ "$hold" = null ]; then
    new_offset=$((offset + complete))
  elif [ "$hold" -le 1 ]; then
    new_offset="$offset"
  else
    new_offset=$((offset + $(head -n "$((hold - 1))" "$UF_WORK/chunk" | wc -c)))
  fi
  rows=$(($(wc -l <"$UF_WORK/p2") - 3))
  if [ "$rows" -le 0 ]; then
    if [ "$UF_CURSOR_OFFSET" -lt 0 ] && [ "$new_offset" -eq 0 ]; then return 1; fi
    [ "$new_offset" -ne "$UF_CURSOR_OFFSET" ] || return 1
  fi
  mkdir -p "$UF_TELEMETRY_DIRECTORY" 2>/dev/null || return 1
  { tail -n +4 "$UF_WORK/p2"; printf '%s,"offset":%s,%s\n' "$cursor_row_prefix" "$new_offset" "$cursor_row_suffix"; } >"$UF_BATCH" || return 1
}

# At most 3 compare-and-swap attempts per file per run; a file that keeps
# losing the race is left for the next trigger.
_uf_flush_file() {
  local transcript_file="$1" session_id="$2" role="$3" size="$4" finished="$5" attempt=0 exit_status
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    _uf_prepare "$transcript_file" "$session_id" "$role" "$size" "$finished" || return 0
    _uf_barrier
    exit_status=0
    with_ledger_lock "$UF_TELEMETRY_DIRECTORY" _uf_commit_locked "$UF_BATCH" "$session_id" "$role" "$UF_LEDGER_BYTES_READ" "$UF_PRUNE" || exit_status=$?
    case "$exit_status" in
      0) UF_PRUNE=0; return 0 ;;
      3) _uf_log "another flusher committed ${role//[^A-Za-z0-9._-]/?} of ${session_id//[^A-Za-z0-9._-]/?} first; reparsing" ;;
      75) _uf_log "ledger lock timed out; ${transcript_file//[^A-Za-z0-9._\/ -]/?} is left for the next trigger"; return 0 ;;
      *) _uf_log "commit failed for ${transcript_file//[^A-Za-z0-9._\/ -]/?}"; return 0 ;;
    esac
  done
  return 0
}

# Sets UF_SESSION_ID and UF_ROLE from a transcript path.
_uf_identify() {
  local transcript_path="$1" session_directory transcript_name
  case "$transcript_path" in
    */subagents/*)
      session_directory="${transcript_path%%/subagents/*}"
      UF_SESSION_ID="${session_directory##*/}"
      UF_ROLE="subagents/${transcript_path#"$session_directory"/subagents/}"
      ;;
    *)
      transcript_name="${transcript_path##*/}"
      UF_SESSION_ID="${transcript_name%.jsonl}"
      UF_ROLE=main
      ;;
  esac
}

_uf_age_ok() { [ $(($(date +%s) - $1)) -ge "$2" ]; }

_uf_session() {
  local candidate_directory transcript_file size_and_mtime size mtime file_finished
  local -a files=()
  _uf_add() {
    local known_file
    [ -f "$1" ] || return 0
    for known_file in ${files[@]+"${files[@]}"}; do [ "$known_file" = "$1" ] && return 0; done
    files[${#files[@]}]="$1"
  }
  case "$UF_TRANSCRIPT" in *.jsonl) _uf_add "$UF_TRANSCRIPT" ;; esac
  local -a candidate_directories=()
  while IFS= read -r candidate_directory; do candidate_directories[${#candidate_directories[@]}]="$candidate_directory"; done < <(gaia_usage_candidate_directories "$UF_PROJECTS" "$UF_MAIN")
  for candidate_directory in ${candidate_directories[@]+"${candidate_directories[@]}"}; do _uf_add "$candidate_directory/$UF_SESSION.jsonl"; done
  for candidate_directory in ${candidate_directories[@]+"${candidate_directories[@]}"}; do
    for transcript_file in "$candidate_directory/$UF_SESSION"/subagents/agent-*.jsonl; do _uf_add "$transcript_file"; done
  done
  for candidate_directory in ${candidate_directories[@]+"${candidate_directories[@]}"}; do
    for transcript_file in "$candidate_directory/$UF_SESSION"/subagents/workflows/*/agent-*.jsonl; do _uf_add "$transcript_file"; done
  done
  for transcript_file in ${files[@]+"${files[@]}"}; do
    size_and_mtime="$(_uf_stat "$transcript_file")" || continue
    size="${size_and_mtime%% *}" mtime="${size_and_mtime##* }"
    _uf_identify "$transcript_file"
    [ "$UF_SESSION_ID" = "$UF_SESSION" ] || continue
    if [ "$UF_ROLE" = main ]; then
      file_finished="$UF_FINISHED_MAIN"
    elif [ "$UF_ALL_SIDECARS_FINISHED" = 1 ] || _uf_age_ok "$mtime" "${GAIA_USAGE_SIDECAR_QUIET_SECONDS:-60}"; then
      file_finished=true
    else
      file_finished=false
    fi
    _uf_flush_file "$transcript_file" "$UF_SESSION" "$UF_ROLE" "$size" "$file_finished"
  done
}

_uf_sweep() {
  local start line size path modified_time modified_path file_finished budget="${GAIA_USAGE_SWEEP_BUDGET_SECONDS:-240}" age
  local -a sizes=() paths=() modified_time_lines=()
  mkdir -p "$UF_TELEMETRY_DIRECTORY" 2>/dev/null || return 0
  if ! mkdir "$UF_SWEEP_LOCK" 2>/dev/null; then
    modified_time="$(stat "$UF_STAT_FLAG" "${UF_STAT_FORMAT#* }" "$UF_SWEEP_LOCK" 2>/dev/null)" || return 0
    age=$(($(date +%s) - modified_time))
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
  done < <(gaia_usage_due_files "$UF_PROJECTS" "$UF_MAIN" "$UF_TELEMETRY_DIRECTORY")
  [ "${#paths[@]}" -gt 0 ] || return 0
  # One batched stat for the due files' mtimes; a file that vanished since the
  # enumeration has no line and reads as live.
  while IFS= read -r line; do modified_time_lines[${#modified_time_lines[@]}]="$line"; done < <(printf '%s\0' ${paths[@]+"${paths[@]}"} | xargs -0 stat "$UF_STAT_FLAG" "$UF_STAT_FORMAT_WITH_NAME" 2>/dev/null)
  local i=0 j=0
  while [ "$i" -lt "${#paths[@]}" ]; do
    [ $(($(date +%s) - start)) -lt "$budget" ] || { _uf_log "sweep budget spent; the next sweep resumes"; break; }
    path="${paths[$i]}" size="${sizes[$i]}" modified_time=""
    if [ "$j" -lt "${#modified_time_lines[@]}" ]; then
      modified_path="${modified_time_lines[$j]#* }"
      if [ "$modified_path" = "$path" ]; then modified_time="${modified_time_lines[$j]%% *}"; j=$((j + 1)); fi
    fi
    i=$((i + 1))
    _uf_identify "$path"
    _uf_valid_session_id "$UF_SESSION_ID" || continue
    file_finished=false
    if [ "$UF_SESSION_ID" != "$UF_SELF" ] && [ -n "$modified_time" ] && _uf_age_ok "$modified_time" "${GAIA_USAGE_LIVE_SECONDS:-300}"; then file_finished=true; fi
    _uf_flush_file "$path" "$UF_SESSION_ID" "$UF_ROLE" "$size" "$file_finished"
  done
}

if [ "$UF_SWEEP" = 1 ]; then _uf_sweep; else _uf_session; fi
exit 0
