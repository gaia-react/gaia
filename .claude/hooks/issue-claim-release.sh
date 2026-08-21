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
# cwd-relative source that misses would leave cmd_targets_foreign_repo
# undefined, and the foreign-repo check would fall through rather than bail,
# so a --repo other-org/other-repo invocation would resolve THIS repo's pull
# request and strip labels here. Undefined after the source is fail-closed.
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
[ -n "${_lib:-}" ] && [ -f "$_lib/repo-scope.sh" ] && . "$_lib/repo-scope.sh"
type cmd_targets_foreign_repo >/dev/null 2>&1 || exit 0
cmd_targets_foreign_repo "$cmd" && exit 0

# Pull the pull-request reference: the first token after `merge` that neither
# starts with `-` nor is the value of a preceding value-taking flag. Taking
# the first non-flag token instead would read `gh pr merge --repo x/y 1498`
# as a reference of `x/y`, which fails and silently releases nothing.
tail_re='gh[[:space:]]+pr[[:space:]]+merge[[:space:]]*(.*)$'
args=""
if [[ "$cmd" =~ $tail_re ]]; then
  args="${BASH_REMATCH[1]}"
fi

# Every value-taking flag, and only those. Checked against gh's own help
# output rather than recalled: -m is --merge, a BOOLEAN, so listing it here
# would make `-m 1498` skip the reference and resolve the current branch
# instead. -A/--author-email and -F/--body-file do take values, so omitting
# them would make the value itself the reference.
value_flags=" -R --repo -A --author-email -b --body -F --body-file -t --subject --match-head-commit "
ref=""
skip_next=0
# Word splitting is wanted here; pathname expansion is not. Without set -f,
# `--body *` would glob against the repo root and a filename could become the
# reference.
set -f
for tok in $args; do
  if [ "$skip_next" = 1 ]; then
    skip_next=0
    continue
  fi
  case "$tok" in
    -*)
      case "$value_flags" in
        *" $tok "*) skip_next=1 ;;
      esac
      continue
      ;;
    *)
      ref="$tok"
      break
      ;;
  esac
done
set +f

# Pin the read and the write to THIS repository so the two can never
# straddle. Resolved once, from the hook's own cwd, which a `cd` inside the
# tool command never changes.
home=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ -n "$home" ] || exit 0

# A URL reference is the one form --repo cannot contain: gh resolves the
# repository from the URL and ignores the flag. Left alone, a merged
# sibling-repo pull request read by URL would strip THIS repository's
# unrelated issue of the same number, because the label write resolves here.
# So accept a URL only when it names the home repo, reduced to its number;
# an unrecognized shape exits rather than guessing.
url_re='^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/([^/]+/[^/]+)/pull/([0-9]+)$'
case "$ref" in
  *://*)
    if [[ "$ref" =~ $url_re ]] && [ "${BASH_REMATCH[1]}" = "$home" ]; then
      ref="${BASH_REMATCH[2]}"
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

# GitHub's own closing keywords, case-insensitive, followed by whitespace and
# #<digits>.
issue_re='(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved)[[:space:]]+#[0-9]+'
nums=$(printf '%s' "$body" | grep -oiE "$issue_re" 2>/dev/null | grep -oE '[0-9]+' 2>/dev/null | sort -u)

[ -n "$nums" ] || exit 0

echo "$nums" | while IFS= read -r n; do
  [ -n "$n" ] || continue
  gh issue edit "$n" --repo "$home" --remove-label in-progress >/dev/null 2>&1 || true
done

exit 0
