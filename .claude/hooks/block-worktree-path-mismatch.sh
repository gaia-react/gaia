#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit hook: deny a file_path that resolves to the
# main checkout while this session works inside a linked git worktree.
#
# Once a session has switched into a linked worktree (see
# .claude/skills/gaia/references/isolation.md, "Export: RESOLVED_MODE and
# RESOLVED_ROOT"), every Edit/Write/MultiEdit call is expected to target that
# worktree. A stale absolute path from before the switch (e.g. the main
# checkout's own copy of a file that also exists in the worktree) is a
# different, equally valid file on disk, so the edit tools apply it with no
# error: the write silently lands in the wrong checkout. This is the
# silent-wrong-write footgun of tech-debt #841.
#
# Tree identity comes from one shared rule and one shared resolver, so this
# guard never re-derives "which tree am I in":
#
#   Whose working directory: the payload's `cwd` field names the working
#   directory Claude Code reports for the agent that issued this call, and it is
#   authoritative for tree identity whenever it is absolute and resolves to a
#   checkout. It is honored on its own terms there: no comparison against the
#   hook's own process cwd. The absolute requirement is load-bearing, because
#   the value reaches a bare `cd` that would option-parse a leading dash and
#   succeed into the wrong directory. A payload cwd that is relative, or absolute
#   but not a checkout, is unusable and routes to the process cwd instead. The
#   process cwd is the fallback, and it alone would leave the guard inert
#   whenever the hook process sits outside the repository (tech-debt #940), which
#   is an ALLOW; reading the payload first is what keeps the guard live.
#
#   Which tree, and where main is: .gaia/scripts/main-root-lib.sh is the one
#   resolver for both questions. gaia_is_linked_worktree answers whether the
#   acting cwd sits in a linked worktree at all, and gaia_resolve_main_root
#   answers the main checkout's root -- both symlink-canonicalized, env-stripped,
#   and correct in every checkout shape including submodules. Resolving both
#   roots physically keeps their comparison symmetric, so a checkout reached
#   through a symlinked path is never mistaken for a different tree.
#
# Scope, and why it stops there: the guard adjudicates "does this target resolve
# to the main checkout", which is #841's own case. `main_root` is identical from
# every worktree of the repo, so that question is cwd-independent by
# construction. A write from one linked worktree into another is left to the
# caller's own RESOLVED_ROOT discipline, per this guard's defense-in-depth role
# in isolation.md.
#
# Fail-open, matching the other block-*.sh guards: any ambiguity (identity
# undeterminable, a target directory that does not exist yet, `git` unavailable,
# the resolver or registry unreachable) allows the call rather than blocking a
# legitimate edit on an identity it could not confirm. Blocking a legitimate
# edit is the cheap-to-notice failure, and this guard is defense-in-depth, not
# the only line.
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

# The shared resolver and the state-registry reader, sourced from this hook's
# own checkout via BASH_SOURCE (never from the process cwd): this file and the
# two libraries ship together, so their location is fixed relative to this file
# no matter which checkout the hook runs in. If either is unreachable the guard
# can no longer adjudicate, so it fails open.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0
# shellcheck source=/dev/null
source "$gaia_scripts/state-registry-lib.sh" 2>/dev/null || exit 0

# git with the three repository-discovery overrides stripped, so every answer
# here is derived from on-disk layout alone (mirrors the resolver's own
# _gaia_git). An ambient GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR from a calling git
# hook would otherwise stand in for the checkout's own layout.
_wg_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git "$@"
}

# The acting agent's working directory: the payload cwd when it is absolute and
# resolves to a checkout, the hook's process cwd otherwise. The absolute check is
# the load-bearing gate (a leading dash would option-parse inside `git -C`'s and
# `cd`'s operand); the checkout check is what routes an absolute non-repo value
# (e.g. /tmp) to the fallback rather than adopting it as a tree.
payload_cwd=$(jq -r '.cwd // empty' <<<"$payload")
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && _wg_git -C "$payload_cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi

# Not inside a linked worktree (or identity indeterminate): nothing to guard.
# gaia_is_linked_worktree is the resolver's own linked-worktree predicate, so the
# "which tree am I in" question is answered in exactly one place. It returns
# non-zero for the main checkout, a plain checkout, and any case git cannot
# answer -- each a fail-open ALLOW for this non-destructive guard.
gaia_is_linked_worktree "$source_cwd" || exit 0

