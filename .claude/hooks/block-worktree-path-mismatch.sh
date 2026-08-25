#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit hook: deny a file_path that resolves to a
# checkout other than the linked git worktree this session works inside -- the
# main checkout or a sibling worktree.
#
# Once a session has switched into a linked worktree (see
# .claude/skills/gaia/references/isolation.md, "Export: RESOLVED_MODE and
# RESOLVED_ROOT"), every Edit/Write/MultiEdit call is expected to target that
# worktree. A stale absolute path from before the switch (e.g. the main
# checkout's own copy of a file that also exists in the worktree) is a
# different, equally valid file on disk, so the edit tools apply it with no
# error: the write silently lands in the wrong checkout. This is the
# silent-wrong-write footgun of tech-debt gaia-react/gaia#841.
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
#   whenever the hook process sits outside the repository (tech-debt gaia-react/gaia#940), which
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
# Scope: the guard adjudicates "does this target resolve into the acting tree",
# denying any write whose target lands in a different checkout -- the main
# checkout (gaia-react/gaia#841's own case) or a sibling linked worktree. The acting tree is the
# worktree the payload cwd names; the target's own tree is compared against it,
# so the question is answered from that one authoritative identity, not from main
# alone. This is the defense-in-depth role isolation.md contracts: deny an
# Edit/Write/MultiEdit whose file_path resolves to a different worktree than
# RESOLVED_ROOT.
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
#
# Both loads parse-check rather than carrying a trailing `|| exit 0`. Under
# `set -e` a failed `.` abandons the shell ahead of that arm, and the two ways
# it fails do not cost the same. Bash cannot open the file: the shell exits 1,
# which a PreToolUse hook reports as an advisory, so the edit proceeds
# unadjudicated with a raw diagnostic on stderr. That is the 3.2.57 stock macOS
# ships as /bin/bash; 5.x reaches the arm instead. Bash opens the file but
# cannot parse it, a lib left holding conflict markers: the shell exits 2, the
# deny code, so this fail-open guard denies the edit instead of allowing it.
#
# Both halves are 3.2-only, and it is the arm that makes them so: bash 5 lets
# the failed source's status reach `|| exit 0` for an unparseable lib exactly
# as it does for a missing one, measured both ways on 3.2.57 and 5.3.15. What
# separates the two halves is the exit code, 1 advisory against 2 deny, not
# their platform reach; only a bare `.` carrying no arm at all dies on both
# shells. The bats cases below are pinned to /bin/bash for that reason, and
# dropping the pin would green them against the spelling this replaced.
# `bash -n` answers both questions in one call and subsumes an existence test. Both loads sit past the tool-name and
# file-path gates above, so the forks are paid only on a real Edit/Write.
#
# What degrades in the arm's place is the `type` check below.
#
# Only the resolver loads here. The registry reader is deferred to its one
# point of use, far below, because the two sit behind very different gates and
# a parse check is a fork. This hook fires on every Edit/Write/MultiEdit, so a
# fork on this path is paid on every file the session touches, and it measures
# ~2.8ms on bash 3.2.57 and ~5.5ms on 5.3.15 against a ~16-22ms hook process on
# this machine, a surcharge rather than a doubling. The resolver has to
# be paid here: the linked-worktree predicate that gates everything below comes
# out of it, so there is no cheaper question to ask first that does not
# hand-roll a second copy of the resolution this file keeps in one place. The
# registry reader has no such constraint, and moving it behind the
# `.gaia/local` arm halves what an ordinary edit pays.
#
# Paying it at all was once argued against on the grounds that an unparseable
# library is rare and recoverable, because a denying Bash hook still leaves the
# editor tools free to repair it. That argument inverts here: the tool this
# hook denies IS the editor tool, so a corrupted library would deny the very
# Edit that repairs it. It no longer has to carry the decision alone, either.
# The pre-gate loads in the sibling hooks parse-check too, once the cost figure
# that argued for a cheaper arm failed to reproduce, so this is the norm across
# the family rather than an exception to it.
gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || exit 0
gaia_scripts="$gaia_scripts/.gaia/scripts"
# shellcheck source=/dev/null
"${BASH:-bash}" -n "$gaia_scripts/main-root-lib.sh" 2>/dev/null && . "$gaia_scripts/main-root-lib.sh" 2>/dev/null || true
type gaia_resolve_tree_root >/dev/null 2>&1 || exit 0

