#!/usr/bin/env bash
#
# The /gaia-debt named-batch budget: scores a set of operator-named tech-debt
# issues from the ordered backlog and prints one JSON document with each
# member's cost, the set's total against the budget, a verdict, and, when the
# set is over budget, the best within-budget subsets to offer instead. Called
# by the named-set section of .claude/skills/gaia/references/debt.md.
#
# The budget is deterministic and costs no model tokens: it is computed from
# labels and the dedup-key path alone, never from judgment.
#
# COST of a member:
#   base       difficulty easy, medium, or hard. Ungraded (null) and any
#              unknown grade cost the same as medium.
#   surcharge  footprint narrow adds nothing. Wide, null, and any unknown
#              footprint add DEBT_BUDGET_WIDE_SURCHARGE, unless waived. A spec
#              footprint is a caller bug (spec-class issues never reach the
#              scorer) and is refused.
#   waiver     the surcharge is waived when the member's directory (its
#              key.path minus the last segment, `src/a/x.ts` -> `src/a`) is
#              not the repository root `.` and at least one other member of the
#              set being scored has the identical directory, whatever that
#              member's footprint. A path with no `/` has directory `.`, and
#              the root never earns a waiver. A member with no key, or no
#              usable path, has no directory and neither earns nor gives one.
#              Only the dedup-key path is read; an issue body never earns
#              overlap credit.
# The set FITS when the total is at most DEBT_BUDGET_LIMIT.
#
# SUBSET OFFER (only when over): every non-empty subset of the named members
# that fits when scored on its own (waivers counted among that subset only) and
# is maximal (adding any one other named member makes it over). Ranked by
# member count descending, then the highest severity present descending, then
# backlog positions (each subset's positions ascending, compared
# lexicographically, lower first). The first DEBT_BUDGET_OFFER_LIMIT are kept;
# the first is marked recommended.
#
# MONOTONICITY, which the enumeration's pruning relies on: adding a member
# never lowers the total, because the most an added member can save is one
# other member's surcharge and it costs at least the easy base, and the easy
# base is at least the surcharge. So fitting is downward-closed, a subset is
# only extended while it still fits, and every single member fits on its own
# (the largest single cost is hard plus the surcharge). The script checks the
# easy-base-versus-surcharge relation at startup and refuses to run if a later
# tuning breaks it, because the pruning is only correct while it holds.
#
# DATA, NOT COMMAND TEXT: a dedup-key path comes from an editable issue body
# and its extraction pattern admits `$(...)` and backticks. So the backlog
# arrives as JSON (on stdin, or from --backlog), argv carries only validated
# issue numbers, and every path is handled by jq alone, never placed in a shell
# string.
#
# The backlog is the array the ordering query in the playbook emits, in its
# emitted order; a member's backlog position is its 0-based index. Fields read
# per named member: number, sev, difficulty, footprint, key.path. Everything
# else, body included, is ignored.
#
# Usage:
#   bash .gaia/scripts/debt-batch-budget.sh [--backlog <file>] <issue-number>...
#
# --backlog reads the backlog JSON from a file instead of stdin. Each issue
# number is a positive integer without leading zeros; at least one is required
# and none may repeat.
#
# Output: {members, total, budget, verdict, subsets} on stdout. members and
# each subset's members are in backlog order, not argv order. subsets is []
# when the set fits.
#
# Exit:
#   0  the set fits
#   1  the set is over budget (the full document is still printed)
#   2  usage or malformed input: a bad, duplicate, or missing issue number, an
#      unknown option, --backlog without a value, backlog JSON that is not an
#      array, a named number absent from it, a named member without a numeric
#      sev, a spec footprint, or the startup relation above broken. stdout
#      empty, one `debt-batch-budget: <reason>` line on stderr.
#   3  input unreadable: jq is not installed (the message names jq), the
#      --backlog file cannot be read, or the backlog is empty or not JSON.
#      stdout empty, one line on stderr. Fail-closed, the posture
#      debt-stale-claims.sh takes.
#
# bash 3.2 safe; jq 1.6-compatible builtins only.

set -uo pipefail

