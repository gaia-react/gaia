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
_usage_dir="${BASH_SOURCE[0]%/*}"
[ "$_usage_dir" = "${BASH_SOURCE[0]}" ] && _usage_dir=.
# shellcheck source=.gaia/scripts/usage-lib.sh
. "$_usage_dir/usage-lib.sh"
# shellcheck source=.gaia/scripts/usage-resolve-lib.sh
. "$_usage_dir/usage-resolve-lib.sh"
# shellcheck source=.gaia/scripts/usage-render-lib.sh
. "$_usage_dir/usage-render-lib.sh"
# Absent after a partial update: readouts then take the pre-change sequence.
# shellcheck source=.gaia/scripts/usage-memo-lib.sh
[ -f "$_usage_dir/usage-memo-lib.sh" ] && . "$_usage_dir/usage-memo-lib.sh" 2>/dev/null
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$_usage_dir/ledger-path-lib.sh" 2>/dev/null || true
# Absent after a partial update: readouts then print cost as unavailable.
# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$_usage_dir/token-pricing-lib.sh" 2>/dev/null || true

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

_err() { printf 'usage %s: %s\n' "$SUB" "$*" >&2; }
_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_is_pr() { [[ "${1-}" =~ ^[1-9][0-9]{0,9}$ ]]; }
# The ref grammar admits `..` and empty path segments; git refuses both in a
# ref name, so no normalized branch carries one and a --key that does is a typo
# or a probe.
_key_ok() {
  case "$1" in branch:*) ;; *) return 1 ;; esac
  gaia_usage_valid_ref "$1" || return 1
  case "${1#branch:}" in *..* | /* | */ | *//*) return 1 ;; esac
}
_is_iso() { [[ "${1-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$ ]]; }

MAIN_ROOT="" TEL="" LEDGER="" RATE_TABLE="" PROJECTS_ROOT="" SESSION="" SIDECHAIN=false
SOURCE="" MERGE="" PRNUM="" BRANCH="" KEY="" MERGED_AT="" AT="" PARTIAL=0 UNCONFIRMED=0
ARGS=()

# rc 2 on a malformed flag; the caller decides whether that exits 2 or 0.
_parse() {
  local f
  while [ $# -gt 0 ]; do
    f="$1"
    case "$f" in
      --sidechain) SIDECHAIN=true; shift; continue ;;
      --partial) PARTIAL=1; shift; continue ;;
      --unconfirmed) UNCONFIRMED=1; shift; continue ;;
      --main-root | --telemetry-dir | --ledger | --rate-table | --projects-root | --session | --source | \
        --merge | --pr | --branch | --key | --merged-at | --at)
        [ $# -ge 2 ] || { _err "$f needs a value"; return 2; }
        case "$f" in
          --main-root) MAIN_ROOT="$2" ;; --telemetry-dir) TEL="$2" ;; --ledger) LEDGER="$2" ;;
          --rate-table) RATE_TABLE="$2" ;; --projects-root) PROJECTS_ROOT="$2" ;; --session) SESSION="$2" ;;
          --source) SOURCE="$2" ;; --merge) MERGE="$2" ;; --pr) PRNUM="$2" ;; --branch) BRANCH="$2" ;;
          --key) KEY="$2" ;; --merged-at) MERGED_AT="$2" ;; --at) AT="$2" ;;
        esac
        shift 2 ;;
      --) shift; while [ $# -gt 0 ]; do ARGS[${#ARGS[@]}]="$1"; shift; done ;;
      -*) _err "unknown flag ${f//[^A-Za-z0-9._=\/-]/?}"; return 2 ;;
      *) ARGS[${#ARGS[@]}]="$f"; shift ;;
    esac
  done
}

# Resolves the roots every subcommand shares. The ledger follows the one rule
# the flusher also uses, so a split point and an interval read the same file.
_ctx() {
  if [ -z "$MAIN_ROOT" ]; then MAIN_ROOT="$(gaia_usage_main_root)" || MAIN_ROOT=""; fi
  if [ -z "$TEL" ]; then
    [ -n "$MAIN_ROOT" ] || { _err "no main checkout resolves; pass --main-root"; return 2; }
    TEL="$(gaia_usage_telemetry_dir "$MAIN_ROOT")"
  elif [ -z "$LEDGER" ]; then
    LEDGER="$TEL/cost.jsonl"
  fi
  if [ -z "$LEDGER" ]; then
    if declare -F gaia_resolve_ledger_path >/dev/null 2>&1; then
      LEDGER="$(gaia_resolve_ledger_path "" "$MAIN_ROOT")" || LEDGER=""
    fi
    [ -n "$LEDGER" ] || LEDGER="$TEL/cost.jsonl"
  fi
  [ -n "$PROJECTS_ROOT" ] || PROJECTS_ROOT="$(gaia_usage_projects_root "")"
  return 0
}

_keys() { gaia_usage_keys_json "${MAIN_ROOT:-.}" "$TEL/usage.jsonl" "$TEL/links.jsonl" "$LEDGER" "$@"; }

# jq refuses to compile a def that names an unbound global, so every call
# binds all of them: the stores as $u, $l, $c, plus $keys, $rates, $pr, $key,
# and $ref from the shell globals below.
KEYS='{}' RATES=null PR_JSON=null
_jq_store() {
  local filter="$1" u="$TEL/usage.jsonl" l="$TEL/links.jsonl" c="$LEDGER"
  shift
  [ -f "$u" ] || u=/dev/null
  [ -f "$l" ] || l=/dev/null
  [ -f "$c" ] || c=/dev/null
  # priced_row is referenced by usage_model, so a missing pricing lib gets a
  # stand-in that prices nothing; RATES stays null and the readout says so.
  local pricing="${GAIA_PRICING_JQ_DEFS-}"
  [ -n "$pricing" ] || pricing='def priced_row($r): {dollars: 0, unpriced: []};'
  # $keys grows with the branch history, so it reaches jq on fd 3 rather than
  # argv, where Linux refuses any one argument over 128 KiB. Bound ahead of the
  # defs, it is the $keys their bodies name, as the global was.
  jq -n --rawfile u "$u" --rawfile l "$l" --rawfile c "$c" --rawfile _keysraw /dev/fd/3 --argjson rates "$RATES" \
    --argjson pr "$PR_JSON" --arg key "$KEY" --arg ref "${ARGS[0]-}" "$@" \
    "(\$_keysraw | fromjson) as \$keys | $GAIA_USAGE_JQ_DEFS$pricing$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MODEL_JQ$GAIA_USAGE_VIEW_JQ $filter" \
    3<<<"$KEYS"
}

_live_edges() {
  KEYS="$(_keys "$@")" || return 1
  _jq_store 'usage_edges(usage_rows($l); usage_rows($c); $keys)' -c
}

# _append <target> <rows>: the rows file is removed on every path.
_append() {
  local target="$1" rows="$2" rc=0
  gaia_usage_append "$TEL" "$target" "$rows" || rc=$?
  rm -f "$rows"
  case "$rc" in
    0) return 0 ;;
    75) _err "ledger lock timed out; nothing was written, rerun the command"; return 75 ;;
    *) _err "no ledger mutex available; nothing was written"; return 1 ;;
  esac
}

