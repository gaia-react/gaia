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
#   Separately, on the digest-marker-presence filter's active path, the
#   filter appends one re-spawn breadcrumb per considered member to
#   .gaia/local/telemetry/audit-respawn.jsonl. A breadcrumb is not a
#   clearance artifact (only an audit member's own review ever writes one of
#   those), and the append never affects stdout or the exit status: it is
#   fail-open and silent on every path, exactly like the mints-nothing
#   guarantee above.
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
#   not in a git repo               -> same fail-closed answer as an unknown
#                                      flag, and for the same reason: the query
#                                      is unanswerable, so it must not answer
#                                      "nobody owed". The merge deny-hook
#                                      DENIES when its own member query cannot
#                                      be answered, so a spawn set of nobody
#                                      here names a set that gate rejects.
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
#   resolver exits non-zero         -> same fail-closed answer as an unknown
#                                      flag. A non-zero exit from the dispatch
#                                      resolver means it could not resolve the
#                                      audited root, so it does not know who is
#                                      owed; that is not an empty set.
#   resolver names nobody           -> run the ownerless probe.
#
# The ownerless probe (mirrors check_out_of_scope_pr in
# .claude/hooks/pr-merge-audit-check.sh, via the shared classifier both
# consult):
#   The merge deny-hook does NOT auto-allow on a zero-match dispatch. When
#   the dispatch resolver returns an EMPTY set, the deny-hook falls through
#   to a LEGACY single-signal gate that still requires the default member's
#   clearance unless the diff passes its own out-of-scope allowlist. So a diff
#   touching an IN-SCOPE-BUT-OWNERLESS file (a root Makefile, say: claimed by
#   no roster glob and admitted by no arm of the allowlist) resolves to an
#   EMPTY dispatched set yet STILL denies the merge without that clearance.
#   Answering "spawn nobody" there would deadlock the merge: the gate demands
#   a marker that nothing is ever spawned to produce. This probe closes that
#   hole by re-running the deny-hook's own allowlist logic locally:
#     1. Resolve the diff base the same way the resolver and the hook do
#        (honoring --base).
#     2. Base unresolvable -> the default member (the hook's bypass returns
#        1 there and the merge denies; fail-closed mirror).
#     3. Empty diff -> the default member (the hook's bypass treats an empty
#        diff as unusable input, not as "nothing to audit"; mirror it). The
#        arm itself records why splitting "unresolvable" from "empty" here is
#        a trap rather than the obvious cleanup it looks like.
#     4. Otherwise classify every changed path via the shared out-of-scope
#        allowlist predicate. Any path that predicate does not admit is IN
#        SCOPE and prints the default member; all paths admitted prints
#        nothing. The admitted set lives in one place, the predicate itself
#        (.claude/hooks/lib/audit-scope.sh), and is not restated here: a
#        second copy is what lets the probe and the gate drift apart.
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
# Not in a git repo -> there is no diff to classify, so the query is
# unanswerable and it fails closed to the default member, in the shape the
# --base and unknown-flag arms above use: a stderr line, the member on stdout,
# exit 0. The stdout lines ARE the spawn set, so a non-zero exit here would be
# a new contract rather than a fail-closed answer.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "resolve-audit-spawn: not in a git repository, failing closed to code-audit-frontend" >&2
  echo "code-audit-frontend"
  exit 0
fi

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

# --- Load the shared ownership classifier + base-provenance resolver +
#     digest engine + clearance reader
#
# Resolved from this script's OWN on-disk location, never cwd, never
# $repo_root. Absent or unreadable module: the ownerless probe below fails
# closed to the default member on an unavailable base resolver exactly as it
# already does on an unavailable classifier, and digest_marker_filter below
# degrades to a pass-through, same as its other unusable-query branches.
# Unreadable is not the only way a module fails: one that is PRESENT but
# unparseable abandons the shell at the load, so the `-f` tests below prove
# nothing on their own and none of the degrade paths above is ever reached.
# `set +e` across the whole group is what lets them run.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
set +e
if [ -n "$_lib_dir" ]; then
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/audit-scope.sh" ] && . "$_lib_dir/audit-scope.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/audit-base-provenance.sh" ] && . "$_lib_dir/audit-base-provenance.sh" 2>/dev/null
  # The digest-marker-presence filter's own dependencies: the digest engine
  # (audit_digests_all) and the clearance reader (clearance_member_cleared).
  # Absent -> digest_marker_filter passes the member list through unchanged:
  # this script is a query, not a gate, and MINTS NOTHING on any path.
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/audit-digest.sh" ] && . "$_lib_dir/audit-digest.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_lib_dir/audit-clearance.sh" ] && . "$_lib_dir/audit-clearance.sh" 2>/dev/null
fi
set -e

