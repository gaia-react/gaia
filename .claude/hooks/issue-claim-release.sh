#!/bin/bash
# PostToolUse Bash hook: after a `gh pr merge` for THIS repo, strip the
# `in-progress` claim label from every issue the merged pull request closes.
# `in-progress` marks an issue as being actively worked; releasing it here
# means claiming and releasing never require a dedicated command, the merge
# itself is the release trigger.
#
# Unlike debt-sentinel-touch.sh, which fires on `gh pr merge` unconditionally
# because over-arming a staleness sentinel is harmless, this hook must confirm
# the merge actually landed before it acts: a `gh pr merge` rejected by branch
# protection or a pending check leaves the work in flight, and releasing the
# claim on that rejection would let a second person start it while the first
# is still mid-review. So it resolves the pull request with one `gh pr view`
# call and requires .state == "MERGED" before touching any label.
#
# Fire-and-forget after that: it NEVER blocks or fails a merge (PostToolUse,
# always exit 0). It touches no .gaia/local state, releasing a claim is a
# GitHub-side label write only.

# -e is intentionally omitted; all error-prone commands are individually
# guarded (|| true, 2>/dev/null) so this hook can never fail a merge.
set -uo pipefail

input=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

tool_name=$(echo "$input" | jq -r '.tool_name // ""' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

# Avoid the name `command`: it would shadow bash's `command` builtin.
cmd=$(echo "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Same construction as debt-sentinel-touch.sh / pr-merge-audit-check.sh: match
# `gh pr merge` only as a real shell invocation, at the very start of the
# command or immediately after a shell separator.
gh_verb='gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*'"$gh_verb"
start_re='^[[:space:]]*'"$gh_verb"
if [[ "$cmd" =~ $start_re ]]; then
  : # match at command start
elif [[ "$cmd" =~ $sep_re ]]; then
  : # match after a shell separator (incl. newline)
else
  exit 0
fi

# Source the lib from this script's own location, never from cwd. A
# cwd-relative source that misses would leave the boundary function undefined,
# and the foreign-repo check would fall through rather than bail, so a
# --repo other-org/other-repo invocation would resolve THIS repo's pull request
# and strip labels here. Undefined after the source is fail-closed.
#
# The boundary itself is checked further down, against the value the scan
# below reads, not against a regex over this whole string. A whole-string
# capture cannot tell which command in a multi-command tool call a flag belongs
# to, so `gh pr merge 5; gh issue list --repo other-org/x` reads as foreign
# under one while the merge itself targets home. The scan answers that
# precisely, and it is the only boundary read this hook needs: a `cd` or
# `git -C` redirection puts the merge behind an earlier command, which the
# scan's first-command contract already declines.
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
# shellcheck source=/dev/null
[ -n "${_lib:-}" ] && [ -f "$_lib/repo-scope.sh" ] && . "$_lib/repo-scope.sh"
type repo_slug_is_foreign >/dev/null 2>&1 || exit 0
type gaia_scan_gh_merge >/dev/null 2>&1 || exit 0

# Read the merge invocation with the lib's shared first-command scan, which
# hands back the pull-request reference and the `-R`/`--repo` value the merge
# itself carries, quoting and flag position already resolved the way the shell
# resolves them.
#
# It abstains rather than guessing on the two shapes it cannot read: a tool
# call whose first command is not the merge, and a single-dash flag cluster.
# Both abstentions cost this hook a release, which is a claim removed by hand;
# reading either one anyway costs a claim stripped off an issue in THIS
# repository that the merge never closed, silently and pointing at the wrong
# issue. `.claude/rules/issue-claim.md` documents the first cost to the reader
# who has to pay it.
gaia_scan_gh_merge "$cmd" || exit 0
ref="$GAIA_GH_MERGE_REF"
cmd_repo="$GAIA_GH_MERGE_REPO"

# Pin the read and the write to THIS repository so the two can never
# straddle. Resolved once, from the hook's own cwd, which a `cd` inside the
# tool command never changes.
# Both fields come from ONE call: gh identifies a repository as
# [HOST/]OWNER/REPO, so the slug alone does not name it. An adopter mirroring
# one repository between github.com and an enterprise host carries the same
# OWNER/REPO on both, and a merge on either would otherwise resolve the
# other's pull request of that number here. The host is the URL's authority.
# This call is the one that pays: the boundary check reads the scanned value
# and so runs below, not above. The resolver memoizes, so that check reuses
# this resolution rather than making a second `gh repo view`.
gaia_repo_scope_resolve_home || exit 0
home="$GAIA_REPO_SCOPE_HOME_SLUG"
home_host="$GAIA_REPO_SCOPE_HOME_HOST"
# GitHub resolves OWNER/REPO case-insensitively, so a merge spelled
# `gaia-react/GAIA` lands on the home repository and a case-sensitive
# comparison would read it as another one. Every comparison against `home`
# below uses this form; only the label write uses the exact spelling gh
# reported.
home_lc=$(printf '%s' "$home" | tr '[:upper:]' '[:lower:]')

# `--repo owner/repo` names the target itself, and gh honors it over cwd, so
# it decides the boundary alone. The value compared is the SCANNED one, which
# is why this sits after the scan rather than over the raw command text: the
# scan reads quoting and flag position the way the shell does, so it knows
# which command in the tool call the flag belongs to and it hands over a
# quoted value with its quotes already removed. A regex over the whole string
# has neither property, and both misreads land on the same act. A bare repo
# name is not accepted because gh rejects one outright, so no reachable
# invocation is lost.
#
# The comparison itself is the shared act-on-home one, host half included: an
# empty value means no explicit target, which is home.
repo_slug_is_foreign "$cmd_repo" && exit 0

# A URL reference is the one form --repo cannot contain: gh resolves the
# repository from the URL and ignores the flag. Left alone, a merged
# sibling-repo pull request read by URL would strip THIS repository's
# unrelated issue of the same number, because the label write resolves here.
# So accept a URL only when it names the home repo, reduced to its number;
# an unrecognized shape exits rather than guessing.
# The authority is captured and compared too, for the same reason the flag's
# host half is: the same OWNER/REPO served from another host is another
# repository, and matching on the slug alone would accept it.
url_re='^[a-zA-Z][a-zA-Z0-9+.-]*://([^/]+)/([^/]+/[^/]+)/pull/([0-9]+)$'
case "$ref" in
  *://*)
    if [[ "$ref" =~ $url_re ]] \
      && [ "$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')" = "$home_host" ] \
      && [ "$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')" = "$home_lc" ]; then
      ref="${BASH_REMATCH[3]}"
    else
      exit 0
    fi
    ;;
esac

# One gh pr view call, reused for both fields. No ref means the current
# branch, which is gh's own default when none is passed; --repo is omitted
# on that arm because gh rejects the flag without a selector, and cwd
# already resolves to the home repo.
if [ -n "$ref" ]; then
  pr_json=$(gh pr view --repo "$home" "$ref" --json state,body 2>/dev/null) || exit 0
else
  pr_json=$(gh pr view --json state,body 2>/dev/null) || exit 0
fi

state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null)
[ "$state" = "MERGED" ] || exit 0

body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null)

