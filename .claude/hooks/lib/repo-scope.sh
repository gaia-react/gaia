#!/usr/bin/env bash
# Shared helper: decide whether a Bash command acts on a DIFFERENT git repo
# than the one these hooks are installed in (the "home repo").
#
# Template-distributed and portable: the home repo is whatever repo contains
# .claude/hooks (resolved via `git rev-parse --show-toplevel`), never a
# hardcoded slug. Adopters get the same cross-repo isolation for free: a
# guard installed in project A never fires on a `git`/`gh` command aimed at
# a sibling project B.
#
# Usage (from a PreToolUse Bash hook, after extracting $cmd):
#   [ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
#   if type cmd_targets_foreign_repo >/dev/null 2>&1 \
#      && cmd_targets_foreign_repo "$cmd"; then exit 0; fi   # foreign: allow
#
# Fail-closed: returns 0 (true, "foreign") ONLY when it can POSITIVELY resolve
# a target whose git toplevel differs from the home repo (or an explicit
# `gh -R/--repo owner/repo` whose repo name differs). Any ambiguity, parse
# failure, OR a deliberately under-specified form it cannot model exactly
# (e.g. multiple `git -C` flags, where git's last-wins semantics defeat a
# single capture) returns 1 so the caller still enforces, protection never
# weakens silently, even for crafted command strings.

cmd_targets_foreign_repo() {
  local cmd="$1"
  local home_top target_dir top ghrepo

  home_top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$home_top" ] || return 1

  # 1. Explicit `gh ... -R owner/repo` / `--repo owner/repo` (space OR `=`
  #    form). gh ignores cwd when this is given, so it is authoritative.
  #    Comparison is repo-NAME only (basename): a same-named fork
  #    (`-R myfork/<homename>`) classifies as home and over-enforces,
  #    fail-closed and safe, but worth knowing for fork workflows.
  ghrepo=$(printf '%s' "$cmd" | sed -nE 's/.*(-R|--repo)[[:space:]=]+([^[:space:]]+).*/\2/p' | head -1)
  if [ -n "$ghrepo" ]; then
    [ "${ghrepo##*/}" != "${home_top##*/}" ] && return 0
    return 1
  fi

  # 2. Explicit `git -C <path>`. git applies multiple -C cumulatively with
  #    the LAST winning, which a single-capture regex cannot model. More
  #    than one -C is therefore genuinely ambiguous here: stay fail-closed
  #    (return 1 = enforce) rather than risk a wrong "foreign" verdict.
  if [ "$(printf '%s' "$cmd" | grep -oE 'git[[:space:]]+-C[[:space:]]|[[:space:]]-C[[:space:]]' | wc -l | tr -d ' ')" -gt 1 ]; then
    return 1
  fi
  target_dir=$(printf '%s' "$cmd" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)

  # 3. Leading `cd <path> &&|;` before the git/gh invocation.
  if [ -z "$target_dir" ]; then
    target_dir=$(printf '%s' "$cmd" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:]]+)[[:space:]]*(\&\&|;).*/\1/p' | head -1)
  fi

  # No redirection found: the command runs against the home repo.
  [ -n "$target_dir" ] || return 1

  # Strip one layer of surrounding quotes the capture may have included
  # (callers legitimately write `git -C "/abs/path"` or `cd '/abs/path' &&`).
  # The space-delimited capture keeps the quotes, which would defeat the
  # `git -C "$target_dir"` lookup below.
  case "$target_dir" in
    \"*\") target_dir="${target_dir#\"}"; target_dir="${target_dir%\"}" ;;
    \'*\') target_dir="${target_dir#\'}"; target_dir="${target_dir%\'}" ;;
  esac

  # Expand a leading ~ (our cross-repo flows use ~/path targets). The tilde
  # arrives as a literal character in the command text, bash never expanded
  # it because it was inside the tool_input string, so strip it by offset.
  # SC2088 fires on the quoted tilde, but these are case PATTERNS matching a
  # literal '~' in the input string, not an expansion attempt, intentional.
  # shellcheck disable=SC2088
  case "$target_dir" in
    '~') target_dir="$HOME" ;;
    '~/'*) target_dir="$HOME/${target_dir:2}" ;;
  esac

  top=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$top" ] || return 1

  local a b
  a=$(cd "$top" 2>/dev/null && pwd -P) || return 1
  b=$(cd "$home_top" 2>/dev/null && pwd -P) || return 1
  [ "$a" != "$b" ] && return 0
  return 1
}

