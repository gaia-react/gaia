# shellcheck shell=bash
# GAIA usage ledger: `usage.sh record` closes a /gaia-spec, /gaia-plan or
# maintenance-command run and prints its Cost line, and `usage.sh represented`
# answers whether a run's close is on the ledger (the archive gate).
#
#   record <ref> --workflow <w> [--pr <N>] [--issue <N>] [--start <iso>] [--json]
#   represented <ref> --workflow <w>
#
# Sourced by usage.sh at top level, after the other libraries, and relies on
# the globals and helpers it defines (_parse, _resolve_context, _error, _now,
# _is_pr, _is_iso, _rows_file, the flag variables). Defines functions only; no
# side effects at source time.
#
# Exit codes. record: 0 recorded; 1 refused with nothing written (no session id,
# no unclaimed start, already recorded, ledger lock timed out); 2 usage error
# (bad ref, unknown flag, missing or disallowed --workflow, --pr or --issue on a
# non-command ref, jq absent, unreadable ledger). A non-zero exit prints one
# stderr line and no Cost line. represented: 0 a close with that ref and
# workflow is on the ledger; 1 none is; 2 usage error, jq absent, or a missing
# or unreadable usage.jsonl. Neither runs usage.sh's jq-absent preamble, which
# exits 0: an archive gate that read "nothing owed" from a missing jq would
# delete a folder it could not check.
#
# Which close pairs with which start is decided by usage_intervals alone
# (usage-resolve-lib.sh), and the figures come from gaia_usage_interval_view
# (usage-render-lib.sh); this file holds neither an attribution rule nor a
# pricing rule.
#
# Waits, each with its own reason:
#   GAIA_USAGE_MERGE_CAP_SECONDS (5)     how long record waits on the flusher
#       before it closes anyway and marks the line partial. The flusher is
#       never killed, because a kill could land mid-append.
#   GAIA_LEDGER_LOCK_TIMEOUT_SECONDS (10)   the close append waits on the ledger
#       lock this long: at least one full flusher commit hold (about 2 s) plus
#       the poll interval, and never the remainder of the flush cap, which a
#       slow flusher may already have spent.
#   GAIA_USAGE_RENDER_CAP_SECONDS (10)   how long the Cost line may take once
#       the close row is written; past it a marker replaces the line.

# shellcheck disable=SC2154  # flag variables and helpers come from usage.sh

# _record_preamble <args...>: parses the common flags, resolves the roots, and
# refuses a flag neither subcommand owns. rc 2 on any failure.
_record_preamble() {
  local usage_file
  [ -z "$(gaia_usage_inactive_reason)" ] || { _error "jq not found; nothing was done"; return 2; }
  _parse "$@" || return 2
  _resolve_context || return 2
  if [ -n "$SESSION$SOURCE$MERGE$BRANCH$KEY$MERGED_AT$AT" ] || [ "$PARTIAL$UNCONFIRMED$LINE$AUDITORS_GIVEN" != 0000 ] || [ "$SIDECHAIN" != false ]; then
    _error "unknown flag; see usage.sh --help"
    return 2
  fi
  [ -n "$WORKFLOW" ] || { _error "--workflow is required"; return 2; }
  usage_file="$TELEMETRY_DIRECTORY/usage.jsonl"
  if [ -e "$usage_file" ] && { [ ! -f "$usage_file" ] || [ ! -r "$usage_file" ]; }; then
    _error "the usage ledger exists but cannot be read"
    return 2
  fi
  return 0
}

