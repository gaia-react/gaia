#!/usr/bin/env bash
# shellcheck shell=bash
#
# pr-wait-merge.sh: wait for a pull request to reach a terminal merge state,
# and stop early on any state that means it never will. The script itself reads
# nothing from the working directory, so run it by any path that resolves; the
# spelling below assumes a shell at the checkout root:
#   bash .gaia/scripts/pr-wait-merge.sh --pr <N> [--repo <[HOST/]OWNER/REPO>]
#                                       [--attempts <N>] [--interval <seconds>]
#
# Exit codes, one per verdict, so a caller branches on the status rather than
# parsing prose. The verdict token is also printed to stdout on its own line.
#   0   MERGED        the merge landed
#   3   CONFLICTING   the base branch conflicts with the pull request
#   4   CHECK_FAILED  a REQUIRED check failed or was cancelled
#   5   TIMEOUT       the attempt bound was spent with the pull request still open
#   6   CLOSED        the pull request was closed without merging
#   2   a refusal rather than a verdict: a usage error, no gh on PATH, or a gh
#       that never answered across the whole bound (see $reads_ok below)
#   130 / 143         a SIGINT or SIGTERM interrupted the wait
#
# EXIT 2 IS A REFUSAL, NEVER A VERDICT, and the distinction is the reason the
# arm exists. Every other code above reports something read from GitHub. Exit 2
# reports that nothing was read, so a caller must not treat it as "still
# pending" and proceed to cleanup or to a second wait.
#
# WHY THIS IS A SCRIPT AND NOT A SNIPPET. It was a snippet, in
# `wiki/concepts/PR Merge Workflow.md`, and a snippet is retyped by whoever
# needs it. A retyped safety property decays the moment retyping it gets hard,
# and there is a specific, reproducible thing that makes it hard here: the
# compound `gh pr view --jq 'if .state == "MERGED" then ...'` form is refused
# outright by the worktree-isolation guard, which cannot verify that a `gh`
# call wrapped in a construct that complex stays inside the worktree. The
# caller is then one keystroke from a loop that waits only for `MERGED`.
#
# That is gaia-react/gaia#2209, and it is a recurrence rather than a
# hypothetical. On PR gaia-react/gaia#2203 the refusal landed, an ad-hoc
# `until [ "$(gh pr view 2203 --json state --jq .state)" != "OPEN" ]` was
# substituted, `origin/main` then landed a conflicting `CHANGELOG.md` entry,
# the pull request went CONFLICTING with auto-merge still queued, and the loop
# had no exit condition that could ever fire. It spun until a human noticed.
# A single `bash .gaia/scripts/pr-wait-merge.sh --pr <N>` invocation is plain
# enough for that guard to read, so the documented path stops being the one
# the guard refuses.
#
# Issue gaia-react/gaia#2144 fixed the TEXT of the polls; this file is the
# other half, making the text the only reachable way to wait.
# `.claude/hooks/block-handrolled-pr-poll.sh` is the enforcement half, and it
# names this script in its denial: a denial with no blessed alternative is
# what produces the next improvisation.
#
# THE WAITING RULES, preserved from the prose this replaces, because each one
# exists to stop the poll abandoning a merge that is about to land:
#
#   1. `mergeable` reads UNKNOWN for a short while after any push, while
#      GitHub recomputes it. UNKNOWN is still waiting, never clean and never
#      conflicting.
#   2. Only REQUIRED checks count. A failed optional check does not block a
#      queued merge, so exiting on one would abandon a live merge.
#   3. `gh pr checks` prints nothing and exits non-zero while no check has
#      registered yet. That is still waiting, not a failure.
#
# NO `gh pr merge` OF ITS OWN, deliberately. The merge and the wait are
# separate acts with separate callers: `/gaia-release` queues its merge with
# `--merge --auto` and `/gaia-debt` with `--squash`, and a caller resuming a
# wait after a conflict repair must not re-merge at all. Folding a merge in
# here would make the wait unusable for the third case and would hide which
# spelling the second ran.
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

PROG="pr-wait-merge.sh"