# GitHub's own closing keywords, case-insensitive. All three spellings its
# documentation gives are accepted after the keyword: a bare `#<n>`, the
# colon form `Closes: #<n>`, and the repository-qualified
# `Closes owner/repo#<n>`. Matching only the first left GitHub closing an
# issue while the claim stayed live, silently, which is the failure this
# hook exists to prevent one direction of.
#
# The left boundary is load-bearing: without it a body reading `left
# unresolved #<n>` matches as `resolved #<n>`, and GitHub closes nothing
# there, because it requires the keyword to stand as its own word. Releasing
# on that match strips a claim off work that is still in flight, which is the
# harm every guard here exists to prevent; this is the arm that reaches it
# through the pull-request BODY, while the scan and the repository checks
# above guard the arm that reaches it by resolving the wrong pull request.
#
# A qualifier is compared against the home repo before anything is released,
# because a `Fixes other-org/other-repo#<n>` closes an issue over there and
# releasing on it would strip THIS repo's unrelated issue of that number.
# The label write only ever reaches home, so a genuinely foreign qualifier
# is out of this hook's reach by construction and is dropped rather than
# followed.
issue_re='(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+'
nums=$(printf '%s' "$body" | grep -oiE "$issue_re" 2>/dev/null | while IFS= read -r m; do
  # Everything after the last whitespace and before the `#` is the
  # qualifier, and it is empty for both unqualified spellings.
  qual="${m%#*}"
  qual="${qual##*[[:space:]]}"
  if [ -n "$qual" ]; then
    [ "$(printf '%s' "$qual" | tr '[:upper:]' '[:lower:]')" = "$home_lc" ] || continue
  fi
  printf '%s\n' "${m##*#}"
done | sort -u)

[ -n "$nums" ] || exit 0

echo "$nums" | while IFS= read -r n; do
  [ -n "$n" ] || continue
  gh issue edit "$n" --repo "$home" --remove-label in-progress >/dev/null 2>&1 || true
done

exit 0
