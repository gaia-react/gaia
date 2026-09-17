#!/usr/bin/env bash
# shellcheck shell=bash
#
# Resolves a Code Audit Team member's review scope in one command: the diff
# bases, the changed-file lists they yield, the dirty-in-scope check, and the
# scope-digest capture. A member runs it as one plain command with a literal
# path and carries each printed value into its later Bash calls as a literal.
#
# Why a script and not a fenced block in the member definition: a member
# dispatched into a linked worktree runs under the runtime's worktree
# confinement, which refuses a multi-command block, a `git` call inside a
# command substitution, and a command name computed at runtime, however the
# block's git calls are spelled. A script invoked by its literal path runs
# regardless of what it does inside, and its git calls stay under shellcheck
# and bats instead of in prose.
#
# Usage:
#   <root>/.gaia/scripts/audit-resolve-scope.sh --member <name> --root <root>
#       [--review-path <pathspec>]... [--skip-full-base] [--base-override <ref>]
#
#   --member          The member resolving its scope. Passed to
#                     resolve-audit-base.sh --member and to the capture.
#   --root            The working root under review. Must resolve, physically,
#                     to the tree this script sits in (see "Confinement").
#   --review-path     A pathspec narrowing the review-scope list (CHANGED).
#                     Repeatable. The membership list (FULL_CHANGED) is never
#                     narrowed.
#   --skip-full-base  Do not resolve the membership base. For a member whose
#                     self-skip is not membership-based (the default member
#                     asks the dispatch oracle instead), an unresolvable
#                     membership base is not a reason to stop.
#   --base-override   Use <ref> as the review base in place of the resolver's
#                     first line. KEY_REF, BASE_REASON and ANCHOR_TREE still
#                     come from the resolver, which made that decision.
#
# Output (stdout), one KEY=value per line, in this order:
#   AUDIT_ROOT FULL_BASE BASE_REF BASE_REASON KEY_REF ANCHOR_TREE BASE_SHA
#   KEY_BASE D_SCOPE, then one FULL_CHANGED=<path> per whole-PR path, one
#   CHANGED=<path> per review-scope path, one DIRTY=<status line> per dirty
#   in-scope entry. An unresolved scalar prints with an empty value. FULL_BASE
#   is omitted under --skip-full-base.
#
# Exit status:
#   0  resolved. Warnings about an empty base or a failed capture go to stderr
#      and do not change the status, because each consumer downstream already
#      refuses on the empty value it would receive.
#   1  the membership base is unresolvable, or the base-provenance resolver it
#      comes from is missing. Nothing after it runs: an empty
#      FULL_BASE makes FULL_CHANGED empty at status 0, which reads exactly like
#      a pull request that touched nothing in the member's remit, and a
#      self-skip there writes no marker at all.
#   2  usage error, or a --root this script refuses.
#
# Confinement: the script derives its own tree from its on-disk location and
# refuses a --root that does not resolve to that same tree. A member can
# therefore never resolve one tree's scope with another tree's machinery, the
# "review one tree, certify another" shape the working root exists to prevent.
# The comparison is physical (`cd && pwd -P`, the tree's portable idiom; neither
# `realpath` nor `readlink -f` is guaranteed on macOS), so a symlinked spelling
# of the right tree passes.

_ars_usage() {
  printf 'usage: audit-resolve-scope.sh --member <name> --root <root> [--review-path <pathspec>]... [--skip-full-base] [--base-override <ref>]\n' >&2
}

member=""
root_arg=""
root_given=0
skip_full_base=0
base_override=""
review_paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --member)
      [ "$#" -ge 2 ] || { _ars_usage; exit 2; }
      member="$2"; shift 2 ;;
    --root)
      [ "$#" -ge 2 ] || { _ars_usage; exit 2; }
      root_arg="$2"; root_given=1; shift 2 ;;
    --review-path)
      [ "$#" -ge 2 ] || { _ars_usage; exit 2; }
      review_paths+=("$2"); shift 2 ;;
    --skip-full-base)
      skip_full_base=1; shift ;;
    --base-override)
      [ "$#" -ge 2 ] || { _ars_usage; exit 2; }
      base_override="$2"; shift 2 ;;
    -h|--help)
      _ars_usage; exit 0 ;;
    *)
      printf 'audit-resolve-scope: unknown argument: %s\n' "$1" >&2
      _ars_usage; exit 2 ;;
  esac
done

if [ -z "$member" ] || [ "$root_given" -eq 0 ]; then
  _ars_usage
  exit 2
fi

# An empty --root is refused before the cd below: `cd ""` returns 0 on bash
# 3.2 (macOS /bin/bash) and would resolve the ambient directory.
if [ -z "$root_arg" ]; then
  printf 'audit-resolve-scope: --root is empty; refusing rather than resolving the ambient directory\n' >&2
  exit 2
fi

self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)"
root="$(cd "$root_arg" 2>/dev/null && pwd -P)"
if [ -z "$self_root" ] || [ -z "$root" ]; then
  printf "audit-resolve-scope: --root '%s' does not resolve to a directory\n" "$root_arg" >&2
  exit 2
fi
if [ "$root" != "$self_root" ]; then
  printf "audit-resolve-scope: --root '%s' resolves to %s, not to %s, the tree this script belongs to; run the copy under the root you are auditing\n" \
    "$root_arg" "$root" "$self_root" >&2
  exit 2
fi

printf 'AUDIT_ROOT=%s\n' "$root"