# The re-spawn breadcrumb ledger's shared writer. This one lives BESIDE this
# script, not under .claude/hooks/lib/ with the digest recipe above, so it is
# resolved from this script's own on-disk location directly rather than via
# $_lib_dir. Absent, unsourceable, or defective -> the breadcrumb is disabled
# and nothing else about the oracle changes; every call against it below is
# additionally guarded on `command -v gaia_respawn_record`, so a partially
# loaded or redefined lib can never make the oracle abort.
_respawn_lib="$(dirname "${BASH_SOURCE[0]}")/audit-respawn-lib.sh"
if [ -f "$_respawn_lib" ]; then
  # `set -u` and `set -e` are both relaxed for the source alone. An unset-variable
  # reference at the lib's top level aborts the shell where it stands, and so does
  # a parse error in a present-but-unparseable copy, so neither a trailing
  # `|| true` nor any guard below would ever be reached. Restored on the next
  # line, so the oracle's own body still runs under -eu.
  # Source-time output goes nowhere either. The lib is contracted to have no
  # side effects at source time, and this script's stdout IS its answer, so a
  # stray print there would corrupt the spawn set itself rather than merely
  # log noise.
  set +eu
  # shellcheck source=/dev/null
  . "$_respawn_lib" >/dev/null 2>&1
  set -eu
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

# _respawn_breadcrumb <member> <digest> <cleared>
#
# Appends one re-spawn breadcrumb for MEMBER to the ledger. The per-run
# context (ledger path, ts, branch, head, merge_base) is NOT re-derived here:
# it reads the plain variables of the same name that digest_marker_filter,
# its only caller, already resolved once above its member loop -- ordinary
# bash dynamic scoping, not a second computation. `command -v
# gaia_respawn_record` guards the write: an absent, unsourceable, or
# defective ledger lib disables the breadcrumb and changes nothing else.
# ALWAYS returns 0. The call site still wraps every call in `|| true` so a
# future edit here can never trip `set -euo pipefail`.
_respawn_breadcrumb() {
  command -v gaia_respawn_record >/dev/null 2>&1 || return 0
  gaia_respawn_record "$ledger" "$ts" "$branch" "$head" "$merge_base" "$1" "$2" "$3" || true
  return 0
}

