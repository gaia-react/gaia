#!/usr/bin/env bash
# GAIA usage ledger: record lineage and bindings, and read attributed spend.
#
# Exit codes: readouts (pr, pr-branch, initiative, reconcile) exit 0 always.
# Writes exit 0 written (or nothing owed), 1 refused (a cycle, or no ledger
# mutex available), 2 usage or grammar error, 75 lock timeout; every non-zero
# write leaves both stores untouched. With jq absent every subcommand prints
# the inactive line and exits 0 before touching any file.
#
# The merge hook and the PR-create hook call `pr`, `pr-branch`, and `link`;
# they pass raw branch spellings through --branch and never normalize or key a
# branch themselves, and read edge liveness only through `pr-branch`.
#
# No `set -e`: a readout degrades to a marked figure rather than aborting.

# shellcheck disable=SC2016  # jq programs are single-quoted on purpose

_usage_self="${BASH_SOURCE[0]}"
_usage_script_directory="${BASH_SOURCE[0]%/*}"
[ "$_usage_script_directory" = "${BASH_SOURCE[0]}" ] && _usage_script_directory=.
# shellcheck source=.gaia/scripts/usage-lib.sh
. "$_usage_script_directory/usage-lib.sh"
# shellcheck source=.gaia/scripts/usage-resolve-lib.sh
. "$_usage_script_directory/usage-resolve-lib.sh"
# shellcheck source=.gaia/scripts/usage-render-lib.sh
. "$_usage_script_directory/usage-render-lib.sh"
# Absent after a partial update: readouts then take the pre-change sequence.
# shellcheck source=.gaia/scripts/usage-memo-lib.sh
[ -f "$_usage_script_directory/usage-memo-lib.sh" ] && . "$_usage_script_directory/usage-memo-lib.sh" 2>/dev/null
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$_usage_script_directory/ledger-path-lib.sh" 2>/dev/null || true
# Absent after a partial update: readouts then print cost as unavailable.
# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$_usage_script_directory/token-pricing-lib.sh" 2>/dev/null || true

usage_help() {
  cat <<'EOF'
usage: bash .gaia/scripts/usage.sh <subcommand> [args]
  link <child-ref> <parent-ref> [--source <s>]      record a lineage edge
  link --merge <pr> (--branch <raw> | --key <branch-ref>) [--merged-at <iso>] [--source <s>]
  link --pr <pr> --branch <raw> [--source <s>]      record a PR's branch
  unlink <child-ref> <parent-ref>                   tombstone an edge
  lineage <path-to-SPEC.md>                         record a SPEC's lineage: entries
  declare <research:slug|init:slug> [--session <sid>] [--at <iso>]
  pr [<pr>] [--branch <raw> | --key <branch-ref>] [--merged-at <iso>] [--partial] [--unconfirmed]
  pr-branch <pr>                                    the branch key a PR is linked to
  initiative <ref>                                  spend under each root of <ref>
  reconcile                                         attributed vs unattributed spend
common: [--main-root <dir>] [--telemetry-dir <dir>] [--ledger <cost.jsonl>]
        [--rate-table <path>] [--projects-root <dir>]
link, unlink, declare: [--session <sid>] [--sidechain]
EOF
}

