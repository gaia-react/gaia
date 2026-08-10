#!/usr/bin/env bash
# Single source of truth for the chore(deps) skip predicate shared by
# tests.yml, chromatic.yml, code-review-audit.yml and
# .claude/hooks/pr-merge-audit-check.sh: does the given subject (a PR title
# or a commit subject, depending on caller) begin with `chore(deps):` or
# `chore(deps-dev):`?
#
# Usage: bash .gaia/scripts/chore-deps-skip.sh <subject>
# Prints exactly `true` or `false` on stdout and always exits 0, including
# with no argument or an empty argument, so a caller under `set -eu` can use
# this in a command substitution without aborting the step.
set -eu

subject="${1-}"

case "$subject" in
  'chore(deps):'* | 'chore(deps-dev):'*) printf 'true\n' ;;
  *) printf 'false\n' ;;
esac
