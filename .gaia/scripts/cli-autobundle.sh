#!/usr/bin/env bash
# Rebuild and stage the committed CLI bundles when a commit stages CLI inputs.
#
# Usage: cli-autobundle.sh <repo-root>
#
# Called by the maintainer-only arm of .githooks/pre-commit. The committed
# bundles (.gaia/cli/gaia, .gaia/cli/gaia-maintainer) are what hooks, skills and
# every worktree execute, so a commit that changes their inputs must carry the
# rebuilt bundles; CI's freshness check is the backstop, this makes the rebuild
# automatic.
#
# Triggers: any staged path (every status, deletions included) under
# .gaia/cli/src/, or .gaia/cli/package.json, the root pnpm-lock.yaml (the CLI is
# a member of the root workspace), .gaia/cli/tsconfig*.json (esbuild reads the
# nearest tsconfig.json). With none staged it exits 0 and prints nothing.
#
# Exit codes:
#   0  nothing to do, bundles rebuilt and staged, or the CLI has no install
#   1  unstaged or untracked CLI source, or the build failed
#   2  usage error
#
# Why it refuses on unstaged or untracked .gaia/cli/src changes: the bundle
# builds from the working tree, so those changes would land in a bundle that
# does not match the committed source.
#
# Why a missing install only warns: a clone or worktree without
# .gaia/cli/node_modules cannot build, and failing every commit there would
# block unrelated work; CI's freshness check still fails the PR until the
# bundles are rebuilt.
#
# Inherited GIT_INDEX_FILE is left alone on purpose: `git add` below must stage
# into the index the hook's commit will use.

set -u

if [ "$#" -ne 1 ]; then
  echo "usage: cli-autobundle.sh <repo-root>" >&2
  exit 2
fi
root=$1
cli_directory=".gaia/cli"

# --quiet exits 0 with nothing staged under the pathspecs, 1 with something
# staged, and higher when git itself fails.
git -C "$root" diff --cached --quiet --no-renames -- \
  "$cli_directory/src" "$cli_directory/package.json" "pnpm-lock.yaml" "$cli_directory/tsconfig*.json"
staged_status=$?
if [ "$staged_status" -eq 0 ]; then
  exit 0
fi
if [ "$staged_status" -ne 1 ]; then
  echo "cli-autobundle: could not read the staged paths in $root" >&2
  exit 1
fi

dirty_paths=()
while IFS= read -r -d '' dirty_path; do
  dirty_paths+=("$dirty_path")
done < <(
  git -C "$root" diff --name-only -z -- "$cli_directory/src"
  git -C "$root" ls-files -z --others --exclude-standard -- "$cli_directory/src"
)

if [ "${#dirty_paths[@]}" -gt 0 ]; then
  echo "CLI source is staged but these .gaia/cli/src paths have unstaged or untracked changes, so the bundles cannot be rebuilt to match the commit:" >&2
  for dirty_path in ${dirty_paths[@]+"${dirty_paths[@]}"}; do
    echo "  $dirty_path" >&2
  done
  echo "Stage them, or set them aside, then commit again." >&2
  exit 1
fi

if [ ! -x "$root/$cli_directory/node_modules/.bin/esbuild" ] || ! command -v pnpm > /dev/null 2>&1; then
  echo "warning: CLI bundles not rebuilt (no CLI install or no pnpm). Run 'pnpm install --frozen-lockfile' from the repository root then 'pnpm -C .gaia/cli bundle' and stage both bundles; CI's freshness check fails until then." >&2
  exit 0
fi

if ! build_output=$(pnpm -C "$root/$cli_directory" bundle 2>&1); then
  echo "CLI bundle build failed:" >&2
  printf '%s\n' "$build_output" >&2
  exit 1
fi

git -C "$root" add -- "$cli_directory/gaia" "$cli_directory/gaia-maintainer" || exit 1
echo "CLI bundles rebuilt and staged (.gaia/cli/gaia, .gaia/cli/gaia-maintainer)."
exit 0