_error() { printf 'usage %s: %s\n' "$SUBCOMMAND" "$*" >&2; }
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_is_pr() { [[ "${1-}" =~ ^[1-9][0-9]{0,9}$ ]]; }
# The ref grammar admits `..` and empty path segments; git refuses both in a
# ref name, so no normalized branch carries one and a --key that does is a typo
# or a probe.
_key_ok() {
  case "$1" in branch:*) ;; *) return 1 ;; esac
  gaia_usage_valid_reference "$1" || return 1
  case "${1#branch:}" in *..* | /* | */ | *//*) return 1 ;; esac
}
_is_iso() { [[ "${1-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; }

MAIN_ROOT="" TELEMETRY_DIRECTORY="" LEDGER="" RATE_TABLE="" PROJECTS_ROOT="" SESSION="" SIDECHAIN=false
SOURCE="" MERGE="" PR_NUMBER="" BRANCH="" KEY="" MERGED_AT="" AT="" PARTIAL=0 UNCONFIRMED=0
ARGS=()

# rc 2 on a malformed flag; the caller decides whether that exits 2 or 0.
_parse() {
  local flag
  while [ $# -gt 0 ]; do
    flag="$1"
    case "$flag" in
      --sidechain) SIDECHAIN=true; shift; continue ;;
      --partial) PARTIAL=1; shift; continue ;;
      --unconfirmed) UNCONFIRMED=1; shift; continue ;;
      --main-root | --telemetry-dir | --ledger | --rate-table | --projects-root | --session | --source | \
        --merge | --pr | --branch | --key | --merged-at | --at)
        [ $# -ge 2 ] || { _error "$flag needs a value"; return 2; }
        case "$flag" in
          --main-root) MAIN_ROOT="$2" ;; --telemetry-dir) TELEMETRY_DIRECTORY="$2" ;; --ledger) LEDGER="$2" ;;
          --rate-table) RATE_TABLE="$2" ;; --projects-root) PROJECTS_ROOT="$2" ;; --session) SESSION="$2" ;;
          --source) SOURCE="$2" ;; --merge) MERGE="$2" ;; --pr) PR_NUMBER="$2" ;; --branch) BRANCH="$2" ;;
          --key) KEY="$2" ;; --merged-at) MERGED_AT="$2" ;; --at) AT="$2" ;;
        esac
        shift 2 ;;
      --) shift; while [ $# -gt 0 ]; do ARGS[${#ARGS[@]}]="$1"; shift; done ;;
      -*) _error "unknown flag ${flag//[^A-Za-z0-9._=\/-]/?}"; return 2 ;;
      *) ARGS[${#ARGS[@]}]="$flag"; shift ;;
    esac
  done
}

# Resolves the roots every subcommand shares. The ledger follows the one rule
# the flusher also uses, so a split point and an interval read the same file.
_resolve_context() {
  if [ -z "$MAIN_ROOT" ]; then MAIN_ROOT="$(gaia_usage_main_root)" || MAIN_ROOT=""; fi
  if [ -z "$TELEMETRY_DIRECTORY" ]; then
    [ -n "$MAIN_ROOT" ] || { _error "no main checkout resolves; pass --main-root"; return 2; }
    TELEMETRY_DIRECTORY="$(gaia_usage_telemetry_directory "$MAIN_ROOT")"
  elif [ -z "$LEDGER" ]; then
    LEDGER="$TELEMETRY_DIRECTORY/cost.jsonl"
  fi
  if [ -z "$LEDGER" ]; then
    if declare -F gaia_resolve_ledger_path >/dev/null 2>&1; then
      LEDGER="$(gaia_resolve_ledger_path "" "$MAIN_ROOT")" || LEDGER=""
    fi
    [ -n "$LEDGER" ] || LEDGER="$TELEMETRY_DIRECTORY/cost.jsonl"
  fi
  [ -n "$PROJECTS_ROOT" ] || PROJECTS_ROOT="$(gaia_usage_projects_root "")"
  return 0
}

_keys() { gaia_usage_keys_json "${MAIN_ROOT:-.}" "$TELEMETRY_DIRECTORY/usage.jsonl" "$TELEMETRY_DIRECTORY/links.jsonl" "$LEDGER" "$@"; }

# jq refuses to compile a def that names an unbound global, so every call
# binds all of them: the stores as $usage_store, $links_store, $cost_store, plus $keys, $rates, $pr, $key,
# and $reference from the shell globals below.
KEYS='{}' RATES=null PR_JSON=null
_jq_store() {
  local filter="$1" usage_file="$TELEMETRY_DIRECTORY/usage.jsonl" links_file="$TELEMETRY_DIRECTORY/links.jsonl" cost_file="$LEDGER"
  shift
  [ -f "$usage_file" ] || usage_file=/dev/null
  [ -f "$links_file" ] || links_file=/dev/null
  [ -f "$cost_file" ] || cost_file=/dev/null
  # priced_row is referenced by usage_model, so a missing pricing lib gets a
  # stand-in that prices nothing; RATES stays null and the readout says so.
  local pricing="${GAIA_PRICING_JQ_DEFS-}"
  [ -n "$pricing" ] || pricing='def priced_row($row): {dollars: 0, unpriced: []};'
  # $keys grows with the branch history, so it reaches jq on fd 3 rather than
  # argv, where Linux refuses any one argument over 128 KiB. Bound ahead of the
  # defs, it is the $keys their bodies name, as the global was.
  jq -n --rawfile usage_store "$usage_file" --rawfile links_store "$links_file" --rawfile cost_store "$cost_file" --rawfile _keysraw /dev/fd/3 --argjson rates "$RATES" \
    --argjson pr "$PR_JSON" --arg key "$KEY" --arg reference "${ARGS[0]-}" "$@" \
    "(\$_keysraw | fromjson) as \$keys | $GAIA_USAGE_JQ_DEFS$pricing$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MODEL_JQ$GAIA_USAGE_VIEW_JQ $filter" \
    3<<<"$KEYS"
}

_live_edges() {
  KEYS="$(_keys "$@")" || return 1
  _jq_store 'usage_edges(usage_rows($links_store); usage_rows($cost_store); $keys)' -c
}

# _append <target> <rows>: the rows file is removed on every path.
_append() {
  local target="$1" rows="$2" exit_status=0
  gaia_usage_append "$TELEMETRY_DIRECTORY" "$target" "$rows" || exit_status=$?
  rm -f "$rows"
  case "$exit_status" in
    0) return 0 ;;
    75) _error "ledger lock timed out; nothing was written, rerun the command"; return 75 ;;
    *) _error "no ledger mutex available; nothing was written"; return 1 ;;
  esac
}

