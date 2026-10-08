#!/usr/bin/env bash
#
# The /gaia-debt backlog pass: takes the ordered backlog, sets aside the issues
# that must not be picked up, and groups the rest into related-fix clusters.
# Called by .claude/skills/gaia/references/debt.md, which owns the ordering
# query and reads this script's report instead of clustering by hand.
#
# Usage:
#   <the ordering command> | bash .gaia/scripts/debt-backlog.sh
#   bash .gaia/scripts/debt-backlog.sh --backlog <file>
#
# The backlog is the array the ordering query emits, already in backlog order.
# Fields read per issue: number, labels (name strings), key ({class, path, line}
# or null), body, footprint. DATA, NOT COMMAND TEXT: a key and a body come from
# an editable issue body, so everything is compared by jq as strings and never
# placed in a shell string.
#
# Exclusions, first match wins, each issue in exactly one bucket and never in a
# cluster:
#   in_progress   label `in-progress`
#   spec_parked   label `debt:spec-pending` or `debt:spec-active`
#   investigate   label `severity:investigate`
# Exclusion runs before clustering so an excluded issue cannot drag a sibling
# that shares its path into a batch.
#
# Cluster path: key.path. A keyless issue falls back to the first token in its
# body shaped `<path>:<digits>` not followed by another digit, where <path> is a
# run of characters other than whitespace, backtick, colon, quotes and
# parentheses that contains a `/` or a `.`. No such token: the issue stands
# alone. Example body token: .claude/hooks/x.sh:12
#
# Pair relation, candidates only: the same path (byte-equal); or the same
# key.class and the same directory (text before the last `/`, `.` when there is
# none). The sentinel class `holistic/unclassified` never satisfies the class
# rule: it is what an unclassified filing falls back to, so two issues sharing
# it share no root-cause signal. A shared directory alone is too weak to join
# anything. A keyless issue has no class. A cluster is a connected component of
# that relation with two or more members.
#
# Output, one JSON object on stdout:
#   {"candidates":[N...],
#    "excluded":{"in_progress":[...],"spec_parked":[...],"investigate":[...]},
#    "clusters":[{"members":[N...],"paths":[...],"signal":"path"|"class-dir"|"mixed"}],
#    "spec_class":[N...]}
# Number lists are in backlog order; clusters are ordered by first member.
# signal is `path` when every member shares one path, `class-dir` when no pair
# shares a path, else `mixed`. spec_class lists candidates whose footprint is
# `spec`; a spec issue still clusters, the offer withholds it, not this pass.
#
# Exit:
#   0  the report is printed
#   2  usage or unreadable input: an unknown flag, --backlog without a value or
#      naming a missing file, jq not installed (the message names jq), input
#      that is empty, not JSON, not an array, or holding an issue without a
#      numeric number. stdout empty, one `debt-backlog: <reason>` line on
#      stderr. The caller treats any non-zero exit as a stop before claiming.
#
# bash 3.2 safe; jq 1.6-compatible builtins only.

set -uo pipefail

die() {
  printf 'debt-backlog: %s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || die "jq is not installed; the backlog pass cannot run without it"

backlog_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --backlog)
      [ "$#" -ge 2 ] || die "--backlog needs a file"
      backlog_file="$2"
      shift 2
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [ -n "$backlog_file" ]; then
  [ -f "$backlog_file" ] || die "cannot read the backlog file: $backlog_file"
  backlog="$(cat "$backlog_file")" || die "cannot read the backlog file: $backlog_file"
else
  backlog="$(cat)" || die "cannot read the backlog from stdin"
fi

case "$backlog" in *[![:space:]]*) ;; *) die "the backlog is empty" ;; esac
printf '%s' "$backlog" | jq -e . >/dev/null 2>&1 || die "the backlog is not valid JSON"
printf '%s' "$backlog" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die "the backlog is not a JSON array"
printf '%s' "$backlog" | jq -e 'all(.[]; type == "object" and (.number | type) == "number")' >/dev/null 2>&1 \
  || die "every backlog issue needs a numeric number"

printf '%s' "$backlog" | jq -c '
  def label_names: (.labels // []) | map(if type == "object" then .name else . end);
  def bucket:
    label_names as $names
    | if ($names | index("in-progress")) != null then "in_progress"
      elif ($names | index("debt:spec-pending")) != null or ($names | index("debt:spec-active")) != null then "spec_parked"
      elif ($names | index("severity:investigate")) != null then "investigate"
      else "candidate" end;
  def body_path:
    [ (.body // "") | match("([^\\s`:\u0027\"()]+):[0-9]+(?![0-9])"; "g") | .captures[0].string
      | select(contains("/") or contains(".")) ][0];
  def cluster_path:
    if (.key | type) == "object" and (.key.path | type) == "string" and (.key.path | length) > 0
    then .key.path else body_path end;
  def directory: if contains("/") then sub("/[^/]*$"; "") else "." end;
  def seeded_class:
    if (.key | type) == "object" and (.key.path | type) == "string" and (.key.path | length) > 0
       and (.key.class | type) == "string" and (.key.class | length) > 0
       and .key.class != "holistic/unclassified"
    then .key.class else null end;

  map(. + {bucket: bucket}) as $all
  | ($all | map(select(.bucket == "candidate"))) as $candidates
  | ($candidates | map(
      cluster_path as $path
      | seeded_class as $class
      | {number, footprint, path: $path,
         tokens: ( (if $path != null then ["p\u0000" + $path] else [] end)
                 + (if $path != null and $class != null
                    then ["c\u0000" + $class + "\u0000" + ($path | directory)] else [] end) )}
    )) as $nodes
  | ($nodes | length) as $count
  # Connected components by label propagation over shared tokens: every node
  # starts as its own position and takes the smallest label among the nodes
  # sharing a token, until nothing changes. Labels only fall, so it ends.
  | def step($labels):
      (reduce range(0; $count) as $position ({};
         reduce $nodes[$position].tokens[] as $token (.;
           .[$token] = ([.[$token], $labels[$position]] | map(select(. != null)) | min)))) as $by_token
      | [range(0; $count) | . as $position
         | ([$nodes[$position].tokens[] | $by_token[.]] + [$labels[$position]]) | min];
    ([range(0; $count)] | until(step(.) == .; step(.))) as $labels
  | ([range(0; $count)] | group_by($labels[.]) | map(select(length >= 2))) as $groups
  | {
      candidates: ($candidates | map(.number)),
      excluded: {
        in_progress: ($all | map(select(.bucket == "in_progress") | .number)),
        spec_parked: ($all | map(select(.bucket == "spec_parked") | .number)),
        investigate: ($all | map(select(.bucket == "investigate") | .number))
      },
      clusters: ($groups | map(sort) | sort_by(.[0]) | map(
        . as $positions
        | ($positions | map($nodes[.])) as $members
        | ($members | map(.path) | reduce .[] as $path ([]; if index($path) == null then . + [$path] else . end)) as $paths
        | {members: ($members | map(.number)),
           paths: $paths,
           signal: (if ($paths | length) == 1 then "path"
                    elif ($paths | length) == ($members | length) then "class-dir"
                    else "mixed" end)})),
      spec_class: ($candidates | map(select(.footprint == "spec") | .number))
    }
' || die "jq could not build the report"
