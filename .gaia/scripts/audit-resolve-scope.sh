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
# confinement, which refuses a multi-command block naming `git`, a `git` call inside a
# command substitution, and a command name computed at runtime, however the
# block's git calls are spelled. A script invoked by its literal path runs
# regardless of what it does inside, and its git calls stay under shellcheck
# and bats instead of in prose.
#
# Usage:
#   <root>/.gaia/scripts/audit-resolve-scope.sh --member <name> --root <root>
#       [--review-path <pathspec>]... [--skip-full-base] [--base-override <ref>]
#       [--eligibility [--finding-path <path>]...]
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
#   --eligibility     Also resolve the default member's waive-eligibility set:
#                     the whole-PR fork point against the branch the pull
#                     request merges into (ELIG_BASE) and every path it
#                     changes, unfiltered (ELIG_CHANGED). No other option in
#                     THIS script consults `gh`; the base resolver every run
#                     invokes may itself call `gh api` when GH_TOKEN and
#                     GITHUB_REPOSITORY are both set, which is what the
#                     suite's "gh is never called" probe depends on being
#                     unset.
#   --finding-path    A finding's repo-relative path to answer "did this pull
#                     request change it" for, against the eligibility set.
#                     Repeatable. Requires --eligibility.
#
# Output (stdout), one KEY=value per line, in this order:
#   AUDIT_ROOT FULL_BASE BASE_REF BASE_REASON KEY_REF ANCHOR_TREE BASE_SHA
#   KEY_BASE AUDIT_KEY ELIG_BASE D_SCOPE, then one FULL_CHANGED=<path> per
#   whole-PR path, one CHANGED=<path> per review-scope path, one
#   ELIG_CHANGED=<path> per eligibility path, one
#   DEBT_ORIGIN_CHANGED=<1|0|unknown> <path> per --finding-path, one
#   DIRTY=<status line> per dirty in-scope entry, its path raw rather than
#   quoted. An unresolved scalar prints with an empty value: AUDIT_KEY is empty
#   whenever KEY_BASE or the branch is undeterminable, a detached HEAD among
#   them, and every artifact keyed on it is skipped fail-open. FULL_BASE is
#   omitted under --skip-full-base; ELIG_BASE and both eligibility lists are
#   omitted without --eligibility.
#
# Exit status:
#   0  resolved. Warnings about an empty base or a failed capture go to stderr
#      and do not change the status, because each consumer downstream already
#      refuses on the empty value it would receive. An eligibility base that
#      does not resolve, or whose diff fails, is one of these: ELIG_BASE prints
#      empty and every verdict is `unknown`, which disengages the waive rather
#      than stopping the audit that reads it.
#   1  the membership base is unresolvable, the base-provenance resolver it
#      comes from is missing, or a diff listing either changed-path list fails.
#      Nothing after it runs: an empty FULL_BASE or a failed diff makes the
#      list empty at status 0, which reads exactly like a pull request that
#      touched nothing in the member's remit, and a self-skip there writes no
#      marker at all. The stderr line names which of the causes it hit.
#   2  usage error (a --finding-path without --eligibility among them), or a
#      --root this script refuses.
#
# Confinement: the script derives its own tree from its on-disk location and
# refuses a --root that does not resolve to that same tree. A member can
# therefore never resolve one tree's scope with another tree's machinery, the
# "review one tree, certify another" shape the working root exists to prevent.
# The comparison is physical (`cd && pwd -P`, the tree's portable idiom; neither
# `realpath` nor `readlink -f` is guaranteed on macOS), so a symlinked spelling
# of the right tree passes.

_ars_usage() {
  printf 'usage: audit-resolve-scope.sh --member <name> --root <root> [--review-path <pathspec>]... [--skip-full-base] [--base-override <ref>] [--eligibility [--finding-path <path>]...]\n' >&2
}

member=""
root_arg=""
root_given=0
skip_full_base=0
base_override=""
eligibility=0
review_paths=()
finding_paths=()
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
    --eligibility)
      eligibility=1; shift ;;
    --finding-path)
      [ "$#" -ge 2 ] || { _ars_usage; exit 2; }
      finding_paths+=("$2"); shift 2 ;;
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
if [ "${#finding_paths[@]}" -gt 0 ] && [ "$eligibility" -eq 0 ]; then
  printf 'audit-resolve-scope: --finding-path requires --eligibility\n' >&2
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