_rows_file() { mkdir -p "$TELEMETRY_DIRECTORY" && mktemp "$TELEMETRY_DIRECTORY/.usage-rows.tmp.XXXXXX"; }

_session_or_null() {
  local session_id="${SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$session_id" ] && gaia_usage_valid_reference "session:$session_id"; then printf '%s' "$session_id"; fi
}

# _branch_reference <raw>: the key for a raw branch, empty for an empty
# normalization or the default branch (both are session spend, never a branch).
_branch_reference() {
  local normalized_branch
  _gaia_usage_load gaia_branch_normalize branch-name-lib.sh || return 1
  normalized_branch="$(gaia_branch_normalize "$1")"
  [ -n "$normalized_branch" ] || return 0
  [ "$normalized_branch" = HEAD ] && return 0
  [ "$normalized_branch" = "$(gaia_usage_default_branch "${MAIN_ROOT:-.}")" ] && return 0
  gaia_usage_branch_key "$normalized_branch"
}

# _edge_rows <rows_file> <kind> <source> <skip_live 0|1> <child> <parent>...:
# appends one row per pair to the rows file. A cycle refuses the whole call
# unless skip_live is set (lineage), where the pair is skipped instead.
_edge_rows() {
  local rows="$1" kind="$2" edge_source="$3" skip="$4" edges child parent cycle_path session_id written_count=0
  shift 4
  session_id="$(_session_or_null)"
  edges="$(_live_edges "$@")" || { _error "could not read the links ledger"; return 1; }
  while [ $# -ge 2 ]; do
    child="$1" parent="$2"
    shift 2
    if [ "$kind" = edge ]; then
      if [ "$skip" = 1 ] && jq -e --arg child "$child" --arg parent "$parent" 'any(.[]; .child == $child and .parent == $parent)' <<<"$edges" >/dev/null; then
        continue
      fi
      cycle_path="$(jq -r --arg child "$child" --arg parent "$parent" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
        . as $live_edges | usage_path($live_edges; $parent; $child) | if . == null then empty else [$child] + . | join(" -> ") end' <<<"$edges")"
      if [ -n "$cycle_path" ]; then
        _error "refused: the edge would close a cycle (each arrow points from child to parent)"
        printf '  cycle: %s\n' "${cycle_path//[^A-Za-z0-9._:%\/ >-]/?}" >&2
        [ "$skip" = 1 ] && continue
        return 1
      fi
    fi
    jq -nc --arg kind "$kind" --arg child "$child" --arg parent "$parent" --arg edge_source "$edge_source" --arg timestamp "$(_now)" --arg session_id "$session_id" \
      --argjson sidechain "$SIDECHAIN" '{schema_version: 1, kind: $kind, child: $child, parent: $parent, source: $edge_source, ts: $timestamp,
        session_id: (if $session_id == "" then null else $session_id end), sidechain: $sidechain}' >>"$rows" || return 1
    written_count=$((written_count + 1))
  done
  [ "$written_count" -gt 0 ] || return 3
}

_check_source() {
  local allowed_source
  for allowed_source in "$@"; do [ "$SOURCE" = "$allowed_source" ] && return 0; done
  _error "--source must be one of: $*"
  return 2
}