# _record_check_workflow: --workflow names a member of the start set and is
# allowed for the ref kind. rc 2 otherwise.
_record_check_workflow() {
  local ref="$1" slug
  [[ "$WORKFLOW" =~ ^[a-z][a-z-]{0,31}$ ]] || { _error "--workflow takes a workflow name"; return 2; }
  case "$GAIA_USAGE_START_SET" in
    *\"$WORKFLOW\"*) ;;
    *) _error "--workflow $WORKFLOW is not a workflow that records a run"; return 2 ;;
  esac
  case "$ref" in
    spec:*)
      [ "$WORKFLOW" = gaia-spec ] || [ "$WORKFLOW" = gaia-plan ] || { _error "a spec: ref records gaia-spec or gaia-plan"; return 2; } ;;
    plan:*)
      [ "$WORKFLOW" = gaia-plan ] || { _error "a plan: ref records gaia-plan"; return 2; } ;;
    command:*)
      slug="${ref#command:}"
      if [ "$slug" != "$WORKFLOW" ] || [ "$WORKFLOW" = gaia-spec ] || [ "$WORKFLOW" = gaia-plan ]; then
        _error "a command: ref is command:<workflow> for a maintenance command"
        return 2
      fi ;;
    *) _error "record takes a spec:, plan: or command: ref"; return 2 ;;
  esac
}

# _record_command_ref <now>: the run ref a command close is written under,
# unique on the ledger so two runs of one command stay apart.
_record_command_ref() {
  local stamp="${1//[-:]/}" candidate attempt=0
  while :; do
    candidate="$(printf 'command:%s-%s-%04x' "$WORKFLOW" "$stamp" $(((RANDOM << 1 ^ RANDOM) & 65535)))"
    grep -qF -- "\"ref\":\"$candidate\"" "$TELEMETRY_DIRECTORY/usage.jsonl" 2>/dev/null || break
    attempt=$((attempt + 1))
    [ "$attempt" -lt 20 ] || break
  done
  printf '%s' "$candidate"
}

# _record_flush: runs the session's flusher in the background and waits up to
# the cap. Sets RECORD_PARTIAL to 1 when it is still running at the cap. This
# loop is not shared with usage-merge.sh because that script's loop is
# interleaved with its merge confirmation and its render, which record has
# neither of. Descriptor 3 is closed so a caller capturing this process does
# not wait on a survivor.
_record_flush() {
  local cap="${GAIA_USAGE_MERGE_CAP_SECONDS:-5}" flush_pid started_at
  case "$cap" in '' | *[!0-9]* | 0) cap=5 ;; esac
  RECORD_PARTIAL=0
  bash "$_usage_script_directory/usage-flush.sh" --session "$SESSION_ID" --finished-main --all-sidecars-finished \
    --main-root "$MAIN_ROOT" --telemetry-dir "$TELEMETRY_DIRECTORY" --projects-root "$PROJECTS_ROOT" \
    </dev/null >/dev/null 2>&1 3>&- &
  flush_pid=$!
  started_at="$(date +%s)"
  while kill -0 "$flush_pid" 2>/dev/null && [ $(($(date +%s) - started_at)) -lt "$cap" ]; do sleep 0.1; done
  if kill -0 "$flush_pid" 2>/dev/null; then
    RECORD_PARTIAL=1
    disown "$flush_pid" 2>/dev/null
  else
    wait "$flush_pid" 2>/dev/null
  fi
  return 0
}

