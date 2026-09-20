#!/usr/bin/env bash
#
# The /gaia-debt stale-claim verdict: prints the number of every open
# `tech-debt` issue whose `in-progress` claim is stale, one per line, and
# nothing else. It never strips a label; the caller does that for each number
# printed (.claude/skills/gaia/references/debt.md, "Reconcile stale claims").
#
# A claim is LIVE when any one of these holds, and stale only when none does:
#   branch  some local or remote-tracking branch names the issue as a debt
#           member, read through .gaia/scripts/branch-name-lib.sh, so the
#           worktree spelling (`worktree-debt+<n>-<slug>`) counts exactly as
#           `debt/<n>-<slug>` does, and every member of a batch branch counts
#   pr      an open pull request's head branch names it the same way, or its
#           body carries a GitHub closing keyword against it (the
#           close/fix/resolve family, any case, naming `#<n>`,
#           `owner/repo#<n>`, or an issue URL). A cross-repository reference
#           counts too: it can only keep a claim, never strip one, so reading
#           it as live is the safe direction. The head-branch arm
#           covers a drain on another machine that has pushed but not yet
#           written its closing line.
#   fresh   the issue was updated within the grace window, default 1800
#           seconds. This protects a claim set before its branch exists. The
#           age is computed here, from epoch seconds on both sides, rather
#           than judged by reading a timestamp: a Z-normalized `updatedAt`
#           read against a local-time sense of "now" mistakes a minute-old
#           claim for one from yesterday.
#
# FAIL-CLOSED on every input: stripping a live claim hands one issue to two
# sessions, while leaving a stale claim costs one reconcile cycle. So if the
# claims query, the pull-request query, the ref store, the branch library, jq,
# or the clock cannot be read, this prints nothing on stdout, names what failed
# on stderr, and exits 3. The caller strips nothing on a non-zero exit.
#
# Usage:
#   bash .gaia/scripts/debt-stale-claims.sh [--dir <repo>] [--grace <seconds>]
#
# Test seams (each replaces one live read; the suite drives every arm with
# them): --claims-json <file> (the `gh issue list` array of
# {number, updatedAt}), --prs-json <file> (the `gh pr list` array of
# {headRefName, body}), --branches <file> (branch names, one per line), and
# --now <epoch-seconds>.
#
# Exit: 0 verdict printed (possibly empty), 2 usage error, 3 an input could
# not be read.

set -uo pipefail

dir="."
grace=1800
claims_file=""
prs_file=""
branches_file=""
now=""

die_usage() {
  printf 'debt-stale-claims: %s\n' "$1" >&2
  exit 2
}
die_input() {
  printf 'debt-stale-claims: %s; no claim is judged stale\n' "$1" >&2
  exit 3
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir | --grace | --claims-json | --prs-json | --branches | --now)
      [ "$#" -ge 2 ] || die_usage "$1 needs a value"
      case "$1" in
        --dir) dir="$2" ;;
        --grace) grace="$2" ;;
        --claims-json) claims_file="$2" ;;
        --prs-json) prs_file="$2" ;;
        --branches) branches_file="$2" ;;
        --now) now="$2" ;;
      esac
      shift 2
      ;;
    *) die_usage "unknown argument $1" ;;
  esac
done

case "$grace" in "" | *[!0-9]*) die_usage "--grace must be whole seconds" ;; esac
case "$now" in *[!0-9]*) die_usage "--now must be epoch seconds" ;; esac

command -v jq >/dev/null 2>&1 || die_input "jq is not installed"

lib="$(dirname "${BASH_SOURCE[0]}")/branch-name-lib.sh"
[ -r "$lib" ] || die_input "branch library $lib is missing or unreadable"
# shellcheck source=/dev/null
. "$lib" || die_input "branch library $lib failed to load"

if [ -n "$claims_file" ]; then
  claims="$(cat "$claims_file")" || die_input "cannot read $claims_file"
else
  claims="$(gh issue list --label tech-debt --label in-progress --state open \
    --limit 1000 --json number,updatedAt)" \
    || die_input "gh issue list failed (auth, network, or rate limit)"