# The acting agent's working directory: the payload cwd when it is absolute and
# resolves to a checkout, the hook's process cwd otherwise. The absolute check is
# the load-bearing gate (a leading dash would option-parse inside `git -C`'s and
# `cd`'s operand); the checkout check is what routes an absolute non-repo value
# (e.g. /tmp) to the fallback rather than adopting it as a tree.
payload_cwd=$(jq -r '.cwd // empty' <<<"$payload")
source_cwd="$PWD"
if [[ "$payload_cwd" == /* ]] && gaia_resolve_tree_root "$payload_cwd" >/dev/null 2>&1; then
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

# current_root is the acting tree's own physically-resolved toplevel: the tree
# the target must land in, and the value the deny condition compares file_root
# against. It is resolved physically, as main_root and file_root already are, so
# the roots stay on the same footing and a symlinked path cannot make a same-tree
# write look cross-tree or the reverse.
current_root="$(gaia_resolve_tree_root "$source_cwd")" || exit 0
[[ -n "$current_root" ]] || exit 0

target_dir=$(dirname -- "$file_path")
resolved_target_dir="$(CDPATH='' cd "$target_dir" 2>/dev/null && pwd -P)" || exit 0
[[ -n "$resolved_target_dir" ]] || exit 0

# A linked worktree's whole .gaia/local is one symlink to the main checkout's
# own .gaia/local (see wiki/concepts/Worktrees.md). `git -C` resolves that
# symlink before computing --show-toplevel, so a write ANYWHERE under
# .gaia/local now reports the MAIN checkout as its toplevel and looks like a
# wrong-checkout write -- true of the whole tree, not a hand-listed subset, so
# this is ONE registry-driven rule instead of the two hand-listed exempt sets
# (linkable paths, main-anchored dirs) this guard used to maintain.
#
# gaia_registry_recognizes (with its own ancestor recognition: a container
# such as debt/ or audit/ is recognized once ANY child under it is a
# registered entry, even though the bare container is not itself a row) says
# whether the write targets a real, registry-known part of .gaia/local at
# all; gaia_registry_classify then says which scope. Every scope except
# per-tree is main's by construction post-flip and is exempt outright:
# shared and main-anchored state already had no worktree-side copy worth
# protecting, and the ephemeral cache entries (spec-session locks,
# audit-window breadcrumbs, and the rest) never had one either -- denying
# them would block the sole correct write, not catch a wrong one (tech-debt
# gaia-react/gaia#934's class). A relpath the registry does not recognize at all (typo,
# stray, or genuinely unclassified) is NOT exempted here and falls through
# to the ordinary cross-tree deny below, the same as before the cutover.
#
# The one entry that still needs protecting is per-tree state
# (red-ledger/, worthiness-ledger/, forensics/, handoff/): each addresses
# itself under a subdirectory named by gaia_tree_key
# (.gaia/scripts/main-root-lib.sh), the acting tree's own physically-resolved
# root, hashed. A write whose path carries the ACTING tree's own key is
# exempt; one carrying a peer tree's key, or the bare unkeyed container, is
# not, and falls through to the same deny.
#
# LOST PROTECTION: pre-cutover this guard told a correct per-tree write from
# a stale pre-switch one by PHYSICAL location -- a real per-worktree
# directory versus main's. Post-cutover the tree key in the path is the only
# signal, and a key is a deterministic hash of a tree's own root, not a
# secret: this guard can no longer distinguish a write that is genuinely
# from a live session in the acting tree from an absolute path some other
# mechanism constructed that merely happens to embed the acting tree's own
# key. Designing a replacement is a later phase's job; naming the loss here
# is this one's.
gaia_local="$main_root/.gaia/local"
case "$resolved_target_dir" in
  "$gaia_local" | "$gaia_local"/*)
    relpath="${resolved_target_dir#"$gaia_local"}"
    relpath="${relpath#/}"
    # The registry reader, loaded here rather than beside the resolver above:
    # this arm is the only place it is used, and the gate in front of it is a
    # write under .gaia/local from a linked worktree, which is far narrower
    # than the every-edit gate the resolver's own load sits behind. Same parse
    # check, same reason (see that load's comment); it just costs less here.
    #
    # The `type` check below is not redundant with the parse check, and it is
    # the reason the load cannot simply be left bare: an unloaded
    # state-registry-lib.sh does not fail open on its own. gaia_registry_recognizes
    # is consulted from inside an `if` condition, so an undefined function reads
    # as "no entry recognizes this path" and routes the write to the unregistered
    # DENY arm below. A library that never loaded would then make this guard
    # block more, not less, which inverts the fail-open contract stated at the
    # top of this file.
    # shellcheck source=/dev/null
    "${BASH:-bash}" -n "$gaia_scripts/state-registry-lib.sh" 2>/dev/null && . "$gaia_scripts/state-registry-lib.sh" 2>/dev/null || true
    type gaia_registry_recognizes >/dev/null 2>&1 || exit 0
    if (cd "$main_root" 2>/dev/null && gaia_registry_recognizes "$relpath" d); then
      scope="$(cd "$main_root" 2>/dev/null && gaia_registry_classify "$relpath" 2>/dev/null)" || scope=""
      if [[ "$scope" != "per-tree" ]]; then
        exit 0
      fi
      acting_key="$(gaia_tree_key "$current_root" 2>/dev/null)" || exit 0
      [[ -n "$acting_key" ]] || exit 0
      container="${relpath%%/*}"
      case "$relpath" in
        "$container/$acting_key" | "$container/$acting_key"/*) exit 0 ;;
      esac
      # Both messages name the local-state root through $gaia_local rather than
      # spelling it out. That is the derive rule this hook is held to (the
      # manifest's derive arm, check-hook-scope-manifest.sh) applied to prose as
      # well as to logic, and it makes the advice better: the caller is told the
      # absolute path to use, not a repo-relative fragment they have to rebuild
      # from a root the symlink has already moved out from under them.
      wg_local_reason="'$file_path' is per-tree state under '$container/', which is addressed by the writing tree's own key. This session's tree key is '$acting_key', so the correct path is '$gaia_local/$container/$acting_key/'. The path given carries a different tree's key, or none at all, and every reader looks only under the key -- so this write would be invisible to the tree that made it and could shadow another tree's."
    else
      wg_local_reason="'$file_path' is under '$gaia_local', which a linked worktree reaches through one symlink to the main checkout, but no entry in .gaia/state-registry.json recognizes it. Because it is unregistered, this guard cannot tell whether it is state the whole clone shares or state this tree must keep to itself, and re-resolving the repository root will not change the answer -- the symlink resolves to the main checkout either way. Register it in .gaia/state-registry.json with its scope, or write it under an entry that already exists."
    fi
    ;;
esac

# The target's own checkout, physically resolved so the comparison against the
# physically-resolved current_root is symmetric: a symlinked path cannot make a
# same-tree write look cross-tree, or the reverse.
file_root="$(gaia_resolve_tree_root "$target_dir")" || exit 0
[[ -n "$file_root" ]] || exit 0

# The target resolves into a checkout other than the acting tree: the main
# checkout or a sibling worktree, both the gaia-react/gaia#841 silent-wrong-write. The exempt
# shared and main-anchored paths have already returned above, so a cross-tree
# target reaching here is a real wrong-write, not a legitimate write-through to
# main.
if [[ "$file_root" != "$current_root" ]]; then
  # A .gaia/local target reaching here has a more useful thing to say than the
  # generic stale-path advice, and saying the generic thing would be actively
  # wrong: re-resolving the repository root does not move a path that reaches
  # main through the one .gaia/local symlink, so the caller would be sent round
  # a loop it cannot exit. The branch above sets the specific reason; the
  # generic one still covers every path outside .gaia/local, where the stale
  # pre-switch absolute path really is the cause.
  if [[ -n "${wg_local_reason:-}" ]]; then
    deny "BLOCKED: $wg_local_reason"
  fi
  deny "BLOCKED: '$file_path' resolves to a different checkout ('$file_root') than the linked worktree this session works inside ('$current_root'). This is the silent-wrong-write footgun from tech-debt gaia-react/gaia#841: a stale pre-switch absolute path is a real, valid file in another checkout (the main checkout or a sibling worktree), so the edit tools would apply it with no error. Resolve RESOLVED_ROOT fresh (git rev-parse --show-toplevel) and prefix file_path with it."
fi

exit 0
