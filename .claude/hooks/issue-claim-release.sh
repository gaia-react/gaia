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
# The scan reads the FIRST command in the tool call and requires that command
# to be the merge itself. Anything else, and the hook exits without touching
# a label.
#
# That is a deliberate retreat, and the reason is worth stating because the
# narrower rules all failed. Whatever sits ahead of the merge decides how the
# merge should be read, and reading it needs the shell's own semantics: a
# comment hides a command, a heredoc body is not a quoted span so its lines
# read as commands, `cd` and `(cd` and `pushd` decide which repository the
# merge lands in, and each of those is a construct rather than a spelling, so
# every rule naming one left the next one open. Each round of that cost a
# release onto an issue in THIS repository that the merge never closed, which
# is the exact harm the rest of this file exists to prevent.
#
# Requiring the merge to come first closes the whole class at once: there is
# no prefix left to misread, and every word the parser below sees comes from
# the merge invocation itself. That narrows the remaining grammar to gh's
# flags, which is smaller but is NOT closed by the `value_flags` enumeration
# on its own, because gh also clusters shorthands; the parser abstains on a
# cluster rather than modelling one. The cost is that `<something> && <merge>` in
# one tool call releases nothing. That shape is not how this repository
# merges (the workflow runs the merge as its own step), and the cost of
# missing one is a claim removed by hand, against a wrong release that is
# silent and points at the wrong issue.
#
# The words that come out are unquoted, so nothing downstream needs to know
# quotes exist, and a `;` inside a squash subject stays text.

# Named once, above the loop: a `case` pattern cannot hold a `$'\n'` literal,
# and a command substitution in one would run per scanned character. The
# newline is the load-bearing member of the set below: the arming match
# counts one as a separator, so without it here the scan would run past the
# end of a command that match already treats as several. The scan also cuts
# at a lone `&`, which the arming match does not accept before the verb; that
# asymmetry costs a background-started merge its release and never a wrong
# one, so it is the safe direction to differ in.
NL=$'\n'
TAB=$'\t'
words=()
cur=()
piece_closed=0

# Accept `cur` when it IS the merge invocation, and on acceptance hand its
# post-verb words to the parser below. Copied element by
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

# `${cmd:$i:1}` costs O(i), so indexing the whole string per character makes
# the scan quadratic, and this is a PostToolUse hook, so that cost is a
# synchronous stall on every merge. The command is whatever the tool call
# carried, and a block that writes a multi-kilobyte pull-request body before
# merging is ordinary, so the input is not small. Two things keep it cheap
# and neither changes what the state machine reads: bytes instead of
# characters, since every character this scan looks for is ASCII and a
# multibyte character's bytes are all non-ASCII, so they land in the current
# word intact; and one slice per block rather than per character, which
# leaves only a small quadratic term. macOS still ships bash 3.2, where both
# constants are several times CI's.
_prev_lc_all="${LC_ALL-}"
_had_lc_all="${LC_ALL+set}"
LC_ALL=C
BLOCK=256
n_cmd=${#cmd}
base=0
while [ "$base" -lt "$n_cmd" ]; do
  block="${cmd:$base:$BLOCK}"
  base=$((base + BLOCK))
  k=0
  n_block=${#block}
  while [ "$k" -lt "$n_block" ]; do
    c="${block:$k:1}"
    k=$((k + 1))
    # A backslash-newline is a line CONTINUATION: the shell drops both
    # characters rather than making the newline text. Appending it would put
    # a lone newline in the word stream, and the first non-flag word is the
    # reference, so a merge written across two lines would resolve a newline
    # and release nothing at all.
    if [ "$esc" = 1 ]; then
      esc=0
      [ "$c" = "$NL" ] && continue
      word="$word$c"; have_word=1; continue
    fi
    # Inside single quotes a backslash is literal, as in the shell itself.
    # `have_word` is deliberately NOT set here: at the backslash it is not yet
    # known whether a word follows it or a line continuation does, and marking
    # one either way puts an empty word into the stream on the continuation.
    # The escaped-character branch above marks it once a character survives.
    if [ "$c" = "\\" ] && [ "$q" != "'" ]; then
      esc=1; continue
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
        # An empty piece is no command at all: leading whitespace or a
        # newline, or the second character of `&&` / `||`. Keep scanning so
        # the FIRST real command is still the one that gets judged.
        [ "${#cur[@]}" -eq 0 ] && continue
        piece_closed=1; break 2
        ;;
      '#')
        # A word-initial unquoted `#` opens a COMMENT, so the shell drops it
        # and everything after it to the newline and gh never receives any of
        # it. Read as ordinary text those words reach the parser below, and a
        # `--repo` among them wins, because the parser keeps the LAST one it
        # sees and the shared guard above captures greedily. A foreign merge
        # whose trailing comment names this repository would then resolve THIS
        # repository's pull request of that number and strip claims here.
        # Mid-word the character is ordinary text, which is the shell's rule
        # too and is what keeps `fix#<n>` intact.
        #
        # Stopping the scan is the same retreat the separators take, and it is
        # required rather than convenient: skipping ahead to the newline would
        # let a comment that HIDES a leading command promote the words after
        # it into the first command. The merge has to be that command anyway,
        # so nothing beyond the comment was readable.
        [ "$have_word" = 1 ] && { word="$word$c"; continue; }
        piece_closed=1; break 2
        ;;
      *) word="$word$c"; have_word=1 ;;
    esac
  done