DEBT_BUDGET_COST_EASY=2
DEBT_BUDGET_COST_MEDIUM=3 # also the cost of an ungraded issue
DEBT_BUDGET_COST_HARD=7
DEBT_BUDGET_WIDE_SURCHARGE=2
DEBT_BUDGET_LIMIT=12
DEBT_BUDGET_OFFER_LIMIT=3

die_usage() {
  printf 'debt-batch-budget: %s\n' "$1" >&2
  exit 2
}
die_input() {
  printf 'debt-batch-budget: %s\n' "$1" >&2
  exit 3
}

[ "$DEBT_BUDGET_COST_EASY" -ge "$DEBT_BUDGET_WIDE_SURCHARGE" ] \
  || die_usage "the easy base cost must be at least the wide surcharge; the subset pruning is only correct while it is"

backlog_file=""
numbers=" " # the named issue numbers, space-delimited
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backlog)
      [ "$#" -ge 2 ] || die_usage "--backlog needs a value"
      backlog_file="$2"
      shift 2
      ;;
    -*) die_usage "unknown option $1" ;;
    *)
      case "$1" in
        "" | 0* | *[!0-9]*) die_usage "issue numbers must be positive integers without leading zeros: $1" ;;
      esac
      case "$numbers" in *" $1 "*) die_usage "issue number $1 is named twice" ;; esac
      numbers="$numbers$1 "
      shift
      ;;
  esac
done
[ "$numbers" != " " ] || die_usage "name at least one issue number"

command -v jq >/dev/null 2>&1 || die_input "jq is not installed; a named batch cannot be scored without it"

if [ -n "$backlog_file" ]; then
  backlog="$(cat -- "$backlog_file" 2>/dev/null)" || die_input "cannot read $backlog_file"
else
  backlog="$(cat)" || die_input "cannot read the backlog from stdin"
fi
case "$backlog" in *[![:space:]]*) ;; *) die_input "the backlog is empty" ;; esac
printf '%s' "$backlog" | jq -e . >/dev/null 2>&1 || die_input "the backlog is not valid JSON"

named_json="[${numbers# }"
named_json="${named_json% }]"
named_json="${named_json// /,}"

# The jq program is single-quoted on purpose: $names inside it are jq variables.
# shellcheck disable=SC2016
program='
def directory_of:
  if (.key | type) == "object" and (.key.path | type) == "string" and (.key.path | length) > 0
  then (.key.path | split("/")) as $segments
    | if ($segments | length) < 2 then "." else ($segments[:-1] | join("/")) end
  else null end;

def real_directory: . != null and . != ".";

def shared_of($chosen):
  reduce ($chosen[] | select(.directory | real_directory) | .directory) as $d ({}; .[$d] += 1);

def surcharge_of($member; $shared):
  if $member.due
  then (if ($member.directory | real_directory) and $shared[$member.directory] > 1
        then 0 else $surcharge end)
  else 0 end;

if length != 1 or (.[0] | type) != "array" then
  {error: "the backlog is not a single JSON array"}
