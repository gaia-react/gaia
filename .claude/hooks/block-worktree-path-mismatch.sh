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
# session is inside a linked worktree, and a target that resolves to the main
# checkout is denied.
#
# Scope, and why it stops there: the hook reads its own process cwd, and that
# cwd is shared across concurrently active agents, so when one teammate enters
# a worktree every other agent's cwd moves with it. "Is this target MY
# worktree" is therefore unanswerable here, and adjudicating it would deny a
# teammate's correct write. `main_root` derives from --git-common-dir, which is
# identical from every worktree of the repo, so "does this target resolve to
# the main checkout" stays correct no matter which worktree the shared cwd sits
# in. The guard adjudicates only that, which is #841's own case. A write from
# one linked worktree into another is left to the caller's own RESOLVED_ROOT
# discipline, per this guard's defense-in-depth role in isolation.md.
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
resolved_target_dir="$(cd "$target_dir" 2>/dev/null && pwd -P)" || exit 0
[[ -n "$resolved_target_dir" ]] || exit 0

# The shared .gaia/local/ tree is exempt. create-worktree.sh / link-worktree.sh
# symlink the per-machine working state (audit markers, debt state, telemetry,
# setup-state.json) out of every linked worktree and into the main checkout, so
# that state is shared rather than forked. `git -C` resolves a symlink before
# computing --show-toplevel, so a write to the worktree's own .gaia/local/audit/
# reports the MAIN checkout as its toplevel and reads as a wrong-checkout write.
# It is the intended write, and nothing under that tree is a reviewed source
# surface. The trailing slash on both sides keeps this a path-segment match, so
# a sibling such as .gaia/localish/ stays guarded.
case "$resolved_target_dir/" in
  "$main_root"/.gaia/local/*) exit 0 ;;
esac

file_root="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$file_root" ]] || exit 0

if [[ "$file_root" == "$main_root" ]]; then
  deny "BLOCKED: '$file_path' resolves to the main checkout ('$main_root') while this session works inside a linked worktree ('$current_root'). This is the silent-wrong-write footgun from tech-debt #841: a stale pre-switch absolute path is a real, valid file in another checkout, so the edit tools would apply it with no error. Resolve RESOLVED_ROOT fresh (git rev-parse --show-toplevel) and prefix file_path with it."
fi

exit 0
