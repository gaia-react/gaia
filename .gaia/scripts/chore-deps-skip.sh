#!/usr/bin/env bash
# Single source of truth for the chore(deps) skip predicate: does the given
# subject (a PR title or a commit subject, depending on caller) begin with
# `chore(deps):` or `chore(deps-dev):`, AND is the changed-path list on stdin
# confined to a dependency manifest (package.json, pnpm-lock.yaml,
# pnpm-workspace.yaml, matched by exact case-arm literal, no globs, so a
# nested manifest such as app/foo/package.json is not on the list)?
#
# Usage: bash .gaia/scripts/chore-deps-skip.sh <subject> <<<"$paths"
# One path per line on stdin, blank lines ignored. This predicate drains all
# of stdin on every path, including a non-matching title, so a pipefail
# caller may pipe a live writer directly in with no SIGPIPE risk. The
# prescribed form is still a here-string built from a variable first, so the
# caller can tell a failed diff apart from an empty one.
#
# Prints exactly `true` or `false` on stdout and always exits 0, including
# with no argument, an empty argument, a closed stdin, or no stdin at all, so
# a caller under `set -eu` can use this in a command substitution without
# aborting the step. Fails closed: an empty or unreadable path list is
# `false`, same as a non-matching title.
#
# Honest limit: a manifest is itself executable configuration (package.json
# `scripts`, pnpm-workspace.yaml `allowBuilds`/`overrides`), so a manifest-only
# diff under a dep-bump title still skips whatever this predicate gates.
#
# Consumers: `git grep chore-deps-skip`.
set -eu

subject="${1-}"

paths=""
if [ ! -t 0 ]; then
  # `p=` first: a closed fd 0 (`<&-`) still passes `[ ! -t 0 ]`, and a `read`
  # on a closed fd assigns nothing, so `[ -n "$p" ]` on an unset `p` would trip
  # `set -u`. `read`'s own stderr is silenced for the same closed-fd case:
  # bash writes a "Bad file descriptor" diagnostic there that a caller under
  # `set -eu` never asked for and this predicate's contract never promises.
  p=
  while IFS= read -r p 2>/dev/null || [ -n "$p" ]; do
    paths="${paths}${p}"$'\n'
  done
fi

case "$subject" in
  'chore(deps):'* | 'chore(deps-dev):'*)
    manifest_only=1
    saw_path=0
    p=
    while IFS= read -r p || [ -n "$p" ]; do
      [ -n "$p" ] || continue
      saw_path=1
      case "$p" in
        package.json | pnpm-lock.yaml | pnpm-workspace.yaml) ;;
      # gaia:maintainer-only:start
        # This maintainer checkout's own package manifests, under .gaia/cli/.
        .gaia/cli/package.json | .gaia/cli/pnpm-lock.yaml | .gaia/cli/pnpm-workspace.yaml) ;;
      # gaia:maintainer-only:end
        *) manifest_only=0 ;;
      esac
    done <<<"$paths"
    if [ "$saw_path" -eq 1 ] && [ "$manifest_only" -eq 1 ]; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    ;;
  *) printf 'false\n' ;;
esac