# main_root is the resolved main-checkout root, from the one shared resolver. A
# resolution failure is undeterminable identity, which this guard treats as
# fail-open.
main_root="$(gaia_resolve_main_root "$source_cwd")" || exit 0
[[ -n "$main_root" ]] || exit 0

# current_root is the acting tree's own physically-resolved toplevel, used only
# in the deny message. It is resolved physically, as main_root already is, so the
# two roots stay on the same footing.
current_root="$(_wg_git -C "$source_cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
current_root="$(CDPATH='' cd "$current_root" 2>/dev/null && pwd -P)" || exit 0
[[ -n "$current_root" ]] || exit 0

target_dir=$(dirname -- "$file_path")
resolved_target_dir="$(CDPATH='' cd "$target_dir" 2>/dev/null && pwd -P)" || exit 0
[[ -n "$resolved_target_dir" ]] || exit 0

# Exempt the main-checkout paths a linked worktree legitimately writes through to
# main, read from the state registry so this guard never hand-lists them:
#
#   - The registry's linkable trees (gaia_registry_linkable_paths): the shared
#     state link-worktree.sh symlinks out of every worktree into the main
#     checkout, so state is shared rather than forked. `git -C` resolves a
#     symlink before computing --show-toplevel, so a write to the worktree's own
#     symlinked .gaia/local/audit/ reports the MAIN checkout as its toplevel and
#     looks like a wrong-checkout write. It is the intended write; the symlinked
#     dirs are exempt. (A symlinked FILE such as setup-state.json needs no arm of
#     its own: its target_dir is the worktree's own real .gaia/local, which never
#     reaches this case and is allowed by the main-checkout test below.)
#   - The registry's wholly main-anchored directories
#     (gaia_registry_main_only_dirs): the plan and SPEC ledgers and the
#     worktree-creation locks, which have no worktree-side copy at all. The
#     main-checkout path is the only path that resolves to a real ledger there,
#     so denying it would block the sole correct write rather than catch a wrong
#     one (tech-debt #934).
#
# Reading both from the registry is what keeps this guard, link-worktree.sh, and
# link-worktree.ts in agreement: a directory newly classified shared or
# main-only in the registry is armed here with no edit to this hook, where a
# hand-maintained twin of the list would drift. The rest of .gaia/local/
# (handoff/, red-ledger/, forensics/, the non-shared cache/ subdirs) is
# per-worktree, so a stale pre-switch path into main's copy is exactly the #841
# silent-wrong-write this guard exists to catch, and stays denied. The read runs
# with cwd at main_root so the reader locates main's registry even when the hook
# process sits outside the repository. The trailing slash on both sides keeps
# each arm a path-segment match, so a sibling such as .gaia/localish/ or
# .gaia/local/plansible/ stays guarded.
exempt_paths="$(
  cd "$main_root" 2>/dev/null || exit 0
  gaia_registry_linkable_paths 2>/dev/null || true
  gaia_registry_main_only_dirs 2>/dev/null || true
)" || exempt_paths=""
gaia_local="$main_root/.gaia/local"
while IFS= read -r exempt; do
  [[ -n "$exempt" ]] || continue
  case "$resolved_target_dir/" in
    "$gaia_local/$exempt"/*) exit 0 ;;
  esac
done <<<"$exempt_paths"

# The target's own checkout, physically resolved so the comparison against the
# physically-resolved main_root is symmetric: a symlinked path cannot make an
# in-worktree write look like a main-checkout one, or the reverse.
file_root="$(_wg_git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[[ -n "$file_root" ]] || exit 0
file_root="$(CDPATH='' cd "$file_root" 2>/dev/null && pwd -P)" || exit 0
[[ -n "$file_root" ]] || exit 0

if [[ "$file_root" == "$main_root" ]]; then
  deny "BLOCKED: '$file_path' resolves to the main checkout ('$main_root') while this session works inside a linked worktree ('$current_root'). This is the silent-wrong-write footgun from tech-debt #841: a stale pre-switch absolute path is a real, valid file in another checkout, so the edit tools would apply it with no error. Resolve RESOLVED_ROOT fresh (git rev-parse --show-toplevel) and prefix file_path with it."
fi

exit 0
