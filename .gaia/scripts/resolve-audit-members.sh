#!/usr/bin/env bash
# resolve-audit-members.sh: Code Audit Team dispatch resolver.
#
# Turns the current branch's diff into the DISPATCHED MEMBER SET, the deduped,
# lexically-sorted set of auditor member names that own at least one changed
# file. The local merge gate (pr-merge-audit-check.sh) and the member-aware
# GAIA-Audit status POST both consume this to require a per-member clearance
# for every dispatched member; a diff touching two members' surfaces cannot
# merge until BOTH clear.
#
# Usage:
#   resolve-audit-members.sh [--root <path>] [--base <ref>]
#     --root <path> The audited working root. Authoritative when supplied, and
#                   validated as a git checkout. Without it the root comes from
#                   the current working directory.
#     --base <ref>  Diff base override. Without it, the base is resolved the
#                   same way pr-merge-audit-check.sh does: the remote default
#                   branch (origin/HEAD, fallback main), then the merge-base of
#                   HEAD with it (fallback: local <default> merge-base).
#     --help | -h   Print this usage and exit.
#
# Output contract:
#   One dispatched member name per line on stdout, deduped and lexically
#   sorted. EMPTY stdout means zero-match: the entire diff is out of audit
#   scope.
#
#   Exit 0 covers every ANSWERABLE query, including an empty diff, an
#   unresolvable diff base, and an unknown flag, so consumers can parse stdout
#   unconditionally there. Exit 2 means the query is UNANSWERABLE: the audited
#   root does not resolve, from --root or from cwd. Nothing lands on stdout and
#   one diagnostic line lands on stderr. A caller must never read a non-zero
#   exit as an empty member set: "I could not answer" is not "nobody is owed",
#   and a gate that conflates them clears a diff no dispatched member read.
#
# Dispatch algorithm, per changed file, in two precedence tiers (owned by
# audit-scope.sh, sourced below):
#   1. Every CLAIMANT (non-default) member whose globs match the path wins,
#      first-match-wins over roster order.
#   2. Else, if the default member's own declared globs match the path, the
#      default member is added.
#   3. Else the file has no owner (out of scope). No routing decision
#      consults a hardcoded auditable-base literal; every member, the default
#      included, declares its domain in the roster.
#
# Roster-source precedence:
#   1. The `auditors:` block in <repo-root>/.gaia/audit-ci.yml, when present
#      and non-empty.
#   2. Otherwise the built-in fallback roster in audit-scope.sh. Its
#      maintainer-only entries sit inside `# gaia:maintainer-only` markers so
#      the release scrub strips them from the shipped script; an adopter's
#      built-in fallback is therefore the default (frontend) member and the
#      workflows member only.
#   The resolver iterates the roster GENERICALLY: it emits whatever member
#   names the roster defines and is not hard-coded to any specific member, so
#   an adopter adds a member with a config entry plus an agent file, no script
#   edit.
#
# Glob semantics (matched against repo-relative POSIX paths), mirroring the
# release scrub's globToRegex:
#   **/ -> (.*/)?  (any depth, INCLUDING zero segments, spanning /)
#   **  -> .*
#   *   -> [^/]*   (any run within one path segment, never crossing /)
# So `.gaia/**/*.sh` matches `.gaia/x.sh` and `.gaia/scripts/y.sh`;
# `.github/**/*.sh` matches a top-level `.github/x.sh` as well as
# `.github/workflows/y.sh` (the `**/` collapses to zero segments);
# `.specify/extensions/gaia/lib/*.sh` matches only direct children;
# `app/**` matches anything under app/.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. No `cd` (per .claude/rules/shell-cwd.md); the repo root is
# resolved via `git rev-parse --show-toplevel` and every git call is scoped
# to it with `git -C`.

set -euo pipefail

# --- Parse arguments ----------------------------------------------------------

BASE_OVERRIDE=""
ROOT_OVERRIDE=""