_rows_file() { mkdir -p "$TEL" && mktemp "$TEL/.usage-rows.tmp.XXXXXX"; }

_session_or_null() {
  local s="${SESSION:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -n "$s" ] && gaia_usage_valid_ref "session:$s"; then printf '%s' "$s"; fi
}

# _branch_ref <raw>: the key for a raw branch, empty for an empty
# normalization or the default branch (both are session spend, never a branch).
_branch_ref() {
  local norm
  _gaia_usage_load gaia_branch_normalize branch-name-lib.sh || return 1
  norm="$(gaia_branch_normalize "$1")"
  [ -n "$norm" ] || return 0
  [ "$norm" = HEAD ] && return 0
  [ "$norm" = "$(gaia_usage_default_branch "${MAIN_ROOT:-.}")" ] && return 0
  gaia_usage_branch_key "$norm"
}

# _edge_rows <rows_file> <kind> <source> <skip_live 0|1> <child> <parent>...:
# appends one row per pair to the rows file. A cycle refuses the whole call
# unless skip_live is set (lineage), where the pair is skipped instead.
_edge_rows() {
  local rows="$1" kind="$2" src="$3" skip="$4" edges ch pa cyc sid n=0
  shift 4
  sid="$(_session_or_null)"
  edges="$(_live_edges "$@")" || { _err "could not read the links ledger"; return 1; }
  while [ $# -ge 2 ]; do
    ch="$1" pa="$2"
    shift 2
    if [ "$kind" = edge ]; then
      if [ "$skip" = 1 ] && jq -e --arg c "$ch" --arg p "$pa" 'any(.[]; .child == $c and .parent == $p)' <<<"$edges" >/dev/null; then
        continue
      fi
      cyc="$(jq -r --arg c "$ch" --arg p "$pa" "$GAIA_USAGE_JQ_DEFS$GAIA_USAGE_RESOLVE_JQ"'
        . as $e | usage_path($e; $p; $c) | if . == null then empty else [$c] + . | join(" -> ") end' <<<"$edges")"
      if [ -n "$cyc" ]; then
        _err "refused: the edge would close a cycle (each arrow points from child to parent)"
        printf '  cycle: %s\n' "${cyc//[^A-Za-z0-9._:%\/ >-]/?}" >&2
        [ "$skip" = 1 ] && continue
        return 1
      fi
    fi
    jq -nc --arg k "$kind" --arg c "$ch" --arg p "$pa" --arg s "$src" --arg ts "$(_now)" --arg sid "$sid" \
      --argjson sc "$SIDECHAIN" '{schema_version: 1, kind: $k, child: $c, parent: $p, source: $s, ts: $ts,
        session_id: (if $sid == "" then null else $sid end), sidechain: $sc}' >>"$rows" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 3
}

