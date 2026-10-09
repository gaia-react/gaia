#!/usr/bin/env bash
# audit-base-provenance.sh: the one place that resolves a diff base together
# with its provenance for the Code Audit Team. Sourced, never executed; does no
# work at source time. Bash 3.2 compatible (macOS default). Never `cd`, with one
# stated exception: each gh call here runs inside a subshell that changes into
# <root>, because gh derives the repository and the current branch's pull
# request from its working directory, and the repository must equal the status
# poster's own derivation byte for byte.
#
# The base-ladder functions:
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
#   audit_github_repository <root>
#   audit_github_pr_base_branch <root>
#   audit_github_base_tip <root> <repository> <base-branch>
#       The GitHub-verified base: the repository GAIA-Audit is posted to, the
#       pull request's base branch name, and that branch's current tip, each
#       read through gh. The merge gate and the status poster trust nothing
#       else for the base.
#
#   audit_local_base_reference <root>
#       The fully-qualified local remote-tracking ref every other caller
#       computes against.
#
# Conflating the trust predicate (audit_provenance_empty_is_decisive) with the
# anchor (the second field audit_resolve_base_provenance prints) is a
# merge-gate bypass: the anchor names which branch the base was taken against,
# and only the trust predicate says whether an empty range against that base
# is decisive. A caller that infers decisiveness from the anchor reimplements
# the predicate badly and can disagree with it.
#
# Why the GitHub-verified base sits beside the ladder and is not one of its
# rungs: a ladder falls through from a rung that fails to the next, and the
# gate must never fall through from a failed GitHub lookup to a local ref. A
# stale or forged local ref would then supply the base the gate trusts. The
# GitHub functions return a failure the caller turns into a denial, and the
# ladder stays the answer for callers that deliberately accept a local base.
# They live in this file so base derivation keeps one home.
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

  # The fully-qualified spelling is load-bearing, not pedantic (reproduced on
  # git 2.55.0). Git resolves the bare revspec origin/<name>
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
# assertion for a permit diagnostic. --no-renames keeps a rename's old path in
# the list, so moving app/ source to an out-of-scope path cannot read as an
# out-of-scope-only change set.
#
# return: 0 iff the diff command exited zero; 1 on any diff failure and on an
# empty <root> or <base>. Empty stdout with return 0 is a real empty change
# set; empty stdout with a non-zero return is never one.
audit_provenance_changed_files() {
  local root="$1" base="$2" changed_paths

  [ -n "$root" ] || return 1
  [ -n "$base" ] || return 1

  changed_paths="$(set -o pipefail; git -C "$root" diff --name-only -z --no-renames "${base}...HEAD" 2>/dev/null | tr '\0' '\n')" || return 1
  printf '%s' "$changed_paths"
  return 0
}

# audit_provenance_empty_is_decisive <trust>
#
# return: 0 iff <trust> is remote, supplied or github; 1 otherwise (local,
# unresolvable, an empty string, anything unrecognized). Consults no anchor,
# reads no git, touches no filesystem.
#
# The only definition of "does an empty change set at this trust level mean
# there is nothing left to audit" tree-wide. Neither the merge gate nor the
# member resolver owns a copy, which is what keeps the two from reaching
# opposite verdicts about the same provenance.
audit_provenance_empty_is_decisive() {
  case "$1" in
    remote | supplied | github) return 0 ;;
    *) return 1 ;;
  esac
}

# --- GitHub-verified base and the local base reference -------------------------

# _audit_github_fail <message>: the single stderr line of a gh failure, and the
# gh-failure return code every caller maps to a denial.
_audit_github_fail() {
  printf 'audit-base-provenance: %s\n' "$1" >&2
  return 5
}