# ---------------------------------------------------------------------------
# Act-on-home variant, for a consumer that ACTS on the home repo rather than
# blocking on it: posts a comment, strips a label. Same question, opposite
# fail direction and a different comparison.
#
# Fail direction. The guard above resolves every ambiguity to 1 ("home"), so a
# blocking consumer keeps enforcing; over-enforcement is safe. Reading a foreign
# command as home is not safe for a consumer that acts: it writes to a pull
# request or an issue the command never named. So here every ambiguity resolves
# to 0 ("foreign") and the caller declines.
#
# The inversion reaches the whole question rather than one arm of it, because
# this entry point does not share the guard's arms. It reads the merge with the
# first-command scan below, so a redirection ahead of the merge is not a shape
# it has to model: any prefix at all means the first command is not the merge,
# and it declines. `pushd`, a subshell `(cd ...`, and a `cd` to a path that does
# not resolve are each foreign here for that one reason, and so is a `-R`
# belonging to a later command in the same tool call.
#
# Comparison. gh identifies a repository as [HOST/]OWNER/REPO, so this compares
# the WHOLE value against one `gh repo view --json nameWithOwner,url` call,
# case-insensitively because GitHub resolves OWNER/REPO that way. The guard
# above compares the repo-NAME half against the checkout's directory basename,
# which reads a same-named fork (`--repo other-org/<homename>` from a checkout
# named `<homename>`, the ordinary fork topology) as home. That is the safe
# direction there and the wrong one here.
#
# Usage (from a hook that acts on the home repo, after extracting $cmd):
#   _lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)"
#   [ -n "${_lib:-}" ] && [ -f "$_lib/repo-scope.sh" ] && . "$_lib/repo-scope.sh"
#   type cmd_targets_foreign_repo_slug >/dev/null 2>&1 || exit 0  # undefined: decline
#   if cmd_targets_foreign_repo_slug "$cmd"; then exit 0; fi      # foreign: decline
#
# The `type` guard is not optional decoration. Sourcing this lib cwd-relative
# and then writing `type f >/dev/null 2>&1 && f "$cmd"` falls THROUGH to acting
# when the source misses, which is the fail-open composition of a missing
# boundary check and a consumer that acts. Source from ${BASH_SOURCE[0]} and
# treat undefined as a reason to exit.

# Home identity, resolved at most once per process. `gh repo view` is a network
# call, and a caller that also needs the slug itself (issue-claim-release.sh
# pins both its read and its write to it) would otherwise pay for a second one.
GAIA_REPO_SCOPE_HOME_SLUG=""
GAIA_REPO_SCOPE_HOME_HOST=""
_gaia_repo_scope_home_tried=""

