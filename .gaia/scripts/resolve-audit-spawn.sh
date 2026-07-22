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
#   resolve-audit-spawn.sh [--base <ref>] [--no-carry-forward]
#     --base <ref>  Diff base override. Forwarded to resolve-audit-members.sh
#                   AND honored by this script's own ownerless probe below.
#     --no-carry-forward
#                   Skip the digest-marker-presence filter entirely and emit
#                   the unfiltered dispatch set, byte-for-byte. The frontend
#                   member's self-skip probe uses this: it must key on "the
#                   diff does not dispatch me", never on "I was already
#                   cleared", so that a member omitted for being pre-cleared
#                   can still be deliberately spawned to re-review.
#     --help | -h   Print this usage and exit 0. This is NOT a dispatch
#                   query: its stdout is never a member list.
#
# Output contract:
#   One Code Audit Team member (agent) name per line, deduped and lexically
#   sorted (LC_ALL=C, inherited verbatim from the dispatch resolver). Exit code
#   is 0 on EVERY path, so callers parse stdout unconditionally.
#
#   EMPTY stdout carries TWO meanings: EITHER nothing in this diff is
#   auditable (no member is owed), OR every dispatched member's own
#   valid current-digest earned marker is already present (nothing left to
#   spawn). The script writes no clearance artifact on any path (mints
#   nothing).
#
#   stderr carries advisories only, never part of the answer: the fail-closed
#   warnings below, the freshness advisory below, and the dispatch resolver's
#   own diagnostics passed through.
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
#     and names >=1 member          -> that output, filtered by the
#                                      digest-marker-presence check below
#                                      (unless --no-carry-forward), never
#                                      re-sorted or renamed.
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
# .claude/hooks/pr-merge-audit-check.sh, via the shared classifier both
# consult):
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
#     4. Otherwise classify every changed path via the shared out-of-scope
#        allowlist predicate. Any path outside {wiki/, .claude/, .specify/,
#        .gaia/, docs/, root *.md} is IN SCOPE and prints the default member.
#        All paths out of scope prints nothing.
#   The default member on this path is not a roster assumption and not
#   per-member special-casing: it mirrors the deny-hook's own hardcoded
#   legacy fallback, which is the sole authority on what clears that path.
#   The classifier module unavailable: fails closed to the default member,
#   the same class of answer as every other unusable-query path below.
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
NO_CARRY_FORWARD=0

print_usage() {
  cat <<'USAGE'
Usage: resolve-audit-spawn.sh [--base <ref>] [--no-carry-forward]
  Emits the Code Audit Team SPAWN set (one member name per line, sorted) for
  the current branch's diff: the members to proactively spawn before
  `gh pr merge`. Empty output means EITHER nothing in this diff is auditable
  (no member is owed) OR every dispatched member's current-digest marker is
  already present (nothing left to spawn). --no-carry-forward skips the
  digest-marker-presence filter and emits the unfiltered dispatch set,
  byte-for-byte. Exit 0 always.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-carry-forward)
      NO_CARRY_FORWARD=1
      shift
      ;;
    --base)
      # `[ -z "$2" ]` is not redundant with the arity check. `--base "$REF"` with
      # REF unset (QUOTED, so the word survives) arrives as $#=2 with an empty
      # $2, which would otherwise set BASE_OVERRIDE="" and be silently treated as
      # "no override at all" -- a mangled query answered from a base the caller
      # never asked for. The arity check alone only catches the UNQUOTED mangle,
      # where the empty word vanishes before the script sees it. Both shapes are
      # the same operator error and both must fail closed.
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
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

# --- Freshness advisory: HEAD behind origin/main ---------------------------
#
# This script runs immediately before every dispatch wave, which makes it the
# one cheap place to notice a stale branch. A branch that falls behind main
# during a long run audits clean, and only then needs a rebase to merge; the
# rebase pulls main's changes to member-owned files into the branch, rotates
# those members' content digests, and invalidates every marker the audit just
# earned. The whole round is spent again.
#
# Advisory only. Auditing an older tree deliberately is legitimate, so this
# warns and never blocks: it does not change the member set on stdout and does
# not change the exit status, which stays 0 on every path.
#
# No `git fetch` here. The oracle runs before every dispatch wave and must stay
# fast and offline-safe, so the comparison reads the local `origin/main` ref
# exactly as it stands; a stale ref that yields no warning is an accepted false
# negative. `origin/main` not resolving at all (an adopter clone, a different
# default branch, no remote) emits nothing, the same fail-open answer as every
# other uncertainty here.
warn_if_behind_origin_main() {
  local behind
  git -C "$repo_root" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1 || return 0
  behind="$(git -C "$repo_root" rev-list --count HEAD..refs/remotes/origin/main 2>/dev/null || true)"
  # Non-numeric or zero: nothing to say. Also swallows a `rev-list` failure,
  # which returns an empty count.
  case "$behind" in
    '' | 0 | *[!0-9]*) return 0 ;;
  esac
  echo "resolve-audit-spawn: branch is $behind commits behind origin/main; rebase before dispatching or you will re-audit." >&2
}

warn_if_behind_origin_main || true

resolver="$repo_root/.gaia/scripts/resolve-audit-members.sh"