# Defaults match the prose this replaces: five attempts, thirty seconds apart,
# which is the ~2-3 minute bound its callers cite. A caller whose merge waits
# on a full CI run passes a longer bound, because that outlasts this one; grep
# the tree for `--attempts` to see which do rather than trusting a list here,
# since a list is what goes stale when the next caller is added.
DEFAULT_ATTEMPTS=5
DEFAULT_INTERVAL=30

usage() {
  cat <<EOF
Usage: bash .gaia/scripts/$PROG --pr <number> [--repo <[HOST/]OWNER/REPO>]
                                [--attempts <n>] [--interval <seconds>]

  --pr        the pull request number to wait on. Required.
  --repo      the repository holding it, in gh's own [HOST/]OWNER/REPO
              spelling. Defaults to whatever gh resolves from the working
              directory, which is what a wait on this checkout's own pull
              request wants.
  --attempts  how many times to read the state before giving up.
              Default $DEFAULT_ATTEMPTS.
  --interval  seconds to sleep between reads. Default $DEFAULT_INTERVAL.
              Zero is allowed, which polls without sleeping.

Prints one verdict token on stdout and exits:
  MERGED (0), CONFLICTING (3), CHECK_FAILED (4), TIMEOUT (5), CLOSED (6).
Exit 2 is a refusal rather than a verdict: a usage error, no gh, or a gh that
never answered.
EOF
}

PR=""
REPO=""
ATTEMPTS="$DEFAULT_ATTEMPTS"
INTERVAL="$DEFAULT_INTERVAL"

# A non-negative integer, and nothing else. Rejecting a bad value loudly
# matters more here than in most argument parsing: a bound that silently
# defaulted would turn a caller's deliberate 20-attempt release wait into a
# 5-attempt one, and the only symptom is a TIMEOUT on a merge that was going
# to land.
is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] || { printf '%s: --pr needs a value\n' "$PROG" >&2; exit 2; }
      PR="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { printf '%s: --repo needs a value\n' "$PROG" >&2; exit 2; }
      REPO="$2"
      shift 2
      ;;
    --attempts)
      [ "$#" -ge 2 ] || { printf '%s: --attempts needs a value\n' "$PROG" >&2; exit 2; }
      ATTEMPTS="$2"
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { printf '%s: --interval needs a value\n' "$PROG" >&2; exit 2; }
      INTERVAL="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unrecognized argument: %s\n' "$PROG" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$PR" ]; then
  printf '%s: --pr is required\n' "$PROG" >&2
  usage >&2
  exit 2
fi
if ! is_uint "$PR"; then
  printf '%s: --pr must be a pull request number, got: %s\n' "$PROG" "$PR" >&2
  exit 2
fi
if ! is_uint "$ATTEMPTS" || [ "$ATTEMPTS" -lt 1 ]; then
  printf '%s: --attempts must be a positive integer, got: %s\n' "$PROG" "$ATTEMPTS" >&2
  exit 2
fi
if ! is_uint "$INTERVAL"; then
  printf '%s: --interval must be a non-negative integer, got: %s\n' "$PROG" "$INTERVAL" >&2
  exit 2
fi
# gh's own spelling, `[HOST/]OWNER/REPO`. Validated rather than passed through
# because a value gh cannot resolve prints nothing and exits non-zero on every
# read, which lands in the no-read refusal below, where the message would blame
# auth or the pull-request number rather than the argument actually at fault.
#
# The host-qualified form is accepted because gh documents it and agents write
# it; `.claude/rules/issue-claim.md` names it as a spelling that turns up in
# practice. It is told apart from a plain three-segment path by the dot in its
# first segment, which a host has and a GitHub owner name cannot.
repo_ok() {
  case "$1" in
    /* | */) return 1 ;;
    */*/*/*) return 1 ;;
    */*/*)
      # [HOST/]OWNER/REPO: the first segment must look like a host.
      case "${1%%/*}" in
        *.*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    */*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$REPO" ] && ! repo_ok "$REPO"; then
  printf '%s: --repo must be OWNER/REPO, or HOST/OWNER/REPO, got: %s\n' "$PROG" "$REPO" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  printf '%s: gh is not on PATH, so the merge state cannot be read. This is a\n' "$PROG" >&2
  printf 'refusal, not a verdict: nothing here reports the wait succeeded or failed.\n' >&2
  exit 2