# _record_locked: runs under with_ledger_lock, which may be a subshell, so the
# verdict is the exit code and the detail travels in files under RECORD_WORK.
# 0 written; 3 no unclaimed start; 4 already recorded; 6 the ledger could not
# be read; 7 an append failed. The decision is made here, with the lock held,
# so two closes cannot both pair with one start.
# shellcheck disable=SC2016  # jq source, no shell expansion
_record_locked() {
  local ledger="$TELEMETRY_DIRECTORY/usage.jsonl" decision verdict
  decision="$({ LC_ALL=C grep -F -- "$SESSION_ID" "$ledger" 2>/dev/null || true; } | LC_ALL=C grep -F '"kind":"binding"' |
    jq -nRc --arg session_id "$SESSION_ID" --arg workflow "$WORKFLOW" --arg ref "$RUN_REF" --arg now "$NOW" --arg start_ts "$START_ISO" \
      "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
      [inputs | (try fromjson catch null) | select(type == "object" and .schema_version == 1 and .kind == "binding"
          and .session_id == $session_id and .workflow == $workflow and (.type == "start" or .type == "close"))] as $existing
      | ($now | usage_epoch) as $now_t
      | ($start_ts | if . == "" then null else usage_epoch end) as $recovery_t
      | [$existing[] | select(.type == "start") | . + {_t: (.ts | usage_epoch)}] as $starts
      | ({schema_version: 1, kind: "binding", type: "close", session_id: $session_id, ts: $now, ref: $ref, workflow: $workflow, source: "record-command"}
         + (if $recovery_t == null then {} else {start_ts: $start_ts} end)) as $close_row
      | usage_intervals($existing) as $before
      | if $recovery_t != null then
          ([$starts[] | select(._t == $recovery_t)] | length > 0) as $start_exists
          | if any($existing[]; .type == "close" and (.start_ts | type) == "string" and (.start_ts | usage_epoch) == $recovery_t)
               or ($start_exists and any($before[]; .t0 == $recovery_t))
            then {verdict: "recorded"}
            else {verdict: "write", t0: $start_ts,
                  rows: ((if $start_exists then [] else [{schema_version: 1, kind: "binding", type: "start", session_id: $session_id, ts: $start_ts,
                                                         workflow: $workflow, source: "record-command"}] end) + [$close_row])} end
        else
          usage_intervals($existing + [$close_row]) as $after
          | if ($after | length) > ($before | length)
            then ([$after[] | select(IN($before[]) | not)] | last) as $new
              | {verdict: "write", t0: ([$starts[] | select(._t == $new.t0)] | first | .ts), rows: [$close_row]}
            elif any($starts[]; ._t != null and ._t <= $now_t) then {verdict: "recorded"}
            else {verdict: "nostart"} end
        end')" || return 6
  verdict="$(jq -r '.verdict // empty' <<<"$decision" 2>/dev/null)" || return 6
  case "$verdict" in
    nostart) return 3 ;;
    recorded) return 4 ;;
    write) ;;
    *) return 6 ;;
  esac
  jq -r '.t0' <<<"$decision" >"$RECORD_WORK/t0" || return 6
  jq -c '.rows[]' <<<"$decision" >"$RECORD_WORK/usage_rows" || return 6
  # The edges go first: they name a run ref nothing else uses yet, so one left
  # behind by a failed close append is inert, and the close row is the commit.
  if [ -s "$RECORD_WORK/link_rows" ]; then cat "$RECORD_WORK/link_rows" >>"$TELEMETRY_DIRECTORY/links.jsonl" || return 7; fi
  cat "$RECORD_WORK/usage_rows" >>"$ledger" || return 7
}

# _record_link_rows: the edge rows --pr and --issue ask for, written with the
# close under one lock. A fresh run ref has no parents, so no edge here can
# close a cycle and the cycle walk the link subcommand runs is skipped.
_record_link_rows() {
  local child
  : >"$RECORD_WORK/link_rows"
  for child in ${PR_NUMBER:+"pr:$PR_NUMBER"} ${ISSUE_NUMBER:+"issue:$ISSUE_NUMBER"}; do
    jq -nc --arg child "$child" --arg parent "$RUN_REF" --arg timestamp "$NOW" --arg session_id "$SESSION_ID" \
      '{schema_version: 1, kind: "edge", child: $child, parent: $parent, source: "link-command", ts: $timestamp, session_id: $session_id, sidechain: false}' \
      >>"$RECORD_WORK/link_rows" || return 1
  done
}

# _record_tree <pid>: the pid and every descendant, parents first, listed before
# any kill because a killed parent hands its children to init.
_record_tree() {
  local child_pid
  printf '%s\n' "$1"
  command -v pgrep >/dev/null 2>&1 || return 0
  for child_pid in $(pgrep -P "$1" 2>/dev/null); do _record_tree "$child_pid"; done
}

