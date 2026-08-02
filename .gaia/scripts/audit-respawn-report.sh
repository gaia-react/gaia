#!/usr/bin/env bash
# audit-respawn-report.sh: the Code Audit Team re-spawn attribution query.
#
# .gaia/scripts/resolve-audit-spawn.sh appends one breadcrumb per considered
# member to .gaia/local/telemetry/audit-respawn.jsonl every time its digest-
# marker-presence filter runs: the member, its content digest, whether it was
# cleared, the branch, HEAD, and the merge-base of HEAD and origin/main. It
# records what it saw and classifies nothing.
#
# This script is the judgement, as a query over the accumulated records: over
# a caller-given time window, how many member re-spawns are attributable to a
# peer's merge landing under an already-audited branch, rather than to the
# branch's own content changing?
#
# The attribution rule. Group every record by [branch, member]; order each
# group by ts ascending. For each consecutive pair (p, c) within a group:
#   rotated         := c.digest != p.digest, and both are non-empty
#   base_moved      := c.merge_base != p.merge_base, and both are non-empty
#   lost_clearance  := p.cleared == true and c.cleared == false
# Pairs are formed over the WHOLE ledger, before any window filter; a pair is
# in window when c.ts >= since. That ordering is deliberate: filtering first
# would silently drop every transition whose earlier half fell just outside
# the window, which is exactly the transition most likely to matter at a
# window boundary.
#
# Reported counts, all over in-window pairs:
#   records                      records whose own ts >= since
#   transitions                  in-window consecutive pairs
#   peer_merge_respawns          rotated and base_moved and lost_clearance
#   own_change_respawns          rotated and (not base_moved) and lost_clearance
#   peer_merge_rotations_upper   rotated and base_moved
# peer_merge_respawns is the single quantity this instrument exists to
# produce. The other four are context that keeps it honest.
#
# Three caveats travel with the number wherever it is reported (also printed
# below in the text report):
#   1. A run that both absorbs main and lands its own edits classifies as
#      peer-merge, so within its own class the count is an upper bound.
#   2. The pairing needs an observation taken while the member was cleared, so
#      the count is a lower bound on total incidence.
#   3. Attribution is a query over recorded facts, never a judgement the
#      resolver makes; refining the rule needs no ledger migration.
#
# Usage:
#   audit-respawn-report.sh [--since <days>] [--json] [--root <path>] [--help|-h]
#     --since <days>  Window in days, default 30. Non-empty run of digits.
#     --json          Emit one JSON object instead of the text report.
#     --root <path>   Repo root override, default `git rev-parse --show-toplevel`.
#     --help | -h     Usage, exit 0.
#
# Exit codes. Unlike the oracle and the retention sweep, this is a human-
# facing query tool, so it reports its inability to answer rather than
# swallowing it:
#   0  a report was produced. Includes the absent-ledger case (all counts
#      zero), which is a real answer, not an error.
#   1  the question cannot be answered: jq missing, an unresolvable root, an
#      unparseable --since, or an unknown flag. Diagnostic on stderr, nothing
#      on stdout.
#
# A malformed (non-JSON) ledger line is skipped, not fatal: a lost record is
# not a reason to refuse the whole report.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. Never `date -v` (BSD-only) or `date -d` (GNU-only); epoch
# arithmetic is shell `date -u +%s` plus jq's `todateiso8601` /
# `fromdateiso8601` on both platforms.
#
# gaia:maintainer-only:start
# Sibling bats suite: .gaia/scripts/tests/audit-respawn-report.bats.
# gaia:maintainer-only:end

set -uo pipefail

print_usage() {
  cat <<'USAGE'
Usage: audit-respawn-report.sh [--since <days>] [--json] [--root <path>] [--help|-h]
  Reports how many Code Audit Team re-spawns, over the last <days> (default
  30), are attributable to a peer's merge landing under an already-audited
  branch versus the branch's own content changing. Reads
  .gaia/local/telemetry/audit-respawn.jsonl. Exit 0 on a produced report
  (including the absent-ledger, all-zero case); exit 1 when the question
  cannot be answered (jq missing, an unresolvable root, an unparseable
  --since, or an unknown flag).
USAGE
}

SINCE_DAYS="30"
JSON_OUT=0
ROOT_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --since)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "audit-respawn-report: --since requires a <days> argument" >&2
        exit 1
      fi
      SINCE_DAYS="$2"
      shift 2
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "audit-respawn-report: --root requires a <path> argument" >&2
        exit 1
      fi
      ROOT_OVERRIDE="$2"
      shift 2
      ;;
    --help | -h)
      print_usage
      exit 0
      ;;
    *)
      echo "audit-respawn-report: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

case "$SINCE_DAYS" in
  '' | *[!0-9]*)
    echo "audit-respawn-report: --since must be a non-empty run of digits, got '$SINCE_DAYS'" >&2
    exit 1
    ;;