# --- Load the shared ownership classifier + digest engine + clearance reader
#
# Resolved from this script's OWN on-disk location, never cwd, never
# $repo_root. Absent or unreadable module: the ownerless probe below fails
# closed to the default member (unaffected), and digest_marker_filter below
# degrades to a pass-through, same as its other unusable-query branches.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-scope.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-scope.sh"
fi
# The digest-marker-presence filter's own dependencies: the digest engine
# (audit_digests_all) and the clearance reader (clearance_member_cleared).
# Absent -> digest_marker_filter passes the member list through unchanged:
# this script is a query, not a gate, and MINTS NOTHING on any path.
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-digest.sh"
fi
if [ -n "$_lib_dir" ] && [ -f "$_lib_dir/audit-clearance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_lib_dir/audit-clearance.sh"
fi

# --- Digest batch (parallel arrays; bash 3.2 has no associative arrays) ----

_DIGEST_MEMBER=()
_DIGEST_VALUE=()

# _load_member_digests: populates the parallel arrays above from ONE
# audit_digests_all walk (directive PERF-001), scoped to $repo_root. Returns
# 1 (arrays left empty) when the digest engine is unavailable or the batch
# fails/returns nothing (a missing sha256 tool, an unloadable classifier, a
# git failure).
_load_member_digests() {
  command -v audit_digests_all >/dev/null 2>&1 || return 1
  local batch line
  batch="$(audit_digests_all "$repo_root" 2>/dev/null)" || return 1
  [ -n "$batch" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    _DIGEST_MEMBER[${#_DIGEST_MEMBER[@]}]="${line%%$'\t'*}"
    _DIGEST_VALUE[${#_DIGEST_VALUE[@]}]="${line#*$'\t'}"
  done <<EOF
$batch
EOF
  return 0
}

# _member_digest <member> -> that member's digest on stdout, exit 0; exit 1
# (empty stdout) when the member is absent from the loaded batch.
_member_digest() {
  local want="$1" i=0
  while [ "$i" -lt "${#_DIGEST_MEMBER[@]}" ]; do
    if [ "${_DIGEST_MEMBER[$i]}" = "$want" ]; then
      printf '%s\n' "${_DIGEST_VALUE[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# --- The digest-marker-presence filter (mints nothing) ---------------------
#
# Reads a newline-separated member list on $1, prints the members whose valid
# CURRENT-digest earned marker is NOT already present. This is the digest
# analog of the deleted carry-forward cf_filter: a simple presence check, no
# anchor selection, no delta computation, no ancestry check. Pure query: the
# digest batch and the clearance reader only read.
#
# The digest lib, the clearance lib, or the digest batch itself being
# unavailable disables the whole feature and passes the list through
# unchanged, degrading to today's spawn-everyone behavior; matches the old
# jq-absent degrade the deleted carry-forward filter used.
digest_marker_filter() {
  local members="$1" m out="" digest

  if ! command -v clearance_member_cleared >/dev/null 2>&1 || ! _load_member_digests; then
    printf '%s' "$members"
    return 0
  fi

  while IFS= read -r m; do
    [ -n "$m" ] || continue
    digest="$(_member_digest "$m")" || digest=""
    if [ -n "$digest" ] && clearance_member_cleared "$repo_root" "$digest" "$m"; then
      continue
    fi
    out="${out}${m}
"
  done <<EOF
$members
EOF

  printf '%s' "$out"
  return 0
}

# --- The ownerless probe ---------------------------------------------------

ownerless_probe() {
  local default_branch base changed path

  if ! command -v audit_out_of_scope_allowlisted >/dev/null 2>&1; then
    echo "resolve-audit-spawn: ownership classifier unavailable, failing closed to code-audit-frontend" >&2
    echo "code-audit-frontend"
    return 0
  fi

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
    audit_out_of_scope_allowlisted "$path" && continue
    echo "code-audit-frontend"
    return 0
  done <<EOF
$changed
EOF

  return 0
}

# --- Delegate to the dispatch resolver, guarded on the exec bit -----------

if [ -x "$resolver" ]; then
  set --
  [ -n "$BASE_OVERRIDE" ] && set -- --base "$BASE_OVERRIDE"
  # The resolver's stderr passes THROUGH deliberately. Only stdout is the
  # contract, so its diagnostics cost the caller nothing, and swallowing them
  # would leave an operator debugging "why was my specialized member not
  # spawned?" with no signal at all: a malformed `auditors:` block in
  # .gaia/audit-ci.yml makes the resolver warn and return an empty set, and this
  # script would then quietly fall through to the ownerless probe.
  members="$(bash "$resolver" "$@" || true)"

  # Branch the three states on whether the RESOLVER named anyone, captured
  # BEFORE the digest-marker-presence filter, never on the post-filter list.
  # The filter may legitimately empty a non-empty resolver set (every member
  # already cleared), and the fail-closed answers (an unresolvable base, an
  # unreadable roster) live in the ownerless probe, which must stay reachable
  # ONLY when the resolver itself named nobody.
  resolver_named=0
  [ -n "$members" ] && resolver_named=1

  if [ "$resolver_named" -eq 1 ]; then
    if [ "$NO_CARRY_FORWARD" -eq 0 ]; then
      members="$(digest_marker_filter "$members")"
    fi
    # The ownerless probe is now UNREACHABLE: once the resolver named anyone,
    # this exit fires regardless of whether the filter emptied the list.
    [ -n "$members" ] && printf '%s\n' "$members"
    exit 0
  fi
fi

# Reached ONLY when the resolver named nobody (or is absent/non-executable).
ownerless_probe
exit 0
