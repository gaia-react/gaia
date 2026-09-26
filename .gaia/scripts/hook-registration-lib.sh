#!/usr/bin/env bash
# shellcheck shell=bash
#
# hook-registration-lib.sh: the shared read of `.claude/settings.json`'s
# PreToolUse registrations, the shared oracle for whether a registered hook can
# stop a tool call, and the one spelling of a hook name inside a registration
# command. Source it; it defines functions and that literal, and runs nothing.
#
# `.gaia/scripts/lint-hook-jq-availability.sh` asks whether a registered hook
# can stop a tool call, so its jq arm knows when a fail-open miss is a blocking
# guard rather than an advisory one. A second copy of that question drifts
# from this one silently, because the gate's own suite would pass against its
# own copy.
#
# `GAIA_HOOK_NAME_RE` has a consumer outside that gate, and it fails in a
# quieter direction than it does. `.gaia/tests/helpers/hook-registration.sh`
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
readonly GAIA_HOOK_NAME_RE='\.claude/hooks/[A-Za-z0-9_./-]+\.sh'

# gaia_pretooluse_hooks <repo_root>
#
# Print every hook script registered under `.hooks.PreToolUse` as its path
# relative to `.claude/hooks/`, one per line, sorted and deduplicated. Needs jq
# on PATH; the caller checks that and reports its own diagnostic.
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
    sed -e 's#^\.claude/hooks/##' |
    sort -u
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