print_usage() {
  cat <<'USAGE'
Usage: resolve-audit-members.sh [--root <path>] [--base <ref>]
  Emits the dispatched auditor member set (one name per line, sorted) for the
  current branch's diff. Empty output = entire diff out of scope. Exit 0 on
  every answerable query; exit 2 when the audited root does not resolve.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      # `[ -z "$2" ]` is not redundant with the arity check, and the asymmetry
      # with `--base` below is deliberate. `--root "$R"` with R unset (QUOTED,
      # so the word survives) arrives as $#=2 with an empty $2; read as "no
      # override" it would answer from a root the caller never named, which is
      # the mangled-query shape resolve-audit-spawn.sh:147-166 also fails
      # closed on. The root decides WHICH TREE the answer describes, so a
      # mangled one is unanswerable, not a fallback.
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "resolve-audit-members: --root requires a <path> argument" >&2
        exit 2
      fi
      ROOT_OVERRIDE="$2"
      shift 2
      ;;
    --base)
      if [ "$#" -lt 2 ]; then
        echo "resolve-audit-members: --base requires a <ref> argument" >&2
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
      echo "resolve-audit-members: unrecognized argument '$1'" >&2
      print_usage >&2
      exit 0
      ;;
  esac
done

# --- Resolve the repo root -----------------------------------------------
#
# --root is authoritative when supplied and is validated here; otherwise the
# root comes from cwd. Either way, a root that does not resolve makes the whole
# query unanswerable, so it fails closed: nothing on stdout, one line on
# stderr, exit 2. Empty stdout is reserved for the real answer "nothing in this
# diff is in audit scope", and the member-aware gates read an empty set as
# "nobody is owed a clearance".

if [ -n "$ROOT_OVERRIDE" ]; then
  repo_root="$(git -C "$ROOT_OVERRIDE" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$repo_root" ]; then
    echo "resolve-audit-members: --root '$ROOT_OVERRIDE' is not a git repository" >&2
    exit 2
  fi
else
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$repo_root" ]; then
    echo "resolve-audit-members: the working directory is not a git repository; pass --root <path>" >&2
    exit 2
  fi
fi

# --- Load the shared ownership classifier ------------------------------------
#
# Resolved from this script's OWN on-disk location, never cwd, never
# $repo_root: the bats suites run this script with cwd inside a sandbox that
# has no .claude/ at all. Absent or unreadable module: this resolver is a
# query, not a gate, so it fails safe to its existing empty-stdout contract
# rather than crash. (The merge gate, not this resolver, is where an absent
# module must deny.)
# Bracketed in `set +e` because errexit is armed above: a module that is present
# but unparseable abandons the shell AT the load, so an `-f` test ahead of it
# proves nothing and the fail-safe below is never reached. Testing what the
# modules DEFINE routes absent and unparseable to the same empty-stdout exit.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -z "$_lib_dir" ]; then
  exit 0
fi
set +e
# shellcheck source=/dev/null
[ -f "$_lib_dir/audit-scope.sh" ] && . "$_lib_dir/audit-scope.sh" 2>/dev/null
# shellcheck source=/dev/null
[ -f "$_lib_dir/audit-base-provenance.sh" ] && . "$_lib_dir/audit-base-provenance.sh" 2>/dev/null
set -e
# Probe each module's LAST definition, not the first symbol this script calls.
# A truncated copy parses as far as the truncation and defines every function
# ahead of it, so a probe of an early export answers yes for a copy missing what
# the call it gates will itself reach, and the run then dies at that inner call
# instead of taking the empty-stdout exit. The last definition is the one probe
# that needs no reasoning about which internal call goes how deep.
type audit_owners_for_paths >/dev/null 2>&1 || exit 0
type audit_provenance_empty_is_decisive >/dev/null 2>&1 || exit 0

audit_scope_init "$repo_root"