else
  .[0] as $backlog
  | ($named | map(. as $wanted
      | [$backlog | to_entries[]
          | select((.value | type) == "object" and .value.number == $wanted)]
      | first // null)) as $found
  | ($found | map(. == null) | index(true)) as $missing
  | if $missing != null then
      {error: "issue \($named[$missing]) is not in the backlog"}
    else
      ($found | sort_by(.key)) as $entries
      | ($entries | map(select((.value.sev | type) != "number")) | first // null) as $unscored
      | ($entries | map(select(.value.footprint == "spec")) | first // null) as $spec
      | if $unscored != null then
          {error: "issue \($unscored.value.number) has no numeric sev"}
        elif $spec != null then
          {error: "issue \($spec.value.number) has a spec footprint; spec-class issues are not scored"}
        else
          ($entries | map(.value as $issue | {
              number: $issue.number,
              position: .key,
              sev: $issue.sev,
              difficulty: $issue.difficulty,
              footprint: $issue.footprint,
              directory: ($issue | directory_of),
              base: (if $issue.difficulty == "easy" then $easy
                     elif $issue.difficulty == "hard" then $hard
                     else $medium end),
              due: ($issue.footprint != "narrow")
            })) as $m
          | ($m | length) as $count

          | def total($indexes):
              ($indexes | map($m[.])) as $chosen
              | shared_of($chosen) as $shared
              | reduce $chosen[] as $member (0;
                  . + $member.base + surcharge_of($member; $shared));

            # Adding a member to a running state: the total moves by its base,
            # its own surcharge, and the refund when it is the second member of
            # a directory and the first was paying. Carrying the total this way
            # keeps the enumeration linear in the subsets it visits; total()
            # stays the authority for every number that is printed.
            def extend($state; $i):
              $m[$i] as $member
              | if ($member.directory | real_directory) then
                  ($state.dirs[$member.directory] // {count: 0, pending: 0}) as $slot
                  | (if $member.due and $slot.count == 0 then $surcharge else 0 end) as $own
                  | {sum: ($state.sum + $member.base + $own - $slot.pending),
                     dirs: ($state.dirs + {($member.directory): {
                       count: ($slot.count + 1),
                       pending: (if $slot.count == 0 then $own else 0 end)}})}
                else
                  {sum: ($state.sum + $member.base + (if $member.due then $surcharge else 0 end)),
                   dirs: $state.dirs}
                end;

            def fitting($start; $state):
              (if ($state.indexes | length) > 0 then $state else empty end),
              (range($start; $count) as $i
                | extend($state; $i) as $next
                | select($next.sum <= $limit)
                | $next + {indexes: ($state.indexes + [$i]),
                           top: ([$state.top, $m[$i].sev] | max)}
                | fitting($i + 1; .));

            def is_maximal($indexes):
              all(range(0; $count) | select(. as $i | $indexes | index($i) | not);
                  total($indexes + [.]) > $limit);

          total([range(0; $count)]) as $total
          | shared_of($m) as $shared
          | {
              members: ($m | map(. as $member
                | surcharge_of($member; $shared) as $applied
                | {number: $member.number, position: $member.position, sev: $member.sev,
                   difficulty: $member.difficulty, footprint: $member.footprint,
                   directory: $member.directory, base: $member.base,
                   surcharge: $applied,
                   waived: ($member.due and $applied == 0),
                   cost: ($member.base + $applied)})),
              total: $total,
              budget: $limit,
              verdict: (if $total <= $limit then "fits" else "over" end),
              subsets: (
                if $total <= $limit then []
                else
                  [fitting(0; {indexes: [], sum: 0, dirs: {}, top: null})] as $all
                  | ($all | map(.indexes | length) | max) as $largest
                  | ($all | group_by(.indexes | length)
                          | map({key: (.[0].indexes | length | tostring), value: .})
                          | from_entries) as $by_size
                  | [limit($offer;
                      range($largest; 0; -1) as $size
                      | ($by_size[$size | tostring] // [])
                      | sort_by([-.top, .indexes])
                      | .[]
                      | select($size == $largest or is_maximal(.indexes)))]
                  | to_entries
                  | map({members: (.value.indexes | map($m[.].number)),
                         total: total(.value.indexes),
                         recommended: (.key == 0)})
                end)
            }
        end
    end
end
'

document="$(printf '%s' "$backlog" | jq -s \
  --argjson named "$named_json" \
  --argjson easy "$DEBT_BUDGET_COST_EASY" \
  --argjson medium "$DEBT_BUDGET_COST_MEDIUM" \
  --argjson hard "$DEBT_BUDGET_COST_HARD" \
  --argjson surcharge "$DEBT_BUDGET_WIDE_SURCHARGE" \
  --argjson limit "$DEBT_BUDGET_LIMIT" \
  --argjson offer "$DEBT_BUDGET_OFFER_LIMIT" \
  "$program")" || die_input "jq failed while scoring the backlog"

reason="$(printf '%s' "$document" | jq -r '.error // empty')" \
  || die_input "jq failed while reading its own result"
[ -z "$reason" ] || die_usage "$reason"

printf '%s\n' "$document"
verdict="$(printf '%s' "$document" | jq -r '.verdict')" \
  || die_input "jq failed while reading its own result"
[ "$verdict" = "fits" ]
