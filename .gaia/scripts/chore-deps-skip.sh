#!/usr/bin/env bash
# Single source of truth for the chore(deps) skip predicate: does the given
# subject (a PR title or a commit subject, depending on caller) begin with
# `chore(deps):` or `chore(deps-dev):`, AND is the changed-path list on stdin
# confined to a dependency manifest? A manifest is the root package.json,
# pnpm-lock.yaml or pnpm-workspace.yaml (exact case-arm literals), or a path
# matching a registered package's `dependencyManifests` globs (registry and
# descriptor: `.claude/hooks/lib/gaia-packages.sh`), so `frontend/package.json`
# is one and a nested manifest such as `frontend/app/foo/package.json`, or one
# under an unregistered directory, is not.
#
# Usage: bash .gaia/scripts/chore-deps-skip.sh <subject> <<<"$paths"
# One path per line on stdin, blank lines ignored. This predicate drains all
# of stdin on every path, including a non-matching title, so a pipefail
# caller may pipe a live writer directly in with no SIGPIPE risk. The
# prescribed form is still a here-string built from a variable first, so the
# caller can tell a failed diff apart from an empty one.
#
# A registry or descriptor that cannot be read prints `false` (not
# dependency-only) with the reason on stderr; it never prints `true`.
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

# The registry lives beside this script's tree, so a caller running the script
# from a PR tree reads that tree's registry, whatever its own working directory.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

paths=""
if [ ! -t 0 ]; then
  # `changed_path=` first: a closed fd 0 (`<&-`) still passes `[ ! -t 0 ]`, and a `read`
  # on a closed fd assigns nothing, so `[ -n "$changed_path" ]` on an unset `changed_path` would trip
  # `set -u`. `read`'s own stderr is silenced for the same closed-fd case:
  # bash writes a "Bad file descriptor" diagnostic there that a caller under
  # `set -eu` never asked for and this predicate's contract never promises.
  changed_path=
  while IFS= read -r changed_path 2>/dev/null || [ -n "$changed_path" ]; do
    paths="${paths}${changed_path}"$'\n'
  done
fi

case "$subject" in
  'chore(deps):'* | 'chore(deps-dev):'*)
    manifest_only=1
    saw_path=0
    manifest_ere=''
    packages_lib="$repo_root/.claude/hooks/lib/gaia-packages.sh"
    load_status=0
    if [ -f "$packages_lib" ]; then
      # shellcheck source=/dev/null
      . "$packages_lib"
      gaia_packages_load "$repo_root" || load_status=$?
      if [ "$load_status" -eq 0 ]; then
        manifest_ere="$(gaia_package_globs_ere dependencyManifests)"
      else
        printf '%s\n' "$GAIA_PACKAGES_ERROR" >&2
      fi
    else
      load_status=1
      printf 'gaia-packages: .claude/hooks/lib/gaia-packages.sh is missing. Next step: restore it from git or run /update-gaia.\n' >&2
    fi
    changed_path=
    while IFS= read -r changed_path || [ -n "$changed_path" ]; do
      [ -n "$changed_path" ] || continue
      saw_path=1
      case "$changed_path" in
        package.json | pnpm-lock.yaml | pnpm-workspace.yaml) ;;
      # gaia:maintainer-only:start
        # This maintainer checkout's CLI package manifest; its lockfile is the root one.
        .gaia/cli/package.json) ;;
      # gaia:maintainer-only:end
        *)
          if [ -z "$manifest_ere" ] || ! printf '%s\n' "$changed_path" | grep -Eq -- "$manifest_ere"; then
            manifest_only=0
          fi
          ;;
      esac
    done <<<"$paths"
    if [ "$load_status" -eq 0 ] && [ "$saw_path" -eq 1 ] && [ "$manifest_only" -eq 1 ]; then
      printf 'true\n'
    else
      printf 'false\n'
    fi
    ;;
  *) printf 'false\n' ;;
esac
