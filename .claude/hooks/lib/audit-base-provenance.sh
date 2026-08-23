#!/usr/bin/env bash
# audit-base-provenance.sh: the one place that resolves a diff base together
# with its provenance for the Code Audit Team. Sourced, never executed; does no
# work at source time. Bash 3.2 compatible (macOS default). Never `cd`.
#
# Three functions:
#
#   audit_resolve_base_provenance <root> <anchor-request> [<supplied-base>]
#                                  [<record-base-branch>]
#       Walks the resolution ladder (supplied override, pull-request record,
#       default-branch) and prints ONE line answering three questions at once:
#       how much the base deserves to be trusted, which branch it was actually
#       taken against, and the base itself.
#
#   audit_provenance_changed_files <root> <base>
#       Answers "what changed": the repo-relative paths in <base>...HEAD.
#       Distinguishes a real empty change set (return 0, empty stdout) from a
#       diff that never ran at all (return 1), which a bare exit-status read
#       cannot tell apart from an empty answer.
#
#   audit_provenance_empty_is_decisive <trust>
#       Answers "does an empty change set at this trust level mean the merge
#       has nothing left to audit". The only definition of that predicate
#       tree-wide.
#
# Conflating the trust predicate (function 3) with the anchor (the second
# field function 1 prints) is a merge-gate bypass: the anchor names which
# branch the base was taken against, and only the trust predicate says whether
# an empty range against that base is decisive. A caller that infers
# decisiveness from the anchor reimplements function 3 badly and can disagree
# with it.
#
# Why a sibling of audit-scope.sh rather than an addition to it: that file's
# own header says it holds ownership classification alone and that mixing
# concerns there is itself a bypass. Base provenance is a different question.
# It lives under .claude/hooks/lib/ anyway, which is what gives it
# gate-machinery classification for free (audit-machinery.sh's
# AUDIT_MACHINERY_PATHS carries a .claude/hooks/lib/** prefix entry).
#
# Pinned caller idiom (bash 3.2 handles IFS=$'\t' read and <<<):
#
#   prov="$(audit_resolve_base_provenance "$root" default-branch "$BASE_OVERRIDE")" || prov=""
#   IFS=$'\t' read -r prov_trust prov_anchor prov_base <<< "$prov" || true
#
# An empty $prov leaves all three fields empty, which every consumer treats as
# unresolvable and fails closed on.
#
# No environment arm: this file reads no environment variable naming a base
# branch, on any path. The merge gate refuses an environment-sourced base by
# name, because an exported base-ref variable would let a caller shrink a
# fail-closed check's diff until every remaining path looked out of scope, and
# lifting an arm that read one would import that hole here. The disposition
# sidecar this ladder is generalized from keeps its own two-source read
# (GITHUB_BASE_REF under Actions, else the pull request's own record) at its
# own call site, and passes the resulting branch name in as
# <record-base-branch> instead.