# _audit_github_deadline_seconds: 15 seconds per function call. It sits well
# under the 60-second hook timeout and leaves room for the two gh calls a gate
# run makes. GAIA_AUDIT_GH_DEADLINE_SECONDS may only lower it (an integer from
# 1 to 15; anything else is ignored), which keeps the expiry path testable
# without a quarter-minute wait.
_audit_github_deadline_seconds() {
  local seconds="${GAIA_AUDIT_GH_DEADLINE_SECONDS:-15}"
  case "$seconds" in
    '' | *[!0-9]*) seconds=15 ;;
  esac
  if [ "$seconds" -lt 1 ] || [ "$seconds" -gt 15 ]; then
    seconds=15
  fi
  printf '%s' "$seconds"
}

# _audit_github_run <output-file> <gh-argument>...
#
# Runs gh prompt-free in its own process group, writes its stdout to
# <output-file>, and kills the whole group when the deadline passes, so a
# hung gh and anything it spawned leave no orphan. Job control is switched on
# inside a subshell only (bash 3.2 gives a background job its own process
# group that way), never in the caller's shell.
#
# return: gh's own exit status; 124 when the deadline expired; 127 when gh is
# not on PATH.
_audit_github_run() {
  local output_file="$1" run_status
  shift
  command -v gh >/dev/null 2>&1 || return 127
  (
    set -m
    local tick_limit tick=0 gh_pid
    tick_limit=$(( $(_audit_github_deadline_seconds) * 10 ))
    GH_PROMPT_DISABLED=1 GIT_TERMINAL_PROMPT=0 gh "$@" >"$output_file" 2>/dev/null </dev/null &
    gh_pid=$!
    while kill -0 "$gh_pid" 2>/dev/null; do
      if [ "$tick" -ge "$tick_limit" ]; then
        kill -TERM -- "-$gh_pid" 2>/dev/null
        sleep 0.2
        kill -KILL -- "-$gh_pid" 2>/dev/null
        wait "$gh_pid" 2>/dev/null
        exit 124
      fi
      sleep 0.1
      tick=$((tick + 1))
    done
    wait "$gh_pid"
  ) 2>/dev/null
  run_status=$?
  return "$run_status"
}

# _audit_github_query <root> <description> <gh-argument>...
#
# Runs one gh call from <root> as its working directory (the stated cd
# exception) and prints its stdout on success. Prints nothing and returns 5
# with one stderr line otherwise.
_audit_github_query() {
  local root="$1" description="$2" output_file run_status answer
  shift 2
  output_file="$(mktemp "${TMPDIR:-/tmp}/audit-github.XXXXXX")" \
    || { _audit_github_fail "cannot create a temporary file for ${description}"; return; }
  ( cd "$root" 2>/dev/null && _audit_github_run "$output_file" "$@" )
  run_status=$?
  answer="$(cat "$output_file" 2>/dev/null)"
  rm -f "$output_file"
  case "$run_status" in
    0) ;;
    124) _audit_github_fail "gh timed out reading ${description}; run gh auth status and retry"; return ;;
    *) _audit_github_fail "gh failed reading ${description}; run gh auth status and retry"; return ;;
  esac
  [ -n "$answer" ] || { _audit_github_fail "gh returned nothing for ${description}"; return; }
  printf '%s\n' "$answer"
}

