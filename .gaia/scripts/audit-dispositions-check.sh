#!/usr/bin/env bash
# audit-dispositions-check.sh: the deterministic check on an audit round's
# dispositions file, and the renderers of its PR-body records.
#
# Inside an audit-loop unit the Opus orchestrator disposes every finding of a
# round in <run-folder>/dispositions-<r>.json. The main thread no longer reads
# each disposition, so this script forbids the dispositions only a human may
# make (SPEC-093 D4). The orchestrator writes the dispositions file and is the
# actor this check bounds, which is why nothing it grades comes from that file:
# severity, the security flag, cross-remit and authorship are read from the
# members' findings sidecars by identity key (member, finding_class, path,
# line), through `audit-loop-eval.sh findings`. Relabelling a Critical as
# Important inside the dispositions entry changes nothing.
#
# Usage:
#   audit-dispositions-check.sh check        --root <R> --run-folder <D> --round <r> [--snapshot-dir <S>]
#   audit-dispositions-check.sh check-all    --root <R> --run-folder <D> [--snapshot-dir <S>]
#   audit-dispositions-check.sh waiver-table --root <R> --run-folder <D> --rounds <a>-<b> [--snapshot-dir <S>]
#   audit-dispositions-check.sh pr-sections  --root <R> --run-folder <D>
#
# Rules (a violation prints `violation: <token> <compact key json>` on stdout):
#   critical-not-fix            a Critical (severity error) key disposed anything but fix,
#                               or file when the finding is branch-authored
#   security-not-fix            the same for a security:true key (a finding with no
#                               boolean security field reads as true)
#   empty-reason                a non-fix disposition with an empty or blank reason
#   vetoed-not-fix              a key vetoed for this round (effective_from_round <= r)
#                               that is not fix; a synthetic fix entry for a vetoed key
#                               no member re-reported passes
#   enforcement-paths-set       enforcement_paths_allowed is non-empty (a finding that
#                               needs one stops the unit with needs-human)
#   missing-basis               waive-out-of-scope without basis triage-threshold|cross-remit
#   cross-remit-basis-mismatch  basis cross-remit on a finding not flagged cross_remit
#   unknown-key                 an entry with no matching finding and no veto: reads as
#                               Critical and security (fail closed)
#   edited-after-check          the dispositions file no longer matches its snapshot
#
# Exit codes: 0 pass, 1 violation, 2 usage, 3 unreadable input (jq absent, the
# evaluator failing, an unparseable dispositions, vetoes or snapshot file).
#
# Frozen snapshots. A member's sidecar is overwritten every round, so once
# round r+1's members write, round r's findings are gone and a re-grade of an
# old dispositions file would read every key as unknown. With --snapshot-dir a
# passing live `check` writes <S>/dispositions-<r>.checked.json (the file's
# sha256 plus the per-key lookup it graded), and `check-all` re-grades from
# that snapshot, never from live sidecars and never through the evaluator. The
# snapshot directory is in the guarded loop state directory; only the bound
# hook's invocation passes --snapshot-dir (the unit runs without it and writes
# nothing). An existing snapshot is never overwritten by a different file.
#
# Vetoes apply forward only. vetoes.json entries carry effective_from_round, so
# a veto recorded after a unit returned binds the rounds it applies to and
# never re-fails the earlier dispositions file that held the original waiver.
#
# Honest limits. A member that misclassifies a finding as security:false is not
# caught here. vetoes.json sits in the Claude-writable run folder (the main
# thread writes it) and is trusted as written; a forged veto can only demand
# more fix, never fewer.
#
# waiver-table prints a markdown table of every non-fix entry for a round range,
# severity and security from the snapshot when present (default directory: the
# branch's state directory, read only), else from live findings; `unknown`
# when neither knows the key. pr-sections prints the PR-body records: accepted
# residuals and cross-remit waivers in the keyed form /gaia-residue parses,
# triage-threshold waivers as key-less one-liners, vetoed keys excluded for the
# rounds the veto binds.

set -uo pipefail

