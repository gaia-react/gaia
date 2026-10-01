#!/usr/bin/env bash
# Whether a pull request comes from a fork, and the one refusal every local
# gate prints when it does. Sourced, never executed; does no work at source
# time beyond defining the message.
#
# Why a fork is refused rather than audited: every gate that runs after a fork
# head is checked out runs the hook and script copies in the working tree,
# which the fork authored, under the maintainer's credentials. No local gate
# can audit that safely, so each one refuses and names the manual path. The
# pre-checkout guard is the one consumer that acts while the tree is still the
# maintainer's own; the others refuse anyway, so a fork head that arrived some
# other way still never reaches an audit or a merge through them.
#
#   gaia_pr_is_cross_repository <pr-number-or-empty>
#     0  cross-repository (fork) pull request
#     1  same-repository pull request, or no pull request for the current
#        branch (empty argument only)
#     2  gh could not answer: absent, unauthenticated, network, a pull
#        request number gh cannot resolve, or an answer that is neither
#        `true` nor `false`. GAIA_CROSS_REPO_GH_ERROR then holds one line
#        naming the failure, for the caller's deny reason.
#
# An empty argument asks about the current branch of the working directory,
# which is gh's own default. The caller owns the working directory.
#
# Exit 1 for "no pull request" is read off gh's own wording, `no pull requests
# found`, because gh exits 1 for that and for a network failure alike. Any
# other non-zero answer is exit 2, so a gh whose wording changes makes the
# callers deny, never allow.

# shellcheck disable=SC2034 # GAIA_CROSS_REPO_GH_ERROR is read by the sourcing hook
if [ -z "${GAIA_CROSS_REPO_REFUSAL_MESSAGE+set}" ]; then
  readonly GAIA_CROSS_REPO_REFUSAL_MESSAGE='This pull request comes from a fork (cross-repository). GAIA never audits or merges a fork PR locally, because doing so would run the fork'"'"'s own harness code with your credentials. Manual path: review the harness diff by hand (.claude/, .gaia/, .github/, .specify/), then push the branch to origin so it becomes a same-repo pull request, and run the PR Merge Workflow on that.'
fi

GAIA_CROSS_REPO_GH_ERROR=''

gaia_pr_is_cross_repository() {
  local pr_number="${1-}" answer exit_status first_line
  GAIA_CROSS_REPO_GH_ERROR=''

  case "$pr_number" in
    '') ;;
    *[!0-9]*)
      GAIA_CROSS_REPO_GH_ERROR="'${pr_number}' is not a pull request number"
      return 2
      ;;
  esac

  if ! command -v gh >/dev/null 2>&1; then
    GAIA_CROSS_REPO_GH_ERROR='gh is not on PATH'
    return 2
  fi

  # stderr is folded into the capture so the "no pull requests found" wording
  # can be read on failure. On success a stray stderr line (an update notice)
  # would spoil the exact match below; the notifier is switched off for that
  # reason, and anything else that slips in still fails closed as exit 2.
  # ${pr_number:+...} keeps an empty argument from reaching gh as an empty
  # positional, which gh would reject rather than read as the current branch.
  exit_status=0
  answer=$(GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
    gh pr view ${pr_number:+"$pr_number"} --json isCrossRepository --jq .isCrossRepository \
    2>&1 </dev/null) || exit_status=$?
  answer="$(printf '%s' "$answer" | tr -d '\r')"

  if [ "$exit_status" -eq 0 ]; then
    case "$answer" in
      true) return 0 ;;
      false) return 1 ;;
    esac
    first_line="$(printf '%s\n' "$answer" | head -n 1)"
    GAIA_CROSS_REPO_GH_ERROR="gh pr view answered '${first_line}' for isCrossRepository, which is neither true nor false"
    return 2
  fi

  if [ -z "$pr_number" ]; then
    case "$answer" in
      *'no pull requests found'*) return 1 ;;
    esac
  fi

  first_line="$(printf '%s\n' "$answer" | head -n 1)"
  GAIA_CROSS_REPO_GH_ERROR="gh pr view exited ${exit_status}${first_line:+: ${first_line}}"
  return 2
}

#   gaia_cross_repo_deny_reason <pr-number-or-empty> <directory-or-empty>
#       <fork-lead> <undetermined-lead> <undetermined-tail> [<suffix>]
#     Runs gaia_pr_is_cross_repository and prints the caller's complete deny
#     reason: for a fork, <fork-lead> then the refusal message; when gh could
#     not answer, "<undetermined-lead> comes from a fork (<gh error>),
#     <undetermined-tail> If the pull request is a fork: " then the refusal
#     message. <suffix> ends either reason. Returns 0 after printing a reason,
#     1 with no output for a same-repository pull request.
#     A non-empty <directory> is where gh is asked from; one that cannot be
#     entered reads as gh not answering. The body runs in a subshell so that
#     cd never reaches the caller.
gaia_cross_repo_deny_reason() (
  pr_number="${1-}"
  directory="${2-}"
  fork_lead="${3-}"
  undetermined_lead="${4-}"
  undetermined_tail="${5-}"
  suffix="${6-}"
  fork_status=0

  if [ -n "$directory" ] && ! cd "$directory" 2>/dev/null; then
    GAIA_CROSS_REPO_GH_ERROR=''
    fork_status=2
  else
    gaia_pr_is_cross_repository "$pr_number" || fork_status=$?
  fi

  case "$fork_status" in
    1) return 1 ;;
    0) printf '%s' "${fork_lead}${GAIA_CROSS_REPO_REFUSAL_MESSAGE}${suffix}" ;;
    *) printf '%s' "${undetermined_lead} comes from a fork (${GAIA_CROSS_REPO_GH_ERROR:-gh could not answer}), ${undetermined_tail} If the pull request is a fork: ${GAIA_CROSS_REPO_REFUSAL_MESSAGE}${suffix}" ;;
  esac
)
