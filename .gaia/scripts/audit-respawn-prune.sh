#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted jq filters where $line, $ts,
# $epoch, $cutoff, $n are jq bindings, not shell variables.
# shellcheck disable=SC2016
#
# audit-respawn-prune.sh: the audit re-spawn ledger prune sweep -- the reaper
# the registry entry `audit-respawn-ledger` (.gaia/state-registry.json)
# promises via its `reaped_by` field. This script's literal name for itself
# is the string that field carries verbatim:
#
#   audit re-spawn ledger prune sweep
#
# Bounds .gaia/local/telemetry/audit-respawn.jsonl, the Code Audit Team spawn
# oracle's re-spawn breadcrumb ledger (.gaia/scripts/audit-respawn-lib.sh),
# which nothing else bounds. Two trim arms, and they are not peers:
#
#   Age arm  drops every record whose `ts` parses and is older than the
#            retention window (gaia_respawn_retention_days, floor-clamped).
#            A record that does not parse as JSON, or whose `ts` is missing
#            or unparseable, is always kept: the sweep never deletes what it
#            cannot classify.
#   Cap arm  subordinate to the age arm. It may only trim records the age arm
#            has ALREADY decided are out-of-window; it never removes a record
#            still inside the window, even when the in-window set alone
#            exceeds the cap (gaia_respawn_max_records, floor-clamped). A
#            repository whose oracle runs hot enough to exceed the cap inside
#            the window grows its ledger past the cap rather than losing the
#            measurement -- the SPEC's reopen condition needs the full
#            observation window, and a cap that dropped in-window records
#            would silently shorten it.
#
#            The cap arm engages ONLY when the ledger's total record count
#            (before this run) exceeds the cap; below that, the ledger is not
#            under size pressure at all and the age arm's own unconditional
#            drop stands untouched -- an idle repository never sees an
#            out-of-window record survive just because the cap has room. Once
#            engaged, the newest out-of-window records fill the smaller of
#            (a) the room left under the cap after every in-window record is
#            kept, and (b) how far over the cap the full pre-prune ledger
#            actually was, so the reprieve never manufactures headroom that
#            was not already being spent. Both bounds floor at zero.
#
# Every surviving line is written back byte-identical to its input (this
# script never re-serializes a record through jq); this is enforced by
# selecting survivors by original line number rather than reconstructing JSON.
#
# Concurrency: no lock. A record appended between this sweep's read and its
# atomic replace is lost. Accepted: the sweep runs once at session start, the
# ledger is a breadcrumb store whose own writer already tolerates a missing
# record (gaia_respawn_record fails open and silent), and no clearance
# decision depends on this ledger.
#
# Fail-safe and fail-silent by construction: an unresolvable root, a missing
# sibling lib, an absent or empty ledger, or a missing jq are each a silent
# no-op that leaves the ledger untouched. Exits 0 on every normal and failure
# path, so it can never block a session start, the same contract
# .claude/hooks/local-janitor.sh carries; 130 or 143 only when a SIGINT or
# SIGTERM interrupts the sweep, from the trap arms beside the mktemp below,
# which is the one case where stopping is the point. No stdout in normal
# operation; `--help` prints usage and exits 0.
#
# Usage:
#   audit-respawn-prune.sh [<root>] [--help|-h]
#
# <root> defaults to the current tree's own toplevel (git rev-parse
# --show-toplevel) when omitted -- the same call the janitor uses for its own
# .gaia/local walks. A linked worktree's .gaia/local is one wholesale symlink
# to the main checkout's (.gaia/scripts/link-worktree.sh), so this reaches
# the single shared ledger from every tree without a separate main-root
# derivation.

set -uo pipefail

for _arg in "$@"; do
  case "$_arg" in
    --help | -h)
      printf 'Usage: audit-respawn-prune.sh [<root>] [--help|-h]\n'
      printf 'Prunes .gaia/local/telemetry/audit-respawn.jsonl: drops records past\n'
      printf 'the retention window, then caps the out-of-window remainder. The cap\n'
      printf 'never trims a record still inside the window. See\n'
      printf '.gaia/scripts/audit-respawn-lib.sh for the retention knobs.\n'
      exit 0
      ;;
  esac
done

root="${1:-}"
if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
fi
[ -n "$root" ] || exit 0

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$lib_dir" ] || exit 0
lib="$lib_dir/audit-respawn-lib.sh"
[ -f "$lib" ] || exit 0
# shellcheck source=/dev/null
. "$lib" || exit 0