case "${BASH_SOURCE[0]}" in
  */*) _GAIA_DISP_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) _GAIA_DISP_DIR="." ;;
esac

_usage() {
  printf 'usage: audit-dispositions-check.sh check|check-all|waiver-table|pr-sections --root <R> --run-folder <D> [--round <r>|--rounds <a>-<b>] [--snapshot-dir <S>]\n' >&2
  return 2
}

_err() { printf 'audit-dispositions-check: %s\n' "$*" >&2; }

# shellcheck disable=SC2016
_GRADE_JQ='
def idk: [.member, .finding_class, .path, .line];
def kid: {member, finding_class, path, line};
def trim: gsub("^\\s+|\\s+$"; "");
($vet | map(select(.effective_from_round <= $r) | [.member, .finding_class, .path, .line])) as $vk
| ($look | map({key: (idk | tojson), value: .}) | from_entries) as $L
| (
    (.entries[] | . as $e | idk as $k | $L[($k | tojson)] as $l | ($vk | any(. == $k)) as $v | (kid | tojson) as $kj
      | (if $l == null and ($v | not) then ["unknown-key"]
         else [
           (if $l != null and .disposition != "fix"
               and ((($l.severity | IN("warning", "suggestion")) | not) or ($l.security | if type == "boolean" then . else true end))
               and ((.disposition == "file" and $l.authored == false) | not)
            then (if ($l.severity | IN("warning", "suggestion")) then "security-not-fix" else "critical-not-fix" end)
            else empty end),
           (if .disposition != "fix" and ((if (.reason | type) == "string" then .reason else "" end) | trim) == ""
            then "empty-reason" else empty end),
           (if $v and .disposition != "fix" then "vetoed-not-fix" else empty end),
           (if .disposition == "waive-out-of-scope" and ((.basis | IN("triage-threshold", "cross-remit")) | not)
            then "missing-basis" else empty end),
           (if .disposition == "waive-out-of-scope" and .basis == "cross-remit" and ($l == null or $l.cross_remit != true)
            then "cross-remit-basis-mismatch" else empty end)
         ] end)
      | .[] | "violation: \(.) \($kj)"),
    (if ((.enforcement_paths_allowed // []) | if type == "array" then length > 0 else true end)
     then "violation: enforcement-paths-set \(.enforcement_paths_allowed | tojson)" else empty end)
  )
'

# _sha256 <file>: the hex digest.
_sha256() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 <"$1")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum <"$1")" || return 1
  else
    return 1
  fi
  printf '%s\n' "${out%% *}"
}

# _valid_dispositions <file>: rc 0 when the file has the shape the grader reads.
_valid_dispositions() {
  jq -e 'type == "object" and (.entries | type) == "array"
    and all(.entries[]; type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
      and (.path | type) == "string" and (.line | type) == "number"
      and (.disposition | IN("fix", "accept-residual", "waive-out-of-scope", "file")))' <"$1" >/dev/null 2>&1
}

# _load_vetoes: sets VETOES to the keys array (with effective_from_round), "[]"
# when the file is absent; rc 3 when present and malformed.
_load_vetoes() {
  local f="$RUN_FOLDER/vetoes.json"
  VETOES="[]"
  [ -e "$f" ] || return 0
  VETOES="$(jq -c -s 'if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
      and all(.keys[]; type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
        and (.path | type) == "string" and (.effective_from_round | type == "number" and . == floor)))
    then .[0].keys else error("malformed vetoes.json") end' <"$f" 2>/dev/null)" || { _err "unparseable $f"; return 3; }
  [ -n "$VETOES" ] || { _err "unparseable $f"; return 3; }
}

# _live_lookup <r>: the round's findings as the lookup array. rc 3 on failure.
_live_lookup() {
  local out
  out="$(bash "$_GAIA_DISP_DIR/audit-loop-eval.sh" findings --root "$ROOT" --round "$1" 2>/dev/null)" || return 3
  printf '%s' "$out" | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored})' 2>/dev/null || return 3
}

# _grade <round> <lookup-json>: prints violations; rc 0 none, 1 some, 3 input.
_grade() {
  local out
  out="$(jq -r --argjson r "$1" --argjson look "$2" --argjson vet "$VETOES" "$_GRADE_JQ" "$RUN_FOLDER/dispositions-$1.json" 2>/dev/null)" || return 3
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"
  return 1
}

# _snapshot_ok <round>: sets SNAP to the snapshot path when present.
_snap_path() { printf '%s/dispositions-%s.checked.json' "$SNAPSHOT_DIR" "$1"; }

# _write_snapshot <round> <sha> <lookup>
_write_snapshot() {
  local tmp
  mkdir -p "$SNAPSHOT_DIR" 2>/dev/null || { _err "cannot create $SNAPSHOT_DIR"; return 3; }
  tmp="$(mktemp "$SNAPSHOT_DIR/.dispositions-$1.XXXXXX")" || { _err "cannot write in $SNAPSHOT_DIR"; return 3; }
  if jq -n -c --argjson r "$1" --arg s "$2" --argjson l "$3" '{version: 1, round: $r, dispositions_sha256: $s, lookup: $l}' >"$tmp" \
    && mv -f "$tmp" "$(_snap_path "$1")"; then
    return 0
  fi
  rm -f "$tmp"
  _err "cannot write the snapshot for round $1"
  return 3
}

# _check_live <round>: the live check; writes the snapshot on a pass when asked.
_check_live() {
  local r="$1" f="$RUN_FOLDER/dispositions-$1.json" lookup rc sha snap have
  [ -f "$f" ] || { _err "no $f"; return 3; }
  _valid_dispositions "$f" || { _err "unreadable dispositions file $f"; return 3; }
  lookup="$(_live_lookup "$r")" || { _err "the evaluator could not read round $r"; return 3; }
  rc=0
  _grade "$r" "$lookup" || rc=$?
  [ "$rc" -eq 3 ] && { _err "could not grade $f"; return 3; }
  if [ -n "$SNAPSHOT_DIR" ]; then
    sha="$(_sha256 "$f")" || { _err "no sha256 tool"; return 3; }
    snap="$(_snap_path "$r")"
    if [ -e "$snap" ]; then
      have="$(jq -r '.dispositions_sha256 // ""' <"$snap" 2>/dev/null)" || have=""
      if [ "$have" != "$sha" ]; then
        printf 'violation: edited-after-check {"round":%s}\n' "$r"
        return 1
      fi
    elif [ "$rc" -eq 0 ]; then
      _write_snapshot "$r" "$sha" "$lookup" || return 3
    fi
  fi
  return "$rc"
}

# _check_snapshot <round>: re-grade from the frozen snapshot.
_check_snapshot() {
  local r="$1" f="$RUN_FOLDER/dispositions-$1.json" snap sha have lookup
  snap="$(_snap_path "$r")"
  _valid_dispositions "$f" || { _err "unreadable dispositions file $f"; return 3; }
  have="$(jq -r 'if .version == 1 and (.lookup | type) == "array" then .dispositions_sha256 else error("bad") end' <"$snap" 2>/dev/null)" \
    || { _err "unreadable snapshot $snap"; return 3; }
  sha="$(_sha256 "$f")" || { _err "no sha256 tool"; return 3; }
  if [ "$have" != "$sha" ]; then
    printf 'violation: edited-after-check {"round":%s}\n' "$r"
    return 1
  fi
  lookup="$(jq -c '.lookup' <"$snap")" || return 3
  _grade "$r" "$lookup"
}

_cmd_check() {
  [[ "${ROUND:-}" =~ ^[0-9]+$ ]] && [ "$ROUND" -ge 1 ] || { _usage; return 2; }
  _load_vetoes || return 3
  _check_live "$ROUND"
}

_cmd_check_all() {
  local f base r rc worst=0
  _load_vetoes || return 3
  for f in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    r="${BASH_REMATCH[1]}"
    r=$((10#$r))
    rc=0
    if [ -n "$SNAPSHOT_DIR" ] && [ -e "$(_snap_path "$r")" ]; then
      _check_snapshot "$r" || rc=$?
    else
      _check_live "$r" || rc=$?
    fi
    if [ "$rc" -eq 3 ]; then worst=3
    elif [ "$rc" -ne 0 ] && [ "$worst" -eq 0 ]; then worst=1; fi
  done
  return "$worst"
}

# shellcheck disable=SC2016
_TABLE_JQ='
def idk: [.member, .finding_class, .path, .line];
def cell: tostring | gsub("\\|"; "\\|") | gsub("\\s+"; " ");
($look | map({key: (idk | tojson), value: .}) | from_entries) as $L
| .entries[] | select(.disposition != "fix") | . as $e | $L[(idk | tojson)] as $l
| "| \("\(.path):\(.line) \(.finding_class)" | cell) | \(.member | cell) | \(($l.severity // "unknown") | cell)"
  + " | \(($l | if . == null then "unknown" else (.security | if type == "boolean" then . else true end) end) | cell)"
  + " | \(.disposition | cell) | \((if (.reason | type) == "string" then .reason else "" end) | cell) |"
'

_cmd_waiver_table() {
  local a b r f lookup sdir snap sp
  [[ "${ROUNDS:-}" =~ ^([0-9]+)-([0-9]+)$ ]] || { _usage; return 2; }
  a=$((10#${BASH_REMATCH[1]}))
  b=$((10#${BASH_REMATCH[2]}))
  sdir="$SNAPSHOT_DIR"
  if [ -z "$sdir" ]; then
    sp="$(bash "$_GAIA_DISP_DIR/audit-loop-eval.sh" state-path --root "$ROOT" 2>/dev/null)" && sdir="${sp%.json}.d"
  fi
  printf '| key | member | severity | security | disposition | reason |\n|---|---|---|---|---|---|\n'
  r="$a"
  while [ "$r" -le "$b" ]; do
    f="$RUN_FOLDER/dispositions-$r.json"
    if [ -f "$f" ]; then
      _valid_dispositions "$f" || { _err "unreadable dispositions file $f"; return 3; }
      snap="$sdir/dispositions-$r.checked.json"
      lookup=""
      if [ -n "$sdir" ] && [ -e "$snap" ]; then
        lookup="$(jq -c 'if (.lookup | type) == "array" then .lookup else error("bad") end' <"$snap" 2>/dev/null)" || lookup=""
      fi
      [ -n "$lookup" ] || lookup="$(_live_lookup "$r")" || lookup="[]"
      jq -r --argjson look "$lookup" "$_TABLE_JQ" "$f" || return 3
    fi
    r=$((r + 1))
  done
}

# shellcheck disable=SC2016
_ENTRIES_JQ='
($vet | map(select(.effective_from_round <= $r) | [.member, .finding_class, .path, .line])) as $vk
| [.entries[] | select(.disposition != "fix") | . as $e | [.member, .finding_class, .path, .line] as $k
   | select(($vk | any(. == $k)) | not)
   | {r: $r, path, line, finding_class, disposition,
      basis: (if (.basis | type) == "string" then .basis else "" end),
      reason: (if (.reason | type) == "string" then .reason else "" end)}]
'

# shellcheck disable=SC2016
_SECTIONS_JQ='
def trim: gsub("^\\s+|\\s+$"; "");
def one: gsub("<!--|-->"; "") | gsub("\\s+"; " ") | trim | if . == "" then "no reason recorded" else . end;
def ln: if (.line | type) == "number" and .line >= 1 then .line else 1 end;
def keyed: "- `\(.path):\(ln)` \(.reason | one). <!-- gaia-debt-key: v1 class=\(.finding_class) path=\(.path) line=\(ln) -->";
def triage: "- \(.path):\(ln) \(.finding_class): \(.reason | one)";
def section($head; $rows; fmt): if ($rows | length) == 0 then empty else ([$head, ""] + ($rows | map(fmt)) | join("\n")) end;
(add // [])
| map(. + {sec: (if .disposition == "accept-residual" then "accept"
                 elif .disposition == "waive-out-of-scope" and .basis == "cross-remit" then "cross"
                 elif .disposition == "waive-out-of-scope" and .basis == "triage-threshold" then "triage"
                 else "" end)})
| map(select(.sec != ""))
| sort_by(-.r) | unique_by([.sec, .path, .line, .finding_class])
| sort_by(.path, .line, .finding_class) as $all
| [ section("## Accepted residuals (recorded, not fixed)"; ($all | map(select(.sec == "accept"))); keyed),
    section("## Out-of-scope machinery findings (recorded, not filed)"; ($all | map(select(.sec == "cross"))); keyed),
    section("## Waived below triage threshold (not filed)"; ($all | map(select(.sec == "triage"))); triage) ]
| join("\n\n")
'

_cmd_pr_sections() {
  local f base r chunks="" one
  _load_vetoes || return 3
  for f in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$f" ] || continue
    base="${f##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    r=$((10#${BASH_REMATCH[1]}))
    _valid_dispositions "$f" || { _err "unreadable dispositions file $f"; return 3; }
    one="$(jq -c --argjson r "$r" --argjson vet "$VETOES" "$_ENTRIES_JQ" "$f")" || return 3
    chunks="$chunks$one"$'\n'
  done
  [ -n "$chunks" ] || return 0
  printf '%s' "$chunks" | jq -r -s "$_SECTIONS_JQ" || return 3
}

main() {
  local sub="${1-}"
  [ $# -gt 0 ] && shift
  ROOT="" RUN_FOLDER="" ROUND="" ROUNDS="" SNAPSHOT_DIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _usage; return 2; }; ROOT="$2"; shift 2 ;;
      --run-folder) [ $# -ge 2 ] || { _usage; return 2; }; RUN_FOLDER="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _usage; return 2; }; ROUND="$2"; shift 2 ;;
      --rounds) [ $# -ge 2 ] || { _usage; return 2; }; ROUNDS="$2"; shift 2 ;;
      --snapshot-dir) [ $# -ge 2 ] || { _usage; return 2; }; SNAPSHOT_DIR="$2"; shift 2 ;;
      *) _usage; return 2 ;;
    esac
  done
  case "$sub" in
    check | check-all | waiver-table | pr-sections) ;;
    *) _usage; return 2 ;;
  esac
  [ -n "$RUN_FOLDER" ] || { _usage; return 2; }
  case "$sub" in pr-sections) ;; *) [ -n "$ROOT" ] || { _usage; return 2; } ;; esac
  command -v jq >/dev/null 2>&1 || { _err "jq is required and was not found on PATH"; return 3; }
  case "$sub" in
    check) _cmd_check ;;
    check-all) _cmd_check_all ;;
    waiver-table) _cmd_waiver_table ;;
    pr-sections) _cmd_pr_sections ;;
  esac
}

main "$@"
exit $?