done
if [ "$_had_lc_all" = set ]; then LC_ALL="$_prev_lc_all"; else unset LC_ALL; fi
# The whole command was one piece, so its trailing word closes it.
if [ "$piece_closed" = 0 ]; then
  [ "$have_word" = 1 ] && cur+=("$word")
fi
# `cur` is the first command in the tool call. It has to BE the merge; the
# arming match above only proved the phrase appears somewhere a command could
# start, which a comment, a heredoc body line, and a quoted value all satisfy.
take_command || exit 0

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
    # A single-dash CLUSTER, which gh's flag library accepts and this parser
    # does not model. pflag reads a one-dash token letter by letter, and the
    # first value-taking shorthand in it swallows the rest of the token or
    # the next word: `-sRother-org/other-repo` is a squash merge of another
    # repository, and `-st 1234 5` gives `1234` to the subject rather than
    # making it the reference. Read here as one unknown flag, the first
    # spelling leaves the repository check unarmed and the second makes a
    # subject the reference, and both end in a label stripped off an issue in
    # THIS repository.
    #
    # Rejecting the whole shape rather than the letter `R` is deliberate:
    # matching R alone would close the spelling that was reported and leave
    # the one that was not, which is how the ten rounds before this went. A
    # token whose FIRST letter is value-taking is not a cluster (the rest is
    # that flag's value), so it falls through to the arms below.
    -[!-RAbFt]?*)
      exit 0
      ;;
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
    # A shorthand with its value attached: `-Rowner/repo` is the same
    # invocation as `-R owner/repo`. Only the repository shorthand is read
    # back; an attached value on another value-taking shorthand stays one
    # word and consumes nothing, which the arm below gets right by doing
    # nothing with it.
    -R?*)
      cmd_repo="${tok#-R}"
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
# Both fields come from ONE call: gh identifies a repository as
# [HOST/]OWNER/REPO, so the slug alone does not name it. An adopter mirroring
# one repository between github.com and an enterprise host carries the same
# OWNER/REPO on both, and a merge on either would otherwise resolve the
# other's pull request of that number here. The host is the URL's authority.
home_json=$(gh repo view --json nameWithOwner,url 2>/dev/null)
home=$(printf '%s' "$home_json" | jq -r '.nameWithOwner // ""' 2>/dev/null)
[ -n "$home" ] || exit 0
home_host=$(printf '%s' "$home_json" | jq -r '.url // ""' 2>/dev/null)
home_host="${home_host#*://}"
home_host="${home_host%%/*}"
home_host=$(printf '%s' "$home_host" | tr '[:upper:]' '[:lower:]')
[ -n "$home_host" ] || exit 0
# GitHub resolves OWNER/REPO case-insensitively, so a merge spelled
# `gaia-react/GAIA` lands on the home repository and a case-sensitive
# comparison would read it as another one. Every comparison against `home`
# below uses this form; only the label write uses the exact spelling gh
# reported.
home_lc=$(printf '%s' "$home" | tr '[:upper:]' '[:lower:]')

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
  # A host-qualified value is `HOST/OWNER/REPO`, and the host half decides as
  # much as the slug does: the same OWNER/REPO on another host is another
  # repository. Accept the qualifier only when it names the home host, and
  # exit otherwise rather than dropping it and comparing what is left.
  case "$cmd_repo" in
    */*/*)
      cmd_host=$(printf '%s' "${cmd_repo%%/*}" | tr '[:upper:]' '[:lower:]')
      [ "$cmd_host" = "$home_host" ] || exit 0
      cmd_repo="${cmd_repo#*/}"
      ;;
  esac
  [ "$(printf '%s' "$cmd_repo" | tr '[:upper:]' '[:lower:]')" = "$home_lc" ] || exit 0
fi

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
