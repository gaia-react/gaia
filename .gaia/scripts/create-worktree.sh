#!/usr/bin/env bash
# WorktreeCreate hook: creates a git worktree and sets up GAIA shared-state
# symlinks. Claude Code fires this hook and waits for the worktree path on
# stdout before the agent starts.
#
# Input:  JSON on stdin: worktree_name, base_ref, cwd (plus common fields).
# Output: absolute worktree path on stdout.
# Exit:   0 on success with path; non-zero aborts the caller.

set -euo pipefail

input="$(cat)"
worktree_name="$(printf '%s' "$input" | jq -r '.worktree_name // ""')"
base_ref="$(printf '%s' "$input" | jq -r '.base_ref // "main"')"

if [ -z "$worktree_name" ]; then
  printf 'create-worktree: missing worktree_name\n' >&2
  exit 1
fi

# Defense-in-depth: worktree_name lands in a filesystem path and a branch
# name. Reject `..` and absolute paths so the worktree can't escape the
# sibling worktrees/ directory even if the stdin payload is influenced by
# untrusted content. Internal slashes (e.g. `fix/foo`) stay allowed.
if [[ "$worktree_name" == *..* || "$worktree_name" == /* ]]; then
  printf 'create-worktree: worktree_name must not contain ".." or start with "/"\n' >&2
  exit 1
fi

project_root="$(git rev-parse --show-toplevel)"
worktree_path="$(dirname "$project_root")/worktrees/$worktree_name"

mkdir -p "$(dirname "$worktree_path")"

# Try new branch first; if name already exists, check out the existing one.
if ! git -C "$project_root" worktree add "$worktree_path" -b "$worktree_name" "${base_ref:-main}" 2>/dev/null; then
  if ! git -C "$project_root" worktree add "$worktree_path" "$worktree_name" 2>/dev/null; then
    printf 'create-worktree: git worktree add failed for %s\n' "$worktree_path" >&2
    # `git worktree remove --force` clears both the directory and the stale
    # .git/worktrees/ registration; rm -rf is the fallback if git itself
    # can't clean up. rmdir alone would leave a non-empty dir behind.
    git -C "$project_root" worktree remove --force "$worktree_path" 2>/dev/null \
      || rm -rf "$worktree_path" 2>/dev/null || true
    exit 1
  fi
fi

# Set up shared-state symlinks inside the new worktree.
(cd "$worktree_path" && bash ".gaia/scripts/link-worktree.sh") || true

printf '%s\n' "$worktree_path"
