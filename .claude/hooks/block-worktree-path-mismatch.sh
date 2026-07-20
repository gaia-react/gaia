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
# Whose working directory: the hook reads the calling agent's own cwd from the
# PreToolUse payload's `cwd` field, falling back to its own process cwd when the
# payload omits it or names a directory outside this repo. Neither source is
# contracted, and the payload is not the better-evidenced one: the hooks
# reference defines `cwd` only as the working directory at invocation and says
# nothing about per-agent versus shared scoping. It is preferred because it is a
# declared input describing this call, where the process cwd is ambient state
# inferred to stand in for one. Reading only the process cwd would let the guard
# go silently inert if a harness version ever stopped aligning the two. The
# payload cwd is honored only when it is absolute and resolves to a checkout of
# this repo; anything else routes to the process cwd. That absolute-path
# requirement is load-bearing, not cosmetic, and is argued where it is enforced.
#
# Scope, and why it stops there: the guard adjudicates "does this target resolve
# to the main checkout", which is #841's own case. `main_root` derives from
# --git-common-dir, which is identical from every worktree of the repo, so that
# question is cwd-independent by construction. A write from one linked worktree
# into another is left to the caller's own RESOLVED_ROOT discipline, per this
# guard's defense-in-depth role in isolation.md.
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
# The calling agent's working directory comes from the payload's `cwd`, the
# value Claude Code reports for the agent that issued this call. It is honored
# only when it is absolute AND resolves to a checkout of THIS repo (same common
# git dir as main_root); a cwd naming an unrelated repository would arm the gate
# on a comparison between two different repositories and deny a legitimate edit.
# The hook's own process cwd is the fallback for an absent, relative,
# unresolvable, or foreign-repo payload cwd.
current_root=""
payload_cwd=$(jq -r '.cwd // empty' <<<"$payload")
# Absolute-cwd invariant, established once so every consumer below inherits it:
# payload_cwd flows into `git -C`, into string-concatenation, and into `cd`, and
# each option-parses its own operand. `cd` is the sharp edge: `cd -P`, `cd -L`,
# and `cd -e` parse as an option with NO operand, so cd lands in $HOME and
# succeeds rather than failing into the `|| payload_main_root=""` fallback, and
# `cd -` moves to $OLDPWD and prints it. Requiring a leading slash makes every
# downstream operand provably absolute, which is the same property main_root's
# own two-branch derivation above guarantees, and unlike a `--` terminator it
# behaves identically on bash 3.2 and bash 5. An empty value falls through to
# the `-n` guard below and routes to the process cwd, same as an absent field.
# `dirname --` and `CDPATH=''` below are belt-and-braces once this holds: with
# an absolute payload_cwd neither a dash-leading operand nor a CDPATH lookup is
# reachable, and they stay as defense in depth.
case "$payload_cwd" in
  /*) ;;
  *) payload_cwd="" ;;
esac
if [[ -n "$payload_cwd" ]]; then
  payload_common_dir="$(git -C "$payload_cwd" rev-parse --git-common-dir 2>/dev/null)" || payload_common_dir=""
  case "$payload_common_dir" in
    '') abs_payload_common_dir='' ;;
    /*) abs_payload_common_dir="$payload_common_dir" ;;
    *) abs_payload_common_dir="$payload_cwd/$payload_common_dir" ;;
  esac
  if [[ -n "$abs_payload_common_dir" ]]; then
    payload_main_root="$(CDPATH='' cd "$(dirname -- "$abs_payload_common_dir")" 2>/dev/null && pwd -P)" || payload_main_root=""
    if [[ -n "$payload_main_root" && "$payload_main_root" == "$main_root" ]]; then
      current_root="$(git -C "$payload_cwd" rev-parse --show-toplevel 2>/dev/null)" || current_root=""
    fi
  fi
fi
[[ -n "$current_root" ]] || current_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$main_root" && -n "$current_root" ]] || exit 0

# Not inside a linked worktree: nothing to guard.
[[ "$main_root" != "$current_root" ]] || exit 0

target_dir=$(dirname -- "$file_path")
resolved_target_dir="$(CDPATH='' cd "$target_dir" 2>/dev/null && pwd -P)" || exit 0
[[ -n "$resolved_target_dir" ]] || exit 0

# The symlinked shared-state dirs are exempt. link-worktree.sh symlinks exactly
# five paths under .gaia/local/ out of every linked worktree and into the main
# checkout so that state is shared rather than forked: setup-state.json,
# cache/shared, audit, telemetry, and debt. (It also symlinks gitignored
# checkout-root .env files, which need no arm here: their target_dir is the
# worktree root, so the main-checkout test below allows them.) `git -C` resolves a symlink before computing
# --show-toplevel, so a write to the worktree's own .gaia/local/audit/ reports
# the MAIN checkout as its toplevel and reads as a wrong-checkout write. That is
# the intended write, so the four symlinked DIRS are exempt.
#
# The exemption stops there deliberately. The rest of .gaia/local/ (plans/,
# specs/, handoff/, red-ledger/, forensics/, worktree-locks/, the non-shared
# cache/ subdirs) is not symlinked, so each worktree owns its own copy and a
# stale pre-switch path there is exactly the #841 silent-wrong-write this guard
# exists to catch. setup-state.json needs no arm of its own: it is a symlinked
# FILE, so its target_dir is the worktree's own real .gaia/local, which never
# reaches this case and is allowed by the main-checkout test below.
#
# The trailing slash on both sides keeps each arm a path-segment match, so a
# sibling such as .gaia/localish/ stays guarded.
case "$resolved_target_dir/" in
  "$main_root"/.gaia/local/audit/* | \
    "$main_root"/.gaia/local/debt/* | \
    "$main_root"/.gaia/local/telemetry/* | \
    "$main_root"/.gaia/local/cache/shared/*) exit 0 ;;
esac

file_root="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$file_root" ]] || exit 0

if [[ "$file_root" == "$main_root" ]]; then
  deny "BLOCKED: '$file_path' resolves to the main checkout ('$main_root') while this session works inside a linked worktree ('$current_root'). This is the silent-wrong-write footgun from tech-debt #841: a stale pre-switch absolute path is a real, valid file in another checkout, so the edit tools would apply it with no error. Resolve RESOLVED_ROOT fresh (git rev-parse --show-toplevel) and prefix file_path with it."
fi

exit 0
