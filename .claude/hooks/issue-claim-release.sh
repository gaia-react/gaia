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
# shellcheck source=/dev/null
[ -n "${_lib:-}" ] && [ -f "$_lib/repo-scope.sh" ] && . "$_lib/repo-scope.sh"
type cmd_targets_foreign_repo >/dev/null 2>&1 || exit 0
cmd_targets_foreign_repo "$cmd" && exit 0

# Split the command into shell-like words. This is a real scan rather than a
# set of patterns over the raw text, and the difference is the whole point: a
# quote character opens a span in which whitespace, separators and the other
# quote character are all ordinary text, and a backslash escapes the
# character after it. Pattern-matching the raw text got this wrong once per
# spelling, always in the direction of reading part of one value, or part of
# a following command, as the pull-request reference.
#
# The scan starts at the beginning of the command, not at the position some
# pattern found the merge phrase at, because a textual occurrence of that
# phrase is not a place a command begins: `# <phrase> 5` on an earlier line,
# or the phrase inside an earlier command's quoted value, is text, and
# entering there resolves whatever number follows it, which is a pull request
# this merge never touched. So the scan cuts the command at every separator
# outside a quoted span and takes the FIRST piece whose own first three words
# are the merge verb; its remaining words are what gets parsed below. When no
# piece is a merge invocation, the phrase was only ever text and there is
# nothing to act on.
#
# The words that come out are unquoted, so nothing downstream needs to know
# quotes exist, and a `;` inside a squash subject stays text.

# Named once, above the loop: a `case` pattern cannot hold a `$'\n'` literal,
# and a command substitution in one would run per scanned character. The
# separator set below is the same set the arming match at the top of this
# hook uses, newline included, or the scan would disagree with the match
# about where a multi-line command ends.
NL=$'\n'
TAB=$'\t'
words=()
cur=()
matched=0

# Accept the piece currently in `cur` when it IS the merge invocation, and on
# acceptance hand its post-verb words to the parser below. Copied element by
# element rather than sliced: `"${cur[@]:3}"` on a three-word array is an
# unbound expansion under `set -u` on bash 3.2, which macOS still ships.
take_command() {
  [ "${#cur[@]}" -ge 3 ] || return 1
  [ "${cur[0]}" = "gh" ] && [ "${cur[1]}" = "pr" ] && [ "${cur[2]}" = "merge" ] || return 1
  local j=3
  while [ "$j" -lt "${#cur[@]}" ]; do
    words+=("${cur[$j]}")
    j=$((j + 1))
  done
  return 0
}

word=""
have_word=0
q=""
esc=0
i=0
while [ "$i" -lt "${#cmd}" ]; do
  c="${cmd:$i:1}"
  i=$((i + 1))
  if [ "$esc" = 1 ]; then
    word="$word$c"; have_word=1; esc=0; continue
  fi
  # Inside single quotes a backslash is literal, as in the shell itself.
  if [ "$c" = "\\" ] && [ "$q" != "'" ]; then
    esc=1; have_word=1; continue
  fi
  if [ -n "$q" ]; then
    if [ "$c" = "$q" ]; then q=""; else word="$word$c"; fi
    have_word=1
    continue
  fi
  case "$c" in
    '"'|"'") q="$c"; have_word=1 ;;
    ' '|"$TAB")
      [ "$have_word" = 1 ] && cur+=("$word")
      word=""; have_word=0
      ;;
    '&'|'|'|';'|"$NL")
      [ "$have_word" = 1 ] && cur+=("$word")
      word=""; have_word=0
      if take_command; then matched=1; break; fi
      cur=()
      ;;
    *) word="$word$c"; have_word=1 ;;
  esac
done
if [ "$matched" = 0 ]; then
  [ "$have_word" = 1 ] && cur+=("$word")
  take_command && matched=1
fi
[ "$matched" = 1 ] || exit 0

# Every value-taking flag, and only those. Checked against gh's own help
# output rather than recalled: -m is --merge, a BOOLEAN, so listing it here
# would make `-m 1498` skip the reference and resolve the current branch
# instead. -A/--author-email and -F/--body-file do take values, so omitting
# them would make the value itself the reference.
value_flags=" -R --repo -A --author-email -b --body -F --body-file -t --subject --match-head-commit "
ref=""
cmd_repo=""
skip_next=0
skip_flag=""
n=${#words[@]}
i=0
while [ "$i" -lt "$n" ]; do
  tok="${words[$i]}"
  i=$((i + 1))
  if [ "$skip_next" = 1 ]; then
    skip_next=0
    [ "$skip_flag" = repo ] && cmd_repo="$tok"
    skip_flag=""
    continue
  fi
  case "$tok" in
    -*=*)
      # `--flag=value` carries its value in the same word.
      flag="${tok%%=*}"
      case "$value_flags" in
        *" $flag "*)
          case "$flag" in
            -R|--repo) cmd_repo="${tok#*=}" ;;
          esac
          ;;
      esac
      ;;
    -*)
      case "$value_flags" in
        *" $tok "*)
          skip_next=1
          case "$tok" in
            -R|--repo) skip_flag=repo ;;
          esac
          ;;
      esac
      ;;
    *)
      # The first non-flag word is the reference, and the scan continues:
      # gh accepts flags in any position, so `merge 5 --repo other-org/gaia`
      # is an ordinary invocation and stopping here would leave the boundary
      # check below unarmed for every trailing spelling of the flag.
      [ -n "$ref" ] || ref="$tok"
      ;;
  esac
done

# Pin the read and the write to THIS repository so the two can never
# straddle. Resolved once, from the hook's own cwd, which a `cd` inside the
# tool command never changes.
home=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
[ -n "$home" ] || exit 0

# `--repo owner/repo` names the target itself, and gh honors it over cwd, so
# it decides the boundary alone. The shared guard above compares only the
# repo-NAME half, which classifies a same-named sibling (`--repo other-org/gaia`
# from a checkout named `gaia`, the ordinary fork topology) as home. That is
# the safe direction for the blocking guards sharing that lib, where home
# means enforce, and the wrong one here, where home means ACT: the hook would
# read THIS repo's pull request of that number and strip a claim off a ticket
# nobody touched. Compare the whole slug. A bare repo name is not accepted
# because gh rejects one outright, so no reachable invocation is lost.
#
# Known limit: a QUOTED flag value (`--repo="owner/repo"`) never reaches this
# arm. The shared guard's own capture keeps the quote characters, so its
# name-half comparison misses and it classifies the command foreign first.
# That direction releases nothing rather than releasing wrongly, and closing
# it means changing the comparison the nine blocking consumers share.
if [ -n "$cmd_repo" ]; then
  # A host-qualified value (github.com/owner/repo) names the same repo.
  case "$cmd_repo" in
    */*/*) cmd_repo="${cmd_repo#*/}" ;;
  esac
  [ "$cmd_repo" = "$home" ] || exit 0
fi

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
# on that match is the one way this hook can strip a claim off work that is
# still in flight, which is the harm every other guard here exists to
# prevent.
#
# A qualifier is compared against the home repo before anything is released,
# because a `Fixes other-org/other-repo#<n>` closes an issue over there and
# releasing on it would strip THIS repo's unrelated issue of that number.
# The label write only ever reaches home, so a genuinely foreign qualifier
# is out of this hook's reach by construction and is dropped rather than
# followed.
issue_re='(^|[^[:alnum:]_])(close|closes|closed|fix|fixes|fixed|resolve|resolves|resolved):?[[:space:]]+([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)?#[0-9]+'
home_lc=$(printf '%s' "$home" | tr '[:upper:]' '[:lower:]')
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
