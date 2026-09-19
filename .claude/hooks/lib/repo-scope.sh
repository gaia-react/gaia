#!/usr/bin/env bash
# Shared helper: decide whether a Bash command acts on a DIFFERENT git repo
# than the one these hooks are installed in (the "home repo").
#
# Template-distributed and portable: the home repo is whatever repo the
# session's working directory sits in, never a hardcoded slug. Adopters get the
# same cross-repo isolation for free: a guard installed in project A never
# fires on a `git`/`gh` command aimed at a sibling project B.
#
# A repository is not a directory. Every linked worktree of the home repo, and
# a checkout whose directory is not named for the repository, is still the
# home repo, so neither a toplevel nor a directory name can stand in for its
# identity: a linked worktree's toplevel is its own directory, and both
# comparisons read `--repo <home>` or `git -C <main-checkout>` as foreign.
#
# Usage (from a PreToolUse Bash hook, after extracting $cmd):
#   _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _lib_dir=''
#   [ -n "$_lib_dir" ] && [ -f "$_lib_dir/repo-scope.sh" ] && . "$_lib_dir/repo-scope.sh"
#   if type cmd_targets_foreign_repo >/dev/null 2>&1 \
#      && cmd_targets_foreign_repo "$cmd"; then exit 0; fi   # foreign: allow
#
# Fail-closed: returns 0 (true, "foreign") ONLY when it can POSITIVELY resolve
# a target in a different repository (or an explicit `gh -R/--repo
# owner/repo` whose repo name is none of the home repo's) for at least one
# command in the tool call and no command in it acts on this one. Any ambiguity,
# parse failure, an identity it cannot resolve, OR a deliberately
# under-specified form it cannot model exactly (e.g. multiple `git -C` flags,
# where git's last-wins semantics defeat a single capture) returns 1 so the
# caller still enforces.
#
# Honest limits: a command is recognised as git or gh by its literal name, as
# the consumers' own arming matches are. A name the shell assembles by
# expansion (`g$'i't`, a glob such as `/usr/bin/gi?`) is not read as either
# program, so after a foreign command it can read foreign. The word scan
# models neither heredocs nor ANSI-C quoting; the quote desync either can cause
# is caught only where the commands it hides name git or gh.

# The repository name a git remote URL or a gh [HOST/]OWNER/REPO value ends
# in, lowercased because GitHub resolves names case-insensitively, with a
# trailing `/` and `.git` dropped. The last `/` or `:` segment covers every
# remote spelling git accepts: `https://host/owner/repo.git`,
# `git@host:owner/repo.git`, `ssh://host:22/owner/repo`, a local path.
_gaia_repo_scope_repo_name() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  v="${v%/}"
  v="${v%.git}"
  printf '%s' "${v##*[/:]}"
}

# The shared main-checkout resolver, loaded from this library's own on-disk
# location (never cwd: a hook suite runs from a sandbox with no .gaia/).
# Errexit is suspended across the load and restored to what it was, for the
# reason .claude/hooks/lib/verb-arming.sh gives at its own repo-scope load: a
# parse error abandons the shell from a condition context too, and in the
# errexit consumers that exit is the deny code.
_gaia_repo_scope_load_main_root() {
  local root errexit_was
  type gaia_resolve_common_dir >/dev/null 2>&1 && return 0
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)" || return 1
  [ -f "$root/.gaia/scripts/main-root-lib.sh" ] || return 1
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck source=/dev/null
  . "$root/.gaia/scripts/main-root-lib.sh" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  type gaia_resolve_common_dir >/dev/null 2>&1
}

# Set by cmd_targets_foreign_repo to the directory a `cd` earlier in the tool
# call moves the deciding command into, once that directory resolves as this
# repository, and empty otherwise. A home verdict on a `cd` into a linked
# worktree means "this repository" but not "this checkout", so a caller that
# reads per-checkout state (the branch) reads it there rather than from its own
# working directory.
#
# Honest limit: a command's own `git -C` or `gh -R` decides where that command
# acts, so neither publishes, and a caller reads its own directory for that
# spelling. That is the pre-existing reading for it, never a looser one.
GAIA_REPO_SCOPE_LEAD_CD=""

