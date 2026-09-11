#!/usr/bin/env bash
# bats5.sh - Run bats under bash 5 when one is available (pre-flight guard).
#
# macOS ships bash 3.2 as /bin/bash, which is what bats-core resolves to by
# default. A bash-3.2 local `bats` run is a weaker signal than CI (ubuntu bash
# 5): a false bare `[[ ]]` can pass silently, and BSD-only commands (e.g.
# `date -v`) that fail on Linux go uncaught. This prefers a Homebrew bash 5 on
# PATH (Apple Silicon: /opt/homebrew/bin, Intel: /usr/local/bin) and warns
# loudly on stderr when the bash bats will actually use resolves to major
# version < 4, so the warning fires only where the gap is real (silent on any
# bash 5 host, macOS or Linux). See .claude/rules/bats-assertions.md.
#
# Usage:
#   source .gaia/scripts/bats5.sh   # then call `bats5` wherever a page says `bats`
#   .gaia/scripts/bats5.sh <args>   # run directly; forwards <args> to bats under the guard

bats5() {
  # The helper vars are locals so sourcing this file into a shell does not
  # leak them; PATH is exported on purpose, that export is the whole point.
  local d resolved_bash major
  for d in /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$d/bash" ]; then
      PATH="$d:$PATH"
      export PATH
      break
    fi
  done
  resolved_bash=$(command -v bash)
  # SC2016: single quotes are intentional. BASH_VERSINFO must expand inside the
  # resolved bash ("$resolved_bash" -c ...), not in this shell.
  # shellcheck disable=SC2016
  major=$("$resolved_bash" -c 'echo "${BASH_VERSINFO[0]}"')
  if [ "$major" -lt 4 ]; then
    echo "############################################################" >&2
    echo "# WARNING: bats will run under bash $major ($resolved_bash)." >&2
    echo "# This local green is a WEAKER signal than CI (ubuntu bash 5):" >&2
    echo "# a false bare [[ ]] can pass silently, and BSD-only commands" >&2
    echo "# (e.g. 'date -v') that fail on Linux won't be caught here." >&2
    echo "# brew install bash, then re-run before trusting this pass count." >&2
    echo "############################################################" >&2
  fi
  # Gate git's background auto-maintenance for the run. Left ungated, every
  # `git commit` into a fixture repository spawns a detached
  # `git maintenance run --auto` that can outlive its test and race the teardown
  # deleting that repository. maintenance.auto gates modern git and gc.auto git
  # predating the maintenance task set; the autoDetach pair (both spellings,
  # since modern git reads maintenance.autoDetach first) keeps any run that
  # starts anyway in the foreground. An environment entry reaches every git
  # subprocess regardless of cwd and outranks repo-local config; a test that
  # needs git's own resolution sets GIT_CONFIG_COUNT=0 for that one call.
  #
  # Appended after any GIT_CONFIG_* entries the environment already carries
  # rather than written over them: a dropped core.hooksPath or url.insteadOf
  # would change a suite's behavior with nothing to say so. git applies the
  # entries in order and a later one wins, so the gates hold even against an
  # ambient entry naming the same key. The subshell keeps every export out of
  # the caller's shell, which is where a sourced bats5 runs: an export there
  # would gate maintenance in every real repository that shell touches later.
  (
    n="${GIT_CONFIG_COUNT:-0}"
    for kv in gc.auto=0 maintenance.auto=false gc.autoDetach=false maintenance.autoDetach=false; do
      export "GIT_CONFIG_KEY_$n=${kv%%=*}" "GIT_CONFIG_VALUE_$n=${kv#*=}"
      n=$((n + 1))
    done
    export GIT_CONFIG_COUNT="$n"
    bats "$@"
  )
}

# When executed directly (not sourced), run the guard immediately.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  bats5 "$@"
fi