# Returns 0 with both globals populated, 1 when the home repo cannot be
# identified. A failed resolution is remembered too, so a caller in a repo gh
# cannot resolve does not retry the call on every question.
gaia_repo_scope_resolve_home() {
  if [ -n "$_gaia_repo_scope_home_tried" ]; then
    [ -n "$GAIA_REPO_SCOPE_HOME_SLUG" ] || return 1
    return 0
  fi
  _gaia_repo_scope_home_tried=1

  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local json url
  json=$(gh repo view --json nameWithOwner,url 2>/dev/null) || return 1
  GAIA_REPO_SCOPE_HOME_SLUG=$(printf '%s' "$json" | jq -r '.nameWithOwner // ""' 2>/dev/null)
  [ -n "$GAIA_REPO_SCOPE_HOME_SLUG" ] || return 1

  # The host is the URL's authority: an adopter mirroring one repository
  # between github.com and an enterprise host carries the same OWNER/REPO on
  # both, so the slug alone does not name it.
  url=$(printf '%s' "$json" | jq -r '.url // ""' 2>/dev/null)
  url="${url#*://}"
  GAIA_REPO_SCOPE_HOME_HOST=$(printf '%s' "${url%%/*}" | tr '[:upper:]' '[:lower:]')
  if [ -z "$GAIA_REPO_SCOPE_HOME_HOST" ]; then
    GAIA_REPO_SCOPE_HOME_SLUG=""
    return 1
  fi
  return 0
}

# Compare ONE already-extracted [HOST/]OWNER/REPO value against the home repo.
# 0 = foreign (decline), 1 = home. An EMPTY value means the command named no
# explicit target, which is home: gh resolves from cwd there.
#
# This is the half a consumer that parses the command itself wants. A regex
# over the raw command text cannot tell which command in a multi-command string
# a flag belongs to, so `gh pr merge 5; gh issue list --repo other/x` reads as
# foreign under a whole-string capture while the merge itself targets home. A
# caller holding a properly scanned value passes it here and skips that class
# of misread entirely.
repo_slug_is_foreign() {
  local value="$1"
  local cmd_host

  [ -n "$value" ] || return 1

  gaia_repo_scope_resolve_home || return 0

  # A host-qualified value is HOST/OWNER/REPO, and the host half decides as
  # much as the slug does: the same OWNER/REPO served from another host is
  # another repository. Accept the qualifier only when it names the home host,
  # and decline otherwise rather than dropping it and comparing what is left.
  case "$value" in
    */*/*)
      cmd_host=$(printf '%s' "${value%%/*}" | tr '[:upper:]' '[:lower:]')
      [ "$cmd_host" = "$GAIA_REPO_SCOPE_HOME_HOST" ] || return 0
      value="${value#*/}"
      ;;
  esac

  # Case-insensitive: GitHub resolves OWNER/REPO that way, so a merge spelled
  # in another case lands on the home repository and a case-sensitive
  # comparison would read it as a different one.
  [ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" \
    = "$(printf '%s' "$GAIA_REPO_SCOPE_HOME_SLUG" | tr '[:upper:]' '[:lower:]')" ] || return 0
  return 1
}

# ---------------------------------------------------------------------------
# First-command scan, shared by every consumer that acts on the home repo.
#
# Split the command into shell-like words. This is a real scan rather than a
# set of patterns over the raw text, and the difference is the whole point: a
# quote character opens a span in which whitespace, separators and the other
# quote character are all ordinary text, and a backslash escapes the
# character after it. Pattern-matching the raw text got this wrong once per
# spelling, always in the direction of reading part of one value, or part of
# a following command, as the pull-request reference or as the repository.
#
# The scan reads the FIRST command in the tool call and hands back its words.
# Whatever sits ahead of a command decides how that command should be read,
# and reading it needs the shell's own semantics: a comment hides a command,
# a heredoc body is not a quoted span so its lines read as commands, `cd` and
# `(cd` and `pushd` decide which repository the command lands in, and each of
# those is a construct rather than a spelling, so every rule naming one left
# the next one open. Requiring the command to come first closes the whole
# class at once: there is no prefix left to misread, and every word a caller
# sees comes from the invocation itself.
#
# The words that come out are unquoted, so nothing downstream needs to know
# quotes exist, and a `;` inside a squash subject stays text.
#
# Sets GAIA_FIRST_COMMAND_WORDS to the first command's words. Returns 0 when
# it read at least one word, 1 when the string held no command at all.
GAIA_FIRST_COMMAND_WORDS=()