# A word naming git or gh as a program, wherever it sits in the word: `git`,
# `/usr/bin/git`, `(gh`, `$(git`, a `bash -c` script holding either. `.` and
# word characters are not boundaries, so `.gitignore`, `github` and `repo.git`
# do not match.
_GAIA_REPO_SCOPE_TOOL_RE='(^|[^[:alnum:]_.])(git|gh)([^[:alnum:]_.]|$)'

# A word that can move a command off the directory the hook runs in: a
# directory change, git's `-C`, or gh's repository flag. A call holding none of
# them has no command that can be foreign.
_GAIA_REPO_SCOPE_MOVE_RE='(^|[^[:alnum:]_.])(cd|pushd|popd|-C|-R|--repo)([^[:alnum:]_.]|$)'

# The tool pattern above, read against the raw text of the rest of a call
# rather than a scanned word. The scan drops quote characters, backslashes, and
# line continuations, so any of them may sit inside or around a name the scan
# hands back (`g\it`, `"gh"`); each is also a boundary character. So a stretch
# of raw text this does not match yields no word the tool pattern matches.
_GAIA_REPO_SCOPE_DROPPED="[\""$'\047'"\\"$'\n'"]*"
_GAIA_REPO_SCOPE_TOOL_RAW_RE='(^|[^[:alnum:]_.])g'"$_GAIA_REPO_SCOPE_DROPPED"'(h|i'"$_GAIA_REPO_SCOPE_DROPPED"'t)([^[:alnum:]_.]|$)'

# Sets the caller's `flat` to `$1` with every quote character, backslash, and
# line continuation removed. The scan's words are that text split at
# whitespace and separators, less what quoting keeps literal, so a pattern
# absent from `flat` is absent from every word the scan hands back.
_gaia_repo_scope_flatten() {
  local bs=\\ nl=$'\n' sq=$'\047'
  flat="${1//"$bs$nl"/}"
  flat="${flat//[\"$sq\\]/}"
}

# The verdict covers the whole tool call, and it is HOME when ANY command in
# the call acts on the home repository: foreign only when every command is
# foreign-acting or touches no repository at all. Judging the call by one
# command let a foreign first `gh` exempt a home commit after it, a trailing
# `git -C <sibling>` exempt a home commit before it, and a leading `cd
# <sibling>` exempt a commit made after `cd -` (gaia-react/gaia#2081). The rule
# "nothing may follow a foreign command" was rejected because it enforces on a
# sibling merge followed only by sibling commands or by `echo`.
#
# The accepted cost: a foreign command sharing its call with a home one, even a
# read-only `git status`, is enforced as home. Running the foreign command as
# its own tool call is the sidestep.
cmd_targets_foreign_repo() {
  local _prev_lc_all _had_lc_all rc=1

  GAIA_REPO_SCOPE_LEAD_CD=""
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 1

  # The scan reports byte offsets, and the walk slices the command at them, so
  # both have to count bytes rather than characters.
  _prev_lc_all="${LC_ALL-}"
  _had_lc_all="${LC_ALL+set}"
  LC_ALL=C
  if _gaia_repo_scope_verdict "$1"; then rc=0; fi
  if [ "$_had_lc_all" = set ]; then LC_ALL="$_prev_lc_all"; else unset LC_ALL; fi
  return "$rc"
}