fi

trap 'exit 130' INT
trap 'exit 143' TERM

# Reads the pull request's state and mergeability as one tab-separated line,
# and returns gh's own exit status.
#
# The `// "UNKNOWN"` is what keeps rule 1 above true when GitHub answers with
# a null `mergeable` rather than the literal string, which it does on a pull
# request it has not computed yet. Only the two field reads live in the jq
# filter; the decision is made in shell below, where it is readable and where
# the bats suite can drive it.
#
# The status matters as much as the output. A `gh` that is present but cannot
# answer at all (expired auth, a rate limit, a network outage, a pull-request
# number that does not exist) prints nothing, and a blank state is otherwise
# indistinguishable from a live pending merge: the loop would spend its whole
# bound and report TIMEOUT, whose message reports the pull request as still
# open. Nothing would have established that pull request, let alone any state
# of it. `$reads_ok` below is what separates the two.
# Each filter is named once and expanded at both call sites below. The two
# explicit branches are deliberate, because `--repo` is optional and every way
# of carrying an optional argument through in bash 3.2 (an array under
# `set -u`, an unquoted expansion, `${x:+...}`) trades the duplication for a
# quoting or emptiness hazard on a command that has to be exactly right. What
# must NOT be duplicated along with the branch is the filter: two copies drift,
# and the suite asserts only that `--repo` reaches each call, never what the
# filter says, so a repair landing in one branch alone would leave a wait that
# passes `--repo` reading a different shape than one that does not.
# shellcheck disable=SC2016
VIEW_JQ='[.state, (.mergeable // "UNKNOWN")] | @tsv'
# shellcheck disable=SC2016
CHECKS_JQ='map(select(.bucket == "fail" or .bucket == "cancel")) | length'

read_state() {
  if [ -n "$REPO" ]; then
    gh pr view "$PR" --repo "$REPO" --json state,mergeable --jq "$VIEW_JQ" 2>/dev/null
  else
    gh pr view "$PR" --json state,mergeable --jq "$VIEW_JQ" 2>/dev/null
  fi
}

# 0 when a required check has failed or been cancelled, 1 otherwise.
#
# Both "not yet registered" cases resolve to 1 (keep waiting), and they are
# different cases: `gh pr checks` exits non-zero with no output before any
# check registers, and answers `0` once checks exist and none has failed.
# Neither is a failure, so neither ends the wait. A non-numeric answer is
# treated the same way for the same reason: this predicate's job is to end a
# wait on proof of failure, and anything it cannot read is not proof.
required_check_failed() {
  local failed
  if [ -n "$REPO" ]; then
    failed=$(gh pr checks "$PR" --repo "$REPO" --required --json bucket \
      --jq "$CHECKS_JQ" 2>/dev/null) || return 1
  else
    failed=$(gh pr checks "$PR" --required --json bucket \
      --jq "$CHECKS_JQ" 2>/dev/null) || return 1
  fi
  is_uint "$failed" || return 1
  [ "$failed" -gt 0 ]
}

verdict="TIMEOUT"
attempt=0
# Whether ANY read across the whole bound came back with a state. Zero is what
# separates "nothing answered" from "the merge is still pending", which are
# otherwise the same blank line. Gated on the whole bound rather than on a
# single failure, so one transient error still keeps waiting.
reads_ok=0

