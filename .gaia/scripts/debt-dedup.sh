#!/usr/bin/env bash
#
# The tech-debt dedup check: answers whether a finding at <path>:<line> already
# has an issue, so the caller (.claude/skills/file-tech-debt/SKILL.md) files
# only when this says no. Prints exactly one JSON line on exit 0 or 1.
#
# Usage:
#   bash .gaia/scripts/debt-dedup.sh --path <repo-relative-posix-path> --line <integer>
#
# Identity is the key comment's `path` (byte-equal) plus `line` (integer
# equal). The class is ignored: a finding reclassified between two runs is the
# same finding. The accepted cost is that two distinct findings on one
# `path:line` collapse into one issue.
#
# Tiers, first hit wins, lowest issue number within a tier:
#   1. an open issue whose key matches;
#   2. a closed issue whose key matches AND that was declined (the `wontfix`
#      label, or closed as not planned). A closed match that was resolved is
#      not a match: the finding came back, so it is filed again;
#   3. an open issue with NO parseable key whose body cites `<path>:<line>`
#      with a non-digit or the end of the body right after it. This catches
#      human-filed issues. The search is a literal substring test, never a
#      regex built from the path, and the trailing-digit guard is what keeps
#      line 4 from matching a cited line 42.
#
# Why not `gh issue list --search`: GitHub search tokenizes on `/`, `:` and
# `@`, so a path:line query cannot be made exact.
#
# stdout, one line:
#   exit 0  {"match":false}
#   exit 1  {"match":true,"number":N,"state":"OPEN"|"CLOSED","declined":bool,
#            "source":"key"|"keyless","inner_key":"v1 class=... path=... line=..."|null}
#           inner_key is the verbatim text inside the matched key comment.
# Exit 2: usage error. Exit 3: an input could not be read (gh failed, invalid
# JSON, jq missing, or a result that fills its limit and so may be truncated).
# Both print nothing on stdout and one `debt-dedup: <reason>` line on stderr.
# The caller never files on 2 or 3: filing on a check that did not run is the
# duplicate this script exists to prevent.
#
# The key capture below is byte-identical to the one in the ordering query of
# .claude/skills/gaia/references/debt.md; a suite compares the two texts.
#
# Test seams (each replaces one live read): --open-json <file> (array of
# {number, body}) and --closed-json <file> (array of
# {number, body, labels, stateReason}).

set -uo pipefail

# A result whose length equals its limit may have been cut off, and a missing
# declined issue re-files a rejected finding, so equality is a failure, never
# a pass. The closed set grows without bound, hence the larger ceiling.
open_limit=1000
closed_limit=5000

search_path=""
search_line=""
open_file=""
closed_file=""

die_usage() {
  printf 'debt-dedup: %s\n' "$1" >&2
  exit 2
}
die_input() {
  printf 'debt-dedup: %s; do not file on this result\n' "$1" >&2
  exit 3
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path | --line | --open-json | --closed-json)
      [ "$#" -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --path) search_path="$2" ;;
        --line) search_line="$2" ;;
        --open-json) open_file="$2" ;;
        --closed-json) closed_file="$2" ;;
      esac
      shift 2
      ;;
    *) die_usage "unknown argument $1" ;;
  esac
done

[ -n "$search_path" ] || die_usage "--path is required and must not be empty"
[ -n "$search_line" ] || die_usage "--line is required"
case "$search_line" in *[!0-9]*) die_usage "--line must be a whole number" ;; esac
# Base 10 explicitly: a leading zero would otherwise read as octal.
search_line=$((10#$search_line))

command -v jq >/dev/null 2>&1 || die_input "jq is not installed"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/debt-dedup.XXXXXX")" \
  || die_input "cannot create a scratch directory"
trap 'rm -rf "$work_directory"' EXIT
open_copy="$work_directory/open.json"
closed_copy="$work_directory/closed.json"

if [ -n "$open_file" ]; then
  cat "$open_file" >"$open_copy" 2>/dev/null || die_input "cannot read $open_file"
else
  gh issue list --label tech-debt --state open --limit "$open_limit" \
    --json number,body >"$open_copy" 2>/dev/null \
    || die_input "gh issue list (open) failed (auth, network, or rate limit)"
fi
if [ -n "$closed_file" ]; then
  cat "$closed_file" >"$closed_copy" 2>/dev/null || die_input "cannot read $closed_file"
else
  gh issue list --label tech-debt --state closed --limit "$closed_limit" \
    --json number,body,labels,stateReason >"$closed_copy" 2>/dev/null \
    || die_input "gh issue list (closed) failed (auth, network, or rate limit)"
fi

for list_name in open closed; do
  list_copy="$work_directory/$list_name.json"
  jq -e 'type == "array"' "$list_copy" >/dev/null 2>&1 \
    || die_input "the $list_name list is not a JSON array"
  list_length="$(jq 'length' "$list_copy")" \
    || die_input "the $list_name list could not be counted"
  if [ "$list_name" = open ]; then list_limit="$open_limit"; else list_limit="$closed_limit"; fi
  [ "$list_length" -lt "$list_limit" ] \
    || die_input "the $list_name list has $list_length issues, which fills its limit of $list_limit and may be truncated"
done

verdict="$(
  jq -n -c --arg path "$search_path" --argjson line "$search_line" \
    --slurpfile open "$open_copy" --slurpfile closed "$closed_copy" '
    def key_of:
      ([(.body // "") | capture("<!-- gaia-debt-key: v1 class=(?<class>[^ ]+) path=(?<path>[^>\n]+) line=(?<line>[0-9]+) -->")] | .[0]) // null;
    def key_matches:
      . != null and .path == $path and (.line | tonumber) == $line;
    def inner_key: "v1 class=\(.class) path=\(.path) line=\(.line)";
    def cites($needle):
      (split($needle)) as $parts
      | ($parts | length) as $count
      | any(range(1; $count);
          . as $index
          | $parts[$index] as $rest
          | if $rest != "" then ($rest[0:1] | test("[0-9]") | not)
            elif $index == $count - 1 then true
            else ($needle[0:1] | test("[0-9]") | not) end);
    def declined:
      ((.labels // []) | map(.name) | index("wontfix") != null) or .stateReason == "NOT_PLANNED";
    def result($state; $declined; $source):
      {match: true, number: .number, state: $state, declined: $declined,
       source: $source, inner_key: (if $source == "key" then (key_of | inner_key) else null end)};
    ($path + ":" + ($line | tostring)) as $needle
    | ($open[0] | map(. + {k: key_of}) | sort_by(.number)) as $open_issues
    | ($closed[0] | map(. + {k: key_of}) | sort_by(.number)) as $closed_issues
    | ([$open_issues[] | select(.k | key_matches)] | .[0]) as $tier1
    | ([$closed_issues[] | select((.k | key_matches) and declined)] | .[0]) as $tier2
    | ([$open_issues[] | select(.k == null and ((.body // "") | cites($needle)))] | .[0]) as $tier3
    | if $tier1 then $tier1 | result("OPEN"; false; "key")
      elif $tier2 then $tier2 | result("CLOSED"; true; "key")
      elif $tier3 then $tier3 | result("OPEN"; false; "keyless")
      else {match: false} end
  '
)" || die_input "the issue lists could not be compared"

printf '%s\n' "$verdict"
[ "$(jq -r '.match' <<<"$verdict")" = "true" ] && exit 1
exit 0