# audit_resolve_base_provenance <root> <anchor-request> [<supplied-base>]
#                                [<record-base-branch>]
#
# stdout: exactly one line, three TAB-separated fields, one trailing newline,
# nothing else: <trust>\t<anchor>\t<base>.
#   <trust>  remote | local | supplied | unresolvable
#   <anchor> default-branch | pr-record -- which branch the base was actually
#            taken against, not what the caller asked for. pr-record only when
#            the record arm below produced the base; default-branch on every
#            other path, including supplied and unresolvable.
#   <base>   a 40-hex commit sha, empty exactly when <trust> is unresolvable.
#
# return: 0 on every resolvable path, including the unresolvable verdict --
# "I could not resolve a base" is an answer, not a failure. 2 on a usage error
# (empty <root>, <root> not a git work tree, an unrecognized
# <anchor-request>), printing nothing on stdout and one line on stderr.
# Callers are contractually required to treat any non-zero return as
# unresolvable and fail closed.
audit_resolve_base_provenance() {
  local root="$1" anchor_request="$2" supplied_base="${3:-}" record_base_branch="${4:-}"
  local default_branch resolved

  if [ -z "$root" ] || [ "$(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
    echo "audit_resolve_base_provenance: <root> must be a git work tree" >&2
    return 2
  fi
  case "$anchor_request" in
    default-branch | pr-record) ;;
    *)
      echo "audit_resolve_base_provenance: <anchor-request> must be default-branch or pr-record" >&2
      return 2
      ;;
  esac

  # 1. Supplied override, verified against this tree. A caller-named revision
  # this checkout cannot reach must never fall through to an empty diff read
  # as a trustworthy nothing.
  if [ -n "$supplied_base" ]; then
    resolved="$(git -C "$root" rev-parse --verify --quiet "${supplied_base}^{commit}" 2>/dev/null)"
    if [ -n "$resolved" ]; then
      printf 'supplied\tdefault-branch\t%s\n' "$resolved"
    else
      printf 'unresolvable\tdefault-branch\t\n'
    fi
    return 0
  fi

  # 2. Pull-request record. No bare-name arm here: that is exactly where a
  # local branch would slip in and narrow the answer, matching the merge
  # gate's existing record path.
  if [ "$anchor_request" = "pr-record" ] && [ -n "$record_base_branch" ] \
    && git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/${record_base_branch}" >/dev/null 2>&1; then
    resolved="$(git -C "$root" merge-base HEAD "refs/remotes/origin/${record_base_branch}" 2>/dev/null)"
    if [ -n "$resolved" ]; then
      printf 'remote\tpr-record\t%s\n' "$resolved"
      return 0
    fi
    # The ref verified but merge-base failed (unrelated histories, a shallow
    # HEAD). Falling through to the ladder below would hand a consumer a
    # resolved, WIDER default-branch base exactly where it denies today --
    # the fail-open direction the SPEC's `always` boundary forbids. Anchor
    # stays default-branch: no base was taken against the record, so
    # reporting pr-record would claim a derivation that never happened.
    printf 'unresolvable\tdefault-branch\t\n'
    return 0
  fi
  # A record branch whose remote-tracking ref does not verify never entered
  # the record path in the first place, so it falls through to the ladder
  # below exactly as a plain default-branch request would.

  # 3. Default-branch ladder.
  default_branch="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  [ -n "$default_branch" ] || default_branch="main"

  # The fully-qualified spelling is load-bearing, not pedantic (SEC-001,
  # reproduced on git 2.55.0). Git resolves the bare revspec origin/<name>
  # through refs/heads/ before refs/remotes/, so a local branch literally
  # named origin/main would supply the base here while
  # refs/remotes/origin/main still verifies, minting `remote` trust for a
  # purely local base. Never spell a remote-minting ref as origin/<name>
  # anywhere in this file.
  if git -C "$root" rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null 2>&1; then
    resolved="$(git -C "$root" merge-base HEAD "refs/remotes/origin/${default_branch}" 2>/dev/null)"
    if [ -n "$resolved" ]; then
      printf 'remote\tdefault-branch\t%s\n' "$resolved"
      return 0
    fi
  fi

  resolved="$(git -C "$root" merge-base HEAD "${default_branch}" 2>/dev/null)"
  if [ -n "$resolved" ]; then
    printf 'local\tdefault-branch\t%s\n' "$resolved"
    return 0
  fi

  printf 'unresolvable\tdefault-branch\t\n'
  return 0
}

# audit_provenance_changed_files <root> <base>
#
# stdout: newline-delimited repo-relative changed paths for <base>...HEAD.
# NUL-delimited derivation translated to newlines, inside a pipefail subshell
# so a git failure survives the pipe ($(...) alone discards NUL bytes, which
# is why the tr cannot move out of the substitution). The 2>/dev/null is
# required: without it a failed diff writes `fatal: ...` to the caller's
# stderr, which collides with the merge gate's pinned single-line stderr
# assertion for a permit diagnostic.
#
# return: 0 iff the diff command exited zero; 1 on any diff failure and on an
# empty <root> or <base>. Empty stdout with return 0 is a real empty change
# set; empty stdout with a non-zero return is never one.
audit_provenance_changed_files() {
  local root="$1" base="$2" out

  [ -n "$root" ] || return 1
  [ -n "$base" ] || return 1

  out="$(set -o pipefail; git -C "$root" diff --name-only -z "${base}...HEAD" 2>/dev/null | tr '\0' '\n')" || return 1
  printf '%s' "$out"
  return 0
}

# audit_provenance_empty_is_decisive <trust>
#
# return: 0 iff <trust> is remote or supplied; 1 otherwise (local,
# unresolvable, an empty string, anything unrecognized). Consults no anchor,
# reads no git, touches no filesystem.
#
# The only definition of "does an empty change set at this trust level mean
# there is nothing left to audit" tree-wide. Neither the spawn oracle nor the
# merge gate owns a copy, which is what keeps the two from reaching opposite
# verdicts about the same provenance.
audit_provenance_empty_is_decisive() {
  case "$1" in
    remote | supplied) return 0 ;;
    *) return 1 ;;
  esac
}
