#!/usr/bin/env bash
#
# The /gaia-debt staleness probe: reports, for every issue in the ordered
# backlog, whether its dedup-key path is still tracked. Called by the
# staleness-probe section of .claude/skills/gaia/references/debt.md, which
# annotates a gone path and never acts on it.
#
# DATA, NOT COMMAND TEXT: a dedup-key path comes from an editable issue body
# and its extraction pattern admits `$(...)`, backticks, and quotes. So the
# backlog arrives as JSON on stdin, the script takes no arguments, and every
# path is compared by jq against the `git ls-files -z` listing as a string,
# never placed in a shell string or handed to git as a pathspec.
#
# INDEX, EXACT MATCH: a path is tracked only when it equals an index entry
# byte for byte. An untracked file on disk at the path is gone (a build
# artifact is not a live source file), and so is a directory, a glob, or a
# pathspec-magic spelling, since a dedup key names one file.
#
# The repository is the one containing the working directory, read from its
# top level, so a run from a subdirectory sees the whole index. The playbook
# runs it from the repository root.
#
# Usage:
#   <the ordering command> | bash .gaia/scripts/debt-path-probe.sh
#
# The backlog is the array the ordering query in the playbook emits. Fields
# read per issue: number, key.path. Everything else, body included, is
# ignored.
#
# Output: one JSON array on stdout, one {number, path, status} per issue in
# backlog order. status is `tracked`, `gone`, or `keyless` (a null key, or a
# key without a non-empty string path); path is null when keyless.
#
# Exit:
#   0  the report is printed
#   2  usage or malformed input: any argument, a backlog that is not an
#      array, or an issue without a numeric number. stdout empty, one
#      `debt-path-probe: <reason>` line on stderr.
#   3  input unreadable: jq is not installed (the message names jq), stdin is
#      empty or not JSON, the working directory is not inside a git
#      repository, or the index cannot be listed. stdout empty, one line on
#      stderr. Fail-closed: no report rather than a report of every path
#      gone.
#
# bash 3.2 safe; jq 1.6-compatible builtins only.

set -uo pipefail

die_usage() {
  printf 'debt-path-probe: %s\n' "$1" >&2
  exit 2
}
die_input() {
  printf 'debt-path-probe: %s\n' "$1" >&2
  exit 3
}

[ "$#" -eq 0 ] || die_usage "takes no arguments; pipe the backlog JSON on stdin"

command -v jq >/dev/null 2>&1 || die_input "jq is not installed; the staleness probe cannot run without it"

backlog="$(cat)" || die_input "cannot read the backlog from stdin"
case "$backlog" in *[![:space:]]*) ;; *) die_input "the backlog is empty" ;; esac
printf '%s' "$backlog" | jq -e . >/dev/null 2>&1 || die_input "the backlog is not valid JSON"
printf '%s' "$backlog" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die_usage "the backlog is not a JSON array"
printf '%s' "$backlog" | jq -e 'all(.[]; (.number | type) == "number")' >/dev/null 2>&1 \
  || die_usage "every backlog issue needs a numeric number"

top_level="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top_level" ] \
  || die_input "the working directory is not inside a git repository"

index_listing="$(mktemp)" || die_input "cannot create a temporary file"
trap 'rm -f "$index_listing"' EXIT
git -C "$top_level" ls-files -z >"$index_listing" 2>/dev/null \
  || die_input "cannot list the git index"

printf '%s' "$backlog" | jq -c --rawfile index "$index_listing" '
  (reduce ($index | split("\u0000")[] | select(length > 0)) as $entry ({}; .[$entry] = true)) as $tracked
  | map(
      if (.key | type) == "object" and (.key.path | type) == "string" and (.key.path | length) > 0
      then .key.path as $path
        | {number, path: $path,
           status: (if ($tracked | has($path)) then "tracked" else "gone" end)}
      else {number, path: null, status: "keyless"}
      end
    )
' || die_input "jq could not build the report"