# _record_print_cost <t0> <close ts>: the Cost line (or its JSON) as the last
# stdout line, bounded by the render cap. The close row is already written, so a
# cap or a failure prints a marker and the exit stays 0.
_record_print_cost() {
  local interval_start="$1" interval_end="$2" view_file="$RECORD_WORK/view" view_pid pids render_cap="${GAIA_USAGE_RENDER_CAP_SECONDS:-10}" started_at wait_ticks
  local view_json tokens dollars elapsed unpriced
  case "$render_cap" in '' | *[!0-9]* | 0) render_cap=10 ;; esac
  usage_rates_load "$RATE_TABLE" "$MAIN_ROOT"
  (gaia_usage_interval_view "$SESSION_ID" "$interval_start" "$interval_end") >"$view_file" 2>/dev/null 3>&- &
  view_pid=$!
  started_at="$(date +%s)"
  while kill -0 "$view_pid" 2>/dev/null && [ $(($(date +%s) - started_at)) -lt "$render_cap" ]; do sleep 0.1; done
  if kill -0 "$view_pid" 2>/dev/null; then
    pids="$(_record_tree "$view_pid")"
    disown "$view_pid" 2>/dev/null
    # shellcheck disable=SC2086  # one pid per word
    kill -TERM $pids 2>/dev/null
    wait_ticks=0
    while [ "$wait_ticks" -lt 10 ] && kill -0 "$view_pid" 2>/dev/null; do sleep 0.1; wait_ticks=$((wait_ticks + 1)); done
    # shellcheck disable=SC2086  # one pid per word
    kill -KILL $pids 2>/dev/null
    printf '! readout timed out after %ss; the run is recorded, read its cost with: bash .gaia/scripts/usage.sh initiative %s --line\n' "$render_cap" "$RUN_REF"
    return 0
  fi
  wait "$view_pid" 2>/dev/null
  view_json="$(cat "$view_file")"
  if ! jq -e 'type == "object" and (.tokens | type) == "number"' <<<"$view_json" >/dev/null 2>&1; then
    printf '! readout unavailable; the run is recorded, read its cost with: bash .gaia/scripts/usage.sh initiative %s --line\n' "$RUN_REF"
    return 0
  fi
  if [ "$JSON" = 1 ]; then
    jq -c '{tokens, dollars, elapsed_seconds}' <<<"$view_json"
    return 0
  fi
  IFS=$'\t' read -r tokens dollars elapsed unpriced < <(jq -r '[.tokens, (.dollars // "null"), .elapsed_seconds, .unpriced] | @tsv' <<<"$view_json")
  _usage_override_marker
  gaia_usage_cost_line "$tokens" "$dollars" "$elapsed"
  [ "$RECORD_PARTIAL" = 0 ] || printf ' (partial: flush incomplete)'
  [ "$unpriced" != true ] || printf ' (partial: lower bound)'
  printf '\n'
}

