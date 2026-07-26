#!/usr/bin/env bash
# PreToolUse mcp__serena__activate_project hook: deny an activate_project call
# whose target is a DIFFERENT tree of this clone than the one the session acts
# in.
#
# Serena is registered without --project-from-cwd, so activate_project is
# exposed and no project auto-activates: every session must call it, by name
# or by absolute path. A NAME resolves through Serena's own machine-global
# registry (~/.serena/serena_config.yml, a list of absolute project paths,
# each carrying a project_name from its own .serena/project.yml) to whichever
# checkout registered that name. .serena/project.yml is tracked, so every
# linked worktree of this clone carries the SAME name -- and the registry
# entry that name resolves to is whichever checkout registered first, in
# practice the main checkout. A session working in a linked worktree that
# activates by that bare name therefore gets every subsequent symbol answer
# resolved against main's files, silently: no error, no indication, and a
# session that never notices because the tool call itself succeeded. The path
# form of the same call is exposed to the identical mistake in reverse: a
# stale absolute path left over from another tree, or copy-pasted from
# elsewhere, activates that tree instead of this one, just as silently.
#
# Tree identity comes from the one shared resolver, so this guard never
# re-derives "which tree am I in":
#
#   Whose working directory: the payload's `cwd` field, honored on the same
#   terms as block-worktree-path-mismatch.sh's own treatment -- absolute and
#   resolving to a checkout, or the hook's own process cwd otherwise. The
#   absolute requirement is load-bearing for the same reason there: the value
#   reaches a bare `cd` that would option-parse a leading dash and succeed
#   into the wrong directory.
#
#   Which tree: .gaia/scripts/main-root-lib.sh's gaia_resolve_tree_root, the
#   per-tree counterpart of gaia_resolve_main_root -- the acting tree's own
#   root, physically resolved, whether that tree is main or a linked
#   worktree.
#
# Two arms, because the argument to `project` is either a path or a name:
#
#   PATH arm: the argument physically resolves to a checkout of the SAME
#   clone as the acting tree, but a different one -- the main checkout or a
#   sibling worktree. Symmetric by design: it holds whether the session acts
#   in the main checkout or a linked worktree, because "activate the tree you
#   are in" is true both ways.
#
#   NAME arm: the argument is a bare name. Applies only from inside a linked
#   worktree -- in the main checkout the bare name IS the correct activation,
#   because the registry resolves it there. Denied only when the name equals
#   the acting tree's own .serena/project.yml project_name, the one shape
#   that is provably wrong: that name resolves through the registry to a
#   DIFFERENT checkout (main), never to this one.
#
# What this guard does NOT cover: it cannot see which project Serena has
# already activated, so it adjudicates the activation CALL, not the answer a
# later symbol query gives -- a session that activated before this guard
# existed, or before this file was added, is not retro-corrected. It also
# cannot stop a name Serena's registry has not yet registered for this
# clone's own checkouts; that is not the failure mode described above, which
# needs an existing collision to fire.
#
# Fail-open, matching the other block-*.sh guards: any ambiguity (identity
# undeterminable, jq or the resolver unavailable, a target that does not
# resolve) allows the call rather than blocking a legitimate activation on an
# identity it could not confirm.
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

[[ "$tool_name" == "mcp__serena__activate_project" ]] || exit 0

project=$(jq -r '.tool_input.project // empty' <<<"$payload")
[[ -n "$project" ]] || exit 0

# The shared resolver, sourced from this hook's own checkout via BASH_SOURCE
# (never from the process cwd): this file and the library ship together, so
# its location is fixed relative to this file no matter which checkout the
# hook runs in. If it is unreachable the guard can no longer adjudicate, so
# it fails open.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
source "$gaia_scripts/main-root-lib.sh" 2>/dev/null || exit 0

# Every git question this guard asks is asked through the shared resolver,
# never through a raw git primitive: gaia_resolve_tree_root for "which tree is
# this", gaia_resolve_main_root for "which clone is this". Both strip the three
# repository-discovery overrides internally, so an ambient
# GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR from a calling git hook cannot stand in
# for a checkout's own layout, and neither answer is a second hand-written
# derivation of the main-checkout root.
#
# Two trees belong to the same clone exactly when they resolve to the same main
# checkout, which is what makes a sibling worktree distinguishable from an
# unrelated project without this guard computing a common dir of its own.

# The acting agent's working directory: the payload cwd when it is absolute
# and resolves to a checkout, the hook's process cwd otherwise. Same contract
# as block-worktree-path-mismatch.sh's own source_cwd.
payload_cwd=$(jq -r '.cwd // empty' <<<"$payload")
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && gaia_resolve_tree_root "$payload_cwd" >/dev/null 2>&1; then
  source_cwd="$payload_cwd"
fi

# current_root is the acting tree's own physically-resolved root, whether
# that tree is main or a linked worktree. A resolution failure is
# undeterminable identity, which this guard treats as fail-open.
current_root="$(gaia_resolve_tree_root "$source_cwd")" || exit 0
[[ -n "$current_root" ]] || exit 0

# The argument names a path when it starts with `/`, contains a `/`, or is
# exactly `.`/`..`; a non-absolute one resolves against the acting cwd, never
# the hook's own process cwd. Anything else is a bare name.
case "$project" in
  /*)
    candidate="$project"
    ;;
  */* | . | ..)
    candidate="$source_cwd/$project"
    ;;
  *)
    candidate=""
    ;;
esac

if [[ -n "$candidate" ]]; then
  # --- PATH arm ---
  resolved="$(CDPATH='' cd "$candidate" 2>/dev/null && pwd -P)" || exit 0
  [[ -n "$resolved" ]] || exit 0
  [[ "$resolved" != "$current_root" ]] || exit 0

  # A different clone entirely (another project) is not this guard's concern:
  # two trees are the same clone exactly when they resolve to the same main
  # checkout.
  target_main_root="$(gaia_resolve_main_root "$resolved")" || exit 0
  [[ -n "$target_main_root" ]] || exit 0
  current_main_root="$(gaia_resolve_main_root "$source_cwd")" || exit 0
  [[ -n "$current_main_root" ]] || exit 0
  [[ "$target_main_root" == "$current_main_root" ]] || exit 0

  target_toplevel="$(gaia_resolve_tree_root "$resolved")" || exit 0
  [[ -n "$target_toplevel" ]] || exit 0
  [[ "$target_toplevel" != "$current_root" ]] || exit 0

  deny "BLOCKED: '$project' resolves to '$target_toplevel', a different checkout of this clone than the tree this session works in ('$current_root'). Activating it would point every subsequent symbol answer at that tree's files instead of this one, with no error and no indication of the mismatch. Pass '$current_root' instead."
fi

# --- NAME arm ---
# Only from inside a linked worktree: in the main checkout the bare name is
# the correct activation, since the registry resolves it there.
gaia_is_linked_worktree "$source_cwd" || exit 0

project_yml="$current_root/.serena/project.yml"
[[ -f "$project_yml" ]] || exit 0

own_name_line=$(sed -nE 's/^project_name:[[:space:]]*(.*)$/\1/p' "$project_yml" 2>/dev/null | head -1)
own_name=$(sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' <<<"$own_name_line")
[[ -n "$own_name" ]] || exit 0

if [[ "$project" == "$own_name" ]]; then
  deny "BLOCKED: activating '$project' by name resolves through Serena's machine-global project registry to whichever checkout registered that name, which is the main checkout -- not '$current_root', the linked worktree this session works in. Every symbol answer would then be resolved against the main checkout's files, silently: no error, no indication. Pass the path '$current_root' instead."
fi

exit 0