while [ "$attempt" -lt "$ATTEMPTS" ]; do
  attempt=$((attempt + 1))

  line=$(read_state)
  state="${line%%$'\t'*}"
  mergeable="${line#*$'\t'}"
  # An unreadable answer leaves both halves equal to the whole line (no tab to
  # split on), including the empty string. Blank them rather than letting a gh
  # error message flow into the comparisons below as if it were a state.
  if [ "$state" = "$line" ]; then
    state=""
    mergeable=""
  fi
  [ -n "$state" ] && reads_ok=$((reads_ok + 1))

  # MERGED is tested before every other arm, and that order is load-bearing.
  # GitHub can leave a stale `mergeable` on a pull request that has already
  # merged, so reading the conflict first would report a failure on a landed
  # merge and the caller would skip its cleanup.
  if [ "$state" = "MERGED" ]; then
    verdict="MERGED"
    break
  fi

  # Closed without merging. A third state that means the merge will never
  # land, and without an arm of its own it spends the whole bound and reports
  # TIMEOUT, which on a release wait is ten minutes on a pull request somebody
  # closed. The snippet this script replaces had the same gap.
  if [ "$state" = "CLOSED" ]; then
    verdict="CLOSED"
    break
  fi

  if [ "$mergeable" = "CONFLICTING" ]; then
    verdict="CONFLICTING"
    break
  fi

  # Gated on a state having been read, so an attempt that learned nothing
  # spends one `gh` call rather than two. Against a `gh` that cannot answer at
  # all the whole bound is such attempts, and the conditions that produce it,
  # a rate limit above all, are the ones where doubling the call rate makes
  # the recovery slower. No verdict changes: with no state read there is
  # nothing for this arm to resolve against anyway.
  if [ -n "$state" ] && required_check_failed; then
    verdict="CHECK_FAILED"
    break
  fi

  # Sleep between reads, never after the last one: a bound of N attempts owes
  # N-1 waits, and sleeping after the final read would add the interval to
  # every timeout for nothing.
  if [ "$attempt" -lt "$ATTEMPTS" ] && [ "$INTERVAL" -gt 0 ]; then
    sleep "$INTERVAL"
  fi
done

# A bound spent without a single readable answer is a refusal, not a verdict.
# It reaches here from a gh that is present but can never answer: expired auth,
# a rate limit, a network outage, or a pull-request number that does not exist,
# which `is_uint` accepts because it checks shape rather than existence. The
# TIMEOUT arm below would otherwise report the pull request as still open,
# having established neither that pull request nor any state of it. Print no
# verdict token at all: a caller reading stdout must not receive a word that
# looks like an answer.
if [ "$verdict" = "TIMEOUT" ] && [ "$reads_ok" -eq 0 ]; then
  printf '%s: the merge state of PR #%s could not be read on any of %s attempt(s).\n' \
    "$PROG" "$PR" "$ATTEMPTS" >&2
  printf 'This is a refusal, not a verdict: nothing here reports the merge is pending,\n' >&2
  printf 'and no local cleanup should follow it. gh is on PATH but never answered, so\n' >&2
  printf 'check gh auth status, the pull-request number, and any --repo value.\n' >&2
  exit 2
fi

printf '%s\n' "$verdict"

case "$verdict" in
  MERGED)
    exit 0
    ;;
  CLOSED)
    printf '%s: PR #%s is closed without having merged, so no wait can succeed.\n' "$PROG" "$PR" >&2
    printf 'Reopen it, or take the change forward on a new pull request.\n' >&2
    exit 6
    ;;
  CONFLICTING)
    printf '%s: the base branch conflicts with PR #%s, so the queued merge cannot land.\n' "$PROG" "$PR" >&2
    printf 'Repair it per wiki/concepts/PR Merge Workflow.md, "### Conflict found mid-wait",\n' >&2
    printf 'then run this wait again.\n' >&2
    exit 3
    ;;
  CHECK_FAILED)
    printf '%s: a required check on PR #%s failed or was cancelled, so the queued\n' "$PROG" "$PR" >&2
    printf 'merge cannot land. Inspect it with: gh pr checks %s --required\n' "$PR" >&2
    exit 4
    ;;
  *)
    printf '%s: PR #%s was still open after %s attempt(s) %s second(s) apart.\n' \
      "$PROG" "$PR" "$ATTEMPTS" "$INTERVAL" >&2
    printf 'This is not a failure, and it is not a report that a merge is pending: this\n' >&2
    printf 'script queues no merge and reads none, so both states arrive here alike. A\n' >&2
    printf 'merge queued with --auto completes when its checks pass; with none queued,\n' >&2
    printf 'nothing is merging this pull request yet and the wait alone will not change\n' >&2
    printf 'that. Do no local cleanup until gh pr view %s --json state reads MERGED.\n' "$PR" >&2
    exit 5
    ;;
esac