esac
# Base-10 forced: strips a leading zero and guards bash arithmetic below from
# ever reading a digit run as octal.
SINCE_DAYS_NUM=$((10#$SINCE_DAYS))

if ! command -v jq >/dev/null 2>&1; then
  echo "audit-respawn-report: jq is required" >&2
  exit 1
fi

if [ -n "$ROOT_OVERRIDE" ]; then
  repo_root="$ROOT_OVERRIDE"
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$repo_root" ]; then
  echo "audit-respawn-report: could not resolve a repo root (pass --root)" >&2
  exit 1
fi

_lib="$(dirname "${BASH_SOURCE[0]}")/audit-respawn-lib.sh"
if [ ! -f "$_lib" ]; then
  echo "audit-respawn-report: cannot find audit-respawn-lib.sh beside this script" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_lib"

ledger="$(gaia_respawn_ledger_path "$repo_root" 2>/dev/null)" || ledger=""
if [ -z "$ledger" ]; then
  echo "audit-respawn-report: could not resolve the ledger path" >&2
  exit 1
fi

cutoff=$(($(date -u +%s) - SINCE_DAYS_NUM * 86400))
since="$(jq -rn --argjson e "$cutoff" '$e | todateiso8601' 2>/dev/null)" || since=""
if [ -z "$since" ]; then
  echo "audit-respawn-report: could not compute the window start" >&2
  exit 1
fi

content=""
[ -f "$ledger" ] && content="$(cat "$ledger" 2>/dev/null || true)"

# The jq program. Reads the raw ledger text as one string (-R -s), splits on
# newline, drops blank lines, and parses each survivor with `fromjson? //
# empty` so one malformed line is skipped rather than aborting the report.
#
# Pairing happens over the WHOLE parsed set, grouped by [branch, member] and
# sorted by ts within each group, before the window filter is applied to the
# pair's LATER record only -- see the header comment above for why that
# order matters. `records` is independently the count of records whose own
# ts falls in window.
#
# ts -> epoch is fromdateiso8601, wrapped in try/catch: an unparseable ts
# sorts and pairs on its raw string but never counts as in-window, for either
# `records` or a pair. sort_by(.ts) on the writer's fixed-width ISO-8601 UTC
# string is a correct chronological sort.
# shellcheck disable=SC2016 # single-quoted on purpose: these are jq $-vars, fed via --argjson/--arg, never bash-interpolated.
JQ_PROGRAM='
def epoch_of: try (.ts | fromdateiso8601) catch null;
def in_window($e): ($e != null) and ($e >= $cutoff);

[ split("\n")[] | select(length > 0) | (fromjson? // empty) ] as $recs
| ( $recs | map(select(in_window(epoch_of))) | length ) as $records
| ( $recs
    | group_by([(.branch // ""), (.member // "")])
    | map(
        sort_by(.ts)
        | . as $g
        | [ range(1; ($g | length)) | { p: $g[. - 1], c: $g[.] } ]
      )
    | add // []
  ) as $pairs
| ( $pairs | map(select(in_window(.c | epoch_of))) ) as $inwin
| ( $inwin
    | map(
        (((.p.digest // "") != "") and ((.c.digest // "") != "") and ((.p.digest) != (.c.digest))) as $rotated
        | (((.p.merge_base // "") != "") and ((.c.merge_base // "") != "") and ((.p.merge_base) != (.c.merge_base))) as $base_moved
        | (((.p.cleared // false) == true) and ((.c.cleared // false) == false)) as $lost_clearance
        | { rotated: $rotated, base_moved: $base_moved, lost_clearance: $lost_clearance }
      )
  ) as $flags
| {
    schema: 1,
    window_days: $window_days,
    since: $since,
    ledger: $ledger,
    records: $records,
    transitions: ($inwin | length),
    peer_merge_respawns: ($flags | map(select(.rotated and .base_moved and .lost_clearance)) | length),
    own_change_respawns: ($flags | map(select(.rotated and (.base_moved | not) and .lost_clearance)) | length),
    peer_merge_rotations_upper: ($flags | map(select(.rotated and .base_moved)) | length)
  }
'

report_json="$(printf '%s' "$content" | jq -R -s -c \
  --argjson cutoff "$cutoff" \
  --argjson window_days "$SINCE_DAYS_NUM" \
  --arg since "$since" \
  --arg ledger "$ledger" \
  "$JQ_PROGRAM" 2>/dev/null)" || report_json=""

if [ -z "$report_json" ] || ! jq -e 'type == "object" and has("peer_merge_respawns")' >/dev/null 2>&1 <<<"$report_json"; then
  echo "audit-respawn-report: could not build the report" >&2
  exit 1
fi

if [ "$JSON_OUT" -eq 1 ]; then
  printf '%s\n' "$report_json"
  exit 0
fi

records="$(jq -r '.records' <<<"$report_json")"
transitions="$(jq -r '.transitions' <<<"$report_json")"
peer_merge="$(jq -r '.peer_merge_respawns' <<<"$report_json")"
own_change="$(jq -r '.own_change_respawns' <<<"$report_json")"
rotations_upper="$(jq -r '.peer_merge_rotations_upper' <<<"$report_json")"

printf 'audit re-spawn attribution\n'
printf 'window:                        last %s days (since %s)\n' "$SINCE_DAYS_NUM" "$since"
printf 'ledger:                        %s\n' "$ledger"
printf '\n'
printf 'records in window:             %s\n' "$records"
printf 'observed transitions:          %s\n' "$transitions"
printf 'peer-merge re-spawns:          %s   <- the reopen-condition quantity\n' "$peer_merge"
printf 'own-change re-spawns:          %s\n' "$own_change"
printf 'peer-merge rotations (upper):  %s\n' "$rotations_upper"
printf '\n'
printf 'Caveats:\n'
printf '  - a run that both absorbs main and lands its own edits counts as peer-merge,\n'
printf '    so within its class this is an upper bound\n'
printf '  - the pairing needs an observation taken while the member was cleared, so it\n'
printf '    is a lower bound on total incidence\n'
printf '  - attribution is a query over recorded facts, not a judgement the resolver\n'
printf '    makes\n'

exit 0