# Each diff and the status write to a file first, so their exit status is read.
# A process substitution discards it, and a failed diff then yields an empty
# list at status 0.
ars_tmp="$(mktemp -d "${TMPDIR:-/tmp}/audit-resolve-scope.XXXXXX")" || {
  printf 'audit-resolve-scope: could not create a temporary directory\n' >&2
  exit 1
}
trap 'rm -rf "$ars_tmp"' EXIT

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
  if ! git -C "$root" diff --name-only -z "${FULL_BASE}...HEAD" > "$ars_tmp/full" 2>"$ars_tmp/full.err"; then
    printf 'could not list the whole pull request (%s...HEAD): %s; membership scope is unresolvable, do NOT self-skip\n' \
      "$FULL_BASE" "$(head -1 "$ars_tmp/full.err")" >&2
    exit 1
  fi
  while IFS= read -r -d '' path; do
    full_changed+=("$path")
  done < "$ars_tmp/full"
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

# The artifact key a member reads its re-run ledger by. Printed rather than
# derived member-side, because deriving it means sourcing a library, which is a
# multi-command block.
AUDIT_KEY=""
if [ -n "$KEY_BASE" ] && [ -f "$self_root/.gaia/scripts/audit-key-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$self_root/.gaia/scripts/audit-key-lib.sh"
  AUDIT_KEY="$(gaia_audit_key "$KEY_BASE" "$root" 2>/dev/null)" || AUDIT_KEY=""
fi
printf 'AUDIT_KEY=%s\n' "$AUDIT_KEY"

# The eligibility set decides which out-of-scope findings the default member's
# machinery waive may cover, so it is taken against the branch this pull
# request MERGES INTO, never the advertised default: on a pull request stacked
# on another branch, a default-branch fork point hands the waive every file the
# base branch changed. A declared base counts only when its remote-tracking ref
# resolves, since a bare local branch of the same name could sit on this pull
# request's own commits and empty the set.
#
# The ladder is deliberately not the verify side's
# (.claude/hooks/lib/audit-base-provenance.sh): its `origin/<default>` arm is a
# short revspec a local branch of that name shadows, where the verify side
# reads the fully-qualified ref.
#
# Unlike FULL_BASE, an unresolvable ELIG_BASE does not stop the script. The
# default member's self-skip is oracle-based, so an empty base costs the waive
# brake and nothing else. The base is tested, never the diff's emptiness: git
# resolves an empty left side to HEAD, so an unresolved base and a resolved
# base with no differences both yield an empty diff, and only one of them
# means "unknown".
elig_changed=()
if [ "$eligibility" -eq 1 ]; then
  pr_branch=""
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    pr_branch="$GITHUB_BASE_REF"
  elif command -v gh >/dev/null 2>&1; then
    pr_branch="$( (cd "$root" && gh pr view --json baseRefName --jq '.baseRefName') 2>/dev/null || true)"
  fi
  elig_ref=""
  if [ -n "$pr_branch" ] && git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/${pr_branch}" >/dev/null 2>&1; then
    elig_ref="refs/remotes/origin/${pr_branch}"
  fi
  default_branch="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  [ -n "$default_branch" ] || default_branch="main"
  primary_ref="${elig_ref:-origin/${default_branch}}"
  fallback_ref="${elig_ref:-${default_branch}}"
  ELIG_BASE="$(git -C "$root" merge-base HEAD "$primary_ref" 2>/dev/null || git -C "$root" merge-base HEAD "$fallback_ref" 2>/dev/null || true)"
  if [ -z "$ELIG_BASE" ]; then
    printf 'no eligibility base against %s or %s: the machinery waive disengages and every provenance verdict is unknown\n' \
      "$primary_ref" "$fallback_ref" >&2
  elif ! git -C "$root" diff --name-only -z "${ELIG_BASE}...HEAD" > "$ars_tmp/elig" 2>"$ars_tmp/elig.err"; then
    printf 'could not list the eligibility set (%s...HEAD): %s; the machinery waive disengages and every provenance verdict is unknown\n' \
      "$ELIG_BASE" "$(head -1 "$ars_tmp/elig.err")" >&2
    ELIG_BASE=""
  else
    while IFS= read -r -d '' path; do
      elig_changed+=("$path")
    done < "$ars_tmp/elig"
  fi
  printf 'ELIG_BASE=%s\n' "$ELIG_BASE"
fi

# Three-dot against HEAD: the clearance digest is computed over HEAD's tracked
# content, so the review list must name HEAD's changes, not the working tree's
# and not an advanced ref tip's.
changed=()
if [ -n "$BASE_SHA" ]; then
  if ! git -C "$root" diff --name-only -z "${BASE_SHA}...HEAD" -- ${review_paths[@]+"${review_paths[@]}"} > "$ars_tmp/review" 2>"$ars_tmp/review.err"; then
    printf 'could not list the review increment (%s...HEAD): %s; review scope is unresolvable\n' \
      "$BASE_SHA" "$(head -1 "$ars_tmp/review.err")" >&2
    exit 1
  fi
  while IFS= read -r -d '' path; do
    changed+=("$path")
  done < "$ars_tmp/review"
fi

# `Read` returns working-tree bytes while the clearance attests to HEAD, so a
# review over a dirty file certifies content nobody read. Only the review list
# is checked, never the whole tree. This fails closed: a status that cannot run
# reports the sentinel rather than reading as clean. xargs keeps a large list
# under the argument-length limit and exits non-zero when any batch fails.
# -z keeps each path raw, matching the CHANGED lines a member filters by the
# same globs; without it a path holding a space or a non-ASCII byte is quoted.
# A rename record, which carries its original path as a second record, cannot
# arise: status reports one only when both paths are in the pathspec, and a
# staged rename's new path is not in HEAD, so it is never in the review list.
dirty=()
if [ "${#changed[@]}" -gt 0 ]; then
  if ! printf '%s\0' "${changed[@]}" | xargs -0 git -C "$root" status --porcelain -z -- > "$ars_tmp/dirty"; then
    printf 'dirty-scope check could not run; refusing rather than assuming a clean tree\n' >&2
    dirty=("dirty-scope check failed")
  else
    while IFS= read -r -d '' rec; do
      dirty+=("$rec")
    done < "$ars_tmp/dirty"
  fi
fi

# The capture runs last, after the scope it pins is resolved. A second capture
# in the same review returns the first value (audit-scope-digest.sh owns that),
# so re-running this script mid-review changes nothing.
D_SCOPE="$("$root/.gaia/scripts/audit-scope-digest.sh" --capture --root "$root" --member "$member" --base "$KEY_BASE")" || D_SCOPE=""
[ -n "$D_SCOPE" ] || printf 'could not capture a scope digest; a gating member'"'"'s earned clearance write will refuse without one\n' >&2
printf 'D_SCOPE=%s\n' "$D_SCOPE"

for path in ${full_changed[@]+"${full_changed[@]}"}; do
  printf 'FULL_CHANGED=%s\n' "$path"
done
for path in ${changed[@]+"${changed[@]}"}; do
  printf 'CHANGED=%s\n' "$path"
done
for path in ${elig_changed[@]+"${elig_changed[@]}"}; do
  printf 'ELIG_CHANGED=%s\n' "$path"
done
# Whole-string equality against the set, never a prefix or substring test. An
# unresolved base answers `unknown`, never `0`: `0` asserts the pull request did
# not touch the path, which an unresolved base cannot assert.
for finding in ${finding_paths[@]+"${finding_paths[@]}"}; do
  verdict="unknown"
  if [ -n "$ELIG_BASE" ]; then
    verdict="0"
    for path in ${elig_changed[@]+"${elig_changed[@]}"}; do
      if [ "$path" = "$finding" ]; then
        verdict="1"
        break
      fi
    done
  fi
  printf 'DEBT_ORIGIN_CHANGED=%s %s\n' "$verdict" "$finding"
done
if [ "${#dirty[@]}" -gt 0 ]; then
  printf 'DIRTY IN REVIEW SCOPE:\n' >&2
  printf '%s\n' "${dirty[@]}" >&2
  for line in "${dirty[@]}"; do
    printf 'DIRTY=%s\n' "$line"
  done
fi
exit 0