subcommand_link() {
  local rows exit_status key
  if [ -n "$MERGE" ]; then
    SOURCE="${SOURCE:-link-command}"
    _check_source gh-pr-merge link-command || return 2
    _is_pr "$MERGE" || { _error "--merge takes a PR number"; return 2; }
    MERGED_AT="${MERGED_AT:-$(_now)}"
    _is_iso "$MERGED_AT" || { _error "--merged-at takes a UTC ISO time (YYYY-MM-DDTHH:MM:SSZ)"; return 2; }
    if [ -n "$KEY" ]; then
      _key_ok "$KEY" || { _error "--key is not a valid branch ref"; return 2; }
      key="$KEY"
    elif [ -n "$BRANCH" ]; then
      key="$(_branch_reference "$BRANCH")"
      [ -n "$key" ] || { _error "--branch names no feature branch"; return 2; }
    else
      _error "--merge needs --branch or --key"; return 2
    fi
    rows="$(_rows_file)" || return 1
    jq -nc --argjson pr "$MERGE" --arg branch_key "$key" --arg merged_at "$MERGED_AT" --arg edge_source "$SOURCE" --arg timestamp "$(_now)" \
      --arg session_id "$(_session_or_null)" '{schema_version: 1, kind: "merge", pr: $pr, key: $branch_key, merged_at: $merged_at,
        source: $edge_source, ts: $timestamp, session_id: (if $session_id == "" then null else $session_id end)}' >"$rows" || { rm -f "$rows"; return 1; }
    _append links.jsonl "$rows"
    return
  fi
  SOURCE="${SOURCE:-link-command}"
  _check_source link-command spec-frontmatter gh-pr-create gh-pr-merge || return 2
  if [ -n "$PR_NUMBER" ]; then
    _is_pr "$PR_NUMBER" || { _error "--pr takes a PR number"; return 2; }
    [ -n "$BRANCH" ] || { _error "--pr needs --branch"; return 2; }
    key="$(_branch_reference "$BRANCH")"
    [ -n "$key" ] || return 0
    rows="$(_rows_file)" || return 1
    exit_status=0
    _edge_rows "$rows" edge "$SOURCE" 1 "pr:$PR_NUMBER" "$key" || exit_status=$?
    [ "$exit_status" = 0 ] || { rm -f "$rows"; [ "$exit_status" = 3 ] && return 0; return "$exit_status"; }
    _append links.jsonl "$rows"
    return
  fi
  [ "${#ARGS[@]}" -eq 2 ] || { _error "link takes <child-ref> <parent-ref>"; return 2; }
  gaia_usage_valid_reference "${ARGS[0]}" || { _error "invalid child ref"; return 2; }
  gaia_usage_valid_reference "${ARGS[1]}" || { _error "invalid parent ref"; return 2; }
  rows="$(_rows_file)" || return 1
  exit_status=0
  _edge_rows "$rows" edge "$SOURCE" 0 "${ARGS[0]}" "${ARGS[1]}" || exit_status=$?
  [ "$exit_status" = 0 ] || { rm -f "$rows"; return "$exit_status"; }
  _append links.jsonl "$rows"
}

subcommand_unlink() {
  local rows
  [ "${#ARGS[@]}" -eq 2 ] || { _error "unlink takes <child-ref> <parent-ref>"; return 2; }
  gaia_usage_valid_reference "${ARGS[0]}" || { _error "invalid child ref"; return 2; }
  gaia_usage_valid_reference "${ARGS[1]}" || { _error "invalid parent ref"; return 2; }
  rows="$(_rows_file)" || return 1
  _edge_rows "$rows" unlink link-command 0 "${ARGS[0]}" "${ARGS[1]}" || { rm -f "$rows"; return 1; }
  _append links.jsonl "$rows"
}