# --- Resolve the diff base + changed files -----------------------------------

# The base is the repository's advertised DEFAULT branch, deliberately, and not
# the branch this pull request merges into. Membership is safe wide: a base
# below the pull request's own fork point only adds files, and every extra file
# can only add a member to the spawn set, which is the fail-closed direction --
# an over-dispatched member reviews a diff it did not owe, while an
# under-dispatched one leaves a surface unreviewed and the merge looking
# audited. The specialists' own self-skip base agrees with this one for the
# same reason, since a member that skips while membership still demands its
# marker deadlocks the merge.
#
# The eligibility set the machinery-waive abuse-check reads
# (.claude/hooks/lib/audit-dispositions.sh) reaches the opposite answer from
# this same principle, and the difference is a property of the consumer rather
# than of the derivation: there a wider set WAIVES more findings into prose
# instead of filing them, so wide is the loose direction and that set scopes to
# the pull request's own base. The two are not accidentally different.
#
# The anchor is supplied to the shared resolver as an explicit `default-branch`
# argument here, rather than being implicit in a private merge-base chain, so
# a narrowing to `pr-record` shows up as a diff to this literal rather than as
# a silent change in behavior.
resolve_base() {
  local prov prov_trust prov_anchor prov_base
  prov="$(audit_resolve_base_provenance "$repo_root" default-branch "$BASE_OVERRIDE")" || prov=""
  # shellcheck disable=SC2034 # trust and anchor are part of the pinned three-field idiom; this consumer's answer never changes with either
  IFS=$'\t' read -r prov_trust prov_anchor prov_base <<< "$prov" || true
  printf '%s' "$prov_base"
}

base="$(resolve_base)"
[ -n "$base" ] || exit 0

# `-z`, because this list decides MEMBERSHIP and a quoted path fails open.
# Under git's default core.quotePath, `diff --name-only` C-quotes any path
# carrying non-ASCII or control bytes and emits the surrounding double quotes
# as literal characters, so `ete.ts` with accents arrives as the token
# "\303\251t\303\251.ts". That token matches no member's remit glob, the
# classifier below names no owner for it, and a pull request whose only
# in-remit change is such a file resolves an EMPTY member set. That is quiet
# rather than loud: resolve-audit-spawn.sh treats an empty set as "nobody owns
# anything here" and falls through to its ownerless probe, which spawns the
# default member. So the file is reviewed by a member whose remit excludes it
# while the specialist that owns it is never named, and the merge completes
# looking audited. `-z` disables
# quoting outright rather than narrowing it -- `core.quotePath=false` still
# quotes a path containing a quote, a backslash, or a control byte -- and the
# `tr` is what turns the NUL-terminated output back into the newline-delimited
# list every consumer below reads. Same spelling the roster's own definitions
# use (.claude/agents/code-audit-*.md).
#
# Quote-safe is not the same as faithful to every path, and the `tr` is where
# the difference lives: a path containing a literal newline survives `-z` and
# is then split back into two ownerless tokens, so membership resolves empty
# for it exactly as it did before. That is not a regression (the quoted
# spelling produced one ownerless token instead of two) and closing it means
# consuming the NUL stream without the round-trip, which every consumer below
# would have to want. code-audit-frontend.md records the same residue against
# its own eligibility set.
changed="$(git -C "$repo_root" diff --name-only -z "${base}...HEAD" 2>/dev/null | tr '\0' '\n' || true)"
[ -n "$changed" ] || exit 0

# --- Dispatch: batch-classify every changed path, collect unique owners -----
#
# Deduped, lexically-sorted member names. Empty input -> empty output (the
# batch predicate emits nothing for an ownerless path; `awk` here drops the
# "-" placeholder rather than the member name).

printf '%s\n' "$changed" | audit_owners_for_paths \
  | awk -F'\t' '$2 != "-" { print $2 }' \
  | LC_ALL=C sort -u