fi

# No claims at all is a complete answer, and the only one that needs no other
# input, so a peer's missing gh scope for pull requests cannot block it.
# Array-ness is asserted before length, the same way the pull-request check
# below does it: `jq length` is also defined on an object and on a string, so
# it would pass a payload that is not a list of claims at all and leave the
# failure to surface further down, under a message about one claim's fields.
printf '%s' "$claims" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die_input "the claims list is not a JSON array"
count="$(printf '%s' "$claims" | jq 'length' 2>/dev/null)" \
  || die_input "the claims list could not be counted"
[ "$count" = "0" ] && exit 0

if [ -n "$prs_file" ]; then
  prs="$(cat "$prs_file")" || die_input "cannot read $prs_file"
else
  prs="$(gh pr list --state open --limit 1000 --json headRefName,body)" \
    || die_input "gh pr list failed (auth, network, or rate limit)"
fi
printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || die_input "the pull-request list is not a JSON array"

if [ -n "$branches_file" ]; then
  branches="$(cat "$branches_file")" || die_input "cannot read $branches_file"
else
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 \
    || die_input "$dir is not a git repository, so no branch can be read"
  # gaia_branch_list returns 0 whatever the ref read does, so a ref store that
  # cannot be read reaches here as an empty branch list, which is the same
  # value a repository with no branches produces and reads as "every claim is
  # stale". The library owns the probe itself (gaia_branch_refs_readable, its
  # fail-closed companion), which names the namespace that failed; rendering
  # that namespace in this script's own vocabulary stays here, because the
  # message is this caller's contract and its suite pins it. Which of a corrupt
  # packed-refs, an unreadable ref file, or a permission denial produced the
  # failure is not distinguishable at this point.
  if ! unreadable_ns="$(gaia_branch_refs_readable "$dir")"; then
    case "$unreadable_ns" in
      refs/heads) ns_label="local refs" ;;
      refs/remotes) ns_label="remote-tracking refs" ;;
      *) ns_label="refs" ;;
    esac
    die_input "$dir $ns_label cannot be read (corrupt, unreadable, or permission-denied), so no branch can keep a claim alive"
  fi
  branches="$(gaia_branch_list "$dir")"
fi

if [ -z "$now" ]; then
  now="$(date -u +%s)" || die_input "the clock could not be read"
fi

# The two pull-request reads run here, each with its own refusal, rather than
# inside the group below: a group's exit status is its last command's, so a
# failing head-branch projection would be reported as a failing body scan and
# send the operator to repair the half that worked.
pr_heads="$(printf '%s' "$prs" | jq -r '.[].headRefName // empty')" \
  || die_input "the pull-request head branches could not be read"
pr_closed="$(printf '%s' "$prs" | jq -r '
    .[].body // ""
    | [scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?\\s+(?:[\\w.-]+/[\\w.-]+#|https?://[^\\s/]+/[^\\s/]+/[^\\s/]+/issues/|#)([0-9]+)\\b")[0]]
    | .[]')" \
  || die_input "the pull-request bodies could not be scanned"

# Every issue a branch or an open pull request keeps alive, one per line.
live="$(
  {
    printf '%s\n' "$branches"
    printf '%s\n' "$pr_heads"
  } | while IFS= read -r b; do
    [ -n "$b" ] && gaia_branch_members "$b"
  done
  printf '%s\n' "$pr_closed"
)" || die_input "the liveness set could not be assembled"

# Captured whole before printing: a jq failure partway through the claims
# would otherwise have already printed the numbers before it, and a caller
# strips every number it sees.
stale="$(printf '%s' "$claims" | jq -r \
  --arg live "$live" --argjson now "$now" --argjson grace "$grace" '
  ($live | split("\n") | map(select(. != "") | tonumber)) as $keep
  | .[]
  | select((.number as $n | $keep | index($n)) | not)
  | select(($now - (.updatedAt | fromdateiso8601)) >= $grace)
  | .number')" \
  || die_input "a claim carries an unreadable number or updatedAt"
[ -z "$stale" ] || printf '%s\n' "$stale"
exit 0
