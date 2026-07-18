#!/usr/bin/env bash
# WorktreeRemove hook: registering a WorktreeRemove hook replaces the harness's
# native `git worktree remove` entirely, so this hook owns the full teardown of
# a GAIA worktree: remove the worktree, delete its branch, and prune empty
# parent dirs under .claude/worktrees/.
#
# The hook runs with cwd INSIDE the worktree being removed, and git refuses to
# remove the worktree it is standing in, so every git action targets the main
# checkout resolved via --git-common-dir.
#
# Input:  JSON on stdin with `.worktree_path` (absolute path to the worktree).
# Exit:   0 on success (harness reports "removed"); non-zero means the worktree
#         could not be removed (harness keeps it).
set -uo pipefail

input="$(cat)"
worktree_path="$(printf '%s' "$input" | jq -r '.worktree_path // .cwd // ""')"

if [ -z "$worktree_path" ]; then
  printf 'remove-worktree: missing worktree_path\n' >&2
  exit 1
fi

# Resolve the main checkout (the hook's own cwd is the worktree being removed).
common="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)"
case "$common" in
  /*) main_root="$(dirname "$common")" ;;
  *)  main_root="$(cd "$(dirname "$common")" 2>/dev/null && pwd || pwd)" ;;
esac
base="$main_root/.claude/worktrees"

# Read the branch checked out in that worktree straight from git (robust to
# naming) before removing it. Detached-HEAD worktrees yield no branch.
# `worktree` line: substr, not $2 -- porcelain does not quote the path, so a
# $2 split would truncate at the first space in the path.
branch="$(git -C "$main_root" worktree list --porcelain 2>/dev/null \
  | awk -v p="$worktree_path" '
      $1 == "worktree" { cur = substr($0, 10) }
      $1 == "branch" && cur == p { sub("refs/heads/", "", $2); print $2 }')"

# Remove the worktree from the main checkout. --force discards the (already
# consent-gated) working copy; the harness only triggers removal after a
# no-changes auto-clean or an explicit discard.
if ! git -C "$main_root" worktree remove --force "$worktree_path" 2>/dev/null; then
  git -C "$main_root" worktree prune 2>/dev/null || true
  # Idempotent: an already-gone worktree is success; anything else is a failure.
  if [ -e "$worktree_path" ]; then
    printf 'remove-worktree: failed to remove %s\n' "$worktree_path" >&2
    exit 1
  fi
fi

# Delete the now-detached branch. Never touch the default branch. `-D` matches
# the harness's own "removing discards the branch and its commits" semantics.
if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
  git -C "$main_root" branch -D "$branch" 2>/dev/null || true
fi

# Prune empty parent dirs a slashed name leaves behind (e.g. .../worktrees/feat),
# walking up only within .claude/worktrees/ and stopping at the first non-empty.
dir="$(dirname "$worktree_path")"
while [ "$dir" != "$base" ] && [ "${dir#"$base"/}" != "$dir" ]; do
  rmdir "$dir" 2>/dev/null || break
  dir="$(dirname "$dir")"
done

exit 0