# Walks every command in the tool call with the scan below, carrying the
# directory each `cd` moves the rest of the call into. Returns 0 (foreign) only
# when at least one command is foreign and none is home.
#
# A `cd` moves that directory only where the shell is certain to run it in the
# calling shell and every later command is certain to run after it. The scan
# splits at newlines, `&` and `|` without modelling what groups them, so a `cd`
# inside a subshell, a `$( )`, a function body, a heredoc body, a loop or an
# `if`, a pipeline, or a backgrounded command would otherwise move it for
# commands the shell runs in the original directory, and read a home command
# after it as foreign. So once any command opens one of those constructs the
# walk goes opaque and every later `cd` makes the directory unknown, which is
# home. A `cd` reached through `&&` runs only if everything before it
# succeeded, so its move ends with its and-or list, and a `||` after a move
# makes the directory unknown.
_gaia_repo_scope_verdict() {
  local cmd="$1"
  local NL=$'\n'
  local pos=0 n_cmd=${#cmd} rest foreign=0 kind c1 c2 walked=0 tool_end
  # Read by the helpers below through bash's dynamic scope.
  local dir="" dir_known=1 remotes="" remotes_read=0 home_common="" home_common_read=0
  local flat opaque=0 sep_before=start sep_after list_moved=0 cond_move=0

  # The walk is a character loop in bash, so a large call costs real time on a
  # blocking hook's path; these checks skip it wherever it cannot change the
  # answer.
  _gaia_repo_scope_flatten "$cmd"
  [[ "$flat" =~ $_GAIA_REPO_SCOPE_MOVE_RE ]] || return 1
  _gaia_repo_scope_tool_end "$cmd"

  while [ "$pos" -lt "$n_cmd" ]; do
    # Nothing left names either program, so nothing left can be home or
    # foreign.
    [ "$pos" -lt "$tool_end" ] || break
    # Each scan slices the whole call, so the walk costs its length once per
    # command. Past this many commands it stops and enforces rather than stall
    # the hook: an over-enforcement, never a guess of foreign.
    walked=$((walked + 1))
    [ "$walked" -le "$_GAIA_REPO_SCOPE_WALK_MAX" ] || return 1
    if gaia_scan_first_command "$cmd" "$pos"; then
      sep_after=end
      if [ "$GAIA_FIRST_COMMAND_CLOSED" = 1 ]; then
        c1="${cmd:$((GAIA_FIRST_COMMAND_END - 1)):1}"
        c2="${cmd:$GAIA_FIRST_COMMAND_END:1}"
        case "$c1$c2" in
          '&&') sep_after=and ;;
          '||') sep_after=or ;;
          '&'*) sep_after='bg' ;;
          '|'*) sep_after=pipe ;;
          *) sep_after=seq ;;
        esac
      fi
      kind=0
      _gaia_repo_scope_segment || kind=$?
      [ "$kind" = 1 ] && _gaia_repo_scope_swallowed && kind=2
      [ "$kind" = 2 ] && return 1
      [ "$kind" = 1 ] && foreign=1
      _gaia_repo_scope_opens_group && opaque=1
      case "$sep_after" in
        or) [ "$list_moved" = 1 ] && dir_known=0 ;;
        seq|bg)
          [ "$cond_move" = 1 ] && dir_known=0
          list_moved=0; cond_move=0
          ;;
      esac
      sep_before="$sep_after"
    fi
    [ "$GAIA_FIRST_COMMAND_CLOSED" = 1 ] || break
    pos="$GAIA_FIRST_COMMAND_END"
    # A comment runs to the end of its line, and the next line is a command.
    # A comment that closed a command already ended its list above. One on a
    # line of its own, after a trailing `&&`, `||` or `|`, does not: bash
    # carries that list or pipeline onto the next line, so the separator the
    # walk last read still stands.
    if [ "${cmd:$((pos - 1)):1}" = "#" ]; then
      rest="${cmd:$pos}"
      case "$rest" in *"$NL"*) ;; *) break ;; esac
      rest="${rest%%"$NL"*}"
      pos=$((pos + ${#rest} + 1))
    fi
  done
  [ "$foreign" = 1 ]
}

# Commands the walk reads before it stops and enforces. Measured on bash 3.2
# and 5, a call of 140KB costs under a second at this depth, where an unbounded
# walk over 4,000 commands took ten.
_GAIA_REPO_SCOPE_WALK_MAX=128

# Sets the caller's `tool_end` to the byte offset just past the last stretch of
# the call the raw tool pattern matches, 0 when there is none. Past it no
# command names git or gh. Counting stops after as many matches as the walk
# would read commands, and the whole call is kept, since a walk that long stops
# on its own.
_gaia_repo_scope_tool_end() {
  local s="$1" m pre n=0
  tool_end=0
  while [[ "$s" =~ $_GAIA_REPO_SCOPE_TOOL_RAW_RE ]]; do
    n=$((n + 1))
    if [ "$n" -gt "$_GAIA_REPO_SCOPE_WALK_MAX" ]; then tool_end=${#1}; return 0; fi
    m="${BASH_REMATCH[0]}"
    pre="${s%%"$m"*}"
    tool_end=$((tool_end + ${#pre} + ${#m}))
    s="${s:$((${#pre} + ${#m}))}"
  done
}

# 0 when a word after the first of the command the scan just read names git
# or gh beside a command separator or a newline. The scan models neither a
# heredoc nor ANSI-C quoting, so an apostrophe in a heredoc body, or a `$'\''`,
# can open a quoted span the shell never opened and carry the commands after
# it into one word of this command. A foreign command holding one would hide
# them, so it enforces instead. A `--body` that only mentions git stays
# foreign; one that also holds a `;` enforces.
_gaia_repo_scope_swallowed() {
  local i n=${#GAIA_FIRST_COMMAND_WORDS[@]} tok NL=$'\n'
  i=1
  while [ "$i" -lt "$n" ]; do
    tok="${GAIA_FIRST_COMMAND_WORDS[$i]}"
    i=$((i + 1))
    case "$tok" in
      *';'* | *'&'* | *'|'* | *"$NL"*)
        [[ "$tok" =~ $_GAIA_REPO_SCOPE_TOOL_RE ]] && return 0
        ;;
    esac
  done
  return 1
}

# 0 when the command the scan just read opens or closes a construct that scopes
# a `cd` away from the commands after it: a subshell, a group, a function body
# or definition, a command or process substitution, a heredoc, or a compound
# command's keyword. The scan drops quotes, so a parenthesis inside a quoted
# commit subject counts too: that only makes later `cd`s unknown, which
# enforces.
_gaia_repo_scope_opens_group() {
  local tok
  case "${GAIA_FIRST_COMMAND_WORDS[0]}" in
    if|then|else|elif|fi|for|while|until|do|done|case|'esac'|select|function|'!')
      return 0 ;;
  esac
  for tok in "${GAIA_FIRST_COMMAND_WORDS[@]}"; do
    case "$tok" in
      *'('* | *')'* | *'{'* | *'}'* | *'`'* | *\<\<*) return 0 ;;
    esac
  done
  return 1
}

# Classifies the command the scan just read: 0 touches no repository, 1 acts
# on another repository, 2 acts on this one or cannot be read (enforce).
#
# Only a command whose first word is `git` or `gh` is read for where it acts.
# Any other command that names either program anywhere in its words (a
# subshell, `env` or `VAR=` prefix, `$( )`, backticks, `bash -c`, `xargs`) is
# a shape this walk does not model, so it is home. A heredoc body's lines reach
# here as commands and are classified like any other: a body line reading as a
# foreign `gh -R` counts as foreign, one naming git or gh any other way
# enforces, and one starting `cd` moves nothing, because the heredoc left the
# walk opaque.
_gaia_repo_scope_segment() {
  local n=${#GAIA_FIRST_COMMAND_WORDS[@]}
  local i tok target cdir="" ccount=0 ghrepo="" name r

  case "${GAIA_FIRST_COMMAND_WORDS[0]}" in
    cd)
      # Only a `cd` the calling shell certainly runs, ahead of every command
      # after it, moves the directory (see the walk above). Any other leaves it
      # unknown, and so does one that is opaque itself (`cd x)` closes a
      # subshell).
      if [ "$opaque" = 1 ] || _gaia_repo_scope_opens_group; then dir_known=0; return 0; fi
      case "$sep_before:$sep_after" in
        start:seq|start:and|start:end|seq:seq|seq:and|seq:end|and:seq|and:and|and:end) ;;
        *) dir_known=0; return 0 ;;
      esac
      if [ "$n" -ne 2 ]; then dir_known=0; return 0; fi
      target="${GAIA_FIRST_COMMAND_WORDS[1]}"
      # A bare `cd`, `cd -`, and a target the shell rewrites before cd sees it
      # land somewhere this walk cannot name, so every command after one is
      # home until an absolute `cd` names a directory again.
      _gaia_repo_scope_expand_dir || { dir_known=0; return 0; }
      case "$target" in
        /*) dir="$target"; dir_known=1 ;;
        *) [ "$dir_known" = 1 ] && dir="${dir:+$dir/}$target" ;;
      esac
      list_moved=1
      [ "$sep_before" = and ] && cond_move=1
      return 0
      ;;
    pushd|popd)
      dir_known=0
      return 0
      ;;
    git)
      # git's global options come before the subcommand. An unmodelled one that
      # takes a separate value ends this walk early and hides a later `-C`,
      # which reads the command against the tracked directory instead.
      i=1
      while [ "$i" -lt "$n" ]; do
        tok="${GAIA_FIRST_COMMAND_WORDS[$i]}"
        case "$tok" in
          -C)
            ccount=$((ccount + 1))
            cdir="${GAIA_FIRST_COMMAND_WORDS[$((i + 1))]:-}"
            i=$((i + 2))
            ;;
          -c|--config-env|--attr-source|--namespace) i=$((i + 2)) ;;
          --git-dir|--git-dir=*|--work-tree|--work-tree=*) return 2 ;;
          -*) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      # git applies multiple -C cumulatively with the LAST winning, which this
      # walk does not model, so more than one is ambiguous: enforce.
      [ "$ccount" -gt 1 ] && return 2
      if [ "$ccount" = 1 ]; then
        target="$cdir"
        _gaia_repo_scope_expand_dir || return 2
        case "$target" in
          /*) ;;
          *) [ "$dir_known" = 1 ] || return 2; target="${dir:+$dir/}$target" ;;
        esac
        r=0
        _gaia_repo_scope_where "$target" || r=$?
        [ "$r" = 0 ] && return 1
        return 2
      fi
      r=0
      _gaia_repo_scope_tracked || r=$?
      [ "$r" = 0 ] && return 1
      return 2
      ;;
    gh)
      # `-R`/`--repo` (space OR `=` form). gh ignores cwd when this is given,
      # so it is authoritative for the command carrying it. It is read from
      # this command's own words, which the scan unquoted, so `--repo` inside
      # a quoted `--body` stays text and another program's `-R` operand (`cp
      # -R a/b x`, gaia-react/gaia#2011) is never in reach.
      i=1
      while [ "$i" -lt "$n" ]; do
        tok="${GAIA_FIRST_COMMAND_WORDS[$i]}"
        i=$((i + 1))
        case "$tok" in
          # gh's flag library keeps the LAST spelling it reads, so the walk
          # does not stop at the first one.
          -R|--repo)
            [ "$i" -lt "$n" ] && ghrepo="${GAIA_FIRST_COMMAND_WORDS[$i]}"
            ;;
          -R=*|--repo=*) ghrepo="${tok#*=}" ;;
          # An ATTACHED shorthand (`-Rowner/repo`) is not read. Only the flags
          # a given gh subcommand takes a value for decide whether such a word
          # is a repository or some other flag's value (`--subject
          # -Rfoo/bar`), and this entry point serves every subcommand, so it
          # models no per-subcommand flag set. It may name either repository,
          # so enforce.
          -R?*) return 2 ;;
        esac
      done
      if [ -z "$ghrepo" ]; then
        r=0
        _gaia_repo_scope_tracked || r=$?
        [ "$r" = 0 ] && return 1
        return 2
      fi
      # Only the characters a [HOST/]OWNER/REPO or a URL spelling of one
      # holds. Anything else (a quote left over, an escape, `$`, a backtick, a
      # brace, a glob, a tilde) is a value the shell may rewrite before gh sees
      # it, so what gh names is unknown. An allowlist, because each blocklist
      # of those left the next expansion out.
      case "$ghrepo" in *[![:alnum:]._:/-]*) return 2 ;; esac
      # gh refuses a value with no owner, so it names no repository to exempt.
      case "$ghrepo" in */*) ;; *) return 2 ;; esac
      name=$(_gaia_repo_scope_repo_name "$ghrepo")
      [ -n "$name" ] || return 2
      # The home repo's names are the repository names its remotes point at.
      # Remotes live in the shared git config, so every worktree reads the
      # same set, and none of them depends on what a checkout's directory is
      # called. Every remote counts rather than only the one `gh` would pick,
      # because a fork clone's `gh pr merge` resolves to its `upstream`
      # remote, not `origin`.
      #
      # Comparison is repo-NAME only: a same-named fork (`-R
      # myfork/<homename>`) classifies as home and over-enforces, fail-closed
      # and safe, but worth knowing for fork workflows. `gh repo view` would
      # name the whole slug, but it is a network call on a blocking hook's
      # path and it names one repository where a fork clone has two.
      if [ "$remotes_read" = 0 ]; then
        remotes=$(git config --get-regexp '^remote\..+\.url$' 2>/dev/null \
          | while read -r _ url; do _gaia_repo_scope_repo_name "$url"; echo; done)
        remotes_read=1
      fi
      # No remote names the home repo, so there is nothing to call foreign.
      [ -n "$remotes" ] || return 2
      # A shell match rather than grep: a matcher that fails to run would read
      # as "no match" and exempt the command.
      case "$NL$remotes$NL" in *"$NL$name$NL"*) return 2 ;; esac
      return 1
      ;;
  esac

  for tok in "${GAIA_FIRST_COMMAND_WORDS[@]}"; do
    if [[ "$tok" =~ $_GAIA_REPO_SCOPE_TOOL_RE ]]; then
      _gaia_repo_scope_tracked || true
      return 2
    fi
  done
  return 0
}

