#!/usr/bin/env bash
# shellcheck shell=bash
#
# hook-registration-lib.sh: the shared read of `.claude/settings.json`'s
# PreToolUse registrations, the shared oracle for whether a registered hook can
# stop a tool call, and the one spelling of a hook name inside a registration
# command. Source it; it defines functions and that literal, and runs nothing.
#
# Two gates ask the same two questions of the same surface and must not answer
# them differently: `.gaia/scripts/lint-hook-jq-availability.sh` (a blocking
# hook whose jq arm fails open) and `.gaia/scripts/lint-hook-monitor-arming.sh`
# (a blocking guard a Monitor-armed command walks past). A second copy of
# either question drifts from the first silently, because each gate's own
# suite passes against its own copy.
#
# `GAIA_HOOK_NAME_RE` has a consumer outside those gates, and it fails in a
# quieter direction than they do. `.gaia/tests/helpers/hook-registration.sh`
# feeds the literal to jq's `match` builtin to assert that a hook is registered
# at all, once per registration assertion across the bats suites. Widening the
# class to admit a path shape a gate needs also widens what every one of those
# assertions accepts: a wider class still matches, so they stay green while
# asserting less. Read that consumer before changing the literal.
#
# Bash 3.2 compatible. Never `cd`.

if [ -n "${GAIA_HOOK_REGISTRATION_LIB:-}" ]; then
  return 0
fi
GAIA_HOOK_REGISTRATION_LIB=1

# The one spelling of a hook name inside a registration command, named once.
# `readonly` is safe under the source guard above: a second source returns before
# reaching this line, so it can never re-assign a readonly name and error.
#
# The trailing group is what makes the path token TERMINATE at `.sh`, and it is
# load-bearing. The class has to be unanchored on the left, because a
# registration command wraps the path in a `"$(git rev-parse --show-toplevel
# …)"` prefix, and it has to end in `.sh`. Those two together let a longer path
# whose prefix ends in `.sh` yield a match equal to the shorter name: against
# `.claude/hooks/capture-gh-artifact.sh.bak`, the longest match ending in `.sh`
# is the real hook's own name. A settings entry pointing at a `.bak`, `.orig` or
# `.disabled` copy then reads as the hook being registered while no tool call
# ever reaches the hook. Requiring the next character to be one that cannot
# continue a path, or requiring there to be no next character, is what closes
# that.
#
# Every consumer drops that trailing group from the value they compare:
# `gaia_pretooluse_hooks` and `gaia_hook_name_from_command` below both strip
# it with the same `sed` pattern, one against a whole registration set and one
# against a single command string, and `.gaia/tests/helpers/hook-registration.sh`
# reads the first capture rather than the whole match. A consumer comparing
# the raw match instead compares a name with the quote or space that
# terminated it still attached, and matches nothing.
readonly GAIA_HOOK_NAME_RE='(\.claude/hooks/[A-Za-z0-9_./-]+\.sh)([^A-Za-z0-9_./-]|$)'

# gaia_pretooluse_hooks <repo_root>
#
# Print every hook script registered under `.hooks.PreToolUse` as its path
# relative to `.claude/hooks/`, one per line, sorted and deduplicated. Needs jq
# on PATH; the caller checks that and reports its own diagnostic.
#
# `grep -oE` prints the whole match, capture groups included, so the second
# `sed` expression drops the one character `GAIA_HOOK_NAME_RE`'s trailing group
# may have consumed. The path token always ends in `.sh`, which is what lets
# that strip be written without a second copy of the path character class: a
# match is the path plus at most one character, and a match that ended at the
# end of the command carries none.
gaia_pretooluse_hooks() {
  local root="$1"
  jq -r '
    .hooks.PreToolUse // []
    | .[]
    | .hooks[]?
    | .command // empty
  ' "$root/.claude/settings.json" 2>/dev/null |
    grep -F '.claude/hooks/' |
    grep -oE "$GAIA_HOOK_NAME_RE" |
    sed -e 's#^\.claude/hooks/##' -e 's#\(\.sh\).$#\1#' |
    sort -u
}

# gaia_hook_name_from_command <command>
#
# Print the hook's path relative to .claude/hooks/, extracted from ONE
# registration command string, or nothing if the command names no hook under
# .claude/hooks/. The single-command counterpart to gaia_pretooluse_hooks
# above: that one reads a whole registration set from settings.json and
# returns it sorted and deduplicated, which a caller judging one row at a
# time, keeping its own row index, cannot use.
gaia_hook_name_from_command() {
  local command="$1"
  printf '%s' "$command" | grep -oE "$GAIA_HOOK_NAME_RE" |
    sed -e 's#^.*\.claude/hooks/##' -e 's#\(\.sh\).$#\1#'
}

# gaia_hook_blocks <hook_script_path>
#
# Succeed when the script can stop a tool call: it emits a permissionDecision,
# or it exits 2. Full-line comments are excluded, which is load-bearing rather
# than tidy -- at least one advisory hook here carries the string `exit 2` in a
# paragraph of its header explaining a failure mode it does NOT cause, and
# grading that as a block would misfile a correctly-filed advisory hook.
#
# ONE awk PASS, not a `grep -v | grep -q` pipeline, and the reason is a fail-open
# the first consumer was caught by on its first run against the live tree.
# `grep -q` exits at its first match and closes the pipe under it; the upstream
# grep then takes SIGPIPE and returns 141, and `set -o pipefail` promotes that to
# the pipeline's status. The function returned non-zero ON A MATCH, so every hook
# whose upstream lost that race classified as advisory and the check reported
# clean over the very defect it was written for. A single process cannot lose
# that race.
#
# The `exit 2` test pads the line on both sides so the surrounding-character
# class needs no anchor alternation: with a leading and trailing space, a bare
# `exit 2` matches and `exit 22` cannot.
#
# The comment exclusion reads text rather than control flow, so an `exit 2`
# inside a heredoc or a string over-classifies. That direction is the safe one
# for both consumers: over-classifying can only red a hook a human then reads,
# while under-classifying returns a silent wrong answer about whether an action
# stops.
gaia_hook_blocks() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next
      if (index(line, "permissionDecision")) { found = 1; exit }
      probe = " " line " "
      if (probe ~ /[^A-Za-z0-9_]exit 2[^0-9]/) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}