_check_source() {
  local s
  for s in "$@"; do [ "$SOURCE" = "$s" ] && return 0; done
  _err "--source must be one of: $*"
  return 2
}

cmd_link() {
  local rows rc key
  if [ -n "$MERGE" ]; then
    SOURCE="${SOURCE:-link-command}"
    _check_source gh-pr-merge link-command || return 2
    _is_pr "$MERGE" || { _err "--merge takes a PR number"; return 2; }
    MERGED_AT="${MERGED_AT:-$(_now)}"
    _is_iso "$MERGED_AT" || { _err "--merged-at takes a UTC ISO time (YYYY-MM-DDTHH:MM:SSZ)"; return 2; }
    if [ -n "$KEY" ]; then
      _key_ok "$KEY" || { _err "--key is not a valid branch ref"; return 2; }
      key="$KEY"
    elif [ -n "$BRANCH" ]; then
      key="$(_branch_ref "$BRANCH")"
      [ -n "$key" ] || { _err "--branch names no feature branch"; return 2; }
    else
      _err "--merge needs --branch or --key"; return 2
    fi
    rows="$(_rows_file)" || return 1
    jq -nc --argjson pr "$MERGE" --arg k "$key" --arg m "$MERGED_AT" --arg s "$SOURCE" --arg ts "$(_now)" \
      --arg sid "$(_session_or_null)" '{schema_version: 1, kind: "merge", pr: $pr, key: $k, merged_at: $m,
        source: $s, ts: $ts, session_id: (if $sid == "" then null else $sid end)}' >"$rows" || { rm -f "$rows"; return 1; }
    _append links.jsonl "$rows"
    return
  fi
  SOURCE="${SOURCE:-link-command}"
  _check_source link-command spec-frontmatter gh-pr-create gh-pr-merge || return 2
  if [ -n "$PRNUM" ]; then
    _is_pr "$PRNUM" || { _err "--pr takes a PR number"; return 2; }
    [ -n "$BRANCH" ] || { _err "--pr needs --branch"; return 2; }
    key="$(_branch_ref "$BRANCH")"
    [ -n "$key" ] || return 0
    rows="$(_rows_file)" || return 1
    rc=0
    _edge_rows "$rows" edge "$SOURCE" 1 "pr:$PRNUM" "$key" || rc=$?
    [ "$rc" = 0 ] || { rm -f "$rows"; [ "$rc" = 3 ] && return 0; return "$rc"; }
    _append links.jsonl "$rows"
    return
  fi
  [ "${#ARGS[@]}" -eq 2 ] || { _err "link takes <child-ref> <parent-ref>"; return 2; }
  gaia_usage_valid_ref "${ARGS[0]}" || { _err "invalid child ref"; return 2; }
  gaia_usage_valid_ref "${ARGS[1]}" || { _err "invalid parent ref"; return 2; }
  rows="$(_rows_file)" || return 1
  rc=0
  _edge_rows "$rows" edge "$SOURCE" 0 "${ARGS[0]}" "${ARGS[1]}" || rc=$?
  [ "$rc" = 0 ] || { rm -f "$rows"; return "$rc"; }
  _append links.jsonl "$rows"
}

cmd_unlink() {
  local rows
  [ "${#ARGS[@]}" -eq 2 ] || { _err "unlink takes <child-ref> <parent-ref>"; return 2; }
  gaia_usage_valid_ref "${ARGS[0]}" || { _err "invalid child ref"; return 2; }
  gaia_usage_valid_ref "${ARGS[1]}" || { _err "invalid parent ref"; return 2; }
  rows="$(_rows_file)" || return 1
  _edge_rows "$rows" unlink link-command 0 "${ARGS[0]}" "${ARGS[1]}" || { rm -f "$rows"; return 1; }
  _append links.jsonl "$rows"
}