# audit_github_repository <root>
#
# stdout: owner/name of the repository GAIA-Audit is posted to, derived the way
# the status poster derives it. return: 0, or 5 with nothing on stdout.
audit_github_repository() {
  local repository
  repository="$(_audit_github_query "$1" "the repository" repo view --json nameWithOwner --jq .nameWithOwner)" \
    || return $?
  case "$repository" in
    *[!A-Za-z0-9._/-]* | */*/* | /* | */) _audit_github_fail "gh returned an unusable repository name"; return ;;
    */*) ;;
    *) _audit_github_fail "gh returned an unusable repository name"; return ;;
  esac
  printf '%s\n' "$repository"
}

# audit_github_pr_base_branch <root>
#
# stdout: the base branch name of the current branch's pull request. return: 0,
# or 5 with nothing on stdout.
audit_github_pr_base_branch() {
  local base_branch
  base_branch="$(_audit_github_query "$1" "the pull request base branch" pr view --json baseRefName --jq .baseRefName)" \
    || return $?
  if ! git check-ref-format "refs/remotes/origin/${base_branch}" 2>/dev/null; then
    _audit_github_fail "gh returned an unusable base branch name"
    return
  fi
  printf '%s\n' "$base_branch"
}

# audit_stale_cached_base <root> <github-base-branch>
#
# return: 0 when the branch's cached base name (branch.<branch>.gaia-audit-base)
# differs from the base GitHub reports, with the recovery command on stdout;
# 1 otherwise. The cache drives the local digest producers and GitHub drives the
# gate and the status poster, so a retargeted pull request leaves them keyed to
# different bases until the cache is unset.
audit_stale_cached_base() {
  local root="$1" github_base="$2" branch cached_name
  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || return 1
  cached_name="$(git -C "$root" config --get "branch.${branch}.gaia-audit-base" 2>/dev/null)" || return 1
  [ -n "$cached_name" ] && [ "$cached_name" != "$github_base" ] || return 1
  printf 'git config --unset branch.%s.gaia-audit-base\n' "$branch"
}

# audit_github_base_tip <root> <repository> <base-branch>
#
# stdout: the base branch's current tip, 40 lowercase hex. return: 0, or 5 on gh
# absence, an authentication or network failure, a non-40-hex answer or the
# deadline expiring, with one stderr line and nothing on stdout.
audit_github_base_tip() {
  local root="$1" repository="$2" base_branch="$3" tip
  if [ -z "$repository" ] || [ -z "$base_branch" ] \
    || ! git check-ref-format "refs/remotes/origin/${base_branch}" 2>/dev/null; then
    _audit_github_fail "no repository or usable base branch to look up"
    return
  fi
  tip="$(_audit_github_query "$root" "the base branch tip" api "repos/${repository}/branches/${base_branch}" --jq .commit.sha)" \
    || return $?
  case "$tip" in
    *[!0-9a-f]*) _audit_github_fail "gh returned a base tip that is not a commit id"; return ;;
  esac
  if [ "${#tip}" -ne 40 ]; then
    _audit_github_fail "gh returned a base tip that is not a commit id"
    return
  fi
  printf '%s\n' "$tip"
}

# audit_local_base_reference <root>
#
# stdout: refs/remotes/origin/<name>. The name is the per-branch cache
# (branch.<branch>.gaia-audit-base), else one gh lookup written back to that
# key, else the target of refs/remotes/origin/HEAD, else main. A detached HEAD
# skips the cache and gh. A failed lookup writes nothing, so the next call
# retries. return: 0, or 1 with one stderr line naming git fetch origin when
# the resolved ref does not verify.
#
# The fully-qualified spelling is the whole guard against a local branch
# literally named origin/<name> (see the default-branch arm above). There is no
# local-branch fallback.
audit_local_base_reference() {
  local root="$1" branch cached_name name reference

  branch="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || branch=""
  name=""
  if [ -n "$branch" ]; then
    cached_name="$(git -C "$root" config --get "branch.${branch}.gaia-audit-base" 2>/dev/null)" || cached_name=""
    if [ -n "$cached_name" ] && git check-ref-format "refs/remotes/origin/${cached_name}" 2>/dev/null; then
      name="$cached_name"
    else
      name="$(audit_github_pr_base_branch "$root" 2>/dev/null)" || name=""
      if [ -n "$name" ]; then
        git -C "$root" config "branch.${branch}.gaia-audit-base" "$name" 2>/dev/null || true
      fi
    fi
  fi
  if [ -z "$name" ]; then
    name="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  fi
  [ -n "$name" ] || name="main"

  reference="refs/remotes/origin/${name}"
  if ! git -C "$root" rev-parse --verify --quiet "${reference}^{commit}" >/dev/null 2>&1; then
    printf 'audit-base-provenance: %s does not exist locally; run git fetch origin\n' "$reference" >&2
    return 1
  fi
  printf '%s\n' "$reference"
}
