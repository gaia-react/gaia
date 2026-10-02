#!/usr/bin/env bash
# audit-dispositions-check.sh: the deterministic check on an audit round's
# dispositions file, and the renderers of its PR-body records.
#
# Inside an audit-loop unit the Opus orchestrator disposes every finding of a
# round in <run-folder>/dispositions-<r>.json. The main thread no longer reads
# each disposition, so this script forbids the dispositions only a human may
# make. The orchestrator writes the dispositions file and is the
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
#   undisposed                  a branch-authored finding (authored not false), or a key
#                               vetoed for this round, with no entry in the file
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
# hook's invocation passes --snapshot-dir, and only that invocation writes.
# Without --snapshot-dir, `check` and `check-all` read the frozen snapshots
# from the branch's state directory (the state file's path minus .json, plus
# .d), exactly as waiver-table does, and write nothing: a round with a snapshot
# is re-graded from it, a round without one from live findings, so the
# read-only last guard passes on a multi-round branch whose earlier sidecars
# were overwritten. A branch with no state directory has no snapshots to read.
# An existing snapshot is never overwritten by a different file.
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
  */*) _GAIA_DISPOSITIONS_DIRECTORY="${BASH_SOURCE[0]%/*}" ;;
  *) _GAIA_DISPOSITIONS_DIRECTORY="." ;;
esac

_usage() {
  printf 'usage: audit-dispositions-check.sh check|check-all|waiver-table|pr-sections --root <R> --run-folder <D> [--round <r>|--rounds <a>-<b>] [--snapshot-dir <S>]\n' >&2
  return 2
}

_error() { printf 'audit-dispositions-check: %s\n' "$*" >&2; }

# shellcheck disable=SC2016
_GRADE_JQ='
def key_array: [.member, .finding_class, .path, .line];
def key_object: {member, finding_class, path, line};
def trim: gsub("^\\s+|\\s+$"; "");
($vetoes | map(select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line])) as $vetoed_keys
| ($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| [.entries[] | key_array] as $disposed_keys
| (
    (.entries[] | . as $entry | key_array as $key | $lookup_by_key[($key | tojson)] as $lookup_entry | ($vetoed_keys | any(. == $key)) as $is_vetoed | (key_object | tojson) as $key_json
      | (if $lookup_entry == null and ($is_vetoed | not) then ["unknown-key"]
         else [
           (if $lookup_entry != null and .disposition != "fix"
               and ((($lookup_entry.severity | IN("warning", "suggestion")) | not) or ($lookup_entry.security | if type == "boolean" then . else true end))
               and ((.disposition == "file" and $lookup_entry.authored == false) | not)
            then (if ($lookup_entry.severity | IN("warning", "suggestion")) then "security-not-fix" else "critical-not-fix" end)
            else empty end),
           (if .disposition != "fix" and ((if (.reason | type) == "string" then .reason else "" end) | trim) == ""
            then "empty-reason" else empty end),
           (if $is_vetoed and .disposition != "fix" then "vetoed-not-fix" else empty end),
           (if .disposition == "waive-out-of-scope" and ((.basis | IN("triage-threshold", "cross-remit")) | not)
            then "missing-basis" else empty end),
           (if .disposition == "waive-out-of-scope" and .basis == "cross-remit" and ($lookup_entry == null or $lookup_entry.cross_remit != true)
            then "cross-remit-basis-mismatch" else empty end)
         ] end)
      | .[] | "violation: \(.) \($key_json)"),
    (([$lookup[] | select(.authored != false)] + [$vetoes[] | select(.effective_from_round <= $round)])
      | map(key_object) | unique_by(key_array) | .[] | select(key_array as $key | $disposed_keys | any(. == $key) | not)
      | "violation: undisposed \(tojson)"),
    (if ((.enforcement_paths_allowed // []) | if type == "array" then length > 0 else true end)
     then "violation: enforcement-paths-set \(.enforcement_paths_allowed | tojson)" else empty end)
  )
'

# _sha256 <file>: the hex digest.
_sha256() {
  local digest_output
  if command -v shasum >/dev/null 2>&1; then
    digest_output="$(shasum -a 256 <"$1")" || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest_output="$(sha256sum <"$1")" || return 1
  else
    return 1
  fi
  printf '%s\n' "${digest_output%% *}"
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
  local vetoes_file="$RUN_FOLDER/vetoes.json"
  VETOES="[]"
  [ -e "$vetoes_file" ] || return 0
  VETOES="$(jq -c -s 'if length == 1 and (.[0] | type == "object" and .version == 1 and (.keys | type) == "array"
      and all(.keys[]; type == "object" and (.member | type) == "string" and (.finding_class | type) == "string"
        and (.path | type) == "string" and (.effective_from_round | type == "number" and . == floor)))
    then .[0].keys else error("malformed vetoes.json") end' <"$vetoes_file" 2>/dev/null)" || { _error "unparseable $vetoes_file"; return 3; }
  [ -n "$VETOES" ] || { _error "unparseable $vetoes_file"; return 3; }
}

# _live_lookup <r>: the round's findings as the lookup array. rc 3 on failure.
_live_lookup() {
  local evaluator_output
  evaluator_output="$(bash "$_GAIA_DISPOSITIONS_DIRECTORY/audit-loop-eval.sh" findings --root "$ROOT" --round "$1" 2>/dev/null)" || return 3
  printf '%s' "$evaluator_output" | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored})' 2>/dev/null || return 3
}

# _grade <round> <lookup-json>: prints violations; rc 0 none, 1 some, 3 input.
_grade() {
  local violations
  violations="$(jq -r --argjson round "$1" --argjson lookup "$2" --argjson vetoes "$VETOES" "$_GRADE_JQ" "$RUN_FOLDER/dispositions-$1.json" 2>/dev/null)" || return 3
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}

# _default_snapshot_directory: the branch's snapshot directory, read only; empty when
# the evaluator knows no state path for ROOT.
_default_snapshot_directory() {
  local state_path
  state_path="$(bash "$_GAIA_DISPOSITIONS_DIRECTORY/audit-loop-eval.sh" state-path --root "$ROOT" 2>/dev/null)" && printf '%s.d' "${state_path%.json}"
  return 0
}

# _snapshot_path <round>: the snapshot of a round in READ_DIRECTORY, which is
# --snapshot-dir when given and the branch's default directory otherwise.
_snapshot_path() { printf '%s/dispositions-%s.checked.json' "$READ_DIRECTORY" "$1"; }

# _write_snapshot <round> <sha> <lookup>
_write_snapshot() {
  local temporary_file
  mkdir -p "$SNAPSHOT_DIRECTORY" 2>/dev/null || { _error "cannot create $SNAPSHOT_DIRECTORY"; return 3; }
  temporary_file="$(mktemp "$SNAPSHOT_DIRECTORY/.dispositions-$1.XXXXXX")" || { _error "cannot write in $SNAPSHOT_DIRECTORY"; return 3; }
  if jq -n -c --argjson round "$1" --arg sha "$2" --argjson lookup "$3" '{version: 1, round: $round, dispositions_sha256: $sha, lookup: $lookup}' >"$temporary_file" \
    && mv -f "$temporary_file" "$(_snapshot_path "$1")"; then
    return 0
  fi
  rm -f "$temporary_file"
  _error "cannot write the snapshot for round $1"
  return 3
}

# _check_live <round>: the live check; writes the snapshot on a pass when asked.
_check_live() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" lookup exit_status sha snapshot_file have
  [ -f "$dispositions_file" ] || { _error "no $dispositions_file"; return 3; }
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  lookup="$(_live_lookup "$round")" || { _error "the evaluator could not read round $round"; return 3; }
  exit_status=0
  _grade "$round" "$lookup" || exit_status=$?
  [ "$exit_status" -eq 3 ] && { _error "could not grade $dispositions_file"; return 3; }
  if [ -n "$SNAPSHOT_DIRECTORY" ]; then
    sha="$(_sha256 "$dispositions_file")" || { _error "no sha256 tool"; return 3; }
    snapshot_file="$(_snapshot_path "$round")"
    if [ -e "$snapshot_file" ]; then
      have="$(jq -r '.dispositions_sha256 // ""' <"$snapshot_file" 2>/dev/null)" || have=""
      if [ "$have" != "$sha" ]; then
        printf 'violation: edited-after-check {"round":%s}\n' "$round"
        return 1
      fi
    elif [ "$exit_status" -eq 0 ]; then
      _write_snapshot "$round" "$sha" "$lookup" || return 3
    fi
  fi
  return "$exit_status"
}

# _check_snapshot <round>: re-grade from the frozen snapshot.
_check_snapshot() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" snapshot_file sha have lookup
  snapshot_file="$(_snapshot_path "$round")"
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  have="$(jq -r 'if .version == 1 and (.lookup | type) == "array" then .dispositions_sha256 else error("bad") end' <"$snapshot_file" 2>/dev/null)" \
    || { _error "unreadable snapshot $snapshot_file"; return 3; }
  sha="$(_sha256 "$dispositions_file")" || { _error "no sha256 tool"; return 3; }
  if [ "$have" != "$sha" ]; then
    printf 'violation: edited-after-check {"round":%s}\n' "$round"
    return 1
  fi
  lookup="$(jq -c '.lookup' <"$snapshot_file")" || return 3
  _grade "$round" "$lookup"
}

_command_check() {
  [[ "${ROUND:-}" =~ ^[0-9]+$ ]] && [ "$ROUND" -ge 1 ] || { _usage; return 2; }
  _load_vetoes || return 3
  if [ -z "$SNAPSHOT_DIRECTORY" ] && [ -n "$READ_DIRECTORY" ] && [ -e "$(_snapshot_path "$ROUND")" ]; then
    _check_snapshot "$ROUND"
    return $?
  fi
  _check_live "$ROUND"
}

_command_check_all() {
  local dispositions_file base round exit_status worst=0
  _load_vetoes || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$dispositions_file" ] || continue
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    round="${BASH_REMATCH[1]}"
    round=$((10#$round))
    exit_status=0
    if [ -n "$READ_DIRECTORY" ] && [ -e "$(_snapshot_path "$round")" ]; then
      _check_snapshot "$round" || exit_status=$?
    else
      _check_live "$round" || exit_status=$?
    fi
    if [ "$exit_status" -eq 3 ]; then worst=3
    elif [ "$exit_status" -ne 0 ] && [ "$worst" -eq 0 ]; then worst=1; fi
  done
  return "$worst"
}

# shellcheck disable=SC2016
_TABLE_JQ='
def key_array: [.member, .finding_class, .path, .line];
def cell: tostring | gsub("\\|"; "\\|") | gsub("\\s+"; " ");
($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| .entries[] | select(.disposition != "fix") | . as $entry | $lookup_by_key[(key_array | tojson)] as $lookup_entry
| "| \("\(.path):\(.line) \(.finding_class)" | cell) | \(.member | cell) | \(($lookup_entry.severity // "unknown") | cell)"
  + " | \(($lookup_entry | if . == null then "unknown" else (.security | if type == "boolean" then . else true end) end) | cell)"
  + " | \(.disposition | cell) | \((if (.reason | type) == "string" then .reason else "" end) | cell) |"
'

_command_waiver_table() {
  local first_round last_round round dispositions_file lookup snapshot_directory snapshot_file
  [[ "${ROUNDS:-}" =~ ^([0-9]+)-([0-9]+)$ ]] || { _usage; return 2; }
  first_round=$((10#${BASH_REMATCH[1]}))
  last_round=$((10#${BASH_REMATCH[2]}))
  snapshot_directory="$READ_DIRECTORY"
  printf '| key | member | severity | security | disposition | reason |\n|---|---|---|---|---|---|\n'
  round="$first_round"
  while [ "$round" -le "$last_round" ]; do
    dispositions_file="$RUN_FOLDER/dispositions-$round.json"
    if [ -f "$dispositions_file" ]; then
      _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
      snapshot_file="$snapshot_directory/dispositions-$round.checked.json"
      lookup=""
      if [ -n "$snapshot_directory" ] && [ -e "$snapshot_file" ]; then
        lookup="$(jq -c 'if (.lookup | type) == "array" then .lookup else error("bad") end' <"$snapshot_file" 2>/dev/null)" || lookup=""
      fi
      [ -n "$lookup" ] || lookup="$(_live_lookup "$round")" || lookup="[]"
      jq -r --argjson lookup "$lookup" "$_TABLE_JQ" "$dispositions_file" || return 3
    fi
    round=$((round + 1))
  done
}

# shellcheck disable=SC2016
_ENTRIES_JQ='
($vetoes | map(select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line])) as $vetoed_keys
| [.entries[] | select(.disposition != "fix") | . as $entry | [.member, .finding_class, .path, .line] as $key
   | select(($vetoed_keys | any(. == $key)) | not)
   | {round: $round, path, line, finding_class, disposition,
      basis: (if (.basis | type) == "string" then .basis else "" end),
      reason: (if (.reason | type) == "string" then .reason else "" end)}]
'

# shellcheck disable=SC2016
_SECTIONS_JQ='
def trim: gsub("^\\s+|\\s+$"; "");
def one: gsub("<!--|-->"; "") | gsub("\\s+"; " ") | trim | if . == "" then "no reason recorded" else . end;
def line_number: if (.line | type) == "number" and .line >= 1 then .line else 1 end;
def keyed: "- `\(.path):\(line_number)` \(.reason | one). <!-- gaia-debt-key: v1 class=\(.finding_class) path=\(.path) line=\(line_number) -->";
def triage: "- \(.path):\(line_number) \(.finding_class): \(.reason | one)";
def section($head; $rows; fmt): if ($rows | length) == 0 then empty else ([$head, ""] + ($rows | map(fmt)) | join("\n")) end;
(add // [])
| map(. + {sec: (if .disposition == "accept-residual" then "accept"
                 elif .disposition == "waive-out-of-scope" and .basis == "cross-remit" then "cross"
                 elif .disposition == "waive-out-of-scope" and .basis == "triage-threshold" then "triage"
                 else "" end)})
| map(select(.sec != ""))
| sort_by(-.round) | unique_by([.sec, .path, .line, .finding_class])
| sort_by(.path, .line, .finding_class) as $all
| [ section("## Accepted residuals (recorded, not fixed)"; ($all | map(select(.sec == "accept"))); keyed),
    section("## Out-of-scope machinery findings (recorded, not filed)"; ($all | map(select(.sec == "cross"))); keyed),
    section("## Waived below triage threshold (not filed)"; ($all | map(select(.sec == "triage"))); triage) ]
| join("\n\n")
'

_command_pr_sections() {
  local dispositions_file base round chunks="" one
  _load_vetoes || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$dispositions_file" ] || continue
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    round=$((10#${BASH_REMATCH[1]}))
    _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
    one="$(jq -c --argjson round "$round" --argjson vetoes "$VETOES" "$_ENTRIES_JQ" "$dispositions_file")" || return 3
    chunks="$chunks$one"$'\n'
  done
  [ -n "$chunks" ] || return 0
  printf '%s' "$chunks" | jq -r -s "$_SECTIONS_JQ" || return 3
}

main() {
  local subcommand="${1-}"
  [ $# -gt 0 ] && shift
  ROOT="" RUN_FOLDER="" ROUND="" ROUNDS="" SNAPSHOT_DIRECTORY="" READ_DIRECTORY=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _usage; return 2; }; ROOT="$2"; shift 2 ;;
      --run-folder) [ $# -ge 2 ] || { _usage; return 2; }; RUN_FOLDER="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _usage; return 2; }; ROUND="$2"; shift 2 ;;
      --rounds) [ $# -ge 2 ] || { _usage; return 2; }; ROUNDS="$2"; shift 2 ;;
      --snapshot-dir) [ $# -ge 2 ] || { _usage; return 2; }; SNAPSHOT_DIRECTORY="$2"; shift 2 ;;
      *) _usage; return 2 ;;
    esac
  done
  case "$subcommand" in
    check | check-all | waiver-table | pr-sections) ;;
    *) _usage; return 2 ;;
  esac
  [ -n "$RUN_FOLDER" ] || { _usage; return 2; }
  case "$subcommand" in pr-sections) ;; *) [ -n "$ROOT" ] || { _usage; return 2; } ;; esac
  command -v jq >/dev/null 2>&1 || { _error "jq is required and was not found on PATH"; return 3; }
  READ_DIRECTORY="$SNAPSHOT_DIRECTORY"
  case "$subcommand" in pr-sections) ;; *) [ -n "$READ_DIRECTORY" ] || READ_DIRECTORY="$(_default_snapshot_directory)" ;; esac
  case "$subcommand" in
    check) _command_check ;;
    check-all) _command_check_all ;;
    waiver-table) _command_waiver_table ;;
    pr-sections) _command_pr_sections ;;
  esac
}

main "$@"
exit $?
