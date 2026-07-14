#!/usr/bin/env bash
# resolve-audit-spawn.sh: Code Audit Team SPAWN oracle.
#
# Answers "who must audit this diff?" so an operator (or an instruction
# surface) can proactively spawn the right Code Audit Team members BEFORE
# `gh pr merge`, instead of discovering them only when the merge deny-hook
# fires. This is the spawn-side counterpart to
# .gaia/scripts/resolve-audit-members.sh, the DISPATCH resolver it wraps.
#
# Usage:
#   resolve-audit-spawn.sh [--base <ref>]
#     --base <ref>  Diff base override. Forwarded to resolve-audit-members.sh
#                   AND honored by this script's own ownerless probe below.
#     --help | -h   Print this usage and exit 0. This is NOT a dispatch
#                   query: its stdout is never a member list.
#
# Output contract:
#   One Code Audit Team member (agent) name per line, deduped and lexically
#   sorted (LC_ALL=C, inherited verbatim from the dispatch resolver). EMPTY
#   stdout means nothing in this diff is auditable: no member is owed. Exit
#   code is 0 on EVERY path, so callers parse stdout unconditionally.
#
# Branch table:
#   --help / -h                     -> usage on stdout, exit 0.
#   unknown flag                    -> warning on stderr, then the default
#                                      member on stdout, exit 0. Fail-closed:
#                                      an unparseable query must never answer
#                                      "nobody owed". (The dispatch resolver
#                                      itself answers an unknown flag with
#                                      EMPTY stdout, which is exactly why
#                                      this script parses its own arguments
#                                      instead of inheriting that behavior.)
#   --base with no <ref>            -> same fail-closed answer as an unknown
#                                      flag, and for the same reason: it is an
#                                      unparseable query, so it must not answer
#                                      "nobody owed". Empty stdout is a real
#                                      answer here ("no member is owed"), never
#                                      an error channel.
#   not in a git repo               -> nothing, exit 0. The merge deny-hook
#                                      also exits permissively when it cannot
#                                      resolve a SHA, so there is nothing to
#                                      mirror here.
#   dispatch resolver is executable
#     and names >=1 member          -> that output, VERBATIM. Never filtered,
#                                      re-sorted, renamed, or special-cased.
#                                      This is the roster-generic path: any
#                                      member the roster defines, today's or
#                                      an adopter's future one, flows through
#                                      untouched.
#   resolver absent, OR present
#     without the exec bit          -> fall to the ownerless probe below.
#                                      Delegation is guarded on `[ -x ]`, not
#                                      on existence, mirroring the merge
#                                      deny-hook's own guard
#                                      (`[ -x .gaia/scripts/resolve-audit-members.sh ]`).
#                                      Running a non-executable resolver
#                                      anyway would return a full member set
#                                      where the merge gate requires only its
#                                      legacy-gate clearance, spawning a
#                                      member no gate requires.
#   resolver names nobody           -> run the ownerless probe.
#
# The ownerless probe (mirrors check_out_of_scope_pr in
# .claude/hooks/pr-merge-audit-check.sh):
#   The merge deny-hook does NOT auto-allow on a zero-match dispatch. When
#   the dispatch resolver returns an EMPTY set, the deny-hook falls through
#   to a LEGACY single-signal gate that still requires the default member's
#   clearance unless the diff passes its own out-of-scope allowlist (wiki/,
#   .claude/, .specify/, .gaia/, docs/, root-level *.md). So a diff touching
#   an IN-SCOPE-BUT-OWNERLESS file (a root Dockerfile, .gitignore, anything
#   under public/**) resolves to an EMPTY dispatched set yet STILL denies the
#   merge without that clearance. Answering "spawn nobody" there would
#   deadlock the merge: the gate demands a marker that nothing is ever
#   spawned to produce. This probe closes that hole by re-running the
#   deny-hook's own allowlist logic locally:
#     1. Resolve the diff base the same way the resolver and the hook do
#        (honoring --base).
#     2. Base unresolvable -> the default member (the hook's bypass returns
#        1 there and the merge denies; fail-closed mirror).
#     3. Empty diff -> the default member (the hook's bypass treats an empty
#        diff as unusable input, not as "nothing to audit"; mirror it).
#     4. Otherwise classify every changed path with the hook's own `case`
#        arms. Any path outside {wiki/, .claude/, .specify/, .gaia/, docs/,
#        root *.md} is IN SCOPE and prints the default member. All paths
#        out of scope prints nothing.
#   The default member on this path is not a roster assumption and not
#   per-member special-casing: it mirrors the deny-hook's own hardcoded
#   legacy fallback, which is the sole authority on what clears that path.
#   Keep this probe's `case` arms in sync with check_out_of_scope_pr() in
#   .claude/hooks/pr-merge-audit-check.sh if that allowlist ever changes.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. No `cd` (per .claude/rules/shell-cwd.md); the repo root is
# resolved via `git rev-parse --show-toplevel` and every git call is scoped
# to it with `git -C`.
#
# gaia:maintainer-only:start
# Sibling bats suite: .gaia/scripts/tests/resolve-audit-spawn.bats.
# gaia:maintainer-only:end