# Reads the frontmatter at call time only; nothing reads a SPEC file at read
# time, so the edges must be on the ledger before the SPEC folder is reaped.
subcommand_lineage() {
  local path="${ARGS[0]-}" id entry rows exit_status first=1
  local -a pairs=()
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf "usage lineage: no SPEC file at '%s'\n" "${path//[^A-Za-z0-9._\/ -]/?}" >&2
    return 2
  fi
  while IFS= read -r entry; do
    if [ "$first" = 1 ]; then
      first=0 id="$entry"
      gaia_usage_valid_reference "spec:$id" || { _error "frontmatter spec_id is not SPEC-NNN"; return 2; }
      continue
    fi
    [ -n "$entry" ] || continue
    if ! gaia_usage_valid_reference "$entry"; then
      _error "skipping lineage entry that is not a valid ref"
      printf '  entry: %s\n' "${entry//[^A-Za-z0-9._:\/ -]/?}" >&2
      continue
    fi
    pairs[${#pairs[@]}]="spec:$id"
    pairs[${#pairs[@]}]="$entry"
  done < <(gaia_usage_spec_lineage "$path")
  [ "$first" = 0 ] || { _error "frontmatter spec_id is not SPEC-NNN"; return 2; }
  [ "${#pairs[@]}" -gt 0 ] || return 0
  rows="$(_rows_file)" || return 1
  exit_status=0
  _edge_rows "$rows" edge spec-frontmatter 1 "${pairs[@]}" || exit_status=$?
  [ "$exit_status" = 0 ] || { rm -f "$rows"; [ "$exit_status" = 3 ] && return 0; return "$exit_status"; }
  _append links.jsonl "$rows"
}

subcommand_declare() {
  local reference="${ARGS[0]-}" session_id rows invoking_session_id="${CLAUDE_CODE_SESSION_ID:-}"
  [ "${#ARGS[@]}" -eq 1 ] || { _error "declare takes one research: or init: ref"; return 2; }
  case "$reference" in research:* | init:*) ;; *) _error "declare accepts only research: and init: refs"; return 2 ;; esac
  gaia_usage_valid_reference "$reference" || { _error "invalid ref"; return 2; }
  session_id="${SESSION:-$invoking_session_id}"
  gaia_usage_valid_reference "session:$session_id" || { _error "no session to bind; pass --session <sid>"; return 2; }
  AT="${AT:-$(_now)}"
  _is_iso "$AT" || { _error "--at takes a UTC ISO time (YYYY-MM-DDTHH:MM:SSZ)"; return 2; }
  gaia_usage_valid_reference "session:$invoking_session_id" || invoking_session_id=""
  rows="$(_rows_file)" || return 1
  jq -nc --arg session_id "$session_id" --arg timestamp "$AT" --arg reference "$reference" --arg invoking_session_id "$invoking_session_id" --argjson sidechain "$SIDECHAIN" \
    '{schema_version: 1, kind: "binding", type: "declare", session_id: $session_id, ts: $timestamp, ref: $reference,
      source: "declare-command", invoking_session_id: (if $invoking_session_id == "" then null else $invoking_session_id end), sidechain: $sidechain}' \
    >"$rows" || { rm -f "$rows"; return 1; }
  _append usage.jsonl "$rows"
}

subcommand_pr_branch() {
  _is_pr "${ARGS[0]-}" || return 0
  PR_JSON="${ARGS[0]}"
  KEYS="$(_keys)" || return 0
  _jq_store 'usage_rows($links_store) as $links | usage_pr_branch($links; usage_edges($links; []; $keys); $pr) // empty' \
    -r 2>/dev/null
  return 0
}

# _readout_legacy <view-filter> <renderer> [renderer args...]: the pre-change
# readout, kept as the fallback the memo path can always land on.
_readout_legacy() {
  local view="$1" render="$2" view_json hooks=0 unflushed
  shift 2
  KEYS="$(_keys)" || KEYS='{}'
  usage_rates_load "$RATE_TABLE" "$MAIN_ROOT" "$(usage_models_of "$KEYS" ||
    _jq_store '[usage_rows($usage_store)[] | select(.kind == "segment") | (.by_model // {}) | keys[]] | unique' -c)"
  RATES="$USAGE_RATES"
  view_json="$(_jq_store "$view" -c)" || { _error "could not read the usage ledger"; return 0; }
  gaia_usage_hooks_registered "$MAIN_ROOT" && hooks=1
  unflushed="$(usage_unflushed "$PROJECTS_ROOT" "$MAIN_ROOT" "$TELEMETRY_DIRECTORY")"
  "$render" "$view_json" "$hooks" "$unflushed" "$@"
}

# Reruns this command in a fresh bash that takes only the legacy readout: the
# rate heal tries the feed once per process, and the memo path spent that try.
_readout_fallback() {
  gaia_usage_memo_trace "fallback=legacy"
  _GAIA_USAGE_READOUT_LEGACY=1 "${BASH:-bash}" "$_usage_self" "$SUBCOMMAND" --main-root "$MAIN_ROOT" \
    --telemetry-dir "$TELEMETRY_DIRECTORY" --ledger "$LEDGER" --projects-root "$PROJECTS_ROOT" ${_USAGE_ARGV[@]+"${_USAGE_ARGV[@]}"}
}