full_changed=()
if [ "$skip_full_base" -eq 0 ]; then
  # FULL_BASE decides one thing, the self-skip, so it comes from the same
  # resolver the membership decision reads (resolve-audit-members.sh calls it
  # with this anchor request): membership is resolved over the whole pull
  # request diff, never over the review increment, and a self-skip base that
  # disagreed with membership could skip a member membership still demands.
  prov_lib="$self_root/.claude/hooks/lib/audit-base-provenance.sh"
  FULL_BASE=""
  if [ -f "$prov_lib" ]; then
    # shellcheck source=/dev/null
    . "$prov_lib"
    prov="$(audit_resolve_base_provenance "$root" default-branch)" || prov=""
    # shellcheck disable=SC2034 # trust and anchor are part of the pinned three-field idiom
    IFS=$'\t' read -r prov_trust prov_anchor FULL_BASE <<< "$prov" || true
  fi
  printf 'FULL_BASE=%s\n' "$FULL_BASE"
  if [ -z "$FULL_BASE" ]; then
    if [ -f "$prov_lib" ]; then
      printf 'no merge-base against the default branch: membership scope is unresolvable, do NOT self-skip\n' >&2
    else
      printf 'base-provenance resolver missing at %s: membership scope is unresolvable, do NOT self-skip\n' "$prov_lib" >&2
    fi
    exit 1
  fi
  while IFS= read -r -d '' path; do
    full_changed+=("$path")
  done < <(git -C "$root" diff --name-only -z "${FULL_BASE}...HEAD" 2>/dev/null)
fi

# The resolver reads its tree from the working directory, so it runs from the
# root rather than from wherever this script was invoked.
BASE_OUT="$(cd "$root" && "$root/.github/audit/resolve-audit-base.sh" --member "$member")"
BASE_REF="$(printf '%s\n' "$BASE_OUT" | sed -n 1p)"
BASE_REASON="$(printf '%s\n' "$BASE_OUT" | sed -n 2p)"
KEY_REF="$(printf '%s\n' "$BASE_OUT" | sed -n 3p)"
ANCHOR_TREE="$(printf '%s\n' "$BASE_OUT" | sed -n 4p)"
[ -z "$base_override" ] || BASE_REF="$base_override"

BASE_SHA=""
[ -z "$BASE_REF" ] || BASE_SHA="$(git -C "$root" merge-base "$BASE_REF" HEAD 2>/dev/null || true)"
KEY_BASE=""
[ -z "$KEY_REF" ] || KEY_BASE="$(git -C "$root" merge-base "$KEY_REF" HEAD 2>/dev/null || true)"

# An empty BASE_SHA does not make the diff below fail: git resolves the empty
# left side to HEAD, so the review list comes back empty at status 0 and is
# indistinguishable from a genuinely empty increment. Say so where the silence
# is created, and skip the diff rather than run it on an empty base.
[ -n "$BASE_SHA" ] || printf 'resolve-audit-base returned no base; review scope is unreliable\n' >&2
[ -n "$KEY_BASE" ] || printf 'resolve-audit-base returned no shared key base; artifact keying is unreliable\n' >&2

printf 'BASE_REF=%s\n' "$BASE_REF"
printf 'BASE_REASON=%s\n' "$BASE_REASON"
printf 'KEY_REF=%s\n' "$KEY_REF"
printf 'ANCHOR_TREE=%s\n' "$ANCHOR_TREE"
printf 'BASE_SHA=%s\n' "$BASE_SHA"
printf 'KEY_BASE=%s\n' "$KEY_BASE"

# Three-dot against HEAD: the clearance digest is computed over HEAD's tracked
# content, so the review list must name HEAD's changes, not the working tree's
# and not an advanced ref tip's.
changed=()
if [ -n "$BASE_SHA" ]; then
  while IFS= read -r -d '' path; do
    changed+=("$path")
  done < <(git -C "$root" diff --name-only -z "${BASE_SHA}...HEAD" -- ${review_paths[@]+"${review_paths[@]}"} 2>/dev/null)
fi

# `Read` returns working-tree bytes while the clearance attests to HEAD, so a
# review over a dirty file certifies content nobody read. Only the review list
# is checked, never the whole tree. This fails closed: a status that cannot run
# reports the sentinel rather than reading as clean. xargs keeps a large list
# under the argument-length limit and exits non-zero when any batch fails.
dirty=""
if [ "${#changed[@]}" -gt 0 ]; then
  if ! dirty="$(printf '%s\0' "${changed[@]}" | xargs -0 git -C "$root" status --porcelain --)"; then
    printf 'dirty-scope check could not run; refusing rather than assuming a clean tree\n' >&2
    dirty="dirty-scope check failed"
  fi
fi

# The capture runs last, after the scope it pins is resolved. A second capture
# in the same review returns the first value (audit-scope-digest.sh owns that),
# so re-running this script mid-review changes nothing.
D_SCOPE="$("$root/.gaia/scripts/audit-scope-digest.sh" --capture --root "$root" --member "$member" --base "$KEY_BASE")" || D_SCOPE=""
[ -n "$D_SCOPE" ] || printf 'could not capture a scope digest; the earned clearance write will refuse\n' >&2
printf 'D_SCOPE=%s\n' "$D_SCOPE"

for path in ${full_changed[@]+"${full_changed[@]}"}; do
  printf 'FULL_CHANGED=%s\n' "$path"
done
for path in ${changed[@]+"${changed[@]}"}; do
  printf 'CHANGED=%s\n' "$path"
done
if [ -n "$dirty" ]; then
  printf 'DIRTY IN REVIEW SCOPE:\n%s\n' "$dirty" >&2
  printf '%s\n' "$dirty" | while IFS= read -r line; do
    printf 'DIRTY=%s\n' "$line"
  done
fi
exit 0
