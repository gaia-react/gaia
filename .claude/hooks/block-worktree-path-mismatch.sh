#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit hook: deny a file_path that resolves to a
# different git worktree than the one this session currently works in.
#
# Once a session has switched into a linked worktree (see
# .claude/skills/gaia/references/isolation.md, "Export: RESOLVED_MODE and
# RESOLVED_ROOT"), every Edit/Write/MultiEdit call is expected to target that
# worktree. A stale absolute path from before the switch (e.g. the main
# checkout's own copy of a file that also exists in the worktree) is a
# different, equally valid file on disk, so the edit tools apply it with no
# error: the write silently lands in the wrong checkout.
#
# Detection mirrors isolation.md's own worktree check (same as
# .gaia/scripts/link-worktree.sh): compare the toplevel that owns the common
# git dir (the main checkout) against the current toplevel. When they match,
# this session is not inside a linked worktree at all (feature-branch mode,
# or a plain checkout) and there is nothing to guard. When they differ, this
# session is inside a linked worktree, and the current toplevel is the only
# authorized target for Edit/Write/MultiEdit.
#
# Fail-open, matching the other block-*.sh guards: any ambiguity (not a git
# repo, a target directory that does not exist yet, `git` unavailable) allows
# the call rather than blocking a legitimate edit on a heuristic miss.
set -euo pipefail

payload=$(cat)
tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

case "$tool_name" in
  Edit | Write | MultiEdit) ;;
  *) exit 0 ;;
esac

file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
[[ -n "$file_path" ]] || exit 0

common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
case "$common_dir" in
  /*) abs_common_dir="$common_dir" ;;
  *) abs_common_dir="$PWD/$common_dir" ;;
esac
main_root="$(cd "$(dirname "$abs_common_dir")" 2>/dev/null && pwd -P)" || exit 0
current_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$main_root" && -n "$current_root" ]] || exit 0

# Not inside a linked worktree: nothing to guard.
[[ "$main_root" != "$current_root" ]] || exit 0

target_dir=$(dirname -- "$file_path")
file_root="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$file_root" ]] || exit 0

if [[ "$file_root" != "$current_root" ]]; then
  deny "BLOCKED: '$file_path' resolves to a different git worktree ('$file_root') than this session's current worktree ('$current_root'). This is the silent-wrong-write footgun from tech-debt #841: a stale pre-switch absolute path is a real, valid file in another checkout, so the edit tools would apply it with no error. Resolve RESOLVED_ROOT fresh (git rev-parse --show-toplevel) and prefix file_path with it."
fi

exit 0