_record_run() {
  local hint status=0 t0
  REF="${ARGS[0]-}"
  if [ "${#ARGS[@]}" -ne 1 ] || ! gaia_usage_valid_reference "$REF"; then _error "record takes one valid ref"; return 2; fi
  _record_check_workflow "$REF" || return 2
  hint="bash .gaia/scripts/usage.sh record $REF --workflow $WORKFLOW --start <iso>"
  if [ -n "$PR_NUMBER$ISSUE_NUMBER" ] && [ "${REF%%:*}" != command ]; then
    _error "--pr and --issue link a command run; a spec: or plan: ref takes neither"
    return 2
  fi
  if [ -n "$PR_NUMBER" ] && ! _is_pr "$PR_NUMBER"; then _error "--pr takes a PR number"; return 2; fi
  if [ -n "$ISSUE_NUMBER" ] && ! _is_pr "$ISSUE_NUMBER"; then _error "--issue takes an issue number"; return 2; fi
  SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$START_ISO" ]; then
    [[ "$START_ISO" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { _error "--start takes a UTC time (YYYY-MM-DDTHH:MM:SSZ)"; return 2; }
    [[ "$START_ISO" > "$(_now)" ]] && { _error "--start is in the future"; return 2; }
  fi
  gaia_usage_valid_reference "session:$SESSION_ID" || {
    _error "no session id (CLAUDE_CODE_SESSION_ID is empty or invalid); nothing was written, rerun: $hint"
    return 1
  }
  _gaia_usage_load with_ledger_lock spec/with-ledger-lock.sh || { _error "no ledger mutex available; nothing was written"; return 1; }
  mkdir -p "$TELEMETRY_DIRECTORY" || { _error "no ledger directory; nothing was written"; return 1; }
  _record_flush
  NOW="$(_now)"
  RUN_REF="$REF"
  [ "${REF%%:*}" != command ] || RUN_REF="$(_record_command_ref "$NOW")"
  _record_link_rows || { _error "could not build the link rows; nothing was written"; return 1; }
  GAIA_LEDGER_LOCK_TIMEOUT_SECONDS="${GAIA_LEDGER_LOCK_TIMEOUT_SECONDS:-10}" with_ledger_lock "$TELEMETRY_DIRECTORY" _record_locked 2>/dev/null || status=$?
  case "$status" in
    0) ;;
    3) _error "no unclaimed $WORKFLOW start in this session; nothing was written, rerun: $hint"; return 1 ;;
    4) _error "this run is already recorded; nothing was written, if it was missed rerun: $hint"; return 1 ;;
    75) _error "ledger lock timed out; nothing was written, rerun: bash .gaia/scripts/usage.sh record $REF --workflow $WORKFLOW${START_ISO:+ --start $START_ISO}"; return 1 ;;
    6) _error "could not read the usage ledger; nothing was written"; return 2 ;;
    *) _error "could not append to the usage ledger; check the close row before rerunning"; return 1 ;;
  esac
  t0="$(cat "$RECORD_WORK/t0")"
  _record_print_cost "$t0" "$NOW"
}

# shellcheck disable=SC2329  # reached through usage.sh's dispatch
_record_main() {
  local status=0
  _record_preamble "$@" || return 2
  RECORD_WORK="$(mktemp -d 2>/dev/null)" || { _error "no scratch directory; nothing was written"; return 1; }
  _record_run || status=$?
  rm -rf "$RECORD_WORK"
  return "$status"
}

# shellcheck disable=SC2016,SC2329  # jq source, no shell expansion; reached through usage.sh's dispatch
_represented_main() {
  local ref usage_file rc=0
  _record_preamble "$@" || return 2
  ref="${ARGS[0]-}"
  if [ "${#ARGS[@]}" -ne 1 ] || ! gaia_usage_valid_reference "$ref"; then _error "represented takes one valid ref"; return 2; fi
  if [ -n "$PR_NUMBER$ISSUE_NUMBER$START_ISO" ] || [ "$JSON" != 0 ]; then _error "unknown flag; represented takes only --workflow"; return 2; fi
  [[ "$WORKFLOW" =~ ^[a-z][a-z-]{0,31}$ ]] || { _error "--workflow takes a workflow name"; return 2; }
  usage_file="$TELEMETRY_DIRECTORY/usage.jsonl"
  [ -f "$usage_file" ] || { _error "the usage ledger is missing"; return 2; }
  # Only close rows can answer, so a fixed-string prefilter keeps the read to
  # them; no key, branch map or memo is built.
  LC_ALL=C grep -F '"type":"close"' "$usage_file" 2>/dev/null |
    jq -neR --arg ref "$ref" --arg workflow "$WORKFLOW" '
      [inputs | (try fromjson catch null)
        | select(type == "object" and .schema_version == 1 and .kind == "binding" and .type == "close" and .workflow == $workflow and (.ref | type) == "string"
            and (.ref == $ref or (($ref | startswith("command:")) and (.ref | startswith($ref + "-")))))]
      | length > 0' >/dev/null 2>&1 || rc=$?
  case "$rc" in 0 | 1) return "$rc" ;; *) _error "could not read the usage ledger"; return 2 ;; esac
}