gaia_scan_first_command() {
  local cmd="$1"
  # Named once, above the loop: a `case` pattern cannot hold a `$'\n'`
  # literal, and a command substitution in one would run per scanned
  # character. The newline is the load-bearing member of the set below: a
  # caller's arming match counts one as a separator, so without it here the
  # scan would run past the end of a command that match already treats as
  # several. The scan also cuts at a lone `&`, which those arming matches do
  # not accept before their verb; that asymmetry costs a background-started
  # command its handling and never a wrong one, so it is the safe direction
  # to differ in.
  local NL=$'\n'
  local TAB=$'\t'
  local word="" have_word=0 q="" esc=0 piece_closed=0
  local _prev_lc_all _had_lc_all BLOCK n_cmd base block k n_block c

  GAIA_FIRST_COMMAND_WORDS=()

  # `${cmd:$i:1}` costs O(i), so indexing the whole string per character makes
  # the scan quadratic, and the callers are hooks, so that cost is a
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
      # a lone newline in the word stream, and a caller reading the first
      # non-flag word as its reference would resolve a newline instead of a
      # command written across two lines.
      if [ "$esc" = 1 ]; then
        esc=0
        [ "$c" = "$NL" ] && continue
        word="$word$c"; have_word=1; continue
      fi
      # Inside single quotes a backslash is literal, as in the shell itself.
      # `have_word` is deliberately NOT set here: at the backslash it is not
      # yet known whether a word follows it or a line continuation does, and
      # marking one either way puts an empty word into the stream on the
      # continuation. The escaped-character branch above marks it once a
      # character survives.
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
          [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word")
          word=""; have_word=0
          ;;
        '&'|'|'|';'|"$NL")
          [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word")
          word=""; have_word=0
          # An empty piece is no command at all: leading whitespace or a
          # newline, or the second character of `&&` / `||`. Keep scanning so
          # the FIRST real command is still the one that gets handed back.
          [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -eq 0 ] && continue
          piece_closed=1; break 2
          ;;
        '#')
          # A word-initial unquoted `#` opens a COMMENT, so the shell drops it
          # and everything after it to the newline and the command never
          # receives any of it. Read as ordinary text those words reach a
          # caller's parser, and a `--repo` among them wins, because that
          # parser keeps the LAST one it sees. A foreign command whose
          # trailing comment names this repository would then resolve THIS
          # repository. Mid-word the character is ordinary text, which is the
          # shell's rule too and is what keeps `fix#<n>` intact.
          #
          # Stopping the scan is the same retreat the separators take, and it
          # is required rather than convenient: skipping ahead to the newline
          # would let a comment that HIDES a leading command promote the words
          # after it into the first command. The command a caller wants has to
          # be that first command anyway, so nothing beyond the comment was
          # readable.
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
    [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word")
  fi

  [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -gt 0 ] || return 1
  return 0
}

# `gh pr merge` form of the scan above, for the two consumers that act on the
# home repo off a merge. Requires the FIRST command in the tool call to BE the
# merge, then reads that invocation's own flags.
#
# Sets GAIA_GH_MERGE_REF to the pull-request reference the merge names (empty
# when it names none, which is gh's current-branch default) and
# GAIA_GH_MERGE_REPO to its `-R`/`--repo` value (empty when it carries none,
# which means gh resolves from cwd). Returns 0 when both are populated from a
# merge invocation it read completely, 1 when it abstains: the tool call's
# first command is not the merge, or the merge carries a flag shape this
# parser does not model.
#
# The cost of the first-command requirement is that `<something> && <merge>`
# in one tool call is not read. That shape is not how this repository merges
# (the merge workflow runs the merge as its own step), and the alternative is
# a prefix nobody can read exactly, whose misreads all land on a write to a
# repository the command never named.
GAIA_GH_MERGE_REF=""
GAIA_GH_MERGE_REPO=""

gaia_scan_gh_merge() {
  local cmd="$1"
  local i n tok flag skip_next skip_flag value_flags

  GAIA_GH_MERGE_REF=""
  GAIA_GH_MERGE_REPO=""

  gaia_scan_first_command "$cmd" || return 1
  # The first command has to BE the merge; a caller's arming match only proved
  # the phrase appears somewhere a command could start, which a comment, a
  # heredoc body line, and a quoted value all satisfy.
  [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -ge 3 ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[0]}" = "gh" ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[1]}" = "pr" ] || return 1
  [ "${GAIA_FIRST_COMMAND_WORDS[2]}" = "merge" ] || return 1

  # Every value-taking flag, and only those. Checked against gh's own help
  # output rather than recalled: -m is --merge, a BOOLEAN, so listing it here
  # would make `-m 1498` skip the reference and resolve the current branch
  # instead. -A/--author-email and -F/--body-file do take values, so omitting
  # them would make the value itself the reference.
  value_flags=" -R --repo -A --author-email -b --body -F --body-file -t --subject --match-head-commit "
  skip_next=0
  skip_flag=""
  n=${#GAIA_FIRST_COMMAND_WORDS[@]}
  i=3
  while [ "$i" -lt "$n" ]; do
    tok="${GAIA_FIRST_COMMAND_WORDS[$i]}"
    i=$((i + 1))
    if [ "$skip_next" = 1 ]; then
      skip_next=0
      [ "$skip_flag" = repo ] && GAIA_GH_MERGE_REPO="$tok"
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
      # subject the reference, and both end in a write onto something in THIS
      # repository the merge never named.
      #
      # Rejecting the whole shape rather than the letter `R` is deliberate:
      # matching R alone would close the spelling that was reported and leave
      # the one that was not, which is how the ten rounds before this went. A
      # token whose FIRST letter is value-taking is not a cluster (the rest is
      # that flag's value), so it falls through to the arms below.
      -[!-RAbFt]?*)
        return 1
        ;;
      -*=*)
        # `--flag=value` carries its value in the same word.
        flag="${tok%%=*}"
        case "$value_flags" in
          *" $flag "*)
            case "$flag" in
              -R|--repo) GAIA_GH_MERGE_REPO="${tok#*=}" ;;
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
        GAIA_GH_MERGE_REPO="${tok#-R}"
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
        # is an ordinary invocation and stopping here would leave the
        # repository read unarmed for every trailing spelling of the flag.
        [ -n "$GAIA_GH_MERGE_REF" ] || GAIA_GH_MERGE_REF="$tok"
        ;;
    esac
  done
  return 0
}