# Reads the frontmatter at call time only; nothing reads a SPEC file at read
# time, so the edges must be on the ledger before the SPEC folder is reaped.
cmd_lineage() {
  local path="${ARGS[0]-}" id e rows rc first=1
  local -a pairs=()
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    printf "usage lineage: no SPEC file at '%s'\n" "${path//[^A-Za-z0-9._\/ -]/?}" >&2
    return 2
  fi
  while IFS= read -r e; do
    if [ "$first" = 1 ]; then
      first=0 id="$e"
      gaia_usage_valid_ref "spec:$id" || { _err "frontmatter spec_id is not SPEC-NNN"; return 2; }
      continue
    fi
    [ -n "$e" ] || continue
    if ! gaia_usage_valid_ref "$e"; then
      _err "skipping lineage entry that is not a valid ref"
      printf '  entry: %s\n' "${e//[^A-Za-z0-9._:\/ -]/?}" >&2
      continue
    fi
    pairs[${#pairs[@]}]="spec:$id"
    pairs[${#pairs[@]}]="$e"
  done < <(gaia_usage_spec_lineage "$path")
  [ "$first" = 0 ] || { _err "frontmatter spec_id is not SPEC-NNN"; return 2; }
  [ "${#pairs[@]}" -gt 0 ] || return 0
  rows="$(_rows_file)" || return 1
  rc=0
  _edge_rows "$rows" edge spec-frontmatter 1 "${pairs[@]}" || rc=$?
  [ "$rc" = 0 ] || { rm -f "$rows"; [ "$rc" = 3 ] && return 0; return "$rc"; }
  _append links.jsonl "$rows"
}

cmd_declare() {
  local ref="${ARGS[0]-}" sid rows inv="${CLAUDE_CODE_SESSION_ID:-}"
  [ "${#ARGS[@]}" -eq 1 ] || { _err "declare takes one research: or init: ref"; return 2; }
  case "$ref" in research:* | init:*) ;; *) _err "declare accepts only research: and init: refs"; return 2 ;; esac
  gaia_usage_valid_ref "$ref" || { _err "invalid ref"; return 2; }
  sid="${SESSION:-$inv}"
  gaia_usage_valid_ref "session:$sid" || { _err "no session to bind; pass --session <sid>"; return 2; }
  AT="${AT:-$(_now)}"
  _is_iso "$AT" || { _err "--at takes a UTC ISO time (YYYY-MM-DDTHH:MM:SSZ)"; return 2; }
  gaia_usage_valid_ref "session:$inv" || inv=""
  rows="$(_rows_file)" || return 1
  jq -nc --arg sid "$sid" --arg ts "$AT" --arg r "$ref" --arg inv "$inv" --argjson sc "$SIDECHAIN" \
    '{schema_version: 1, kind: "binding", type: "declare", session_id: $sid, ts: $ts, ref: $r,
      source: "declare-command", invoking_session_id: (if $inv == "" then null else $inv end), sidechain: $sc}' \
    >"$rows" || { rm -f "$rows"; return 1; }
  _append usage.jsonl "$rows"
}

cmd_pr_branch() {
  _is_pr "${ARGS[0]-}" || return 0
  PR_JSON="${ARGS[0]}"
  KEYS="$(_keys)" || return 0
  _jq_store 'usage_rows($l) as $links | usage_pr_branch($links; usage_edges($links; []; $keys); $pr) // empty' \
    -r 2>/dev/null
  return 0
}

# _readout_legacy <view-filter> <renderer> [renderer args...]: the pre-change
# readout, kept as the fallback the memo path can always land on.
_readout_legacy() {
  local view="$1" render="$2" v hooks=0 unf
  shift 2
  KEYS="$(_keys)" || KEYS='{}'
  usage_rates_load "$RATE_TABLE" "$MAIN_ROOT" "$(usage_models_of "$KEYS" ||
    _jq_store '[usage_rows($u)[] | select(.kind == "segment") | (.by_model // {}) | keys[]] | unique' -c)"
  RATES="$USAGE_RATES"
  v="$(_jq_store "$view" -c)" || { _err "could not read the usage ledger"; return 0; }
  gaia_usage_hooks_registered "$MAIN_ROOT" && hooks=1
  unf="$(usage_unflushed "$PROJECTS_ROOT" "$MAIN_ROOT" "$TEL")"
  "$render" "$v" "$hooks" "$unf" "$@"
}

