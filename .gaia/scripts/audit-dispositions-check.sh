#!/usr/bin/env bash
# audit-dispositions-check.sh: the deterministic check on an audit round's
# dispositions file, and the renderers of its PR-body records.
#
# Inside an audit-loop unit the Opus orchestrator disposes every finding of a
# round in <run-folder>/dispositions-<r>.json. The main thread no longer reads
# each disposition, so this script forbids the dispositions only a human may
# make. The orchestrator writes the dispositions file and is the
# actor this check bounds, which is why nothing it grades comes from that file:
# severity, the security flag, cross-remit, authorship and the triage mark are
# read from the members' findings sidecars by identity key (member,
# finding_class, path, line), through `audit-loop-eval.sh findings`.
# Relabelling a Critical as Important inside the dispositions entry changes
# nothing.
#
# Usage:
#   audit-dispositions-check.sh check          --root <R> --run-folder <D> --round <r> [--snapshot-dir <S>]
#   audit-dispositions-check.sh check-all      --root <R> --run-folder <D> [--snapshot-dir <S>]
#   audit-dispositions-check.sh check-outcomes --root <R> --run-folder <D> --round <r>
#   audit-dispositions-check.sh waiver-table   --root <R> --run-folder <D> --rounds <a>-<b> [--snapshot-dir <S>]
#   audit-dispositions-check.sh pr-sections    --root <R> --run-folder <D> [--snapshot-dir <S>]
#
# Dispositions: fix, accept-residual, waive-out-of-scope, file, divert.
#
# Rules (a violation prints `violation: <token> <compact key json>` on stdout):
#   critical-not-fix            a Critical (severity error) key disposed anything but fix,
#                               or file or divert when the finding is from outside the branch
#   security-not-fix            the same for a security:true key (a finding with no
#                               boolean security field reads as true)
#   security-file-not-private   a Critical or security:true key from outside the branch
#                               disposed file while the repo is not confirmed PRIVATE
#                               (`gh repo view` visibility, probed only when such an
#                               entry exists; a failed probe is not PRIVATE): it diverts,
#                               never a public or internal issue
#   divert-not-allowed          divert on a key that is branch-authored or not
#                               security-class (security not false, or severity error)
#   empty-reason                a non-fix disposition with an empty or blank reason
#   vetoed-not-fix              a waiver-vetoed key (must be fixed) for this round
#                               (effective_from_round <= r) that is not fix; a synthetic
#                               fix entry for a waiver-vetoed key no member re-reported passes
#   undisposed                  a finding of any authorship, or a waiver-vetoed key for
#                               this round, with no entry in the file, unless the finding
#                               carries an honored triage mark or was disposed file or
#                               divert in an earlier round
#   enforcement-paths-set       enforcement_paths_allowed is non-empty (a finding that
#                               needs one stops the unit with needs-human)
#   missing-basis               waive-out-of-scope without basis triage-threshold|cross-remit
#   cross-remit-basis-mismatch  basis cross-remit on a finding not flagged cross_remit
#   unknown-key                 an entry with no matching finding and no veto: reads as
#                               Critical and security (fail closed)
#   edited-after-check          the dispositions file no longer matches its snapshot
#   outcome-missing             (check-outcomes) a file or divert entry with no line in
#                               <D>/filing-outcomes-<r>.jsonl, the filing script's record
#   outcome-failed              (check-outcomes) that line's outcome is failed, or a
#                               value the filing script never writes; absent and
#                               transient pass, since neither is a merge blocker
#
# Triage mark. A sidecar entry with `triage: true` is honored as disposed only
# when its member is on the triage allowlist (empty unless this checkout
# defines one, so elsewhere no mark is honored), the roster at
# <R>/.gaia/audit-ci.yml gives its
# path to that member, its security is exactly false and its severity is not
# error; otherwise it is graded and disposed like any finding. The roster half
# is applied when the lookup is built (an unreadable roster honors nothing), so
# the lookup's `triage` is already roster-bounded. A dispositions entry for the
# key wins over the mark.
#
# Carry-forward. A key disposed file or divert in dispositions-<k>.json, k < r,
# is not undisposed in round r: the filing script's outcome (and its retry
# file, for a transient one) is what keeps it pending, matching the A(r)
# model's disposed set. A key disposed fix earlier carries nothing.
#
# check-outcomes reconciles one round. check-all runs it for every round
# graded under the current predicate (a live round or a version-2 snapshot);
# check never runs it, because the unit files only after its check passes.
#
# Exit codes: 0 pass, 1 violation, 2 usage, 3 unreadable input (jq absent, the
# evaluator failing, an unparseable dispositions, vetoes, outcomes or snapshot
# file, the secret screen failing to run).
#
# Frozen snapshots. A member's sidecar is overwritten every round, so once
# round r+1's members write, round r's findings are gone and a re-grade of an
# old dispositions file would read every key as unknown. With --snapshot-dir a
# passing live `check` writes <S>/dispositions-<r>.checked.json (version 2: the
# file's sha256 plus the per-key lookup it graded, triage mark included), and
# `check-all` re-grades from that snapshot, never from live sidecars and never
# through the evaluator. The snapshot directory is in the guarded loop state
# directory; only the bound hook's invocation passes --snapshot-dir, and only
# that invocation writes. Without --snapshot-dir, every subcommand that grades
# or renders reads the frozen snapshots from the branch's state directory (the state file's path
# minus .json, plus .d) and writes nothing: a round with a snapshot is
# re-graded from it, a round without one from live findings, so the read-only
# last guard passes on a multi-round branch whose earlier sidecars were
# overwritten. A branch with no state directory has no snapshots to read. An
# existing snapshot is never overwritten by a different file.
#
# Forward-only grading. A version-1 snapshot was written before the current
# predicate and is re-graded under the one it passed: only a branch-authored
# finding (authored not false) is mandatory, divert does not exist, no triage
# mark or carry-forward applies, and no outcome reconciliation runs. Live
# rounds and version-2 snapshots use the current predicate.
#
# Vetoes apply forward only. vetoes.json entries carry effective_from_round, so
# a waiver veto recorded after a unit returned binds the rounds it applies to
# and never re-fails the earlier dispositions file that held the original
# waiver.
#
# Visibility. The repository is resolved once from <R> and the visibility read
# names it explicitly, with GH_REPO unset for both calls. No environment
# variable, cached file or other local state is consulted; only an exact
# `PRIVATE` answer counts.
#
# Honest limits. A member that misclassifies a finding as security:false is not
# caught here, and neither is a triage mark on a finding the marking member
# misgrades. vetoes.json sits in the Claude-writable run folder (the main
# thread writes it) and is trusted as written; a forged veto can only demand
# more fix, never fewer. The outcomes file is Claude-writable too: a forged
# `filed` line passes check-outcomes, which bounds an orchestrator that skips
# the filing script, not one that forges its record.
#
# waiver-table prints a markdown table of every non-fix entry for a round range
# except divert, which is a count line under the table; severity and security
# come from the snapshot when present, else from live findings; `unknown` when
# neither knows the key. pr-sections prints the PR-body records from the same
# lookup: accepted residuals and cross-remit waivers in the keyed form
# /gaia-residue parses, triage-threshold waivers and honored triage marks as
# key-less one-liners deduplicated by key, waiver-vetoed keys excluded for the
# rounds the veto binds, diverts as a count only, and the not-filed section
# from the outcomes files and <D>/filing-retry/. A waiver or triage line
# renders only when the lookup says security false and severity not error, and
# every rendered reason passes `file-tech-debt.sh screen-text` first; a reason
# that fails renders as a withheld count.

