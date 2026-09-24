#!/usr/bin/env bash
# Shared bats primitive for asserting that a hook is registered in
# `.claude/settings.json` at all.
#
# Sourced from a suite's `setup()`, from any bats directory. The path is
# repo-root-absolute, so what varies between call sites is only how the suite
# names its own repo root:
#
#   . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
#   . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/hook-registration.sh"
#
# This is a CROSS-DIRECTORY helper, alongside `files.sh` and `path.sh`. What
# separates this directory from the per-suite-directory `.gaia/tests/lib/helpers/`
# and `.gaia/tests/hooks/helpers/` is REACH, not how a file there is invoked:
# a suite in any bats directory may source what lives here, while those two
# serve their own directory's suites, whatever invocation style a file in them
# happens to use.
#
# API:
#   hook_registered SETTINGS EVENT_FILTER HOOK_NAME
#
# WHY IT LIVES HERE rather than in `.gaia/tests/hooks/helpers/run-hook.sh`,
# where it was written. Registration is asserted from outside that directory
# too: `.gaia/tests/sandbox/spec-028-composition.bats` pins the read-side .env
# guard's registrations and sources no hooks-suite harness. While the function
# was reachable only from that harness, a suite outside it had no shared form to
# reach for, so the one thing left was a hand-written jq predicate over the
# command spelling: a change to the sanctioned registration command form reds a
# hand-written predicate while every `hook_registered` call site stays green,
# and the maintainer sent there by that red has nothing pointing at the shared
# assertion (#1911). Reachability is what this move fixes. It does not follow
# that every hand-written predicate is now gone, and nothing here should be read
# as claiming so; `git grep` for the suites that read a registration and do not
# call `hook_registered` is what answers that.
#
# The function was already dependency-light and location-independent by design
# -- it needs `GAIA_HOOK_NAME_RE` and its three arguments, and takes SETTINGS as
# an argument rather than reading the ambient `SETTINGS_ABS` every hooks suite
# resolves -- so lifting it here moves nothing it depended on.
# `run-hook.sh` sources this file and re-exports the function, so every suite
# converted onto it keeps calling it exactly as before.
#
# The directive below is the one thing this file needs that a suite does not:
# `status` is set by bats' own `run`, which is invisible to the linter here
# because this is a `.sh` held to the strictest severity floor rather than a
# `.bats` file (see .gaia/tests/shell-lint.sh). Scoped to the one code, so every
# other finding in this file still fires.
# shellcheck disable=SC2154
#
# Sourced, so it enables no shell options of its own: bats runs each `@test`
# body under `set -e` already, and a suite that wants more sets it itself.

# `GAIA_HOOK_NAME_RE`, which the assertion below matches with, comes from the
# gates' own library rather than a copy here: it is the one spelling of a hook
# name inside a registration command, and a copy of it would drift from the
# original silently, because each holder keeps passing against the copy it
# reads. Rooted at this file's own on-disk location, so it resolves however a
# suite is invoked.
#
# The literal's first capture is the path token and its second is the character
# that terminated it, so the assertion below compares `.captures[0]` rather than
# the whole match. Comparing the whole match would compare a name with the quote
# or space that terminated it still attached; the library's own header carries
# why the terminator is in the literal at all.
# shellcheck source=../../scripts/hook-registration-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/hook-registration-lib.sh"

# --- registration: is the hook wired into settings.json at all? ------------
# Separate from the verdict mechanisms in
# `.gaia/tests/hooks/helpers/run-hook.sh`: those drive a hook and read its
# verdict, this one reads the file that decides whether the hook is reached.
#
# It answers REGISTRATION and nothing else, deliberately. Whether a registration
# names its script in a form that resolves independently of the shell's working
# directory is a different question, and it already has an owner:
# .gaia/scripts/check-hook-command-rooting.sh tests it as a property over every
# registered command, and .claude/rules/maintainers/hook-registration.md
# states the sanctioned form in prose. A suite that pinned the spelling here
# instead would hold a second, weaker copy of that claim, one that goes green
# against itself while the form it encodes moves, which is exactly what
# having the form named once prevents.
#
# hook_registered SETTINGS EVENT_FILTER HOOK_NAME
# Asserts that the entries EVENT_FILTER selects in the settings file SETTINGS
# carry a command that runs HOOK_NAME. EVENT_FILTER is a jq expression,
# `.hooks.PreToolUse[] | select(.matcher == "Bash")` for a matcher-scoped event
# or `.hooks.PostCompact[]` for one registered without a matcher; HOOK_NAME is
# the bare script name. Fails when the event key is absent, when the filter
# selects nothing, and when nothing it selects runs the hook, so an assertion
# cannot pass over an empty set.
#
# SETTINGS is an argument rather than the `SETTINGS_ABS` every hooks suite
# already resolves, because a suite whose only remaining read of that variable
# happened inside this function would assign it and never mention it again,
# which is an unused-variable warning at the `.bats` severity floor. That choice
# is also what makes the function callable from a suite that resolves no such
# variable at all, which is how it reaches this directory.
hook_registered() {
  local settings="$1" filter="$2" hook="$3"
  run jq -e --arg re "$GAIA_HOOK_NAME_RE" --arg hook "$hook" \
    "[ $filter | .hooks[] | .command // empty ] |
       any([match(\$re; \"g\").captures[0].string] | any(. == \".claude/hooks/\" + \$hook))" \
    "$settings"
  [ "$status" -eq 0 ]
}