# Rewrites the caller's `target` the way the shell would before cd or git sees
# it, as far as that is knowable: returns 1 for a value the shell rewrites in a
# way this cannot follow, and for `-` and the empty string.
#
# The tilde arrives as a literal character in the command text, since bash
# never expanded it inside the tool_input string, so it is stripped by offset.
# SC2088 fires on the quoted tilde, but these are case PATTERNS matching a
# literal '~' in the input string, not an expansion attempt, intentional.
# shellcheck disable=SC2088
_gaia_repo_scope_expand_dir() {
  case "$target" in
    '~') target="$HOME" ;;
    '~/'*) target="$HOME/${target:2}" ;;
  esac
  case "$target" in
    '' | -* | *'$'* | *'`'* | *\\* | *'*'* | *'?'* | *'['* | *'{'* | *'~'*) return 1 ;;
  esac
  return 0
}

# Where the directory `$1` sits: 0 another repository, 1 this repository, 2
# unresolvable. Same repository means same git common directory, which a main
# checkout shares with every linked worktree of it. The resolver's identity
# answer rather than two main-root resolutions: this runs on nearly every git
# tool call. Without the resolver, or for a target whose repository cannot be
# resolved, there is no identity to compare, so the caller enforces.
_gaia_repo_scope_where() {
  local a
  _gaia_repo_scope_load_main_root || return 2
  if [ "$home_common_read" = 0 ]; then
    home_common=$(gaia_resolve_common_dir) || home_common=""
    home_common_read=1
  fi
  [ -n "$home_common" ] || return 2
  a=$(gaia_resolve_common_dir "$1") || return 2
  [ -n "$a" ] || return 2
  [ "$a" = "$home_common" ] && return 1
  return 0
}