set -euo pipefail

# --- Parse arguments -----------------------------------------------------
#
# Mirrors resolve-audit-members.sh's own shift-based loop. That loop
# consumes the positional parameters, so "$@" is NOT forwarded bare to the
# resolver below; it is reconstructed explicitly from BASE_OVERRIDE instead.

BASE_OVERRIDE=""

print_usage() {
  cat <<'USAGE'
Usage: resolve-audit-spawn.sh [--base <ref>]
  Emits the Code Audit Team SPAWN set (one member name per line, sorted) for
  the current branch's diff: the members to proactively spawn before
  `gh pr merge`. Empty output = nothing in this diff is auditable, no member
  is owed. Exit 0 always.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      if [ "$#" -lt 2 ]; then
        # Fail-closed, exactly as the unknown-flag arm below. A `--base` with no
        # ref is an unparseable query, and empty stdout is NOT neutral here: the
        # output contract above defines it as "no member is owed", so answering
        # empty would tell the caller to spawn nobody while the merge deny-hook
        # still demands markers. That is the silent-bypass class this script
        # exists to eliminate. Reachable via an unquoted empty ref
        # (`--base $REF` with REF unset), the standard way a caller mangles a
        # flag argument.
        echo "resolve-audit-spawn: --base requires a <ref> argument, failing closed to code-audit-frontend" >&2
        echo "code-audit-frontend"
        exit 0
      fi
      BASE_OVERRIDE="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      # Fail-closed: an unparseable query must never answer "nobody owed".
      echo "resolve-audit-spawn: unrecognized argument '$1', failing closed to code-audit-frontend" >&2
      echo "code-audit-frontend"
      exit 0
      ;;
  esac
done

# --- Resolve the repo root -------------------------------------------------
#
# Not in a git repo -> nothing to diff; emit nothing and exit 0.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || exit 0

resolver="$repo_root/.gaia/scripts/resolve-audit-members.sh"

# --- The ownerless probe ---------------------------------------------------

ownerless_probe() {
  local default_branch base changed path

  if [ -n "$BASE_OVERRIDE" ]; then
    base="$BASE_OVERRIDE"
  else
    default_branch="$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
    [ -n "$default_branch" ] || default_branch="main"
    base="$(git -C "$repo_root" merge-base HEAD "origin/${default_branch}" 2>/dev/null \
      || git -C "$repo_root" merge-base HEAD "${default_branch}" 2>/dev/null \
      || true)"
  fi
  if [ -z "$base" ]; then
    echo "code-audit-frontend"
    return 0
  fi

  changed="$(git -C "$repo_root" diff --name-only "${base}...HEAD" 2>/dev/null || true)"
  if [ -z "$changed" ]; then
    echo "code-audit-frontend"
    return 0
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
      wiki/*|.claude/*|.specify/*|.gaia/*|docs/*) continue ;;
      */*) echo "code-audit-frontend"; return 0 ;;
      *.md) continue ;;
      *) echo "code-audit-frontend"; return 0 ;;
    esac
  done <<EOF
$changed
EOF

  return 0
}

# --- Delegate to the dispatch resolver, guarded on the exec bit -----------

if [ -x "$resolver" ]; then
  set --
  [ -n "$BASE_OVERRIDE" ] && set -- --base "$BASE_OVERRIDE"
  members="$(bash "$resolver" "$@" 2>/dev/null || true)"
  if [ -n "$members" ]; then
    printf '%s\n' "$members"
    exit 0
  fi
fi

ownerless_probe
exit 0