# Reruns this command in a fresh bash that takes only the legacy readout: the
# rate heal tries the feed once per process, and the memo path spent that try.
_readout_fallback() {
  gaia_usage_memo_trace "fallback=legacy"
  _GAIA_USAGE_READOUT_LEGACY=1 "${BASH:-bash}" "$_usage_self" "$SUB" --main-root "$MAIN_ROOT" \
    --telemetry-dir "$TEL" --ledger "$LEDGER" --projects-root "$PROJECTS_ROOT" ${_USAGE_ARGV[@]+"${_USAGE_ARGV[@]}"}
}

# _readout <view> <legacy-view> <renderer> [renderer args...]: <view> reads
# $urows, $links, $cost and the memo-restricted $mk; <legacy-view> is the same
# view for the pre-change sequence. The renderers never read RATES, so the memo
# path can run in a subshell.
_readout() {
  local view="$1" legacy="$2" render="$3" v hooks=0 unf
  shift 3
  if [ -n "${_GAIA_USAGE_READOUT_LEGACY:-}" ] || ! declare -F gaia_usage_memo_readout >/dev/null 2>&1; then
    _readout_legacy "$legacy" "$render" "$@"
    return 0
  fi
  v="$(gaia_usage_memo_readout "$_usage_dir" "$TEL" "$LEDGER" "$MAIN_ROOT" "$RATE_TABLE" "$view" \
    --argjson pr "$PR_JSON" --arg key "$KEY" --arg ref "${ARGS[0]-}")" || { _readout_fallback; return 0; }
  gaia_usage_hooks_registered "$MAIN_ROOT" && hooks=1
  unf="$(usage_unflushed "$PROJECTS_ROOT" "$MAIN_ROOT" "$TEL")"
  "$render" "$v" "$hooks" "$unf" "$@"
}

cmd_pr() {
  if [ "${#ARGS[@]}" -gt 0 ]; then
    _is_pr "${ARGS[0]}" || { _err "pr takes a PR number"; return 0; }
    PR_JSON="${ARGS[0]}"
  fi
  if [ -n "$KEY" ]; then
    _key_ok "$KEY" || { _err "--key is not a valid branch ref"; return 0; }
  elif [ -n "$BRANCH" ]; then
    KEY="$(_branch_ref "$BRANCH")"
    [ -n "$KEY" ] || { _err "--branch names no feature branch"; return 0; }
  elif [ "$PR_JSON" = null ]; then
    _err "pr needs a PR number, --branch, or --key"; return 0
  fi
  _readout 'usage_view_pr_of($urows; $links; $cost; $pr; (if $key == "" then null else $key end); $mk)' \
    'usage_view_pr($pr; (if $key == "" then null else $key end))' usage_render_pr \
    "$PARTIAL" "$UNCONFIRMED" "$BRANCH"
}

cmd_initiative() {
  if [ "${#ARGS[@]}" -ne 1 ] || ! gaia_usage_valid_ref "${ARGS[0]}"; then
    _err "initiative takes one valid ref"
    return 0
  fi
  _readout 'usage_view_initiative_of($urows; $links; $cost; $ref; $mk)' 'usage_view_initiative($ref)' \
    usage_render_initiative
}

cmd_reconcile() { _readout 'usage_view_reconcile_of($urows; $links; $cost; $mk)' 'usage_view_reconcile' usage_render_reconcile; }

# _pre <write 0|1> [args...]: the shared preamble of every subcommand. Exits
# on an inactive install or a bad argument; a readout exits 0 either way.
_pre() {
  local write="$1" rc=0
  shift
  if [ -n "$(gaia_usage_inactive_reason)" ]; then
    printf 'usage tracking inactive: jq not found\n'
    exit 0
  fi
  _parse "$@" || rc=$?
  if [ "$rc" = 0 ]; then _ctx || rc=$?; fi
  [ "$rc" = 0 ] && return 0
  [ "$write" = 1 ] && exit "$rc"
  exit 0
}

SUB="${1-}"
[ $# -gt 0 ] && shift
_USAGE_ARGV=("$@")
case "$SUB" in
  link) _pre 1 "$@"; cmd_link; exit ;;
  unlink) _pre 1 "$@"; cmd_unlink; exit ;;
  lineage) _pre 1 "$@"; cmd_lineage; exit ;;
  declare) _pre 1 "$@"; cmd_declare; exit ;;
  pr) _pre 0 "$@"; cmd_pr; exit 0 ;;
  pr-branch) _pre 0 "$@"; cmd_pr_branch; exit 0 ;;
  initiative) _pre 0 "$@"; cmd_initiative; exit 0 ;;
  reconcile) _pre 0 "$@"; cmd_reconcile; exit 0 ;;
  "" | -h | --help) usage_help; exit 0 ;;
  *) usage_help >&2; exit 2 ;;
esac