set -uo pipefail

case "${BASH_SOURCE[0]}" in
  */*) _GAIA_DISPOSITIONS_DIRECTORY="${BASH_SOURCE[0]%/*}" ;;
  *) _GAIA_DISPOSITIONS_DIRECTORY="." ;;
esac

# The members whose sidecar triage mark can be honored. Empty by default, so a
# mark is ignored and the finding is disposed like any other.
_TRIAGE_MEMBERS='[]'
# gaia:maintainer-only:start
# The maintainer members the harness triage threshold governs.
_TRIAGE_MEMBERS='["code-audit-maintainer-shell","code-audit-maintainer-node"]'
# gaia:maintainer-only:end

_usage() {
  printf 'usage: audit-dispositions-check.sh check|check-all|check-outcomes|waiver-table|pr-sections --root <R> --run-folder <D> [--round <r>|--rounds <a>-<b>] [--snapshot-dir <S>]\n' >&2
  return 2
}

_error() { printf 'audit-dispositions-check: %s\n' "$*" >&2; }

_TEMPORARY_FILES=()
# shellcheck disable=SC2329
_cleanup() {
  [ "${#_TEMPORARY_FILES[@]}" -eq 0 ] || rm -f "${_TEMPORARY_FILES[@]}"
  return 0
}
trap _cleanup EXIT

# shellcheck disable=SC2016
_GRADE_JQ='
def key_array: [.member, .finding_class, .path, .line];
def key_object: {member, finding_class, path, line};
def trim: gsub("^\\s+|\\s+$"; "");
def security_class: ((.severity | IN("warning", "suggestion")) | not) or (.security | if type == "boolean" then . else true end);
def triage_honored: .triage == true and .security == false and .severity != "error" and (.member | IN($triage_members[]));
($vetoes | map(select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line])) as $vetoed_keys
| ($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| [.entries[] | key_array] as $disposed_keys
| (if $version >= 2 then $carried else [] end) as $carried_keys
| (
    (.entries[] | . as $entry | key_array as $key | $lookup_by_key[($key | tojson)] as $lookup_entry | ($vetoed_keys | any(. == $key)) as $is_vetoed | (key_object | tojson) as $key_json
      | (if $lookup_entry == null and ($is_vetoed | not) then ["unknown-key"]
         else [
           (if $lookup_entry != null and .disposition != "fix"
               and ((($lookup_entry.severity | IN("warning", "suggestion")) | not) or ($lookup_entry.security | if type == "boolean" then . else true end))
               and (((.disposition == "file" or ($version >= 2 and .disposition == "divert")) and $lookup_entry.authored == false) | not)
            then (if ($lookup_entry.severity | IN("warning", "suggestion")) then "security-not-fix" else "critical-not-fix" end)
            else empty end),
           (if $lookup_entry != null and .disposition == "file" and $lookup_entry.authored == false
               and ($lookup_entry | security_class) and $visibility != "PRIVATE"
            then "security-file-not-private" else empty end),
           (if .disposition == "divert"
               and ($version < 2 or $lookup_entry == null or $lookup_entry.authored != false or (($lookup_entry | security_class) | not))
            then "divert-not-allowed" else empty end),
           (if .disposition != "fix" and ((if (.reason | type) == "string" then .reason else "" end) | trim) == ""
            then "empty-reason" else empty end),
           (if $is_vetoed and .disposition != "fix" then "vetoed-not-fix" else empty end),
           (if .disposition == "waive-out-of-scope" and ((.basis | IN("triage-threshold", "cross-remit")) | not)
            then "missing-basis" else empty end),
           (if .disposition == "waive-out-of-scope" and .basis == "cross-remit" and ($lookup_entry == null or $lookup_entry.cross_remit != true)
            then "cross-remit-basis-mismatch" else empty end)
         ] end)
      | .[] | "violation: \(.) \($key_json)"),
    (([$lookup[]
        | select(if $version >= 2 then (triage_honored | not) else .authored != false end)
        | select(key_array as $key | $carried_keys | any(. == $key) | not)]
      + [$vetoes[] | select(.effective_from_round <= $round)])
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
      and (.disposition | IN("fix", "accept-residual", "waive-out-of-scope", "file", "divert")))' <"$1" >/dev/null 2>&1
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

# _roster_owned_indexes <lookup>: the JSON array of lookup indexes whose
# triage-marked allowlisted entry the roster gives to that same member. The
# roster library lives with the hooks; it is sourced only when a candidate
# exists, and an absent library or unreadable roster honors nothing.
_roster_owned_indexes() {
  local candidates index member path owned="[]" library="$_GAIA_DISPOSITIONS_DIRECTORY/../../.claude/hooks/lib/audit-scope.sh"
  candidates="$(printf '%s' "$1" | jq -r --argjson triage_members "$_TRIAGE_MEMBERS" \
    'to_entries[] | select(.value.triage == true and (.value.member | IN($triage_members[])) and (.value.path | type) == "string")
     | "\(.key)\t\(.value.member)\t\(.value.path)"')" || return 3
  if [ -n "$candidates" ] && [ -f "$library" ]; then
    # shellcheck source=/dev/null
    . "$library" 2>/dev/null
    if type audit_owner_for_path >/dev/null 2>&1 && audit_scope_init "$ROOT" 2>/dev/null; then
      while IFS=$'\t' read -r index member path; do
        [ -n "$path" ] || continue
        [ "$(audit_owner_for_path "$path")" = "$member" ] || continue
        owned="$(jq -n -c --argjson owned "$owned" --argjson index "$index" '$owned + [$index]')" || return 3
      done <<<"$candidates"
    fi
  fi
  printf '%s\n' "$owned"
}

# _live_lookup <r>: the round's findings as the lookup array, the triage mark
# already bounded by the roster. rc 3 on failure.
_live_lookup() {
  local evaluator_output lookup owned
  evaluator_output="$(bash "$_GAIA_DISPOSITIONS_DIRECTORY/audit-loop-eval.sh" findings --root "$ROOT" --round "$1" 2>/dev/null)" || return 3
  lookup="$(printf '%s' "$evaluator_output" | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored,
    triage: (.triage == true), triage_reason: (if (.triage_reason | type) == "string" then .triage_reason else "" end)})' 2>/dev/null)" || return 3
  [ -n "$lookup" ] || return 3
  owned="$(_roster_owned_indexes "$lookup")" || return 3
  printf '%s' "$lookup" | jq -c --argjson owned "$owned" 'to_entries | map(.value + {triage: (.value.triage and (.key | IN($owned[])))})' 2>/dev/null || return 3
}

# _repo_visibility: the visibility of the repository resolved once from ROOT,
# empty when either gh call fails (which reads as not PRIVATE). GH_REPO is
# unset so the environment cannot point either call at another repository.
_repo_visibility() {
  (
    unset GH_REPO
    repository="$(cd "$ROOT" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || exit 0
    [ -n "$repository" ] || exit 0
    gh repo view "$repository" --json visibility --jq .visibility 2>/dev/null || true
  )
}

# _carried_keys <round>: identity keys disposed file or divert in any earlier
# round's dispositions file, read in one jq pass. An unreadable file makes the
# pass carry nothing, so a lost file leaves more findings undisposed, never
# fewer.
_carried_keys() {
  local k=1 carried
  local -a earlier_files=()
  while [ "$k" -lt "$1" ]; do
    [ -f "$RUN_FOLDER/dispositions-$k.json" ] && earlier_files+=("$RUN_FOLDER/dispositions-$k.json")
    k=$((k + 1))
  done
  [ "${#earlier_files[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  carried="$(jq -c -n '[inputs | .entries[] | select(.disposition == "file" or .disposition == "divert") | [.member, .finding_class, .path, .line]]' \
    ${earlier_files[@]+"${earlier_files[@]}"} 2>/dev/null)" || carried=""
  printf '%s\n' "${carried:-[]}"
}

# _grade_pass <round> <lookup> <version> <carried> <visibility>
_grade_pass() {
  jq -r --argjson round "$1" --argjson lookup "$2" --argjson version "$3" --argjson carried "$4" --arg visibility "$5" \
    --argjson vetoes "$VETOES" --argjson triage_members "$_TRIAGE_MEMBERS" "$_GRADE_JQ" "$RUN_FOLDER/dispositions-$1.json" 2>/dev/null
}

# _grade <round> <lookup-json> <predicate-version>: prints violations; rc 0
# none, 1 some, 3 input. The first pass assumes the repo is not PRIVATE, so the
# visibility probe runs only when a security-class file entry makes the answer
# matter.
_grade() {
  local violations carried="[]"
  [ "$3" -ge 2 ] && carried="$(_carried_keys "$1")"
  violations="$(_grade_pass "$1" "$2" "$3" "$carried" unprobed)" || return 3
  case "$violations" in
    *"violation: security-file-not-private "*)
      if [ "$(_repo_visibility)" = PRIVATE ]; then
        violations="$(_grade_pass "$1" "$2" "$3" "$carried" PRIVATE)" || return 3
      fi
      ;;
  esac
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

# _has_snapshot <round>
_has_snapshot() { [ -n "$READ_DIRECTORY" ] && [ -e "$(_snapshot_path "$1")" ]; }

# _write_snapshot <round> <sha> <lookup>
_write_snapshot() {
  local temporary_file
  mkdir -p "$SNAPSHOT_DIRECTORY" 2>/dev/null || { _error "cannot create $SNAPSHOT_DIRECTORY"; return 3; }
  temporary_file="$(mktemp "$SNAPSHOT_DIRECTORY/.dispositions-$1.XXXXXX")" || { _error "cannot write in $SNAPSHOT_DIRECTORY"; return 3; }
  if jq -n -c --argjson round "$1" --arg sha "$2" --argjson lookup "$3" '{version: 2, round: $round, dispositions_sha256: $sha, lookup: $lookup}' >"$temporary_file" \
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
  _grade "$round" "$lookup" 2 || exit_status=$?
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

# _check_snapshot <round>: re-grade from the frozen snapshot, under the
# predicate its version names; sets CHECKED_VERSION to that version.
_check_snapshot() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" snapshot_file sha have lookup version snapshot_fields
  snapshot_file="$(_snapshot_path "$round")"
  CHECKED_VERSION=2
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  snapshot_fields="$(jq -r 'if (.version == 1 or .version == 2) and (.lookup | type) == "array" and (.dispositions_sha256 | type) == "string"
      then .version, .dispositions_sha256, (.lookup | tojson) else error("bad") end' <"$snapshot_file" 2>/dev/null)" \
    || { _error "unreadable snapshot $snapshot_file"; return 3; }
  { IFS= read -r version; IFS= read -r have; IFS= read -r lookup; } <<<"$snapshot_fields"
  CHECKED_VERSION="$version"
  sha="$(_sha256 "$dispositions_file")" || { _error "no sha256 tool"; return 3; }
  if [ "$have" != "$sha" ]; then
    printf 'violation: edited-after-check {"round":%s}\n' "$round"
    return 1
  fi
  _grade "$round" "$lookup" "$version"
}

# _check_outcomes <round>: reconcile every file and divert entry with the
# filing script's outcome line for its key (the last one, when a round filed
# the key more than once). The caller has validated the dispositions file.
_check_outcomes() {
  local round="$1" dispositions_file="$RUN_FOLDER/dispositions-$1.json" outcome_file="$RUN_FOLDER/filing-outcomes-$1.jsonl" violations
  local -a outcome_source=(--argjson outcome_lines '[]')
  [ -e "$outcome_file" ] && outcome_source=(--slurpfile outcome_lines "$outcome_file")
  violations="$(jq -r ${outcome_source[@]+"${outcome_source[@]}"} '
    (if all($outcome_lines[]; type == "object" and (.key | type) == "object") then $outcome_lines
     else error("malformed outcome line") end
     | map({key: (.key | [.member, .finding_class, .path, .line]), outcome})) as $outcomes
    | .entries[] | select(.disposition == "file" or .disposition == "divert")
    | [.member, .finding_class, .path, .line] as $key | ({member, finding_class, path, line} | tojson) as $key_json
    | ([$outcomes[] | select(.key == $key)] | last) as $outcome
    | if $outcome == null then "violation: outcome-missing \($key_json)"
      elif ($outcome.outcome | IN("filed", "diverted", "absent", "transient")) then empty
      else "violation: outcome-failed \($key_json)" end' "$dispositions_file" 2>/dev/null)" \
    || { _error "unparseable $dispositions_file or $outcome_file"; return 3; }
  [ -z "$violations" ] && return 0
  printf '%s\n' "$violations"
  return 1
}

_valid_round() { [[ "${ROUND:-}" =~ ^[0-9]+$ ]] && [ "$ROUND" -ge 1 ]; }

_command_check() {
  _valid_round || { _usage; return 2; }
  _load_vetoes || return 3
  if [ -z "$SNAPSHOT_DIRECTORY" ] && _has_snapshot "$ROUND"; then
    _check_snapshot "$ROUND"
    return $?
  fi
  _check_live "$ROUND"
}

_command_check_outcomes() {
  local dispositions_file
  _valid_round || { _usage; return 2; }
  dispositions_file="$RUN_FOLDER/dispositions-$ROUND.json"
  [ -f "$dispositions_file" ] || { _error "no $dispositions_file"; return 3; }
  _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
  _check_outcomes "$ROUND"
}

# _fold <status>: folds one exit status into WORST, 3 over 1 over 0.
_fold() {
  if [ "$1" -eq 3 ] || [ "$WORST" -eq 3 ]; then WORST=3
  elif [ "$1" -ne 0 ]; then WORST=1; fi
}

_command_check_all() {
  local dispositions_file base round exit_status
  WORST=0
  _load_vetoes || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$dispositions_file" ] || continue
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    round="${BASH_REMATCH[1]}"
    round=$((10#$round))
    exit_status=0
    CHECKED_VERSION=2
    if _has_snapshot "$round"; then
      _check_snapshot "$round" || exit_status=$?
    else
      _check_live "$round" || exit_status=$?
    fi
    _fold "$exit_status"
    # A round whose dispositions file did not read has nothing to reconcile.
    if [ "$CHECKED_VERSION" -ge 2 ] && [ "$exit_status" -ne 3 ]; then
      exit_status=0
      _check_outcomes "$round" || exit_status=$?
      _fold "$exit_status"
    fi
  done
  return "$WORST"
}

# _round_lookup <round>: the snapshot's lookup when one exists, else the live
# one, else "[]" (every key then reads unknown).
_round_lookup() {
  local lookup=""
  if _has_snapshot "$1"; then
    lookup="$(jq -c 'if (.lookup | type) == "array" then .lookup else error("bad") end' <"$(_snapshot_path "$1")" 2>/dev/null)" || lookup=""
  fi
  [ -n "$lookup" ] || lookup="$(_live_lookup "$1")" || lookup="[]"
  printf '%s\n' "$lookup"
}

# _divert_line <count>: the only form a divert takes outside the local record.
_divert_line() {
  printf 'Diverted security findings: %s (local records under .gaia/local/audit/security/)\n' "$1"
}

# shellcheck disable=SC2016
_TABLE_JQ='
def key_array: [.member, .finding_class, .path, .line];
def cell: tostring | gsub("\\|"; "\\|") | gsub("\\s+"; " ");
($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| .entries[] | select(.disposition != "fix" and .disposition != "divert") | . as $entry | $lookup_by_key[(key_array | tojson)] as $lookup_entry
| "| \("\(.path):\(.line) \(.finding_class)" | cell) | \(.member | cell) | \(($lookup_entry.severity // "unknown") | cell)"
  + " | \(($lookup_entry | if . == null then "unknown" else (.security | if type == "boolean" then . else true end) end) | cell)"
  + " | \(.disposition | cell) | \((if (.reason | type) == "string" then .reason else "" end) | cell) |"
'

_command_waiver_table() {
  local first_round last_round round dispositions_file lookup divert_count=0 round_diverts
  [[ "${ROUNDS:-}" =~ ^([0-9]+)-([0-9]+)$ ]] || { _usage; return 2; }
  first_round=$((10#${BASH_REMATCH[1]}))
  last_round=$((10#${BASH_REMATCH[2]}))
  printf '| key | member | severity | security | disposition | reason |\n|---|---|---|---|---|---|\n'
  round="$first_round"
  while [ "$round" -le "$last_round" ]; do
    dispositions_file="$RUN_FOLDER/dispositions-$round.json"
    if [ -f "$dispositions_file" ]; then
      _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
      lookup="$(_round_lookup "$round")"
      jq -r --argjson lookup "$lookup" "$_TABLE_JQ" "$dispositions_file" || return 3
      round_diverts="$(jq '[.entries[] | select(.disposition == "divert")] | length' "$dispositions_file")" || return 3
      divert_count=$((divert_count + round_diverts))
    fi
    round=$((round + 1))
  done
  [ "$divert_count" -eq 0 ] || { printf '\n'; _divert_line "$divert_count"; }
}

# _ROWS_JQ: one round's PR-body candidate rows. A waiver or triage row exists
# only inside the render bound (the lookup says security false and severity
# not error); divert rows carry no reason, since only their count is rendered.
# shellcheck disable=SC2016
_ROWS_JQ='
def key_array: [.member, .finding_class, .path, .line];
def trim: gsub("^\\s+|\\s+$"; "");
def one: gsub("<!--|-->"; "") | gsub("\\s+"; " ") | trim | if . == "" then "no reason recorded" else . end;
def text($value): (if ($value | type) == "string" then $value else "" end) | one;
def in_bound: . != null and .security == false and .severity != "error";
($vetoes | map(select(.effective_from_round <= $round) | [.member, .finding_class, .path, .line])) as $vetoed_keys
| ($lookup | map({key: (key_array | tojson), value: .}) | from_entries) as $lookup_by_key
| [.entries[] | key_array] as $disposed_keys
| [ (.entries[] | select(.disposition != "fix") | select(key_array as $key | $vetoed_keys | any(. == $key) | not)
      | $lookup_by_key[(key_array | tojson)] as $lookup_entry
      | (if .disposition == "accept-residual" then "accept"
         elif .disposition == "divert" then "divert"
         elif .disposition != "waive-out-of-scope" then ""
         elif (($lookup_entry | in_bound) | not) then ""
         elif .basis == "cross-remit" then "cross"
         elif .basis == "triage-threshold" then "triage"
         else "" end) as $section
      | select($section != "")
      | {round: $round, section: $section, member, path, line, finding_class,
         reason: (if $section == "divert" then "" else text(.reason) end)}),
    ($lookup[] | select(.triage == true and (.member | IN($triage_members[])) and in_bound)
      | select(key_array as $key | ($disposed_keys | any(. == $key)) or ($vetoed_keys | any(. == $key)) | not)
      | {round: $round, section: "triage", member, path, line, finding_class, reason: text(.triage_reason)}) ]
'

# shellcheck disable=SC2016
_SECTIONS_JQ='
def line_number: if (.line | type) == "number" and .line >= 1 then .line else 1 end;
def keyed: "- `\(.path):\(line_number)` \(.reason). <!-- gaia-debt-key: v1 class=\(.finding_class) path=\(.path) line=\(line_number) -->";
def triage: "- \(.path):\(line_number) \(.finding_class): \(.reason)";
def withheld($count; $noun): "- \($count) \($noun) withheld: reason failed the secret screen";
def section($head; $rows; fmt; $noun):
  if ($rows | length) == 0 then empty
  else ($rows | map(select(.clean))) as $shown | (($rows | length) - ($shown | length)) as $withheld_count
    | ([$head, ""] + ($shown | map(fmt)) + (if $withheld_count > 0 then [withheld($withheld_count; $noun)] else [] end)) | join("\n") end;
. as $rows
| ([$rows[] | select(.section != "divert")] | to_entries | map(.value + {clean: ($clean[.key] == true)})) as $screened
| [ section("## Accepted residuals (recorded, not fixed)"; ($screened | map(select(.section == "accept"))); keyed; "accepted residual(s)"),
    section("## Out-of-scope machinery findings (recorded, not filed)"; ($screened | map(select(.section == "cross"))); keyed; "waived finding(s)"),
    section("## Waived below triage threshold (not filed)"; ($screened | map(select(.section == "triage"))); triage; "waived finding(s)"),
    (if $divert_line == "" then empty else $divert_line end),
    (if ($absent | length) == 0 and $pending == 0 then empty
     else (["## Not filed (no issue backend)", ""]
       + ($absent | map("- \(.member) \(.path):\(line_number) (\(.finding_class)): not filed, no issue backend"))
       + (if $pending > 0 then ["- \($pending) finding(s) pending: the issue backend was unreachable; retried next round"] else [] end))
       | join("\n") end) ]
| join("\n\n")
'

# _absent_outcomes: the keys whose latest outcome across the rounds' outcome
# files is a file disposition left absent (no issue backend). Lines that do
# not parse are skipped: this renders a record, it does not grade one.
_absent_outcomes() {
  local outcome_file base round chunks=""
  for outcome_file in "$RUN_FOLDER"/filing-outcomes-*.jsonl; do
    [ -e "$outcome_file" ] || continue
    base="${outcome_file##*/}"
    [[ "$base" =~ ^filing-outcomes-([0-9]+)\.jsonl$ ]] || continue
    round=$((10#${BASH_REMATCH[1]}))
    chunks="$chunks$(jq -c -R --argjson round "$round" 'fromjson? | select(type == "object" and (.key | type) == "object") | . + {round: $round}' <"$outcome_file" 2>/dev/null)"$'\n'
  done
  printf '%s' "$chunks" | jq -c -s 'sort_by(.round) | group_by(.key | [.member, .finding_class, .path, .line]) | map(last)
    | map(select(.outcome == "absent" and .disposition == "file") | .key | {member, finding_class, path, line})
    | sort_by(.path, .line, .finding_class)'
}

# _pending_count: the retry files the filing script keeps for transient outcomes.
_pending_count() {
  local retry_file count=0
  for retry_file in "$RUN_FOLDER"/filing-retry/*.json; do
    [ -f "$retry_file" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# _screen_reasons <texts> <scratch-file>: a JSON array of booleans, true for
# each line of <texts> that passes the secret screen. rc 3 when the screen
# cannot run.
_screen_reasons() {
  local text_file="$2" reason_text verdicts="" screen_status
  [ -n "$1" ] || { printf '[]\n'; return 0; }
  while IFS= read -r reason_text; do
    printf '%s\n' "$reason_text" >"$text_file"
    screen_status=0
    bash "$_GAIA_DISPOSITIONS_DIRECTORY/file-tech-debt.sh" screen-text --text-file "$text_file" >/dev/null 2>&1 || screen_status=$?
    case "$screen_status" in
      0) verdicts="$verdicts,true" ;;
      1) verdicts="$verdicts,false" ;;
      *) _error "the secret screen could not run (exit $screen_status)"; return 3 ;;
    esac
  done <<<"$1"
  printf '[%s]\n' "${verdicts#,}"
}

_command_pr_sections() {
  local dispositions_file base round chunks="" one lookup rows texts text_file clean absent pending divert_count divert_line=""
  _load_vetoes || return 3
  for dispositions_file in "$RUN_FOLDER"/dispositions-*.json; do
    [ -e "$dispositions_file" ] || continue
    base="${dispositions_file##*/}"
    [[ "$base" =~ ^dispositions-([0-9]+)\.json$ ]] || continue
    round=$((10#${BASH_REMATCH[1]}))
    _valid_dispositions "$dispositions_file" || { _error "unreadable dispositions file $dispositions_file"; return 3; }
    lookup="$(_round_lookup "$round")"
    one="$(jq -c --argjson round "$round" --argjson vetoes "$VETOES" --argjson lookup "$lookup" \
      --argjson triage_members "$_TRIAGE_MEMBERS" "$_ROWS_JQ" "$dispositions_file")" || return 3
    chunks="$chunks$one"$'\n'
  done
  rows="$(printf '%s' "$chunks" | jq -c -s 'add // [] | sort_by(-.round) | unique_by([.section, .path, .line, .finding_class]) | sort_by(.path, .line, .finding_class)')" || return 3
  texts="$(printf '%s' "$rows" | jq -r '.[] | select(.section != "divert") | .reason')" || return 3
  text_file="$(mktemp "${TMPDIR:-/tmp}/audit-dispositions-reason.XXXXXX")" || { _error "cannot create a scratch file"; return 3; }
  _TEMPORARY_FILES+=("$text_file")
  clean="$(_screen_reasons "$texts" "$text_file")" || return 3
  absent="$(_absent_outcomes)" || return 3
  pending="$(_pending_count)"
  divert_count="$(printf '%s' "$rows" | jq '[.[] | select(.section == "divert")] | length')" || return 3
  [ "$divert_count" -eq 0 ] || divert_line="$(_divert_line "$divert_count")"
  printf '%s' "$rows" | jq -r --argjson clean "$clean" --argjson absent "$absent" --argjson pending "$pending" \
    --arg divert_line "$divert_line" "$_SECTIONS_JQ" || return 3
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
    check | check-all | check-outcomes | waiver-table | pr-sections) ;;
    *) _usage; return 2 ;;
  esac
  [ -n "$RUN_FOLDER" ] || { _usage; return 2; }
  [ -n "$ROOT" ] || { _usage; return 2; }
  command -v jq >/dev/null 2>&1 || { _error "jq is required and was not found on PATH"; return 3; }
  READ_DIRECTORY="$SNAPSHOT_DIRECTORY"
  [ -n "$READ_DIRECTORY" ] || READ_DIRECTORY="$(_default_snapshot_directory)"
  case "$subcommand" in
    check) _command_check ;;
    check-all) _command_check_all ;;
    check-outcomes) _command_check_outcomes ;;
    waiver-table) _command_waiver_table ;;
    pr-sections) _command_pr_sections ;;
  esac
}

main "$@"
exit $?