# --- The digest-marker-presence filter (mints nothing) ---------------------
#
# Reads a newline-separated member list on $1, prints the members whose valid
# CURRENT-digest earned marker is NOT already present, and the members whose
# earned marker IS present but is outranked by a live same-digest refusal.
# This is the digest analog of the deleted carry-forward cf_filter: a simple
# presence check, no anchor selection, no delta computation, no ancestry
# check. Pure query: the digest batch and the clearance reader only read.
#
# Refusal precedence is the merge hook's rule (pr-merge-audit-check.sh reads
# the refusal family before the earned family), and this filter answers a
# different question for the same state, so the two must agree on it. They
# would not agree without the refusal read below: the writer publishes a
# refusal BESIDE any same-digest earned marker rather than replacing it, so a
# cleared-only filter reports "nobody owed" while the merge stays denied, and
# the operator is told there is no member left to run.
#
# The digest lib, the clearance lib, or the digest batch itself being
# unavailable disables the whole feature and passes the list through
# unchanged, degrading to today's spawn-everyone behavior; matches the old
# jq-absent degrade the deleted carry-forward filter used.
digest_marker_filter() {
  local members="$1" m out="" digest cleared ledger ts branch head merge_base

  # Both readers are probed, not just the first. An older clearance lib carries
  # `clearance_member_cleared` without `clearance_member_refused`, and a missing
  # function exits 127, which `!` inverts to true: the filter would then read
  # every member as un-refused and silently revert to the cleared-only behavior
  # this refusal read exists to correct, leaking one stderr line and nothing
  # else. Probing both degrades the whole filter instead, which is the answer
  # this branch already gives for every other unavailable dependency.
  if ! command -v clearance_member_cleared >/dev/null 2>&1 \
     || ! command -v clearance_member_refused >/dev/null 2>&1 \
     || ! _load_member_digests; then
    printf '%s' "$members"
    return 0
  fi

  # --- Re-spawn breadcrumb: per-run context, computed once ------------------
  #
  # What is recorded, once per considered member below: the member's name,
  # its content digest from the batch already loaded above, and whether a
  # valid current-digest earned marker cleared it -- the two facts this
  # filter already computes to decide whether to spawn the member, not a
  # second derivation. Alongside them, resolved ONCE here rather than per
  # member: a UTC timestamp, the branch, HEAD, and the merge-base of HEAD and
  # origin/main.
  #
  # The resolver never classifies. It does not decide whether a re-spawn came
  # from the branch's own edits or from absorbing a peer's merge; that
  # question is a query over the accumulated records (comparing merge_base
  # and digest across consecutive rows for the same branch and member),
  # answerable later without touching this write path.
  #
  # The write sits ONLY here, inside the branch this filter is already
  # active on, after both `command -v clearance_member_cleared` and
  # `_load_member_digests` have already succeeded above. Every other path
  # through this script -- the fail-closed answers, the ownerless probe,
  # `--no-carry-forward`, and this filter's own degrade branch just above --
  # writes nothing, because none of them derives a digest and none of them
  # has anything to record.
  #
  # Fail open and silent. Each lookup below is `2>/dev/null || true`-guarded:
  # a detached HEAD yields an empty branch, an unresolvable origin/main
  # yields an empty merge_base, and neither disables the breadcrumb.
  # `merge_base` reads refs/remotes/origin/main literally (matching the
  # freshness advisory above), never the ownerless probe's origin/HEAD
  # default-branch resolution, so the field has one meaning wherever it is
  # read. No `git fetch`: the oracle runs before every dispatch wave and must
  # stay fast and offline-safe. Nothing here may print to stdout or stderr,
  # change the member set, or trip `set -euo pipefail`; `_respawn_breadcrumb`
  # below is called with `|| true` for exactly that reason.
  ledger="$(gaia_respawn_ledger_path "$repo_root" 2>/dev/null || true)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  merge_base="$(git -C "$repo_root" merge-base HEAD refs/remotes/origin/main 2>/dev/null || true)"

  while IFS= read -r m; do
    [ -n "$m" ] || continue
    digest="$(_member_digest "$m")" || digest=""
    cleared=false
    if [ -n "$digest" ] && clearance_member_cleared "$repo_root" "$digest" "$m" \
       && ! clearance_member_refused "$repo_root" "$digest" "$m"; then
      cleared=true
    fi
    _respawn_breadcrumb "$m" "$digest" "$cleared" || true
    if [ "$cleared" = true ]; then
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
  local prov prov_trust prov_anchor prov_base changed path

  if ! command -v audit_out_of_scope_allowlisted >/dev/null 2>&1; then
    echo "resolve-audit-spawn: ownership classifier unavailable, failing closed to code-audit-frontend" >&2
    echo "code-audit-frontend"
    return 0
  fi

  if ! command -v audit_resolve_base_provenance >/dev/null 2>&1; then
    echo "resolve-audit-spawn: base-provenance resolver unavailable, failing closed to code-audit-frontend" >&2
    echo "code-audit-frontend"
    return 0
  fi

  prov="$(audit_resolve_base_provenance "$repo_root" default-branch "$BASE_OVERRIDE")" || prov=""
  # shellcheck disable=SC2034 # anchor is part of the pinned three-field idiom; this consumer's decision table never consults it
  IFS=$'\t' read -r prov_trust prov_anchor prov_base <<< "$prov" || true
  if [ -z "$prov_trust" ] || [ "$prov_trust" = "unresolvable" ]; then
    echo "code-audit-frontend"
    return 0
  fi

  # `-z` for the reason resolve-audit-members.sh states at its own copy of this
  # derivation, though NOT for the same consequence, and the difference is
  # worth stating so a reader does not carry the stronger claim here. This
  # probe fails CLOSED on a C-quoted token: the quoted form is not allowlisted,
  # so the loop below spawns the default member. What quoting costs here is
  # accuracy rather than coverage -- a pull request whose only change is an
  # allowlisted out-of-scope path spawns a member it does not need, because the
  # allowlist never gets to recognize the path. The flag is what lets this
  # probe answer the question it is actually asking.
  # The probe reads the base's provenance, not the diff's emptiness. An empty
  # range dispatches nobody only when the diff command exited zero AND the
  # trust token is `remote` or `supplied`; a `local` or `unresolvable` base
  # still dispatches the default member. `local` is untrustworthy concretely: a
  # local default branch that has already absorbed this branch's commits puts
  # the merge base at HEAD, so the range is empty for a pull request that
  # changes plenty.
  #
  # This probe exists to PREDICT the merge gate, and the two do NOT always
  # resolve the same range. The gate prefers the pull request's own recorded
  # base branch through the hosting API; this probe deliberately does not,
  # because it must stay offline-safe and runs before every dispatch wave. So a
  # zero-commit branch whose pull request targets a non-default branch can have
  # this probe answer "nobody" while the gate's own range is non-empty. The
  # gate denies, so the probe's answer merges nothing. On exactly that path the
  # gate's member set is empty by construction, so it falls through to its
  # legacy single-signal branch, whose reason lists the clearance signals it
  # did not find and names no member set at all; the operator has to work out
  # who is owed from the base. This work adds no recovery mechanism for that
  # shape and claims none exists.
  #
  # Neither this probe nor the gate owns a copy of the trust rule; both call
  # audit_provenance_empty_is_decisive, which is what keeps them from reaching
  # opposite verdicts on the same provenance.
  if ! changed="$(audit_provenance_changed_files "$repo_root" "$prov_base")"; then
    echo "code-audit-frontend"
    return 0
  fi
  if [ -z "$changed" ]; then
    if audit_provenance_empty_is_decisive "$prov_trust"; then
      return 0
    fi
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
  resolver_rc=0
  members="$(bash "$resolver" "$@")" || resolver_rc=$?

  # A NON-ZERO exit is not an empty set: the resolver could not resolve the
  # audited root, so it does not know who is owed. Fail closed to the default
  # member, the answer every other unanswerable query here gets. Falling to the
  # ownerless probe instead would re-derive the diff from the same root the
  # resolver just failed on, and answer with the same confidence it declined to
  # have.
  if [ "$resolver_rc" -ne 0 ]; then
    echo "resolve-audit-spawn: the dispatch resolver could not answer (exit ${resolver_rc}), failing closed to code-audit-frontend" >&2
    echo "code-audit-frontend"
    exit 0
  fi

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