# Where the walk's tracked directory sits, with `_gaia_repo_scope_where`'s
# codes. The hook's own directory, with no `cd` ahead, is this repository. A
# `cd` target that resolves as this repository is published for the caller
# (GAIA_REPO_SCOPE_LEAD_CD, above); an unresolvable one never is, because a
# caller reading its branch from a path git cannot open would read no branch
# at all and let the command through.
_gaia_repo_scope_tracked() {
  local r=0
  [ "$dir_known" = 1 ] || return 2
  [ -n "$dir" ] || return 1
  _gaia_repo_scope_where "$dir" || r=$?
  # shellcheck disable=SC2034 # read by red-verify-commit-check.sh and worthiness-presence-check.sh
  [ "$r" = 1 ] && GAIA_REPO_SCOPE_LEAD_CD="$dir"
  return "$r"
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
# above compares the repo-NAME half against the repository names the home
# repo's remotes point at, which reads a same-named fork
# (`--repo other-org/<homename>` from a clone of `<homename>`, the ordinary
# fork topology) as home. That is the safe direction there and the wrong one
# here.
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
#
# An optional second argument is the byte offset to start reading at, and
# GAIA_FIRST_COMMAND_END is set to the byte offset just past the character that
# closed the command (the string's length when nothing did), so a caller can
# walk every command in a tool call by scanning again from there. The character
# before that offset is the `#` when a comment closed it, whose text runs to the
# end of its line and is the caller's to skip.
#
# Also sets GAIA_FIRST_COMMAND_CLOSED: 0 when no separator and no comment closed
# the first command, 1 when one did with something after it. A caller asking
# whether a second command was spelled with a separator cannot ask that of the
# text, because the spellings that matter break any literal scan of it
# (`gh pr "merge" <n>`, a line continuation inside the verb, a subshell, a brace
# group). This scan tokenizes the way the shell does, so it answers that
# question exactly, and publishing the answer costs one assignment rather than
# a second parser.
#
# What it does NOT report is EXPANSION. A command substitution, a backtick and
# a process substitution are ordinary word text to a scan that models words, so
# a string carrying one reaches the end with this flag still 0 while the shell
# runs the payload. A caller that needs "nothing else runs at all" has to rule
# that class out itself; this flag is one half of that question, not the whole
# of it.
GAIA_FIRST_COMMAND_WORDS=()
GAIA_FIRST_COMMAND_CLOSED=0
GAIA_FIRST_COMMAND_END=0

gaia_scan_first_command() {
  local cmd="$1" start="${2:-0}"
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
  local word="" chunk="" have_word=0 q="" qset="" esc=0 piece_closed=0
  local _prev_lc_all _had_lc_all BLOCK n_cmd base block k n_block c rest run

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
  #
  # A third: a word accumulates into `chunk` and reaches `word` once per
  # block, not one character at a time. `word="$word$c"` costs O(word), and
  # nothing bounds how long one word gets, since inside a quoted span
  # whitespace, separators and newlines are all ordinary text, so a quoted
  # `--body` is one word however long the prose is. Appending per character
  # made the scan quadratic in that body's size: seconds of synchronous stall
  # on a deny-capable gate at a size an ordinary pull-request body reaches.
  # Flushing per block bounds the per-character append by BLOCK and pays the
  # O(word) append BLOCK times less often. The cost of that is that every read
  # of the word has to spell `$word$chunk`, which is why the pushes below do.
  _prev_lc_all="${LC_ALL-}"
  _had_lc_all="${LC_ALL+set}"
  LC_ALL=C
  BLOCK=256
  n_cmd=${#cmd}
  base="$start"
  GAIA_FIRST_COMMAND_END="$n_cmd"
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
        chunk="$chunk$c"; have_word=1; continue
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
        if [ "$c" = "$q" ]; then
          q=""; qset=""
        else
          chunk="$chunk$c"
          # `c` was ordinary text inside the span, so the run after it is
          # ordinary until the next character that means anything here: the
          # closing quote, and in a double-quoted span a backslash. Take that
          # whole run in one operation instead of a character at a time, which
          # is what makes a long quoted body cost about what reading it costs.
          # `rest` is a tail of the BLOCK-sized slice, never of the whole
          # command, so this pattern match is bounded too; matching over the
          # full string would trade the quadratic append for a superlinear
          # match and buy much less.
          rest="${block:$k}"
          # shellcheck disable=SC2295 # $qset is a PATTERN here, not a literal
          run="${rest%%$qset*}"
          if [ -n "$run" ]; then chunk="$chunk$run"; k=$((k + ${#run})); fi
        fi
        have_word=1
        continue
      fi
      case "$c" in
        '"'|"'")
          q="$c"; have_word=1
          # The stop set the bulk run above cuts at, built once per span
          # rather than per character. A backslash is literal inside single
          # quotes, which is the same rule the escape branch above already
          # applies, so it is not a stop there.
          if [ "$c" = "'" ]; then qset="[']"; else qset='[\\"]'; fi
          ;;
        ' '|"$TAB")
          [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word$chunk")
          word=""; chunk=""; have_word=0
          ;;
        '&'|'|'|';'|"$NL")
          [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word$chunk")
          word=""; chunk=""; have_word=0
          # An empty piece is no command at all: leading whitespace or a
          # newline, or the second character of `&&` / `||`. Keep scanning so
          # the FIRST real command is still the one that gets handed back.
          [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -eq 0 ] && continue
          piece_closed=1; GAIA_FIRST_COMMAND_END=$((base - BLOCK + k)); break 2
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
          [ "$have_word" = 1 ] && { chunk="$chunk$c"; continue; }
          piece_closed=1; GAIA_FIRST_COMMAND_END=$((base - BLOCK + k)); break 2
          ;;
        *) chunk="$chunk$c"; have_word=1 ;;
      esac
    done
    word="$word$chunk"; chunk=""
  done
  if [ "$_had_lc_all" = set ]; then LC_ALL="$_prev_lc_all"; else unset LC_ALL; fi
  # shellcheck disable=SC2034 # read by the merge gate, never in this file
  GAIA_FIRST_COMMAND_CLOSED="$piece_closed"
  # The whole command was one piece, so its trailing word closes it.
  if [ "$piece_closed" = 0 ]; then
    [ "$have_word" = 1 ] && GAIA_FIRST_COMMAND_WORDS+=("$word$chunk")
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

# ---------------------------------------------------------------------------
# URL-reference form of the act-on-home question, shared by the same two
# consumers.
#
# gh takes `<number> | <url> | <branch>` as a merge selector, and a URL is the
# one form `-R`/`--repo` cannot qualify: gh resolves the repository from the
# URL itself and ignores the flag, so the scanned repository is empty and the
# comparison above reads it as home. A consumer that ACTS on the home
# repository therefore cannot take a URL's number at face value: a merged
# sibling-repository pull request read by URL would reach THIS repository's
# pull request or issue of the same number, because the write resolves here.
#
# Both consumers ask this of the identical scanned value, which is why the
# answer lives here beside the `-R`/`--repo` half rather than twice in them.
# The two halves are one boundary, and a boundary that answers the same
# question two different ways depending on which hook asks it is the failure
# a single definition rules out.
#
# Sets GAIA_HOME_PR_NUMBER and returns 0 when the reference is a URL naming
# the home repository. Returns 1 otherwise, which every caller reads as
# "decline": an unresolvable home, an unrecognized URL shape, another
# repository, and another host are all values no caller may act on.
GAIA_HOME_PR_NUMBER=""

gaia_gh_merge_ref_to_home_pr() {
  local ref="$1"
  local url_re host slug number

  GAIA_HOME_PR_NUMBER=""

  gaia_repo_scope_resolve_home || return 1

  # Two shapes are matched as loosely as gh matches them; everywhere else this
  # stays deliberately tighter, so the first half is not a rule to follow gh
  # everywhere. gh's own URL matcher is `^/([^/]+)/([^/]+)/pull/(\d+)` against
  # the parsed path, UNANCHORED at the end, and it compares `u.Hostname()`,
  # which drops both a port and any userinfo.
  #
  # Followed: a `/`, `?`, or `#` suffix, the Files tab's own address being
  # `.../pull/7/files`, and a `:port` on the authority. gh merges the home
  # pull request each of those names, so declining one costs the consumer a
  # merge it should have acted on, which is the whole reason to loosen.
  #
  # Not followed: a suffix has to start with a separator, so `/pull/7files`
  # declines where gh's unanchored regex reads pull request 7, and userinfo
  # stays on the compared authority, so `https://user@github.com/...` declines
  # too. Every divergence that remains declines, which is this function's safe
  # direction, so each costs a silent no-op rather than a wrong write.
  #
  # That last sentence is why the scheme is `https?` and not a general scheme
  # class. gh reads only http and https as a URL and treats any other scheme
  # as a branch name, so a general class accepts `ftp://<home>/pull/7` and
  # hands back 7 for a reference gh never resolved: an ACCEPT where gh
  # declines, which is the one direction a boundary that acts cannot have.
  # Narrowing here keeps every divergence on the declining side.
  #
  # The bracketed spelling is a case-insensitive `https?`. A URL scheme is
  # case-insensitive and Go lowercases it before gh ever sees it, so a plain
  # `https?` would decline `HTTPS://<home>/pull/7`, which gh merges. The
  # alternative, `shopt -s nocasematch`, is process-global: it would also
  # reach the port strip below and every later `[[ ]]` in whichever hook
  # sourced this file.
  url_re='^[hH][tT][tT][pP][sS]?://([^/]+)/([^/]+/[^/]+)/pull/([0-9]+)([/?#].*)?$'
  [[ "$ref" =~ $url_re ]] || return 1
  host=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
  slug=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
  number="${BASH_REMATCH[3]}"

  # Drop a `:port` as gh's `u.Hostname()` does. Requiring digits after the
  # colon is what keeps this off a bracketed IPv6 authority's own colons:
  # `[::1]` ends in `]` and is left whole, `[::1]:443` ends in digits and
  # loses only the port. The home host never carries one, so a port left on
  # would simply never compare equal.
  if [[ "$host" =~ ^(.*):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  fi

  # The authority decides as much as the slug: the same OWNER/REPO served from
  # another host is another repository, and matching on the slug alone would
  # accept it. The slug comparison is case-insensitive because GitHub resolves
  # OWNER/REPO that way, so a URL spelled in another case lands on the home
  # repository and a case-sensitive comparison would cost the action.
  [ "$host" = "$GAIA_REPO_SCOPE_HOME_HOST" ] || return 1
  [ "$slug" = "$(printf '%s' "$GAIA_REPO_SCOPE_HOME_SLUG" | tr '[:upper:]' '[:lower:]')" ] || return 1

  # shellcheck disable=SC2034 # read by both sourcing consumers, never here
  GAIA_HOME_PR_NUMBER="$number"
  return 0
}
