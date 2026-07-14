#!/usr/bin/env bash
# WorktreeCreate hook: creates a git worktree under .claude/worktrees/ and sets
# up GAIA shared-state symlinks. Claude Code fires this hook and waits for the
# worktree path on stdout before the agent starts. A registered WorktreeCreate
# hook replaces the harness's default `git worktree` logic entirely.
#
# Input:  JSON on stdin. The harness sends the worktree name under `.name`
#         (legacy/HTTP variants used `.worktree_name`); no base ref or target
#         path is included, so this hook derives both. Common fields
#         (session_id, cwd, hook_event_name, ...) are present but unused.
# Output: absolute worktree path on stdout.
# Exit:   0 on success with path; non-zero aborts worktree creation.

set -euo pipefail

input="$(cat)"
# The harness sends the worktree name under `.name`; older/HTTP hook variants
# used `.worktree_name`. Read tolerantly so the hook survives payload drift.
worktree_name="$(printf '%s' "$input" | jq -r '.name // .worktree_name // ""')"

if [ -z "$worktree_name" ]; then
  printf 'create-worktree: missing worktree_name\n' >&2
  exit 1
fi

# Defense-in-depth: worktree_name lands in a filesystem path and a branch
# name. Reject `..` and absolute paths so the worktree can't escape the
# worktrees/ directory even if the stdin payload is influenced by untrusted
# content. Internal slashes (e.g. `fix/foo`) stay allowed.
if [[ "$worktree_name" == *..* || "$worktree_name" == /* ]]; then
  printf 'create-worktree: worktree_name must not contain ".." or start with "/"\n' >&2
  exit 1
fi

project_root="$(git rev-parse --show-toplevel)"

# No base ref is carried in the WorktreeCreate payload, so derive one: honor a
# ref if a future harness version supplies it, else branch fresh from the remote
# default branch (matching the harness default), else fall back to local HEAD.
base_ref="$(printf '%s' "$input" | jq -r '.base_ref // .source_ref // ""')"
if [ -z "$base_ref" ]; then
  base_ref="$(git -C "$project_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo HEAD)"
fi

# Create under .claude/worktrees/ to match the harness default and gitignore.
worktree_path="$project_root/.claude/worktrees/$worktree_name"

mkdir -p "$(dirname "$worktree_path")"

# Record whether the target path is already there before we touch it. The
# failure cleanup below force-removes $worktree_path, and on a name collision
# (a peer session already holding a worktree of this name) both `worktree add`
# attempts fail, so that cleanup would delete someone else's worktree along
# with any uncommitted work in it. Only clean up a path this run created.
path_pre_existed=0
if [ -e "$worktree_path" ]; then
  path_pre_existed=1
fi

# Try new branch first; if name already exists, check out the existing one.
# Silence git entirely (stdout too): "HEAD is now at ..." is written to stdout,
# and the hook's stdout must carry only the worktree path for the harness.
if ! git -C "$project_root" worktree add "$worktree_path" -b "$worktree_name" "$base_ref" >/dev/null 2>&1; then
  if ! git -C "$project_root" worktree add "$worktree_path" "$worktree_name" >/dev/null 2>&1; then
    printf 'create-worktree: git worktree add failed for %s\n' "$worktree_path" >&2
    # Both adds failed, so this run registered nothing: any live worktree now at
    # the path belongs to someone else. Re-read the list here rather than trust
    # the pre-add sample alone, because a peer session racing us on this name
    # can have created and registered it inside our check-to-add window.
    #
    # Fail closed on an unreadable list: it cannot prove the path is ours, and
    # not deleting other people's work is this guard's entire purpose.
    if ! wt_list="$(git -C "$project_root" worktree list --porcelain 2>/dev/null)"; then
      printf 'create-worktree: cannot read the worktree list; leaving %s alone\n' "$worktree_path" >&2
      exit 1
    fi

    # `-e` is load-bearing, not redundant with the grep: git keeps listing a
    # worktree whose directory is gone (it is merely prunable), so the grep
    # alone would read a crashed run's stale registration as live and skip the
    # cleanup that prunes it, wedging this name for every later run.
    # Here-string, not a pipe: `git ... | grep -q` under pipefail lets grep's
    # early exit SIGPIPE the upstream write and flip a match into a false miss.
    # `-x` (whole-line) because `worktree /path/alpha` prefixes `.../alpha2`.
    if [ "$path_pre_existed" -eq 1 ] \
      || { [ -e "$worktree_path" ] && grep -qxF "worktree $worktree_path" <<<"$wt_list"; }; then
      # Not ours to delete. Say so: a name collision is the likeliest reason the
      # add failed at all, and the operator needs a way out.
      printf 'create-worktree: %s was not created by this run; leaving it intact (remove it yourself, or retry with a different worktree name)\n' "$worktree_path" >&2
    else
      # `git worktree remove --force` clears both the directory and the stale
      # .git/worktrees/ registration; rm -rf is the fallback if git itself
      # can't clean up. rmdir alone would leave a non-empty dir behind.
      git -C "$project_root" worktree remove --force "$worktree_path" 2>/dev/null \
        || rm -rf "$worktree_path" 2>/dev/null || true
    fi
    exit 1
  fi
fi

# Set up shared-state symlinks inside the new worktree.
(cd "$worktree_path" && bash ".gaia/scripts/link-worktree.sh") || true

printf '%s\n' "$worktree_path"