ledger="$(gaia_respawn_ledger_path "$root" 2>/dev/null)" || exit 0
[ -n "$ledger" ] || exit 0
[ -f "$ledger" ] || exit 0
[ -s "$ledger" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

days="$(gaia_respawn_retention_days)"
cap="$(gaia_respawn_max_records)"
now_epoch="$(date -u +%s 2>/dev/null)" || exit 0
cutoff=$((now_epoch - days * 86400))

tab="$(printf '\t')"

# One jq pass classifies every line by the AGE ARM alone, tagging each with
# its original line number so survivors can later be re-selected from the
# ledger byte-identical, never reconstructed from parsed JSON:
#   "<n>\tK"          in-window (or unparseable): always survives the age arm
#   "<n>\tD\t<epoch>" out-of-window: a cap-arm candidate, epoch for sorting
#
# awk supplies the line number, and the selection pass below re-reads the
# ledger with the same awk numbering, so exactly ONE scheme decides which
# record is which. jq's own `input_line_number` is deliberately not used: on a
# ledger whose final line carries no trailing newline it reports the same
# number for the last two lines, while awk's FNR counts them separately. The
# two schemes then disagree by one from that point on, and the age arm inverts,
# dropping a live in-window record and keeping an expired one. No writer here
# produces an unterminated ledger, but a short or interrupted append does, and
# that is exactly when the sweep must not corrupt the measurement.
classified="$(awk -v OFS="$tab" '{ print FNR, $0 }' "$ledger" \
  | jq -R -r --argjson cutoff "$cutoff" '
  . as $row
  | ($row | index("\t")) as $i
  | ($row[:$i]) as $n
  | ($row[($i + 1):]) as $line
  | ((try ($line | fromjson | .ts) catch null) // null) as $ts
  | (if $ts == null then null
     else (try ($ts | fromdateiso8601) catch null) end) as $epoch
  | if ($epoch == null or $epoch >= $cutoff) then
      $n + "\tK"
    else
      $n + "\tD\t" + ($epoch | tostring)
    end
')"
jq_status=$?
[ "$jq_status" -eq 0 ] || exit 0

inwindow_count="$(awk -F"$tab" '$2 == "K" { c++ } END { print c + 0 }' <<<"$classified")"
total_records="$(awk -F"$tab" 'END { print NR + 0 }' <<<"$classified")"

# budget = max(0, min(room left under the cap after in-window, how far over
# the cap the full pre-prune ledger was)). The second term is the gate: when
# the ledger was never over the cap to begin with (total_records <= cap),
# room_under_cap alone would be a large positive number for any ordinary
# repository (the default cap is 20000) and would wrongly resurrect
# out-of-window records the age arm already dropped. Bounding by the actual
# overage keeps the cap arm inert until the ledger is genuinely under
# pressure.
room_under_cap=$((cap - inwindow_count))
overage=$((total_records - cap))
budget=$room_under_cap
[ "$overage" -lt "$budget" ] && budget=$overage
[ "$budget" -lt 0 ] && budget=0

# Cap arm: the newest out-of-window candidates, up to $budget, chosen by
# sorting on the epoch field then trimming; their original line numbers are
# recovered afterward so the final selection can be restored to file order.
keep_out_nums=""
if [ "$budget" -gt 0 ]; then
  keep_out_nums="$(awk -F"$tab" '$2 == "D" { print $3 "\t" $1 }' <<<"$classified" \
    | sort -t "$tab" -k1,1nr \
    | head -n "$budget" \
    | cut -d "$tab" -f2)"
fi

keep_nums="$(
  {
    awk -F"$tab" '$2 == "K" { print $1 }' <<<"$classified"
    [ -n "$keep_out_nums" ] && printf '%s\n' "$keep_out_nums"
  } | sort -n -u
)"

tmp="$(mktemp "${ledger}.XXXXXX" 2>/dev/null)" || exit 0
# Nothing else reaps a stray sibling: the janitor's outlier sweep never enters
# telemetry/, and the ledger's registry entry matches an exact path. An
# interrupt between here and the mv would otherwise leave one behind for good.
#
# Three arms, not one shared arm. Bash resumes at the point of interruption once
# a trapped signal handler returns, so a single `EXIT INT TERM` arm that only
# unlinks would leave an interrupt removing the temp file and the prune running
# on to `mv` a file it no longer owns, then exiting 0 as if it had pruned. The
# signal arms exit, and the EXIT arm they fall into owns the removal.
trap 'rm -f -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_status=0
if [ -n "$keep_nums" ]; then
  awk 'NR == FNR { keep[$1] = 1; next } (FNR in keep)' \
    <(printf '%s\n' "$keep_nums") "$ledger" > "$tmp" || write_status=1
fi
if [ "$write_status" -ne 0 ]; then
  rm -f -- "$tmp"
  exit 0
fi

mv -- "$tmp" "$ledger" || { rm -f -- "$tmp"; exit 0; }

exit 0