# Whole-command form, for a consumer with no scanner of its own. It reads the
# merge invocation with the scan above and hands its `-R`/`--repo` value to
# the comparison above.
#
# Every abstention of the scan's is foreign here, which is this entry point's
# safe direction: a tool call whose first command is not the merge carries a
# prefix that decides which repository the merge lands in, and a flag shape
# the parser does not model can name another repository outright. Neither is
# a value this entry point parsed, so neither is one it lets a caller act on.
#
# That covers the redirections a regex over the raw text cannot: a leading
# `cd`, a `pushd`, a subshell `(cd ...`, a `cd` to a path that does not
# resolve. It equally covers a `-R` belonging to a LATER command in the same
# tool call (`gh pr merge 42 && grep -R app/routes .`), which no shape test on
# the value can tell from gh's own repository flag, since a path argument
# carries a slash exactly as a slug does. The scan tells them apart by knowing
# which command the flag belongs to, and a merge that carries none reads home
# because it is the first command, so nothing redirected cwd ahead of it.
cmd_targets_foreign_repo_slug() {
  local cmd="$1"

  gaia_scan_gh_merge "$cmd" || return 0

  # An empty value means the merge named no explicit target. The comparison
  # reads that as home, which is correct here precisely because the scan
  # proved the merge is the first command in the tool call.
  if repo_slug_is_foreign "$GAIA_GH_MERGE_REPO"; then return 0; fi
  return 1
}