# _readout <view> <legacy-view> <renderer> [renderer args...]: <view> reads
# $usage_records, $links, $cost and the memo-restricted $memo_keys; <legacy-view> is the same
# view for the pre-change sequence. The renderers never read RATES, so the memo
# path can run in a subshell.
_readout() {
  local view="$1" legacy="$2" render="$3" view_json hooks=0 unflushed
  shift 3
  if [ -n "${_GAIA_USAGE_READOUT_LEGACY:-}" ] || ! declare -F gaia_usage_memo_readout >/dev/null 2>&1; then
    _readout_legacy "$legacy" "$render" "$@"
    return 0
  fi
  view_json="$(gaia_usage_memo_readout "$_usage_script_directory" "$TELEMETRY_DIRECTORY" "$LEDGER" "$MAIN_ROOT" "$RATE_TABLE" "$view" \
    --argjson pr "$PR_JSON" --arg key "$KEY" --arg reference "${ARGS[0]-}")" || { _readout_fallback; return 0; }
  gaia_usage_hooks_registered "$MAIN_ROOT" && hooks=1
  unflushed="$(usage_unflushed "$PROJECTS_ROOT" "$MAIN_ROOT" "$TELEMETRY_DIRECTORY")"
  "$render" "$view_json" "$hooks" "$unflushed" "$@"
}

subcommand_pr() {
  if [ "${#ARGS[@]}" -gt 0 ]; then
    _is_pr "${ARGS[0]}" || { _error "pr takes a PR number"; return 0; }
    PR_JSON="${ARGS[0]}"
  fi
  if [ -n "$KEY" ]; then
    _key_ok "$KEY" || { _error "--key is not a valid branch ref"; return 0; }
  elif [ -n "$BRANCH" ]; then
    KEY="$(_branch_reference "$BRANCH")"
    [ -n "$KEY" ] || { _error "--branch names no feature branch"; return 0; }
  elif [ "$PR_JSON" = null ]; then
    _error "pr needs a PR number, --branch, or --key"; return 0
  fi
  _readout 'usage_view_pr_of($usage_records; $links; $cost; $pr; (if $key == "" then null else $key end); $memo_keys)' \
    'usage_view_pr($pr; (if $key == "" then null else $key end))' usage_render_pr \
    "$PARTIAL" "$UNCONFIRMED" "$BRANCH"
}

subcommand_initiative() {
  if [ "${#ARGS[@]}" -ne 1 ] || ! gaia_usage_valid_reference "${ARGS[0]}"; then
    _error "initiative takes one valid ref"
    return 0
  fi
  _readout 'usage_view_initiative_of($usage_records; $links; $cost; $reference; $memo_keys)' 'usage_view_initiative($reference)' \
    usage_render_initiative
}

subcommand_reconcile() { _readout 'usage_view_reconcile_of($usage_records; $links; $cost; $memo_keys)' 'usage_view_reconcile' usage_render_reconcile; }

# _pre <write 0|1> [args...]: the shared preamble of every subcommand. Exits
# on an inactive install or a bad argument; a readout exits 0 either way.
_pre() {
  local write="$1" exit_status=0
  shift
  if [ -n "$(gaia_usage_inactive_reason)" ]; then
    printf 'usage tracking inactive: jq not found\n'
    exit 0
  fi
  _parse "$@" || exit_status=$?
  if [ "$exit_status" = 0 ]; then _resolve_context || exit_status=$?; fi
  [ "$exit_status" = 0 ] && return 0
  [ "$write" = 1 ] && exit "$exit_status"
  exit 0
}

SUBCOMMAND="${1-}"
[ $# -gt 0 ] && shift
_USAGE_ARGV=("$@")
case "$SUBCOMMAND" in
  link) _pre 1 "$@"; subcommand_link; exit ;;
  unlink) _pre 1 "$@"; subcommand_unlink; exit ;;
  lineage) _pre 1 "$@"; subcommand_lineage; exit ;;
  declare) _pre 1 "$@"; subcommand_declare; exit ;;
  pr) _pre 0 "$@"; subcommand_pr; exit 0 ;;
  pr-branch) _pre 0 "$@"; subcommand_pr_branch; exit 0 ;;
  initiative) _pre 0 "$@"; subcommand_initiative; exit 0 ;;
  reconcile) _pre 0 "$@"; subcommand_reconcile; exit 0 ;;
  "" | -h | --help) usage_help; exit 0 ;;
  *) usage_help >&2; exit 2 ;;
esac
